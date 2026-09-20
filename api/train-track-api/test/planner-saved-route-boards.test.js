import test from 'node:test';
import assert from 'node:assert/strict';
import { SavedRouteBoards, savedRoutePlanKey } from '../lib/planner/saved-route-boards.js';
import { normalizeRouteBoards } from '../lib/planner/route-boards.js';
import { PlannerError } from '../lib/planner/contract.js';

const start = Date.parse('2026-09-17T12:10:00Z');
const version = 'a'.repeat(64);
const body = { routes: [{ id: 'saved', origin: 'KTH', destination: 'VIC' }] };
const tick = () => new Promise(resolve => setImmediate(resolve));
const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };
async function idle(manager) {
    for (let i = 0; i < 150 && (manager.active || manager.activeLive.size || manager.liveQueue.length || manager.queue.length); i++) await tick();
    assert.equal(manager.active, null);
    assert.equal(manager.activeLive.size, 0);
    assert.equal(manager.liveQueue.length, 0);
    assert.equal(manager.queue.length, 0);
}
function fixture(t, overrides = {}) {
    let now = start, currentVersion = version;
    const records = overrides.records ?? new Map();
    const calls = [], directCalls = [], refreshCalls = [], logs = [], retained = [];
    let statuses = 0;
    const result = () => ({ journeys: [{ id: 'trip', departure: new Date(now + 60000).toISOString(),
        arrival: new Date(now + 1200000).toISOString(), legs: [] }], dataset: { version: currentVersion, scheduledOnly: true },
    search: { window: { from: new Date(now).toISOString(), to: new Date(now + 21600000).toISOString() } }, warnings: [], pagination: {} });
    const cache = { get: async key => records.get(key), set: async (key, value) => { records.set(key, value); return true; } };
    const service = {
        status: async () => { statuses++; return { available: true, dataset: { version: currentVersion } }; },
        retainResult: value => retained.push(value),
        call: async (method, payload, options) => {
            calls.push({ method, payload, options });
            options.onStart?.();
            if (overrides.call) return overrides.call(method, payload, options, result);
            return { result: result(), connections: { stations: [], rules: { tsi: [], links: [] } } };
        }
    };
    const live = {
        direct: async (request, options) => {
            directCalls.push({ request, options });
            return overrides.direct ? overrides.direct(request, options) : { status: 'empty' };
        },
        refresh: async (plan, request, options) => {
            refreshCalls.push({ plan, request, options });
            return overrides.refresh ? overrides.refresh(plan, request, options) : {
                ...result(), live: { mode: request.realtime, status: 'live', expiresAt: new Date(now + 90000).toISOString() }
            };
        }
    };
    const searchLog = { start: input => {
        const row = { input, updates: [], finishes: [] }; logs.push(row);
        return { update: value => row.updates.push(value), finish: value => row.finishes.push(value) };
    } };
    const manager = new SavedRouteBoards(service, { live, cache, now: () => now, searchLog, ...overrides.options });
    t.after(() => manager.close());
    return { manager, cache, service, records, calls, directCalls, refreshCalls, logs, retained, result,
        advance: ms => { now += ms; }, setVersion: value => { currentVersion = value; }, statuses: () => statuses };
}

test('direct departures use no timetable metadata, planner, cache or search logs', async t => {
    const snapshot = { departures: [{ serviceID: 'live-train' }], dataStatus: 'live' };
    const f = fixture(t, { direct: () => ({ status: 'available', snapshot }) });
    assert.equal((await f.manager.get(body)).apiVersion, 4);
    await idle(f.manager);
    const board = (await f.manager.get(body)).boards[0];
    assert.equal(board.status, 'ready');
    assert.equal(board.source, 'direct');
    assert.deepEqual(board.direct, snapshot);
    assert.equal(f.statuses(), 0);
    assert.equal(f.calls.length, 0);
    assert.equal(f.logs.length, 0);
    assert.equal(f.records.size, 0);
});

test('a later direct replacement bus cannot suppress an earlier connecting journey', async t => {
    const directDeparture = new Date(start + 176 * 60000).toISOString();
    const f = fixture(t, { direct: () => ({ status: 'available', compareWithConnections: true,
        departureAt: directDeparture, snapshot: { departures: [{ serviceID: 'late-bus', serviceType: 'bus' }] } }) });
    await f.manager.get(body); await idle(f.manager);
    const board = (await f.manager.get(body)).boards[0];
    assert.equal(board.source, 'planned');
    assert.equal(board.result.journeys[0].departure, new Date(start + 60000).toISOString());
    assert.equal(f.calls.length, 1);
});

test('an earlier direct replacement bus remains selected after connecting journeys are compared', async t => {
    const directDeparture = new Date(start + 30000).toISOString();
    const snapshot = { departures: [{ serviceID: 'early-bus', serviceType: 'bus' }] };
    const f = fixture(t, { direct: () => ({ status: 'available', compareWithConnections: true,
        departureAt: directDeparture, snapshot }) });
    await f.manager.get(body); await idle(f.manager);
    const board = (await f.manager.get(body)).boards[0];
    assert.equal(board.source, 'direct');
    assert.deepEqual(board.direct, snapshot);
    assert.equal(f.calls.length, 1);
});

test('a direct replacement bus remains available when its comparison plan fails', async t => {
    const snapshot = { departures: [{ serviceID: 'fallback-bus', serviceType: 'bus' }] };
    const f = fixture(t, { direct: () => ({ status: 'available', compareWithConnections: true,
        departureAt: new Date(start + 176 * 60000).toISOString(), snapshot }),
    call: async () => { throw new PlannerError('SEARCH_TIMEOUT', 'Planning exceeded its budget.'); } });
    await f.manager.get(body); await idle(f.manager);
    const board = (await f.manager.get(body)).boards[0];
    assert.equal(board.source, 'direct');
    assert.deepEqual(board.direct, snapshot);
    assert.equal(board.error, undefined);
});

test('time-locked later searches preserve their window and bypass current direct departures', async t => {
    const later = new Date(start + 6 * 60 * 60 * 1000).toISOString();
    const future = { routes: [{ ...body.routes[0], id: 'later', time: later }] };
    const f = fixture(t, { direct: () => ({ status: 'available', snapshot: { departures: [{ serviceID: 'current' }] } }) });
    await f.manager.get(future);
    await idle(f.manager);
    const board = (await f.manager.get(future)).boards[0];
    assert.equal(f.directCalls.length, 0, 'a future planner window must not be replaced by the current live board');
    assert.equal(f.calls.length, 1);
    assert.equal(f.calls[0].method, 'savedRoutePlan');
    assert.equal(f.calls[0].payload.request.time, later);
    assert.equal(f.calls[0].payload.request.algorithm, 'raptor');
    assert.equal(f.calls[0].payload.includeDirect, true);
    assert.equal(board.source, 'planned');
    assert.ok(board.result);
    assert.equal(board.direct, undefined);
    assert.equal(f.refreshCalls.length, 1);
    assert.equal((await f.manager.get(future)).boards[0].status, 'ready');
    await idle(f.manager);
    assert.equal(f.refreshCalls.length, 1, 'a completed future board must wait for the next live-check interval');
});

test('unknown, stale, partial and failed direct lookups cannot start a planner fallback', async t => {
    for (const reason of ['unknown', 'stale', 'partial', 'unavailable', 'details-failed']) {
        const f = fixture(t, { direct: () => ({ status: 'unknown', error: { code: 'LIVE_UNAVAILABLE', message: reason } }) });
        await f.manager.get(body); await idle(f.manager);
        const board = (await f.manager.get(body)).boards[0];
        assert.equal(board.status, 'unavailable');
        assert.equal(board.error.message, reason);
        assert.equal(f.calls.length, 0);
        assert.equal(f.statuses(), 0);
        assert.equal(f.logs.length, 0);
    }
});

test('confirmed empty direct board plans once and refreshes only cached topology thereafter', async t => {
    const f = fixture(t);
    const viaBody = { routes: [{ ...body.routes[0], via: ['BMS'] }] };
    await f.manager.get(viaBody); await idle(f.manager);
    await f.manager.get(viaBody); await idle(f.manager);
    const board = (await f.manager.get(viaBody)).boards[0];
    assert.equal(board.source, 'planned');
    assert.equal(board.status, 'ready');
    assert.equal(f.calls.length, 1);
    assert.equal(f.calls[0].method, 'savedRoutePlan');
    assert.equal(f.calls[0].payload.request.windowMinutes, 360);
    assert.equal(f.calls[0].payload.request.realtime, 'off');
    assert.deepEqual(f.calls[0].payload.request.via, ['BMS']);
    assert.equal(f.calls[0].options.priority, 'background');
    assert.equal(f.logs.length, 1);
    assert.equal(f.logs[0].input.cacheStatus, 'miss');
    assert.equal(f.logs[0].finishes[0].status, 'success');
    for (let i = 0; i < 3; i++) {
        f.advance(31000); await f.manager.get(viaBody); await idle(f.manager);
    }
    assert.equal(f.calls.length, 1);
    assert.ok(f.refreshCalls.length >= 3);
    assert.equal(f.logs.length, 1);
});

test('fallback topology is shared across clients, realtime modes and process restarts for two hours', async t => {
    const f = fixture(t);
    await f.manager.get(body, { client: 'first' }); await idle(f.manager);
    const record = [...f.records.values()][0];
    assert.equal(record.expiresAt - record.computedAt, 7200000);
    const other = fixture(t, { records: f.records });
    const ignored = { routes: [{ ...body.routes[0], id: 'second', realtime: 'ignore' }] };
    other.advance(70 * 60000);
    await other.manager.get(ignored, { client: 'second' }); await idle(other.manager);
    assert.equal(other.calls.length, 0);
    assert.equal(other.refreshCalls.length, 1);
    assert.equal(other.refreshCalls[0].request.realtime, 'ignore');
    assert.equal((await other.manager.get(ignored)).boards[0].id, 'second');
    assert.equal(other.logs.length, 1);
    assert.equal(other.logs[0].input.cacheStatus, 'hit');
    other.advance(31000); await other.manager.get(ignored); await idle(other.manager);
    assert.equal(other.logs.length, 1);
});

test('cache identity includes date, dataset and required route options but excludes request time and live policy', () => {
    const request = normalizeRouteBoards(body, start)[0].request;
    const key = savedRoutePlanKey(request, version);
    assert.equal(key, savedRoutePlanKey({ ...request, time: new Date(start + 3600000).toISOString(), realtime: 'ignore' }, version));
    for (const changed of [{ via: ['BMS'] }, { maxChanges: 1 }, { extraConnectionMinutes: 10 },
        { allowedModes: ['rail'] }, { time: '2026-09-18T12:10:00Z' }, { destination: 'ECR' }]) {
        assert.notEqual(key, savedRoutePlanKey({ ...request, ...changed }, version));
    }
    assert.notEqual(key, savedRoutePlanKey(request, 'b'.repeat(64)));
});

test('empty fallback results are cached and not replanned every live poll', async t => {
    const f = fixture(t, { call: async (method, payload, options, result) => ({ result: { ...result(), journeys: [] }, connections: {} }),
        refresh: async plan => plan.result });
    await f.manager.get(body); await idle(f.manager);
    for (let i = 0; i < 3; i++) { f.advance(31000); await f.manager.get(body); await idle(f.manager); }
    assert.equal(f.calls.length, 1);
    assert.equal((await f.manager.get(body)).boards[0].result.journeys.length, 0);
    assert.equal(f.logs[0].finishes[0].outcome, 'empty');
});

test('missing cached-leg live data never replans, while expired or changed timetable plans do', async t => {
    let fail = false;
    const f = fixture(t, { refresh: async plan => {
        if (fail) throw new PlannerError('LIVE_UNAVAILABLE', 'A leg could not be checked.');
        return plan.result;
    } });
    await f.manager.get(body); await idle(f.manager);
    fail = true;
    f.advance(31000); await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.length, 1);
    fail = false;
    f.setVersion('b'.repeat(64));
    f.advance(31000); await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.length, 2);
    f.advance(7200001); await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.length, 3);
});

test('same topology misses coalesce across clients and live modes while a single planner job runs', async t => {
    const held = deferred();
    const f = fixture(t, { call: async (method, payload, options, result) => {
        await held.promise; return { result: result(), connections: {} };
    } });
    await f.manager.get(body, { client: 'first' });
    for (let i = 0; i < 10 && !f.calls.length; i++) await tick();
    const ignored = { routes: [{ ...body.routes[0], id: 'other', realtime: 'ignore' }] };
    await f.manager.get(ignored, { client: 'second' });
    for (let i = 0; i < 10; i++) await tick();
    assert.equal(f.calls.length, 1);
    assert.equal(f.manager.active.entries.size, 2);
    held.resolve(); await idle(f.manager);
    assert.equal(f.logs.length, 1);
    assert.ok(f.logs[0].updates.some(value => value.coalesced));
    assert.equal(f.calls[0].options.signal.aborted, false);
});

test('planning progress stays visible, scheduled options publish before slow leg refresh, and details are retained', async t => {
    const calculation = deferred(), live = deferred();
    const f = fixture(t, { call: async (method, payload, options, result) => {
        options.onProgress?.('searching'); await calculation.promise; return { result: result(), connections: {} };
    }, refresh: async plan => { await live.promise; return plan.result; } });
    await f.manager.get(body);
    for (let i = 0; i < 20 && !f.calls.length; i++) await tick();
    const waiting = (await f.manager.get(body)).boards[0];
    assert.equal(waiting.progress.phase, 'searching');
    assert.ok(waiting.progress.startedAt);
    calculation.resolve();
    for (let i = 0; i < 20 && !f.refreshCalls.length; i++) await tick();
    const provisional = (await f.manager.get(body)).boards[0];
    assert.equal(provisional.result.search.provisional, true);
    assert.equal(provisional.result.live.status, 'unavailable');
    assert.ok(f.retained.length);
    live.resolve(); await idle(f.manager);
});

test('provisional and refreshed boards hide slower connections without pruning the cached plan', async t => {
    const live = deferred();
    const time = minutes => new Date(start + minutes * 60000).toISOString();
    const option = (id, arrival) => ({ id, departure: time(5), arrival: time(arrival), changes: 1, legs: [
        { kind: 'vehicle', mode: 'rail', serviceId: 'same-first-train', operator: 'TL',
            from: { crs: 'ZFD' }, to: { crs: 'HNH' }, departure: time(5), arrival: time(20) },
        { kind: 'transfer', mode: 'interchange', from: { crs: 'HNH' }, to: { crs: 'HNH' },
            departure: time(20), arrival: time(25) },
        { kind: 'vehicle', mode: 'rail', serviceId: id, operator: 'SE', from: { crs: 'HNH' }, to: { crs: 'KTH' },
            departure: time(arrival - 15), arrival: time(arrival) }
    ] });
    const journeys = [option('later', 60), option('earliest', 45), option('last', 75)];
    const f = fixture(t, { call: async (_method, _payload, _options, result) => ({
        result: { ...result(), journeys }, connections: {}
    }), refresh: async plan => { await live.promise; return plan.result; } });
    await f.manager.get(body);
    for (let i = 0; i < 20 && !f.refreshCalls.length; i++) await tick();
    const provisional = (await f.manager.get(body)).boards[0];
    assert.equal(provisional.result.search.provisional, true);
    assert.deepEqual(provisional.result.journeys.map(journey => journey.id), ['earliest']);
    assert.equal([...f.records.values()][0].profile.result.journeys.length, 3);
    live.resolve(); await idle(f.manager);
    const refreshed = (await f.manager.get(body)).boards[0];
    assert.deepEqual(refreshed.result.journeys.map(journey => journey.id), ['earliest']);
    assert.equal([...f.records.values()][0].profile.result.journeys.length, 3);
    assert.equal(f.calls.length, 1);
});

test('live checks and planner calculations each have bounded concurrency', async t => {
    const live = deferred(), plan = deferred();
    const f = fixture(t, { options: { maxLive: 2 }, direct: async () => { await live.promise; return { status: 'empty' }; },
        call: async (method, payload, options, result) => { await plan.promise; return { result: result(), connections: {} }; } });
    const routes = ['KTH', 'ECR', 'BMS', 'EUS'].map((origin, index) => ({ id: String(index), origin, destination: 'VIC' }));
    await f.manager.get({ routes });
    await tick();
    assert.equal(f.directCalls.length, 2);
    assert.equal(f.manager.activeLive.size, 2);
    live.resolve();
    for (let i = 0; i < 20; i++) await tick();
    assert.equal(f.calls.length, 1);
    assert.equal(f.manager.jobs.size, 4);
    const boards = (await f.manager.get({ routes })).boards;
    assert.ok(boards.some(board => board.progress.queuePosition > 0));
    plan.resolve(); await idle(f.manager);
    assert.equal(f.calls.length, 4);
});

test('returning direct services cancel unused fallback work and restore the direct source', async t => {
    let available = false;
    const held = deferred();
    const f = fixture(t, { direct: () => available ? { status: 'available', snapshot: { departures: [{ serviceID: 'direct' }] } } : { status: 'empty' },
        call: async (method, payload, options, result) => { await held.promise; return { result: result(), connections: {} }; } });
    await f.manager.get(body);
    for (let i = 0; i < 20 && !f.calls.length; i++) await tick();
    available = true; f.advance(31000);
    await f.manager.get(body);
    for (let i = 0; i < 20; i++) await tick();
    assert.equal(f.calls[0].options.signal.aborted, true);
    assert.equal((await f.manager.get(body)).boards[0].source, 'direct');
    held.resolve(); await idle(f.manager);
    assert.equal(f.records.size, 0);
});

test('expired interest and shutdown cancel shared work, but another interested mode retains it', async t => {
    const held = deferred();
    const f = fixture(t, { call: async (method, payload, options, result) => { await held.promise; return { result: result(), connections: {} }; } });
    await f.manager.get(body);
    const ignored = { routes: [{ ...body.routes[0], realtime: 'ignore' }] };
    await f.manager.get(ignored, { client: 'second' });
    for (let i = 0; i < 20; i++) await tick();
    f.advance(100000); await f.manager.get(ignored, { client: 'second' });
    for (let i = 0; i < 20; i++) await tick();
    f.advance(30000); f.manager.prune();
    assert.equal(f.calls[0].options.signal.aborted, false);
    assert.equal(f.manager.active.entries.size, 1);
    f.manager.close();
    assert.equal(f.calls[0].options.signal.aborted, true);
    held.resolve(); await idle(f.manager);
    assert.equal(f.records.size, 0);
});

test('planner failures do not enter the two-hour cache and retry only after backoff', async t => {
    const f = fixture(t, { call: async () => { throw new PlannerError('SEARCH_TIMEOUT', 'Planning exceeded its budget.'); } });
    await f.manager.get(body); await idle(f.manager);
    assert.equal((await f.manager.get(body)).boards[0].error.code, 'SEARCH_TIMEOUT');
    assert.equal(f.records.size, 0);
    assert.equal(f.calls.length, 1);
    f.advance(21000); await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.length, 2);
    assert.equal(f.logs[0].finishes[0].status, 'fail');
});

test('a transient direct failure does not cancel a fallback admitted after an earlier successful empty board', async t => {
    const held = deferred();
    let unavailable = false;
    const f = fixture(t, { direct: () => ({ status: unavailable ? 'unknown' : 'empty' }),
        call: async (method, payload, options, result) => { await held.promise; return { result: result(), connections: {} }; } });
    await f.manager.get(body);
    for (let i = 0; i < 20 && !f.calls.length; i++) await tick();
    unavailable = true; f.advance(31000);
    await f.manager.get(body);
    for (let i = 0; i < 20; i++) await tick();
    assert.equal(f.calls[0].options.signal.aborted, false);
    assert.equal(f.calls.length, 1);
    held.resolve(); await idle(f.manager);
    assert.equal(f.records.size, 1);
    f.advance(31000); await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.length, 1);
});

test('fresh empty direct boards remove earlier direct rows while the fallback is queued', async t => {
    const held = deferred();
    let empty = false;
    const f = fixture(t, { direct: () => empty ? { status: 'empty' }
        : { status: 'available', snapshot: { departures: [{ serviceID: 'old' }] } },
    call: async (method, payload, options, result) => { await held.promise; return { result: result(), connections: {} }; } });
    await f.manager.get(body); await idle(f.manager);
    empty = true; f.advance(31000);
    await f.manager.get(body);
    for (let i = 0; i < 20; i++) await tick();
    const board = (await f.manager.get(body)).boards[0];
    assert.equal(board.source, 'planned');
    assert.equal(board.direct, undefined);
    held.resolve(); await idle(f.manager);
});

test('direct board freshness follows the provider observation expiry', async t => {
    const f = fixture(t, { direct: () => ({ status: 'available', snapshot: { departures: [{ serviceID: 'live' }] },
        expiresAt: new Date(start + 5000).toISOString() }) });
    await f.manager.get(body); await idle(f.manager);
    assert.ok((await f.manager.get(body)).boards[0].direct);
    f.advance(6000);
    assert.equal((await f.manager.get(body)).boards[0].direct, undefined);
    assert.equal(f.calls.length, 0);
});

test('oversized persisted and worker plans are bounded before retention', async t => {
    const request = normalizeRouteBoards(body, start)[0].request;
    const f = fixture(t);
    f.records.set(savedRoutePlanKey(request, version), { profile: { result: f.result(), padding: 'x'.repeat(256 * 1024) },
        computedAt: start, expiresAt: start + 7200000 });
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.length, 1);
    assert.equal([...f.records.values()][0].profile.padding, undefined);
    const large = fixture(t, { call: async (method, payload, options, result) => ({ result: result(), padding: 'x'.repeat(256 * 1024) }) });
    await large.manager.get(body); await idle(large.manager);
    assert.equal(large.records.size, 0);
    assert.equal((await large.manager.get(body)).boards[0].error.code, 'PROFILE_TOO_LARGE');
});

test('entry and per-client admission bounds retain finite pending work', async t => {
    const held = deferred();
    const f = fixture(t, { options: { maxEntries: 3, maxPending: 2, maxPerClient: 1 },
        call: async (method, payload, options, result) => { await held.promise; return { result: result(), connections: {} }; } });
    const routes = ['KTH', 'ECR', 'BMS', 'EUS'].map((origin, index) => ({ id: String(index), origin, destination: 'VIC' }));
    await f.manager.get({ routes });
    for (let i = 0; i < 20; i++) await tick();
    assert.equal(f.manager.entries.size, 3);
    assert.equal(f.manager.jobs.size, 3);
    assert.equal(f.manager.queue.length, 0); // The same client already occupies its admitted slot.
    assert.equal(f.calls.length, 1);
    held.resolve(); await idle(f.manager);
    assert.equal(f.calls.length, 3);
});
