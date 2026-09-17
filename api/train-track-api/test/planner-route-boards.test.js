import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { PlannerRouteBoards, normalizeRouteBoards, routeBoardKey } from '../lib/planner/route-boards.js';
import { RouteBoardCache } from '../lib/planner/route-board-cache.js';
import { registerPlannerRoutes } from '../lib/planner-routes.js';
import { PlannerError } from '../lib/planner/contract.js';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';
import { PlannerEngine } from '../lib/planner/engine.js';

const start = Date.parse('2026-09-17T12:10:00Z');
const version = 'a'.repeat(64);
const body = { routes: [{ id: 'saved-route', origin: 'KTH', destination: 'VIC' }] };
const tick = () => new Promise(resolve => setImmediate(resolve));
async function idle(manager) {
    for (let i = 0; i < 100 && (manager.active || manager.queue.length); i++) await tick();
    assert.equal(manager.active, null);
    assert.equal(manager.queue.length, 0);
}
function fixture(t, overrides = {}) {
    let now = start;
    let currentVersion = version;
    const records = new Map();
    const calls = [];
    const cache = { get: async key => records.get(key), set: async (key, value) => { records.set(key, value); return true; } };
    const service = {
        status: async () => ({ available: true, dataset: { version: currentVersion } }),
        call: async (method, payload, options) => {
            calls.push({ method, payload, options });
            if (overrides.call) return overrides.call(method, payload, options);
            if (method === 'routeBoardProfile') return { profile: { version: payload.version, request: payload.request, journeys: [], searchTruncated: false } };
            return { journeys: [{ id: 'trip', departure: new Date(now + 60000).toISOString(), arrival: new Date(now + 20 * 60000).toISOString(), legs: [] }],
                dataset: { version: payload.profile.version }, live: { status: 'live', expiresAt: new Date(now + 90000).toISOString() },
                warnings: [], pagination: {}, search: {}, ...overrides.result };
        }
    };
    const manager = new PlannerRouteBoards(service, { cache, now: () => now, ...overrides.options });
    t.after(() => manager.close());
    return { manager, service, records, calls, cache, advance: ms => { now += ms; }, setVersion: value => { currentVersion = value; } };
}

test('new contract validates bounded batches, ordered required vias and stable cross-client keys', () => {
    const [route] = normalizeRouteBoards({ routes: [{ id: 'a', origin: ' kth ', destination: 'vic', via: [' bms '] }] }, start);
    assert.deepEqual(route.request.via, ['BMS']);
    assert.equal(route.request.origin, 'KTH');
    assert.equal(route.realtime, 'apply');
    const key = routeBoardKey(route.request, version, start);
    assert.equal(key.key, routeBoardKey({ ...route.request, time: new Date(start + 1000).toISOString() }, version, start + 1000).key);
    assert.notEqual(key.key, routeBoardKey({ ...route.request, via: [] }, version, start).key);
    assert.notEqual(key.key, routeBoardKey(route.request, 'b'.repeat(64), start).key);
    assert.equal(key.request.windowMinutes, 480);
    for (const value of [{}, { routes: [] }, { routes: Array(9).fill(body.routes[0]) },
        { routes: [body.routes[0], body.routes[0]] }, { routes: [{ ...body.routes[0], via: ['KTH'] }] },
        { routes: [{ ...body.routes[0], realtime: 'off' }] }, { routes: [{ ...body.routes[0], via: 'BMS' }] }]) {
        assert.throws(() => normalizeRouteBoards(value, start), PlannerError);
    }
});

test('clients and polling share one profile; 20-second app polls do not recalculate routes', async t => {
    const f = fixture(t);
    const first = await f.manager.get(body, { client: 'one', network: 'network' });
    assert.equal(first.boards[0].status, 'queued');
    await f.manager.get({ routes: [{ ...body.routes[0], id: 'another-client-route' }] }, { client: 'two', network: 'network' });
    await idle(f.manager);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfile').length, 1);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardRefresh').length, 1);
    f.advance(20000);
    assert.equal((await f.manager.get(body)).boards[0].status, 'ready');
    await idle(f.manager);
    assert.equal(f.calls.length, 2);
    f.advance(11000);
    assert.equal((await f.manager.get(body)).boards[0].status, 'refreshing');
    await idle(f.manager);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfile').length, 1);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardRefresh').length, 2);
    assert.ok(f.calls.every(call => call.options.priority === 'background'));
    assert.equal(f.records.size, 1);
    assert.equal(JSON.stringify([...f.records.values()]).includes('another-client-route'), false);
    assert.equal(JSON.stringify([...f.records.values()]).includes('expiresAt":"'), false, 'Only numeric scheduled expiry, never live observations, persisted');
});

test('persistent scheduled cache is reusable after a manager restart; live observations are refreshed', async t => {
    const f = fixture(t);
    await f.manager.get(body);
    await idle(f.manager);
    f.manager.close();
    const restarted = new PlannerRouteBoards(f.service, { cache: f.cache, now: () => start + 30000 });
    t.after(() => restarted.close());
    await restarted.get(body);
    await idle(restarted);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfile').length, 1);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardRefresh').length, 2);
    assert.equal(restarted.metrics.cacheHits, 1);
});

test('timetable activation, time buckets and realtime modes have distinct required cache boundaries', async t => {
    const f = fixture(t);
    await f.manager.get(body); await idle(f.manager);
    await f.manager.get({ routes: [{ ...body.routes[0], realtime: 'ignore' }] }); await idle(f.manager);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfile').length, 1, 'Override shares scheduled profiles');
    assert.equal(f.calls.at(-1).payload.realtime, 'ignore');
    f.advance(2000); f.setVersion('b'.repeat(64));
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfile').length, 2);
    f.advance(2 * 3600000);
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfile').length, 3);
});

test('departed results are filtered and expired live observations never return as ready', async t => {
    const f = fixture(t);
    await f.manager.get(body); await idle(f.manager);
    f.advance(61000);
    const update = await f.manager.get(body);
    assert.equal(update.boards[0].result.journeys.length, 0);
    assert.equal(update.boards[0].status, 'refreshing');
    await idle(f.manager);
    f.advance(91000);
    const expired = await f.manager.get(body);
    assert.equal(expired.boards[0].result, undefined);
    assert.equal(expired.boards[0].status, 'queued');
});

test('disruptions trigger one shared early reroute without replacing the scheduled cache', async t => {
    const f = fixture(t, { result: { needsReplan: true, disruptionFingerprint: 'cancelled-one' } });
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardReplan').length, 1);
    f.advance(31000);
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfile').length, 1);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardReplan').length, 1);
    assert.equal([...f.records.values()][0].profile.live, undefined);
});

test('failed computations are retryable and never persisted as no journeys', async t => {
    const f = fixture(t, { call: async () => { throw new PlannerError('SEARCH_TIMEOUT', 'Try again.', 504); } });
    await f.manager.get(body); await idle(f.manager);
    const response = await f.manager.get(body);
    assert.equal(response.boards[0].status, 'unavailable');
    assert.equal(response.boards[0].error.code, 'SEARCH_TIMEOUT');
    assert.equal(response.boards[0].result, undefined);
    assert.equal(f.records.size, 0);
    f.advance(21000);
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.length, 2);
});

test('bounded admission does not multiply jobs and abandoning one shared caller preserves another', async t => {
    let resolve;
    const f = fixture(t, { options: { maxPending: 1 }, call: async () => new Promise(value => { resolve = value; }) });
    await f.manager.get(body, { client: 'one' });
    for (let i = 0; i < 10 && !resolve; i++) await tick();
    f.advance(60000);
    await f.manager.get(body, { client: 'two' });
    const busy = await f.manager.get({ routes: [{ id: 'other', origin: 'ECR', destination: 'VIC' }] });
    assert.equal(busy.boards[0].error.code, 'SEARCH_BUSY');
    f.advance(61000); f.manager.prune();
    assert.equal(f.calls[0].options.signal.aborted, false);
    f.advance(60000); f.manager.prune();
    assert.equal(f.calls[0].options.signal.aborted, true);
    resolve({ profile: { version, searchTruncated: false } });
    await idle(f.manager);
});

test('cache falls back to bounded memory when Mongo is unavailable and rejects oversized records', async () => {
    let now = start;
    const cache = new RouteBoardCache({ collection: async () => { throw new Error('offline'); }, now: () => now, maxEntries: 1 });
    const record = { profile: { version }, computedAt: start, expiresAt: start + 1000 };
    assert.equal(await cache.set('one', record), true);
    assert.deepEqual(await cache.get('one'), record);
    await cache.set('two', record);
    assert.equal(await cache.get('one'), null);
    assert.equal(await cache.set('huge', { ...record, profile: { content: 'x'.repeat(4 * 1024 * 1024) } }), false);
    now += 1001;
    assert.equal(await cache.get('two'), null);
});

test('new HTTP resource leaves legacy APIs and existing planner search contract untouched', async t => {
    const app = express();
    const f = fixture(t);
    f.service.search = async value => ({ oldSearch: value });
    registerPlannerRoutes(app, { service: f.service, routeBoards: f.manager });
    const legacy = { departures: [{ serviceID: 'unchanged' }] };
    app.get('/api/v1/departures/from/KTH/to/VIC', (req, res) => res.json(legacy));
    app.get('/api/v2/departures/from/KTH/to/VIC', (req, res) => res.json([{ KTH_VIC: legacy.departures }]));
    const listener = app.listen(0, '127.0.0.1');
    await new Promise(resolve => listener.once('listening', resolve));
    t.after(() => { f.service.searchJobs.close(); return new Promise(resolve => listener.close(resolve)); });
    const url = `http://127.0.0.1:${listener.address().port}`;
    const send = (path, body) => fetch(`${url}${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const response = await send('/api/v3/journey-planner/route-boards', body);
    assert.equal(response.status, 200);
    assert.equal((await response.json()).boards[0].status, 'queued');
    assert.equal((await send('/api/v2/journey-planner/route-boards', body)).status, 404);
    assert.equal((await send('/api/v3/journey-planner/route-boards', { routes: [] })).status, 400);
    assert.deepEqual(await (await fetch(`${url}/api/v1/departures/from/KTH/to/VIC`)).json(), legacy);
    assert.deepEqual(await (await fetch(`${url}/api/v2/departures/from/KTH/to/VIC`)).json(), [{ KTH_VIC: legacy.departures }]);
    assert.deepEqual(await (await send('/api/v3/journey-planner/search', { unchanged: true })).json(), { oldSearch: { unchanged: true } });
});

test('interactive searches take the next worker slot ahead of queued route warming', async t => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'route-board-priority-'));
    const filename = path.join(directory, 'worker.mjs');
    await fs.writeFile(filename, "import {parentPort} from 'node:worker_threads'; parentPort.on('message',m=>setTimeout(()=>parentPort.postMessage({id:m.id,result:m.payload}),40));");
    const service = new PlannerService({ ...plannerConfig({}), timeoutMs: 3000 }, { workerURL: pathToFileURL(filename) });
    t.after(async () => { service.close(); await fs.rm(directory, { recursive: true, force: true }); });
    const order = [];
    const run = (label, priority) => service.call('search', { label }, { priority }).then(() => { order.push(label); });
    const active = run('active', 'background');
    const warming = run('warming', 'background');
    const interactive = run('interactive', 'interactive');
    await Promise.all([active, warming, interactive]);
    assert.deepEqual(order, ['active', 'interactive', 'warming']);
});

test('persistent cache creates TTL, filters expired records itself and bounds stored profile count', async () => {
    const records = new Map();
    const indexes = [];
    const collection = {
        createIndex: async (...value) => indexes.push(value),
        replaceOne: async (query, value) => records.set(query._id, structuredClone(value)),
        findOne: async query => {
            const value = records.get(query._id);
            return value && value.expiresAt > query.expiresAt.$gt ? structuredClone(value) : null;
        },
        find: () => ({ sort: () => ({ skip: count => ({ toArray: async () => [...records.values()]
            .sort((a, b) => b.expiresAt - a.expiresAt).slice(count).map(value => ({ _id: value._id })) }) }) }),
        deleteMany: async query => query._id.$in.forEach(key => records.delete(key))
    };
    const cache = new RouteBoardCache({ collection: async () => collection, now: () => start, maxEntries: 2 });
    for (let i = 1; i <= 3; i++) await cache.set(String(i), { profile: { version }, computedAt: start, expiresAt: start + i * 1000 });
    assert.equal(records.size, 2);
    assert.ok(!records.has('1'));
    assert.deepEqual(indexes[0], [{ expiresAt: 1 }, { expireAfterSeconds: 0, name: 'expires_at_ttl', timeoutMS: 500 }]);
    const reboot = new RouteBoardCache({ collection: async () => collection, now: () => start + 2500 });
    assert.equal((await reboot.get('3')).profile.version, version);
    assert.equal(await reboot.get('2'), null, 'Do not wait for Mongo TTL cleanup');
});

test('a burst refreshing 64 existing boards obeys global, client and network limits while serving cached results', async t => {
    const f = fixture(t);
    const bodies = Array.from({ length: 64 }, (_, index) => ({ routes: [{ id: `route-${index}`,
        origin: `A${String(index).padStart(2, '0')}`, destination: 'DST' }] }));
    for (const value of bodies) { await f.manager.get(value); await idle(f.manager); }
    assert.equal(f.manager.entries.size, 64);
    f.advance(31000);
    f.service.call = async (method, payload, { signal }) => new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(new PlannerError('SEARCH_CANCELLED', 'Cancelled.', 499)), { once: true });
    });
    const responses = [];
    for (const [index, value] of bodies.entries()) responses.push(await f.manager.get(value,
        { client: index < 20 ? 'same-client' : `client-${index}`, network: index < 40 ? 'same-network' : `network-${index}` }));
    const pending = [...f.manager.queue, f.manager.active].filter(Boolean);
    assert.equal(pending.length, 8);
    assert.equal(pending.filter(work => work.client === 'same-client').length, 2);
    assert.equal(pending.filter(work => work.network === 'same-network').length, 4);
    assert.ok([...new Set(pending.map(work => work.client))].every(client => pending.filter(work => work.client === client).length <= 2));
    assert.ok([...new Set(pending.map(work => work.network))].every(network => pending.filter(work => work.network === network).length <= 4));
    assert.ok(responses.every(value => value.boards[0].result?.journeys.length === 1), 'Cache hits remain available when queue capacity is full');
    assert.equal(responses[63].boards[0].pollAfterMs, 5000);
    assert.equal(responses[63].boards[0].error.code, 'SEARCH_BUSY');
    f.advance(5000);
    await f.manager.get(bodies[63], { client: 'last-client', network: 'last-network' });
    assert.equal(f.manager.queue.length + Number(Boolean(f.manager.active)), 8);
    f.manager.close();
    await tick();
});

test('oversized initial and ephemeral profiles are rejected before retaining or persisting them', async t => {
    const oversized = { version, content: 'x'.repeat(4 * 1024 * 1024) };
    const initial = fixture(t, { call: async () => ({ profile: oversized }) });
    await initial.manager.get(body); await idle(initial.manager);
    assert.equal((await initial.manager.get(body)).boards[0].error.code, 'PROFILE_TOO_LARGE');
    assert.equal(initial.records.size, 0);
    assert.equal([...initial.manager.entries.values()][0].profile, undefined);
    const ephemeral = fixture(t, { call: async (method, payload) => {
        if (method === 'routeBoardProfile') return { profile: { version, request: payload.request } };
        const result = { journeys: [], dataset: { version }, warnings: [], pagination: {}, search: {} };
        return method === 'routeBoardRefresh' ? { ...result, needsReplan: true, disruptionFingerprint: 'delay' }
            : { ...result, refreshProfile: oversized };
    } });
    await ephemeral.manager.get(body); await idle(ephemeral.manager);
    const entry = [...ephemeral.manager.entries.values()][0];
    assert.equal(entry.error.code, 'PROFILE_TOO_LARGE');
    assert.equal(entry.refreshProfile, null);
    assert.ok(entry.profileBytes < 4 * 1024 * 1024);
    assert.ok(JSON.stringify([...ephemeral.records.values()]).length < 4 * 1024 * 1024);
});

test('partial but successful scheduled profiles retain the two-hour lifetime', async t => {
    const f = fixture(t, { call: async (method, payload) => method === 'routeBoardProfile'
        ? { profile: { version, request: payload.request, searchTruncated: true } }
        : { journeys: [], dataset: { version }, warnings: [], pagination: {}, search: { searchTruncated: true } } });
    await f.manager.get(body); await idle(f.manager);
    const entry = [...f.manager.entries.values()][0];
    assert.equal(entry.expiresAt - entry.computedAt, 2 * 3600000);
    f.advance(6 * 60000);
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfile').length, 1);
});

test('a timed-out Mongo write remains the sole persistence operation until it actually settles', async () => {
    let resolveWrite, writeCount = 0;
    const collection = { createIndex: async () => {},
        replaceOne: async (query, value, options) => {
            writeCount++;
            assert.equal(options.timeoutMS, 500);
            return new Promise(resolve => { resolveWrite = resolve; });
        },
        find: () => ({ sort: () => ({ skip: () => ({ toArray: async () => [] }) }) }) };
    const cache = new RouteBoardCache({ collection: async () => collection, deadlineMs: 5, maxEntries: 4, now: () => start });
    const record = { profile: { version }, computedAt: start, expiresAt: start + 3600000 };
    await cache.set('first', record);
    assert.equal(writeCount, 1);
    await Promise.all(Array.from({ length: 50 }, (_, index) => cache.set(`next-${index}`, record)));
    assert.equal(writeCount, 1, 'Timed-out promise must not release the actual write slot');
    assert.equal(cache.memory.size, 4);
    assert.deepEqual(await cache.get('next-49'), record);
    resolveWrite();
    await tick();
    assert.equal(cache.write, null);
    const next = cache.set('after-recovery', record);
    await tick();
    assert.equal(writeCount, 2);
    resolveWrite();
    await next;
});

test('Mongo initialization and reads stay shared after caller deadlines', async () => {
    let resolveConnection, connectionCount = 0, readCount = 0, resolveRead;
    const collection = { createIndex: async () => {}, findOne: async (query, options) => {
        readCount++;
        assert.deepEqual(options, { maxTimeMS: 500, timeoutMS: 500 });
        return new Promise(resolve => { resolveRead = resolve; });
    } };
    const cache = new RouteBoardCache({ collection: () => {
        connectionCount++;
        return new Promise(resolve => { resolveConnection = resolve; });
    }, deadlineMs: 5, now: () => start });
    assert.equal(await cache.get('first'), null);
    await Promise.all(Array.from({ length: 25 }, (_, index) => cache.get(`during-connect-${index}`)));
    assert.equal(connectionCount, 1);
    resolveConnection(collection);
    await tick();
    assert.equal(readCount, 0, 'An expired lookup must not start a late query after connection recovery');
    assert.equal(await cache.get('after-connect'), null);
    await Promise.all(Array.from({ length: 25 }, (_, index) => cache.get(`during-read-${index}`)));
    assert.equal(readCount, 1);
    resolveRead(null);
    await tick();
    assert.equal(cache.read, null);
});

test('real engine and saved-board facade serve a dated engineering diversion after a serialized cache restart', async t => {
    const at = minutes => start + minutes * 60000;
    const train = (id, stops) => ({ id, uid: id, originDate: '2026-09-17', mode: 'rail', operator: 'SE',
        sourceRef: { path: '/private/source', line: 1 }, calls: stops.map(([station, arrival, departure], sequence) => ({
            station, tiploc: station, sequence, arrival: arrival == null ? null : at(arrival),
            departure: departure == null ? null : at(departure), canBoard: departure != null, canAlight: arrival != null
        })) });
    const services = [train('P00001', [['KTH', null, 5], ['BMS', 20, null]]),
        train('P00002', [['BMS', null, 30], ['VIC', 70, null]])];
    const repo = { version, metadata: { source: { generationDate: '2026-09-01' }, importedAt: new Date(start).toISOString(),
        coverage: { startDate: '2026-09-01', endDate: '2026-12-01', basis: 'synthetic' }, limitations: [] },
        stations: ['KTH', 'BMS', 'VIC'].map(crs => ({ crs, name: crs, minimumChangeMinutes: 5 })),
        rules: { tsi: [], links: [] }, resolveServices: date => ({ services: date === '2026-09-17' ? services : [], diagnostics: { counts: {} } }), close() {} };
    const engine = new PlannerEngine({ ...plannerConfig({}), datasetPath: '/fixture' }, { openDataset: async () => repo,
        now: () => start, liveProvider: { fetchBoards: async () => ({ boards: [], errors: [] }), fetchDetails: async () => ({ details: [], errors: [] }) } });
    const methods = [];
    const service = { status: () => engine.status(), call: (method, payload, options) => {
        methods.push(method); return engine[method](payload, options.signal, options.execution);
    } };
    const records = new Map();
    const cache = { get: async key => records.has(key) ? JSON.parse(records.get(key)) : null,
        set: async (key, value) => { records.set(key, JSON.stringify(value)); return true; } };
    const manager = new PlannerRouteBoards(service, { cache, now: () => start });
    t.after(() => { manager.close(); engine.close(); });
    await manager.get(body); await idle(manager);
    const first = (await manager.get(body)).boards[0];
    assert.equal(first.status, 'ready', JSON.stringify(first.error));
    assert.equal(first.result.journeys.length, 1);
    assert.equal(first.result.journeys[0].changes, 1);
    assert.deepEqual(first.result.journeys[0].legs.filter(leg => leg.kind === 'vehicle').map(leg => leg.to.crs), ['BMS', 'VIC']);
    assert.equal(JSON.stringify(first).includes('/private'), false);
    manager.close();
    const restarted = new PlannerRouteBoards(service, { cache, now: () => start });
    t.after(() => restarted.close());
    await restarted.get(body); await idle(restarted);
    assert.equal((await restarted.get(body)).boards[0].result.journeys.length, 1);
    assert.equal(methods.filter(method => method === 'routeBoardProfile').length, 1);
});
