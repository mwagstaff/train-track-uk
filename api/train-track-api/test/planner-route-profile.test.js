import test from 'node:test';
import assert from 'node:assert/strict';
import { findJourneys, validateJourney, scheduledCandidate, departureProfileOrder } from '../lib/planner/router.js';
import { ROUTE_PROFILE_BYTES } from '../lib/planner/route-board-engine.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { plannerConfig } from '../lib/planner/service.js';
import { normalizeRequest } from '../lib/planner/contract.js';

const DATE = '2026-09-17', VERSION = 'd'.repeat(64);
const zero = Date.parse(`${DATE}T08:00:00Z`), minute = 60000;
const at = n => zero + n * minute, iso = n => new Date(at(n)).toISOString();
function train(id, calls) {
    return { id, uid: id, variantId: id, originDate: DATE, operator: 'OP', mode: 'rail',
        calls: calls.map(([station, arrival, departure = arrival, flags = {}], sequence) => ({
            station, tiploc: station, sequence, arrival: arrival === null ? null : at(arrival),
            departure: departure === null ? null : at(departure), canBoard: departure !== null,
            canAlight: arrival !== null, ...flags })) };
}
function network(services) {
    return { services, stations: new Map(['AAA', 'BBB', 'CCC', 'DDD'].map(crs => [crs,
        { crs, name: crs, minimumChangeMinutes: 5 }])), rules: { tsi: [], links: [] } };
}
const request = values => ({ origin: 'AAA', destination: 'DDD', time: iso(0), timeType: 'departAfter',
    windowMinutes: 480, maxChanges: 5, limit: 1000, via: [], ...values });
const metrics = journeys => [...new Set(journeys.map(j => `${Date.parse(j.departure)}|${Date.parse(j.arrival)}|${j.changes}`))].sort();

test('saved departure profiles keep an earlier slow train even when a later departure overtakes it', () => {
    const net = network([train('slow', [['AAA', null, 5], ['DDD', 120, null]]),
        train('fast', [['AAA', null, 60], ['DDD', 100, null]])]);
    assert.deepEqual(findJourneys(request(), net).journeys.map(j => j.legs[0].uid), ['fast']);
    assert.deepEqual(findJourneys(request(), net, { departureProfile: true }).journeys.map(j => j.legs[0].uid), ['fast', 'slow']);
});

test('ordered vias allow staying aboard and exclude passing, skipped and incorrectly ordered calls', () => {
    const net = network([
        train('through', [['AAA', null, 5], ['BBB', 15, 16], ['CCC', 25, 26], ['DDD', 35, null]]),
        train('wrong', [['AAA', null, 10], ['CCC', 17, 18], ['BBB', 24, 25], ['DDD', 30, null]]),
        train('passes', [['AAA', null, 15], ['BBB', 20, 20, { canBoard: false, canAlight: false }], ['CCC', 25, 26], ['DDD', 29, null]]),
        train('express', [['AAA', null, 20], ['DDD', 27, null]])
    ]);
    for (const reverse of [false, true]) {
        const query = request({ via: ['BBB', 'CCC'], ...(reverse ? { timeType: 'arriveBy', time: iso(100) } : {}) });
        const result = findJourneys(query, net, { departureProfile: true });
        assert.deepEqual(result.journeys.map(j => j.legs[0].uid), ['through']);
        assert.equal(result.journeys[0].changes, 0);
        assert.equal(validateJourney(result.journeys[0], net, query), true);
        assert.equal(validateJourney(result.journeys[0], net, { ...query, via: ['CCC', 'BBB'] }), false);
    }
});

test('mandatory intermediate stations can be reached through a supplied transfer in either direction', () => {
    const net = network([train('in', [['AAA', null, 5], ['BBB', 15, null]]),
        train('out', [['CCC', null, 30], ['DDD', 45, null]])]);
    net.rules.links = [{ id: 'walk', origin: 'BBB', destination: 'CCC', minutes: 1,
        mode: 'walk', startTime: '0000', endTime: '2359', priority: 1 }];
    for (const reverse of [false, true]) {
        const query = request({ via: ['BBB', 'CCC'], ...(reverse ? { timeType: 'arriveBy', time: iso(60) } : {}) });
        const routed = findJourneys(query, net, { departureProfile: true });
        assert.equal(routed.journeys.length, 1);
        assert.equal(validateJourney(routed.journeys[0], net, query), true);
        assert.equal(routed.journeys[0].changes, 1);
    }
});

// Independent oracle enumerates legal journeys directly from source calls;
// it uses neither the router indexes nor its labels/boarding dominance.
function exhaustive(net, query) {
    const solutions = [], reverse = query.timeType === 'arriveBy', target = Date.parse(query.time);
    function explore(station, ready, first, rides, used, progress) {
        if (station === query.destination && rides && progress === query.via.length) {
            if (reverse ? ready <= target && ready > target - query.windowMinutes * minute
                : first >= target && first < target + query.windowMinutes * minute) {
                solutions.push({ departure: first, arrival: ready, changes: rides - 1 });
            }
            if (!reverse) return;
        }
        if (rides > query.maxChanges) return;
        for (const service of net.services) {
            if (used.has(service.id)) continue;
            for (let board = 0; board < service.calls.length - 1; board++) {
                const start = service.calls[board];
                if (start.station !== station || !start.canBoard || start.departure < ready + (rides ? 5 * minute : 0)) continue;
                let visited = progress;
                for (let alight = board + 1; alight < service.calls.length; alight++) {
                    const end = service.calls[alight];
                    if ((end.canBoard || end.canAlight) && end.station === query.via[visited]) visited++;
                    if (end.canAlight && end.arrival >= start.departure) explore(end.station, end.arrival,
                        first ?? start.departure, rides + 1, new Set([...used, service.id]), visited);
                }
            }
        }
    }
    explore(query.origin, reverse ? -Infinity : target, null, 0, new Set(), 0);
    return [...new Set(solutions.filter(a => !solutions.some(b => (reverse ? a.arrival === b.arrival : a.departure === b.departure)
        && b.departure >= a.departure && b.arrival <= a.arrival && b.changes <= a.changes
        && (b.departure > a.departure || b.arrival < a.arrival || b.changes < a.changes)))
        .map(j => `${j.departure}|${j.arrival}|${j.changes}`))].sort();
}

test('departure profiles and ordered vias agree with exhaustive cyclic networks in both directions', () => {
    let seed = 27193;
    const random = n => { seed = (Math.imul(seed, 1103515245) + 12345) >>> 0; return (seed >>> 8) % n; };
    const codes = ['AAA', 'BBB', 'CCC', 'DDD'];
    for (let fixture = 0; fixture < 80; fixture++) {
        const services = [];
        for (let i = 0; i < 10; i++) {
            const departure = random(70);
            services.push(train(`T${i}`, Array.from({ length: 4 }, (_, stop) =>
                [codes[random(4)], stop ? departure + stop * 7 : null, stop === 3 ? null : departure + stop * 7 + 1])));
        }
        const net = network(services);
        for (const via of [[], ['BBB'], ['BBB', 'CCC']]) for (const reverse of [false, true]) {
            const query = request({ via, maxChanges: 3, windowMinutes: 120,
                ...(reverse ? { timeType: 'arriveBy', time: iso(110) } : {}) });
            assert.deepEqual(metrics(findJourneys(query, net, { departureProfile: true }).journeys), exhaustive(net, query),
                `fixture ${fixture}, via ${via}, reverse ${reverse}`);
        }
    }
});

function fixture(t, services, rules) {
    const net = network(services), stations = [...net.stations.values()];
    if (rules) net.rules = rules;
    const repo = { ...net, version: VERSION, stations, allStations: stations,
        metadata: { source: { generationDate: DATE }, importedAt: iso(0), maxEventDayOffset: 0,
            coverage: { startDate: DATE, endDate: '2026-09-20', basis: 'Fixture' }, limitations: [] },
        resolveServices: date => ({ services: date === DATE ? services : [], diagnostics: { counts: {} } }), close() {} };
    const engine = new PlannerEngine({ ...plannerConfig({}), datasetPath: '/fixture/profile' },
        { openDataset: async () => repo, now: () => at(120) });
    t.after(() => engine.close());
    return engine;
}

test('engine profile is persistable, dataset-pinned and additive to public search', async t => {
    const engine = fixture(t, [train('slow', [['AAA', null, 5], ['BBB', 15, 16], ['DDD', 120, null]]),
        train('fast', [['AAA', null, 60], ['BBB', 65, 66], ['DDD', 100, null]])]);
    assert.throws(() => normalizeRequest(request()), error => error.code === 'INVALID_REQUEST');
    const response = await engine.routeBoardProfile({ request: request({ via: ['BBB'] }) });
    assert.equal(response.profile.version, VERSION);
    assert.equal(response.profile.profile.complete, true);
    assert.equal(response.profile.candidates.length, 3); // Both direct trains and the earlier feeder to the faster train.
    assert.equal(response.profile.request.windowMinutes, 480);
    assert.equal(JSON.parse(JSON.stringify(response.profile)).candidates.length, 3);
    assert.equal(response.result.journeys[0].legs[0].uid, 'fast');
    assert.equal(response.result.journeys[0].firstTrain.originDate, DATE);
    assert.deepEqual(response.result.journeys[0].legs[0].serviceCallingPoints.map(call => call.station.crs), ['AAA', 'BBB', 'DDD']);
    assert.equal((await engine.journey(response.result.journeys[0].id)).journey.legs[0].uid, 'fast');
    const legacy = await engine.search({ request: normalizeRequest(request({ limit: 5, windowMinutes: 360 })) });
    assert.equal(legacy.journeys[0].legs[0].uid, undefined);
    await assert.rejects(engine.routeBoardProfile({ request: request({ via: ['AAA'] }) }), { code: 'INVALID_REQUEST' });
    await assert.rejects(engine.routeBoardProfile({ request: request(), version: 'e'.repeat(64) }), { code: 'CURSOR_EXPIRED' });
    await assert.rejects(engine.routeBoardProfile({ request: request() }, { aborted: true }), { code: 'SEARCH_CANCELLED' });
});

test('candidate cap is explicit and never claims a complete scheduled profile', async t => {
    const engine = fixture(t, Array.from({ length: 514 }, (_, i) => train(`T${i}`,
        [['AAA', null, i / 2], ['DDD', i / 2 + 10, null]])));
    const { profile, result } = await engine.routeBoardProfile({ request: request({ maxChanges: 0 }) });
    assert.equal(profile.candidates.length, 512);
    assert.equal(profile.profile.complete, false);
    assert.equal(profile.searchTruncated, true);
    assert.equal(result.search.searchTruncated, true);
    assert.ok(result.warnings.some(warning => warning.includes('More alternatives may exist')));
    assert.equal(profile.profile.departureTimesAvailable, 514);
    assert.equal(profile.profile.departureTimesRetained, 512);
});

test('bounded selection gives every departure a first option before filling alternatives', () => {
    const ranked = Array.from({ length: 10 }, (_, index) => ({ departure: iso(0), choice: index }));
    ranked.push({ departure: iso(60), choice: 0 }, { departure: iso(120), choice: 0 });
    assert.deepEqual(departureProfileOrder(ranked).slice(0, 3).map(value => value.departure), [iso(0), iso(60), iso(120)]);
});

test('serialized private profiles stay below the byte cap and disclose omitted candidates', async t => {
    const services = Array.from({ length: 4 }, (_, index) => ({ ...train(`T${index}`,
        [['AAA', null, index * 10], ['DDD', index * 10 + 5, null]]),
    sourceRef: { member: 'MCA', line: index, fixturePadding: 'x'.repeat(1200000) } }));
    const { profile } = await fixture(t, services).routeBoardProfile({ request: request({ maxChanges: 0 }) });
    assert.ok(Buffer.byteLength(JSON.stringify(profile)) <= ROUTE_PROFILE_BYTES);
    assert.equal(profile.candidates.length, 3);
    assert.equal(profile.searchTruncated, true);
    assert.equal(profile.profile.complete, false);
});

test('hourly profile partitions preserve the monolithic frontier at exact boundaries and ordered vias', async t => {
    const services = [0, 59, 60, 119, 120, 359, 360, 479, 480].flatMap((departure, index) => [
        train(`slow${index}`, [['AAA', null, departure], ['BBB', departure + 20, departure + 21], ['DDD', departure + 110, null]]),
        train(`fast${index}`, [['BBB', null, departure + 30], ['DDD', departure + 50, null]])
    ]);
    const engine = fixture(t, services), query = request({ via: ['BBB'] });
    const { profile } = await engine.routeBoardProfile({ request: query });
    assert.deepEqual(metrics(profile.candidates), metrics(findJourneys(query, network(services), { departureProfile: true }).journeys));
    assert.ok(profile.candidates.some(journey => journey.departure === iso(60)));
    assert.ok(profile.candidates.every(journey => journey.departure !== iso(480)));
});

test('ephemeral structural candidates restore source times without retaining expiring predictions', () => {
    const net = network([train('T1', [['AAA', null, 10], ['BBB', 20, 21], ['DDD', 30, null]])]);
    const original = findJourneys(request(), net).journeys[0];
    const live = structuredClone(original);
    live.legs[0].serviceId = 'T1:segment:1';
    live.legs[0].scheduledServiceId = 'T1';
    live.legs[0].live = { status: 'delayed' };
    live.legs[0].departure = iso(20);
    const restored = scheduledCandidate(live, net);
    assert.equal(restored.legs[0].serviceId, 'T1');
    assert.equal(restored.legs[0].departure, iso(10));
    assert.equal(restored.legs[0].live, undefined);
    assert.equal(validateJourney(restored, net, request()), true);
});

test('refresh is routing-free and full replan starts now while retaining a source-only ephemeral pool', async t => {
    const engine = fixture(t, [train('past', [['AAA', null, 5], ['DDD', 120, null]]),
        train('next', [['AAA', null, 150], ['BBB', 165, 166], ['DDD', 180, null]]),
        train('later', [['AAA', null, 200], ['BBB', 215, 216], ['DDD', 230, null]])]);
    engine.liveProvider = {
        fetchBoards: async () => ({ boards: [], errors: [{ reason: 'connectivity' }], limited: false }),
        fetchDetails: async () => ({ details: [], errors: [], limited: false })
    };
    const { profile } = await engine.routeBoardProfile({ request: request({ via: ['BBB'] }) });
    const queries = [];
    engine.findJourneys = (query, net, options) => { queries.push({ ...query, departureProfile: options.departureProfile }); return findJourneys(query, net, options); };
    const refresh = await engine.routeBoardRefresh({ profile, time: iso(120) });
    assert.equal(queries.length, 0);
    assert.equal(refresh.journeys[0].legs[0].uid, 'next');
    assert.equal(refresh.journeys[0].legs[0].live, undefined);
    const replanned = await engine.routeBoardReplan({ profile, time: iso(120), disruptionFingerprint: 'trigger' });
    assert.ok(queries.length > 0);
    assert.equal(queries[0].time, iso(120));
    assert.ok(queries.every(query => query.time === iso(120) && query.windowMinutes === 360 && !query.departureProfile));
    assert.equal(replanned.disruptionFingerprint, 'trigger');
    assert.equal(replanned.needsReplan, false);
    assert.equal(replanned.refreshProfile.profile.ephemeral, true);
    assert.equal(replanned.refreshProfile.version, VERSION);
    assert.ok(replanned.journeys.every(journey => Date.parse(journey.departure) >= at(120)));
    assert.ok(replanned.refreshProfile.candidates.every(candidate => candidate.legs.every(leg => !leg.live)));
    const truncated = await engine.routeBoardReplan({ profile: { ...profile, searchTruncated: true }, time: iso(120) });
    assert.equal(truncated.search.searchTruncated, true);
    assert.ok(truncated.warnings.some(warning => warning.includes('More alternatives may exist')));
});

test('transfer-only profiles refresh to one unique current itinerary without live lookups', async t => {
    for (const mode of ['walk', 'tubeTransfer']) {
        const engine = fixture(t, [], { tsi: [], links: [{ id: mode, origin: 'AAA', destination: 'DDD',
            mode, minutes: 10, startTime: '0000', endTime: '2359', priority: 1 }] });
        engine.liveProvider = { fetchBoards: async () => assert.fail('Transfer-only boards need no live request') };
        const { profile } = await engine.routeBoardProfile({ request: request() });
        assert.equal(profile.candidates.length, 8);
        const response = await engine.routeBoardRefresh({ profile, time: iso(120) });
        assert.equal(response.journeys.length, 1);
        assert.equal(response.journeys[0].departure, iso(120));
        assert.equal(response.journeys[0].legs[0].mode, mode);
        assert.equal(new Set(response.journeys.map(journey => journey.id)).size, response.journeys.length);
    }
});
