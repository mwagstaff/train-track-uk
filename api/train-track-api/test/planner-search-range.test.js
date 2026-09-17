import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizePlannerSearchRange, plannerSearchWindow } from '../lib/planner-search-range.js';
import { PlannerSearchLogReader } from '../lib/planner-search-log.js';

const now = Date.parse('2026-09-17T12:00:00Z');

test('relative URL periods and legacy bookmarks resolve predictably within seven days', () => {
    for (const [q, milliseconds] of [['-5m', 300000], ['-2h', 7200000], ['-7d', 604800000]]) {
        const options = normalizePlannerSearchRange({ q });
        assert.deepEqual(options, { range: 'relative', q });
        const window = plannerSearchWindow(options, now);
        assert.equal(window.from.getTime(), now - milliseconds);
        assert.equal(window.to.getTime(), now);
    }
    assert.deepEqual(normalizePlannerSearchRange({ range: '24h' }), { range: '24h' });
    assert.equal(plannerSearchWindow(normalizePlannerSearchRange({ range: '1h' }), now).from.getTime(), now - 3600000);
    for (const q of ['-0m', '5m', '-1.5h', '-8d', '-10081m', '-999999999999999m', ['-5m'], { value: '-5m' }]) {
        assert.throws(() => normalizePlannerSearchRange({ q }), { code: 'INVALID_SEARCH_RANGE' });
    }
});

test('custom bookmarks require explicit timezones and distinguish both sides of the UK autumn clock change', () => {
    const chosen = normalizePlannerSearchRange({ from: '2026-10-25T01:15:00+01:00', to: '2026-10-25T01:45:00Z' });
    assert.deepEqual(chosen, { range: 'custom', q: 'custom', from: '2026-10-25T00:15:00.000Z', to: '2026-10-25T01:45:00.000Z' });
    assert.equal(Date.parse(chosen.to) - Date.parse(chosen.from), 90 * 60000);
    assert.deepEqual(normalizePlannerSearchRange({ q: 'custom', timezone: 'UTC', from: '2026-09-17T09:30', to: '2026-09-17T11:00' }),
        { range: 'custom', q: 'custom', from: '2026-09-17T09:30:00.000Z', to: '2026-09-17T11:00:00.000Z' });
    for (const fields of [
        { from: '2026-09-17T09:30', to: '2026-09-17T11:00' },
        { from: '2026-02-30T09:00Z', to: '2026-03-01T11:00Z' },
        { from: '2026-09-17T24:00Z', to: '2026-09-18T11:00Z' },
        { from: '2026-09-17T09:30+14:30', to: '2026-09-17T11:00Z' },
        { from: '2026-09-17T11:00Z', to: '2026-09-17T09:30Z' },
        { from: '2026-09-17T09:30Z', to: '2026-09-17T09:30Z' },
        { from: '2026-09-01T09:30Z', to: '2026-09-17T09:30Z' },
        { from: '2026-09-17T09:30Z' }
    ]) assert.throws(() => normalizePlannerSearchRange(fields), { code: 'INVALID_SEARCH_RANGE' });
});

test('custom windows are clipped to retained history without silently replacing the requested dates', () => {
    const options = normalizePlannerSearchRange({ from: '2026-09-09T12:00Z', to: '2026-09-12T12:00Z' });
    const window = plannerSearchWindow(options, now);
    assert.equal(window.from.toISOString(), '2026-09-10T12:00:00.000Z');
    assert.equal(window.to.toISOString(), '2026-09-12T12:00:00.000Z');
    assert.equal(options.from, '2026-09-09T12:00:00.000Z');
});

test('stats, percentile and table rows use the same custom window while different windows get separate bounded snapshots', async () => {
    const matches = [], finds = [];
    const db = {
        aggregate(pipeline) { matches.push(pipeline[0].$match); return { toArray: async () => [{ _id: null, total: 10, measured: 10 }] }; },
        find(filter, options) {
            finds.push(filter);
            const cursor = { sort() { return cursor; }, skip() { return cursor; }, limit() { return cursor; },
                toArray: async () => options.projection ? [{ durationMs: 100 }] : [] };
            return cursor;
        }
    };
    const reader = new PlannerSearchLogReader({ getCollection: () => db, now: () => now, maxSnapshots: 2 });
    const query = { q: 'custom', from: '2026-09-17T10:00:00+01:00', to: '2026-09-17T11:00:00+01:00', source: 'search-job' };
    const result = await reader.list(query);
    assert.deepEqual(matches[0].startedAt, { $gte: new Date('2026-09-17T09:00Z'), $lte: new Date('2026-09-17T10:00Z') });
    assert.deepEqual(finds[0].startedAt, matches[0].startedAt);
    assert.deepEqual(finds[1], matches[0]);
    assert.deepEqual(result.window, { from: new Date('2026-09-17T09:00Z'), to: new Date('2026-09-17T10:00Z') });
    await reader.list({ ...query, page: '2', sort: 'durationMs' });
    assert.equal(matches.length, 1, 'Pagination and sorting retain the same statistics window');
    await reader.list({ q: '-5m' });
    assert.deepEqual(matches[1].startedAt, { $gte: new Date(now - 300000), $lte: new Date(now) });
    await reader.list({ q: '-15m' });
    assert.equal(reader.snapshots.size, 2, 'Arbitrary bookmarked ranges cannot grow the snapshot cache indefinitely');
});
