import test from 'node:test';
import assert from 'node:assert/strict';
import { findJourneysAsync, validateJourney } from '../lib/planner/router.js';
import { createTubeResolver } from '../lib/planner/tube-routing.js';
import { createConnectionIndex } from '../lib/planner/connections.js';

const MINUTE = 60000;
const at = value => Date.parse(`2026-09-19T${value}:00Z`);
const iso = value => new Date(value).toISOString();
const clear = { status: 'noIssues', coverage: 'complete', issues: [], sources: [] };
const train = (id, from, departure, to, arrival) => ({ id, mode: 'rail', operator: 'XX', calls: [
    { station: from, departure: at(departure), canBoard: true },
    { station: to, arrival: at(arrival), canAlight: true }
] });
const network = () => ({ stations: new Map(['AAA', 'VIC', 'PAD', 'BBB'].map(crs => [crs, { crs, name: crs, minimumChangeMinutes: 5 }])),
    services: [train('feeder', 'AAA', '11:00', 'VIC', '11:20'), train('early', 'PAD', '11:45', 'BBB', '12:00'),
        train('later', 'PAD', '12:10', 'BBB', '12:30')],
    rules: { tsi: [], links: [{ id: 'tube-link', origin: 'VIC', destination: 'PAD', mode: 'tubeTransfer', minutes: 10 }] } });
const request = overrides => ({ origin: 'AAA', destination: 'BBB', time: iso(at('10:50')), timeType: 'departAfter',
    windowMinutes: 120, maxChanges: 3, limit: 5, ...overrides });

function resolver({ closure = false, lines = ['circle'], budget = { limit: 2, used: 1 }, now = () => at('08:00') } = {}) {
    const requested = [];
    const source = { lookup: async query => {
        if (query.budget.used >= query.budget.limit) return { status: 'unavailable', journeys: [], meta: { reason: 'requestLimit' } };
        query.budget.used++;
        requested.push(query);
        const start = Date.parse(query.time) - (query.timeMode === 'arriveBy' ? 30 * MINUTE : 0), end = start + 30 * MINUTE;
        const disruption = closure ? { ...clear, status: 'majorIssues', issues: [
            { id: 'closure', severity: 'major', statusDescription: 'Closed', description: 'Line closed' }
        ] } : clear;
        return { status: 'available', expiresAt: iso(at('08:01')), meta: { updatedAt: iso(at('08:00')) }, journeys: [
            { id: 'verified', departureTime: iso(start), arrivalTime: iso(end), disruption,
                legs: lines.map((line, i) => ({ id: String(i), mode: 'tube', instruction: `Take ${line}`, lines: [{ id: line, name: line }],
                    from: { id: i ? 'change' : 'vic', name: i ? 'Change' : 'Victoria' },
                    to: { id: i === lines.length - 1 ? 'pad' : 'change', name: i === lines.length - 1 ? 'Paddington' : 'Change' },
                    departureTime: iso(start + 30 * MINUTE * i / lines.length),
                    arrivalTime: iso(start + 30 * MINUTE * (i + 1) / lines.length), disruption })) }
        ] };
    } };
    return { requested, budget, resolve: createTubeResolver(source, { now, budget }) };
}

test('reserved lookup verifies the selected transfer and reroutes to the later catchable train', async () => {
    const source = resolver(), net = network(), query = request();
    const result = await findJourneysAsync(query, net, { resolveTubeConnection: source.resolve });
    assert.equal(source.requested.length, 1);
    assert.equal(source.budget.used, 2);
    assert.equal(result.journeys[0].legs.at(-1).serviceId, 'later');
    const tube = result.journeys[0].legs.find(leg => leg.mode === 'tubeTransfer');
    assert.equal(tube.localJourney.status, 'available');
    assert.equal(tube.arrival, iso(at('12:00')));
    assert.ok(validateJourney(result.journeys[0], net, query));
});

test('verification cannot retain a generic fallback after learning that the line is closed', async () => {
    const source = resolver({ closure: true });
    const result = await findJourneysAsync(request(), network(), { resolveTubeConnection: source.resolve });
    assert.equal(source.requested.length, 1);
    assert.equal(result.journeys.length, 0);
});

test('verification reapplies maxChanges after the selected Tube option adds a vehicle change', async () => {
    const source = resolver({ lines: ['victoria', 'bakerloo'] });
    const result = await findJourneysAsync(request({ maxChanges: 2 }), network(), { resolveTubeConnection: source.resolve });
    assert.equal(source.requested.length, 1);
    assert.equal(result.journeys.length, 0);
});

test('the reserve cannot exceed the total lookup budget', async () => {
    const source = resolver({ budget: { limit: 1, used: 1 } });
    const result = await findJourneysAsync(request(), network(), { resolveTubeConnection: source.resolve });
    assert.equal(source.requested.length, 0);
    assert.equal(source.budget.used, 1);
    assert.equal(result.journeys[0].legs.find(leg => leg.mode === 'tubeTransfer').localJourney.status, 'unavailable');
});

test('an earlier feeder reuses the actual Tube departure without inventing fewer changes', async () => {
    const source = resolver({ lines: ['victoria', 'bakerloo'] }), net = network(), query = request({ time: iso(at('10:40')) });
    net.services.unshift(train('earlier-feeder', 'AAA', '10:50', 'VIC', '11:10'));
    const result = await findJourneysAsync(query, net, { resolveTubeConnection: source.resolve });
    assert.equal(source.requested.length, 1);
    assert.equal(result.journeys[0].arrival, iso(at('12:30')));
    for (const journey of result.journeys) {
        const tube = journey.legs.find(leg => leg.mode === 'tubeTransfer');
        assert.equal(tube.localJourney.status, 'available');
        assert.equal(tube.localJourney.steps.length, 2);
        assert.equal(tube.localJourney.departureTime, iso(at('11:25')));
        assert.equal(tube.localJourney.expiresAt, iso(at('08:01')));
        assert.equal(journey.changes, 3);
        assert.ok(validateJourney(journey, net, query));
    }
});

test('arrive-by verification checks a newly preferred connection within the same total budget', async () => {
    const source = resolver({ budget: { limit: 4, used: 2 } }), net = network();
    const query = request({ time: iso(at('12:40')), timeType: 'arriveBy' });
    const result = await findJourneysAsync(query, net, { resolveTubeConnection: source.resolve, tubeVerificationLimit: 1 });
    assert.equal(source.requested.length, 2);
    assert.equal(source.budget.used, 4);
    assert.ok(result.journeys.length);
    assert.equal(result.journeys[0].legs.at(-1).serviceId, 'later');
    assert.equal(result.journeys[0].legs.find(leg => leg.mode === 'tubeTransfer').localJourney.status, 'available');
    assert.ok(validateJourney(result.journeys[0], net, query));
});

test('the async router still supports timetable-only callers without a Tube resolver', async () => {
    const result = await findJourneysAsync(request(), network());
    assert.equal(result.journeys[0].legs.at(-1).serviceId, 'early');
});

for (const [name, arrival, departure, elapsed] of [
    ['expired observation', '11:10', null, 2 * MINUTE],
    ['more than 30 minutes away', '10:40', null, 0],
    ['missed Tube departure', '11:21', null, 0],
    ['missed onward train', '11:10', '11:50', 0]
]) {
    test(`nearby reuse rejects ${name}`, async () => {
        let clock = at('08:00');
        const source = resolver({ budget: { limit: 1, used: 0 }, now: () => clock });
        const index = createConnectionIndex(network());
        const query = { from: 'VIC', to: 'PAD', arrival: at('11:20'), direction: 'earliest', allowedModes: ['tubeTransfer'] };
        const first = await source.resolve(index, query);
        assert.equal(first[0].localJourney.status, 'available');
        clock += elapsed;
        const second = await source.resolve(index, { ...query, arrival: at(arrival),
            ...(departure ? { departure: at(departure) } : {}) });
        assert.ok(second.every(connection => connection.localJourney.status === 'unavailable'));
        assert.equal(source.requested.length, 1);
    });
}
