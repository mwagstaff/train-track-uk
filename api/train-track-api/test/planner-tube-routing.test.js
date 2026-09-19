import test from 'node:test';
import assert from 'node:assert/strict';
import { findJourneysAsync, validateJourney } from '../lib/planner/router.js';
import { createTubeResolver } from '../lib/planner/tube-routing.js';
import { PlannerEngine } from '../lib/planner/engine.js';

const MINUTE = 60000;
const at = value => Date.parse(`2026-09-19T${value}:00Z`);
const iso = value => new Date(value).toISOString();
const now = () => at('08:00');
const clear = { status: 'noIssues', hasDisruption: false, coverage: 'complete', issues: [],
    sources: [{ source: 'realtime', status: 'notApplicable' }, { source: 'plannedWorks', status: 'available' }] };
const issue = (status, description = 'Minor Delays') => ({ ...clear, status, hasDisruption: true,
    issues: [{ id: description, lineId: 'circle', severity: status === 'minorIssues' ? 'minor' : 'major',
        description: `Circle line: ${description}`, statusDescription: description, scope: 'line', stale: false }] });

function option(start, minutes = 15, disruption = clear, lines = ['circle']) {
    const end = start + minutes * MINUTE;
    return { id: `${start}-${minutes}-${lines.join('-')}`, departureTime: iso(start), arrivalTime: iso(end),
        durationMinutes: minutes, disruption, warnings: [], legs: lines.map((line, i) => ({
            id: String(i), mode: 'tube', instruction: `Take ${line} to ${i === lines.length - 1 ? 'Victoria' : 'Oxford Circus'}`,
            from: { id: i ? 'change' : 'paddington', name: i ? 'Oxford Circus' : 'Paddington' },
            to: { id: i === lines.length - 1 ? 'victoria' : 'change', name: i === lines.length - 1 ? 'Victoria' : 'Oxford Circus' },
            departureTime: iso(start + minutes * MINUTE * i / lines.length),
            arrivalTime: iso(start + minutes * MINUTE * (i + 1) / lines.length),
            durationMinutes: minutes / lines.length, timing: 'estimated', lines: [{ id: line, name: line }], disruption
        })) };
}

function provider(make) {
    const calls = [];
    return { calls, lookup: async query => {
        calls.push(query);
        return { status: 'available', journeys: make(query), expiresAt: iso(now() + MINUTE), meta: { updatedAt: iso(now()), stale: false } };
    } };
}

function network(services = [], mode = 'tubeTransfer', minutes = 15) {
    return { stations: new Map(['AAA', 'PAD', 'VIC', 'BBB'].map(crs => [crs, { crs, name: crs, minimumChangeMinutes: 5 }])),
        services, rules: { tsi: [], links: [{ id: 'london-link', origin: 'PAD', destination: 'VIC',
            mode, minutes, startTime: '0000', endTime: '2359', sourceRef: { member: 'ALF' } }] } };
}

function service(id, from, departure, to, arrival) {
    return { id, mode: 'rail', operator: 'XX', calls: [
        { station: from, departure: at(departure), canBoard: true },
        { station: to, arrival: at(arrival), canAlight: true }
    ] };
}

const query = overrides => ({ origin: 'PAD', destination: 'VIC', time: iso(at('11:00')), timeType: 'departAfter',
    maxChanges: 5, windowMinutes: 120, limit: 5, ...overrides });
async function search(request, net, source) {
    const resolveTubeConnection = createTubeResolver(source, { now });
    return findJourneysAsync(request, net, { resolveTubeConnection, maxOperations: 1000000, timeoutMs: 10000 });
}

test('transfer-only routing omits outside-journey endpoint allowances and publishes chronological Tube steps', async () => {
    const source = provider(({ time }) => [option(Date.parse(time), 14, clear, ['bakerloo', 'victoria'])]);
    const net = network();
    const result = await search(query(), net, source);
    assert.equal(result.journeys.length, 1);
    const journey = result.journeys[0];
    assert.equal(journey.durationMinutes, 14);
    assert.equal(journey.changes, 1);
    assert.equal(journey.legs[0].localJourney.steps.length, 2);
    assert.equal(journey.legs[0].from.crs, 'PAD');
    assert.ok(validateJourney(journey, net, query()));
    assert.match(journey.legs[0].localJourney.notes.join(' '), /No planned disruption/);
});

test('routing rechecks cancellation immediately after a Tube lookup', async () => {
    const controller = new AbortController();
    let lookedUp = false;
    await assert.rejects(findJourneysAsync(query(), network(), {
        signal: controller.signal,
        resolveTubeConnection: async () => {
            lookedUp = true;
            controller.abort();
            return [];
        }
    }), { code: 'SEARCH_CANCELLED' });
    assert.equal(lookedUp, true);
});

test('routing rechecks its deadline immediately after a Tube lookup', async t => {
    let clock = 0;
    t.mock.method(Date, 'now', () => clock);
    let lookedUp = false;
    await assert.rejects(findJourneysAsync(query(), network(), {
        timeoutMs: 50,
        resolveTubeConnection: async () => {
            lookedUp = true;
            clock = 100;
            return [];
        }
    }), { code: 'SEARCH_TIMEOUT' });
    assert.equal(lookedUp, true);
});

test('minor-delay contingency rejects the earlier onward train and explains the later connection', async () => {
    const net = network([service('feeder', 'AAA', '11:00', 'PAD', '11:20'),
        service('missed', 'VIC', '11:48', 'BBB', '12:05'), service('catchable', 'VIC', '11:55', 'BBB', '12:15')]);
    const source = provider(({ time }) => [option(Date.parse(time), 15, issue('minorIssues'))]);
    const result = await search(query({ origin: 'AAA', destination: 'BBB' }), net, source);
    assert.ok(result.journeys.length);
    assert.equal(result.journeys[0].legs.at(-1).serviceId, 'catchable');
    const transfer = result.journeys[0].legs.find(leg => leg.mode === 'tubeTransfer');
    assert.equal(transfer.breakdown.contingencyMinutes, 5);
    assert.match(transfer.localJourney.notes.join(' '), /extra 5 minutes.*minor delays/);
    assert.equal(transfer.arrival, iso(at('11:50')));
});

test('faster TfL timings expose a train excluded by the generic National Rail duration', async () => {
    const net = network([service('feeder', 'AAA', '11:00', 'PAD', '11:20'), service('earlier', 'VIC', '11:45', 'BBB', '12:00')], 'tubeTransfer', 60);
    const source = provider(({ time }) => [option(Date.parse(time), 10)]);
    const result = await search(query({ origin: 'AAA', destination: 'BBB' }), net, source);
    assert.equal(result.journeys[0]?.legs.at(-1).serviceId, 'earlier');
});

test('walking National Rail links never invoke TubeTrack', async () => {
    const source = provider(() => { throw new Error('walking must not query TubeTrack'); });
    const result = await search(query(), network([], 'walk', 1), source);
    assert.equal(result.journeys[0].legs[0].mode, 'walk');
    assert.equal(source.calls.length, 0);
});

test('automatic ranking prefers a clear slower route and explains avoiding major disruption', async () => {
    const source = provider(({ time }) => [option(Date.parse(time), 10, issue('majorIssues', 'Severe Delays'), ['central']),
        option(Date.parse(time), 20, clear, ['elizabeth'])]);
    const result = await search(query(), network(), source);
    assert.equal(result.journeys[0].legs[0].localJourney.steps[0].lines[0].id, 'elizabeth');
    assert.match(result.journeys[0].legs[0].localJourney.notes.join(' '), /avoid reported disruption.*central/);
});

test('a line-wide partial closure stays advisory while a full closure is excluded', async () => {
    const partial = provider(({ time }) => [option(Date.parse(time), 15, issue('majorIssues', 'Part Closure'))]);
    const result = await search(query(), network(), partial);
    assert.equal(result.journeys.length, 1);
    assert.match(result.journeys[0].legs[0].localJourney.notes.join(' '), /Major disruption/);
    const closed = provider(({ time }) => [option(Date.parse(time), 15, issue('majorIssues', 'Closed'))]);
    assert.equal((await search(query(), network(), closed)).journeys.length, 0);
});

test('arrive-by reserves the five-minute minor-delay contingency before selecting the Tube departure', async () => {
    const source = provider(({ time }) => [option(Date.parse(time) - 15 * MINUTE, 15, issue('minorIssues'))]);
    const request = query({ time: iso(at('12:00')), timeType: 'arriveBy' });
    const result = await search(request, network(), source);
    assert.equal(result.journeys[0].arrival, iso(at('12:00')));
    assert.equal(result.journeys[0].departure, iso(at('11:40')));
    assert.ok(source.calls.every(call => call.timeMode === 'arriveBy'));
    assert.ok(validateJourney(result.journeys[0], network(), request));
});

test('actual Tube boardings enforce maxChanges without losing a slower direct alternative', async () => {
    const source = provider(({ time }) => [option(Date.parse(time), 10, clear, ['bakerloo', 'victoria']),
        option(Date.parse(time), 20, clear, ['circle'])]);
    const result = await search(query({ maxChanges: 0 }), network(), source);
    assert.equal(result.journeys.length, 1);
    assert.equal(result.journeys[0].changes, 0);
    assert.equal(result.journeys[0].legs[0].localJourney.steps[0].lines[0].id, 'circle');
    const sameLine = provider(({ time }) => [option(Date.parse(time), 20, clear, ['mildmay', 'mildmay'])]);
    assert.equal((await search(query(), network(), sameLine)).journeys[0].changes, 1);
});

test('walking-only TfL alternatives retain zero boardings', async () => {
    const source = provider(({ time }) => {
        const value = option(Date.parse(time), 8);
        value.legs[0].mode = 'walking'; value.legs[0].lines = [];
        return [value];
    });
    const result = await search(query({ maxChanges: 0 }), network(), source);
    assert.equal(result.journeys[0].changes, 0);
});

test('API failure falls back with a note but successful no-route and known closures do not', async () => {
    const source = { lookup: async () => ({ status: 'unavailable', reason: 'upstream' }) };
    const result = await search(query(), network(), source);
    assert.equal(result.journeys[0].legs[0].localJourney.status, 'unavailable');
    assert.match(result.journeys[0].legs[0].localJourney.notes[0], /National Rail transfer allowance/);
    assert.equal((await search(query(), network(), provider(() => []))).journeys.length, 0);
    source.lookup = async () => ({ status: 'unavailable', journeys: [option(at('11:05'), 15, issue('majorIssues', 'Closed'))] });
    assert.equal((await search(query(), network(), source)).journeys.length, 0);
});

test('partial coverage never claims a disruption-free route', async () => {
    const source = provider(({ time }) => [option(Date.parse(time), 15, { ...clear, coverage: 'partial' })]);
    const result = await search(query(), network(), source);
    const notes = result.journeys[0].legs[0].localJourney.notes.join(' ');
    assert.match(notes, /incomplete/);
    assert.doesNotMatch(notes, /No planned disruption/);
});

for (const reason of ['requestLimit', 'upstream', 'partialCoverage']) {
    for (const timeType of ['departAfter', 'arriveBy']) {
        test(`${reason} Tube coverage preserves the best ${timeType} connection on the first page`, async () => {
            const reverse = timeType === 'arriveBy';
            const net = network([
                service('feeder', 'AAA', reverse ? '11:10' : '11:00', 'PAD', '11:20'),
                service('onward', 'VIC', '11:50', 'BBB', '12:10'),
                service('direct', 'AAA', reverse ? '11:00' : '11:05', 'BBB', reverse ? '12:10' : '12:20')
            ]);
            const source = reason === 'partialCoverage'
                ? provider(({ time, timeMode }) => [option(Date.parse(time) - (timeMode === 'arriveBy' ? 15 * MINUTE : 0),
                    15, { ...clear, coverage: 'partial' })])
                : { lookup: async () => ({ status: 'unavailable', meta: { reason } }) };
            const request = query({ origin: 'AAA', destination: 'BBB', timeType,
                time: iso(at(reverse ? '12:30' : '10:50')), maxChanges: 2, limit: 1 });
            const result = await search(request, net, source);
            assert.equal(result.journeys.length, 1);
            const journey = result.journeys[0];
            assert.equal(journey.legs[0].serviceId, 'feeder');
            assert.equal(journey.arrival, iso(at('12:10')));
            assert.equal(journey.changes, 2);
            assert.ok(validateJourney(journey, net, request));
            const transfer = journey.legs.find(leg => leg.mode === 'tubeTransfer');
            assert.match(transfer.localJourney.notes.join(' '), reason === 'partialCoverage'
                ? /incomplete/ : /National Rail transfer allowance/);
            assert.doesNotMatch(transfer.localJourney.notes.join(' '), /No planned disruption/);
            const restricted = await search({ ...request, maxChanges: 1 }, net, source);
            assert.equal(restricted.journeys[0].legs[0].serviceId, 'direct');
        });
    }
}

test('partial TfL coverage does not push an earlier connection behind a slower clear option', async () => {
    const source = provider(({ time }) => [option(Date.parse(time), 10, { ...clear, coverage: 'partial' }, ['central']),
        option(Date.parse(time), 20, clear, ['elizabeth'])]);
    const result = await search(query({ limit: 1 }), network(), source);
    const transfer = result.journeys[0].legs[0];
    assert.equal(transfer.localJourney.steps[0].lines[0].id, 'central');
    assert.match(transfer.localJourney.notes.join(' '), /incomplete/);
});

test('unavailable directions retain known major disruption when ranking against a clear rail route', async () => {
    const net = network([service('feeder', 'AAA', '11:00', 'PAD', '11:20'),
        service('onward', 'VIC', '11:50', 'BBB', '12:10'), service('direct', 'AAA', '11:05', 'BBB', '12:20')]);
    const source = { lookup: async ({ time, timeMode }) => ({ status: 'unavailable', meta: { reason: 'upstream' },
        journeys: [option(Date.parse(time) - (timeMode === 'arriveBy' ? 15 * MINUTE : 0),
            15, issue('majorIssues', 'Severe Delays'))] }) };
    const result = await search(query({ origin: 'AAA', destination: 'BBB', time: iso(at('10:50')), limit: 1 }), net, source);
    assert.equal(result.journeys[0].legs[0].serviceId, 'direct');
    assert.match(result.journeys[0].warnings.join(' '), /major TfL disruption/);
});

test('public serialization preserves TfL notes and steps without replacing National Rail identities', async () => {
    const source = provider(({ time }) => [option(Date.parse(time), 15, issue('minorIssues'))]);
    const result = await search(query(), network(), source);
    const engine = new PlannerEngine({}, { now });
    const value = engine.publicJourney(result.journeys[0]);
    assert.equal(value.legs[0].from.crs, 'PAD');
    assert.equal(value.legs[0].localJourney.contingencyMinutes, 5);
    assert.equal(value.legs[0].localJourney.steps[0].from.id, 'paddington');
    assert.equal(value.legs[0].ruleId, undefined);
});
