import test from 'node:test';
import assert from 'node:assert/strict';
import { PlannerSearchLog, PlannerSearchLogReader, normalizePlannerSearchLogQuery, PLANNER_SEARCH_RETENTION_MS } from '../lib/planner-search-log.js';
import { PLANNER_SEARCH_INDEXES, COLLECTIONS } from '../lib/mongo-client.js';

const epoch = Date.parse('2026-09-17T12:00:00Z');
const rowFrom = operation => operation.updateOne.update[0].$replaceWith.$cond[2].$literal;
const quiet = () => {};
const turn = () => new Promise(resolve => setImmediate(resolve));

test('search lifecycle persists allowlisted public fields, timestamps, queue-inclusive duration and first terminal outcome', async () => {
    const writes = [];
    let now = epoch, tick = 100;
    const log = new PlannerSearchLog({ now: () => now, monotonicNow: () => tick,
        getCollection: async () => ({ bulkWrite: async operations => writes.push(...operations) }) });
    const handle = log.start({ source: 'search-job', request: { origin: ' kth ', destination: 'VIC', via: ['BMS'],
        time: new Date(epoch).toISOString(), timeType: 'departAfter', realtime: 'apply', token: 'never-store',
        deviceId: 'never-store', cursor: 'never-store' }, client: 'never-store', network: 'never-store' });
    await log.flush();
    const pending = rowFrom(writes[0]);
    assert.equal(pending.status, 'pending');
    assert.equal(pending.finishedAt, null);
    assert.equal(pending.durationMs, null);
    assert.ok(pending.startedAt instanceof Date);
    tick += 2300; now += 2300;
    handle.update({ phase: 'running', cacheStatus: 'miss', coalesced: true, datasetVersion: 'test-dataset' });
    tick += 400; now += 400;
    handle.finish({ status: 'success', resultCount: 0, outcome: 'empty' });
    handle.finish({ status: 'fail', errorCode: 'SECOND_FINISH' });
    handle.update({ cacheStatus: 'hit' });
    await log.flush();
    const completed = rowFrom(writes.at(-1));
    assert.equal(completed._id, pending._id);
    assert.equal(completed.origin, 'KTH');
    assert.equal(completed.destination, 'VIC');
    assert.deepEqual(completed.via, ['BMS']);
    assert.equal(completed.status, 'success');
    assert.equal(completed.outcome, 'empty');
    assert.equal(completed.durationMs, 2700);
    assert.equal(completed.finishedAt.getTime(), epoch + 2700);
    assert.equal(completed.cacheStatus, 'miss');
    assert.equal(completed.coalesced, true);
    assert.equal(completed.resultCount, 0);
    assert.ok(completed.revision > pending.revision);
    assert.ok(!JSON.stringify(completed).includes('never-store'));
    assert.equal(writes.length, 2, 'Queued phase and terminal updates are coalesced');
});

test('failed pending write cannot discard a newer finish and retries remain bounded', async () => {
    let rejectWrite;
    const writes = [];
    let calls = 0;
    const db = { bulkWrite: async operations => {
        writes.push(...operations);
        if (++calls === 1) return new Promise((resolve, reject) => { rejectWrite = reject; });
    } };
    const log = new PlannerSearchLog({ now: () => epoch, getCollection: async () => db, retryMs: 10000, warn: quiet });
    const handle = log.start({ request: { origin: 'ECR', destination: 'BYM' } });
    const first = log.flush();
    await turn();
    handle.finish({ status: 'fail', errorCode: 'SEARCH_TIMEOUT', finishedAt: epoch + 9000 });
    rejectWrite(new Error('database unavailable'));
    await first;
    assert.equal(log.pending.size, 1);
    await log.flush();
    assert.equal(rowFrom(writes.at(-1)).status, 'fail');
    assert.equal(rowFrom(writes.at(-1)).errorCode, 'SEARCH_TIMEOUT');
    assert.equal(log.dropped, 0);
    assert.equal(log.pending.size, 0);

    const unavailable = new PlannerSearchLog({ now: () => epoch, retryMs: 10000, warn: quiet,
        getCollection: async () => { throw new Error('offline'); } });
    unavailable.start({}).finish({ status: 'other', outcome: 'cancelled' });
    await unavailable.flush(); await unavailable.flush(); await unavailable.flush();
    assert.equal(unavailable.pending.size, 0);
    assert.equal(unavailable.dropped, 1);
});

test('an unresolved Mongo connection does not multiply actual operations or grow the buffer without bound', async () => {
    let resolveCollection, connections = 0;
    const log = new PlannerSearchLog({ now: () => epoch, maxPending: 4, warn: quiet,
        getCollection: () => { connections++; return new Promise(resolve => { resolveCollection = resolve; }); } });
    log.start({});
    const work = log.flush();
    await turn();
    for (let i = 0; i < 100; i++) log.start({}).finish({ status: 'success' });
    assert.equal(log.pending.size, 4);
    assert.equal(connections, 1);
    assert.ok(log.dropped > 0);
    resolveCollection({ bulkWrite: async () => {} });
    await work;
    // Supply the recovered connection for the remaining bounded batch.
    log.getCollection = async () => ({ bulkWrite: async () => {} });
    await log.flush();
});

test('retention is fixed at seven days and expired buffered events are not reinserted', async () => {
    const ttl = PLANNER_SEARCH_INDEXES.find(index => index.expireAfterSeconds !== undefined);
    assert.equal(COLLECTIONS.plannerSearches, 'planner_searches');
    assert.deepEqual(ttl.key, { startedAt: 1 });
    assert.equal(ttl.expireAfterSeconds, 604800);
    let now = epoch, writes = 0;
    const log = new PlannerSearchLog({ now: () => now,
        getCollection: async () => ({ bulkWrite: async () => { writes++; } }) });
    const handle = log.start({});
    now += PLANNER_SEARCH_RETENTION_MS;
    handle.finish({ status: 'other', outcome: 'expired' });
    await log.flush();
    assert.equal(writes, 0);
});

test('admin queries allow only known sorts, sources and bounded pagination', () => {
    assert.deepEqual(normalizePlannerSearchLogQuery({}), { page: 1, pageSize: 50, sort: 'startedAt', direction: 'desc', range: '24h', source: 'all' });
    assert.deepEqual(normalizePlannerSearchLogQuery({ page: '999999999', per_page: '999999', sort: { $where: 'bad' },
        direction: 'sideways', range: 'forever', source: '$ne' }),
    { page: 100000, pageSize: 200, sort: 'startedAt', direction: 'desc', range: '24h', source: 'all' });
});

test('phase telemetry accumulates task deltas and sampled resource peaks without accepting arbitrary fields', async () => {
    const log = new PlannerSearchLog({ now: () => epoch, getCollection: async () => ({ bulkWrite: async () => {} }) });
    const handle = log.start({});
    handle.update({ metricsDelta: { routingMs: 10, routeCalls: 1, queueWaitMs: 5, secret: 99 },
        resourcePeaks: { heapUsedBytes: 500, rssBytes: 900 } });
    const first = [...log.pending.values()][0].row;
    handle.update({ metricsDelta: { routingMs: 20, routeCalls: 2, liveLookupMs: 15, cpuMs: NaN },
        resourcePeaks: { heapUsedBytes: 400, rssBytes: 1000 } });
    handle.finish({ status: 'success' });
    const row = [...log.pending.values()][0].row;
    assert.deepEqual(row.metrics, { routingMs: 30, routeCalls: 3, queueWaitMs: 5, liveLookupMs: 15 });
    assert.deepEqual(row.resourcePeaks, { heapUsedBytes: 500, rssBytes: 1000 });
    assert.equal(first.metrics.routingMs, 10, 'Earlier queued writes are immutable');
    await log.flush();
});

test('statistics cover all selected rows and p99 uses nearest rank, independent of table sorting and page size', async () => {
    const queries = [];
    let aggregates = 0;
    const db = {
        aggregate(pipeline) { aggregates++; assert.equal(pipeline[0].$match.source, 'search-job');
            return { toArray: async () => [{ _id: null, total: 250, success: 190, fail: 10, other: 20, pending: 30,
                completed: 200, measured: 200, maxDurationMs: 10000, averageDurationMs: 3000,
                cacheHits: 100, cacheMisses: 100, cacheUnknown: 50 }] }; },
        find(filter, options) {
            const query = { filter, options };
            queries.push(query);
            const cursor = { sort(value) { query.sort = value; return cursor; }, skip(value) { query.skip = value; return cursor; },
                limit(value) { query.limit = value; return cursor; },
                toArray: async () => options.projection ? [{ durationMs: 9000 }] : [{ _id: 'one', origin: 'KTH', revision: 3 }] };
            return cursor;
        }
    };
    const reader = new PlannerSearchLogReader({ getCollection: async () => db, now: () => epoch });
    const result = await reader.list({ source: 'search-job', range: '7d', page: 3, per_page: 50, sort: 'durationMs', direction: 'asc' });
    assert.equal(result.stats.p99DurationMs, 9000);
    assert.equal(result.stats.total, 250);
    assert.equal(result.totalPages, 5);
    assert.equal(result.stats.completed, 200);
    assert.equal(queries[0].skip, 2, '200 - ceil(200 * .99) from the longest duration');
    assert.deepEqual(queries[0].sort, { durationMs: -1 });
    assert.deepEqual(queries[0].filter.status, { $in: ['success', 'fail'] });
    assert.deepEqual(queries[1].sort, { durationMs: 1, _id: 1 });
    assert.equal(queries[1].skip, 100);
    assert.equal(queries[1].filter.startedAt.$gte.getTime(), epoch - PLANNER_SEARCH_RETENTION_MS);
    assert.equal(result.rows[0].revision, undefined);
    await reader.list({ source: 'search-job', range: '7d', page: 2 });
    assert.equal(aggregates, 1, 'Sort and pagination share a bounded statistics snapshot');
});

test('identical reads coalesce, read capacity is bounded, and a failed read releases its slot', async () => {
    let rejectConnection;
    const reader = new PlannerSearchLogReader({ maxReads: 1,
        getCollection: () => new Promise((resolve, reject) => { rejectConnection = reject; }) });
    const first = reader.list();
    assert.equal(reader.list(), first);
    await assert.rejects(reader.list({ page: 2 }), /busy/);
    rejectConnection(new Error('offline'));
    await assert.rejects(first, /offline/);
    assert.equal(reader.reads.size, 0);
});
