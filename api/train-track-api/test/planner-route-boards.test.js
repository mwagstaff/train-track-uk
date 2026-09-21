import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { PlannerRouteBoards, normalizeRouteBoards, routeBoardKey, routeBoardFragmentKey } from '../lib/planner/route-boards.js';
import { RouteBoardCache } from '../lib/planner/route-board-cache.js';
import { registerPlannerRoutes } from '../lib/planner-routes.js';
import { PlannerError } from '../lib/planner/contract.js';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { noOpPlannerSearchLog } from '../lib/planner-search-log.js';

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

function chunkFixture(t, overrides = {}) {
    const f = fixture(t, { ...overrides, call: async (method, payload, options) => {
        if (overrides.beforeCall) await overrides.beforeCall(method, payload, options);
        options.onStart?.();
        if (method === 'routeBoardProfileChunk') {
            const departure = new Date(Date.parse(payload.chunk.from) + 15 * 60000).toISOString();
            const arrival = new Date(Date.parse(departure) + 20 * 60000).toISOString();
            return { profile: { version: payload.version, request: payload.request, dataset: { version: payload.version },
                candidates: [{ departure, arrival, durationMinutes: 20, changes: 0, legs: [] }],
                searchWindow: { ...payload.chunk, fromInclusive: true, toInclusive: false }, searchTruncated: false, warnings: [],
                profile: { policy: 'route-profile-v1', createdAt: new Date(start).toISOString(), departureTimesAvailable: 1,
                    routingChunkMinutes: 15, complete: true } } };
        }
        return { journeys: payload.profile.candidates.filter(journey => Date.parse(journey.departure) >= Date.parse(payload.time)).slice(0, 5),
            dataset: { version: payload.profile.version }, search: {}, warnings: [], pagination: {} };
    } });
    f.service.supportsProfileChunks = true;
    return f;
}

test('hourly profiles publish the current hour before later worker turns and expose real coverage', async t => {
    let release;
    let chunks = 0;
    const f = chunkFixture(t, { beforeCall: async method => {
        if (method === 'routeBoardProfileChunk' && ++chunks === 2) await new Promise(resolve => { release = resolve; });
    } });
    await f.manager.get(body);
    for (let i = 0; i < 30 && !release; i++) await tick();
    assert.ok(release);
    const early = (await f.manager.get(body)).boards[0];
    assert.equal(early.status, 'refreshing');
    assert.equal(early.result.journeys.length, 1);
    assert.equal(early.coverage.complete, false);
    assert.equal(early.coverage.completedWindows, 1);
    assert.equal(early.progress.totalWindows, 8);
    assert.deepEqual(f.calls.filter(call => call.method !== 'routeBoardPreview').slice(0, 3).map(call => call.method),
        ['routeBoardProfileChunk', 'routeBoardRefresh', 'routeBoardProfileChunk']);
    assert.equal(f.calls[0].payload.chunk.from, '2026-09-17T12:00:00.000Z');
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfileChunk')[1].payload.chunkMinutes, 15);
    release();
    await idle(f.manager);
    const finished = (await f.manager.get(body)).boards[0];
    assert.equal(finished.coverage.complete, true);
    assert.equal(finished.coverage.completedWindows, 8);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfileChunk').length, 8);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardRefresh').length, 2);
});

test('scheduled provisional results are visible while the first live lookup is still waiting', async t => {
    let release;
    let waits = 0;
    const updates = [];
    const f = chunkFixture(t, { options: { searchLog: { start: () => ({ update: value => updates.push(value), finish() {} }) } },
        beforeCall: async method => {
            if (method === 'routeBoardRefresh' && ++waits === 1) await new Promise(resolve => { release = resolve; });
        } });
    await f.manager.get(body);
    for (let i = 0; i < 30 && !release; i++) await tick();
    assert.ok(release);
    const board = (await f.manager.get(body)).boards[0];
    assert.equal(board.result.journeys.length, 1);
    assert.equal(board.result.search.provisional, true);
    assert.equal(board.coverage.completedWindows, 1);
    assert.equal(updates.filter(value => value.firstResultAt).length, 1);
    release();
    await idle(f.manager);
    assert.equal((await f.manager.get(body)).boards[0].result.search.provisional, undefined);
});

test('hourly cache reuses six overlapping intervals at rollover and never shares different required vias', async t => {
    const f = chunkFixture(t);
    await f.manager.get(body); await idle(f.manager);
    f.advance(2 * 3600000);
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfileChunk').length, 10);
    assert.equal([...f.manager.entries.values()][0].profile.profile.coverage.complete, true);
    assert.ok(f.manager.metrics.cacheHits >= 6);
    const canonical = routeBoardKey(normalizeRouteBoards(body, start)[0].request, version, start);
    const from = '2026-09-17T12:00:00.000Z', to = '2026-09-17T13:00:00.000Z';
    assert.notEqual(routeBoardFragmentKey(canonical.request, version, from, to),
        routeBoardFragmentKey({ ...canonical.request, via: ['BMS'] }, version, from, to));
    assert.notEqual(routeBoardFragmentKey(canonical.request, version, from, to),
        routeBoardFragmentKey(canonical.request, 'b'.repeat(64), from, to));
});

test('profile continuation yields saved-route admission to another cold card', async t => {
    const f = chunkFixture(t);
    await f.manager.get({ routes: [body.routes[0], { id: 'other', origin: 'ECR', destination: 'VIC' }] });
    await idle(f.manager);
    const first = f.calls.filter(call => call.method === 'routeBoardProfileChunk').slice(0, 2);
    assert.deepEqual(first.map(call => call.payload.request.origin), ['KTH', 'ECR']);
    assert.ok([...f.manager.entries.values()].every(entry => entry.profile.profile.coverage.complete));
});

test('saved-route telemetry includes outer admission waits once per queued stage', async t => {
    let release;
    let held = false;
    const updates = [];
    const f = chunkFixture(t, { options: { searchLog: { start: ({ request }) => ({
        update: value => updates.push({ origin: request.origin, ...value }), finish() {}
    }) } }, beforeCall: async method => {
        if (!held && method === 'routeBoardProfileChunk') {
            held = true;
            await new Promise(resolve => { release = resolve; });
        }
    } });
    await f.manager.get({ routes: [body.routes[0], { id: 'other', origin: 'ECR', destination: 'VIC' }] });
    for (let i = 0; i < 30 && !release; i++) await tick();
    f.advance(7000);
    release();
    await idle(f.manager);
    const waits = updates.filter(value => value.origin === 'ECR').map(value => value.metricsDelta?.admissionQueueMs ?? 0);
    assert.equal(waits.reduce((a, b) => a + b, 0), 7000);
    assert.ok(updates.filter(value => value.metricsDelta).every(value => Number.isFinite(value.metricsDelta.admissionQueueMs)));
});

test('a failed later hour preserves visible options and resumes without discarding completed fragments', async t => {
    let failed = false;
    const f = chunkFixture(t, { beforeCall: async (method, payload) => {
        if (method === 'routeBoardProfileChunk' && payload.chunk.from === '2026-09-17T13:00:00.000Z' && !failed) {
            failed = true;
            throw new PlannerError('SEARCH_TIMEOUT', 'Try again.', 504);
        }
    } });
    await f.manager.get(body); await idle(f.manager);
    const partial = (await f.manager.get(body)).boards[0];
    assert.equal(partial.error.code, 'SEARCH_TIMEOUT');
    assert.equal(partial.result.journeys.length, 1);
    assert.equal(partial.coverage.completedWindows, 1);
    assert.equal(f.records.size, 1, 'Only the successful hour is cached');
    f.advance(21000);
    await f.manager.get(body); await idle(f.manager);
    const finished = (await f.manager.get(body)).boards[0];
    assert.equal(finished.error, undefined);
    assert.equal(finished.coverage.complete, true);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfileChunk'
        && call.payload.chunk.from === '2026-09-17T12:00:00.000Z').length, 1);
});

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

test('a time-locked route board preserves its requested six-hour departure window', () => {
    const later = new Date(start + 6 * 60 * 60 * 1000).toISOString();
    const [route] = normalizeRouteBoards({ routes: [{ id: 'later', origin: 'KTH', destination: 'VIC', time: later }] }, start);
    const key = routeBoardKey(route.request, version, start, { timeLocked: route.timeLocked });
    assert.equal(route.timeLocked, true);
    assert.equal(route.request.time, later);
    assert.equal(key.request.time, later);
    assert.equal(key.request.windowMinutes, 360);
    assert.notEqual(key.key, routeBoardKey(route.request, version, start).key);
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
    assert.equal(busy.boards[0].error, undefined);
    assert.equal(busy.boards[0].status, 'queued');
    assert.equal(busy.boards[0].progress.phase, 'queued');
    f.advance(61000); f.manager.prune();
    assert.equal(f.calls[0].options.signal.aborted, false);
    f.advance(60000); f.manager.prune();
    assert.equal(f.calls[0].options.signal.aborted, true);
    resolve({ profile: { version, searchTruncated: false } });
    await idle(f.manager);
});

test('all eight routes from one client progress automatically beyond its two admitted slots', async t => {
    const f = fixture(t);
    const batch = { routes: Array.from({ length: 8 }, (_, index) => ({ id: `route-${index}`, origin: `A0${index}`, destination: 'DST' })) };
    const response = await f.manager.get(batch, { client: 'one-device', network: 'home' });
    assert.ok(response.boards.every(board => board.status === 'queued' && board.error === undefined));
    assert.ok(response.boards.every(board => board.progress.queuedAt === new Date(start).toISOString()));
    assert.equal(f.manager.queue.length + Number(Boolean(f.manager.active)), 2);
    await idle(f.manager);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfile').length, 8);
    assert.equal(f.calls.filter(call => call.method === 'routeBoardRefresh').length, 8);
    assert.ok([...f.manager.entries.values()].every(entry => entry.results.has('apply')));
    assert.equal([...f.manager.entries.values()].filter(entry => entry.waiting).length, 0);
});

test('slow recurring refreshes cannot starve a third route polled in the same fixed order', async t => {
    const deferred = [];
    const f = fixture(t, { call: (method, payload, options) => new Promise(resolve => {
        options.onStart();
        deferred.push({ method, payload, resolve });
    }) });
    const batch = { routes: ['AAA', 'BBB', 'CCC'].map(origin => ({ id: origin, origin, destination: 'DST' })) };
    const poll = () => f.manager.get(batch, { client: 'one-device', network: 'home' });
    const settle = async () => { for (let i = 0; i < 8; i++) await tick(); };
    await poll(); await settle();
    for (let step = 0; step < 12; step++) {
        const work = deferred.shift();
        assert.ok(work, `Expected automatic work at step ${step}`);
        f.advance(45000);
        await poll();
        work.resolve(work.method === 'routeBoardProfile'
            ? { profile: { version, request: work.payload.request } }
            : { journeys: [], dataset: { version }, live: { mode: 'apply', status: 'unavailable', warnings: [] }, warnings: [] });
        await settle();
        const state = await poll();
        assert.ok(state.boards.every(board => !board.error));
        assert.ok(f.manager.queue.length + Number(Boolean(f.manager.active)) <= 2);
    }
    assert.deepEqual(f.calls.filter(call => call.method === 'routeBoardProfile').map(call => call.payload.request.origin), ['AAA', 'BBB', 'CCC']);
    assert.deepEqual(f.calls.filter(call => call.method === 'routeBoardRefresh').slice(0, 9)
        .map(call => call.payload.profile.request.origin), ['AAA', 'BBB', 'CCC', 'AAA', 'BBB', 'CCC', 'AAA', 'BBB', 'CCC']);
    f.manager.close();
    for (const work of deferred) work.resolve({ journeys: [] });
    await settle();
});

test('older refreshes keep their place when new cold routes keep arriving', async t => {
    const f = fixture(t);
    await f.manager.get(body); await idle(f.manager);
    f.advance(31000);
    let release;
    const original = f.service.call;
    f.service.call = (method, payload, options) => new Promise(resolve => { release = () => original(method, payload, options).then(resolve); });
    await f.manager.get({ routes: [{ id: 'blocker', origin: 'BLK', destination: 'DST' }] }, { client: 'blocking-client' });
    for (let i = 0; i < 8; i++) await tick();
    await f.manager.get(body, { client: 'refresh-client' });
    const old = f.manager.outstanding().find(work => work.entry.request.origin === 'KTH');
    f.advance(1000);
    await f.manager.get({ routes: ['AAA', 'BBB', 'CCC'].map(origin => ({ id: origin, origin, destination: 'DST' })) }, { client: 'new-client' });
    const outstanding = f.manager.outstanding();
    assert.ok(outstanding.indexOf(old) < outstanding.findIndex(work => work.entry.request.origin === 'AAA'));
    f.service.call = original;
    release();
    await idle(f.manager);
    assert.ok(f.calls.findIndex(call => call.method === 'routeBoardRefresh' && call.payload.profile.request.origin === 'KTH')
        < f.calls.findIndex(call => call.method === 'routeBoardProfile' && call.payload.request.origin === 'AAA'));
});

test('progress reflects worker execution rather than queue time and carries real window counts', async t => {
    const deferred = [];
    const f = fixture(t, { call: (method, payload, options) => new Promise(resolve => deferred.push({ method, payload, options, resolve })) });
    await f.manager.get(body);
    for (let i = 0; i < 8; i++) await tick();
    f.advance(7000);
    const queued = (await f.manager.get(body)).boards[0].progress;
    assert.equal(queued.phase, 'queued');
    assert.equal(queued.startedAt, undefined);
    assert.equal(queued.queuePosition, 1);
    assert.equal(queued.queuedAt, new Date(start).toISOString());
    const work = deferred.shift();
    work.options.onStart();
    work.options.onProgress({ phase: 'searching', completedWindows: 2, totalWindows: 8 });
    const running = (await f.manager.get(body)).boards[0].progress;
    assert.deepEqual(running, { phase: 'searching', queuedAt: new Date(start).toISOString(),
        startedAt: new Date(start + 7000).toISOString(), completedWindows: 2, totalWindows: 8 });
    work.resolve({ profile: { version, request: work.payload.request } });
    for (let i = 0; i < 8; i++) await tick();
    const refresh = deferred.shift();
    refresh.options.onStart();
    refresh.options.onProgress('live');
    assert.equal((await f.manager.get(body)).boards[0].progress.phase, 'live');
    refresh.resolve({ journeys: [], dataset: { version }, warnings: [] });
    await idle(f.manager);
    assert.equal((await f.manager.get(body)).boards[0].progress, undefined);
});

test('genuine failure exposes retry state and automatically retries after the cooldown', async t => {
    let attempts = 0;
    const f = fixture(t, { call: async (method, payload) => {
        if (method === 'routeBoardProfile') {
            if (++attempts === 1) throw new PlannerError('SEARCH_TIMEOUT', 'Try again.', 504);
            return { profile: { version, request: payload.request } };
        }
        return { journeys: [], dataset: { version }, warnings: [] };
    } });
    await f.manager.get(body); await idle(f.manager);
    const failed = (await f.manager.get(body)).boards[0];
    assert.equal(failed.status, 'unavailable');
    assert.equal(failed.error.code, 'SEARCH_TIMEOUT');
    assert.equal(failed.progress.phase, 'retrying');
    f.advance(21000);
    // This is the sweep/completion path, with no new client submission.
    f.manager.prune(); f.manager.admitWaiting(); f.manager.pump();
    await idle(f.manager);
    assert.equal(attempts, 2);
    const ready = (await f.manager.get(body)).boards[0];
    assert.equal(ready.status, 'ready');
    assert.equal(ready.error, undefined);
});

test('a mode change during preparation refreshes the requested mode without an obsolete live replan', async t => {
    let resolveProfile;
    const f = fixture(t, { call: async (method, payload) => {
        if (method === 'routeBoardProfile') return new Promise(resolve => { resolveProfile = () => resolve({ profile: { version, request: payload.request } }); });
        return { journeys: [], dataset: { version }, live: { mode: payload.realtime, status: 'unavailable', warnings: [] }, warnings: [], needsReplan: false };
    } });
    await f.manager.get(body);
    for (let i = 0; i < 8; i++) await tick();
    const ignored = { routes: [{ ...body.routes[0], realtime: 'ignore' }] };
    await f.manager.get(ignored);
    resolveProfile();
    await idle(f.manager);
    assert.deepEqual(f.calls.filter(call => call.method === 'routeBoardRefresh').map(call => call.payload.realtime), ['ignore']);
    assert.equal((await f.manager.get(ignored)).boards[0].result.live.mode, 'ignore');
});

test('a failed active live replan retries as a cheap refresh after switching to scheduled times', async t => {
    let rejectReplan;
    const f = fixture(t, { call: async (method, payload) => {
        if (method === 'routeBoardProfile') return { profile: { version, request: payload.request } };
        if (method === 'routeBoardReplan') return new Promise((resolve, reject) => { rejectReplan = reject; });
        return { journeys: [], dataset: { version }, live: { mode: payload.realtime, status: 'unavailable', warnings: [] }, warnings: [],
            needsReplan: payload.realtime === 'apply', disruptionFingerprint: 'delay' };
    } });
    await f.manager.get(body);
    for (let i = 0; i < 8; i++) await tick();
    assert.equal(typeof rejectReplan, 'function');
    const ignored = { routes: [{ ...body.routes[0], realtime: 'ignore' }] };
    await f.manager.get(ignored);
    rejectReplan(new PlannerError('SEARCH_TIMEOUT', 'Try again.', 504));
    await idle(f.manager);
    f.advance(21000);
    f.manager.prune(); f.manager.admitWaiting(); f.manager.pump();
    await idle(f.manager);
    assert.deepEqual(f.calls.filter(call => call.method === 'routeBoardReplan').map(call => call.payload.realtime), ['apply']);
    assert.equal(f.calls.at(-1).method, 'routeBoardRefresh');
    assert.equal(f.calls.at(-1).payload.realtime, 'ignore');
    assert.equal((await f.manager.get(ignored)).boards[0].result.live.mode, 'ignore');
});

test('obsolete time buckets release active and deferred interest immediately', async t => {
    const f = fixture(t, { call: (method, payload, options) => new Promise((resolve, reject) => {
        options.signal.addEventListener('abort', () => reject(new PlannerError('SEARCH_CANCELLED', 'Cancelled.', 499)), { once: true });
    }) });
    const batch = { routes: ['AAA', 'BBB', 'CCC'].map(origin => ({ id: origin, origin, destination: 'DST' })) };
    await f.manager.get(batch, { client: 'one-device' });
    for (let i = 0; i < 8; i++) await tick();
    const old = f.calls[0];
    const bucket = [...f.manager.entries.values()][0].bucket;
    f.advance(2 * 3600000);
    f.manager.prune();
    assert.equal(old.options.signal.aborted, true);
    assert.equal(f.manager.entries.size, 0);
    assert.equal(f.manager.queue.length, 0);
    await f.manager.get(batch, { client: 'one-device' });
    for (let i = 0; i < 8; i++) await tick();
    assert.ok(f.calls.length > 1, 'New bucket starts without the old two-minute lease');
    assert.ok([...f.manager.entries.values()].every(entry => entry.bucket !== bucket));
    assert.ok(f.manager.queue.length + Number(Boolean(f.manager.active)) <= 2);
    f.manager.close(); await tick();
});

test('memory pressure releases idle queued profiles without losing their age or starving a cold route', async t => {
    const f = fixture(t);
    const request = origin => ({ routes: [{ id: origin, origin, destination: 'DST' }] });
    for (const origin of ['AAA', 'BBB']) { await f.manager.get(request(origin)); await idle(f.manager); }
    f.manager.maxProfileBytes = [...f.manager.entries.values()].reduce((sum, entry) => sum + entry.profileBytes, 0);
    const original = f.service.call;
    let releaseCold;
    f.service.call = (method, payload, options) => method === 'routeBoardProfile' && payload.request.origin === 'CCC'
        ? new Promise(resolve => { releaseCold = () => original(method, payload, options).then(resolve); })
        : original(method, payload, options);
    await f.manager.get(request('CCC'));
    for (let i = 0; i < 8; i++) await tick();
    f.advance(31000);
    await f.manager.get({ routes: [...request('AAA').routes, ...request('BBB').routes] });
    const queued = f.manager.outstanding().filter(work => work.entry.request.origin !== 'CCC');
    assert.equal(queued.length, 2);
    const originalOrder = queued.map(work => [work.entry.key, work.queuedAt, work.order]);
    releaseCold();
    await idle(f.manager);
    assert.equal(f.manager.metrics.failures, 0, 'The cold profile must not fail because all eviction candidates are queued');
    assert.equal(f.calls.filter(call => call.method === 'routeBoardProfile').length, 3, 'Evicted scheduled profiles reload from cache, not another national search');
    assert.ok([...f.manager.entries.values()].every(entry => entry.results.has('apply')));
    assert.ok([...f.manager.entries.values()].reduce((sum, entry) => sum + (entry.profileBytes ?? 0)
        + (entry.refreshProfileBytes ?? 0), 0) <= f.manager.maxProfileBytes);
    for (const [key, queuedAt, order] of originalOrder) {
        const work = queued.find(value => value.entry.key === key);
        assert.equal(work.queuedAt, queuedAt);
        assert.equal(work.order, order);
        assert.ok(f.manager.entries.has(key), 'Queued interest must survive profile eviction');
    }
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
    registerPlannerRoutes(app, { service: f.service, routeBoards: f.manager, searchLog: noOpPlannerSearchLog });
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
    const service = new PlannerService({ ...plannerConfig({}), workerCount: 1, timeoutMs: 3000 }, { workerURL: pathToFileURL(filename) });
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
    const cache = new RouteBoardCache({ collection: async () => collection, now: () => start, maxEntries: 2, ensureIndex: true });
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
    assert.equal(responses[63].boards[0].error, undefined);
    assert.equal(responses[63].boards[0].progress.phase, 'queued');
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
    // Node timers can fire slightly before their nominal fractional deadline.
    await new Promise(resolve => setTimeout(resolve, 5));
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
    const service = { supportsProfileChunks: true, status: () => engine.status(), call: (method, payload, options) => {
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
    assert.equal(methods.filter(method => method === 'routeBoardProfileChunk').length, 8);
    assert.equal(methods.filter(method => method === 'routeBoardProfile').length, 0);
});
