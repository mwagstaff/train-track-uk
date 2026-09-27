import test from 'node:test';
import assert from 'node:assert/strict';
import { findJourneys } from '../lib/planner/router.js';
import { compileRaptorNetwork, findRaptorJourneys } from '../lib/planner/raptor-poc.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { plannerConfig } from '../lib/planner/service.js';
import { decodeCursor, normalizeRequest } from '../lib/planner/contract.js';

const instant = (day, clock) => Date.parse(`2026-09-${day}T${clock}:00+01:00`);
const iso = (day, clock) => new Date(instant(day, clock)).toISOString();
const call = (station, day, arrival, departure) => ({ station,
    arrival: arrival ? instant(day, arrival) : null, departure: departure ? instant(day, departure) : null,
    canAlight: Boolean(arrival), canBoard: Boolean(departure) });
const train = (id, calls) => ({ id, uid: id, mode: 'rail', operator: 'OP', originDate: '2026-09-27', calls });
const request = values => normalizeRequest({ origin: 'ELE', destination: 'BIK', time: iso('27', '02:40'),
    timeType: 'departAfter', limit: 10, ...values });
function network(services) {
    const codes = new Set(services.flatMap(service => service.calls.map(call => call.station)));
    return { services, rules: { tsi: [], links: [] },
        stations: new Map([...codes].map(crs => [crs, { crs, name: crs, minimumChangeMinutes: 10 }])) };
}
const feeder = () => ({ ...train('morning-feeder', [call('ELE', '27', null, '08:23'), call('LBG', '27', '08:48', null)]), operator: 'SE' });
const onward = () => train('first-birkbeck', [call('LBG', '28', null, '05:56'), call('BIK', '28', '06:33', null)]);

for (const algorithm of ['original', 'raptor']) {
    const route = (query, net) => algorithm === 'raptor'
        ? findRaptorJourneys(query, compileRaptorNetwork(net)) : findJourneys(query, net);

    test(`${algorithm} rejects a Newcastle round trip even when every individual wait is within six hours`, () => {
        const net = network([feeder(), onward(),
            train('north', [call('LBG', '27', null, '09:21'), call('NCL', '27', '15:00', null)]),
            train('south', [call('NCL', '27', null, '20:00'), call('LBG', '27', '23:56', null)])]);
        assert.deepEqual(route(request({ algorithm }), net).journeys, []);
        const intentional = route(request({ algorithm, via: ['NCL'] }), net).journeys;
        assert.equal(intentional.length, 1, 'An explicit via can require revisiting London Bridge');
        assert.equal(intentional[0].arrival, iso('28', '06:33'));
        if (algorithm === 'original') {
            const reverse = request({ timeType: 'arriveBy', time: iso('28', '06:33') });
            assert.deepEqual(route(reverse, net).journeys, []);
            assert.equal(route({ ...reverse, via: ['NCL'] }, net).journeys.length, 1);
        }
    });

    test(`${algorithm} detects returns through intermediate public calls, but permits non-boarding pass-throughs`, () => {
        const services = [feeder(),
            train('north', [call('LBG', '27', null, '09:21'), call('STP', '27', '09:35', '09:36'), call('LUT', '27', '10:30', null)]),
            train('south', [call('LUT', '27', null, '16:00'), call('STP', '27', '17:00', '17:01'), call('TUH', '27', '17:30', null)]),
            train('finish', [call('TUH', '27', null, '18:00'), call('BIK', '27', '18:15', null)])];
        assert.deepEqual(route(request({ algorithm }), network(services)).journeys, []);
        const passing = structuredClone(services);
        passing[2].calls[1].canBoard = false;
        passing[2].calls[1].canAlight = false;
        assert.equal(route(request({ algorithm }), network(passing)).journeys.length, 1,
            'Waiting at St Pancras cannot replace this ride when the southbound train does not stop there');
    });

    test(`${algorithm} preserves a through service with repeated stops`, () => {
        const net = network([train('circular', [call('ELE', '27', null, '08:23'), call('LBG', '27', '08:48', '08:49'),
            call('ELE', '27', '09:15', '09:16'), call('BIK', '27', '09:30', null)])]);
        assert.equal(route(request({ algorithm }), net).journeys.length, 1);
    });
}

function engineFixture(t, services) {
    const net = network(services), version = 'a'.repeat(64);
    const repo = { version, stations: [...net.stations.values()], rules: net.rules,
        metadata: { source: { generationDate: '2026-09-26' }, importedAt: iso('26', '20:00'), maxEventDayOffset: 1,
            coverage: { startDate: '2026-09-01', endDate: '2026-10-01' }, limitations: [] },
        resolveServices: date => ({ services: date === '2026-09-27' ? net.services : [], diagnostics: { counts: {} } }),
        close() {} };
    const engine = new PlannerEngine({ ...plannerConfig({}), datasetPath: '/synthetic/journey-quality',
        tubeTrackEnabled: false }, { openDataset: async () => repo, now: () => instant('27', '02:40') });
    t.after(() => engine.close());
    return engine;
}

test('interactive searches continue to the National Rail overnight option instead of stopping on an earlier detour', async t => {
    const engine = engineFixture(t, [feeder(), onward(),
        train('late-feeder', [call('ELE', '27', null, '23:53'), call('LBG', '28', '00:18', null)]),
        // This alternative has no repeated stations. It must still lose to the
        // later departure which arrives earlier with the same number of changes.
        train('victoria-detour', [call('ELE', '27', null, '20:23'), call('VIC', '28', '00:17', null)]),
        train('victoria-finish', [call('VIC', '28', null, '06:03'), call('BIK', '28', '06:53', null)])]);
    let payload = { request: request({ algorithm: 'raptor' }) };
    for (let page = 0; page < 4; page++) {
        const result = await engine.search(payload);
        assert.equal(result.search.searchTruncated, false);
        if (page < 3) {
            assert.deepEqual(result.journeys, [], 'Inferior overnight routes must not stop the app looking in later windows');
            payload = decodeCursor(result.pagination.later);
        } else {
            assert.equal(result.journeys.length, 1);
            const journey = result.journeys[0];
            assert.equal(journey.departure, iso('27', '23:53'));
            assert.equal(journey.arrival, iso('28', '06:33'));
            assert.equal(journey.changes, 1);
            assert.equal(journey.durationMinutes, 400);
            assert.deepEqual(journey.legs.filter(leg => leg.kind === 'vehicle').map(leg => [leg.from.crs, leg.to.crs]),
                [['ELE', 'LBG'], ['LBG', 'BIK']]);
        }
    }
});

test('later-window comparison preserves a route that arrives earlier and keeps departure paging exact', async t => {
    const engine = engineFixture(t, [
        train('early', [call('ELE', '27', null, '08:23'), call('BIK', '27', '09:00', null)]),
        train('later', [call('ELE', '27', null, '08:53'), call('BIK', '27', '09:30', null)])]);
    const result = await engine.search({ request: request({ algorithm: 'raptor', limit: 1 }) });
    assert.equal(result.journeys.length, 1);
    assert.equal(result.journeys[0].departure, iso('27', '08:23'));
    assert.equal(result.pagination.more, undefined);
    const later = await engine.search(decodeCursor(result.pagination.later));
    assert.equal(later.journeys[0].departure, iso('27', '08:53'));
});
