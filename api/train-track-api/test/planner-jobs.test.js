import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { PlannerSearchJobs } from '../lib/planner/search-jobs.js';
import { PlannerError, normalizeRequest } from '../lib/planner/contract.js';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';
import { registerPlannerRoutes } from '../lib/planner-routes.js';
import { noOpPlannerSearchLog } from '../lib/planner-search-log.js';

const version = 'a'.repeat(64);
const request = { origin: 'ECR', destination: 'BYM', time: '2026-09-16T18:09:00+01:00', timeType: 'arriveBy' };
const tick = () => new Promise(resolve => setImmediate(resolve));
function fixture(t, overrides = {}) {
    let now = 0;
    const calls = [];
    const service = { config: { ...plannerConfig({}), maxSearchJobs: 2 },
        status: async () => ({ available: true, dataset: { version } }),
        call(method, payload, options) {
            options.onStart();
            return new Promise((resolve, reject) => {
                calls.push({ method, payload, options, resolve, reject });
                options.signal.addEventListener('abort', () => reject(new PlannerError('SEARCH_CANCELLED', 'Cancelled', 499)), { once: true });
            });
        } };
    const jobs = new PlannerSearchJobs(service, { now: () => now, ...overrides });
    t.after(() => jobs.close());
    return { jobs, service, calls, advance: ms => { now += ms; jobs.prune(); } };
}

test('queued jobs return immediately, pin versions and give processing its own extended budget', async t => {
    const { jobs, calls } = fixture(t);
    const first = await jobs.submit(request, { client: 'one', idempotencyKey: 'search-one' });
    const second = await jobs.submit({ ...request, time: '2026-09-17T18:09:00+01:00' }, { client: 'two' });
    await tick();
    assert.equal(jobs.get(first.id).status, 'running');
    assert.equal(jobs.get(second.id).status, 'queued');
    assert.equal(jobs.get(second.id).queuePosition, 2);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].payload.version, version);
    assert.deepEqual(calls[0].payload.request, normalizeRequest(request));
    assert.deepEqual(calls[0].options.execution, { timeoutMs: 600000, maxOperations: 1000000000, cpuDutyCycle: 1 });
    calls[0].options.onProgress({ phase: 'preparing' });
    assert.equal(jobs.get(first.id).phase, 'preparing');
    const result = { journeys: [{ id: 'journey' }] };
    calls[0].resolve(result);
    await tick();
    assert.deepEqual(jobs.get(first.id).result, result);
    assert.equal(jobs.get(second.id).status, 'running');
    assert.equal(calls.length, 2);
});

test('I/O-capable service admits two bounded operations and cancellation frees the next place', async t => {
    const calls = [];
    const service = { supportsIOYield: true, config: plannerConfig({}),
        status: async () => ({ available: true, dataset: { version } }),
        call(method, payload, options) {
            options.onStart();
            return new Promise((resolve, reject) => {
                calls.push({ resolve, options });
                options.signal.addEventListener('abort', () => reject(new PlannerError('SEARCH_CANCELLED', 'Cancelled', 499)), { once: true });
            });
        } };
    const jobs = new PlannerSearchJobs(service);
    t.after(() => jobs.close());
    const submitted = [];
    for (const [index, destination] of ['BYM', 'VIC', 'INV'].entries()) {
        submitted.push(await jobs.submit({ ...request, destination }, { client: `client-${index}` }));
    }
    await tick();
    assert.equal(calls.length, 2);
    assert.equal(jobs.inFlight.size, 2);
    assert.equal(jobs.get(submitted[2].id).queuePosition, 3);
    jobs.cancel(submitted[0].id);
    await tick();
    assert.equal(calls.length, 3);
    assert.equal(calls[1].options.signal.aborted, false);
    assert.equal(jobs.get(submitted[2].id).status, 'running');
    calls[1].resolve({ journeys: [] });
    calls[2].resolve({ journeys: [] });
    await tick();
    assert.equal(jobs.inFlight.size, 0);
});

test('idempotent retries and shared work retain independent cancellation leases', async t => {
    const { jobs, calls } = fixture(t);
    const [first, retry] = await Promise.all([jobs.submit(request, { client: 'one', idempotencyKey: 'same-key' }),
        jobs.submit(request, { client: 'one', idempotencyKey: 'same-key' })]);
    assert.equal(first.id, retry.id);
    const shared = await jobs.submit(request, { client: 'two' });
    await tick();
    assert.notEqual(first.id, shared.id);
    assert.equal(calls.length, 1);
    jobs.cancel(first.id);
    assert.equal(jobs.get(first.id).status, 'cancelled');
    assert.equal(calls[0].options.signal.aborted, false);
    await assert.rejects(jobs.submit({ ...request, destination: 'VIC' }, { client: 'one', idempotencyKey: 'same-key' }), { status: 409 });
    jobs.cancel(shared.id);
    assert.equal(calls[0].options.signal.aborted, true);
});

test('overlapping admission failures share one backoff timer and close clears it', async t => {
    const rejections = [];
    const service = { supportsIOYield: true, config: plannerConfig({}),
        status: async () => ({ available: true, dataset: { version } }),
        call: () => new Promise((resolve, reject) => rejections.push(reject)) };
    const jobs = new PlannerSearchJobs(service);
    t.after(() => jobs.close());
    await jobs.submit(request, { client: 'one' });
    await jobs.submit({ ...request, destination: 'VIC' }, { client: 'two' });
    await tick();
    assert.equal(rejections.length, 2);
    rejections[0](new PlannerError('SEARCH_BUSY', 'Busy', 429));
    await tick();
    const timer = jobs.retryTimer;
    assert.ok(timer);
    rejections[1](new PlannerError('SEARCH_BUSY', 'Busy', 429));
    await tick();
    assert.equal(jobs.retryTimer, timer);
    assert.equal(jobs.queue.length, 2);
    jobs.close();
    assert.equal(jobs.retryTimer, null);
});

test('admission is globally bounded and per-client/network limits leave room for other users', async t => {
    const { jobs } = fixture(t, { maxPerClient: 1, maxPerNetwork: 1 });
    await jobs.submit(request, { client: 'one', network: 'network-a' });
    await assert.rejects(jobs.submit(request, { client: 'one', network: 'network-b' }), { code: 'SEARCH_BUSY' });
    await assert.rejects(jobs.submit(request, { client: 'two', network: 'network-a' }), { code: 'SEARCH_BUSY' });
    await jobs.submit({ ...request, destination: 'VIC' }, { client: 'two', network: 'network-b' });
    await assert.rejects(jobs.submit({ ...request, destination: 'INV' }, { client: 'three' }), { code: 'SEARCH_BUSY' });
});

test('polling renews only its lease; abandoned queued and running searches are cancelled', async t => {
    const { jobs, calls, advance } = fixture(t, { leaseMs: 1000 });
    const first = await jobs.submit(request, { client: 'one' });
    const abandoned = await jobs.submit({ ...request, destination: 'VIC' }, { client: 'two' });
    await tick();
    advance(700);
    jobs.get(first.id);
    advance(400);
    assert.throws(() => jobs.get(abandoned.id), { code: 'SEARCH_EXPIRED' });
    assert.equal(jobs.get(first.id).status, 'running');
    advance(1001);
    assert.equal(calls[0].options.signal.aborted, true);
    assert.throws(() => jobs.get(first.id), { code: 'SEARCH_EXPIRED' });
    await tick();
    assert.equal(calls.length, 1);
});

test('failed jobs can be retried with a new key; completed leases expire and storage stays bounded', async t => {
    const { jobs, calls, advance } = fixture(t, { maxLeases: 2, resultMs: 500 });
    const first = await jobs.submit(request, { client: 'one', idempotencyKey: 'failure-key' });
    await tick();
    calls[0].reject(new PlannerError('DATASET_UNAVAILABLE', 'Restarted', 503));
    await tick();
    assert.equal(jobs.get(first.id).error.code, 'DATASET_UNAVAILABLE');
    assert.equal((await jobs.submit(request, { client: 'one', idempotencyKey: 'failure-key' })).id, first.id);
    const next = await jobs.submit(request, { client: 'one', idempotencyKey: 'retry-key' });
    await tick();
    assert.equal(calls.length, 2);
    calls[1].resolve({ journeys: [] });
    await tick();
    assert.equal(jobs.get(next.id).status, 'completed');
    await jobs.submit(request, { client: 'two' });
    assert.ok(jobs.leases.size <= 2);
    advance(501);
    assert.throws(() => jobs.get(next.id), { code: 'SEARCH_EXPIRED' });
});

test('HTTP job lifecycle is additive, uncached, parser-bounded and survives a closed submit connection', async t => {
    const { service, calls } = fixture(t);
    const app = express();
    registerPlannerRoutes(app, { service, searchLog: noOpPlannerSearchLog });
    t.after(() => service.searchJobs.close());
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    const base = `http://127.0.0.1:${server.address().port}/api/v3/journey-planner`;
    const submit = await fetch(`${base}/search-jobs`, { method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Idempotency-Key': 'http-search', 'X-Planner-Client': 'test-client' }, body: JSON.stringify(request) });
    assert.equal(submit.status, 202);
    assert.equal(submit.headers.get('cache-control'), 'no-store');
    const job = await submit.json();
    assert.match(job.id, /^[a-f0-9-]{36}$/);
    assert.equal(calls[0].options.signal.aborted, false);
    calls[0].resolve({ journeys: [] });
    await tick();
    const poll = await fetch(`${base}/search-jobs/${job.id}`);
    assert.equal(poll.status, 200);
    assert.equal((await poll.json()).status, 'completed');
    assert.equal((await fetch(`${base}/search-jobs/${job.id}`, { method: 'DELETE' })).status, 204);
    assert.equal((await (await fetch(`${base}/search-jobs/${job.id}`)).json()).status, 'cancelled');
    assert.equal((await fetch(`${base}/search-jobs/unknown`)).status, 410);
    const large = await fetch(`${base}/search-jobs`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ padding: 'x'.repeat(17000) }) });
    assert.equal(large.status, 413);
});

test('worker progress does not settle a request and queue waiting does not consume its execution allowance', async t => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'planner-job-worker-'));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    const filename = path.join(directory, 'worker.mjs');
    await fs.writeFile(filename, `import { parentPort } from 'node:worker_threads';
        parentPort.on('message', message => {
            parentPort.postMessage({ id: message.id, progress: { phase: 'searching' } });
            parentPort.postMessage({ id: message.id, telemetry: { cacheStatus: 'hit' } });
            setTimeout(() => parentPort.postMessage({ id: message.id, result: { done: true } }), message.payload.delay);
        });`);
    const service = new PlannerService({ ...plannerConfig({}), workerCount: 1, timeoutMs: 2000 }, { workerURL: pathToFileURL(filename) });
    t.after(() => service.close());
    const first = service.call('search', { delay: 300 });
    let started = false;
    let progress = false;
    let telemetry;
    const second = service.call('search', { delay: 30 }, { queueTimeoutMs: 2000,
        execution: { timeoutMs: 150, maxOperations: 1000, cpuDutyCycle: 1 },
        onStart: () => { started = true; }, onProgress: () => { progress = true; }, onTelemetry: value => { telemetry = value; } });
    await new Promise(resolve => setTimeout(resolve, 200));
    assert.equal(started, false);
    assert.equal(progress, false);
    assert.equal(telemetry, undefined);
    assert.deepEqual(await first, { done: true });
    assert.deepEqual(await second, { done: true });
    assert.equal(started, true);
    assert.equal(progress, true);
    assert.deepEqual(telemetry, { cacheStatus: 'hit' });
});

test('a full legacy worker queue leaves an accepted job waiting rather than failing it', async t => {
    const { jobs, service, calls } = fixture(t);
    const original = service.call;
    let busy = true;
    service.call = (...args) => busy ? Promise.reject(new PlannerError('SEARCH_BUSY', 'Busy', 429)) : original(...args);
    const job = await jobs.submit(request);
    await tick();
    assert.equal(jobs.get(job.id).status, 'queued');
    busy = false;
    jobs.prune();
    await tick();
    assert.equal(jobs.get(job.id).status, 'queued', 'Polling must not bypass admission backoff');
    await new Promise(resolve => setTimeout(resolve, 1100));
    assert.equal(jobs.get(job.id).status, 'running');
    assert.equal(calls.length, 1);
});

test('active work can keep polling while queued work reaches its independent queue deadline', async t => {
    const { jobs, service, advance } = fixture(t, { leaseMs: 1000 });
    service.config.jobQueueTimeoutMs = 500;
    jobs.config.jobQueueTimeoutMs = 500;
    const first = await jobs.submit(request, { client: 'first' });
    const second = await jobs.submit({ ...request, destination: 'VIC' }, { client: 'second' });
    await tick();
    advance(501);
    assert.equal(jobs.get(first.id).status, 'running');
    assert.equal(jobs.get(second.id).status, 'failed');
    assert.equal(jobs.get(second.id).error.code, 'SEARCH_BUSY');
});
