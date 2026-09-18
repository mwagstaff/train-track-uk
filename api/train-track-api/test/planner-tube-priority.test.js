import test from 'node:test';
import assert from 'node:assert/strict';
import { findJourneysAsync, validateJourney } from '../lib/planner/router.js';
import { createTubeResolver } from '../lib/planner/tube-routing.js';

const MINUTE = 60000;
const at = value => Date.parse(`2026-09-19T${value}:00Z`);
const iso = value => new Date(value).toISOString();
const now = () => at('08:00');
const clear = { status: 'noIssues', hasDisruption: false, coverage: 'complete', issues: [],
    sources: [{ source: 'plannedWorks', status: 'available' }] };

function service(id, from, departure, to, arrival) {
    return { id, mode: 'rail', operator: 'XX', calls: [
        { station: from, departure: at(departure), canBoard: true },
        { station: to, arrival: at(arrival), canAlight: true }
    ] };
}

function link(origin, destination, minutes = 15) {
    return { id: `${origin}-${destination}`, origin, destination, mode: 'tubeTransfer', minutes,
        startTime: '0000', endTime: '2359', sourceRef: { member: 'ALF' } };
}

function network(services, links) {
    const stations = new Set(services.flatMap(value => value.calls.map(call => call.station)));
    for (const value of links) { stations.add(value.origin); stations.add(value.destination); }
    return { stations: new Map([...stations].map(crs => [crs, { crs, name: crs, minimumChangeMinutes: 5 }])),
        services, rules: { tsi: [], links } };
}

function provider(mode = 'tube') {
    const calls = [];
    return { calls, lookup: async query => {
        calls.push(query);
        const duration = 10 * MINUTE;
        const start = Date.parse(query.time) - (query.timeMode === 'arriveBy' ? duration : 0);
        const leg = { id: '0', mode, instruction: `Continue to ${query.to}`,
            from: { id: query.from, name: query.from }, to: { id: query.to, name: query.to },
            departureTime: iso(start), arrivalTime: iso(start + duration), durationMinutes: 10,
            lines: mode === 'walking' ? [] : [{ id: 'circle', name: 'Circle' }], disruption: clear };
        return { status: 'available', journeys: [{ id: `${query.from}-${query.to}-${start}`,
            departureTime: leg.departureTime, arrivalTime: leg.arrivalTime, durationMinutes: 10,
            disruption: clear, warnings: [], legs: [leg] }],
        expiresAt: iso(now() + MINUTE), meta: { updatedAt: iso(now()), stale: false } };
    } };
}

function request(timeType, extra = {}) {
    return { origin: 'AAA', destination: 'BBB', timeType,
        time: iso(at(timeType === 'arriveBy' ? '13:30' : '10:50')),
        maxChanges: 3, windowMinutes: 180, limit: 5, ...extra };
}

async function search(query, net, source) {
    const result = await findJourneysAsync(query, net, { resolveTubeConnection: createTubeResolver(source, { now }) });
    for (const journey of result.journeys) assert.ok(validateJourney(journey, net, query));
    return result;
}

for (const timeType of ['departAfter', 'arriveBy']) {
    test(`${timeType}: twelve dead-end interchanges consume no lookup before Victoria to Paddington`, async () => {
        const reverse = timeType === 'arriveBy';
        const deadEnds = Array.from({ length: 12 }, (_, i) => `D${String(i).padStart(2, '0')}`);
        const links = deadEnds.map(stop => reverse ? link(stop, 'PAD') : link('VIC', stop));
        links.push(link('VIC', 'PAD'));
        const net = network([service('feeder', 'AAA', '11:00', 'VIC', '11:20'),
            service('onward', 'PAD', '12:00', 'BBB', '13:00')], links);
        const source = provider();
        const result = await search(request(timeType), net, source);
        assert.equal(result.journeys.length, 1);
        assert.deepEqual(source.calls.map(call => `${call.from}-${call.to}`), ['VIC-PAD']);
        assert.equal(result.journeys[0].legs.find(leg => leg.mode === 'tubeTransfer').localJourney.status, 'available');
    });

    test(`${timeType}: prune interchanges whose only onward service is outside the feasible time`, async () => {
        const reverse = timeType === 'arriveBy';
        const net = network([service('feeder', 'AAA', '11:00', 'VIC', '11:20'),
            service('onward', 'PAD', '12:00', 'BBB', '13:00'),
            reverse ? service('too-late', 'AAA', '12:00', 'BAD', '12:20')
                : service('too-early', 'BAD', '11:00', 'BBB', '12:00')],
        [reverse ? link('BAD', 'PAD') : link('VIC', 'BAD'), link('VIC', 'PAD')]);
        const source = provider();
        const result = await search(request(timeType), net, source);
        assert.equal(result.journeys.length, 1);
        assert.deepEqual(source.calls.map(call => `${call.from}-${call.to}`), ['VIC-PAD']);
    });

    test(`${timeType}: optimistic pruning preserves a faster walking-only option at maxChanges`, async () => {
        const net = network([service('feeder', 'AAA', '11:00', 'VIC', '11:20'),
            service('onward', 'PAD', '11:40', 'BBB', '13:00')], [link('VIC', 'PAD', 90)]);
        const source = provider('walking');
        const result = await search(request(timeType, { maxChanges: 1 }), net, source);
        assert.equal(result.journeys.length, 1);
        assert.equal(result.journeys[0].changes, 1);
        assert.equal(result.journeys[0].legs.find(leg => leg.mode === 'tubeTransfer').localJourney.steps[0].mode, 'walking');
        assert.equal(source.calls.length, 1);
    });

    test(`${timeType}: prioritize fewer remaining rail boardings before an earlier speculative interchange`, async () => {
        const reverse = timeType === 'arriveBy';
        const extra = reverse
            ? [service('indirect-first', 'AAA', '10:20', 'MID', '10:40'), service('indirect-last', 'MID', '10:45', 'BAD', '11:30')]
            : [service('indirect-first', 'BAD', '11:50', 'MID', '12:10'), service('indirect-last', 'MID', '12:20', 'BBB', '13:10')];
        const net = network([service('feeder', 'AAA', '11:00', 'VIC', '11:20'),
            service('onward', 'PAD', '12:00', 'BBB', '13:00'), ...extra],
        [reverse ? link('BAD', 'PAD') : link('VIC', 'BAD'), link('VIC', 'PAD')]);
        const source = provider();
        await search(request(timeType), net, source);
        assert.equal(`${source.calls[0].from}-${source.calls[0].to}`, 'VIC-PAD');
    });

    test(`${timeType}: prioritize the nearest feasible onward departure when boarding counts tie`, async () => {
        const reverse = timeType === 'arriveBy';
        const alternative = reverse ? service('alternative', 'AAA', '10:40', 'BAD', '11:00')
            : service('alternative', 'BAD', '12:20', 'BBB', '13:20');
        const net = network([service('feeder', 'AAA', '11:00', 'VIC', '11:20'),
            service('onward', 'PAD', '12:00', 'BBB', '13:00'), alternative],
        [reverse ? link('BAD', 'PAD') : link('VIC', 'BAD'), link('VIC', 'PAD')]);
        const source = provider();
        await search(request(timeType), net, source);
        assert.equal(`${source.calls[0].from}-${source.calls[0].to}`, 'VIC-PAD');
    });
}
