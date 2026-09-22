import assert from 'node:assert/strict';
import test from 'node:test';
import { chooseSearchTime, durationSummary, parseComplexRoutes, runPlannerServiceSmoke } from '../scripts/planner-service-smoke.js';

test('service smoke helpers choose a covered date and report nearest-rank timings', () => {
    const dataset = { coverage: { from: '2026-09-01', to: '2026-09-30' } };
    assert.equal(chooseSearchTime(dataset, Date.parse('2026-09-20T12:00:00Z')), '2026-09-21T09:00:00Z');
    assert.equal(chooseSearchTime(dataset, Date.parse('2026-10-20T12:00:00Z')), '2026-09-30T09:00:00Z');
    assert.deepEqual(durationSummary([30, 10, 20]), { count: 3, minMs: 10, medianMs: 20, p95Ms: 30, maxMs: 30 });
    assert.deepEqual(parseComplexRoutes('kth-inv, ABD-PNZ'), [
        { origin: 'KTH', destination: 'INV' }, { origin: 'ABD', destination: 'PNZ' }
    ]);
    assert.throws(() => parseComplexRoutes('KTH-KTH'), /Invalid complex route/);
});

test('service smoke exercises authenticated status, searches, detail and queued work', async () => {
    const token = 'planner-smoke-test-token-long-enough';
    const journeyId = `${'a'.repeat(64)}.${'b'.repeat(32)}`;
    const json = (value, status = 200, headers = {}) => new Response(JSON.stringify(value), {
        status, headers: { 'Content-Type': 'application/json', ...headers }
    });
    const calls = [];
    const fetchImpl = async (url, options) => {
        assert.equal(options.headers.Authorization, `Bearer ${token}`);
        const parsed = new URL(url); calls.push(`${options.method} ${parsed.pathname}`);
        if (parsed.pathname.endsWith('/internal/planner/v1/health')) return json({ hostId: 'mini-planner', protocolVersion: 1, ready: false });
        if (parsed.pathname.endsWith('/internal/planner/v1/readiness')) return json({ readinessReason: 'ingestion_unavailable', ingestion: { enabled: false } });
        if (parsed.pathname.endsWith('/internal/planner/v1/cache/clear')) return json({ clearedSearches: 1 });
        if (parsed.pathname.endsWith('/internal/planner/metrics')) return new Response('process_resident_memory_bytes{service_name="planner"} 104857600\n');
        if (parsed.pathname.endsWith('/status')) return json({ available: true,
            dataset: { version: 'dataset-one', coverage: { from: '2026-09-01', to: '2026-10-01' } } });
        if (parsed.pathname.endsWith('/stations')) return json({ stations: [{ crs: parsed.searchParams.get('q') }] });
        if (parsed.pathname.includes('/journeys/')) return json({ journey: { legs: [{ kind: 'vehicle' }] } });
        if (parsed.pathname.endsWith('/search-jobs')) return json({ id: 'job-one', status: 'completed', pollAfterMs: 1000,
            result: { journeys: [{ id: journeyId }] } }, 202, { 'Retry-After': '1' });
        if (parsed.pathname.endsWith('/search')) {
            const body = JSON.parse(options.body);
            if (body.origin === 'KTH' && body.destination === 'INV' && body.algorithm === 'raptor') {
                return json({ error: { code: 'SEARCH_TIMEOUT', message: 'work budget exceeded' } }, 504);
            }
            return json({ journeys: [{ id: journeyId }], search: { searchTruncated: false } });
        }
        return json({ error: { code: 'NOT_FOUND', message: 'missing test route' } }, 404);
    };
    const report = await runPlannerServiceSmoke({ token, fetchImpl, baseUrl: 'http://planner.test', runs: 1,
        complexRoutes: [{ origin: 'KTH', destination: 'INV' }],
        now: () => Date.parse('2026-09-20T12:00:00Z') });
    assert.equal(report.hostId, 'mini-planner');
    assert.equal(report.searches.length, 2);
    assert.equal(report.detail.legCount, 1);
    assert.equal(report.queuedSearch.journeyCount, 1);
    assert.equal(report.complexRoutes[0].algorithms[0].direct.status, 200);
    assert.equal(report.complexRoutes[0].algorithms[1].direct.errorCode, 'SEARCH_TIMEOUT');
    assert.equal(report.complexRoutes[0].algorithms[1].queuedFallback.journeyCount, 1);
    assert.equal(report.residentMemoryBytes, 104857600);
    assert.ok(calls.includes('POST /api/v3/journey-planner/search'));
    assert.equal(report.cacheClears, 0);

    const beforeColdRun = calls.length;
    const cold = await runPlannerServiceSmoke({ token, fetchImpl, baseUrl: 'http://planner.test', runs: 1,
        complexRoutes: [{ origin: 'KTH', destination: 'INV' }], clearCacheBeforeSearch: true,
        now: () => Date.parse('2026-09-20T12:00:00Z') });
    assert.equal(cold.cachePolicy, 'clear-before-each-search');
    assert.equal(cold.cacheClears, 6);
    const coldCalls = calls.slice(beforeColdRun);
    for (let index = 0; index < coldCalls.length; index++) {
        if (coldCalls[index] === 'POST /api/v3/journey-planner/search'
            || coldCalls[index] === 'POST /api/v3/journey-planner/search-jobs') {
            assert.equal(coldCalls[index - 1], 'POST /internal/planner/v1/cache/clear');
        }
    }
});
