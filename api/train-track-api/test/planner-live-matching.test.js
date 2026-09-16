import test from 'node:test';
import assert from 'node:assert/strict';
import { discoverLiveMatches, matchLiveObservations, expectedDepartureTime } from '../lib/planner/live-matching.js';
import { applyLiveSnapshot } from '../lib/planner/live-network.js';

const zero = Date.parse('2026-09-08T10:00:00+01:00');
const time = minute => zero + minute * 60000;
const train = (id = 'train', rows = [['AAA', null, 0], ['BBB', 10, 11], ['DDD', 20, null]]) => ({
    id, operator: 'OP', mode: 'rail', calls: rows.map(([station, arrival, departure], sequence) => ({
        station, sequence, arrival: arrival == null ? null : time(arrival), departure: departure == null ? null : time(departure),
        canAlight: arrival != null, canBoard: departure != null
    }))
});
function network(services = [train()]) {
    return { services, stations: new Map(['AAA', 'BBB', 'DDD'].map(crs => [crs, { crs, name: crs, minimumChangeMinutes: 5 }])), rules: { tsi: [], links: [] } };
}
function observations(detail = {}) {
    return {
        boards: [{ station: 'AAA', generatedAt: new Date(zero).toISOString(), services: [
            { serviceID: 'opaque-AAA', operatorCode: 'OP', std: '10:00' }
        ] }],
        details: [{ serviceID: 'opaque-AAA', station: 'AAA', generatedAt: new Date(zero).toISOString(), detail: {
            crs: 'AAA', operatorCode: 'OP', std: '10:00', etd: '10:05',
            subsequentCallingPoints: [{ callingPoint: [{ crs: 'BBB', st: '10:10', et: '10:15' }, { crs: 'DDD', st: '10:20', et: '10:25' }] }],
            ...detail
        } }]
    };
}

test('station/operator/dated-clock anchors are verified against ordered through calls', () => {
    const net = network();
    const observationsValue = observations();
    const discovery = discoverLiveMatches(net, observationsValue.boards, { now: zero });
    assert.deepEqual(discovery[0].candidates, [{ scheduledServiceId: 'train', index: 0, scheduledDeparture: time(0) }]);
    const matched = matchLiveObservations(net, observationsValue, { now: zero });
    assert.equal(matched.matchedCount, 1);
    assert.equal(matched.services[0].calls[0].departure, time(5));
    assert.equal(matched.services[0].calls[1].arrival, time(15));
    assert.equal(matched.services[0].calls[1].departure, undefined);
    assert.equal(applyLiveSnapshot(net, matched).services[0].calls[1].canBoard, false);
});

test('verified board observations retain departure platform and train length', () => {
    const input = observations({ platform: '1', length: 8 });
    input.boards[0].services[0].platform = '2';
    input.boards[0].services[0].length = 10;
    input.details[0].detail.subsequentCallingPoints[0].callingPoint[0].length = 4;
    const matched = matchLiveObservations(network(), input, { now: zero });
    assert.equal(matched.services[0].calls[0].platform, '2');
    assert.equal(matched.services[0].calls[0].length, 10);
    assert.equal(matched.services[0].calls[1].length, 4);
});

test('ambiguous occurrences, wrong operators and unordered calling patterns are not overlaid', () => {
    for (const [net, input] of [
        [network([train('one'), train('two')]), observations()],
        [network(), observations({ operatorCode: 'XX' })],
        [network(), observations({ subsequentCallingPoints: [{ callingPoint: [{ crs: 'DDD', st: '10:20' }, { crs: 'BBB', st: '10:10' }] }] })]
    ]) assert.equal(matchLiveObservations(net, input, { now: zero }).services.length, 0);
});

test('unrequested details stay a private coverage diagnostic without an unsafe-matching warning', () => {
    const unrelated = train('unrelated', [['AAA', null, 30], ['BBB', 40, null]]);
    const input = observations();
    input.boards[0].services.push({ serviceID: 'other-board-service', operatorCode: 'OP', std: '10:30' });
    const result = matchLiveObservations(network([train(), unrelated]), input, { now: zero });
    assert.equal(result.matchedCount, 1);
    assert.equal(result.unmatchedCount, 1);
    assert.equal(result.unsafeMatchCount, 0);
    assert.deepEqual(result.warnings, []);
    assert.deepEqual(result.diagnostics, [{ reason: 'missingDetail', station: 'AAA',
        serviceID: 'other-board-service', candidateServiceIds: ['unrelated'] }]);
    assert.deepEqual(result.diagnosticCounts, { missingDetail: 1, staleDetail: 0, ambiguous: 0, mismatch: 0 });
    assert.equal(result.diagnosticsTruncated, false);
});

test('stale, invalid and missing detail timestamps differ from absent details and identity failures', () => {
    for (const generatedAt of [undefined, 'invalid', new Date(zero - 91000).toISOString(), new Date(zero + 6000).toISOString()]) {
        const input = observations();
        input.details[0].generatedAt = generatedAt;
        input.details[0].fetchedAt = new Date(zero).toISOString();
        const result = matchLiveObservations(network(), input, { now: zero });
        assert.deepEqual(result.services, []);
        assert.equal(result.unmatchedCount, 1);
        assert.equal(result.unsafeMatchCount, 0);
        assert.equal(result.diagnosticCounts.staleDetail, 1);
        assert.deepEqual(result.diagnostics, [{ reason: 'staleDetail', station: 'AAA',
            serviceID: 'opaque-AAA', candidateServiceIds: ['train'] }]);
        assert.deepEqual(result.warnings, []);
    }
});

test('ambiguous occurrence and call mappings remain rejected with candidate-scoped diagnostics', () => {
    const duplicate = matchLiveObservations(network([train('one'), train('two')]), observations(), { now: zero });
    assert.deepEqual(duplicate.services, []);
    assert.equal(duplicate.unsafeMatchCount, 1);
    assert.deepEqual(duplicate.diagnostics, [{ reason: 'ambiguous', station: 'AAA',
        serviceID: 'opaque-AAA', candidateServiceIds: ['one', 'two'] }]);
    const repeated = train('repeated', [['AAA', null, 0], ['BBB', 10, 10], ['BBB', 10, 10], ['DDD', 20, null]]);
    const repeatedResult = matchLiveObservations(network([repeated]), observations(), { now: zero });
    assert.deepEqual(repeatedResult.services, []);
    assert.equal(repeatedResult.diagnosticCounts.ambiguous, 1);
    const competing = matchLiveObservations(network([train('unique-mapping'), repeated]), observations(), { now: zero });
    assert.deepEqual(competing.services, []);
    assert.equal(competing.diagnosticCounts.ambiguous, 1);
    assert.deepEqual(competing.diagnostics[0].candidateServiceIds, ['repeated', 'unique-mapping']);
    const mismatch = matchLiveObservations(network(), observations({ operatorCode: 'XX' }), { now: zero });
    assert.deepEqual(mismatch.services, []);
    assert.equal(mismatch.diagnosticCounts.mismatch, 1);
    assert.equal(mismatch.unsafeMatchCount, 1);
    assert.deepEqual(mismatch.warnings, []);
});

test('diagnostics are bounded, retain actual failures before unrequested details, and keep complete counts', () => {
    const input = observations({ operatorCode: 'XX' });
    input.boards[0].services = [
        ...Array.from({ length: 600 }, (_, index) => ({ serviceID: `unrequested-${index}`, operatorCode: 'OP', std: '10:00' })),
        input.boards[0].services[0]
    ];
    const result = matchLiveObservations(network(), input, { now: zero });
    assert.equal(result.unmatchedCount, 601);
    assert.equal(result.unsafeMatchCount, 1);
    assert.equal(result.diagnosticCounts.missingDetail, 600);
    assert.equal(result.diagnosticCounts.mismatch, 1);
    assert.equal(result.diagnostics.length, 512);
    assert.equal(result.diagnostics[0].reason, 'mismatch');
    assert.equal(result.diagnostics[0].serviceID, 'opaque-AAA');
    assert.equal(result.diagnosticsTruncated, true);
});

test('board cancellation applies only at the observed stop, and branch groups stay separate', () => {
    const matched = matchLiveObservations(network(), observations({ isCancelled: true,
        subsequentCallingPoints: [
            { callingPoint: [{ crs: 'BBB', st: '10:10', et: 'On time' }, { crs: 'DDD', st: '10:20', et: 'On time' }] },
            { callingPoint: [{ crs: 'ZZZ', st: '10:22', isCancelled: true }] }
        ]
    }), { now: zero });
    assert.equal(matched.services[0].cancelled, undefined);
    assert.equal(matched.services[0].calls[0].cancelled, true);
    assert.equal(matched.services[0].calls.length, 3);
    const live = applyLiveSnapshot(network(), matched);
    assert.equal(live.services.length, 1);
    assert.equal(live.services[0].calls[0].canBoard, false);
    assert.equal(live.services[0].calls[1].canBoard, true);
});

test('previous call forecasts are departures, subsequent call forecasts are arrivals', () => {
    const input = observations();
    input.boards[0].station = 'BBB';
    input.boards[0].services[0] = { serviceID: 'middle', operatorCode: 'OP', sta: '10:10', std: '10:11' };
    input.details[0] = { serviceID: 'middle', station: 'BBB', generatedAt: new Date(zero).toISOString(), detail: {
        crs: 'BBB', operatorCode: 'OP', sta: '10:10', std: '10:11', eta: '10:15', etd: '10:16',
        previousCallingPoints: [{ callingPoint: [{ crs: 'AAA', st: '10:00', at: '10:05' }] }],
        subsequentCallingPoints: [{ callingPoint: [{ crs: 'DDD', st: '10:20', et: '10:25' }] }]
    } };
    const calls = matchLiveObservations(network(), input, { now: zero }).services[0].calls;
    assert.equal(calls[0].departure, time(5));
    assert.equal(calls[0].arrival, undefined);
    assert.equal(calls[1].arrival, time(15));
    assert.equal(calls[1].departure, time(16));
    assert.equal(calls[2].arrival, time(25));
    assert.equal(calls[2].departure, undefined);
});

test('clock forecasts roll over midnight using the matched schedule occurrence', () => {
    const service = train('night', [['AAA', null, 830], ['DDD', 850, null]]);
    const input = observations({ std: '23:50', etd: '00:05', subsequentCallingPoints: [{ callingPoint: [{ crs: 'DDD', st: '00:10', et: '00:25' }] }] });
    input.boards[0].generatedAt = new Date(time(825)).toISOString();
    input.boards[0].services[0].std = '23:50';
    input.details[0].generatedAt = input.boards[0].generatedAt;
    const calls = matchLiveObservations(network([service]), input, { now: time(825) }).services[0].calls;
    assert.equal(calls[0].departure, time(845));
    assert.equal(calls[1].arrival, time(865));
});

test('expected departure helper keeps actual precedence, midnight dates and unknown values', () => {
    assert.equal(expectedDepartureTime({ etd: '10:05' }, time(0)), time(5));
    assert.equal(expectedDepartureTime({ etd: '10:05', atd: '09:58' }, time(0)), time(-2));
    assert.equal(expectedDepartureTime({ etd: '10:05', atd: 'On time' }, time(0)), time(0));
    assert.equal(expectedDepartureTime({ etd: '00:05' }, time(830)), time(845));
    assert.equal(expectedDepartureTime({ etd: '23:58' }, time(850)), time(838));
    for (const value of [undefined, null, '', 'Delayed', 'Cancelled']) {
        assert.equal(expectedDepartureTime({ etd: value }, time(0)), undefined);
    }
    assert.equal(expectedDepartureTime({ etd: 'On time' }, null), undefined);
});

test('unknown departure delays are explicit and actual times take precedence over estimates', () => {
    const unknown = matchLiveObservations(network(), observations({ etd: 'Delayed' }), { now: zero });
    assert.equal(unknown.services[0].calls[0].departureUnknown, true);
    assert.equal(applyLiveSnapshot(network(), unknown).services[0].calls[0].canBoard, false);
    const actual = matchLiveObservations(network(), observations({ etd: '10:05', atd: '10:02' }), { now: zero });
    assert.equal(actual.services[0].calls[0].departure, time(2));
    const actualOnTime = matchLiveObservations(network(), observations({ etd: '10:05', atd: 'On time' }), { now: zero });
    assert.equal(actualOnTime.services[0].calls[0].departure, time(0));
});

test('provider timestamps must be present, fresh and not in the future', () => {
    for (const generatedAt of [undefined, new Date(zero - 91000).toISOString(), new Date(zero + 6000).toISOString(), 'invalid']) {
        for (const source of ['boards', 'details']) {
            const input = observations();
            input[source][0].generatedAt = generatedAt;
            input[source][0].fetchedAt = new Date(zero).toISOString();
            assert.equal(matchLiveObservations(network(), input, { now: zero }).services.length, 0);
        }
    }
    const input = observations();
    input.details[0].generatedAt = new Date(zero - 20000).toISOString();
    const result = matchLiveObservations(network(), input, { now: zero });
    assert.equal(result.observedAt, zero - 20000);
    assert.equal(result.expiresAt, zero + 70000);
});

test('fresh board cancellation and time facts override an older detailed response at that stop', () => {
    const input = observations({ isCancelled: false, etd: 'On time' });
    input.details[0].generatedAt = new Date(zero - 10000).toISOString();
    Object.assign(input.boards[0].services[0], { isCancelled: true, etd: '10:10', cancelReason: 'Cancelled at this stop' });
    const matched = matchLiveObservations(network(), input, { now: zero });
    assert.equal(matched.services[0].calls[0].cancelled, true);
    assert.equal(matched.services[0].calls[0].departure, time(10));
    assert.equal(matched.services[0].cancelled, undefined);
});

test('overlapping boards use their newest observation regardless of response completion order', () => {
    const input = observations({ isCancelled: false, etd: 'On time' });
    input.details[0].generatedAt = new Date(zero - 10000).toISOString();
    const old = structuredClone(input.boards[0]);
    old.generatedAt = new Date(zero - 10000).toISOString();
    old.window = { offsetMinutes: -119 };
    old.services[0].etd = 'On time';
    input.boards[0].services[0].etd = 'Cancelled';
    for (const boards of [[old, input.boards[0]], [input.boards[0], old]]) {
        const matched = matchLiveObservations(network(), { ...input, boards }, { now: zero });
        assert.equal(matched.services[0].calls[0].cancelled, true);
    }
});

test('unknown future disruption suppresses only later unverified travel, while uncertainty alone is a warning', () => {
    for (const flag of ['futureCancellation', 'futureDelay']) {
        const input = observations({ etd: 'On time', [flag]: true,
            subsequentCallingPoints: [{ callingPoint: [{ crs: 'BBB', st: '10:10', et: 'On time' }, { crs: 'DDD', st: '10:20', et: 'On time' }] }]
        });
        const matched = matchLiveObservations(network(), input, { now: zero });
        const applied = applyLiveSnapshot(network(), matched);
        assert.equal(applied.services[0].calls[0].canBoard, true);
        assert.equal(applied.services[0].calls[1].canBoard, false);
        assert.equal(applied.services[0].calls[2].canAlight, false);
        assert.ok(matched.services[0].warnings.length);
    }
    const uncertain = matchLiveObservations(network(), observations({ uncertainty: true }), { now: zero });
    assert.ok(uncertain.services[0].warnings.length);
    assert.equal(applyLiveSnapshot(network(), uncertain).services[0].calls[0].canBoard, true);
});
