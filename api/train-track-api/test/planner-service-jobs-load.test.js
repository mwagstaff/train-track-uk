import assert from 'node:assert/strict';
import test from 'node:test';
import { formatJobsSummary, jobsLoadWarnings, parseDuration, parseUsers,
    runPlannerJobsLoad, summarizeResourceSamples } from '../scripts/planner-service-jobs-load.js';
import { verifyLoadCache } from '../scripts/planner-service-load.js';
import { plannerConfig } from '../lib/planner/service.js';

test('queued-job limit defaults to 20 and load arguments remain bounded', () => {
    assert.equal(plannerConfig({}).maxSearchJobs, 20);
    assert.equal(plannerConfig({ PLANNER_MAX_SEARCH_JOBS: '8' }).maxSearchJobs, 8);
    assert.equal(parseDuration('60'), 60);
    assert.equal(parseDuration('0'), 0);
    assert.throws(() => parseDuration('601'), /0 to 600/);
    assert.equal(parseUsers('20'), 20);
    assert.throws(() => parseUsers('33'), /1 to 32/);
});

test('resource summary keeps planner CPU, host CPU, RSS, free memory and swap separate', () => {
    const usage = summarizeResourceSamples([
        { at: 0, planner: { cpuSeconds: 10, rssBytes: 100 }, host: {
            cpuTotalTicks: 1000, cpuIdleTicks: 500, freeMemoryPercent: 60, swapUsedMiB: 0 } },
        { at: 1000, planner: { cpuSeconds: 13, rssBytes: 200 }, host: {
            cpuTotalTicks: 2000, cpuIdleTicks: 750, freeMemoryPercent: 55, swapUsedMiB: 5 } }
    ]);
    assert.equal(usage.peakPlannerCpuPercentOneCore, 300);
    assert.equal(usage.peakHostCpuPercent, 75);
    assert.equal(usage.peakPlannerRssBytes, 200);
    assert.equal(usage.minHostFreeMemoryPercent, 55);
    assert.equal(usage.peakSwapUsedMiB, 5);
});

test('job load uses 20 distinct callers, polls to completion and reports end-to-end time', async () => {
    const token = 'test-planner-token-long-enough';
    const requests = [], jobs = new Map();
    const json = (value, status = 200) => new Response(JSON.stringify(value), { status });
    const fetchImpl = async (url, options = {}) => {
        if (url.endsWith('/healthcheck')) return json({ status: 'ok' });
        assert.equal(options.headers?.Authorization, `Bearer ${token}`);
        if (url.endsWith('/status')) return json({ available: true,
            dataset: { version: 'test-version', coverage: { from: '2026-09-01', to: '2026-10-01' } } });
        if (url.endsWith('/cache/clear')) return json({ clearedSearches: 0 });
        if (url.endsWith('/search-jobs')) {
            const body = JSON.parse(options.body);
            requests.push({ body, headers: options.headers });
            const id = `job-${requests.length}`;
            jobs.set(id, body);
            return json({ id, status: 'queued', queuePosition: requests.length, pollAfterMs: 1 }, 202);
        }
        const id = url.split('/').at(-1);
        if (jobs.has(id) && options.method !== 'DELETE') return json({ id, status: 'completed',
            result: { journeys: [{ id: 'journey' }] } });
        throw new Error(`Unexpected URL: ${url}`);
    };
    let cpu = 10, ticks = 1000;
    const report = await runPlannerJobsLoad({ token, pid: 123, levels: [20], durationSeconds: 0,
        fetchImpl, minPollMs: 1, now: () => Date.parse('2026-09-20T12:00:00Z'),
        readPlanner: async () => ({ rssBytes: 600 * 1048576, cpuSeconds: cpu += 0.01 }),
        readHost: async () => ({ cpuTotalTicks: ticks += 100, cpuIdleTicks: ticks / 2,
            freeMemoryPercent: 60, swapUsedMiB: 0 }) });
    assert.equal(report.source, 'search-job');
    assert.equal(report.stages.length, 1);
    assert.equal(report.stages[0].successful, 20);
    assert.equal(report.stages[0].attempted, 20);
    assert.equal(new Set(requests.map(request => request.body.time)).size, 20);
    assert.equal(new Set(requests.map(request => request.headers['X-Planner-Client'])).size, 20);
    assert.equal(new Set(requests.map(request => request.headers['X-Planner-Caller-Network'])).size, 20);
    assert.ok(requests.every(request => request.body.algorithm === 'raptor'
        && request.headers['X-Planner-Forwarded'] === 'gateway-v1'));
    assert.match(formatJobsSummary(report), /burst 20\s+20\/20/);
    assert.deepEqual(jobsLoadWarnings(report, true), []);
});

test('job cache verification reads search-job logs and uses attempted count', async () => {
    const requestedTime = '2026-09-20T09:00:00.000Z';
    const report = { source: 'search-job', stages: [{ users: 20, attempted: 1, successful: 1,
        startedAt: '2026-09-20T08:59:59.000Z', endedAt: '2026-09-20T09:00:01.000Z',
        results: [{ route: 'KTH-VIC', requestedTime }] }] };
    const client = { async connect() {}, db() { return { collection() { return {
        find(filter) {
            assert.equal(filter.source, 'search-job');
            return { async toArray() { return [{ origin: 'KTH', destination: 'VIC',
                requestedTime: new Date(requestedTime), cacheStatus: 'miss', status: 'success',
                metrics: { admissionQueueMs: 50, queueWaitMs: 25 } }]; } };
        }
    }; } }; }, async close() {} };
    assert.equal(await verifyLoadCache(report, 'mongodb://unused', () => client), true);
    assert.equal(report.stages[0].results[0].serverQueueMs, 75);
});
