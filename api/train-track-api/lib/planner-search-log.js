import { randomUUID } from 'node:crypto';
import { COLLECTIONS, getMongoCollection } from './mongo-client.js';
import { normalizePlannerSearchRange, plannerSearchWindow } from './planner-search-range.js';

export const PLANNER_SEARCH_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
export const PLANNER_SEARCH_SOURCES = ['search', 'search-job', 'saved-route', 'saved-refresh', 'saved-replan'];
const noopHandle = Object.freeze({ update() {}, finish() {} });
export const noOpPlannerSearchLog = Object.freeze({ start: () => noopHandle });
const collection = () => getMongoCollection(COLLECTIONS.plannerSearches);
const station = value => typeof value === 'string' && /^[A-Z0-9]{3}$/.test(value.trim().toUpperCase())
    ? value.trim().toUpperCase() : null;
const date = value => {
    const parsed = value == null ? NaN : new Date(value).getTime();
    return Number.isFinite(parsed) ? new Date(parsed) : null;
};
const member = (value, allowed, fallback) => allowed.includes(value) ? value : fallback;
const code = value => typeof value === 'string' && /^[A-Z0-9_]{1,80}$/.test(value) ? value : null;
const METRICS = ['admissionQueueMs', 'queueWaitMs', 'resumeQueueMs', 'preparationMs', 'routingMs', 'liveLookupMs',
    'cpuMs', 'routeCalls', 'operations', 'labels', 'candidates'];
const RESOURCE_PEAKS = ['heapUsedBytes', 'rssBytes'];

// Search completion must never wait for Mongo. Coalesce lifecycle updates and
// bound both retained records and actual database operations during an outage.
export class PlannerSearchLog {
    constructor({ getCollection = collection, now = Date.now, monotonicNow = () => performance.now(),
        maxPending = 2000, batchSize = 50, retryMs = 1000, maxAttempts = 3, warn = message => console.warn(message) } = {}) {
        Object.assign(this, { getCollection, now, monotonicNow, maxPending, batchSize, retryMs, maxAttempts, warn });
        this.pending = new Map();
        this.writing = null;
        this.timer = null;
        this.dropped = 0;
        this.lastWarning = -Infinity;
    }

    start(input = {}) {
        try {
            const request = input.request ?? {};
            const startedAt = date(input.startedAt) ?? new Date(this.now());
            const tick = this.monotonicNow();
            const row = { _id: randomUUID(), source: member(input.source, PLANNER_SEARCH_SOURCES, 'search'),
                origin: station(request.origin), destination: station(request.destination),
                via: Array.isArray(request.via) ? request.via.slice(0, 4).map(station).filter(Boolean) : [],
                requestedTime: date(request.time), timeType: member(request.timeType, ['departAfter', 'arriveBy'], null),
                realtime: member(request.realtime, ['apply', 'ignore', 'off'], 'off'),
                startedAt, finishedAt: null, durationMs: null, status: 'pending', outcome: 'pending', phase: 'queued',
                cacheStatus: 'unknown', coalesced: false, errorCode: null, resultCount: null, datasetVersion: null, revision: 0 };
            const update = fields => {
                if (fields.cacheStatus === 'miss' || (fields.cacheStatus === 'hit' && row.cacheStatus === 'unknown')) {
                    row.cacheStatus = fields.cacheStatus;
                }
                if (typeof fields.coalesced === 'boolean') row.coalesced = fields.coalesced;
                if (['queued', 'running', 'preparing', 'searching', 'live', 'retrying'].includes(fields.phase)) row.phase = fields.phase;
                if (typeof fields.datasetVersion === 'string') row.datasetVersion = fields.datasetVersion.slice(0, 128);
                const firstResultAt = date(fields.firstResultAt);
                if (!row.firstResultAt && firstResultAt) {
                    row.firstResultAt = firstResultAt;
                    row.firstResultMs = Math.max(0, firstResultAt - startedAt);
                }
                for (const key of METRICS) {
                    const value = fields.metricsDelta?.[key];
                    if (Number.isFinite(value) && value >= 0) row.metrics = { ...row.metrics,
                        [key]: Math.round(((row.metrics?.[key] ?? 0) + value) * 1000) / 1000 };
                }
                for (const key of RESOURCE_PEAKS) {
                    const value = fields.resourcePeaks?.[key];
                    if (Number.isFinite(value) && value >= 0) row.resourcePeaks = { ...row.resourcePeaks,
                        [key]: Math.max(row.resourcePeaks?.[key] ?? 0, Math.round(value)) };
                }
            };
            update(input);
            this.enqueue(row);
            let finished = false;
            return {
                update: (fields = {}) => {
                    try { if (!finished) { update(fields); this.enqueue(row); } } catch { /* Logging is best effort. */ }
                },
                finish: (fields = {}) => {
                    try {
                        if (finished) return;
                        finished = true;
                        update(fields);
                        row.finishedAt = date(fields.finishedAt) ?? new Date(this.now());
                        row.durationMs = Math.max(0, Math.round(input.startedAt != null || fields.finishedAt != null
                            ? row.finishedAt - startedAt : this.monotonicNow() - tick));
                        row.status = member(fields.status, ['success', 'fail', 'other'], 'other');
                        row.outcome = typeof fields.outcome === 'string' && /^[a-z_-]{1,40}$/.test(fields.outcome)
                            ? fields.outcome : row.status === 'success' ? 'completed' : row.status === 'fail' ? 'failed' : 'other';
                        row.errorCode = code(fields.errorCode);
                        row.resultCount = Number.isSafeInteger(fields.resultCount) && fields.resultCount >= 0 ? fields.resultCount : null;
                        row.phase = null;
                        this.enqueue(row);
                    } catch { /* Logging is best effort. */ }
                }
            };
        } catch { return noopHandle; }
    }

    enqueue(row, attempts = 0) {
        if (this.now() - row.startedAt >= PLANNER_SEARCH_RETENTION_MS) return;
        if (!this.pending.has(row._id) && this.pending.size >= this.maxPending) {
            this.dropped++;
            this.warning('buffer full; some search records could not be retained');
            return;
        }
        if (!attempts) row.revision++;
        this.pending.set(row._id, { row: { ...row }, attempts });
        this.schedule(0);
    }

    warning(reason) {
        if (this.now() - this.lastWarning < 60000) return;
        this.lastWarning = this.now();
        try { this.warn(`[planner-search-log] ${reason}`); } catch { /* A diagnostic must not break a search. */ }
    }

    schedule(delay) {
        if (this.timer || this.writing || !this.pending.size) return;
        this.timer = setTimeout(() => { this.timer = null; void this.flush(); }, delay);
        this.timer.unref();
    }

    async flush() {
        if (this.writing) return this.writing;
        clearTimeout(this.timer);
        this.timer = null;
        const batch = [...this.pending.values()].slice(0, this.batchSize);
        if (!batch.length) return;
        for (const item of batch) this.pending.delete(item.row._id);
        let failed = false;
        this.writing = Promise.resolve().then(async () => {
            const db = await this.getCollection();
            const current = batch.filter(item => this.now() - item.row.startedAt < PLANNER_SEARCH_RETENTION_MS);
            if (!current.length) return;
            // A write may commit after its client timeout. Revision guards keep
            // a late pending update from replacing a newer completed record.
            await db.bulkWrite(current.map(({ row }) => ({ updateOne: { filter: { _id: row._id }, upsert: true,
                update: [{ $replaceWith: { $cond: [{ $gt: [{ $ifNull: ['$revision', -1] }, row.revision] },
                    '$$ROOT', { $literal: row }] } }] } })),
                { ordered: false, timeoutMS: 2000 });
        }).catch(() => {
            failed = true;
            this.warning('Mongo write failed; retrying buffered search records');
            for (const item of batch) {
                // A finish arriving during a failed pending write must win.
                if (this.pending.has(item.row._id)) continue;
                if (item.attempts + 1 < this.maxAttempts) this.enqueue(item.row, item.attempts + 1);
                else { this.dropped++; this.warning('retry limit reached; some search records could not be saved'); }
            }
        }).finally(() => {
            this.writing = null;
            this.schedule(failed ? this.retryMs : 0);
        });
        return this.writing;
    }
}

const SORTS = ['origin', 'destination', 'startedAt', 'finishedAt', 'status', 'cacheStatus', 'durationMs', 'source'];
const positive = (value, fallback, max) => /^\d+$/.test(String(value ?? '')) && Number(value) > 0
    ? Math.min(max, Number(value)) : fallback;
export function normalizePlannerSearchLogQuery(query = {}) {
    return { page: positive(query.page, 1, 100000), pageSize: positive(query.per_page, 50, 200),
        sort: member(query.sort, SORTS, 'startedAt'), direction: member(query.direction, ['asc', 'desc'], 'desc'),
        ...normalizePlannerSearchRange(query), source: member(query.source, ['all', ...PLANNER_SEARCH_SOURCES], 'all') };
}

const emptyStats = () => ({ total: 0, success: 0, fail: 0, other: 0, pending: 0, completed: 0,
    p99DurationMs: null, maxDurationMs: null, averageDurationMs: null, cacheHits: 0, cacheMisses: 0, cacheUnknown: 0 });
const sumIf = expression => ({ $sum: { $cond: [expression, 1, 0] } });
const isStatus = value => ({ $eq: ['$status', value] });

// Rows and statistics stay in Mongo. A small shared snapshot avoids rescanning
// the seven-day log on every sort/page click; all cards cover the whole filter.
export class PlannerSearchLogReader {
    constructor({ getCollection = collection, now = Date.now, statsTtlMs = 15000, maxReads = 4, maxSnapshots = 32 } = {}) {
        Object.assign(this, { getCollection, now, statsTtlMs, maxReads, maxSnapshots });
        this.snapshots = new Map();
        this.reads = new Map();
    }

    list(query = {}) {
        const options = normalizePlannerSearchLogQuery(query);
        const key = JSON.stringify(options);
        if (this.reads.has(key)) return this.reads.get(key);
        if (this.reads.size >= this.maxReads) return Promise.reject(new Error('Search history is busy. Please try again shortly.'));
        const promise = this.read(options).finally(() => this.reads.delete(key));
        this.reads.set(key, promise);
        return promise;
    }

    async snapshot(db, options) {
        const key = JSON.stringify([options.range, options.q, options.from, options.to, options.source]);
        const old = this.snapshots.get(key);
        if (old && this.now() - old.at < this.statsTtlMs) return old.promise;
        const at = this.now();
        const window = plannerSearchWindow(options, at);
        const filter = { startedAt: { $gte: window.from, $lte: window.to },
            ...(options.source !== 'all' ? { source: options.source } : {}) };
        const promise = this.statistics(db, filter).then(stats => ({ filter, window, stats: { ...stats, asOf: new Date(at) } }))
            .catch(error => { if (this.snapshots.get(key)?.promise === promise) this.snapshots.delete(key); throw error; });
        this.snapshots.delete(key);
        this.snapshots.set(key, { at, promise });
        while (this.snapshots.size > this.maxSnapshots) this.snapshots.delete(this.snapshots.keys().next().value);
        return promise;
    }

    async statistics(db, filter) {
        const completed = { $in: ['$status', ['success', 'fail']] };
        const measured = { $and: [completed, { $isNumber: '$durationMs' }] };
        const duration = { $cond: [measured, '$durationMs', null] };
        const [value] = await db.aggregate([{ $match: filter }, { $group: { _id: null,
            total: { $sum: 1 }, success: sumIf(isStatus('success')), fail: sumIf(isStatus('fail')),
            other: sumIf(isStatus('other')), pending: sumIf(isStatus('pending')), completed: sumIf(completed),
            measured: sumIf(measured), maxDurationMs: { $max: duration }, averageDurationMs: { $avg: duration },
            cacheHits: sumIf({ $eq: ['$cacheStatus', 'hit'] }), cacheMisses: sumIf({ $eq: ['$cacheStatus', 'miss'] }),
            cacheUnknown: sumIf({ $eq: ['$cacheStatus', 'unknown'] })
        } }], { maxTimeMS: 5000, timeoutMS: 6000 }).toArray();
        if (!value) return emptyStats();
        const { _id, measured: count, ...stats } = value;
        let p99DurationMs = null;
        if (count) {
            // Exact nearest-rank p99 without depending on MongoDB 7's $percentile.
            const [percentile] = await db.find({ ...filter, status: { $in: ['success', 'fail'] }, durationMs: { $type: 'number' } },
                { projection: { durationMs: 1 }, maxTimeMS: 5000, timeoutMS: 6000, timeoutMode: 'cursorLifetime' })
                .sort({ durationMs: -1 }).skip(count - Math.ceil(count * 0.99)).limit(1).toArray();
            p99DurationMs = percentile?.durationMs ?? null;
        }
        return { ...stats, p99DurationMs };
    }

    async read(options) {
        const db = await this.getCollection();
        const { filter, window, stats } = await this.snapshot(db, options);
        const totalPages = Math.max(1, Math.ceil(stats.total / options.pageSize));
        const page = Math.min(options.page, totalPages);
        const direction = options.direction === 'asc' ? 1 : -1;
        // TTL cleanup is asynchronous; exclude already expired records even if
        // a shared statistics snapshot was made a few seconds earlier.
        const currentFilter = { ...filter, startedAt: { ...filter.startedAt,
            $gte: new Date(Math.max(filter.startedAt.$gte.getTime(), this.now() - PLANNER_SEARCH_RETENTION_MS)) } };
        const records = await db.find(currentFilter, { maxTimeMS: 5000, timeoutMS: 6000, timeoutMode: 'cursorLifetime', allowDiskUse: true })
            .sort({ [options.sort]: direction, _id: direction }).skip((page - 1) * options.pageSize).limit(options.pageSize).toArray();
        return { ...options, page, total: stats.total, totalPages, stats, window,
            rows: records.map(({ _id, revision, ...row }) => ({ id: String(_id), ...row })) };
    }
}

export const plannerSearchLog = new PlannerSearchLog();
const reader = new PlannerSearchLogReader();
export const listPlannerSearchLogs = query => reader.list(query);
