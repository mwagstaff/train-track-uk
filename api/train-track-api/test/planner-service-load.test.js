import assert from 'node:assert/strict';
import test from 'node:test';
import { formatLoadSummary, loadWarnings, parseAdmissionCap, parseCpuTime, parseLevels,
    runPlannerServiceLoad, verifyLoadCache } from '../scripts/planner-service-load.js';

test('load helpers validate bounded stages and cumulative process CPU time', () => {
    assert.deepEqual(parseLevels('5,10,20,50'), [5, 10, 20, 50]);
    assert.throws(() => parseLevels('5,5'), /ascending/);
    assert.throws(() => parseLevels('51'), /1 to 50/);
    assert.equal(parseCpuTime('0:52.76'), 52.76);
    assert.equal(parseCpuTime('1:02:34.56'), 3754.56);
    assert.equal(parseAdmissionCap('20'), 20);
    assert.throws(() => parseAdmissionCap('101'), /1 to 100/);
    assert.throws(() => parseAdmissionCap('0'), /1 to 100/);
});

test('load stage sends distinct concurrent RAPTOR searches and records rejection separately', async () => {
    const token = 'load-test-service-token-long-enough';
    const bodies = []; let clears = 0, cpuSeconds = 10;
    const json = (value, status = 200) => new Response(JSON.stringify(value), { status });
    const fetchImpl = async (url, options = {}) => {
        if (url.endsWith('/healthcheck')) return json({ status: 'ok' });
        assert.equal(options.headers?.Authorization, `Bearer ${token}`);
        if (url.endsWith('/status')) return json({ available: true,
            dataset: { version: 'test-version', coverage: { from: '2026-09-01', to: '2026-10-01' } } });
        if (url.endsWith('/cache/clear')) { clears++; return json({ clearedSearches: 2 }); }
        if (url.endsWith('/search')) {
            const body = JSON.parse(options.body); bodies.push(body);
            return body.time.endsWith('09:03:00.000Z') || body.time.endsWith('09:04:00.000Z')
                ? json({ error: { code: 'SEARCH_BUSY' } }, 429)
                : json({ journeys: [{ id: 'journey' }] });
        }
        throw new Error(`Unexpected URL: ${url}`);
    };
    const report = await runPlannerServiceLoad({ token, pid: 123, levels: [5], fetchImpl,
        now: () => Date.parse('2026-09-20T12:00:00Z'),
        readUsage: async () => ({ rssBytes: 500 * 1048576, cpuSeconds: cpuSeconds += 0.01 }) });
    assert.equal(clears, 1);
    assert.equal(bodies.length, 5);
    assert.equal(new Set(bodies.map(body => body.time)).size, 5);
    assert.ok(bodies.every(body => body.algorithm === 'raptor'));
    assert.equal(report.stages[0].successful, 3);
    assert.deepEqual(report.stages[0].responses, { 200: 3, SEARCH_BUSY: 2 });
    assert.equal(report.stages[0].usage.peakRssBytes, 500 * 1048576);
    assert.equal(report.healthAfterLoad, 200);
    assert.match(formatLoadSummary(report), /Simultaneous users\s+Completed\s+Other responses/);
    assert.match(formatLoadSummary(report), /5\s+3\/5\s+2 busy/);
    assert.equal(loadWarnings(report, true).length, 2);
});

test('admission override is restored after the load test and included in the report', async () => {
    const token = 'load-test-service-token-long-enough';
    const calls = [];
    const json = (value, status = 200) => new Response(JSON.stringify(value), { status });
    const fetchImpl = async (url, options = {}) => {
        if (url.endsWith('/status')) return json({ available: true,
            dataset: { version: 'test-version', coverage: { from: '2026-09-01', to: '2026-10-01' } } });
        if (url.endsWith('/load/admission')) {
            calls.push({ method: options.method, body: JSON.parse(options.body) });
            return options.method === 'POST'
                ? json({ leaseId: 'test-lease', configuredMaxQueue: 8, maxQueue: 20 })
                : json({ restored: true, maxQueue: 8 });
        }
        if (url.endsWith('/cache/clear')) return json({ clearedSearches: 0 });
        if (url.endsWith('/search')) return json({ journeys: [{ id: 'journey' }] });
        if (url.endsWith('/healthcheck')) return json({ status: 'ok' });
        throw new Error(`Unexpected URL: ${url}`);
    };
    const report = await runPlannerServiceLoad({ token, pid: 123, levels: [1], admissionCap: 20, fetchImpl,
        now: () => Date.parse('2026-09-20T12:00:00Z'),
        readUsage: async () => ({ rssBytes: 500 * 1048576, cpuSeconds: 10 }) });
    assert.deepEqual(calls, [{ method: 'POST', body: { maxQueue: 20 } },
        { method: 'DELETE', body: { leaseId: 'test-lease' } }]);
    assert.deepEqual(report.admission, { configuredMaxQueue: 8, testMaxQueue: 20 });
    assert.deepEqual(loadWarnings({ ...report, stages: [{ ...report.stages[0],
        results: [{ route: 'KTH-INV', status: 504, errorCode: 'SEARCH_TIMEOUT', durationMs: 2288.5 }] }] }, true),
    ['1 users: KTH-INV timeout (HTTP 504, 2288.5 ms)']);
});

test('admission override is restored if a stage cannot start', async () => {
    const token = 'load-test-service-token-long-enough';
    const methods = [];
    const json = (value, status = 200) => new Response(JSON.stringify(value), { status });
    const fetchImpl = async (url, options = {}) => {
        if (url.endsWith('/status')) return json({ available: true,
            dataset: { version: 'test-version', coverage: { from: '2026-09-01', to: '2026-10-01' } } });
        if (url.endsWith('/load/admission')) {
            methods.push(options.method);
            return options.method === 'POST'
                ? json({ leaseId: 'test-lease', configuredMaxQueue: 8, maxQueue: 20 })
                : json({ restored: true, maxQueue: 8 });
        }
        if (url.endsWith('/cache/clear')) return json({}, 503);
        throw new Error(`Unexpected URL: ${url}`);
    };
    await assert.rejects(runPlannerServiceLoad({ token, pid: 123, levels: [1], admissionCap: 20, fetchImpl,
        now: () => Date.parse('2026-09-20T12:00:00Z') }), /Could not clear search-result caches/);
    assert.deepEqual(methods, ['POST', 'DELETE']);
});

test('cache verification accepts only this stage’s matching RAPTOR miss and rejects a hit', async () => {
    const requestedTime = '2026-09-20T09:00:00.000Z';
    const stage = { users: 1, successful: 1, startedAt: '2026-09-20T08:59:59.000Z',
        endedAt: '2026-09-20T09:00:01.000Z', results: [{ route: 'KTH-VIC', requestedTime }] };
    const report = { stages: [stage] };
    let rows = [
        { origin: 'KTH', destination: 'VIC', requestedTime: new Date(requestedTime),
            cacheStatus: 'miss', status: 'success' },
        { origin: 'ABD', destination: 'PNZ', requestedTime: new Date(requestedTime),
            cacheStatus: 'hit', status: 'success' }
    ];
    const client = { async connect() {}, db() { return { collection() { return {
        find(filter) {
            assert.equal(filter.algorithm, 'raptor');
            assert.deepEqual(filter.requestedTime.$in, [new Date(requestedTime)]);
            return { async toArray() { return rows; } };
        }
    }; } }; }, async close() {} };
    assert.equal(await verifyLoadCache(report, 'mongodb://unused', () => client), true);
    assert.deepEqual(stage.cache, { logged: 1, misses: 1, successfulMisses: 1, hits: 0, unknown: 0 });
    rows = [{ ...rows[0], cacheStatus: 'hit' }];
    assert.equal(await verifyLoadCache(report, 'mongodb://unused', () => client), false);
});
