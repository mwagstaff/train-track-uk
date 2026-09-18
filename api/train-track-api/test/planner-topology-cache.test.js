import test from 'node:test';
import assert from 'node:assert/strict';
import { setTimeout as delay } from 'node:timers/promises';
import { applyLiveSnapshot } from '../lib/planner/live-network.js';
import { findJourneys, findJourneysAsync, prepareNetwork, releaseIndexCaches, validateJourney } from '../lib/planner/router.js';

const minute = 60_000, zero = Date.parse('2026-09-08T10:00:00+01:00');
const time = value => zero + value * minute;
const iso = value => new Date(time(value)).toISOString();
const train = (id, rows) => ({ id, uid: id, variantId: `variant:${id}`, originDate: '2026-09-08',
    operator: 'OP', mode: 'rail', sourceRef: { member: 'synthetic.MCA', line: 1 },
    calls: rows.map(([station, arrival, departure], sequence) => ({ station, tiploc: station, sequence,
        arrival: arrival == null ? null : time(arrival), departure: departure == null ? null : time(departure),
        canAlight: arrival != null, canBoard: departure != null })) });
function network(services) {
    return { services, rules: { tsi: [], links: [] }, stations: new Map(
        [...new Set(['AAA', 'BBB', 'CCC', 'DDD', ...services.flatMap(service => service.calls.map(call => call.station))])]
            .map(crs => [crs, { crs, name: crs, minimumChangeMinutes: 5 }])) };
}
const request = values => ({ origin: 'AAA', destination: 'DDD', time: iso(0), timeType: 'departAfter',
    maxChanges: 2, windowMinutes: 120, limit: 100, ...values });
const directions = [{}, { timeType: 'arriveBy', time: iso(120) }];
const snapshot = services => ({ id: 'live-test', observedAt: zero, expiresAt: time(1), services });
const vehicleIds = result => result.journeys.map(journey => journey.legs.filter(leg => leg.kind === 'vehicle').map(leg => leg.serviceId));
const standalone = net => ({ services: structuredClone(net.services), stations: structuredClone(net.stations), rules: structuredClone(net.rules) });
function equivalent(net, query, result = findJourneys(query, net)) {
    const { metrics: ignored, ...actual } = result;
    const { metrics: otherIgnored, ...expected } = findJourneys(query, standalone(net));
    assert.deepEqual(actual, expected, 'Reusing baseline topology must preserve complete itineraries, calling points and ranking');
    for (const journey of actual.journeys) assert.ok(validateJourney(journey, net, query));
    return result;
}
function profile(metrics) {
    for (const field of ['indexBuildMs', 'topologyBoundsMs', 'temporalBoundsMs', 'labelExpansionMs', 'transferResolutionMs', 'resultAssemblyMs']) {
        assert.ok(Number.isFinite(metrics[field]) && metrics[field] >= 0, `${field} is a measured, nonnegative duration`);
    }
    for (const field of ['topologyBoundsBuilds', 'topologyBoundsCacheHits', 'temporalBoundsBuilds', 'temporalBoundsCacheHits', 'internalRoutePasses']) {
        assert.ok(Number.isInteger(metrics[field]) && metrics[field] >= 0, `${field} is a bounded integer counter`);
    }
}

test('cold and warm route profiles count builds and hits without changing the timetable', () => {
    const base = network([train('direct', [['AAA', null, 5], ['DDD', 30, null]])]);
    const before = structuredClone(base);
    const first = findJourneys(request(), base), second = findJourneys(request(), base);
    assert.deepEqual(first.journeys, second.journeys);
    assert.deepEqual(base, before);
    profile(first.metrics);
    profile(second.metrics);
    assert.equal(first.metrics.internalRoutePasses, 1);
    assert.equal(first.metrics.topologyBoundsBuilds, 1);
    assert.equal(first.metrics.topologyBoundsCacheHits, 0);
    assert.equal(first.metrics.temporalBoundsBuilds, 1);
    assert.equal(first.metrics.temporalBoundsCacheHits, 0);
    assert.ok(first.metrics.resultAssemblyMs > 0, 'Ranking and itinerary validation are measured');
    assert.equal(second.metrics.indexBuildMs, 0);
    assert.equal(second.metrics.topologyBoundsBuilds, 0);
    assert.equal(second.metrics.topologyBoundsCacheHits, 1);
    assert.equal(second.metrics.temporalBoundsBuilds, 0);
    assert.equal(second.metrics.temporalBoundsCacheHits, 1);
    assert.ok(second.metrics.resultAssemblyMs > 0);
});

test('a cancelled overlay-first cache miss cannot poison later scheduled searches in either direction', () => {
    for (const direction of directions) {
        const base = network([train('only', [['AAA', null, 5], ['DDD', 30, null]])]);
        const changed = applyLiveSnapshot(base, snapshot([{ serviceId: 'only', cancelled: true }]));
        const query = request(direction), cancelled = equivalent(changed, query);
        assert.equal(cancelled.journeys.length, 0);
        assert.equal(cancelled.metrics.topologyBoundsBuilds, 1);
        assert.equal(prepareNetwork(base).potentials.size, 0, 'A restricted overlay must not fill the baseline cache');
        const original = equivalent(base, query);
        assert.deepEqual(vehicleIds(original), [['only']]);
        assert.equal(original.metrics.topologyBoundsBuilds, 1);
        assert.equal(original.metrics.topologyBoundsCacheHits, 0);
        assert.ok(prepareNetwork(changed).topologyIndex === undefined);
        assert.notEqual(prepareNetwork(changed).potentials, prepareNetwork(base).potentials);
        assert.equal(prepareNetwork(changed).potentials.size, 1);
        assert.notEqual(prepareNetwork(changed).temporal, prepareNetwork(base).temporal);
    }
});

test('independent and chained timing overlays reuse baseline bounds while cancellation falls back', () => {
    for (const direction of directions) {
        const base = network([
            train('best', [['AAA', null, 5], ['DDD', 20, null]]),
            train('alternative', [['AAA', null, 0], ['DDD', 30, null]])
        ]);
        const query = request(direction), original = equivalent(base, query);
        const cancelled = applyLiveSnapshot(base, snapshot([{ serviceId: 'best', cancelled: true }]));
        const delayed = applyLiveSnapshot(base, snapshot([{ serviceId: 'best', calls: [
            { index: 0, departure: time(10) }, { index: 1, arrival: time(25) }
        ] }]));
        const chained = applyLiveSnapshot(delayed, snapshot([{ serviceId: 'best', calls: [
            { index: 0, departure: time(15) }, { index: 1, arrival: time(35) }
        ] }]));
        const platform = applyLiveSnapshot(base, snapshot([{ serviceId: 'best', calls: [{ index: 0, platform: '4' }] }]));
        const ignored = applyLiveSnapshot(base, snapshot([{ serviceId: 'best', cancelled: true }]), { mode: 'ignore' });
        const cancelledResult = equivalent(cancelled, query);
        assert.equal(cancelledResult.metrics.topologyBoundsBuilds, 1);
        assert.equal(cancelledResult.metrics.topologyBoundsCacheHits, 0);
        assert.ok(prepareNetwork(cancelled).topologyIndex === undefined);
        for (const overlay of [delayed, chained, platform, ignored]) {
            const result = equivalent(overlay, query);
            assert.equal(result.metrics.topologyBoundsBuilds, 0);
            assert.equal(result.metrics.topologyBoundsCacheHits, 1);
            assert.equal(result.metrics.temporalBoundsBuilds, 1);
            assert.equal(result.metrics.temporalBoundsCacheHits, 0);
            assert.equal(prepareNetwork(overlay).topologyIndex, prepareNetwork(base));
            assert.notEqual(prepareNetwork(overlay).temporal, prepareNetwork(base).temporal);
        }
        assert.notEqual(prepareNetwork(cancelled).temporal, prepareNetwork(delayed).temporal);
        assert.deepEqual(equivalent(base, query).journeys, original.journeys);
    }
});

test('split cancellations, skipped repeated calls and unknown times retain standalone itinerary ranking', () => {
    for (const direction of directions) {
        const base = network([
            train('loop', [['AAA', null, 0], ['BBB', 10, 11], ['AAA', 20, 21], ['DDD', 30, null]]),
            train('backup', [['AAA', null, 25], ['DDD', 45, null]])
        ]);
        const query = request(direction), original = equivalent(base, query);
        const split = applyLiveSnapshot(base, snapshot([{ serviceId: 'loop', cancelledSegments: [{ fromIndex: 1, toIndex: 2 }] }]));
        assert.ok(equivalent(split, query).journeys.some(journey => journey.legs.some(leg => leg.serviceId === 'loop:live:2-3')));
        const skipped = applyLiveSnapshot(base, snapshot([{ serviceId: 'loop', calls: [{ index: 2, cancelled: true }] }]));
        const skippedResult = equivalent(skipped, query);
        const loop = skippedResult.journeys.flatMap(journey => journey.legs).find(leg => leg.serviceId === 'loop');
        assert.equal(loop.boardIndex, 0, 'The later occurrence of AAA is no longer a boarding opportunity');
        assert.equal(loop.callingPoints.find(call => call.sequence === 2).live.cancelled, true);
        const unknown = applyLiveSnapshot(base, snapshot([{ serviceId: 'loop', unknownDelay: true }]));
        assert.deepEqual(vehicleIds(equivalent(unknown, query)), [['backup']]);
        for (const overlay of [split, skipped, unknown]) {
            const repeated = equivalent(overlay, query);
            assert.ok(prepareNetwork(overlay).topologyIndex === undefined);
            assert.notEqual(prepareNetwork(overlay).potentials, prepareNetwork(base).potentials);
            assert.equal(repeated.metrics.topologyBoundsCacheHits, 1);
            assert.equal(repeated.metrics.temporalBoundsBuilds, 0);
            assert.ok(repeated.metrics.temporalBoundsCacheHits > 0);
        }
        assert.deepEqual(equivalent(base, query).journeys, original.journeys);
    }
});

test('cancelling a shortcut retains three-boarding topology and profile-specific temporal pruning', () => {
    const services = [train('shortcut', [['AAA', null, 5], ['DDD', 15, null]])];
    for (let profile = 0; profile < 12; profile++) {
        const departure = profile * 10;
        services.push(train(`first${profile}`, [['AAA', null, departure], ['BBB', departure + 10, null]]));
        services.push(train(`middle${profile}`, [['BBB', null, departure + 20], ['CCC', departure + 30, null]]));
        services.push(train(`last${profile}`, [['CCC', null, departure + 40], ['DDD', departure + 50, null]]));
    }
    for (const direction of [{}, { timeType: 'arriveBy', time: iso(180) }]) {
        const base = network(services), query = request({ ...direction, windowMinutes: 180 });
        equivalent(base, query);
        const changed = applyLiveSnapshot(base, snapshot([{ serviceId: 'shortcut', cancelled: true }]));
        const result = equivalent(changed, query);
        assert.ok(prepareNetwork(changed).topologyIndex === undefined);
        assert.equal(result.metrics.topologyBoundsBuilds, 1);
        const bounds = prepareNetwork(changed).potentials.values().next().value;
        assert.equal(bounds.get(query.timeType === 'arriveBy' ? 'DDD' : 'AAA'), 3,
            'Removed shortcuts must not leave the original optimistic one-boarding bound');
        assert.ok(result.metrics.temporalBoundsBuilds > 1,
            'Three-boardings must keep profile-specific temporal envelopes enabled');
        assert.equal(result.pagination.total, 12);
        assert.deepEqual(frontier(result), exhaustive(changed, query));
    }
});

test('delay-created three-boarding connections rebuild temporal bounds in both directions', () => {
    for (const direction of directions) {
        const base = network([
            train('first', [['AAA', null, 0], ['BBB', 15, null]]),
            train('second', [['BBB', null, 10], ['CCC', 20, null]]),
            train('third', [['CCC', null, 25], ['DDD', 35, null]])
        ]);
        const query = request(direction), original = equivalent(base, query);
        assert.equal(original.journeys.length, 0);
        const changed = applyLiveSnapshot(base, snapshot([
            { serviceId: 'second', calls: [{ index: 0, departure: time(20) }, { index: 1, arrival: time(30) }] },
            { serviceId: 'third', calls: [{ index: 0, departure: time(35) }, { index: 1, arrival: time(45) }] }
        ]));
        const result = equivalent(changed, query);
        assert.deepEqual(vehicleIds(result), [['first', 'second', 'third']]);
        assert.equal(result.journeys[0].arrival, iso(45));
        assert.equal(result.metrics.topologyBoundsCacheHits, 1);
        assert.ok(result.metrics.temporalBoundsBuilds > 0, 'Delayed times cannot reuse the scheduled temporal envelope');
        assert.equal(result.metrics.temporalBoundsCacheHits, 0);
        assert.notEqual(prepareNetwork(changed).temporal, prepareNetwork(base).temporal);
        const restored = equivalent(base, query);
        assert.equal(restored.journeys.length, 0);
        assert.equal(restored.metrics.temporalBoundsBuilds, 0);
        assert.ok(restored.metrics.temporalBoundsCacheHits > 0);
    }
});

test('direction, boarding budget and allowed modes remain distinct topology cache keys', () => {
    const base = network([train('direct', [['AAA', null, 5], ['DDD', 30, null]])]);
    const queries = [request({ maxChanges: 0, allowedModes: ['rail', 'walk'] }),
        request({ maxChanges: 1, allowedModes: ['rail', 'walk'] }),
        request({ maxChanges: 0, allowedModes: ['replacementBus'] }),
        request({ maxChanges: 0, allowedModes: ['rail', 'walk'], timeType: 'arriveBy', time: iso(120) })];
    for (const query of queries) assert.equal(equivalent(base, query).metrics.topologyBoundsBuilds, 1);
    const reordered = equivalent(base, request({ maxChanges: 0, allowedModes: ['walk', 'rail'] }));
    assert.equal(reordered.metrics.topologyBoundsBuilds, 0);
    assert.equal(reordered.metrics.topologyBoundsCacheHits, 1);
    assert.equal(prepareNetwork(base).potentials.size, 4);
});

test('generic overlays that enable a call or add a service build their own topology bounds', () => {
    for (const direction of directions) {
        const disabled = train('disabled', [['AAA', null, 5], ['DDD', 30, null]]);
        disabled.calls[0].canBoard = false;
        const base = network([disabled]), query = request(direction);
        assert.equal(equivalent(base, query).journeys.length, 0);
        const enabled = structuredClone(disabled);
        enabled.calls[0].canBoard = true;
        const changed = { ...base, services: [enabled], baseNetwork: base, changedServiceIds: new Set(['disabled']) };
        const added = { ...base, services: [...base.services, train('new', [['AAA', null, 10], ['DDD', 25, null]])],
            baseNetwork: base, changedServiceIds: new Set(['new']) };
        for (const expanded of [changed, added]) {
            const result = equivalent(expanded, query);
            assert.equal(result.journeys.length, 1);
            assert.ok(prepareNetwork(expanded).topologyIndex === undefined, 'An expansion cannot use a restrictive baseline lower bound');
            assert.equal(result.metrics.topologyBoundsBuilds, 1);
            assert.equal(result.metrics.topologyBoundsCacheHits, 0);
            assert.equal(prepareNetwork(expanded).potentials.size, 1);
        }
        assert.equal(equivalent(base, query).journeys.length, 0);
    }
});

test('topology and temporal caches remain bounded and release on either baseline or overlay is safe', () => {
    const destinations = Array.from({ length: 33 }, (_, index) => `D${String(index).padStart(2, '0')}`);
    const base = network(destinations.map((destination, index) => train(`T${index}`, [['AAA', null, 5], [destination, 30, null]])));
    const query = request({ destination: destinations[0], maxChanges: 0 });
    const expected = equivalent(base, query).journeys;
    const index = prepareNetwork(base), firstKey = index.potentials.keys().next().value;
    for (const destination of destinations.slice(1)) equivalent(base, { ...query, destination });
    assert.equal(index.potentials.size, 32);
    assert.equal(index.potentials.has(firstKey), false);
    assert.equal(index.temporal.size, 4);
    assert.equal(equivalent(base, query).metrics.topologyBoundsBuilds, 1, 'An evicted destination is rebuilt');
    for (let start = 0; start < 12; start++) findJourneys({ ...query, time: iso(start) }, base);
    for (const envelopes of index.temporal.values()) assert.ok(envelopes.size <= 8);
    const changed = applyLiveSnapshot(base, snapshot([{ serviceId: 'T0', calls: [
        { index: 0, departure: time(6) }, { index: 1, arrival: time(31) }
    ] }]));
    const changedExpected = equivalent(changed, query).journeys, liveIndex = prepareNetwork(changed);
    const baseTemporalSize = index.temporal.size;
    releaseIndexCaches(changed);
    assert.equal(index.potentials.size, 0);
    assert.equal(liveIndex.temporal.size, 0);
    assert.equal(index.temporal.size, baseTemporalSize, 'Releasing an overlay does not discard another index’s temporal bounds');
    const rebuilt = equivalent(changed, query);
    assert.deepEqual(rebuilt.journeys, changedExpected);
    assert.equal(rebuilt.metrics.topologyBoundsBuilds, 1);
    assert.equal(rebuilt.metrics.temporalBoundsBuilds, 1);
    releaseIndexCaches(base);
    assert.equal(index.potentials.size, 0);
    assert.equal(index.temporal.size, 0);
    assert.deepEqual(equivalent(base, query).journeys, expected);
    releaseIndexCaches(network([]));
});

// This oracle reads effective calls directly, without prepared indexes, search
// labels, lower bounds or live metadata. It enumerates all feasible rail rides.
function exhaustive(net, query) {
    const solutions = [], reverse = query.timeType === 'arriveBy', boundary = Date.parse(query.time);
    function explore(station, ready, firstDeparture, rides, used) {
        if (station === query.destination && rides) {
            if (reverse ? ready <= boundary && ready > boundary - query.windowMinutes * minute
                : firstDeparture >= boundary && firstDeparture < boundary + query.windowMinutes * minute) {
                solutions.push({ departure: firstDeparture, arrival: ready, changes: rides - 1 });
            }
            return;
        }
        if (rides > query.maxChanges) return;
        for (const service of net.services) {
            if (used.has(service.id)) continue;
            for (let board = 0; board < service.calls.length - 1; board++) {
                const start = service.calls[board];
                if (start.station !== station || !start.canBoard || !Number.isFinite(start.departure)
                    || start.departure < ready + (rides ? 5 * minute : 0)) continue;
                for (let alight = board + 1; alight < service.calls.length; alight++) {
                    const end = service.calls[alight];
                    if (end.canAlight && Number.isFinite(end.arrival) && end.arrival >= start.departure) {
                        explore(end.station, end.arrival, firstDeparture ?? start.departure,
                            rides + 1, new Set([...used, service.id]));
                    }
                }
            }
        }
    }
    explore(query.origin, reverse ? -Infinity : boundary, null, 0, new Set());
    return [...new Set(solutions.filter(candidate => !solutions.some(other => other.departure >= candidate.departure
        && other.arrival <= candidate.arrival && other.changes <= candidate.changes
        && (other.departure > candidate.departure || other.arrival < candidate.arrival || other.changes < candidate.changes)))
        .map(row => `${row.departure}|${row.arrival}|${row.changes}`))].sort();
}
const frontier = result => [...new Set(result.journeys.map(row => `${Date.parse(row.departure)}|${Date.parse(row.arrival)}|${row.changes}`))].sort();

test('deterministic disrupted cyclic networks agree with exhaustive routing and standalone full itineraries', () => {
    let seed = 32191;
    const random = maximum => { seed = (Math.imul(seed, 1664525) + 1013904223) >>> 0; return seed % maximum; };
    const stations = ['AAA', 'BBB', 'CCC', 'DDD'];
    for (let sample = 0; sample < 24; sample++) {
        const services = [], updates = [];
        for (let number = 0; number < 9; number++) {
            const departure = random(45), id = `T${number}`, delay = random(12);
            const rows = Array.from({ length: 4 }, (_, stop) => [stations[random(4)],
                stop ? departure + stop * 8 : null, stop === 3 ? null : departure + stop * 8 + 1]);
            services.push(train(id, rows));
            updates.push({ serviceId: id, cancelled: random(9) === 0,
                ...(number === 0 ? { cancelledSegments: [{ fromIndex: 1, toIndex: 2 }] } : {}),
                calls: rows.map(([, arrival, leaves], index) => ({ index,
                    ...(arrival == null ? {} : { arrival: time(arrival + delay) }),
                    ...(leaves == null ? {} : { departure: time(leaves + delay) }),
                    ...(number === 1 && index === 1 ? { cancelled: true } : {}) })) });
        }
        const base = network(services), changed = applyLiveSnapshot(base, snapshot(updates));
        for (const direction of directions) {
            const query = request(direction), original = equivalent(base, query);
            const result = equivalent(changed, query);
            assert.deepEqual(frontier(result), exhaustive(changed, query), `sample ${sample}, ${query.timeType}`);
            assert.ok(prepareNetwork(changed).topologyIndex === undefined);
            assert.equal(result.metrics.topologyBoundsBuilds, 1);
            assert.equal(result.metrics.topologyBoundsCacheHits, 0);
            assert.deepEqual(equivalent(base, query).journeys, original.journeys);
        }
    }
});

test('async verification aggregates internal passes and interrupted builds never cache partial bounds', async () => {
    const base = network([train('direct', [['AAA', null, 5], ['DDD', 30, null]])]);
    const resolver = () => { throw new Error('The rail-only fixture must not request TfL'); };
    let verifications = 0;
    resolver.verifySelected = () => ++verifications === 1;
    const result = await findJourneysAsync(request(), base, { resolveTubeConnection: resolver });
    profile(result.metrics);
    assert.equal(result.metrics.internalRoutePasses, 2);
    assert.equal(result.metrics.topologyBoundsBuilds, 1);
    assert.equal(result.metrics.topologyBoundsCacheHits, 1);
    assert.equal(result.metrics.temporalBoundsBuilds, 1);
    assert.equal(result.metrics.temporalBoundsCacheHits, 1);
    releaseIndexCaches(base);
    assert.throws(() => findJourneys(request(), base, { maxOperations: 2 }), error => {
        assert.equal(error.code, 'SEARCH_TIMEOUT');
        profile(error.metrics);
        assert.equal(error.metrics.topologyBoundsBuilds, 1);
        assert.equal(error.metrics.temporalBoundsBuilds, 0);
        return true;
    });
    assert.equal(prepareNetwork(base).potentials.size, 0);
    assert.equal(equivalent(base, request()).metrics.topologyBoundsBuilds, 1);
    assert.throws(() => findJourneys(request(), base, { signal: AbortSignal.abort() }), { code: 'SEARCH_CANCELLED' });
});

test('cancellation during a suspended Tube lookup retains phase metrics without counting I/O as label expansion', async () => {
    for (const reject of [false, true]) {
        const base = network([]);
        base.rules.links = [{ id: 'tube-link', origin: 'AAA', destination: 'DDD', mode: 'tubeTransfer',
            minutes: 10, startTime: '0000', endTime: '2359' }];
        const controller = new AbortController();
        let lookups = 0;
        await assert.rejects(findJourneysAsync(request(), base, { signal: controller.signal,
            resolveTubeConnection: async () => {
                lookups++;
                await delay(110);
                if (reject) throw Object.assign(new Error('Lookup cancelled'), { code: 'SEARCH_CANCELLED' });
                controller.abort();
                return [];
            }
        }), error => {
            assert.equal(error.code, 'SEARCH_CANCELLED');
            profile(error.metrics);
            assert.equal(error.metrics.internalRoutePasses, 1);
            assert.equal(error.metrics.topologyBoundsBuilds, 1);
            assert.equal(error.metrics.temporalBoundsBuilds, 1);
            assert.ok(error.metrics.operations > 0);
            assert.ok(error.metrics.elapsedMs >= 100, 'The fixture actually suspended before cancellation');
            assert.ok(error.metrics.transferResolutionMs >= 100, 'The suspended lookup belongs to transfer resolution');
            assert.ok(error.metrics.labelExpansionMs < error.metrics.elapsedMs - 50,
                'Label expansion must exclude the suspended lookup even on failure');
            return true;
        });
        assert.equal(lookups, 1);
    }
});

test('failed selected-result verification retains assembly and transfer-resolution timing', async () => {
    const base = network([train('direct', [['AAA', null, 5], ['DDD', 30, null]])]);
    const resolver = () => { throw new Error('No Tube edge in this fixture'); };
    resolver.verifySelected = async selected => {
        assert.equal(selected.length, 1);
        await delay(60);
        throw Object.assign(new Error('Verification cancelled'), { code: 'SEARCH_CANCELLED' });
    };
    await assert.rejects(findJourneysAsync(request(), base, { resolveTubeConnection: resolver }), error => {
        assert.equal(error.code, 'SEARCH_CANCELLED');
        profile(error.metrics);
        assert.equal(error.metrics.internalRoutePasses, 1);
        assert.ok(error.metrics.operations > 0);
        assert.ok(error.metrics.resultAssemblyMs > 0);
        assert.ok(error.metrics.transferResolutionMs >= 50);
        assert.ok(error.metrics.labelExpansionMs < error.metrics.elapsedMs - 40);
        return true;
    });
});

test('selected-result verification rechecks cancellation before publication or another route pass', async () => {
    for (const changed of [false, true]) {
        const base = network([train('direct', [['AAA', null, 5], ['DDD', 30, null]])]);
        const controller = new AbortController();
        const resolver = () => { throw new Error('No Tube edge in this fixture'); };
        let verifications = 0;
        resolver.verifySelected = async selected => {
            verifications++;
            assert.equal(selected.length, 1);
            controller.abort();
            return changed;
        };
        await assert.rejects(findJourneysAsync(request(), base, { signal: controller.signal,
            resolveTubeConnection: resolver }), error => {
            assert.equal(error.code, 'SEARCH_CANCELLED');
            profile(error.metrics);
            assert.equal(error.metrics.internalRoutePasses, 1, 'Cancelled verification cannot enter another route pass');
            assert.ok(error.metrics.operations > 0);
            assert.ok(error.metrics.resultAssemblyMs > 0);
            return true;
        });
        assert.equal(verifications, 1);
    }
});

test('selected-result verification respects the total deadline and retains its measured wait', async () => {
    const base = network([train('direct', [['AAA', null, 5], ['DDD', 30, null]])]);
    const resolver = () => { throw new Error('No Tube edge in this fixture'); };
    let verifications = 0;
    resolver.verifySelected = async selected => {
        verifications++;
        assert.equal(selected.length, 1);
        await delay(60);
        return false;
    };
    await assert.rejects(findJourneysAsync(request(), base, { timeoutMs: 30,
        resolveTubeConnection: resolver }), error => {
        assert.equal(error.code, 'SEARCH_TIMEOUT');
        profile(error.metrics);
        assert.equal(error.metrics.internalRoutePasses, 1);
        assert.ok(error.metrics.operations > 0);
        assert.ok(error.metrics.resultAssemblyMs > 0);
        assert.ok(error.metrics.transferResolutionMs >= 40);
        assert.ok(error.metrics.elapsedMs >= 40);
        return true;
    });
    assert.equal(verifications, 1);
});
