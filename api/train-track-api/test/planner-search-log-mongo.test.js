import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { MongoClient } from 'mongodb';
import { PlannerSearchLog, PlannerSearchLogReader, PLANNER_SEARCH_RETENTION_MS } from '../lib/planner-search-log.js';
import { PLANNER_SEARCH_INDEXES } from '../lib/mongo-client.js';

// Explicit opt-in: this test only writes a uniquely named temporary database
// on a local Mongo instance, and removes that database afterwards.
test('planner search log persists and queries real Mongo with seven-day TTL, sorting and full-window statistics', {
    skip: !process.env.MONGO_TEST_URI,
    timeout: 30000
}, async () => {
    const uri = process.env.MONGO_TEST_URI;
    const parsed = new URL(uri);
    assert.equal(parsed.protocol, 'mongodb:');
    assert.ok(['localhost', '127.0.0.1', '[::1]'].includes(parsed.hostname), 'Use an isolated local test Mongo instance.');
    const client = new MongoClient(uri, { serverSelectionTimeoutMS: 2000 });
    const database = client.db(`planner_log_test_${process.pid}_${randomUUID().replaceAll('-', '')}`);
    let log;
    try {
        await client.connect();
        const collection = database.collection('planner_searches');
        await collection.createIndexes(PLANNER_SEARCH_INDEXES);
        const indexes = await collection.listIndexes().toArray();
        const ttl = indexes.find(index => index.name === 'started_at_7_day_ttl');
        assert.deepEqual(ttl.key, { startedAt: 1 });
        assert.equal(ttl.expireAfterSeconds, PLANNER_SEARCH_RETENTION_MS / 1000);

        const now = Date.now();
        const writes = [];
        const revisionLog = new PlannerSearchLog({ now: () => now, getCollection: () => ({
            bulkWrite: (operations, options) => {
                writes.push(structuredClone(operations));
                return collection.bulkWrite(operations, options);
            }
        }) });
        const guarded = revisionLog.start({ request: { origin: 'KTH', destination: 'VIC' } });
        await revisionLog.flush();
        guarded.finish({ status: 'success', resultCount: 0, cacheStatus: 'hit' });
        await revisionLog.flush();
        // Simulate an older pending write committing after its client timed out
        // and after a newer terminal write has already reached the database.
        await collection.bulkWrite(writes[0]);
        const guardedResult = await collection.findOne({ origin: 'KTH' });
        assert.equal(guardedResult.status, 'success');
        assert.equal(guardedResult.resultCount, 0);
        assert.equal(guardedResult.cacheStatus, 'hit');
        assert.equal(guardedResult.revision, 2);
        await collection.deleteOne({ _id: guardedResult._id });

        log = new PlannerSearchLog({ getCollection: () => collection, now: () => now, maxPending: 500 });
        const station = index => `A${String.fromCharCode(65 + Math.floor(index / 26))}${String.fromCharCode(65 + index % 26)}`;
        for (let index = 0; index < 245; index++) {
            const startedAt = new Date(now - (index < 240 ? (index + 1) * 60000 : 2 * 86400000));
            const row = log.start({ source: index % 2 ? 'saved-route' : 'search', startedAt,
                request: { origin: station(index), destination: station(244 - index),
                    time: new Date(now).toISOString(), timeType: 'departAfter', realtime: 'off' },
                cacheStatus: index < 120 || index >= 240 ? 'hit' : 'miss' });
            if (index >= 230 && index < 240) continue;
            const status = index < 200 || index >= 240 ? 'success' : index < 220 ? 'fail' : 'other';
            row.finish({ status, outcome: status === 'other' ? 'cancelled' : undefined,
                errorCode: status === 'fail' ? 'SEARCH_TIMEOUT' : undefined,
                resultCount: status === 'success' ? index % 6 : undefined,
                finishedAt: new Date(startedAt.getTime() + (index + 1) * 100) });
        }
        while (log.pending.size || log.writing) await log.flush();
        assert.equal(await collection.countDocuments({}), 245);
        // Simulate the interval before asynchronous TTL deletion has removed
        // expired rows; the reader must exclude them itself as well.
        await collection.insertMany(Array.from({ length: 5 }, (_, index) => ({ _id: `expired-${index}`,
            source: 'search', origin: 'KTH', destination: 'VIC', startedAt: new Date(now - 8 * 86400000),
            finishedAt: new Date(now - 8 * 86400000 + 999999), durationMs: 999999,
            status: 'success', cacheStatus: 'hit' })));
        const reader = new PlannerSearchLogReader({ getCollection: () => collection, now: () => now });
        const first = await reader.list({ per_page: '50' });
        assert.equal(first.total, 240);
        assert.equal(first.totalPages, 5);
        assert.equal(first.rows.length, 50);
        assert.equal(first.rows[0].origin, station(0));
        assert.equal(first.rows[49].origin, station(49));
        assert.deepEqual({ total: first.stats.total, success: first.stats.success, fail: first.stats.fail,
            other: first.stats.other, pending: first.stats.pending, completed: first.stats.completed,
            p99: first.stats.p99DurationMs, max: first.stats.maxDurationMs, mean: first.stats.averageDurationMs,
            hits: first.stats.cacheHits, misses: first.stats.cacheMisses },
        { total: 240, success: 200, fail: 20, other: 10, pending: 10, completed: 220,
            p99: 21800, max: 22000, mean: 11050, hits: 120, misses: 120 });
        const last = await reader.list({ page: '99', per_page: '50' });
        assert.equal(last.page, 5);
        assert.equal(last.rows.length, 40);
        assert.equal(last.rows.at(-1).origin, station(239));

        const source = await reader.list({ source: 'search', per_page: '10' });
        assert.equal(source.total, 120);
        assert.equal(source.stats.p99DurationMs, 21700);
        assert.ok(source.rows.every(row => row.source === 'search'));
        const hour = await reader.list({ range: '1h' });
        assert.equal(hour.total, 60);
        const week = await reader.list({ range: '7d' });
        assert.equal(week.total, 245);
        assert.ok(week.rows.every(row => now - row.startedAt < PLANNER_SEARCH_RETENTION_MS));

        // Check every heading in both directions against Mongo's own complete
        // result, so null durations/completions and string columns are covered.
        for (const sort of ['origin', 'destination', 'startedAt', 'finishedAt', 'status', 'cacheStatus', 'durationMs', 'source']) {
            for (const direction of ['asc', 'desc']) {
                const actual = await reader.list({ sort, direction, per_page: '50' });
                const order = direction === 'asc' ? 1 : -1;
                const expected = await collection.find({ startedAt: { $gte: new Date(now - 86400000), $lte: new Date(now) } })
                    .sort({ [sort]: order, _id: order }).limit(50).toArray();
                assert.deepEqual(actual.rows.map(row => row.id), expected.map(row => row._id), `${sort} ${direction}`);
            }
        }
        const empty = await reader.list({ source: 'saved-replan' });
        assert.equal(empty.total, 0);
        assert.equal(empty.stats.p99DurationMs, null);
        assert.deepEqual(empty.rows, []);
    } finally {
        if (log) clearTimeout(log.timer);
        try { await database.dropDatabase(); }
        finally { await client.close(); }
    }
});
