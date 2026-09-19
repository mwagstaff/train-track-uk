import test from 'node:test';
import assert from 'node:assert/strict';
import { CAPABILITIES, normalizeRequest, encodeCursor, decodeCursor } from '../lib/planner/contract.js';
import { parseFixedLink } from '../lib/planner/parser.js';
import { createConnectionIndex, resolveConnection, validateFixedLink } from '../lib/planner/connections.js';
import { findJourneys, validateJourney } from '../lib/planner/router.js';
import { compileRaptorNetwork, findRaptorJourneys } from '../lib/planner/raptor-poc.js';
import { PlannerEngine } from '../lib/planner/engine.js';

const instant = clock => Date.parse(`2026-09-19T${clock}:00+01:00`);
const iso = clock => new Date(instant(clock)).toISOString();
const previousModes = ['rail', 'replacementBus', 'walk', 'tubeTransfer'];
const input = { origin: 'CLK', destination: 'ING', time: '2026-09-19T00:54:29.561+01:00',
    timeType: 'departAfter', realtime: 'off', limit: 10 };
const train = (uid, from, to, departure, arrival) => ({ id: uid, uid, variantId: uid, originDate: '2026-09-19',
    mode: 'rail', operator: 'OP', calls: [
        { station: from, sequence: 0, departure: instant(departure), arrival: null, canBoard: true, canAlight: false },
        { station: to, sequence: 1, departure: null, arrival: instant(arrival), canBoard: false, canAlight: true }
    ] });

// Reduced 19 September itinerary with independently transcribed RJTTF939 ALF
// rows and station allowances. Train calls retain the reported service times.
function network() {
    return { stations: new Map(Object.entries({ CLK: 2, KTH: 4, VIC: 15, EUS: 15, STG: 5, ING: 5 })
        .map(([crs, minimumChangeMinutes]) => [crs, { crs, name: crs, minimumChangeMinutes }])),
    rules: { tsi: [], links: [
        parseFixedLink('M=WALK,O=CLK,D=KTH,T=9,S=0001,E=2359,P=4,R=1111110', { member: 'ALF', line: 646 }),
        parseFixedLink('M=TRANSFER,O=EUS,D=VIC,T=19,S=0001,E=0629,P=4,R=0000010', { member: 'ALF', line: 1289 }),
        parseFixedLink('M=TUBE,O=EUS,D=VIC,T=14,S=0630,E=0659,P=4,R=0000010', { member: 'ALF', line: 1292 })
    ] }, services: [
        train('P86786', 'KTH', 'VIC', '04:57', '05:18'),
        train('Y14771', 'EUS', 'STG', '06:10', '12:20'),
        train('C14717', 'STG', 'ING', '12:43', '13:41'),
        train('later-alternative', 'CLK', 'ING', '05:59', '14:39')
    ] };
}

test('generic transfers are advertised and enabled by default, with explicit exclusions preserved', () => {
    assert.ok(CAPABILITIES.allowedModes.includes('genericTransfer'));
    assert.deepEqual(normalizeRequest(input).allowedModes, [...previousModes, 'genericTransfer'].sort());
    assert.deepEqual(normalizeRequest({ ...input, allowedModes: previousModes }).allowedModes, [...previousModes].sort());
    assert.deepEqual(normalizeRequest({ ...input, allowedModes: ['rail', 'genericTransfer'] }).allowedModes, ['genericTransfer', 'rail']);
    assert.throws(() => normalizeRequest({ ...input, allowedModes: ['metroTransfer'] }), { code: 'INVALID_REQUEST' });
});

test('existing normalized cursors keep their original mode permissions', () => {
    for (const algorithm of ['original', 'raptor']) {
        const previous = normalizeRequest({ ...input, algorithm, allowedModes: previousModes });
        const current = normalizeRequest({ ...input, algorithm });
        for (const request of [previous, current]) {
            const decoded = decodeCursor(encodeCursor(request, 'a'.repeat(64), 2));
            assert.deepEqual(decoded.request, request);
            assert.equal(decoded.offset, 2);
        }
        assert.equal(decodeCursor(encodeCursor(previous, 'a'.repeat(64))).request.allowedModes.includes('genericTransfer'), false);
    }
});

test('supplied generic transfers retain source windows, weekday and endpoint allowances', () => {
    const index = createConnectionIndex(network());
    const query = { from: 'VIC', to: 'EUS', arrival: instant('05:18'), departure: instant('06:10') };
    const connection = resolveConnection(index, query);
    assert.equal(connection.mode, 'genericTransfer');
    assert.equal(connection.ruleId, 'ALF:1289');
    assert.equal(connection.movementStart, instant('05:33'));
    assert.equal(connection.movementEnd, instant('05:52'));
    assert.equal(connection.end, instant('06:07'));
    assert.deepEqual(connection.breakdown, { exitMinutes: 15, travelMinutes: 19, entryMinutes: 15, extraMinutes: 0, waitingMinutes: 0 });
    assert.ok(validateFixedLink(index, connection));
    assert.equal(resolveConnection(index, { ...query, allowedModes: previousModes }), null);
    assert.equal(resolveConnection(index, { ...query, extraConnectionMinutes: 4 }), null);
    assert.equal(resolveConnection(index, { ...query, arrival: instant('06:00'), departure: undefined,
        allowedModes: ['genericTransfer'] }), null, 'All 19 movement minutes must fit before the 06:29 source boundary');
    assert.equal(resolveConnection(index, { ...query, arrival: Date.parse('2026-09-20T05:18:00+01:00'),
        departure: undefined, allowedModes: ['genericTransfer'] }), null, 'Saturday-only rows cannot apply on Sunday');
});

for (const algorithm of ['original', 'raptor']) {
    const route = (request, net) => algorithm === 'raptor'
        ? findRaptorJourneys(request, compileRaptorNetwork(net)) : findJourneys(request, net);

    test(`${algorithm} returns the Clock House 04:44–Invergowrie 13:41 itinerary with the supplied transfer`, () => {
        const net = network();
        for (const request of [input, normalizeRequest({ ...input, algorithm })]) {
            const result = route(request, net);
            const journey = result.journeys.find(journey => journey.arrival === iso('13:41'));
            assert.ok(journey);
            assert.equal(journey.departure, iso('04:44'));
            assert.equal(journey.durationMinutes, 537);
            assert.equal(journey.changes, 3, 'The supplied non-walking transfer consumes one boarding');
            assert.deepEqual(journey.legs.filter(leg => leg.kind === 'vehicle').map(leg => leg.serviceId), ['P86786', 'Y14771', 'C14717']);
            const walking = journey.legs[0];
            assert.equal(walking.movementDeparture, iso('04:44'));
            assert.equal(walking.movementArrival, iso('04:53'));
            assert.equal(walking.breakdown.entryMinutes, 4);
            const transfer = journey.legs.find(leg => leg.mode === 'genericTransfer');
            assert.equal(transfer.from.crs, 'VIC');
            assert.equal(transfer.to.crs, 'EUS');
            assert.equal(transfer.movementDeparture, iso('05:33'));
            assert.equal(transfer.movementArrival, iso('05:52'));
            assert.ok(transfer.warnings.some(warning => warning.includes('generic transfer')));
            const presented = new PlannerEngine({}).publicJourney(journey);
            assert.deepEqual(presented.legs.find(leg => leg.mode === 'genericTransfer').warnings, transfer.warnings);
            assert.ok(validateJourney(journey, net, request));
            assert.equal(result.searchTruncated, false);
        }
    });

    test(`${algorithm} keeps mode exclusions, initial departure windows and connection buffers`, () => {
        const net = network();
        for (const values of [{ allowedModes: previousModes }, { allowedModes: ['rail', 'genericTransfer'] },
            { maxChanges: 2 }, { extraConnectionMinutes: 4 }, { time: iso('04:45') }]) {
            const result = route(normalizeRequest({ ...input, algorithm, ...values }), net);
            assert.ok(result.journeys.length);
            assert.ok(result.journeys.every(journey => journey.arrival === iso('14:39')));
        }
        const permitted = normalizeRequest({ ...input, algorithm, allowedModes: ['rail', 'walk', 'genericTransfer'], time: iso('04:44') });
        assert.equal(route(permitted, net).journeys[0].arrival, iso('13:41'));
        const endingAtDeparture = normalizeRequest({ ...input, algorithm, time: '2026-09-18T22:44:00+01:00' });
        assert.equal(route(endingAtDeparture, net).journeys.length, 0, 'The source departure window has an exclusive end');
    });
}
