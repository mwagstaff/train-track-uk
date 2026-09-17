import test from 'node:test';
import assert from 'node:assert/strict';
import { findJourneys, validateJourney } from '../lib/planner/router.js';
import { createConnectionIndex, resolveConnection } from '../lib/planner/connections.js';
import { MAX_CHANGES, DEFAULT_WINDOW_MINUTES } from '../lib/planner/contract.js';

const minute = 60_000;
const zero = Date.parse('2026-09-08T07:00:00+01:00');
const time = minutes => zero + minutes * minute;
const iso = minutes => new Date(time(minutes)).toISOString();
function train(id, operator, stops, mode = 'rail') {
    return {
        id, variantId: `variant:${id}`, uid: id, originDate: '2026-09-08', operator, mode,
        sourceRef: { member: 'synthetic.MCA', line: Number(id.replace(/\D/g, '')) || 1 },
        calls: stops.map(([station, arrival, departure = arrival, permissions = {}], sequence) => ({
            station, tiploc: station, sequence, arrival: arrival == null ? null : time(arrival),
            departure: departure == null ? null : time(departure),
            canBoard: departure != null, canAlight: arrival != null, ...permissions
        }))
    };
}
function network(services, { tsi = [], links = [], allowances = {} } = {}) {
    const codes = new Set([...services.flatMap(service => service.calls.map(call => call.station)), ...links.flatMap(link => [link.origin, link.destination])]);
    return {
        stations: new Map([...codes].map(crs => [crs, { crs, name: `Station ${crs}`, minimumChangeMinutes: allowances[crs] ?? 5 }])),
        services, rules: { tsi, links }
    };
}
function search(net, values = {}) {
    return findJourneys({ origin: 'AAA', destination: 'DDD', time: iso(0), timeType: 'departAfter', maxChanges: 2, windowMinutes: 120, limit: 20, ...values }, net);
}
const serviceIds = journey => journey.legs.filter(leg => leg.kind === 'vehicle').map(leg => leg.serviceId);

test('direct profiles retain later departures and overtaking, with actual source calls', () => {
    const net = network([
        train('slow', 'OP', [['AAA', null, 1], ['DDD', 60, null]]),
        train('fast', 'OP', [['AAA', null, 10], ['BBB', 20, 21], ['DDD', 30, null]]),
        train('later', 'OP', [['AAA', null, 40], ['DDD', 55, null]])
    ]);
    const result = search(net);
    assert.deepEqual(result.journeys.map(serviceIds), [['fast'], ['later']]);
    assert.equal(result.journeys[0].changes, 0);
    assert.deepEqual(result.journeys[0].legs[0].callingPoints.map(call => call.station.crs), ['AAA', 'BBB', 'DDD']);
    assert.equal(result.journeys[0].legs[0].variantId, 'variant:fast');
});

test('completion bounds retain each departure and its direct versus faster connection tradeoff', () => {
    const net = network([
        train('direct', 'OP', [['AAA', null, 10], ['DDD', 60, null]]),
        train('later', 'OP', [['AAA', null, 20], ['DDD', 70, null]]),
        train('in', 'OP', [['AAA', null, 10], ['BBB', 20, null]]),
        train('out', 'OP', [['BBB', null, 25], ['DDD', 40, null]])
    ]);
    const query = { origin: 'AAA', destination: 'DDD', time: iso(0), timeType: 'departAfter', maxChanges: 2, windowMinutes: 120, limit: 20 };
    const result = findJourneys(query, net, { departureProfile: true });
    assert.deepEqual(result.journeys.map(serviceIds), [['in', 'out'], ['direct'], ['later']]);
    for (const journey of result.journeys) assert.ok(validateJourney(journey, net, query));
    // The equivalent reverse profile fixes arrival boundaries instead.
    const mirrored = network(net.services.map(service => ({ ...service, calls: [...service.calls].reverse().map(call => ({
        ...call, station: call.station === 'AAA' ? 'DDD' : call.station === 'DDD' ? 'AAA' : call.station,
        arrival: call.departure == null ? null : time(100) - (call.departure - zero),
        departure: call.arrival == null ? null : time(100) - (call.arrival - zero),
        canBoard: call.canAlight, canAlight: call.canBoard
    })) })));
    const reverseQuery = { ...query, time: iso(100), timeType: 'arriveBy' };
    const reverse = findJourneys(reverseQuery, mirrored, { departureProfile: true });
    assert.deepEqual(reverse.journeys.map(serviceIds), [['out', 'in'], ['direct'], ['later']]);
    for (const journey of reverse.journeys) assert.ok(validateJourney(journey, mirrored, reverseQuery));
});

test('label exhaustion is distinguishable from elapsed or operation budget exhaustion', () => {
    const net = network([train('direct', 'OP', [['AAA', null, 10], ['DDD', 20, null]])]);
    const query = { origin: 'AAA', destination: 'DDD', time: iso(0), timeType: 'departAfter' };
    assert.throws(() => findJourneys(query, net, { maxLabels: 1 }), error => error.code === 'SEARCH_TIMEOUT' && error.reason === 'labelLimit');
    assert.throws(() => findJourneys(query, net, { maxOperations: 1 }), error => error.code === 'SEARCH_TIMEOUT' && error.reason === undefined);
});

test('saved fallback finds connections even when an unavailable scheduled direct train would dominate them', () => {
    const net = network([
        train('direct', 'OP', [['AAA', null, 10], ['DDD', 30, null]]),
        train('in', 'OP', [['AAA', null, 5], ['BBB', 20, null]]),
        train('out', 'OP', [['BBB', null, 25], ['DDD', 45, null]])
    ]);
    const query = { origin: 'AAA', destination: 'DDD', time: iso(0), timeType: 'departAfter',
        maxChanges: 2, windowMinutes: 120, limit: 5 };
    assert.deepEqual(findJourneys(query, net).journeys.map(serviceIds), [['direct']]);
    const fallback = findJourneys(query, net, { excludeDirect: true });
    assert.deepEqual(fallback.journeys.map(serviceIds), [['in', 'out']]);
    assert.ok(validateJourney(fallback.journeys[0], net, query));
    assert.equal(findJourneys({ ...query, maxChanges: 0 }, net, { excludeDirect: true }).journeys.length, 0);
    assert.deepEqual(findJourneys({ ...query, time: iso(60), timeType: 'arriveBy' }, net,
        { excludeDirect: true }).journeys.map(serviceIds), [['in', 'out']]);
    assert.deepEqual(findJourneys(query, net).journeys.map(serviceIds), [['direct']], 'The opt-in must not change legacy searches');
});

test('connection exact threshold and extra buffer, including fractional seconds', () => {
    for (const offset of [-1 / 60, 0, 1 / 60]) {
        const net = network([
            train('in', 'OP', [['AAA', null, 0], ['BBB', 10, null]]),
            train('out', 'OP', [['BBB', null, 15 + offset], ['DDD', 25, null]])
        ]);
        assert.equal(search(net).journeys.length, offset < 0 ? 0 : 1);
        assert.equal(search(net, { extraConnectionMinutes: 1 }).journeys.length, 0);
    }
});

test('operator context survives dominance, including ordered TSI in reverse', () => {
    const net = network([
        train('earlier', 'XX', [['AAA', null, 0], ['BBB', 10, null]]),
        train('later', 'YY', [['AAA', null, 1], ['BBB', 12, null]]),
        train('out', 'ZZ', [['BBB', null, 15], ['DDD', 30, null]])
    ], { tsi: [{ id: 'TSI:1', station: 'BBB', arrivingOperator: 'YY', departingOperator: 'ZZ', minutes: 3 }] });
    for (const values of [{}, { timeType: 'arriveBy', time: iso(30) }]) {
        assert.deepEqual(search(net, values).journeys.map(serviceIds), [['later', 'out']]);
        assert.equal(search(net, values).journeys[0].legs[1].ruleId, 'TSI:1');
    }
});

test('two changes, exact midnight, repeated station calls, and passenger restrictions', () => {
    const net = network([
        train('1', 'OP', [['AAA', null, 1000], ['BBB', 1010, 1010, { canAlight: false }], ['AAA', 1015, 1016], ['BBB', 1020, null]]),
        train('2', 'OP', [['BBB', null, 1025], ['CCC', 1040, null]]),
        train('3', 'OP', [['CCC', null, 1045], ['DDD', 1060, null]])
    ]);
    const result = search(net, { time: iso(999) });
    assert.equal(result.journeys.length, 1);
    assert.equal(result.journeys[0].changes, 2);
    assert.equal(result.journeys[0].legs[0].boardIndex, 2);
    assert.equal(result.journeys[0].legs[0].alightIndex, 3);
    assert.equal(search(net, { time: iso(999), maxChanges: 1 }).journeys.length, 0);
    assert.deepEqual(search(net, { timeType: 'arriveBy', time: iso(1060) }).journeys.map(serviceIds), [['1', '2', '3']]);
});

test('missing interchange allowance excludes connection, but does not penalise initial boarding', () => {
    const net = network([
        train('1', 'OP', [['AAA', null, 0], ['BBB', 10, null]]),
        train('2', 'OP', [['BBB', null, 20], ['DDD', 30, null]])
    ]);
    net.stations.get('BBB').minimumChangeMinutes = null;
    assert.equal(search(net).journeys.length, 0);
    assert.equal(search(net, { destination: 'BBB' }).journeys.length, 1);
});

const link = (values = {}) => ({ id: 'ALF:1', origin: 'BBB', destination: 'CCC', minutes: 1, mode: 'walk', startTime: '0000', endTime: '2359', priority: 1, ...values });

test('directional fixed links add both endpoint allowances exactly once', () => {
    const net = network([
        train('1', 'OP', [['AAA', null, 0], ['BBB', 10, null]]),
        train('2', 'OP', [['CCC', null, 30], ['DDD', 45, null]])
    ], { links: [link()], allowances: { BBB: 15, CCC: 4 } });
    for (const values of [{}, { timeType: 'arriveBy', time: iso(45) }]) {
        const result = search(net, values);
        assert.equal(result.journeys.length, 1);
        assert.equal(result.journeys[0].legs[1].minutes, 20);
        assert.equal(result.journeys[0].changes, 1);
    }
    const connection = createConnectionIndex(net);
    assert.equal(resolveConnection(connection, { from: 'CCC', to: 'BBB', arrival: time(0) }), null);
    assert.equal(search(net, { extraConnectionMinutes: 1 }).journeys.length, 0);
});

test('time-dependent link opening, full traversal window, expiry and priority', () => {
    const net = network([
        train('1', 'OP', [['AAA', null, 0], ['BBB', 10, null]]),
        train('2', 'OP', [['CCC', null, 40], ['DDD', 50, null]])
    ], { links: [link({ minutes: 10, startTime: '0725', endTime: '0735', days: '0100000', startDate: '2026-09-08', endDate: '2026-09-08' })] });
    const forward = search(net).journeys[0];
    assert.equal(forward.legs[1].breakdown.waitingMinutes, 10);
    assert.equal(forward.legs[1].movementDeparture, iso(25));
    assert.equal(search(net, { timeType: 'arriveBy', time: iso(50) }).journeys.length, 1);
    const priority = network(net.services, { links: [link(), link({ id: 'ALF:2', minutes: 30, priority: 2 })] });
    assert.equal(search(priority).journeys.length, 0);
    const expired = network(net.services, { links: [link({ endDate: '2026-09-07' })] });
    assert.equal(search(expired).journeys.length, 0);
    const shortWindow = network(net.services, { links: [link({ minutes: 10, startTime: '0726', endTime: '0735' })] });
    assert.equal(search(shortWindow).journeys.length, 0);
});

test('generic non-walking link counts as a boarding and requires its permitted mode', () => {
    const net = network([
        train('1', 'OP', [['AAA', null, 0], ['BBB', 10, null]]),
        train('2', 'OP', [['CCC', null, 30], ['DDD', 45, null]])
    ], { links: [link({ mode: 'tubeTransfer', minutes: 5 })] });
    assert.equal(search(net).journeys[0].changes, 2);
    assert.equal(search(net, { maxChanges: 1 }).journeys.length, 0);
    assert.equal(search(net, { allowedModes: ['rail', 'walk'] }).journeys.length, 0);
});

test('endpoint links work in both search directions, with actual departure/arrival bounds', () => {
    const net = network([train('1', 'OP', [['BBB', null, 20], ['CCC', 40, null]])], {
        links: [link({ id: 'start', origin: 'AAA', destination: 'BBB', minutes: 5 }), link({ id: 'end', origin: 'CCC', destination: 'DDD', minutes: 5 })]
    });
    for (const values of [{}, { timeType: 'arriveBy', time: iso(60) }]) {
        const result = search(net, values);
        assert.equal(result.journeys.length, 1);
        assert.equal(result.journeys[0].departure, iso(5));
        assert.equal(result.journeys[0].arrival, iso(55));
        assert.equal(result.journeys[0].changes, 0);
    }
});

test('reverse validation retains a later applicable transfer instead of replacing it with an earlier faster link', () => {
    const net = network([
        train('1', 'OP', [['AAA', null, 0], ['BBB', 10, null]]),
        train('2', 'OP', [['CCC', null, 100], ['DDD', 110, null]])
    ], { links: [link({ minutes: 10, endTime: '0730' }), link({ id: 'late', minutes: 60, startTime: '0730', endTime: '0900', priority: 2 })] });
    assert.equal(search(net).journeys[0].legs[1].ruleId, 'ALF:1');
    assert.equal(search(net, { timeType: 'arriveBy', time: iso(110) }).journeys[0].legs[1].ruleId, 'late');
});

test('equal-priority conflicts are excluded, and exact duplicates cannot create shortcuts', () => {
    const services = [train('1', 'OP', [['AAA', null, 0], ['BBB', 10, null]]), train('2', 'OP', [['CCC', null, 30], ['DDD', 40, null]])];
    const conflict = search(network(services, { links: [link(), link({ id: 'other', minutes: 2 })] }));
    assert.equal(conflict.journeys.length, 0);
    assert.ok(conflict.warnings.some(warning => warning.includes('conflicting')));
    assert.equal(search(network(services, { links: [link(), link({ id: 'duplicate' })] })).journeys.length, 1);
});

test('fall clock rollback preserves separate link windows and spring missing hour is not invented', () => {
    const net = network([], { links: [link({ startTime: '0115', endTime: '0130', minutes: 5, days: '0000001' })], allowances: { BBB: 0, CCC: 0 } });
    const index = createConnectionIndex(net);
    const connect = arrival => resolveConnection(index, { from: 'BBB', to: 'CCC', arrival: Date.parse(arrival) });
    assert.equal(connect('2026-10-25T00:20:00Z').movementStart, Date.parse('2026-10-25T00:20:00Z'));
    assert.equal(connect('2026-10-25T00:50:00Z').movementStart, Date.parse('2026-10-25T01:15:00Z'));
    const impossible = createConnectionIndex(network([], { links: [link({ startTime: '0115', endTime: '0130', minutes: 20, days: '0000001' })], allowances: { BBB: 0, CCC: 0 } }));
    assert.equal(resolveConnection(impossible, { from: 'BBB', to: 'CCC', arrival: Date.parse('2026-10-25T00:00:00Z') }), null);
    const spring = createConnectionIndex(network([], { links: [link({ startTime: '0100', endTime: '0200', minutes: 5, days: '0000001' })], allowances: { BBB: 0, CCC: 0 } }));
    assert.equal(resolveConnection(spring, { from: 'BBB', to: 'CCC', arrival: Date.parse('2026-03-29T00:00:00Z') }), null);
});

test('ranked pagination preserves earlier slow direct tradeoffs and equal-time alternatives', () => {
    const net = network([
        train('direct', 'OP', [['AAA', null, 0], ['DDD', 70, null]]),
        train('connection1', 'OP', [['AAA', null, 10], ['BBB', 20, null]]),
        train('connection2', 'OP', [['BBB', null, 25], ['DDD', 30, null]])
    ]);
    const request = { origin: 'AAA', destination: 'DDD', time: iso(0), limit: 1 };
    const first = findJourneys(request, net);
    assert.deepEqual(serviceIds(first.journeys[0]), ['connection1', 'connection2']);
    const second = findJourneys(request, net, { offset: first.pagination.nextOffset });
    assert.deepEqual(serviceIds(second.journeys[0]), ['direct']);
});

test('independent reconstruction validation rejects altered times, calls and rules', () => {
    const net = network([
        train('1', 'OP', [['AAA', null, 0], ['BBB', 10, null]]),
        train('2', 'OP', [['BBB', null, 15], ['DDD', 25, null]])
    ]);
    const request = { origin: 'AAA', destination: 'DDD', time: iso(0), timeType: 'departAfter' };
    const original = search(net).journeys[0];
    assert.equal(validateJourney(original, net, request), true);
    for (const mutate of [j => j.legs[0].arrival = iso(9), j => j.legs[0].alightIndex = 0, j => j.legs[1].ruleId = 'invented']) {
        const changed = structuredClone(original);
        mutate(changed);
        assert.equal(validateJourney(changed, net, request), false);
    }
});

test('request bounds, deterministic window paging, duration and cancellation', () => {
    const net = network([0, 10, 20, 130].map((departure, i) => train(`train${i}`, 'OP', [['AAA', null, departure], ['DDD', departure + 5, null]])));
    const result = search(net, { limit: 2 });
    assert.equal(result.journeys.length, 2);
    assert.equal(result.pagination.nextOffset, 2);
    assert.equal(result.pagination.laterTime, iso(120));
    const nextPage = findJourneys({ origin: 'AAA', destination: 'DDD', time: iso(0), limit: 2, windowMinutes: 120 }, net, { offset: 2 });
    assert.deepEqual(nextPage.journeys.map(serviceIds), [['train2']]);
    assert.equal(nextPage.pagination.nextOffset, null);
    assert.deepEqual(search(net, { time: result.pagination.laterTime }).journeys.map(serviceIds), [['train3']]);
    assert.equal(search(net, { time: iso(120), windowMinutes: 10 }).journeys.length, 0);
    assert.throws(() => findJourneys({ origin: 'AAA', destination: 'DDD', time: iso(0) }, net, { signal: { aborted: true } }), { code: 'SEARCH_CANCELLED' });
    assert.throws(() => findJourneys({ origin: 'AAA', destination: 'DDD', time: iso(0) }, net, { maxOperations: 1 }), { code: 'SEARCH_TIMEOUT' });
    const long = network([train('long', 'OP', [['AAA', null, 0], ['DDD', 1441, null]])]);
    assert.equal(search(long).journeys.length, 0);
    assert.equal(search(net, { destination: 'AAA' }).alreadyAtDestination, true);
});

test('five changes and the wider default departure window work in both directions', () => {
    const codes = ['AAA', 'BBB', 'CCC', 'EEE', 'FFF', 'GGG', 'DDD'];
    const net = network(codes.slice(0, -1).map((from, i) => train(`stage${i}`, 'OP',
        [[from, null, 300 + i * 20], [codes[i + 1], 310 + i * 20, null]])));
    for (const timeType of ['departAfter', 'arriveBy']) {
        const request = { origin: 'AAA', destination: 'DDD', timeType, time: iso(timeType === 'arriveBy' ? 410 : 0) };
        const result = findJourneys(request, net);
        assert.equal(result.journeys.length, 1);
        assert.equal(result.journeys[0].changes, 5);
        assert.equal(result.policy.maxChanges, MAX_CHANGES);
        assert.equal(result.policy.windowMinutes, DEFAULT_WINDOW_MINUTES);
        assert.equal(findJourneys({ ...request, maxChanges: 4 }, net).journeys.length, 0);
        assert.throws(() => findJourneys({ ...request, maxChanges: MAX_CHANGES + 1 }, net), { code: 'INVALID_REQUEST' });
    }
    assert.equal(search(net).journeys.length, 0);
});

test('many departure profiles skip onward trains which cannot complete within the boarding budget', () => {
    const services = Array.from({ length: 150 }, (_, i) => train(`feeder${i}`, 'OP',
        [['AAA', null, i], ['BBB', i + 5, null]]));
    for (let i = 0; i < 1200; i++) services.push(train(`deadEnd${i}`, 'OP',
        [['BBB', null, 400 + i / 10], ['CCC', 410 + i / 10, null]]));
    services.push(train('onward', 'OP', [['BBB', null, 900], ['DDD', 910, null]]));
    for (const reverse of [false, true]) {
        const rows = reverse ? services.map(service => ({ ...service, calls: service.calls.toReversed().map(call => ({
            ...call, arrival: call.departure == null ? null : time(1000) - (call.departure - zero),
            departure: call.arrival == null ? null : time(1000) - (call.arrival - zero),
            canBoard: call.canAlight, canAlight: call.canBoard
        })) })) : services;
        const request = { origin: reverse ? 'DDD' : 'AAA', destination: reverse ? 'AAA' : 'DDD',
            timeType: reverse ? 'arriveBy' : 'departAfter', time: iso(reverse ? 1000 : 0),
            maxChanges: 1, windowMinutes: 360 };
        const result = findJourneys(request, network(rows), { maxOperations: 50_000 });
        assert.equal(result.journeys.length, 1);
        assert.deepEqual(serviceIds(result.journeys[0]), reverse ? ['onward', 'feeder149'] : ['feeder149', 'onward']);
    }
});

test('onboard dominance preserves earlier alighting opportunities and fewer-change tradeoffs', () => {
    const services = [
        train('early', 'XX', [['AAA', null, 0], ['BBB', 10, null]]),
        train('later', 'YY', [['AAA', null, 8], ['CCC', 35, null]]),
        train('shared', 'ZZ', [['BBB', null, 20], ['CCC', 29, 40], ['DDD', 50, null]]),
        train('shortcut', 'ZZ', [['CCC', null, 34], ['DDD', 40, null]]),
        train('direct', 'XX', [['AAA', null, 1], ['DDD', 60, null]])
    ];
    for (const reverse of [false, true]) {
        const rows = reverse ? services.map(service => ({ ...service, calls: service.calls.toReversed().map(call => ({
            ...call, arrival: call.departure == null ? null : time(1000) - (call.departure - zero),
            departure: call.arrival == null ? null : time(1000) - (call.arrival - zero),
            canBoard: call.canAlight, canAlight: call.canBoard
        })) })) : services;
        const request = { origin: reverse ? 'DDD' : 'AAA', destination: reverse ? 'AAA' : 'DDD',
            timeType: reverse ? 'arriveBy' : 'departAfter', time: iso(reverse ? 1000 : 0), maxChanges: 2 };
        const net = network(rows);
        const actual = findJourneys(request, net).journeys.map(j => `${Date.parse(j.departure)}|${Date.parse(j.arrival)}|${j.changes}`);
        assert.deepEqual([...new Set(actual)].sort(), exhaustive(net, request));
        assert.equal(actual.length, 3);
    }
});

test('many distinct completion horizons preserve the full frontier when cached bounds are reused', () => {
    const services = [];
    for (let i = 0; i < 20; i++) {
        const departure = i * 15;
        services.push(train(`first${i}`, 'XX', [['AAA', null, departure], ['BBB', departure + 10, null]]));
        services.push(train(`middle${i}`, 'YY', [['BBB', null, departure + 20], ['CCC', departure + 30, null]]));
        services.push(train(`last${i}`, 'ZZ', [['CCC', null, departure + 40], ['DDD', departure + 50, null]]));
    }
    const net = network(services);
    for (const timeType of ['departAfter', 'arriveBy']) {
        const request = { origin: 'AAA', destination: 'DDD', timeType,
            time: iso(timeType === 'arriveBy' ? 340 : 0), windowMinutes: 360, maxChanges: 5, limit: 100 };
        const result = findJourneys(request, net);
        const actual = result.journeys.map(j => `${Date.parse(j.departure)}|${Date.parse(j.arrival)}|${j.changes}`);
        assert.deepEqual([...new Set(actual)].sort(), exhaustive(net, request));
        assert.equal(result.pagination.total, 20);
        const paged = findJourneys({ ...request, limit: 5 }, net, { offset: 10 });
        assert.deepEqual(paged.journeys.map(serviceIds), result.journeys.slice(10, 15).map(serviceIds));
    }
});

// Independent tiny-network oracle: enumerate every legal boarding/alighting
// combination directly from fixture arrays, without indexes, labels or router helpers.
function exhaustive(net, request) {
    const solutions = [];
    const start = Date.parse(request.time);
    const reverse = request.timeType === 'arriveBy';
    function visit(at, ready, operator, first, rides, used) {
        if (at === request.destination && rides.length) {
            const window = (request.windowMinutes ?? DEFAULT_WINDOW_MINUTES) * minute;
            if (reverse ? ready <= start && ready > start - window : first >= start && first < start + window) {
                solutions.push({ departure: first, arrival: ready, changes: rides.length - 1 });
            }
            return;
        }
        if (rides.length >= (request.maxChanges ?? MAX_CHANGES) + 1) return;
        for (const service of net.services) {
            if (used.has(service.id)) continue;
            for (let boardIndex = 0; boardIndex < service.calls.length - 1; boardIndex++) {
                const board = service.calls[boardIndex];
                if (board.station !== at || !board.canBoard) continue;
                const override = net.rules.tsi.find(rule => rule.station === at && rule.arrivingOperator === operator && rule.departingOperator === service.operator);
                const allowance = rides.length ? (override?.minutes ?? net.stations.get(at).minimumChangeMinutes) : 0;
                if (board.departure < ready + allowance * minute) continue;
                for (let endIndex = boardIndex + 1; endIndex < service.calls.length; endIndex++) {
                    const end = service.calls[endIndex];
                    if (!end.canAlight || end.arrival < board.departure) continue;
                    visit(end.station, end.arrival, service.operator, first ?? board.departure, [...rides, service.id], new Set([...used, service.id]));
                }
            }
        }
    }
    visit(request.origin, reverse ? -Infinity : start, null, null, [], new Set());
    const pareto = solutions.filter(a => !solutions.some(b => b.departure >= a.departure && b.arrival <= a.arrival && b.changes <= a.changes && (b.departure > a.departure || b.arrival < a.arrival || b.changes < a.changes)));
    return [...new Set(pareto.map(value => `${value.departure}|${value.arrival}|${value.changes}`))].sort();
}

test('forward and genuine reverse profile results agree with independently exhaustive generated networks', () => {
    let seed = 9274;
    const random = n => { seed = (seed * 1664525 + 1013904223) >>> 0; return seed % n; };
    const codes = ['AAA', 'BBB', 'CCC', 'DDD'];
    for (let fixture = 0; fixture < 60; fixture++) {
        const services = [];
        for (let i = 0; i < 14; i++) {
            const from = random(3);
            const to = from + 1 + random(3 - from);
            const departure = random(70);
            services.push(train(`${i}`, random(2) ? 'XX' : 'YY', [[codes[from], null, departure], [codes[to], departure + 5 + random(20), null]]));
        }
        const net = network(services, { tsi: [{ id: 'override', station: 'BBB', arrivingOperator: 'XX', departingOperator: 'YY', minutes: 1 }] });
        for (const timeType of ['departAfter', 'arriveBy']) {
            const request = { origin: 'AAA', destination: 'DDD', time: iso(timeType === 'arriveBy' ? 90 : 0), timeType, limit: 100 };
            const actual = findJourneys(request, net).journeys.map(j => `${Date.parse(j.departure)}|${Date.parse(j.arrival)}|${j.changes}`);
            assert.deepEqual([...new Set(actual)].sort(), exhaustive(net, request), `fixture ${fixture}, ${timeType}`);
        }
    }
});

test('cyclic and repeated-location generated networks retain the exhaustive Pareto frontier', () => {
    let seed = 17358;
    const random = n => { seed = (Math.imul(seed, 1103515245) + 12345) >>> 0; return (seed >>> 8) % n; };
    const codes = ['AAA', 'BBB', 'CCC', 'DDD'];
    for (let fixture = 0; fixture < 80; fixture++) {
        const services = [];
        for (let i = 0; i < 12; i++) {
            const departure = random(60);
            const stops = [[codes[random(4)], null, departure]];
            for (let stop = 1; stop <= 3; stop++) stops.push([codes[random(4)], departure + stop * 8, stop === 3 ? null : departure + stop * 8 + 1]);
            services.push(train(`${i}`, random(2) ? 'XX' : 'YY', stops));
        }
        const net = network(services, { tsi: [{ id: 'override', station: 'CCC', arrivingOperator: 'XX', departingOperator: 'YY', minutes: 1 }] });
        for (const crs of codes) if (!net.stations.has(crs)) net.stations.set(crs, { crs, name: crs, minimumChangeMinutes: 5 });
        for (const timeType of ['departAfter', 'arriveBy']) {
            const request = { origin: 'AAA', destination: 'DDD', time: iso(timeType === 'arriveBy' ? 90 : 0), timeType, limit: 100 };
            const actual = findJourneys(request, net).journeys.map(j => `${Date.parse(j.departure)}|${Date.parse(j.arrival)}|${j.changes}`);
            assert.deepEqual([...new Set(actual)].sort(), exhaustive(net, request), `cyclic fixture ${fixture}, ${timeType}`);
        }
    }
});

test('deep profiles retain the exhaustive frontier with later departures and fewer-change detours', () => {
    let seed = 77431;
    const random = n => { seed = (Math.imul(seed, 1103515245) + 12345) >>> 0; return (seed >>> 8) % n; };
    const codes = ['AAA', 'BBB', 'CCC', 'EEE', 'FFF', 'GGG', 'DDD'];
    for (let fixture = 0; fixture < 60; fixture++) {
        const services = codes.slice(0, -1).map((from, i) => train(`chain${i}`, i % 2 ? 'XX' : 'YY',
            [[from, null, i * 20], [codes[i + 1], i * 20 + 10, null]]));
        for (let i = 0; i < 10; i++) {
            const from = random(7);
            const to = random(7);
            const departure = from * 15 + random(60);
            services.push(train(`other${i}`, random(2) ? 'XX' : 'YY',
                [[codes[from], null, departure], [codes[to], departure + 1 + random(35), null]]));
        }
        const net = network(services, { tsi: [{ id: 'override', station: 'CCC', arrivingOperator: 'XX', departingOperator: 'YY', minutes: 1 }] });
        for (const timeType of ['departAfter', 'arriveBy']) {
            const request = { origin: 'AAA', destination: 'DDD', timeType,
                time: iso(timeType === 'arriveBy' ? 180 : 0), maxChanges: 5, windowMinutes: 360, limit: 100 };
            const actual = findJourneys(request, net).journeys.map(j => `${Date.parse(j.departure)}|${Date.parse(j.arrival)}|${j.changes}`);
            assert.deepEqual([...new Set(actual)].sort(), exhaustive(net, request), `deep fixture ${fixture}, ${timeType}`);
        }
    }
});
