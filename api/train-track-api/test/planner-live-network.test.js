import test from 'node:test';
import assert from 'node:assert/strict';
import { applyLiveSnapshot, annotateLiveJourney } from '../lib/planner/live-network.js';
import { findJourneys, prepareNetwork, validateJourney } from '../lib/planner/router.js';

const zero = Date.parse('2026-09-08T10:00:00+01:00');
const time = minute => zero + minute * 60000;
const iso = minute => new Date(time(minute)).toISOString();
const train = (id, rows) => ({ id, operator: 'OP', mode: 'rail', calls: rows.map(([station, arrival, departure], sequence) => ({
    station, tiploc: station, sequence, arrival: arrival == null ? null : time(arrival),
    departure: departure == null ? null : time(departure), canAlight: arrival != null, canBoard: departure != null
})) });
function network(services) {
    return { services, rules: { tsi: [], links: [] }, stations: new Map(
        [...new Set(services.flatMap(service => service.calls.map(call => call.station)))].map(crs => [crs, { crs, name: crs, minimumChangeMinutes: 5 }])) };
}
const request = values => ({ origin: 'AAA', destination: 'DDD', time: iso(0), timeType: 'departAfter', maxChanges: 2, windowMinutes: 120, ...values });
const snapshot = services => ({ id: 'live-test', observedAt: zero, expiresAt: time(1), services });
const ids = result => result.journeys.map(journey => journey.legs.filter(leg => leg.kind === 'vehicle').map(leg => leg.scheduledServiceId || leg.serviceId));

test('departure platform and train length belong to the selected boarding stop in both live modes', () => {
    const original = network([train('train', [['AAA', null, 0], ['BBB', 10, 11], ['DDD', 20, null]])]);
    const update = snapshot([{ serviceId: 'train', calls: [
        { index: 0, departure: time(0), platform: ' 2 ', length: 8 },
        { index: 1, arrival: time(10), departure: time(11), platform: '', length: 0 },
        { index: 2, arrival: time(20), platform: '4', length: 4 }
    ] }]);
    for (const mode of ['apply', 'ignore']) {
        const live = applyLiveSnapshot(original, update, { mode });
        const first = annotateLiveJourney(findJourneys(request(), live).journeys[0], live).legs[0].live;
        assert.equal(first.platform, '2');
        assert.equal(first.length, 8);
        const middle = annotateLiveJourney(findJourneys(request({ origin: 'BBB' }), live).journeys[0], live).legs[0].live;
        assert.equal(middle.platform, undefined);
        assert.equal(middle.length, undefined);
    }
    assert.equal(original.services[0].calls[0].platform, undefined);
});

test('fresh immutable indexes include a delayed train scheduled before the query', () => {
    const original = network([train('late', [['AAA', null, -10], ['DDD', 10, null]]),
        train('unaffected', [['XXX', null, 0], ['YYY', 10, null]])]);
    const before = structuredClone(original);
    assert.equal(findJourneys(request(), original).journeys.length, 0);
    const live = applyLiveSnapshot(original, snapshot([{ serviceId: 'late', calls: [
        { index: 0, departure: time(5) }, { index: 1, arrival: time(25) }
    ] }]));
    const result = findJourneys(request(), live);
    assert.deepEqual(ids(result), [['late']]);
    assert.equal(result.journeys[0].departure, iso(5));
    assert.equal(result.journeys[0].legs[0].scheduledDeparture, iso(-10));
    assert.equal(result.journeys[0].legs[0].live.departureDelayMinutes, 15);
    assert.notEqual(prepareNetwork(original), prepareNetwork(live));
    assert.equal(prepareNetwork(original).connections, prepareNetwork(live).connections);
    assert.equal(prepareNetwork(original).departures.get('XXX'), prepareNetwork(live).departures.get('XXX'));
    assert.notEqual(prepareNetwork(original).departures.get('AAA'), prepareNetwork(live).departures.get('AAA'));
    assert.equal(prepareNetwork(original).departures.get('AAA')[0].time, time(-10));
    assert.equal(prepareNetwork(live).departures.get('AAA')[0].time, time(5));
    assert.notEqual(prepareNetwork(original).potentials, prepareNetwork(live).potentials);
    assert.deepEqual(original, before);
});

test('effective times both remove a missed connection and introduce a newly feasible one in both directions', () => {
    const original = network([
        train('in', [['AAA', null, 0], ['BBB', 10, null]]),
        train('out', [['BBB', null, 15], ['DDD', 30, null]])
    ]);
    const delayedIn = applyLiveSnapshot(original, snapshot([{ serviceId: 'in', calls: [
        { index: 0, departure: time(0) }, { index: 1, arrival: time(12) }
    ] }]));
    const delayedBoth = applyLiveSnapshot(original, snapshot([
        { serviceId: 'in', calls: [{ index: 0, departure: time(0) }, { index: 1, arrival: time(12) }] },
        { serviceId: 'out', calls: [{ index: 0, departure: time(17) }, { index: 1, arrival: time(32) }] }
    ]));
    for (const values of [{}, { timeType: 'arriveBy', time: iso(40) }]) {
        assert.equal(findJourneys(request(values), delayedIn).journeys.length, 0);
        const result = findJourneys(request(values), delayedBoth);
        assert.deepEqual(ids(result), [['in', 'out']]);
        assert.ok(validateJourney(result.journeys[0], delayedBoth, request(values)));
    }
});

test('a cancelled best train exposes alternatives before result ranking', () => {
    const original = network([
        train('best', [['AAA', null, 5], ['DDD', 20, null]]),
        train('alternative', [['AAA', null, 0], ['DDD', 30, null]])
    ]);
    assert.deepEqual(ids(findJourneys(request(), original)), [['best']]);
    const live = applyLiveSnapshot(original, snapshot([{ serviceId: 'best', cancelled: true }]));
    assert.deepEqual(ids(findJourneys(request(), live)), [['alternative']]);
});

test('skipped stops prevent boarding/alighting but preserve through travel and cancelled calling points', () => {
    const original = network([train('train', [['AAA', null, 0], ['BBB', 10, 11], ['DDD', 20, null]])]);
    const live = applyLiveSnapshot(original, snapshot([{ serviceId: 'train', calls: [
        { index: 0, departure: time(0) }, { index: 1, cancelled: true }, { index: 2, arrival: time(20) }
    ] }]));
    const journey = findJourneys(request(), live).journeys[0];
    assert.equal(journey.legs[0].live.cancelled, false);
    assert.equal(journey.legs[0].live.partCancelled, true);
    assert.equal(journey.legs[0].callingPoints[1].live.cancelled, true);
    assert.equal(findJourneys(request({ destination: 'BBB' }), live).journeys.length, 0);
    assert.equal(findJourneys(request({ origin: 'BBB' }), live).journeys.length, 0);
});

test('explicit non-operating sections cannot be crossed while unaffected portions remain usable', () => {
    const original = network([train('train', [['AAA', null, 0], ['BBB', 10, 11], ['CCC', 20, 21], ['DDD', 30, null]])]);
    const update = snapshot([{ serviceId: 'train', cancelledSegments: [{ fromIndex: 1, toIndex: 2 }], calls: [] }]);
    const live = applyLiveSnapshot(original, update);
    assert.equal(findJourneys(request(), live).journeys.length, 0);
    for (const values of [{ destination: 'BBB' }, { origin: 'CCC' }]) {
        const journey = findJourneys(request(values), live).journeys[0];
        assert.equal(journey.legs[0].scheduledServiceId, 'train');
        assert.equal(journey.legs[0].live.cancelled, false);
        assert.equal(journey.legs[0].live.partCancelled, true);
    }
    const annotated = annotateLiveJourney(findJourneys(request(), original).journeys[0], applyLiveSnapshot(original, update, { mode: 'ignore' }));
    assert.equal(annotated.departure, iso(0));
    assert.equal(annotated.legs[0].live.cancelled, true);
});

test('scheduled override keeps timetable timing and feasibility but carries live disruption warnings', () => {
    const original = network([train('train', [['AAA', null, 0], ['DDD', 20, null]])]);
    const ignored = applyLiveSnapshot(original, snapshot([{ serviceId: 'train', calls: [
        { index: 0, cancelled: true, departure: time(10) }, { index: 1, arrival: time(30) }
    ] }]), { mode: 'ignore' });
    const journey = findJourneys(request(), ignored).journeys[0];
    assert.equal(journey.departure, iso(0));
    assert.equal(journey.arrival, iso(20));
    assert.equal(journey.legs[0].live.departure, iso(10));
    assert.equal(journey.legs[0].live.cancelled, true);
    assert.ok(journey.legs[0].warnings.length);
});

test('an arrival-only forecast never invents a catchable departure after its scheduled time', () => {
    const original = network([train('train', [['AAA', null, 0], ['BBB', 10, 11], ['DDD', 30, null]])]);
    const live = applyLiveSnapshot(original, snapshot([{ serviceId: 'train', calls: [
        { index: 0, departure: time(0) }, { index: 1, arrival: time(15) }, { index: 2, arrival: time(35) }
    ] }]));
    assert.equal(findJourneys(request({ origin: 'BBB', time: iso(12) }), live).journeys.length, 0);
    assert.equal(findJourneys(request(), live).journeys.length, 1);
    assert.equal(live.services[0].calls[1].departure, null);
    assert.equal(live.services[0].calls[1].scheduledDeparture, time(11));
});

test('unknown delays and contradictory forecasts do not become feasible on-time connections', () => {
    const original = network([train('train', [['AAA', null, 0], ['DDD', 20, null]])]);
    for (const calls of [[{ index: 0, unknownDelay: true }], [{ index: 0, departure: time(30) }, { index: 1, arrival: time(20) }]]) {
        const live = applyLiveSnapshot(original, snapshot([{ serviceId: 'train', calls }]));
        assert.equal(findJourneys(request(), live).journeys.length, 0);
    }
});

test('live overlay preparation remains cancellable', () => {
    const original = network([train('train', [['AAA', null, 0], ['DDD', 20, null]])]);
    assert.throws(() => applyLiveSnapshot(original, snapshot([]), { check: () => { throw new Error('cancelled'); } }), /cancelled/);
});

test('generated live profiles match a separate direct/one-change enumeration in both time modes', () => {
    let seed = 9327;
    const random = maximum => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed % maximum; };
    const metrics = rows => [...new Set(rows.map(row => JSON.stringify([row.departure, row.arrival, row.changes])))].sort();
    for (let sample = 0; sample < 60; sample++) {
        const rows = [];
        for (let n = 0; n < 3; n++) for (const [from, to] of [['AAA', 'DDD'], ['AAA', 'BBB'], ['BBB', 'DDD']]) {
            const departure = random(70) - 10;
            const arrival = departure + 5 + random(20);
            const delay = random(25);
            rows.push({ id: `${from}-${to}-${n}`, from, to, departure, arrival, delay, cancelled: random(7) === 0 });
        }
        const original = network(rows.map(row => train(row.id, [[row.from, null, row.departure], [row.to, row.arrival, null]])));
        const live = applyLiveSnapshot(original, snapshot(rows.map(row => ({ serviceId: row.id, cancelled: row.cancelled,
            calls: [{ index: 0, departure: time(row.departure + row.delay) }, { index: 1, arrival: time(row.arrival + row.delay) }]
        }))));
        const candidates = [];
        const operating = rows.filter(row => !row.cancelled).map(row => ({ ...row,
            departure: row.departure + row.delay, arrival: row.arrival + row.delay }));
        for (const first of operating.filter(row => row.from === 'AAA')) {
            if (first.to === 'DDD') candidates.push({ departure: iso(first.departure), arrival: iso(first.arrival), changes: 0 });
            else for (const second of operating.filter(row => row.from === 'BBB')) {
                if (second.departure >= first.arrival + 5) candidates.push({ departure: iso(first.departure), arrival: iso(second.arrival), changes: 1 });
            }
        }
        for (const reverse of [false, true]) {
            const eligible = candidates.filter(row => reverse ? row.arrival <= iso(120) && row.arrival > iso(0)
                : row.departure >= iso(0) && row.departure < iso(120));
            const frontier = eligible.filter(candidate => !eligible.some(other => other !== candidate
                && other.departure >= candidate.departure && other.arrival <= candidate.arrival && other.changes <= candidate.changes
                && (other.departure > candidate.departure || other.arrival < candidate.arrival || other.changes < candidate.changes)));
            const result = findJourneys(request({ timeType: reverse ? 'arriveBy' : 'departAfter', time: iso(reverse ? 120 : 0), maxChanges: 1, limit: 100 }), live);
            assert.deepEqual(metrics(result.journeys), metrics(frontier), `sample ${sample}, reverse=${reverse}`);
        }
    }
});
