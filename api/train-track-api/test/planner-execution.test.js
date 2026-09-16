import test from 'node:test';
import assert from 'node:assert/strict';
import { Worker } from 'node:worker_threads';
import { once } from 'node:events';
import { createCooperativeSignal } from '../lib/planner/execution.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { normalizeRequest } from '../lib/planner/contract.js';
import { resolveServices } from '../lib/planner/calendar.js';

function clock(options = {}) {
    const cancelBuffer = new SharedArrayBuffer(4), cancelled = new Int32Array(cancelBuffer);
    let wall = 0, cpu = 0;
    const waits = [];
    const signal = createCooperativeSignal(cancelBuffer, { timeoutMs: 1000, cpuDutyCycle: 0.5, ...options }, {
        now: () => wall,
        cpuTime: () => cpu,
        wait: (view, duration) => {
            assert.ok(duration > 0 && duration <= 25, `Unbounded throttle wait: ${duration}`);
            waits.push(duration);
            wall += duration;
            options.onWait?.(view);
        }
    });
    return { signal, waits, cancelled, advance: (elapsed, active = elapsed) => { wall += elapsed; cpu += active; },
        get wall() { return wall; }, get cpu() { return cpu; } };
}

test('CPU duty accounting yields half of active intervals without banking I/O idle time', () => {
    const fixture = clock();
    fixture.advance(10);
    assert.equal(fixture.signal.aborted, false);
    fixture.advance(10);
    assert.equal(fixture.signal.aborted, false);
    assert.deepEqual(fixture.waits, [10, 10]);
    assert.equal(fixture.cpu / fixture.wall, 0.5);

    const idle = clock();
    idle.advance(100, 10);
    assert.equal(idle.signal.aborted, false);
    assert.deepEqual(idle.waits, []);
    idle.advance(10, 10);
    assert.equal(idle.signal.aborted, false);
    assert.deepEqual(idle.waits, [10], 'Earlier I/O idle time must not buy a later full-CPU burst');
});

test('long native work is repaid in bounded slices and cancellation interrupts the next slice', () => {
    const fixture = clock();
    fixture.advance(80);
    assert.equal(fixture.signal.aborted, false);
    assert.deepEqual(fixture.waits, [25, 25, 25, 5]);
    assert.equal(fixture.cpu / fixture.wall, 0.5);
    const cancelled = clock({ onWait: view => Atomics.store(view, 0, 1) });
    cancelled.advance(80);
    assert.equal(cancelled.signal.aborted, true);
    assert.deepEqual(cancelled.waits, [25]);
    assert.equal(cancelled.signal.aborted, true);
    assert.deepEqual(cancelled.waits, [25]);
});

test('execution deadline includes throttle waiting and unthrottled calls remain cancellable', () => {
    const fixture = clock({ timeoutMs: 100 });
    fixture.advance(80);
    assert.throws(() => fixture.signal.aborted, { code: 'SEARCH_TIMEOUT' });
    assert.deepEqual(fixture.waits, [20]);
    const full = clock({ cpuDutyCycle: 1 });
    full.advance(80);
    assert.equal(full.signal.aborted, false);
    assert.deepEqual(full.waits, []);
    Atomics.store(full.cancelled, 0, 1);
    assert.equal(full.signal.aborted, true);
});

test('throttle validates bounds and cannot block the main thread', () => {
    const buffer = new SharedArrayBuffer(4);
    for (const cpuDutyCycle of [0, -1, 1.1, Infinity, NaN]) {
        assert.throws(() => createCooperativeSignal(buffer, { cpuDutyCycle }), RangeError);
    }
    for (const timeoutMs of [0, -1, Infinity, NaN]) {
        assert.throws(() => createCooperativeSignal(buffer, { timeoutMs }), RangeError);
    }
    assert.throws(() => createCooperativeSignal(buffer, { cpuDutyCycle: 0.5 }), /worker thread/);
    let wall = 0;
    const waits = [];
    const signal = createCooperativeSignal(buffer, { cpuDutyCycle: 0.5 }, {
        now: () => wall, cpuTime: () => null, wait: (_, ms) => { waits.push(ms); wall += ms; }
    });
    wall += 20;
    assert.equal(signal.aborted, false);
    assert.deepEqual(waits, [20], 'Older Node versions use conservative active wall-time accounting');
});

test('a real worker observes shared cancellation during throttling without blocking its parent', { timeout: 5000 }, async t => {
    const cancelBuffer = new SharedArrayBuffer(4);
    const worker = new Worker(`
        const { parentPort, workerData } = require('node:worker_threads');
        import(workerData.module).then(({ createCooperativeSignal }) => {
            const signal = createCooperativeSignal(workerData.cancelBuffer, { timeoutMs: 2000, cpuDutyCycle: 0.5 });
            parentPort.postMessage('started');
            while (!signal.aborted) Math.sqrt(Math.random());
            parentPort.postMessage('cancelled');
        });
    `, { eval: true, workerData: { cancelBuffer, module: new URL('../lib/planner/execution.js', import.meta.url).href } });
    t.after(() => worker.terminate());
    assert.deepEqual(await once(worker, 'message'), ['started']);
    const finished = once(worker, 'message');
    await new Promise(resolve => setTimeout(resolve, 30));
    Atomics.store(new Int32Array(cancelBuffer), 0, 1);
    Atomics.notify(new Int32Array(cancelBuffer), 0);
    assert.deepEqual(await finished, ['cancelled']);
});

const version = 'b'.repeat(64);
const request = normalizeRequest({ origin: 'AAA', destination: 'BBB', timeType: 'departAfter', time: '2026-09-16T09:00:00+01:00' });
const config = { enabled: true, datasetPath: '/synthetic', warnAgeDays: 35, maxStaleDays: 45, dateCacheSize: 6, timeoutMs: 1000, maxOperations: 42 };
function repository() {
    return { version, metadata: { source: { generationDate: '2026-09-01' }, importedAt: '2026-09-01T00:00:00Z',
        coverage: { startDate: '2026-09-01', endDate: '2026-12-31', basis: 'Fixture' }, maxEventDayOffset: 1 },
        stations: ['AAA', 'BBB'].map(crs => ({ crs, name: crs, minimumChangeMinutes: 5 })),
        rules: { tsi: [], links: [] }, resolveServices: () => ({ services: [], diagnostics: { counts: {} } }), close() {} };
}
function emptyResult(req) {
    return { journeys: [], searchTruncated: false, warnings: [], pagination: {}, searchWindow: { from: req.time, to: req.time } };
}
function engine(overrides = {}) {
    return new PlannerEngine(config, { openDataset: async () => repository(), findJourneys: emptyResult,
        now: () => Date.parse('2026-09-16T12:00:00Z'), ...overrides });
}

test('engine uses internal execution overrides and reports preparation/search without narrowing the query', async () => {
    const stages = [], budgets = [], requests = [], prepSignals = [];
    const signal = { aborted: false };
    const repo = repository();
    repo.resolveServices = (date, options) => { prepSignals.push(options.signal); return { services: [], diagnostics: { counts: {} } }; };
    const instance = engine({ openDataset: async () => repo, findJourneys(req, net, options) {
        requests.push(req); budgets.push(options); return emptyResult(req);
    } });
    await instance.search({ request }, signal, { timeoutMs: 600_000, maxOperations: 1_000_000_000, onProgress: phase => stages.push(phase) });
    assert.deepEqual(stages, ['preparing', 'searching']);
    assert.equal(budgets[0].maxOperations, 1_000_000_000);
    assert.ok(budgets[0].timeoutMs > 590_000 && budgets[0].timeoutMs <= 600_000);
    assert.equal(budgets[0].signal, signal);
    assert.ok(prepSignals.length > 0 && prepSignals.every(value => value === signal));
    assert.deepEqual(requests[0], request);
    // Execution options do not alter dataset pinning or the shared result cache.
    await instance.search({ request, version }, signal, { timeoutMs: 2000, maxOperations: 100 });
    assert.equal(budgets.length, 1);
});

test('engine retains normal limits and rejects invalid internal overrides', async () => {
    let budget;
    const instance = engine({ findJourneys(req, net, options) { budget = options; return emptyResult(req); } });
    await instance.search({ request });
    assert.equal(budget.maxOperations, config.maxOperations);
    assert.ok(budget.timeoutMs > 0 && budget.timeoutMs <= config.timeoutMs);
    for (const execution of [{ timeoutMs: 0 }, { maxOperations: 0 }, { maxOperations: Infinity }]) {
        await assert.rejects(instance.search({ request }, undefined, execution), { code: 'INVALID_REQUEST' });
    }
});

test('engine deadline covers preparation and cancelled date resolution never enters its cache', async () => {
    let routed = false;
    const delayed = engine({ openDataset: async () => {
        await new Promise(resolve => setTimeout(resolve, 10)); return repository();
    }, findJourneys() { routed = true; return emptyResult(request); } });
    await assert.rejects(delayed.search({ request }, undefined, { timeoutMs: 1 }), { code: 'SEARCH_TIMEOUT' });
    assert.equal(routed, false);
    const repo = repository();
    repo.resolveServices = () => { throw Object.assign(new Error('Stopped'), { code: 'SEARCH_CANCELLED' }); };
    const cancelled = engine({ openDataset: async () => repo });
    await assert.rejects(cancelled.search({ request }), { code: 'SEARCH_CANCELLED', status: 499 });
    assert.equal(cancelled.dates.size, 0);
    assert.equal(cancelled.networks.size, 0);
    assert.equal(cancelled.searches.size, 0);
});

test('calendar checkpoints propagate cancellation and execution errors rather than partial diagnostics', () => {
    let cancelled = false, read = false;
    const repo = { dateCandidates() { read = true; cancelled = true; return []; } };
    assert.throws(() => resolveServices(repo, '2026-09-16', { signal: { get aborted() { return cancelled; } } }), { code: 'SEARCH_CANCELLED' });
    assert.equal(read, true);
    const error = Object.assign(new Error('Deadline'), { code: 'SEARCH_TIMEOUT' });
    assert.throws(() => resolveServices(repo, '2026-09-16', { signal: { get aborted() { throw error; } } }), value => value === error);
});
