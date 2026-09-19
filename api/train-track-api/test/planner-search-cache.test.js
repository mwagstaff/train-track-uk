import test from 'node:test';
import assert from 'node:assert/strict';
import { PlannerEngine } from '../lib/planner/engine.js';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';
import { PlannerSearchJobs } from '../lib/planner/search-jobs.js';
import { normalizeRequest } from '../lib/planner/contract.js';

const version = 'a'.repeat(64);
const now = Date.parse('2026-09-18T06:00:00Z');
const body = { origin: 'AAA', destination: 'CCC', time: '2026-09-18T07:00:00Z', timeType: 'departAfter',
    allowedModes: ['rail'], maxChanges: 0, windowMinutes: 120, limit: 2 };
const config = { ...plannerConfig({}), datasetPath: '/synthetic/search-cache', prewarm: false,
    tubeTrackEnabled: false, timeoutMs: 5000 };

function data() {
    const departure = Date.parse(body.time) + 60000;
    return {
        repo: { version, stations: ['AAA', 'CCC'].map(crs => ({ crs, name: crs, minimumChangeMinutes: 5 })),
            rules: { tsi: [], links: [] },
            metadata: { source: { generationDate: '2026-09-18' }, importedAt: '2026-09-18T05:00:00Z',
                maxEventDayOffset: 1, coverage: { startDate: '2026-09-01', endDate: '2026-10-01', basis: 'Synthetic fixture' },
                limitations: [] } },
        services: [{ id: 'cache-train', uid: 'cache-train', originDate: '2026-09-18', operator: 'OP', mode: 'rail',
            calls: [{ station: 'AAA', departure, arrival: null, canBoard: true, canAlight: false },
                { station: 'CCC', arrival: departure + 20 * 60000, departure: null, canBoard: false, canAlight: true }] }]
    };
}

function fixture(t) {
    const { repo, services } = data();
    repo.resolveServices = date => ({ services: date === '2026-09-18' ? services : [], diagnostics: { counts: {} } });
    repo.close = () => {};
    const engine = new PlannerEngine(config, { openDataset: async () => repo, now: () => now });
    t.after(() => engine.close());
    return engine;
}

const cacheStatuses = telemetry => telemetry.filter(value => value.cacheStatus).map(value => value.cacheStatus);

test('clearing search results forces both algorithms to miss without discarding prepared data or journey details', async t => {
    const engine = fixture(t), telemetry = [];
    const execution = { onTelemetry: value => telemetry.push(value) };
    let raptor;
    for (const algorithm of ['original', 'raptor']) {
        const request = normalizeRequest({ ...body, algorithm });
        const first = await engine.search({ request }, undefined, execution);
        await engine.search({ request }, undefined, execution);
        if (algorithm === 'raptor') raptor = first;
    }
    const index = engine.raptorIndex;
    const prepared = { datasets: [...engine.datasets], dates: [...engine.dates], networks: [...engine.networks],
        journeys: [...engine.journeys] };
    engine.tubeSnapshots.set('retained-tube', { expiresAt: now + 3600000 });
    const liveSnapshots = new Map([['retained-live', {}]]);
    engine.livePlanner = { snapshots: liveSnapshots };

    assert.deepEqual(engine.clearSearchCache(), { clearedSearches: 2 });
    assert.equal(engine.searches.size, 0);
    assert.equal(engine.raptorIndex, index);
    for (const [name, entries] of Object.entries(prepared)) assert.deepEqual([...engine[name]], entries);
    assert.equal(engine.tubeSnapshots.size, 1);
    assert.equal(engine.livePlanner.snapshots, liveSnapshots);
    assert.equal(liveSnapshots.size, 1);
    assert.equal((await engine.journey(raptor.journeys[0].id)).journey.legs[0].serviceCallingPoints.length, 2);

    for (const algorithm of ['original', 'raptor']) {
        const response = await engine.search({ request: normalizeRequest({ ...body, algorithm }) }, undefined, execution);
        assert.equal(response.search.algorithm, algorithm);
        assert.equal(response.journeys.length, 1);
    }
    assert.deepEqual(cacheStatuses(telemetry), ['miss', 'hit', 'miss', 'hit', 'miss', 'miss']);
    assert.equal(engine.raptorIndex, index);
    assert.deepEqual(engine.clearSearchCache(), { clearedSearches: 2 });
    assert.deepEqual(engine.clearSearchCache(), { clearedSearches: 0 });
});

test('searches already in flight at cache clearing cannot refill it after completing', async t => {
    for (const [algorithm, method] of ['original', 'raptor'].flatMap(algorithm =>
        ['dataset', 'route'].map(method => [algorithm, method]))) {
        const engine = fixture(t);
        let entered, release;
        const ready = new Promise(resolve => { entered = resolve; });
        const gate = new Promise(resolve => { release = resolve; });
        const original = engine[method].bind(engine);
        engine[method] = async (...args) => {
            const result = await original(...args);
            entered();
            await gate;
            return result;
        };
        const request = normalizeRequest({ ...body, algorithm });
        const telemetry = [], execution = { onTelemetry: value => telemetry.push(value) };
        const inFlight = engine.search({ request }, undefined, execution);
        await ready;
        assert.deepEqual(engine.clearSearchCache(), { clearedSearches: 0 });
        release();
        const completed = await inFlight;
        assert.equal(completed.journeys.length, 1, 'Clearing must not cancel a search or remove its result');
        assert.equal(engine.searches.size, 0, 'Pre-clear work must not publish a reusable result');
        await engine.search({ request }, undefined, execution);
        await engine.search({ request }, undefined, execution);
        assert.deepEqual(cacheStatuses(telemetry), ['miss', 'miss', 'hit']);
    }
});

test('clearSearchCache uses the actual routing worker and leaves it alive for uncached original and RAPTOR searches', async t => {
    const { repo, services } = data();
    const source = `
        import { PlannerEngine } from ${JSON.stringify(new URL('../lib/planner/engine.js', import.meta.url).href)};
        const repo = ${JSON.stringify(repo)}, services = ${JSON.stringify(services)};
        repo.resolveServices = date => ({ services: date === '2026-09-18' ? services : [], diagnostics: { counts: {} } });
        repo.close = () => {};
        PlannerEngine.prototype.loadStationPresentation = async function() {
            this.now = () => ${now};
            this.openDataset = async () => repo;
        };
        await import(${JSON.stringify(new URL('../lib/planner/worker.js', import.meta.url).href)});
    `;
    const service = new PlannerService({ ...config, workerCount: 1 }, { workerURL: new URL(`data:text/javascript,${encodeURIComponent(source)}`) });
    service.metadata = () => assert.fail('Cache clearing must not target the separate metadata worker');
    t.after(() => service.close());
    const telemetry = [], options = { onTelemetry: value => telemetry.push(value) };
    let retainedJourney;
    for (const algorithm of ['original', 'raptor']) {
        const first = await service.search({ ...body, algorithm }, options);
        await service.search({ ...body, algorithm }, options);
        retainedJourney = first.journeys[0].id;
    }
    const worker = service.worker;
    const before = await service.call('runtime', {});
    assert.deepEqual(await service.clearSearchCache(), { clearedSearches: 2 });
    assert.equal(service.worker, worker);
    const after = await service.call('runtime', {});
    assert.equal(after.caches.searches, 0);
    for (const name of ['datasets', 'dates', 'networks', 'raptorIndexes', 'journeys']) {
        assert.equal(after.caches[name], before.caches[name], `${name} must stay prepared/retained`);
    }
    assert.ok(service.journeys.has(retainedJourney), 'Retained result details in the parent must not be cleared');
    assert.equal((await service.journey(retainedJourney)).journey.legs[0].serviceCallingPoints.length, 2);
    for (const algorithm of ['original', 'raptor']) {
        assert.equal((await service.search({ ...body, algorithm }, options)).search.algorithm, algorithm);
    }
    assert.deepEqual(cacheStatuses(telemetry), ['miss', 'hit', 'miss', 'hit', 'miss', 'miss']);
    assert.equal(service.worker, worker);

    const jobs = new PlannerSearchJobs(service);
    t.after(() => jobs.close());
    const request = { ...body, algorithm: 'raptor' };
    const first = await jobs.submit(request, { client: 'cache-test', idempotencyKey: 'before-clear' });
    await service.call('runtime', {});
    assert.equal(jobs.get(first.id).status, 'completed');
    assert.equal(jobs.leases.get(first.id).work.telemetry.cacheStatus, 'hit');
    await service.clearSearchCache();
    assert.equal(jobs.get(first.id).status, 'completed', 'Existing polling leases must retain their completed results');
    assert.equal((await jobs.submit(request, { client: 'cache-test', idempotencyKey: 'before-clear' })).id, first.id);
    const fresh = await jobs.submit(request, { client: 'cache-test', idempotencyKey: 'after-clear' });
    await service.call('runtime', {});
    assert.notEqual(fresh.id, first.id);
    assert.equal(jobs.get(fresh.id).status, 'completed');
    assert.equal(jobs.leases.get(fresh.id).work.telemetry.cacheStatus, 'miss');
    assert.equal(jobs.get(first.id).status, 'completed');
    assert.equal(service.worker, worker);
});

test('cache clearing respects service cancellation and closure without creating a worker', async t => {
    const service = new PlannerService(config);
    t.after(() => service.close());
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(service.clearSearchCache({ signal: controller.signal }), { code: 'SEARCH_CANCELLED' });
    assert.equal(service.worker, null);
    service.close();
    await assert.rejects(service.clearSearchCache(), { code: 'DATASET_UNAVAILABLE' });
    assert.equal(service.worker, null);
});
