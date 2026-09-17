import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import http from 'node:http';
import { PlannerError, encodeCursor, normalizeRequest } from '../lib/planner/contract.js';
import { PlannerSearchJobs } from '../lib/planner/search-jobs.js';
import { PlannerRouteBoards } from '../lib/planner/route-boards.js';
import { registerPlannerRoutes } from '../lib/planner-routes.js';

const version = 'a'.repeat(64);
const start = Date.parse('2026-09-17T12:10:00Z');
const request = { origin: 'KTH', destination: 'VIC', time: new Date(start).toISOString(), timeType: 'departAfter' };
const body = { routes: [{ id: 'saved-route', origin: 'KTH', destination: 'VIC' }] };
const tick = () => new Promise(resolve => setImmediate(resolve));
function recorder() {
    const rows = [];
    return { rows, start(input) {
        const row = { cacheStatus: 'unknown', ...input, status: 'pending' };
        rows.push(row);
        let finished = false;
        const update = fields => {
            const previous = row.cacheStatus;
            Object.assign(row, fields);
            if (previous === 'miss') row.cacheStatus = 'miss';
        };
        return { update(fields) { if (!finished) update(fields); },
            finish(fields) { if (!finished) { finished = true; update(fields); } } };
    } };
}
async function idle(manager) {
    for (let i = 0; i < 100 && (manager.active || manager.queue.length); i++) await tick();
    assert.equal(manager.active, null);
    assert.equal(manager.queue.length, 0);
}
async function web(t, service, searchLog) {
    const app = express();
    registerPlannerRoutes(app, { service, searchLog });
    const listener = app.listen(0, '127.0.0.1');
    await new Promise(resolve => listener.once('listening', resolve));
    t.after(async () => { service.searchJobs.close(); service.routeBoards.close(); await new Promise(resolve => listener.close(resolve)); });
    const base = `http://127.0.0.1:${listener.address().port}/api/v3/journey-planner`;
    return { base, send: (value, path = '/search') => fetch(`${base}${path}`, { method: 'POST',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(value) }) };
}

test('synchronous searches log outcomes, actual cache state, cursors and parser rejections without changing responses', async t => {
    const searchLog = recorder();
    const response = { journeys: [{ id: 'trip' }], dataset: { version } };
    const service = { search: async (value, options) => {
        if (value.origin === 'BAD') throw new PlannerError('INVALID_STATION', 'Unknown station.');
        options.onStart(); options.onTelemetry({ cacheStatus: 'hit', datasetVersion: version });
        return response;
    } };
    const server = await web(t, service, searchLog);
    assert.deepEqual(await (await server.send(request)).json(), response);
    const cursor = encodeCursor(normalizeRequest(request), version);
    assert.deepEqual(await (await server.send({ cursor })).json(), response);
    assert.equal((await server.send({ ...request, origin: 'BAD' })).status, 400);
    assert.equal((await fetch(`${server.base}/search`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{bad' })).status, 400);
    assert.equal((await server.send({ padding: 'x'.repeat(17000) })).status, 413);
    assert.equal((await fetch(`${server.base}/search-jobs`, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: 'bad' })).status, 415);
    assert.equal(searchLog.rows.length, 6);
    assert.deepEqual(searchLog.rows.map(row => row.status), ['success', 'success', 'fail', 'fail', 'fail', 'fail']);
    assert.equal(searchLog.rows[0].cacheStatus, 'hit');
    assert.equal(searchLog.rows[0].resultCount, 1);
    assert.equal(searchLog.rows[1].request.origin, 'KTH');
    assert.equal(searchLog.rows[1].request.cursor, undefined);
    assert.equal(searchLog.rows[4].errorCode, 'REQUEST_TOO_LARGE');
    assert.equal(searchLog.rows[5].source, 'search-job');
});

test('disconnecting a synchronous search finishes its observation as cancelled', async t => {
    const searchLog = recorder();
    let admitted;
    const started = new Promise(resolve => { admitted = resolve; });
    const service = { search: (value, { signal }) => new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(new PlannerError('SEARCH_CANCELLED', 'Cancelled.', 499)), { once: true });
        admitted();
    }) };
    const server = await web(t, service, searchLog);
    const client = http.request(`${server.base}/search`, { method: 'POST', headers: { 'Content-Type': 'application/json' } });
    client.on('error', () => {});
    client.end(JSON.stringify(request));
    await started;
    client.destroy();
    for (let i = 0; i < 20 && searchLog.rows[0]?.status === 'pending'; i++) await tick();
    assert.equal(searchLog.rows.length, 1);
    assert.equal(searchLog.rows[0].status, 'other');
    assert.equal(searchLog.rows[0].outcome, 'cancelled');
});

function jobsFixture(t, overrides = {}) {
    let now = start;
    const searchLog = recorder();
    const calls = [];
    const service = { status: async () => ({ available: true, dataset: { version } }),
        call: (method, payload, options) => new Promise((resolve, reject) => {
            options.onStart();
            calls.push({ resolve, reject, options });
            options.signal.addEventListener('abort', () => reject(new PlannerError('SEARCH_CANCELLED', 'Cancelled.', 499)), { once: true });
        }) };
    const jobs = new PlannerSearchJobs(service, { now: () => now, searchLog, ...overrides });
    t.after(() => jobs.close());
    return { jobs, service, calls, searchLog, advance: ms => { now += ms; jobs.prune(); } };
}

test('async idempotent retries and polls are deduplicated while coalesced callers retain independent results', async t => {
    const f = jobsFixture(t);
    const [first, retry] = await Promise.all([f.jobs.submit(request, { client: 'one', idempotencyKey: 'same-key' }),
        f.jobs.submit(request, { client: 'one', idempotencyKey: 'same-key' })]);
    assert.equal(first.id, retry.id);
    const second = await f.jobs.submit(request, { client: 'two' });
    await tick();
    f.calls[0].options.onTelemetry({ cacheStatus: 'miss', datasetVersion: version });
    f.jobs.get(first.id); f.jobs.get(second.id);
    f.advance(500);
    f.jobs.cancel(first.id);
    f.calls[0].resolve({ journeys: [{ id: 'trip' }], dataset: { version } });
    await tick();
    assert.equal(f.calls.length, 1);
    assert.equal(f.searchLog.rows.length, 2);
    assert.deepEqual(f.searchLog.rows.map(row => row.status), ['other', 'success']);
    assert.deepEqual(f.searchLog.rows.map(row => row.coalesced), [false, true]);
    assert.ok(f.searchLog.rows.every(row => row.cacheStatus === 'miss'));
    assert.equal(f.searchLog.rows[1].finishedAt - f.searchLog.rows[1].startedAt, 500);
    f.jobs.cancel(second.id);
    assert.equal(f.searchLog.rows[1].status, 'success', 'Cancelling a completed lease must not rewrite the returned outcome');
});

test('async rejected, expired, failed and closed searches all terminate their records', async t => {
    const f = jobsFixture(t, { leaseMs: 1000, maxPerClient: 1 });
    const first = await f.jobs.submit(request);
    await tick();
    await assert.rejects(f.jobs.submit({ ...request, destination: 'ECR' }), { code: 'SEARCH_BUSY' });
    assert.equal(f.searchLog.rows[1].outcome, 'rejected');
    assert.equal(f.searchLog.rows[1].errorCode, 'SEARCH_BUSY');
    f.advance(1001);
    assert.throws(() => f.jobs.get(first.id), { code: 'SEARCH_EXPIRED' });
    await tick();
    assert.equal(f.searchLog.rows[0].outcome, 'expired');
    await f.jobs.submit(request); await tick();
    f.calls[1].reject(new PlannerError('SEARCH_TIMEOUT', 'Timed out.', 504)); await tick();
    assert.equal(f.searchLog.rows[2].status, 'fail');
    await f.jobs.submit(request); await tick(); f.jobs.close();
    assert.equal(f.searchLog.rows[3].outcome, 'closed');
    assert.ok(f.searchLog.rows.every(row => row.status !== 'pending'));
});

test('a worker-capacity retry does not create a second async search record', async t => {
    const f = jobsFixture(t);
    const original = f.service.call;
    let busy = true;
    f.service.call = (...args) => busy ? Promise.reject(new PlannerError('SEARCH_BUSY', 'Busy.', 429)) : original(...args);
    await f.jobs.submit(request); await tick();
    assert.equal(f.searchLog.rows.length, 1);
    assert.equal(f.searchLog.rows[0].status, 'pending');
    busy = false;
    await new Promise(resolve => setTimeout(resolve, 1100));
    f.calls[0].resolve({ journeys: [] }); await tick();
    assert.equal(f.searchLog.rows.length, 1);
    assert.equal(f.searchLog.rows[0].outcome, 'empty');
});

function boardsFixture(t, options = {}) {
    let now = start;
    const searchLog = recorder();
    const records = new Map();
    const cache = { get: async key => records.get(key), set: async (key, value) => records.set(key, value) };
    const service = { status: async () => ({ available: true, dataset: { version } }),
        call: async (method, payload, execution) => {
            execution.onStart();
            if (options.call) return options.call(method, payload, execution);
            if (method === 'routeBoardProfile') return { profile: { version, request: payload.request, journeys: [] } };
            return { journeys: [{ departure: new Date(now + 600000).toISOString(), legs: [] }], dataset: { version } };
        } };
    const manager = new PlannerRouteBoards(service, { now: () => now, cache, searchLog });
    t.after(() => manager.close());
    return { manager, service, searchLog, cache, advance: ms => { now += ms; }, now: () => now };
}

test('saved-route load, profile and live stages make one row; later refreshes and restart cache hits are distinct', async t => {
    const f = boardsFixture(t);
    await f.manager.get(body);
    await f.manager.get(body, { client: 'another-client' });
    await idle(f.manager);
    assert.equal(f.searchLog.rows.length, 1);
    assert.equal(f.searchLog.rows[0].source, 'saved-route');
    assert.equal(f.searchLog.rows[0].status, 'success');
    assert.equal(f.searchLog.rows[0].cacheStatus, 'miss');
    f.advance(20000);
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.searchLog.rows.length, 1, 'A poll serving a current board does not launch a new search');
    f.advance(11000);
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.searchLog.rows.length, 2);
    assert.equal(f.searchLog.rows[1].source, 'saved-refresh');
    assert.equal(f.searchLog.rows[1].cacheStatus, 'hit');
    f.manager.close();
    const restarted = new PlannerRouteBoards(f.service, { cache: f.cache, searchLog: f.searchLog, now: f.now });
    t.after(() => restarted.close());
    await restarted.get(body); await idle(restarted);
    assert.equal(f.searchLog.rows.length, 3);
    assert.equal(f.searchLog.rows[2].source, 'saved-route');
    assert.equal(f.searchLog.rows[2].cacheStatus, 'hit');
});

test('saved disruption replans are distinct searches and expired queued interest is logged', async t => {
    const f = boardsFixture(t, { call: async (method, payload) => {
        if (method === 'routeBoardProfile') return { profile: { version, request: payload.request, journeys: [] } };
        return { journeys: [], dataset: { version }, needsReplan: method === 'routeBoardRefresh', disruptionFingerprint: 'cancelled' };
    } });
    await f.manager.get(body); await idle(f.manager);
    assert.deepEqual(f.searchLog.rows.map(row => row.source), ['saved-route', 'saved-replan']);
    assert.ok(f.searchLog.rows.every(row => row.status === 'success' && row.cacheStatus === 'miss'));
    const waiting = boardsFixture(t, { call: (method, payload, { signal }) => new Promise((resolve, reject) => {
        signal.addEventListener('abort', () => reject(new PlannerError('SEARCH_CANCELLED', 'Cancelled.', 499)), { once: true });
    }) });
    await waiting.manager.get({ routes: ['AAA', 'BBB', 'CCC'].map(origin => ({ id: origin, origin, destination: 'VIC' })) });
    await tick();
    waiting.advance(120001); waiting.manager.prune(); await tick();
    assert.equal(waiting.searchLog.rows.length, 3);
    assert.ok(waiting.searchLog.rows.every(row => row.status === 'other' && row.outcome === 'expired'));
    assert.equal(waiting.searchLog.rows[1].cacheStatus, 'unknown', 'A cancelled queued route has made no cache decision');
});

test('saved-route capacity retries retain their logical search and original start time', async t => {
    let busy = true;
    const f = boardsFixture(t, { call: async (method, payload) => {
        if (busy) throw new PlannerError('SEARCH_BUSY', 'Busy.', 429);
        if (method === 'routeBoardProfile') return { profile: { version, request: payload.request, journeys: [] } };
        return { journeys: [], dataset: { version } };
    } });
    await f.manager.get(body); await idle(f.manager);
    assert.equal(f.searchLog.rows.length, 1);
    assert.equal(f.searchLog.rows[0].status, 'pending');
    busy = false; f.advance(5001);
    f.manager.prune(); f.manager.admitWaiting(); f.manager.pump(); await idle(f.manager);
    assert.equal(f.searchLog.rows.length, 1);
    assert.equal(f.searchLog.rows[0].status, 'success');
    assert.equal(f.searchLog.rows[0].finishedAt - f.searchLog.rows[0].startedAt, 5001);
});

test('a queued disruption replan overridden to scheduled times is superseded by a correctly labelled refresh', async t => {
    const f = boardsFixture(t);
    await f.manager.get(body); await idle(f.manager);
    const entry = [...f.manager.entries.values()][0];
    f.manager.enqueue(entry, 'replan', 'apply', { client: 'anonymous', network: 'anonymous' });
    assert.equal(f.searchLog.rows[1].cacheStatus, 'unknown');
    await f.manager.get({ routes: [{ ...body.routes[0], realtime: 'ignore' }] }); await idle(f.manager);
    assert.equal(f.searchLog.rows.length, 3);
    assert.equal(f.searchLog.rows[1].source, 'saved-replan');
    assert.equal(f.searchLog.rows[1].outcome, 'superseded');
    assert.equal(f.searchLog.rows[1].cacheStatus, 'unknown');
    assert.equal(f.searchLog.rows[2].source, 'saved-refresh');
    assert.equal(f.searchLog.rows[2].request.realtime, 'ignore');
    assert.equal(f.searchLog.rows[2].status, 'success');
    assert.equal(f.searchLog.rows[2].cacheStatus, 'hit');
});
