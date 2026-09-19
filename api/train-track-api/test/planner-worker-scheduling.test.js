import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';

const workerModule = new URL('../lib/planner/worker.js', import.meta.url).href;
const engineModule = new URL('../lib/planner/engine.js', import.meta.url).href;
const contractModule = new URL('../lib/planner/contract.js', import.meta.url).href;
const waitFor = async predicate => {
    const deadline = Date.now() + 3000;
    while (!predicate()) {
        assert.ok(Date.now() < deadline, 'Worker scheduler did not reach the expected state');
        await new Promise(resolve => setTimeout(resolve, 5));
    }
};

// Exercise the real worker transport, I/O gate, telemetry and warming code with
// tiny engine operations. The test never loads the national timetable or calls
// a production rail-data service.
async function fixture(t, overrides = {}, source) {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'planner-scheduling-'));
    const filename = path.join(directory, 'worker.mjs');
    await fs.writeFile(filename, source ?? `
        import { PlannerEngine } from ${JSON.stringify(engineModule)};
        import { PlannerError } from ${JSON.stringify(contractModule)};
        process.env.LIVE_DEPARTURE_BOARD_API_KEY = 'fixture-key';
        const trace = [];
        let owner = null;
        const enter = tag => {
            if (owner !== null) throw new Error('Overlapping CPU owners: ' + owner + '/' + tag);
            owner = tag; trace.push('enter:' + tag);
        };
        const leave = tag => { trace.push('leave:' + tag); owner = null; };
        const delay = (ms, signal) => new Promise((resolve, reject) => {
            const done = () => { signal?.removeEventListener('abort', abort); resolve(); };
            const timer = setTimeout(done, ms);
            const abort = () => { clearTimeout(timer); signal.removeEventListener('abort', abort); reject(signal.reason); };
            signal?.addEventListener('abort', abort, { once: true });
            if (signal?.aborted) abort();
        });
        PlannerEngine.prototype.search = async function(payload, signal, execution) {
            if (payload.crash) process.exit(1);
            const tag = payload.tag;
            let acquired = false;
            const acquire = () => { enter(tag); acquired = true; };
            const release = () => { leave(tag); acquired = false; };
            acquire();
            try {
                let observation;
                execution.onProgress('started');
                if (payload.ioMs || payload.provider) {
                    release();
                    try {
                        observation = await execution.awaitIO(() => payload.provider
                            ? this.liveProvider.fetchBoards(['AAA'], { offsets: [0], signal: execution.abortSignal, budget: this.createLiveBudget() })
                            : delay(payload.ioMs, execution.abortSignal));
                    } catch (error) {
                        if (signal.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Cancelled', 499);
                        throw error;
                    }
                    acquire();
                    if (payload.ignoreCancellation && signal.aborted) await new Promise(() => {});
                    execution.onProgress('resumed');
                }
                return await execution.measure('routingMs', async () => {
                    if (payload.holdMs) await delay(payload.holdMs);
                    if (signal.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Cancelled', 499);
                    return { tag, observation, trace: [...trace] };
                });
            } finally { if (acquired) release(); }
        };
        for (const method of ['routeBoardProfileChunk', 'routeBoardPreview', 'disruptionProfile']) {
            PlannerEngine.prototype[method] = async (payload, signal, execution) => {
                execution.onTelemetry({ datasetVersion: 'fixture' });
                return execution.measure('routingMs', () => ({ method, tag: payload.tag }));
            };
        }
        PlannerEngine.prototype.dataset = async () => {
            enter('prewarm');
            await delay(30);
            return { version: 'fixture', stations: [{ crs: 'AAA' }, { crs: 'BBB' }] };
        };
        PlannerEngine.prototype.checkQuery = (repo, request) => request;
        PlannerEngine.prototype.network = async () => {
            await delay(30); leave('prewarm');
            return { services: [], stations: new Map(), rules: { tsi: [], links: [] } };
        };
        PlannerEngine.prototype.runtime = function() { return { trace, owner, raptorIndexes: Number(Boolean(this.raptorIndex)) }; };
        await import(${JSON.stringify(workerModule)});
    `);
    const service = new PlannerService({ ...plannerConfig({}), timeoutMs: 4000, prewarm: false, workerCount: 1, ...overrides }, {
        workerURL: pathToFileURL(filename)
    });
    t.after(async () => { service.close(); await fs.rm(directory, { recursive: true, force: true }); });
    return service;
}

test('another search finishes while the real worker waits for live I/O', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    const telemetry = [];
    let liveFinished = false;
    const live = service.call('search', { tag: 'live', ioMs: 200 }, { onTelemetry: value => telemetry.push(value) })
        .then(result => { liveFinished = true; return result; });
    await waitFor(() => service.parked.size === 1);
    const quick = await service.call('search', { tag: 'quick' });
    assert.equal(quick.tag, 'quick');
    assert.equal(liveFinished, false);
    const result = await live;
    assert.equal(result.tag, 'live');
    assert.deepEqual(result.trace.slice(0, 5), ['enter:live', 'leave:live', 'enter:quick', 'leave:quick', 'enter:live']);
    assert.ok(telemetry.some(value => value.metricsDelta?.liveLookupMs > 0));
    assert.ok(telemetry.some(value => value.metricsDelta?.routingMs >= 0));
    assert.ok(telemetry.some(value => value.resourcePeaks?.heapUsedBytes > 0));
});

test('a completed live lookup resumes only after the current CPU owner finishes', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    let resumed = false;
    const live = service.call('search', { tag: 'live', ioMs: 40 }, {
        onProgress: value => { if (value.phase === 'resumed') resumed = true; }
    });
    await waitFor(() => service.parked.size === 1);
    const computing = service.call('search', { tag: 'computing', holdMs: 150 });
    await waitFor(() => service.queue.some(job => job.resuming));
    assert.equal(resumed, false);
    assert.equal(service.active.payload.tag, 'computing');
    await computing;
    assert.equal((await live).tag, 'live');
    assert.equal(resumed, true);
});

test('cancelling a parked I/O request releases its retained worker context', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    const controller = new AbortController();
    const live = service.call('search', { tag: 'live', ioMs: 2000 }, { signal: controller.signal });
    const rejected = assert.rejects(live, { code: 'SEARCH_CANCELLED' });
    await waitFor(() => service.parked.size === 1);
    controller.abort();
    await rejected;
    await waitFor(() => !service.parked.size && !service.active && !service.queue.length);
    assert.equal((await service.call('search', { tag: 'next' })).tag, 'next');
});

test('cancelling an already queued resume still lets the worker unwind', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    const controller = new AbortController();
    const live = service.call('search', { tag: 'live', ioMs: 30 }, { signal: controller.signal });
    const rejected = assert.rejects(live, { code: 'SEARCH_CANCELLED' });
    await waitFor(() => service.parked.size === 1);
    const computing = service.call('search', { tag: 'computing', holdMs: 150 });
    await waitFor(() => service.queue.some(job => job.resuming));
    controller.abort();
    await rejected;
    await computing;
    await waitFor(() => !service.parked.size && !service.active && !service.queue.length);
    assert.equal((await service.call('search', { tag: 'next' })).tag, 'next');
});

test('a cancelled resume that does not cooperate is terminated without losing queued work', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    const controller = new AbortController();
    const live = service.call('search', { tag: 'live', ioMs: 30, ignoreCancellation: true }, { signal: controller.signal });
    const rejected = assert.rejects(live, { code: 'SEARCH_CANCELLED' });
    await waitFor(() => service.parked.size === 1);
    const originalWorker = service.worker;
    const computing = service.call('search', { tag: 'computing', holdMs: 150 });
    await waitFor(() => service.queue.some(job => job.resuming));
    controller.abort();
    await rejected;
    const queued = service.call('search', { tag: 'queued' });
    await computing;
    assert.equal((await queued).tag, 'queued');
    assert.notEqual(service.worker, originalWorker);
    assert.equal(service.parked.size, 0);
});

test('parked and active operations both count toward admission limits', { timeout: 5000 }, async t => {
    const service = await fixture(t, { maxQueue: 2 });
    const live = service.call('search', { tag: 'live', ioMs: 100 });
    await waitFor(() => service.parked.size === 1);
    const computing = service.call('search', { tag: 'computing', holdMs: 150 });
    await assert.rejects(service.call('search', { tag: 'overflow' }), { code: 'SEARCH_BUSY' });
    await Promise.all([live, computing]);
});

test('disabled I/O overlap retains one operation at a time', { timeout: 5000 }, async t => {
    const service = await fixture(t, { maxLiveWaiters: 0 });
    const live = service.call('search', { tag: 'live', ioMs: 60 });
    const next = service.call('search', { tag: 'next' });
    const result = await live;
    assert.equal(service.parked.size, 0);
    assert.deepEqual(result.trace, ['enter:live', 'leave:live', 'enter:live']);
    assert.equal((await next).tag, 'next');
});

test('heap pressure prevents admission of another suspended context', { timeout: 5000 }, async t => {
    const service = await fixture(t, {}, `
        import { parentPort } from 'node:worker_threads';
        const waiting = new Map();
        parentPort.on('message', message => {
            if (message.resume) {
                parentPort.postMessage({ id: message.id, result: waiting.get(message.id) });
                waiting.delete(message.id);
            } else if (message.payload.ioMs) {
                waiting.set(message.id, { tag: message.payload.tag });
                parentPort.postMessage({ id: message.id, waitingForIO: true, heapRatio: 0.8 });
                setTimeout(() => parentPort.postMessage({ id: message.id, readyToResume: true }), message.payload.ioMs);
            } else parentPort.postMessage({ id: message.id, result: { tag: message.payload.tag } });
        });
    `);
    const live = service.call('search', { tag: 'live', ioMs: 100 });
    let nextStarted = false;
    const next = service.call('search', { tag: 'next' }, { onStart: () => { nextStarted = true; } });
    await new Promise(resolve => setTimeout(resolve, 50));
    assert.equal(nextStarted, false);
    assert.equal(service.parked.size, 0);
    await live;
    assert.equal((await next).tag, 'next');
});

test('unstarted requests recover after a worker crash', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    const crash = service.call('search', { tag: 'crash', crash: true });
    const rejected = assert.rejects(crash, { code: 'DATASET_UNAVAILABLE' });
    const queued = service.call('search', { tag: 'queued' });
    await rejected;
    assert.equal((await queued).tag, 'queued');
});

test('a crash releases parked work while keeping unstarted requests recoverable', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    const live = service.call('search', { tag: 'live', ioMs: 2000 });
    const liveRejected = assert.rejects(live, { code: 'DATASET_UNAVAILABLE' });
    await waitFor(() => service.parked.size === 1);
    const crash = service.call('search', { tag: 'crash', crash: true });
    const crashRejected = assert.rejects(crash, { code: 'DATASET_UNAVAILABLE' });
    const queued = service.call('search', { tag: 'queued' });
    await Promise.all([liveRejected, crashRejected]);
    assert.equal((await queued).tag, 'queued');
    assert.equal(service.parked.size, 0);
});

test('prewarm shares the serial operation queue and profile methods receive telemetry', { timeout: 5000 }, async t => {
    const service = await fixture(t, { prewarm: true });
    const search = service.call('search', { tag: 'search', holdMs: 50 });
    const warm = service.call('prewarm', {}, { priority: 'background' });
    await search;
    assert.deepEqual(await warm, { warmed: true });
    const state = await service.call('runtime', {});
    assert.deepEqual(state.trace, ['enter:search', 'leave:search', 'enter:prewarm', 'leave:prewarm']);
    assert.equal(state.owner, null);
    assert.equal(state.raptorIndexes, 1, 'Idle prewarming prepares the RAPTOR index before the first RAPTOR search');
    for (const method of ['routeBoardProfileChunk', 'routeBoardPreview', 'disruptionProfile']) {
        const measurements = [];
        assert.deepEqual(await service.call(method, { tag: method }, { onTelemetry: value => measurements.push(value) }), { method, tag: method });
        assert.ok(measurements.some(value => value.metricsDelta?.routingMs >= 0));
    }
});

test('live provider requests use the parent transport with no cloned AbortSignal', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    const requests = [];
    service.requestUpstream = async (worker, message) => {
        requests.push(message);
        worker.postMessage({ requestId: message.requestId, upstreamResult: { data: {
            crs: 'AAA', generatedAt: new Date().toISOString(), trainServices: []
        } } });
    };
    const result = await service.call('search', { tag: 'provider', provider: true });
    assert.equal(requests.length, 1);
    assert.equal(Object.hasOwn(requests[0].upstream, 'signal'), false);
    assert.equal(requests[0].upstream.api, 'rail_departure_board');
    assert.equal(result.observation.boards.length, 1);
    assert.equal(result.observation.errors.length, 0);
});

test('parent HTTP errors retain their status when returned to the live provider', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    service.requestUpstream = async (worker, message) => {
        worker.postMessage({ requestId: message.requestId, upstreamError: { name: 'AxiosError', code: 'ERR_BAD_REQUEST', status: 429 } });
    };
    const result = await service.call('search', { tag: 'provider', provider: true });
    assert.equal(result.observation.errors[0].reason, 'rateLimited');
});

test('cancelling a live search aborts its parent HTTP request and releases the I/O gate', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    let aborted = false;
    service.requestUpstream = async (worker, message) => {
        const upstream = new AbortController();
        service.upstream.set(message.requestId, upstream);
        await new Promise(resolve => upstream.signal.addEventListener('abort', () => {
            aborted = true;
            worker.postMessage({ requestId: message.requestId, upstreamError: { name: 'AbortError', code: 'ERR_CANCELED' } });
            resolve();
        }, { once: true }));
        service.upstream.delete(message.requestId);
    };
    const controller = new AbortController();
    const live = service.call('search', { tag: 'provider', provider: true }, { signal: controller.signal });
    const rejected = assert.rejects(live, { code: 'SEARCH_CANCELLED' });
    await waitFor(() => service.upstream.size === 1 && service.parked.size === 1);
    controller.abort();
    await rejected;
    await waitFor(() => aborted && !service.upstream.size && !service.parked.size && !service.active);
    assert.equal((await service.call('search', { tag: 'next' })).tag, 'next');
});

test('two real routing workers share one provider request and cancellation preserves the surviving waiter', { timeout: 5000 }, async t => {
    const service = await fixture(t, { workerCount: 2 });
    const controller = new AbortController();
    let physicalRequests = 0, upstreamSignal, finish;
    service.upstreamBroker.performRequest = ({ signal }) => {
        physicalRequests++;
        upstreamSignal = signal;
        return new Promise((resolve, reject) => {
            const abort = () => reject(Object.assign(new Error('Cancelled'), { name: 'AbortError', code: 'ERR_CANCELED' }));
            signal.addEventListener('abort', abort, { once: true });
            finish = () => {
                signal.removeEventListener('abort', abort);
                resolve({ data: { crs: 'AAA', generatedAt: new Date().toISOString(), trainServices: [] } });
            };
        });
    };
    const first = service.call('search', { tag: 'cancelled', provider: true }, { signal: controller.signal });
    const rejected = assert.rejects(first, { code: 'SEARCH_CANCELLED' });
    const survivor = service.call('search', { tag: 'survivor', provider: true });
    try {
        await waitFor(() => service.upstream.size === 2);
        assert.equal(service.slots.filter(slot => slot.worker).length, 2);
        assert.equal(physicalRequests, 1);
        assert.equal(service.upstreamBroker.inflight.size, 1);
        assert.equal([...service.upstreamBroker.inflight.values()][0].consumers.size, 2);
        controller.abort();
        await rejected;
        await waitFor(() => service.upstream.size === 1);
        assert.equal([...service.upstreamBroker.inflight.values()][0].consumers.size, 1);
        assert.equal(upstreamSignal.aborted, false, 'Cancelling one logical waiter must preserve the shared HTTP request');
        finish();
        const result = await survivor;
        assert.equal(result.tag, 'survivor');
        assert.equal(result.observation.boards.length, 1);
        assert.equal(result.observation.errors.length, 0);
        assert.equal(physicalRequests, 1);
        await waitFor(() => !service.upstream.size && !service.parked.size && !service.active);
    } finally {
        controller.abort();
        finish?.();
        await Promise.allSettled([first, survivor]);
    }
});

test('a routing worker crash removes only its waiter from a shared provider request', { timeout: 5000 }, async t => {
    const service = await fixture(t, { workerCount: 2 });
    let physicalRequests = 0, upstreamSignal, finish;
    service.upstreamBroker.performRequest = ({ signal }) => {
        physicalRequests++;
        upstreamSignal = signal;
        return new Promise((resolve, reject) => {
            const abort = () => reject(Object.assign(new Error('Cancelled'), { name: 'AbortError', code: 'ERR_CANCELED' }));
            signal.addEventListener('abort', abort, { once: true });
            finish = () => {
                signal.removeEventListener('abort', abort);
                resolve({ data: { crs: 'AAA', generatedAt: new Date().toISOString(), trainServices: [] } });
            };
        });
    };
    const observe = promise => promise.then(value => ({ value }), error => ({ error }));
    const work = Object.fromEntries(['left', 'right'].map(tag => [tag,
        observe(service.call('search', { tag, provider: true }))]));
    try {
        await waitFor(() => service.upstream.size === 2 && service.parked.size === 1);
        assert.equal(physicalRequests, 1);
        const crashedSlot = service.slots.find(slot => slot.parked.size);
        const crashedTag = [...crashedSlot.parked.values()][0].payload.tag;
        const survivorTag = crashedTag === 'left' ? 'right' : 'left';
        await assert.rejects(service.call('search', { tag: 'crash', crash: true }, {}, crashedSlot),
            { code: 'DATASET_UNAVAILABLE' });
        assert.equal((await work[crashedTag]).error.code, 'DATASET_UNAVAILABLE');
        await waitFor(() => service.upstream.size === 1);
        assert.equal([...service.upstreamBroker.inflight.values()][0].consumers.size, 1);
        assert.equal(upstreamSignal.aborted, false, 'Resetting one worker must preserve the other worker\'s HTTP interest');
        finish();
        const result = (await work[survivorTag]).value;
        assert.equal(result.tag, survivorTag);
        assert.equal(result.observation.boards.length, 1);
        assert.equal(result.observation.errors.length, 0);
        assert.equal(physicalRequests, 1);
        await waitFor(() => !service.upstream.size && !service.parked.size && !service.active);
    } finally {
        finish?.();
        service.close();
        await Promise.all(Object.values(work));
    }
});
