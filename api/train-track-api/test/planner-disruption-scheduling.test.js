import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { pathToFileURL } from 'node:url';
import { PlannerService, availableMemoryBytes, plannerConfig } from '../lib/planner/service.js';

test('macOS maintenance headroom includes reclaimable pages but fails closed on unreadable stats', () => {
    const vmStat = () => `Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free: 10000.
Pages inactive: 30000.
Pages speculative: 5000.
`;
    assert.equal(availableMemoryBytes({ platform: 'darwin', freeBytes: 10000 * 16384, vmStat }), 45000 * 16384);
    assert.equal(availableMemoryBytes({ platform: 'darwin', freeBytes: 10000 * 16384,
        vmStat: () => 'Pages free: 10000.\n' }), 10000 * 16384);
    assert.equal(availableMemoryBytes({ platform: 'darwin', freeBytes: 10000 * 16384,
        vmStat: () => { throw new Error('vm_stat unavailable'); } }), 10000 * 16384);
    assert.equal(availableMemoryBytes({ platform: 'linux', freeBytes: 42,
        vmStat: () => { throw new Error('must not run'); } }), 42);
});

const waitFor = async predicate => {
    const until = Date.now() + 2500;
    while (!predicate()) {
        if (Date.now() > until) throw new Error('Worker did not reach expected state');
        await new Promise(resolve => setTimeout(resolve, 5));
    }
};

async function fixture(t, config = {}, headroom = () => true) {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'disruption-scheduling-'));
    const filename = path.join(directory, 'worker.mjs');
    await fs.writeFile(filename, `
        import { parentPort } from 'node:worker_threads';
        parentPort.on('message', message => {
            const { id, method, payload, cancelBuffer } = message;
            const cancelled = new Int32Array(cancelBuffer);
            parentPort.postMessage({ id, progress: { phase: 'running' } });
            const until = Date.now() + (payload.holdMs ?? 0);
            while (Date.now() < until) {
                if (!payload.ignoreCancellation && Atomics.load(cancelled, 0)) {
                    parentPort.postMessage({ id, error: { code: 'SEARCH_CANCELLED', message: 'Cancelled', status: 499 } });
                    return;
                }
                Atomics.wait(cancelled, 0, 0, 5);
            }
            parentPort.postMessage({ id, result: { tag: payload.tag, method } });
        });
    `);
    const service = new PlannerService({ ...plannerConfig({}), prewarm: false, workerCount: 1, ...config },
        { workerURL: pathToFileURL(filename), maintenanceHeadroom: headroom });
    t.after(async () => { service.close(); await fs.rm(directory, { recursive: true, force: true }); });
    return service;
}

test('maintenance has one idle slot, no waiting queue and never consumes user admission', { timeout: 5000 }, async t => {
    const service = await fixture(t, { maxQueue: 1 });
    let running = false;
    const monitor = service.disruptionProfile({ tag: 'monitor', holdMs: 2000 }, {
        onProgress: () => { running = true; } });
    const deferred = assert.rejects(monitor, { code: 'SEARCH_DEFERRED' });
    await waitFor(() => running);
    await assert.rejects(service.disruptionProfile({ tag: 'extra' }), { code: 'SEARCH_DEFERRED' });
    assert.equal(service.queue.length, 0);
    assert.equal(service.pendingCount({ includeMaintenance: false }), 0);
    const started = Date.now();
    assert.equal((await service.call('search', { tag: 'user' })).tag, 'user');
    await deferred;
    assert.ok(Date.now() - started < 500, 'User search should preempt maintenance promptly');
});

test('maintenance defers while interactive or ordinary background jobs run', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    for (const priority of ['interactive', 'background']) {
        const demand = service.call('search', { tag: priority, holdMs: 50 }, { priority });
        await assert.rejects(service.disruptionProfile({}), { code: 'SEARCH_DEFERRED' });
        assert.equal(service.queue.length, 0);
        await demand;
    }
    assert.equal((await service.disruptionProfile({})).method, 'disruptionProfile');
});

test('ordinary background demand also preempts maintenance instead of ageing behind it', { timeout: 5000 }, async t => {
    const service = await fixture(t);
    const monitor = service.disruptionProfile({ holdMs: 2000 });
    const deferred = assert.rejects(monitor, { code: 'SEARCH_DEFERRED' });
    const demand = service.call('search', { tag: 'refresh' }, { priority: 'background' });
    await deferred;
    assert.equal((await demand).tag, 'refresh');
});

test('two-worker maintenance preserves the first foreground worker and hot date', { timeout: 5000 }, async t => {
    const service = await fixture(t, { workerCount: 2 });
    await service.call('search', { tag: 'first', request: { time: '2026-09-19T12:00:00Z', windowMinutes: 60 } });
    const first = service.slots[0], worker = first.worker, date = first.dateKey;
    let running = false;
    const monitor = service.disruptionProfile({ holdMs: 2000 }, { onProgress: () => { running = true; } });
    const deferred = assert.rejects(monitor, { code: 'SEARCH_DEFERRED' });
    await waitFor(() => running);
    assert.equal(service.slots[1].active.priority, 'maintenance');
    assert.equal(first.active, null);
    assert.equal(first.worker, worker);
    assert.equal(first.dateKey, date);
    await service.call('search', { tag: 'second' });
    await deferred;
    assert.equal(first.worker, worker);
    assert.equal(first.dateKey, date);
});

test('resource pressure prevents maintenance admission and never starts a worker', async t => {
    const service = await fixture(t, {}, () => false);
    await assert.rejects(service.disruptionProfile({}), { code: 'SEARCH_DEFERRED' });
    assert.equal(service.worker, null);
    assert.equal(service.queue.length, 0);
});

test('maintenance cannot make a cold foreground pool adopt its future-date worker', { timeout: 5000 }, async t => {
    const service = await fixture(t, { workerCount: 2 });
    await service.disruptionProfile({ date: '2026-09-23' });
    assert.equal(service.slots[0].worker, null);
    assert.equal(service.slots[1].dateKey, 'monitor:2026-09-23');
    await service.call('search', { tag: 'first-user', request: { time: '2026-09-19T12:00:00Z', windowMinutes: 60 } });
    assert.ok(service.slots[0].worker);
    assert.equal(service.slots[0].lastPriority, 'interactive');
    assert.equal(service.slots[1].lastPriority, 'maintenance');
});

test('non-cooperative maintenance is terminated promptly without dropping waiting users', { timeout: 5000 }, async t => {
    const service = await fixture(t, { maxQueue: 1 });
    let running = false;
    const monitor = service.disruptionProfile({ holdMs: 4000, ignoreCancellation: true }, { onProgress: () => { running = true; } });
    const deferred = assert.rejects(monitor, { code: 'SEARCH_DEFERRED' });
    await waitFor(() => running);
    const previous = service.worker, start = Date.now();
    const result = await service.call('search', { tag: 'user' });
    await deferred;
    assert.equal(result.tag, 'user');
    assert.notEqual(service.worker, previous);
    assert.ok(Date.now() - start < 1000);
});

test('maintenance cancellation is explicit and allows a later retry', { timeout: 5000 }, async t => {
    const service = await fixture(t), controller = new AbortController();
    const monitor = service.disruptionProfile({ holdMs: 2000 }, { signal: controller.signal });
    const cancelled = assert.rejects(monitor, { code: 'SEARCH_CANCELLED' });
    controller.abort();
    await cancelled;
    await waitFor(() => !service.active && !service.slots[0].restarting);
    assert.equal((await service.disruptionProfile({ tag: 'retry' })).tag, 'retry');
});

test('mixed-load bursts retain every foreground admission and promptly preempt each maintenance slice', { timeout: 10000 }, async t => {
    const service = await fixture(t, { workerCount: 2, maxQueue: 4 });
    // Warm the foreground isolate before measuring scheduling rather than Node
    // startup. The other isolate starts a long maintenance slice each round.
    await Promise.all([0, 1].map(index => service.call('search', { tag: `warm-${index}`, holdMs: 10 })));
    const baselineTimes = [], startDelays = [], completionTimes = [];
    for (let round = 0; round < 8; round++) {
        const started = performance.now();
        await Promise.all(Array.from({ length: 4 }, (_, index) => service.call('search',
            { tag: `baseline-${round}-${index}`, holdMs: 10 }, { priority: index === 3 ? 'background' : 'interactive' })));
        baselineTimes.push(performance.now() - started);
    }
    for (let round = 0; round < 8; round++) {
        await waitFor(() => service.maintenanceAvailable());
        let running = false;
        const monitor = service.disruptionProfile({ tag: `monitor-${round}`, holdMs: 2000 },
            { onProgress: () => { running = true; } });
        const deferred = assert.rejects(monitor, { code: 'SEARCH_DEFERRED' });
        await waitFor(() => running);
        const started = performance.now();
        const jobs = Array.from({ length: 4 }, (_, index) => service.call('search',
            { tag: `${round}-${index}`, holdMs: 10 }, { priority: index === 3 ? 'background' : 'interactive',
                onStart: () => { if (!index) startDelays.push(performance.now() - started); } }));
        assert.equal(service.pendingCount({ includeMaintenance: false }), 4);
        await assert.rejects(service.disruptionProfile({}), { code: 'SEARCH_DEFERRED' });
        const results = await Promise.all(jobs);
        await deferred;
        completionTimes.push(performance.now() - started);
        assert.deepEqual(results.map(result => result.tag), Array.from({ length: 4 }, (_, index) => `${round}-${index}`));
        assert.ok(!service.queue.some(job => job.priority === 'maintenance'));
    }
    const maximumStart = Math.max(...startDelays), maximumCompletion = Math.max(...completionTimes);
    assert.ok(maximumStart < 150, `First foreground scheduling delayed ${maximumStart}ms`);
    assert.ok(maximumCompletion < 500, `Foreground burst took ${maximumCompletion}ms`);
    t.diagnostic(`32 foreground/background jobs across 8 maintenance interruptions: max first-start ${maximumStart.toFixed(1)}ms; max four-job burst ${maximumCompletion.toFixed(1)}ms; baseline max four-job burst ${Math.max(...baselineTimes).toFixed(1)}ms.`);
});

test('maintenance has a forced execution deadline even when a caller requests an extended user budget', { timeout: 5000 }, async t => {
    const service = await fixture(t, { maintenanceTimeoutMs: 100 });
    const started = performance.now();
    await assert.rejects(service.disruptionProfile({ holdMs: 2000, ignoreCancellation: true },
        { priority: 'interactive', execution: { timeoutMs: 60000, maxOperations: 1000000000 } }), { code: 'SEARCH_TIMEOUT' });
    assert.ok(performance.now() - started < 700);
    assert.equal((await service.call('search', { tag: 'after-timeout' })).tag, 'after-timeout');
    assert.ok(performance.now() - started < 1000);
});
