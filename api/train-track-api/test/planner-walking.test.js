import test from 'node:test';
import assert from 'node:assert/strict';
import { parseFixedLink } from '../lib/planner/parser.js';
import { findJourneys, validateJourney } from '../lib/planner/router.js';
import { refreshRouteBoard } from '../lib/planner/route-board-live.js';
import { SavedRouteLive } from '../lib/planner/saved-route-live.js';

const instant = clock => Date.parse(`2026-09-18T${clock}:00+01:00`);
const iso = clock => new Date(instant(clock)).toISOString();
const walk = () => parseFixedLink('M=WALK,O=CLK,D=KTH,T=9,S=0001,E=2359,P=4,R=1111110', { member: 'ALF', line: 646 });
const tube = () => parseFixedLink('M=TUBE,O=PAD,D=VIC,T=22,S=0529,E=0659,P=4,R=1111100', { member: 'ALF', line: 2743 });
const train = (id, from, to, departure, arrival) => ({ id, uid: id, variantId: id, originDate: '2026-09-18',
    mode: 'rail', operator: 'OP', calls: [
        { station: from, sequence: 0, departure: instant(departure), arrival: null, canBoard: true, canAlight: false },
        { station: to, sequence: 1, departure: null, arrival: instant(arrival), canBoard: false, canAlight: true }
    ] });
function network(services, links = [walk(), tube()]) {
    return { services, rules: { links, tsi: [] }, stations: new Map(Object.entries({ CLK: 2, KTH: 4, VIC: 15, PAD: 15, BRI: 10 })
        .map(([crs, minimumChangeMinutes]) => [crs, { crs, name: crs, minimumChangeMinutes }])) };
}
const morning = () => network([
    train('Kent House train', 'KTH', 'VIC', '05:12', '05:33'),
    train('Paddington train', 'PAD', 'BRI', '06:28', '08:05'),
    train('Later arrival', 'CLK', 'BRI', '05:25', '08:27')
]);
const query = values => ({ origin: 'CLK', destination: 'BRI', time: iso('04:59'), timeType: 'departAfter', limit: 10, ...values });

test('Clock House walking alternative includes nine minutes walking and four minutes to board, arriving earlier', () => {
    const net = morning();
    for (const request of [query(), query({ timeType: 'arriveBy', time: iso('08:05') })]) {
        const journey = findJourneys(request, net).journeys[0];
        assert.equal(journey.departure, iso('04:59'));
        assert.equal(journey.arrival, iso('08:05'));
        assert.equal(journey.durationMinutes, 186);
        assert.equal(journey.changes, 2, 'Walking is not a train change');
        assert.deepEqual(journey.legs[0].breakdown, { exitMinutes: 0, travelMinutes: 9, entryMinutes: 4, extraMinutes: 0, waitingMinutes: 0 });
        assert.equal(journey.legs[0].movementDeparture, iso('04:59'));
        assert.equal(journey.legs[0].movementArrival, iso('05:08'));
        assert.equal(journey.legs[1].departure, iso('05:12'));
        assert.ok(validateJourney(journey, net, request));
    }
});

test('walking respects departure and arrival boundaries, permitted modes, changes, via and extra connection time', () => {
    const net = morning();
    for (const request of [query({ time: iso('05:00') }), query({ allowedModes: ['rail', 'tubeTransfer'] }),
        query({ extraConnectionMinutes: 1 }), query({ maxChanges: 1 })]) {
        const result = findJourneys(request, net);
        assert.equal(result.journeys[0].arrival, iso('08:27'));
        assert.ok(result.journeys.every(journey => journey.legs[0].mode !== 'walk'));
    }
    assert.equal(findJourneys(query({ timeType: 'arriveBy', time: iso('08:04') }), net).journeys.length, 0);
    assert.equal(findJourneys(query({ via: ['KTH', 'VIC'] }), net).journeys[0].arrival, iso('08:05'));
    assert.equal(findJourneys(query({ via: ['VIC', 'KTH'] }), net).journeys.length, 0);
});

test('the same supplied link works from Kent House and as a final walk in both search directions', () => {
    const net = network([train('From Clock House', 'CLK', 'BRI', '05:12', '06:00'),
        train('Returning', 'BRI', 'KTH', '05:12', '06:00')], [walk()]);
    for (const timeType of ['departAfter', 'arriveBy']) {
        const outgoing = query({ origin: 'KTH', timeType, time: iso(timeType === 'arriveBy' ? '06:00' : '05:01'), maxChanges: 0 });
        const first = findJourneys(outgoing, net).journeys[0];
        assert.equal(first.departure, iso('05:01'));
        assert.equal(first.legs[0].breakdown.entryMinutes, 2);
        assert.equal(first.changes, 0);
        const incoming = query({ origin: 'BRI', destination: 'CLK', timeType,
            time: iso(timeType === 'arriveBy' ? '06:13' : '05:12'), maxChanges: 0 });
        const last = findJourneys(incoming, net).journeys[0];
        assert.equal(last.arrival, iso('06:13'));
        assert.deepEqual(last.legs.at(-1).breakdown, { exitMinutes: 4, travelMinutes: 9, entryMinutes: 0, extraMinutes: 0, waitingMinutes: 0 });
        assert.ok(validateJourney(last, net, incoming));
    }
});

test('shorter walking allowance cannot remove the necessary allowance between two trains', () => {
    const net = network([train('Inbound', 'BRI', 'CLK', '04:00', '04:59'),
        train('Too soon', 'KTH', 'VIC', '05:12', '05:33')], [walk()]);
    const request = query({ origin: 'BRI', destination: 'VIC', time: iso('04:00') });
    assert.equal(findJourneys(request, net).journeys.length, 0, 'Needs 2 minutes to exit, 9 to walk and 4 to board');
});

test('walking without a time benefit is omitted and long walks include their full duration', () => {
    for (const minutes of [9, 35]) {
        const net = network([train('Nearby train', 'KTH', 'BRI', '06:00', '07:00'),
            train('Better train', 'CLK', 'BRI', '06:00', '06:50')], [{ ...walk(), minutes }]);
        const result = findJourneys(query(), net);
        assert.equal(result.journeys.length, 1);
        assert.equal(result.journeys[0].legs[0].serviceId, 'Better train');
        const justWalk = findJourneys(query(), { ...net, services: net.services.slice(0, 1) }).journeys[0];
        assert.equal(justWalk.durationMinutes, minutes + 4 + 60);
    }
});

test('missing, malformed or inactive supplied walking links never invent a nearby route', () => {
    for (const links of [[], [{ ...walk(), minutes: -1 }], [{ ...walk(), minutes: Infinity }],
        [{ ...walk(), days: '0000001' }], [{ ...walk(), startTime: '0505', endTime: '0508' }]]) {
        const net = network([train('Nearby train', 'KTH', 'BRI', '05:12', '06:00')], links);
        // Coordinates by themselves do not establish a safe pedestrian route.
        for (const station of net.stations.values()) Object.assign(station, { latitude: 51.409, longitude: -0.041 });
        assert.equal(findJourneys(query(), net).journeys.length, 0);
    }
});

test('independent validation rejects a walk whose boarding allowance was removed', () => {
    const net = morning(), request = query();
    const journey = structuredClone(findJourneys(request, net).journeys[0]);
    journey.legs[0].breakdown.entryMinutes = 0;
    assert.equal(validateJourney(journey, net, request), false);
});

test('saved and route-board refresh retain endpoint walk allowances and latest useful departure', async () => {
    const now = instant('04:00'), net = morning(), request = query({ time: iso('04:00') });
    const candidates = findJourneys(request, net).journeys;
    const railProvider = { fetchBoards: async () => ({ boards: [], errors: [] }), fetchDetails: async () => ({ details: [], errors: [] }) };
    const board = await refreshRouteBoard({ network: net, profile: { request, candidates }, time: iso('04:00') },
        { provider: railProvider, now: () => now });
    const saved = new SavedRouteLive({ now: () => now, provider: railProvider,
        getDepartures: async () => ({ departures: [], dataStatus: 'unavailable' }) });
    const plan = { result: { dataset: { version: 'test', warnings: [] }, journeys: candidates, search: {}, warnings: [] },
        connections: { stations: [...net.stations.values()], rules: net.rules } };
    const restored = JSON.parse(JSON.stringify(plan));
    const refreshed = await saved.refresh(restored, request);
    for (const result of [board, refreshed]) {
        const journey = result.journeys.find(journey => journey.legs[0].mode === 'walk');
        assert.ok(journey);
        assert.equal(journey.departure, iso('04:59'));
        assert.equal(journey.arrival, iso('08:05'));
        assert.equal(journey.durationMinutes, 186);
        assert.equal(journey.legs[0].breakdown.exitMinutes, 0);
        assert.equal(journey.legs[0].breakdown.entryMinutes, 4);
    }
    const noWalk = await saved.refresh(plan, { ...request, allowedModes: ['rail', 'tubeTransfer'] });
    assert.ok(noWalk.journeys.every(journey => journey.legs.every(leg => leg.mode !== 'walk')));
});

test('saved and route-board refresh retain alighting time before the final walk', async () => {
    const now = instant('04:00');
    const net = network([train('Returning', 'BRI', 'KTH', '05:12', '06:00')], [walk()]);
    const request = query({ origin: 'BRI', destination: 'CLK', time: iso('04:00') });
    const candidates = findJourneys(request, net).journeys;
    const provider = { fetchBoards: async () => ({ boards: [], errors: [] }), fetchDetails: async () => ({ details: [], errors: [] }) };
    const board = await refreshRouteBoard({ network: net, profile: { request, candidates }, time: iso('04:00') }, { provider, now: () => now });
    const saved = new SavedRouteLive({ now: () => now, provider,
        getDepartures: async () => ({ departures: [], dataStatus: 'unavailable' }) });
    const plan = JSON.parse(JSON.stringify({ result: { dataset: { version: 'test', warnings: [] }, journeys: candidates, search: {}, warnings: [] },
        connections: { stations: [...net.stations.values()], rules: net.rules } }));
    for (const result of [board, await saved.refresh(plan, request)]) {
        const journey = result.journeys[0];
        assert.equal(journey.arrival, iso('06:13'));
        assert.equal(journey.durationMinutes, 61);
        assert.deepEqual(journey.legs.at(-1).breakdown, { exitMinutes: 4, travelMinutes: 9, entryMinutes: 0, extraMinutes: 0, waitingMinutes: 0 });
    }
});
