import test from 'node:test';
import assert from 'node:assert/strict';
import { matchStaffObservations } from '../lib/planner/live-staff-matching.js';
import { applyLiveSnapshot, liveLeg } from '../lib/planner/live-network.js';

const now = Date.parse('2026-09-16T16:50:00+01:00');
const instant = clock => Date.parse(`2026-09-16T${clock}:00+01:00`);
function fixture() {
    const service = { id: 'selected', uid: 'G26231', originDate: '2026-09-16', operator: 'SN', mode: 'rail', calls: [
        { station: 'VIC', tiploc: 'VICTRIC', arrival: null, departure: instant('17:05'), canBoard: true, canAlight: false },
        { station: 'ECR', tiploc: 'ECROYDN', arrival: instant('17:23'), departure: instant('17:24'), canBoard: true, canAlight: true },
        { station: 'PMH', tiploc: 'PHBR', arrival: instant('19:00'), departure: null, canBoard: false, canAlight: true }
    ].map((call, sequence) => ({ ...call, sequence })) };
    const item = { uid: 'G26231', sdd: '2026-09-16', rid: '202609167126231', operatorCode: 'SN', isPassengerService: true,
        std: '2026-09-16T17:05:00', etd: '2026-09-16T17:07:30', departureType: 'Forecast',
        platform: '8', platformIsHidden: true, subsequentLocations: [
            { tiploc: 'PASSING', isPass: true, std: '2026-09-16T17:06:30', etd: '2026-09-16T17:09:00', departureType: 'Forecast' },
            { crs: 'ECR', tiploc: 'ECROYDN', sta: '2026-09-16T17:23:00', std: '2026-09-16T17:24:00',
                eta: '2026-09-16T17:25:30', etd: '2026-09-16T17:26:30', arrivalType: 'Forecast', departureType: 'Forecast',
                associations: [{ category: 'divide', uid: 'OTHER', rid: 'child', destCRS: 'BOG' }], platform: '3' },
            { crs: 'PMH', tiploc: 'PHBR', sta: '2026-09-16T19:00:00', eta: '2026-09-16T19:02:30', arrivalType: 'Forecast' }
        ] };
    return { network: { services: [service] }, records: [{ station: 'VIC', generatedAt: new Date(now).toISOString(), services: [item] }],
        service, item, options: { now, serviceIds: ['selected'] } };
}
const match = value => matchStaffObservations(value.network, value.records, value.options);

test('staff recovery verifies exact UID/date/operator and public calls, preserving both direction timestamps', () => {
    const value = fixture();
    const original = structuredClone(value);
    const result = match(value);
    assert.equal(result.matchedCount, 1);
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.services[0].calls.length, 3);
    assert.equal(result.services[0].calls[0].departure, instant('17:07') + 30000);
    assert.equal(result.services[0].calls[1].arrival, instant('17:25') + 30000);
    assert.equal(result.services[0].calls[1].departure, instant('17:26') + 30000);
    assert.equal(result.services[0].calls[0].platform, '');
    assert.equal(result.services[0].calls[1].platform, '3');
    assert.equal(result.observedAt, now);
    assert.equal(result.expiresAt, now + 90000);
    assert.deepEqual(value, original);
    const effective = applyLiveSnapshot(value.network, result);
    const leg = liveLeg(effective.services[0], 0, 1);
    assert.equal(leg.live.status, 'delayed');
    assert.equal(leg.live.arrival, new Date(instant('17:25') + 30000).toISOString());
});

test('staff recovery is opt-in for exact missing service IDs', () => {
    const value = fixture();
    assert.deepEqual(matchStaffObservations(value.network, value.records, { now }).services, []);
    value.options.serviceIds = ['another'];
    assert.deepEqual(match(value).services, []);
});

test('wrong identity, origin date or operator never receives staff forecasts', () => {
    for (const fields of [{ uid: 'C93139' }, { sdd: '2026-09-17' }, { sdd: '2026-02-30' }, { operatorCode: 'SE' }, { rid: '' }]) {
        const value = fixture(); Object.assign(value.item, fields);
        assert.deepEqual(match(value).services, []);
    }
});

test('complete ordered passenger call patterns and TIPLOCs must match the selected schedule', () => {
    for (const change of [
        value => { value.item.subsequentLocations[1].tiploc = 'WRONG'; },
        value => { value.item.subsequentLocations[1].sta = '2026-09-16T17:24:00'; },
        value => { value.item.subsequentLocations[1].sta = '2026-09-17T17:23:00'; },
        value => { value.item.subsequentLocations.reverse(); },
        value => { value.item.subsequentLocations.pop(); },
        value => { value.item.subsequentLocations[1].stdSpecified = false; }
    ]) {
        const value = fixture(); change(value);
        assert.deepEqual(match(value).services, []);
        assert.equal(match(value).diagnostics[0].reason, 'mismatch');
    }
});

test('ambiguity is tested against the whole network, including occurrences outside the allowlist', () => {
    const value = fixture();
    value.network.services.push({ ...value.service, id: 'duplicate' });
    const result = match(value);
    assert.deepEqual(result.services, []);
    assert.equal(result.diagnostics[0].reason, 'ambiguous');
});

test('freshness depends on generatedAt with an explicit offset, never fetchedAt', () => {
    for (const generatedAt of [undefined, 'invalid', '2026-09-16T16:50:00',
        new Date(now - 91000).toISOString(), new Date(now + 6000).toISOString()]) {
        const value = fixture(); value.records[0].generatedAt = generatedAt;
        value.records[0].fetchedAt = new Date(now).toISOString();
        assert.deepEqual(match(value).services, []);
        assert.equal(match(value).diagnostics[0].reason, 'stale');
    }
});

test('actual and forecast types select only their specified fields; unknown forecasts stay unknown', () => {
    const value = fixture();
    value.item.atd = '2026-09-16T17:06:12+01:00'; value.item.departureType = 'Actual';
    const ecr = value.item.subsequentLocations[1];
    ecr.arrivalType = 'NoLog'; ecr.departureType = 'Delayed';
    const calls = match(value).services[0].calls;
    assert.equal(calls[0].departure, instant('17:06') + 12000);
    assert.equal(calls[1].arrival, undefined);
    assert.equal(calls[1].arrivalUnknown, true);
    assert.equal(calls[1].departureUnknown, true);
    value.item.atdSpecified = false;
    assert.equal(match(value).services[0].calls[0].departureUnknown, true);
    value.item.departureTypeSpecified = false;
    assert.equal(match(value).services[0].calls[0].departureUnknown, true);
});

test('cancelled stops remain local and associations never create another portion', () => {
    const value = fixture(); value.item.subsequentLocations[2].isCancelled = true;
    const result = match(value);
    assert.equal(result.services[0].cancelled, undefined);
    assert.equal(result.services[0].calls[2].cancelled, true);
    assert.equal(result.services[0].calls[2].arrival, undefined);
    assert.equal(result.services.length, 1);
    const effective = applyLiveSnapshot(value.network, result);
    assert.equal(liveLeg(effective.services[0], 0, 1).live.cancelled, false);
    assert.equal(liveLeg(effective.services[0], 0, 1).live.partCancelled, true);
});

test('non-passenger, deleted, operational and suppressed services provide no public recovery', () => {
    for (const fields of [{ isPassengerService: false }, { isDeleted: true }, { isOperationalCall: true }, { serviceIsSupressed: true }]) {
        const value = fixture(); Object.assign(value.item, fields);
        assert.deepEqual(match(value).services, []);
    }
    const value = fixture(); value.item.subsequentLocations[1].serviceIsSupressed = true;
    assert.deepEqual(match(value).services, []);
});

test('newer matching observations win independently of completion order', () => {
    for (const reverse of [false, true]) {
        const value = fixture(); const newer = structuredClone(value.records[0]);
        newer.generatedAt = new Date(now + 1000).toISOString();
        newer.services[0].etd = '2026-09-16T17:09:00';
        value.records.push(newer); if (reverse) value.records.reverse();
        assert.equal(match(value).services[0].calls[0].departure, instant('17:09'));
    }
});

test('unknown future cancellation or delay cannot silently retain a reliable later schedule', () => {
    for (const [flag, field] of [['futureCancellation', 'unknownCancellationFromIndex'], ['futureDelay', 'unknownDelayFromIndex']]) {
        const value = fixture(); value.item[flag] = true;
        for (const location of value.item.subsequentLocations) {
            location.eta = location.sta; location.etd = location.std;
        }
        assert.equal(match(value).services[0][field], 0);
    }
});

test('London midnight dates are retained and repeated autumn wall times stay unknown', () => {
    const value = fixture();
    value.item.etd = '2026-09-17T00:05:00';
    assert.equal(match(value).services[0].calls[0].departure, Date.parse('2026-09-16T23:05:00Z'));
    value.item.etd = '2026-10-25T01:30:00';
    assert.equal(match(value).services[0].calls[0].departure, undefined);
    assert.equal(match(value).services[0].calls[0].departureUnknown, true);
    value.item.etd = '2026-03-29T01:30:00';
    assert.equal(match(value).services[0].calls[0].departureUnknown, true);
});

test('cancellation checks are honored while matching and indexing', () => {
    const value = fixture();
    assert.throws(() => matchStaffObservations(value.network, value.records, { ...value.options,
        check: () => { throw new Error('cancelled'); } }), /cancelled/);
});
