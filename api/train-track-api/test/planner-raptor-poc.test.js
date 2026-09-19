import test from 'node:test';
import assert from 'node:assert/strict';
import { compileRaptorNetwork, findRaptorJourneys } from '../lib/planner/raptor-poc.js';
import { findJourneys, validateJourney } from '../lib/planner/router.js';
import { applyLiveSnapshot } from '../lib/planner/live-network.js';

const minute = 60_000;
const zero = Date.parse('2026-09-08T07:00:00+01:00');
const time = value => zero + value * minute;
const iso = value => new Date(time(value)).toISOString();
function train(id, rows, operator = 'OP', mode = 'rail') {
    return { id, uid: id, variantId: `variant:${id}`, originDate: '2026-09-08', operator, mode,
        sourceRef: { member: 'synthetic.MCA', line: 1 },
        calls: rows.map(([station, arrival, departure, permissions = {}], sequence) => ({
            station, tiploc: station, sequence,
            arrival: arrival == null ? null : time(arrival), departure: departure == null ? null : time(departure),
            canAlight: arrival != null, canBoard: departure != null, ...permissions
        })) };
}
function network(services, { links = [], tsi = [], allowances = {} } = {}) {
    const codes = new Set(['AAA', 'BBB', 'CCC', 'DDD',
        ...services.flatMap(service => service.calls.map(call => call.station)),
        ...links.flatMap(link => [link.origin, link.destination])]);
    return { services, rules: { links, tsi }, stations: new Map([...codes].map(crs => [crs,
        { crs, name: `Station ${crs}`, minimumChangeMinutes: Object.hasOwn(allowances, crs) ? allowances[crs] : 5 }])) };
}
const query = values => ({ origin: 'AAA', destination: 'DDD', time: iso(0), timeType: 'departAfter',
    maxChanges: 2, windowMinutes: 120, limit: 100, ...values });
const link = values => ({ id: 'ALF:1', origin: 'BBB', destination: 'CCC', mode: 'walk', minutes: 5,
    startTime: '0000', endTime: '2359', days: '1111111', priority: 1,
    sourceRef: { member: 'ALF', line: 1 }, ...values });
const vehicleIds = journey => journey.legs.filter(leg => leg.kind === 'vehicle').map(leg => leg.serviceId);
const criterion = row => `${Date.parse(row.departure)}|${Date.parse(row.arrival)}|${row.changes}`;
function frontier(result, departureProfile = false) {
    const rows = result.journeys;
    return [...new Set(rows.filter(a => !rows.some(b =>
        (departureProfile ? b.departure === a.departure : b.departure >= a.departure)
        && b.arrival <= a.arrival && b.changes <= a.changes
        && ((!departureProfile && b.departure > a.departure) || b.arrival < a.arrival || b.changes < a.changes)))
        .map(criterion))].sort();
}
function compare(net, request = query(), options = {}) {
    const before = structuredClone(net);
    const actual = findRaptorJourneys(request, compileRaptorNetwork(net), options);
    const expected = findJourneys(request, net, options);
    assert.deepEqual(frontier(actual, options.departureProfile), frontier(expected, options.departureProfile));
    for (const journey of actual.journeys) {
        assert.ok(validateJourney(journey, net, request),
            `Independent reconstruction validation: ${JSON.stringify(vehicleIds(journey))}`);
        const departure = Date.parse(journey.departure), boundary = Date.parse(request.time);
        assert.ok(departure >= boundary && departure < boundary + request.windowMinutes * minute,
            'The actual journey departure must be inside the requested half-open window');
        assert.ok(journey.durationMinutes <= (options.maxDurationMinutes ?? 1440));
    }
    assert.deepEqual(net, before, 'Compiling and querying the POC must not mutate the source timetable');
    assert.equal(actual.searchTruncated, false);
    return actual;
}

// Independent oracle for small rail/bus fixtures. Enumerate every effective
// call occurrence and legal ride, without either implementation's indexes,
// route patterns, labels, lower bounds or connection-resolution helpers.
function exhaustive(net, request, { departureProfile = false, maxDurationMinutes = 1440 } = {}) {
    const solutions = [], boundary = Date.parse(request.time);
    const modes = new Set(request.allowedModes ?? ['rail', 'replacementBus', 'walk', 'tubeTransfer']);
    const maxBoardings = request.maxChanges + 1;
    function visit(at, ready, first, previousOperator, rides, used) {
        if (at === request.destination && rides) {
            if (first >= boundary && first < boundary + request.windowMinutes * minute
                && ready - first <= maxDurationMinutes * minute) {
                solutions.push({ departure: new Date(first).toISOString(), arrival: new Date(ready).toISOString(), changes: rides - 1 });
            }
            return;
        }
        if (rides === maxBoardings) return;
        for (const service of net.services) {
            if (!modes.has(service.mode) || used.has(service.id)) continue;
            for (let boardIndex = 0; boardIndex < service.calls.length - 1; boardIndex++) {
                const board = service.calls[boardIndex];
                if (board.station !== at || !board.canBoard || !Number.isFinite(board.departure)) continue;
                const rules = net.rules.tsi.filter(rule => rule.station === at
                    && rule.arrivingOperator === previousOperator && rule.departingOperator === service.operator);
                if (rides && new Set(rules.map(rule => rule.minutes)).size > 1) continue;
                const allowance = rides ? (rules[0]?.minutes ?? net.stations.get(at).minimumChangeMinutes) : 0;
                if (!Number.isFinite(allowance) || allowance < 0
                    || board.departure < ready + (allowance + (rides ? request.extraConnectionMinutes ?? 0 : 0)) * minute) continue;
                for (let alightIndex = boardIndex + 1; alightIndex < service.calls.length; alightIndex++) {
                    const alight = service.calls[alightIndex];
                    if (!alight.canAlight || !Number.isFinite(alight.arrival) || alight.arrival < board.departure) continue;
                    visit(alight.station, alight.arrival, first ?? board.departure, service.operator,
                        rides + 1, new Set([...used, service.id]));
                }
            }
        }
    }
    visit(request.origin, boundary, null, null, 0, new Set());
    return frontier({ journeys: solutions }, departureProfile);
}

function compareOracleOnly(net, request) {
    const before = structuredClone(net), index = compileRaptorNetwork(net);
    const result = findRaptorJourneys(request, index);
    assert.deepEqual(frontier(result), exhaustive(net, request));
    for (const journey of result.journeys) assert.ok(validateJourney(journey, net, request));
    assert.deepEqual(net, before);
    return { index, result };
}

test('RAPTOR POC retains all origin departure profiles and same-pattern overtaking', () => {
    const net = network([
        train('slow', [['AAA', null, 1], ['BBB', 20, 21], ['DDD', 60, null]]),
        train('fast', [['AAA', null, 10], ['BBB', 15, 16], ['DDD', 30, null]]),
        train('later', [['AAA', null, 40], ['BBB', 45, 46], ['DDD', 55, null]])
    ]);
    const index = compileRaptorNetwork(net);
    assert.equal(index.stats.stoppingPatterns, 1);
    assert.equal(index.stats.overtakingSplits, 1, 'Overtaking creates another FIFO route instead of dropping a trip');
    const result = compare(net);
    assert.deepEqual(frontier(result), [criterion({ departure: iso(10), arrival: iso(30), changes: 0 }),
        criterion({ departure: iso(40), arrival: iso(55), changes: 0 })].sort());
    assert.ok(result.journeys.every(journey => journey.legs[0].callingPoints.length === 3));
});

test('RAPTOR POC departure-profile mode retains a dominated departure and its fewer-change tradeoff', () => {
    const net = network([
        train('direct', [['AAA', null, 10], ['DDD', 60, null]]),
        train('later', [['AAA', null, 20], ['DDD', 70, null]]),
        train('in', [['AAA', null, 10], ['BBB', 20, null]]),
        train('out', [['BBB', null, 25], ['DDD', 40, null]]),
        train('latestFast', [['AAA', null, 30], ['DDD', 50, null]])
    ]);
    const request = query(), options = { departureProfile: true };
    assert.deepEqual(frontier(compare(net, request, options), true), exhaustive(net, request, options));
});

test('RAPTOR POC keeps exact repeated-station boarding events and disallowed calls', () => {
    const loop = train('loop', [['AAA', null, 0], ['BBB', 10, 11], ['AAA', 20, 21], ['DDD', 30, null]]);
    const result = compare(network([loop]));
    assert.equal(result.journeys[0].legs[0].boardIndex, 2);
    loop.calls[2].canBoard = false;
    assert.equal(compare(network([loop])).journeys[0].legs[0].boardIndex, 0);
    loop.calls[3].canAlight = false;
    assert.equal(compare(network([loop])).journeys.length, 0);
});

test('RAPTOR POC equal-time alternatives provide at least one valid representative', () => {
    const net = network(['first', 'second'].map(id => train(id, [['AAA', null, 10], ['DDD', 30, null]])));
    assert.equal(frontier(compare(net)).length, 1);
    const permission = train('no-board', [['AAA', null, 20], ['DDD', 25, null]]);
    permission.calls[0].canBoard = false;
    assert.equal(frontier(compare(network([...net.services, permission]))).length, 1);
});

test('RAPTOR POC frontier replacements preserve the first equal itinerary and exact pages', () => {
    const net = network([
        train('old', [['AAA', null, 0], ['DDD', 50, null]], 'OLD'),
        train('z-selected', [['AAA', null, 10], ['DDD', 40, null]], 'FIRST'),
        train('a-equal', [['AAA', null, 10], ['DDD', 40, null]], 'SECOND'),
        train('later', [['AAA', null, 20], ['DDD', 55, null]], 'LATER'),
        train('feed', [['AAA', null, 10], ['BBB', 20, null]]),
        train('fast', [['BBB', null, 25], ['DDD', 35, null]])
    ]);
    const index = compileRaptorNetwork(net);
    for (const departureProfile of [false, true]) {
        const options = { departureProfile };
        const result = findRaptorJourneys(query(), index, options);
        assert.deepEqual(result.journeys.map(vehicleIds), departureProfile
            ? [['feed', 'fast'], ['z-selected'], ['old'], ['later']]
            : [['feed', 'fast'], ['z-selected'], ['later']]);
        assert.deepEqual(frontier(result, departureProfile), exhaustive(net, query(), options));
        const pages = [];
        for (let offset = 0; offset < result.pagination.total; offset++) {
            const page = findRaptorJourneys(query({ limit: 1 }), index, { ...options, offset });
            pages.push(...page.journeys);
            assert.equal(page.pagination.total, result.pagination.total);
            assert.equal(page.pagination.nextOffset, offset + 1 < result.pagination.total ? offset + 1 : null);
        }
        assert.deepEqual(pages, result.journeys);
        for (const journey of result.journeys) assert.ok(validateJourney(journey, net, query()));
    }
});

test('RAPTOR POC preserves later inbound operators whose TSI allowance alone catches the connection', () => {
    const net = network([
        train('earlier', [['AAA', null, 10], ['BBB', 20, null]], 'XX'),
        train('later', [['AAA', null, 10], ['BBB', 24, null]], 'YY'),
        train('out', [['BBB', null, 25], ['DDD', 35, null]], 'ZZ')
    ], { tsi: [{ id: 'short', station: 'BBB', arrivingOperator: 'YY', departingOperator: 'ZZ', minutes: 1 }], allowances: { BBB: 10 } });
    const result = compare(net);
    assert.deepEqual(vehicleIds(result.journeys[0]), ['later', 'out']);
    assert.deepEqual(frontier(result), exhaustive(net, query()));
});

test('RAPTOR POC resolves exact extra-buffer boundaries without rounding fractional seconds', () => {
    const net = network([
        train('in', [['AAA', null, 0], ['BBB', 10, null]]),
        train('out', [['BBB', null, 15.5], ['DDD', 30, null]])
    ]);
    assert.equal(compare(net, query({ extraConnectionMinutes: 0.5 })).journeys.length, 1);
    assert.equal(compare(net, query({ extraConnectionMinutes: 0.5 + 1 / 60 })).journeys.length, 0);
});

test('RAPTOR POC counts replacement buses and non-walking links as boardings', () => {
    const services = [train('in', [['AAA', null, 0], ['BBB', 10, null]], 'OP', 'replacementBus'),
        train('out', [['CCC', null, 30], ['DDD', 45, null]])];
    const net = network(services, { links: [link({ mode: 'tubeTransfer' })] });
    assert.equal(compare(net).journeys[0].changes, 2);
    assert.equal(compare(net, query({ maxChanges: 1 })).journeys.length, 0);
    assert.equal(compare(net, query({ allowedModes: ['rail', 'walk', 'tubeTransfer'] })).journeys.length, 0);
    assert.equal(compare(net, query({ allowedModes: ['rail', 'replacementBus', 'walk'] })).journeys.length, 0);
});

test('RAPTOR POC compiles effective delays and delay-created overtaking independently', () => {
    const base = network([
        train('first', [['AAA', null, 0], ['BBB', 10, 11], ['DDD', 20, null]]),
        train('second', [['AAA', null, 5], ['BBB', 15, 16], ['DDD', 25, null]])
    ]);
    const original = structuredClone(base), index = compileRaptorNetwork(base);
    const changed = applyLiveSnapshot(base, { id: 'delay', observedAt: zero, services: [{ serviceId: 'first', calls: [
        { index: 1, arrival: time(20), departure: time(21) }, { index: 2, arrival: time(35) }
    ] }] });
    compare(changed);
    assert.deepEqual(frontier(findRaptorJourneys(query(), index)), exhaustive(base, query()));
    assert.deepEqual(base, original, 'A separate effective index cannot mutate or poison the scheduled index');
});

test('RAPTOR POC compiled cancellation, skipped stop, split section and unknown delay match effective calls', () => {
    const base = network([
        train('loop', [['AAA', null, 0], ['BBB', 10, 11], ['AAA', 20, 21], ['DDD', 30, null]]),
        train('backup', [['AAA', null, 10], ['DDD', 40, null]])
    ]);
    for (const update of [{ cancelled: true }, { unknownDelay: true }, { calls: [{ index: 2, cancelled: true }] },
        { cancelledSegments: [{ fromIndex: 1, toIndex: 2 }] }]) {
        const changed = applyLiveSnapshot(base, { id: 'cancel', observedAt: zero,
            services: [{ serviceId: 'loop', ...update }] });
        const request = query();
        assert.deepEqual(frontier(compare(changed, request)), exhaustive(changed, request));
    }
});

test('RAPTOR POC rebuilds effective delays that create a previously impossible onward connection', () => {
    const base = network([
        train('in', [['AAA', null, 0], ['BBB', 15, null]]),
        train('middle', [['BBB', null, 10], ['CCC', 20, null]]),
        train('out', [['CCC', null, 25], ['DDD', 35, null]])
    ]);
    assert.equal(compare(base).journeys.length, 0);
    const changed = applyLiveSnapshot(base, { id: 'delay', observedAt: zero, services: [
        { serviceId: 'middle', calls: [{ index: 0, departure: time(20) }, { index: 1, arrival: time(30) }] },
        { serviceId: 'out', calls: [{ index: 0, departure: time(35) }, { index: 1, arrival: time(45) }] }
    ] });
    assert.deepEqual(vehicleIds(compare(changed).journeys[0]), ['in', 'middle', 'out']);
});

test('RAPTOR POC fixed ALF links retain waiting, date/day limits, complete traversal and priority', () => {
    const services = [train('in', [['AAA', null, 0], ['BBB', 10, null]]),
        train('out', [['CCC', null, 40], ['DDD', 50, null]])];
    const row = link({ minutes: 10, startTime: '0725', endTime: '0735', days: '0100000',
        startDate: '2026-09-08', endDate: '2026-09-08' });
    const result = compare(network(services, { links: [row] }));
    assert.equal(result.journeys[0].legs[1].movementDeparture, iso(25));
    assert.equal(result.journeys[0].legs[1].breakdown.waitingMinutes, 10);
    for (const value of [{ startTime: '0726' }, { endDate: '2026-09-07' }, { days: '1000000' }]) {
        assert.equal(compare(network(services, { links: [{ ...row, ...value }] })).journeys.length, 0);
    }
    assert.equal(compare(network(services, { links: [row, link({ id: 'priority', minutes: 30, priority: 2 })] })).journeys.length, 0);
});

test('RAPTOR POC ALF links are bidirectional but arbitrary fixed links stay directional', () => {
    const services = [train('in', [['AAA', null, 0], ['CCC', 10, null]]),
        train('out', [['BBB', null, 30], ['DDD', 45, null]])];
    assert.equal(compare(network(services, { links: [link()] })).journeys.length, 1);
    assert.equal(compare(network(services, { links: [link({ sourceRef: { member: 'OTHER' } })] })).journeys.length, 0);
});

test('RAPTOR POC conflicting equal-priority ALF rules and missing station allowances cannot make shortcuts', () => {
    const services = [train('in', [['AAA', null, 0], ['BBB', 10, null]]),
        train('out', [['CCC', null, 30], ['DDD', 45, null]])];
    assert.equal(compare(network(services, { links: [link(), link({ id: 'conflict', minutes: 2 })] })).journeys.length, 0);
    assert.equal(compare(network(services, { links: [link(), link({ id: 'duplicate' })] })).journeys.length, 1);
    assert.equal(compare(network(services, { links: [link()], allowances: { BBB: null } })).journeys.length, 0);
});

test('RAPTOR POC endpoint walks use endpoint allowances and actual journey departure windows', () => {
    const net = network([train('middle', [['BBB', null, 20], ['CCC', 40, null]])], {
        links: [link({ id: 'start', origin: 'AAA', destination: 'BBB' }),
            link({ id: 'end', origin: 'CCC', destination: 'DDD' })]
    });
    const result = compare(net);
    assert.equal(result.journeys[0].departure, iso(10));
    assert.equal(result.journeys[0].arrival, iso(50));
    assert.equal(result.journeys[0].changes, 0);
    assert.equal(compare(net, query({ time: iso(11) })).journeys.length, 0);
    assert.equal(compare(net, query({ windowMinutes: 10 })).journeys.length, 0);
});

test('RAPTOR POC does not synthesize unknown links or chain fixed links', () => {
    const services = [train('first', [['AAA', null, 0], ['BBB', 10, null]]),
        train('last', [['CCC', null, 35], ['DDD', 45, null]])];
    assert.equal(compare(network(services)).journeys.length, 0);
    const links = [link({ origin: 'BBB', destination: 'EEE' }), link({ id: 'second', origin: 'EEE', destination: 'CCC' })];
    assert.equal(compare(network(services, { links })).journeys.length, 0);
});

test('RAPTOR POC overnight ALF windows retain the originating operating day', () => {
    const net = network([train('night', [['CCC', null, 1040], ['DDD', 1050, null]])], {
        links: [link({ origin: 'AAA', destination: 'CCC', minutes: 5, startTime: '2355', endTime: '0010', days: '0100000',
            startDate: '2026-09-08', endDate: '2026-09-08' })], allowances: { AAA: 0, CCC: 0 }
    });
    const result = compare(net, query({ time: iso(1020), windowMinutes: 30 }));
    assert.equal(result.journeys[0].departure, iso(1025));
});

test('RAPTOR POC DST autumn repeated hour stays separate and spring missing hour is unavailable', () => {
    const service = train('night', [['CCC', null, 0], ['DDD', 10, null]]);
    service.calls[0].departure = Date.parse('2026-10-25T01:25:00Z');
    service.calls[1].arrival = Date.parse('2026-10-25T01:35:00Z');
    const net = network([service], { links: [link({ origin: 'AAA', destination: 'CCC', minutes: 5,
        startTime: '0115', endTime: '0130', days: '0000001' })], allowances: { AAA: 0, CCC: 0 } });
    const result = compare(net, query({ time: '2026-10-25T00:50:00Z', windowMinutes: 60 }));
    assert.equal(result.journeys[0].departure, '2026-10-25T01:20:00.000Z');
    const spring = structuredClone(net);
    spring.services[0].calls[0].departure = Date.parse('2026-03-29T01:25:00Z');
    spring.services[0].calls[1].arrival = Date.parse('2026-03-29T01:35:00Z');
    spring.rules.links[0] = link({ origin: 'AAA', destination: 'CCC', minutes: 5, startTime: '0100', endTime: '0200', days: '0000001' });
    assert.equal(compare(spring, query({ time: '2026-03-29T00:00:00Z', windowMinutes: 120 })).journeys.length, 0);
});

test('RAPTOR POC first-departure window and duration constraints are inclusive/exclusive at exact bounds', () => {
    const net = network([train('start', [['AAA', null, 0], ['DDD', 30, null]]),
        train('last', [['AAA', null, 119 + 59 / 60], ['DDD', 200, null]]),
        train('outside', [['AAA', null, 120], ['DDD', 121, null]])]);
    assert.deepEqual(frontier(compare(net)), exhaustive(net, query()));
    assert.equal(compare(net, query(), { maxDurationMinutes: 30 }).journeys.length, 1);
    assert.equal(compare(net, query(), { maxDurationMinutes: 30 - 1 / 60 }).journeys.length, 0);
});

test('RAPTOR POC preserves five-change deep chains and fewer-boarding alternatives', () => {
    const codes = ['AAA', 'BBB', 'CCC', 'EEE', 'FFF', 'GGG', 'DDD'];
    const services = codes.slice(0, -1).map((from, i) => train(`chain${i}`,
        [[from, null, 10 + i * 20], [codes[i + 1], 20 + i * 20, null]]));
    const net = network(services), request = query({ maxChanges: 5 });
    assert.equal(compare(net, request).journeys[0].changes, 5);
    assert.equal(compare(net, query({ maxChanges: 4 })).journeys.length, 0);
});

test('RAPTOR POC seeded cyclic and repeated-stop fixtures equal an independent exhaustive frontier', () => {
    let seed = 17358;
    const random = n => { seed = (Math.imul(seed, 1103515245) + 12345) >>> 0; return (seed >>> 8) % n; };
    const codes = ['AAA', 'BBB', 'CCC', 'DDD'];
    for (let fixture = 0; fixture < 36; fixture++) {
        const services = [];
        for (let i = 0; i < 10; i++) {
            const departure = random(65), rows = [[codes[random(4)], null, departure]];
            for (let stop = 1; stop <= 3; stop++) rows.push([codes[random(4)], departure + stop * 8,
                stop === 3 ? null : departure + stop * 8 + 1,
                { canAlight: random(6) !== 0, canBoard: stop < 3 && random(6) !== 0 }]);
            services.push(train(`${fixture}:${i}`, rows, random(2) ? 'XX' : 'YY'));
        }
        const net = network(services, { tsi: [{ id: 'override', station: 'CCC', arrivingOperator: 'XX', departingOperator: 'YY', minutes: 1 }] });
        const request = query({ maxChanges: 3, extraConnectionMinutes: fixture % 3 });
        for (const options of [{}, { departureProfile: true }]) {
            assert.deepEqual(frontier(compare(net, request, options), options.departureProfile),
                exhaustive(net, request, options), `Cyclic fixture ${fixture}, departure profile ${Boolean(options.departureProfile)}`);
        }
    }
});

test('RAPTOR POC seeded shared-pattern FIFO and overtaking loops retain the exhaustive frontier', () => {
    let seed = 622418;
    const random = n => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return (seed >>> 8) % n; };
    const codes = ['AAA', 'BBB', 'CCC', 'DDD'];
    for (let fixture = 0; fixture < 48; fixture++) {
        const services = [];
        for (let pattern = 0; pattern < 4; pattern++) {
            const stations = [codes[random(4)], codes[random(4)], codes[random(4)], codes[random(4)]];
            const operator = random(2) ? 'XX' : 'YY', departure = random(40);
            for (let trip = 0; trip < 4; trip++) {
                const start = departure + trip * 4;
                const final = start + 24 + (fixture % 2 ? random(20) : 0);
                services.push(train(`${pattern}:${trip}`, [[stations[0], null, start],
                    [stations[1], start + 8, start + 9], [stations[2], start + 16, start + 17],
                    [stations[3], final, null]], operator));
            }
        }
        const net = network(services, { tsi: [{ id: 'override', station: 'BBB', arrivingOperator: 'XX', departingOperator: 'YY', minutes: 1 }] });
        const request = query({ maxChanges: 2 });
        for (const options of [{}, { departureProfile: true }]) {
            assert.deepEqual(frontier(compare(net, request, options), options.departureProfile),
                exhaustive(net, request, options), `Shared-route fixture ${fixture}, profile ${Boolean(options.departureProfile)}`);
        }
    }
});

test('RAPTOR POC preserves unsafe service histories for zero-time backward-sequence continuation', () => {
    const net = network([
        train('S', [['BBB', null, 0], ['DDD', 0, 0], ['AAA', 0, 0], ['BBB', 0, null]]),
        train('T', [['AAA', null, 0], ['BBB', 0, null]])
    ], { allowances: { AAA: 0, BBB: 0, DDD: 0 } });
    // The legacy router has a pre-existing dominance omission on this
    // degenerate fixture, so the exhaustive source oracle is the authority.
    // S's AAA->BBB prefix must not erase T: only T may subsequently ride S.
    const { index, result } = compareOracleOnly(net, query({ maxChanges: 1 }));
    assert.ok(index.unsafeServices.has('S'));
    assert.ok(index.unsafeServices.has('T'));
    assert.deepEqual(result.journeys.map(vehicleIds), [['T', 'S']]);
    assert.equal(result.journeys[0].changes, 1);
});

test('RAPTOR POC conservatively preserves histories for nonmonotone effective service times', () => {
    const net = network([
        train('S', [['BBB', null, 2], ['DDD', 3, 3], ['AAA', 0, 0], ['BBB', 1, null]]),
        train('T', [['AAA', null, 0], ['BBB', 1, null]])
    ], { allowances: { AAA: 0, BBB: 0, DDD: 0 } });
    // Each selected ride is chronological, even though S's overall source
    // timeline is not. That source cannot use the strict-progress proof.
    const { index, result } = compareOracleOnly(net, query({ maxChanges: 1 }));
    assert.ok(index.unsafeServices.has('S'));
    assert.ok(!index.unsafeServices.has('T'));
    assert.deepEqual(result.journeys.map(vehicleIds), [['T', 'S']]);
    const reversal = train('dwell-reversal', [['AAA', null, 0], ['BBB', 10, 5], ['DDD', 20, null]]);
    assert.ok(compileRaptorNetwork(network([reversal])).unsafeServices.has('dwell-reversal'));
    const normal = train('normal', [['AAA', null, 0], ['BBB', 5, 5], ['DDD', 10, null]]);
    assert.ok(!compileRaptorNetwork(network([normal])).unsafeServices.has('normal'),
        'Equal arrival/departure dwell times do not remove strictly positive passenger progress');
});

test('RAPTOR POC considers later unsafe continuation trips in an equal-time FIFO route', () => {
    const rows = [['BBB', null, 0], ['DDD', 0, 0], ['AAA', 0, 0], ['BBB', 0, null]];
    const net = network([
        train('X', [['CCC', null, 0], ['AAA', 0, null]]), train('S', rows), train('T', rows)
    ], { allowances: { AAA: 0, BBB: 0, CCC: 0, DDD: 0 } });
    const { result } = compareOracleOnly(net, query({ origin: 'CCC', maxChanges: 2 }));
    assert.equal(result.journeys[0].changes, 2);
    const ids = vehicleIds(result.journeys[0]);
    assert.equal(ids[0], 'X');
    assert.deepEqual(new Set(ids.slice(1)), new Set(['S', 'T']));
    assert.equal(result.journeys[0].legs.filter(leg => leg.kind === 'vehicle')[1].boardIndex, 2);
});

test('RAPTOR POC later unsafe FIFO continuation preserves a strictly earlier final arrival', () => {
    const net = network([
        train('X', [['CCC', null, -10], ['AAA', 0, null]]),
        train('S', [['BBB', null, 120], ['DDD', 125, 125], ['AAA', 0, 0], ['BBB', 5, null]]),
        train('T', [['BBB', null, 121], ['DDD', 126, 126], ['AAA', 1, 1], ['BBB', 6, null]])
    ], { allowances: { AAA: 0, BBB: 0, CCC: 0, DDD: 0 } });
    // S and T form one FIFO route, but neither is globally chronological.
    // Taking only the earliest continuation S would force the final T ride,
    // arriving at 126 instead of the feasible X -> T -> S arrival at 125.
    const { index, result } = compareOracleOnly(net, query({ origin: 'CCC', time: iso(-10), maxChanges: 2 }));
    assert.equal(index.stats.routes, 2, 'S and T share one route; X supplies the other');
    assert.ok(index.unsafeServices.has('S') && index.unsafeServices.has('T'));
    assert.deepEqual(result.journeys.map(vehicleIds), [['X', 'T', 'S']]);
    assert.equal(result.journeys[0].arrival, iso(125));
});

test('RAPTOR POC recomputes unsafe histories for operational cancellation-split identities', () => {
    const base = network([
        train('S', [['BBB', null, 0], ['DDD', 0, 0], ['AAA', 0, 0], ['BBB', 0, null]]),
        train('T', [['AAA', null, 0], ['BBB', 0, null]])
    ], { allowances: { AAA: 0, BBB: 0, DDD: 0 } });
    const original = structuredClone(base), index = compileRaptorNetwork(base);
    const split = applyLiveSnapshot(base, { id: 'split', observedAt: zero,
        services: [{ serviceId: 'S', cancelledSegments: [{ fromIndex: 1, toIndex: 2 }] }] });
    const { index: splitIndex, result } = compareOracleOnly(split, query({ maxChanges: 1 }));
    assert.ok(splitIndex.unsafeServices.has('S:live:0-1'));
    assert.ok(splitIndex.unsafeServices.has('S:live:2-3'));
    assert.ok(!splitIndex.unsafeServices.has('S'));
    assert.equal(result.journeys[0].changes, 1);
    assert.deepEqual(frontier(findRaptorJourneys(query({ maxChanges: 1 }), index)), exhaustive(base, query({ maxChanges: 1 })));
    assert.deepEqual(base, original);
});

test('RAPTOR POC pagination and balanced departure profiles do not change the criterion frontier', () => {
    const net = network([
        train('first', [['AAA', null, 0], ['DDD', 40, null]]),
        train('second', [['AAA', null, 10], ['DDD', 50, null]]),
        train('third', [['AAA', null, 20], ['DDD', 60, null]]),
        train('feed', [['AAA', null, 10], ['BBB', 20, null]]),
        train('fast', [['BBB', null, 25], ['DDD', 30, null]])
    ]);
    const index = compileRaptorNetwork(net), request = query({ limit: 2 });
    const options = { departureProfile: true, balanceDepartures: true };
    const first = findRaptorJourneys(request, index, options), pages = [...first.journeys];
    let next = first.pagination.nextOffset;
    while (next != null) {
        const result = findRaptorJourneys(request, index, { ...options, offset: next });
        pages.push(...result.journeys);
        next = result.pagination.nextOffset;
    }
    const full = findRaptorJourneys(query(), index, options);
    assert.deepEqual(pages, full.journeys);
    assert.deepEqual(frontier(full, true), exhaustive(net, query(), options));
});

test('RAPTOR POC rejects unsupported arrival and live-resolver semantics instead of silently ignoring them', () => {
    const index = compileRaptorNetwork(network([train('direct', [['AAA', null, 0], ['DDD', 30, null]])]));
    for (const [request, options] of [[query({ timeType: 'arriveBy' }), {}],
        [query(), { resolveTubeConnection: async () => null }], [query(), { excludeDirect: new Set(['AAA|DDD']) }]]) {
        assert.throws(() => findRaptorJourneys(request, index, options), { code: 'UNSUPPORTED_REQUEST' });
    }
});

test('RAPTOR POC rejects invalid bounds/stations and recognizes already-at-destination', () => {
    const index = compileRaptorNetwork(network([train('direct', [['AAA', null, 0], ['DDD', 30, null]])]));
    for (const request of [query({ time: 'invalid' }), query({ windowMinutes: 0 }), query({ maxChanges: 6 }), query({ maxChanges: -1 })]) {
        assert.throws(() => findRaptorJourneys(request, index), { code: 'INVALID_REQUEST' });
    }
    assert.throws(() => findRaptorJourneys(query({ destination: 'XXX' }), index), { code: 'INVALID_STATION' });
    for (const via of [null, 'BBB', ['XXX'], ['BBB', 'BBB'], ['AAA'], ['DDD']]) {
        assert.throws(() => findRaptorJourneys(query({ via }), index), { code: 'INVALID_STATION' });
    }
    assert.throws(() => findRaptorJourneys(query({ destination: 'AAA', via: ['BBB'] }), index), { code: 'INVALID_STATION' });
    const result = findRaptorJourneys(query({ destination: 'AAA' }), index);
    assert.equal(result.alreadyAtDestination, true);
    assert.deepEqual(result.journeys, []);
});

test('RAPTOR POC honors exact operation and label budgets and cancellation before publishing', () => {
    const index = compileRaptorNetwork(network(Array.from({ length: 40 }, (_, i) => train(`direct${i}`,
        [['AAA', null, i], ['DDD', i + 30, null]]))));
    const request = query(), result = findRaptorJourneys(request, index);
    assert.deepEqual(findRaptorJourneys(request, index, { maxOperations: result.metrics.operations }).journeys, result.journeys);
    assert.throws(() => findRaptorJourneys(request, index, { maxOperations: result.metrics.operations - 1 }), { code: 'SEARCH_TIMEOUT' });
    assert.throws(() => findRaptorJourneys(request, index, { maxLabels: 1 }), { code: 'SEARCH_TIMEOUT' });
    assert.throws(() => findRaptorJourneys(request, index, { signal: { aborted: true } }), { code: 'SEARCH_CANCELLED' });
    let polls = 0;
    assert.throws(() => findRaptorJourneys(request, index, { signal: { get aborted() { return ++polls > 1; } } }), { code: 'SEARCH_CANCELLED' });
    assert.throws(() => compileRaptorNetwork(index.network, { check() { throw new Error('compile cancelled'); } }), /compile cancelled/);
});

test('RAPTOR POC checks elapsed deadline before publishing a short completed route', t => {
    const index = compileRaptorNetwork(network([train('direct', [['AAA', null, 0], ['DDD', 30, null]])]));
    const clock = Date.now();
    let polls = 0;
    // Deadline creation and entry are on time. The final mandatory checkpoint
    // observes expiry, even though this short search has fewer than 256 checks.
    t.mock.method(Date, 'now', () => clock + (++polls >= 3 ? 11 : 0));
    assert.throws(() => findRaptorJourneys(query(), index, { timeoutMs: 10 }), { code: 'SEARCH_TIMEOUT' });
});
