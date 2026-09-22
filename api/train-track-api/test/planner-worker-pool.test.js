import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';
import { PlannerSearchJobs } from '../lib/planner/search-jobs.js';
import { normalizeRequest, decodeCursor } from '../lib/planner/contract.js';

const version = 'a'.repeat(64);
const request = normalizeRequest({ origin: 'AAA', destination: 'BBB', time: '2026-09-18T10:00:00Z', timeType: 'departAfter' });
const waitFor = async predicate => {
    const deadline = Date.now() + 4000;
    while (!predicate()) {
        assert.ok(Date.now() < deadline, 'Worker pool did not reach the expected state');
        await new Promise(resolve => setTimeout(resolve, 5));
    }
};
const gate = () => new Int32Array(new SharedArrayBuffer(8));
const ioGate = () => new Int32Array(new SharedArrayBuffer(12));
const release = value => { Atomics.store(value, 1, 1); Atomics.notify(value, 1); };

async function fixture(t, overrides = {}) {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'planner-pool-'));
    const filename = path.join(directory, 'worker.mjs');
    const contractURL = new URL('../lib/planner/contract.js', import.meta.url).href;
    await fs.writeFile(filename, `
        import { parentPort, threadId } from 'node:worker_threads';
        import { randomUUID } from 'node:crypto';
        import { encodeCursor } from ${JSON.stringify(contractURL)};
        const searches = new Set(), snapshots = new Set(), resumes = new Map();
        let searchCount = 0, cacheHits = 0;
        const waitGate = (control, cancelled) => new Promise((resolve, reject) => {
            const deadline = Date.now() + 5000;
            const timer = setInterval(() => {
                if (Atomics.load(control, 1) || Atomics.load(cancelled, 0)) { clearInterval(timer); resolve(); }
                else if (Date.now() >= deadline) { clearInterval(timer); reject(new Error('Test I/O gate timed out')); }
            }, 5);
        });
        parentPort.on('message', async ({ id, method, payload, cancelBuffer, resume }) => {
            if (resume) { resumes.get(id)?.(); resumes.delete(id); return; }
            try {
                if (method === 'clearSearchCache') {
                    const clearedSearches = searches.size;
                    searches.clear();
                    parentPort.postMessage({ id, result: { clearedSearches } });
                    return;
                }
                if (method === 'runtime') {
                    parentPort.postMessage({ id, result: { threadId, searches: searchCount, cacheHits, datePreparations: 0,
                        caches: { searches: searches.size }, memoryBytes: { rss: 999999999,
                            heapUsed: 100 + threadId, heapTotal: 200 + threadId, external: 10, arrayBuffers: 5 } } });
                    return;
                }
                if (payload.crash) process.exit(1);
                if (payload.ioGate) {
                    const control = new Int32Array(payload.ioGate), cancelled = new Int32Array(cancelBuffer);
                    Atomics.add(control, 0, 1);
                    parentPort.postMessage({ id, waitingForIO: true, heapRatio: 0.1 });
                    await waitGate(control, cancelled);
                    await new Promise(resolve => {
                        resumes.set(id, resolve);
                        parentPort.postMessage({ id, readyToResume: true });
                    });
                    Atomics.add(control, 2, 1);
                    if (Atomics.load(cancelled, 0)) throw Object.assign(new Error('Cancelled'), { code: 'SEARCH_CANCELLED', status: 499 });
                }
                if (payload.holdGate) {
                    const control = new Int32Array(payload.holdGate), cancelled = new Int32Array(cancelBuffer);
                    Atomics.add(control, 0, 1);
                    // Keep ownership while allowing the suspended I/O callback to request a resume.
                    await waitGate(control, cancelled);
                    if (Atomics.load(cancelled, 0)) throw Object.assign(new Error('Cancelled'), { code: 'SEARCH_CANCELLED', status: 499 });
                }
                if (payload.gate) {
                    const gate = new Int32Array(payload.gate), cancelled = new Int32Array(cancelBuffer);
                    Atomics.add(gate, 0, 1);
                    const deadline = Date.now() + 5000;
                    // This synchronous loop cannot share a JavaScript thread with another task.
                    while (!Atomics.load(gate, 1)) {
                        if (Atomics.load(cancelled, 0)) throw Object.assign(new Error('Cancelled'), { code: 'SEARCH_CANCELLED', status: 499 });
                        if (Date.now() >= deadline) throw new Error('Test rendezvous timed out');
                    }
                }
                const snapshot = payload.liveSnapshotId ?? payload.tubeSnapshotId;
                if (snapshot && !snapshots.has(snapshot)) {
                    throw Object.assign(new Error('Snapshot belongs to another worker'), { code: 'CURSOR_EXPIRED', status: 410 });
                }
                const key = JSON.stringify(payload.request), cacheHit = searches.has(key);
                searches.add(key); searchCount++; cacheHits += Number(cacheHit);
                let more;
                if (snapshot || payload.snapshotKind) {
                    const retained = snapshot ?? randomUUID();
                    snapshots.add(retained);
                    const live = Boolean(payload.liveSnapshotId || payload.snapshotKind === 'live');
                    more = encodeCursor(payload.request, ${JSON.stringify(version)}, (payload.offset ?? 0) + 1,
                        live ? retained : undefined, live ? undefined : retained);
                }
                parentPort.postMessage({ id, telemetry: { cacheStatus: cacheHit ? 'hit' : 'miss' } });
                parentPort.postMessage({ id, result: { threadId, tag: payload.tag, cacheHit,
                    dataset: { version: ${JSON.stringify(version)} }, journeys: [], pagination: { more } } });
            } catch (error) {
                parentPort.postMessage({ id, error: { code: error.code ?? 'DATASET_UNAVAILABLE',
                    message: error.message, status: error.status ?? 503 } });
            }
        });
    `);
    const service = new PlannerService({ ...plannerConfig({}), workerCount: 2, timeoutMs: 6000,
        prewarm: false, maxLiveWaiters: 0, ...overrides }, { workerURL: pathToFileURL(filename) });
    t.after(async () => { service.close(); await fs.rm(directory, { recursive: true, force: true }); });
    return service;
}

test('planner worker count defaults to two, supports one to eight or auto, and bounds invalid configuration', () => {
    assert.equal(plannerConfig({}).workerCount, 2);
    assert.equal(plannerConfig({}).maxQueue, 8);
    for (const count of ['1', '2', '3', '8']) assert.equal(plannerConfig({ PLANNER_WORKERS: count }).workerCount, Number(count));
    for (const count of ['', '0', '-1', '9', '1.5', 'Infinity', 'invalid']) {
        assert.equal(plannerConfig({ PLANNER_WORKERS: count }).workerCount, 2);
    }
    const auto = plannerConfig({ PLANNER_WORKERS: 'auto' }).workerCount;
    assert.ok(auto >= 2 && auto <= 6);
    assert.equal(plannerConfig({ PLANNER_WORKERS: '4' }).maxQueue, 16);
    assert.equal(plannerConfig({ PLANNER_WORKERS: '4', PLANNER_MAX_QUEUE: '10' }).maxQueue, 10);
    const pool = new PlannerService({ ...plannerConfig({ PLANNER_WORKERS: '4' }), prewarm: false });
    try { assert.equal(pool.slots.length, 4); } finally { pool.close(); }
    const service = new PlannerService(plannerConfig({}), { metadataOnly: true });
    try {
        assert.equal(service.workerCount, 1);
        assert.equal(service.slots.length, 1);
    } finally { service.close(); }
});

test('temporary load admission cap changes real pool admission without changing configuration', { timeout: 10000 }, async t => {
    const service = await fixture(t, { maxQueue: 1 });
    const rendezvous = gate();
    const first = service.call('search', { request, tag: 'first', gate: rendezvous.buffer });
    try {
        await waitFor(() => Atomics.load(rendezvous, 0) === 1);
        await assert.rejects(service.call('search', { request, tag: 'rejected' }), { code: 'SEARCH_BUSY' });
        const lease = service.acquireLoadAdmissionCap(2);
        assert.equal(service.config.maxQueue, 1);
        const second = service.call('search', { request: { ...request, destination: 'CCC' },
            tag: 'second', gate: rendezvous.buffer });
        await waitFor(() => Atomics.load(rendezvous, 0) === 2);
        assert.equal(service.releaseLoadAdmissionCap(lease.leaseId).maxQueue, 1);
        await assert.rejects(service.call('search', { request, tag: 'rejected-again' }), { code: 'SEARCH_BUSY' });
        release(rendezvous);
        await Promise.all([first, second]);
    } finally { release(rendezvous); }
});

test('two synchronous CPU searches run in separate workers and the pool stays bounded', { timeout: 10000 }, async t => {
    const service = await fixture(t);
    const rendezvous = gate();
    const first = service.call('search', { request, tag: 'first', gate: rendezvous.buffer });
    const second = service.call('search', { request: { ...request, destination: 'CCC' }, tag: 'second', gate: rendezvous.buffer });
    try { await waitFor(() => Atomics.load(rendezvous, 0) === 2); }
    finally { release(rendezvous); }
    const results = await Promise.all([first, second]);
    assert.notEqual(results[0].threadId, results[1].threadId);
    assert.equal(service.workerCount, 2);
    assert.equal(service.slots.filter(slot => slot.worker).length, 2);
});

test('pool admission counts running and queued searches globally', { timeout: 10000 }, async t => {
    const service = await fixture(t, { maxQueue: 3 });
    const rendezvous = gate();
    const first = service.call('search', { request, gate: rendezvous.buffer });
    const second = service.call('search', { request: { ...request, destination: 'CCC' }, gate: rendezvous.buffer });
    let queued;
    try {
        await waitFor(() => Atomics.load(rendezvous, 0) === 2);
        queued = service.call('search', { request: { ...request, destination: 'DDD' }, tag: 'queued' });
        await assert.rejects(service.call('search', { request: { ...request, destination: 'EEE' } }), { code: 'SEARCH_BUSY' });
    } finally { release(rendezvous); }
    await Promise.all([first, second]);
    assert.equal((await queued).tag, 'queued');
});

test('queued-search admission supplies both CPU workers and keeps excess work queued', { timeout: 10000 }, async t => {
    const service = await fixture(t);
    const rendezvous = gate();
    const call = service.call.bind(service);
    service.status = async () => ({ available: true, dataset: { version } });
    service.call = (method, payload, options) => call(method,
        method === 'search' ? { ...payload, gate: rendezvous.buffer } : payload, options);
    const jobs = new PlannerSearchJobs(service);
    t.after(() => jobs.close());
    const submitted = [];
    try {
        for (const [index, destination] of ['BBB', 'CCC', 'DDD'].entries()) {
            submitted.push(await jobs.submit({ ...request, destination }, { client: `client-${index}` }));
        }
        await waitFor(() => Atomics.load(rendezvous, 0) === 2);
        assert.equal(jobs.inFlight.size, 2);
        assert.equal(jobs.get(submitted[0].id).status, 'running');
        assert.equal(jobs.get(submitted[1].id).status, 'running');
        assert.equal(jobs.get(submitted[2].id).status, 'queued');
    } finally { release(rendezvous); }
    await waitFor(() => submitted.every(job => jobs.get(job.id).status === 'completed'));
    assert.notEqual(jobs.get(submitted[0].id).result.threadId, jobs.get(submitted[1].id).result.threadId);
});

test('cancelling one CPU search leaves the other worker running', { timeout: 10000 }, async t => {
    const service = await fixture(t);
    const left = gate(), right = gate(), controller = new AbortController();
    const first = service.call('search', { request, gate: left.buffer }, { signal: controller.signal });
    const cancelled = assert.rejects(first, { code: 'SEARCH_CANCELLED' });
    const second = service.call('search', { request: { ...request, destination: 'CCC' }, tag: 'unaffected', gate: right.buffer });
    try {
        await waitFor(() => Atomics.load(left, 0) === 1 && Atomics.load(right, 0) === 1);
        controller.abort();
        await cancelled;
        assert.equal((await service.call('search', { request, tag: 'replacement' })).tag, 'replacement');
    } finally { release(left); release(right); }
    assert.equal((await second).tag, 'unaffected');
});

test('only one live lookup parks globally and its resume waits for the owning worker', { timeout: 10000 }, async t => {
    const service = await fixture(t, { maxLiveWaiters: 1 });
    const controls = { left: ioGate(), right: ioGate() }, held = gate();
    const work = Object.fromEntries(Object.entries(controls).map(([tag, control]) => [tag,
        service.call('search', { request: { ...request, destination: tag === 'left' ? 'CCC' : 'DDD' }, tag, ioGate: control.buffer })]));
    let third;
    try {
        await waitFor(() => Object.values(controls).every(control => Atomics.load(control, 0) === 1)
            && service.parked.size === 1);
        const parkedSlot = service.slots.find(slot => slot.parked.size);
        const waitingSlot = service.slots.find(slot => slot !== parkedSlot);
        const parkedTag = [...parkedSlot.parked.values()][0].payload.tag;
        const waitingTag = waitingSlot.active.payload.tag;
        const parkedThread = parkedSlot.worker.threadId, waitingThread = waitingSlot.worker.threadId;
        assert.notEqual(parkedThread, waitingThread);
        third = service.call('search', { request: { ...request, destination: 'EEE' }, tag: 'third', holdGate: held.buffer });
        await waitFor(() => Atomics.load(held, 0) === 1);
        assert.equal(parkedSlot.active.payload.tag, 'third');
        assert.equal(waitingSlot.active.payload.tag, waitingTag, 'The second I/O lookup keeps its active slot');
        release(controls[parkedTag]);
        await waitFor(() => service.queue.some(job => job.resuming));
        const resume = service.queue.find(job => job.resuming);
        assert.equal(resume.slot, parkedSlot);
        assert.equal(Atomics.load(controls[parkedTag], 2), 0);
        assert.equal(service.parked.size, 1);
        release(controls[waitingTag]);
        assert.equal((await work[waitingTag]).threadId, waitingThread);
        assert.equal(waitingSlot.active, null);
        assert.equal(Atomics.load(controls[parkedTag], 2), 0, 'An idle different worker cannot resume the retained context');
        release(held);
        assert.equal((await third).threadId, parkedThread);
        assert.equal((await work[parkedTag]).threadId, parkedThread);
        assert.equal(Atomics.load(controls[parkedTag], 2), 1);
        assert.equal(service.parked.size, 0);
    } finally {
        for (const control of Object.values(controls)) release(control);
        release(held);
        await Promise.allSettled([...Object.values(work), ...(third ? [third] : [])]);
    }
});

test('cancellation and close unwind a parked resume, its CPU owner and the other I/O worker', { timeout: 10000 }, async t => {
    const service = await fixture(t, { maxLiveWaiters: 1 });
    const controls = { left: ioGate(), right: ioGate() }, controllers = {
        left: new AbortController(), right: new AbortController()
    }, held = gate();
    const observe = promise => promise.then(value => ({ value }), error => ({ error }));
    const work = Object.fromEntries(Object.entries(controls).map(([tag, control]) => [tag,
        observe(service.call('search', { request: { ...request, destination: tag === 'left' ? 'CCC' : 'DDD' },
            tag, ioGate: control.buffer }, { signal: controllers[tag].signal }))]));
    let third;
    try {
        await waitFor(() => Object.values(controls).every(control => Atomics.load(control, 0) === 1)
            && service.parked.size === 1);
        const parkedSlot = service.slots.find(slot => slot.parked.size);
        const parkedTag = [...parkedSlot.parked.values()][0].payload.tag;
        const otherTag = parkedTag === 'left' ? 'right' : 'left';
        third = observe(service.call('search', { request: { ...request, destination: 'EEE' }, tag: 'third', holdGate: held.buffer }));
        await waitFor(() => Atomics.load(held, 0) === 1);
        controllers[parkedTag].abort();
        assert.equal((await work[parkedTag]).error.code, 'SEARCH_CANCELLED');
        await waitFor(() => service.queue.some(job => job.resuming));
        assert.equal(service.parked.size, 1, 'The cancelled context still needs its owning slot to unwind');
        service.close();
        assert.equal((await work[otherTag]).error.code, 'DATASET_UNAVAILABLE');
        assert.equal((await third).error.code, 'DATASET_UNAVAILABLE');
        assert.equal(service.queue.length, 0);
        assert.equal(service.parked.size, 0);
        assert.ok(service.slots.every(slot => slot.worker === null && slot.active === null));
    } finally {
        service.close();
        for (const control of Object.values(controls)) release(control);
        release(held);
        await Promise.all([...Object.values(work), ...(third ? [third] : [])]);
    }
});

test('a crashed worker recovers without terminating the other worker search', { timeout: 10000 }, async t => {
    const service = await fixture(t);
    const held = gate();
    const first = service.call('search', { request, tag: 'survivor', gate: held.buffer });
    try {
        await waitFor(() => Atomics.load(held, 0) === 1);
        await assert.rejects(service.call('search', { request: { ...request, destination: 'CCC' }, crash: true }),
            { code: 'DATASET_UNAVAILABLE' });
        assert.equal((await service.call('search', { request: { ...request, destination: 'DDD' }, tag: 'recovered' })).tag, 'recovered');
    } finally { release(held); }
    assert.equal((await first).tag, 'survivor');
});

for (const snapshotKind of ['live', 'tube']) {
    test(`${snapshotKind} pagination stays with its snapshot worker while another worker is idle`, { timeout: 10000 }, async t => {
        const service = await fixture(t);
        const query = snapshotKind === 'live' ? { ...request, realtime: 'apply' } : request;
        const first = await service.call('search', { request: query, snapshotKind });
        const held = gate();
        const holding = service.call('search', { request: query, gate: held.buffer });
        let page, pageFinished = false;
        try {
            await waitFor(() => Atomics.load(held, 0) === 1);
            // Ensure the second worker exists and can finish unrelated work.
            const other = await service.call('search', { request: { ...request, destination: 'CCC' } });
            assert.notEqual(other.threadId, first.threadId);
            page = service.call('search', decodeCursor(first.pagination.more)).then(result => { pageFinished = true; return result; });
            await new Promise(resolve => setTimeout(resolve, 30));
            assert.equal(pageFinished, false, 'Pagination must wait for the worker retaining the snapshot');
        } finally { release(held); }
        await holding;
        assert.equal((await page).threadId, first.threadId);
        const next = await service.call('search', decodeCursor((await page).pagination.more));
        assert.equal(next.threadId, first.threadId, 'Further offsets retain the same snapshot owner');
    });
}

test('an unknown snapshot fails instead of recomputing a fresh search', async t => {
    const service = await fixture(t);
    await assert.rejects(service.call('search', { request: { ...request, realtime: 'apply' },
        liveSnapshotId: '00000000-0000-4000-8000-000000000000', offset: 1 }), { code: 'CURSOR_EXPIRED' });
});

test('a snapshot expires when its worker is replaced', { timeout: 10000 }, async t => {
    const service = await fixture(t);
    const first = await service.call('search', { request, snapshotKind: 'tube' });
    await assert.rejects(service.call('search', { request, crash: true }), { code: 'DATASET_UNAVAILABLE' });
    await assert.rejects(service.call('search', decodeCursor(first.pagination.more)), { code: 'CURSOR_EXPIRED' });
    const replacement = await service.call('search', { request });
    assert.notEqual(replacement.threadId, first.threadId);
    await assert.rejects(service.call('search', decodeCursor(first.pagination.more)), { code: 'CURSOR_EXPIRED' });
});

test('warm date and repeated-result affinity survives work on a second date', { timeout: 10000 }, async t => {
    const service = await fixture(t);
    const tomorrow = { ...request, time: '2026-09-19T10:00:00Z' };
    const first = await service.call('search', { request });
    const held = gate();
    const holding = service.call('search', { request, gate: held.buffer });
    let second;
    try {
        await waitFor(() => Atomics.load(held, 0) === 1);
        second = await service.call('search', { request: tomorrow });
        assert.notEqual(second.threadId, first.threadId);
    } finally { release(held); }
    await holding;
    const repeated = await service.call('search', { request: tomorrow });
    assert.equal(repeated.threadId, second.threadId);
    assert.equal(repeated.cacheHit, true);
    assert.equal((await service.call('search', { request })).threadId, first.threadId);
    assert.equal((await service.call('search', { request: { ...tomorrow, destination: 'CCC' } })).threadId, second.threadId);
});

test('cache clear reaches both workers and preserves snapshot pagination', { timeout: 10000 }, async t => {
    const service = await fixture(t);
    const first = await service.call('search', { request, snapshotKind: 'tube' });
    const held = gate();
    const holding = service.call('search', { request, gate: held.buffer });
    const tomorrow = { ...request, time: '2026-09-19T10:00:00Z' };
    let second;
    try {
        await waitFor(() => Atomics.load(held, 0) === 1);
        second = await service.call('search', { request: tomorrow });
    } finally { release(held); }
    await holding;
    const workers = service.slots.map(slot => slot.worker);
    assert.deepEqual(await service.clearSearchCache(), { clearedSearches: 2 });
    assert.deepEqual(service.slots.map(slot => slot.worker), workers);
    assert.equal((await service.call('search', { request })).cacheHit, false);
    const repeated = await service.call('search', { request: tomorrow });
    assert.equal(repeated.threadId, second.threadId);
    assert.equal(repeated.cacheHit, false);
    assert.equal((await service.call('search', decodeCursor(first.pagination.more))).threadId, first.threadId);
});

test('pool runtime aggregates heap counters and samples shared RSS once', { timeout: 10000 }, async t => {
    const service = await fixture(t);
    const held = gate();
    const first = service.call('search', { request, gate: held.buffer });
    const second = service.call('search', { request: { ...request, destination: 'CCC' }, gate: held.buffer });
    try { await waitFor(() => Atomics.load(held, 0) === 2); }
    finally { release(held); }
    await Promise.all([first, second]);
    const runtime = await service.call('runtime', {});
    assert.equal(runtime.workerCount, 2);
    assert.equal(runtime.workers.length, 2);
    assert.equal(runtime.searches, 2);
    assert.equal(runtime.memoryBytes.heapUsed, runtime.workers.reduce((sum, worker) => sum + worker.memoryBytes.heapUsed, 0));
    assert.equal(runtime.memoryBytes.external, 20);
    assert.equal(runtime.memoryBytes.arrayBuffers, 10);
    assert.ok(Math.abs(runtime.memoryBytes.rss - process.memoryUsage().rss) < 4 * 1024 * 1024,
        'RSS belongs to the process and must not be summed from worker reports');
});

test('cold pool inspection and cache clearing do not start workers', async t => {
    const service = await fixture(t);
    assert.equal(service.slots.filter(slot => slot.worker).length, 0);
    assert.deepEqual(await service.clearSearchCache(), { clearedSearches: 0 });
    const runtime = await service.call('runtime', {});
    assert.equal(runtime.workerCount, 2);
    assert.equal(runtime.workers.length, 0);
    assert.equal(service.slots.filter(slot => slot.worker).length, 0);
});
