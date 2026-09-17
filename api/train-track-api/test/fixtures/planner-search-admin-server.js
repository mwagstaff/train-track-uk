// Local synthetic UI fixture. Run from the API directory:
// node test/fixtures/planner-search-admin-server.js
// This server does not read or write search logs, or run planner searches.
import express from 'express';
import { renderAdminShell } from '../../lib/admin-portal.js';
import { registerPlannerSearchAdminRoutes } from '../../lib/planner-search-admin.js';
import { normalizePlannerSearchLogQuery } from '../../lib/planner-search-log.js';
import { plannerSearchWindow } from '../../lib/planner-search-range.js';

const app = express();
const admin = express.Router();
const now = Date.now();
const routes = [['KTH', 'INV'], ['VIC', 'ECR'], ['ECR', 'BYM'], ['KTH', 'VIC'], ['CLK', 'WAT'], ['KTH', 'STP']];
const sources = ['search', 'search-job', 'saved-route', 'saved-refresh', 'saved-replan'];
const rows = Array.from({ length: 76 }, (_, index) => {
    const [origin, destination] = routes[index % routes.length];
    const status = index === 0 ? 'pending' : index % 11 === 0 ? 'fail' : index % 7 === 0 ? 'other' : 'success';
    const durationMs = status === 'pending' ? null : index % 11 === 0 ? 135040 : 225 + index * 1729;
    const startedAt = new Date(now - index * 83000 - 100000);
    return { id: String(index), origin, destination, via: index === 5 ? ['HNH'] : [], startedAt,
        finishedAt: durationMs === null ? null : new Date(startedAt.getTime() + durationMs),
        status, outcome: status === 'other' ? 'cancelled' : status, phase: 'searching',
        errorCode: status === 'fail' ? 'SEARCH_TIMEOUT' : null,
        cacheStatus: index === 0 || index % 9 === 0 ? 'unknown' : index % 3 === 0 ? 'miss' : 'hit',
        durationMs, source: sources[index % sources.length], resultCount: index % 13 === 0 ? 0 : 5, coalesced: index % 4 === 0,
        ...(index === 1 ? { metrics: { queueWaitMs: 120, resumeQueueMs: 0, preparationMs: 180, routingMs: 1100,
            liveLookupMs: 525, cpuMs: 910, routeCalls: 2, operations: 25102, labels: 250, candidates: 14 },
            resourcePeaks: { heapUsedBytes: 420 * 1048576, rssBytes: 950 * 1048576 } } : {}) };
});

registerPlannerSearchAdminRoutes(admin, {
    renderShell: renderAdminShell,
    listSearches: async query => {
        if (query.fixture === 'error') throw new Error('Synthetic repository unavailable');
        const selected = normalizePlannerSearchLogQuery({ per_page: '25', ...query });
        const { source, sort, direction, pageSize } = selected;
        const window = plannerSearchWindow(selected, now);
        const matching = query.fixture === 'empty' ? [] : rows.filter(row => (source === 'all' || row.source === source)
            && row.startedAt >= window.from && row.startedAt <= window.to);
        const count = predicate => matching.filter(predicate).length;
        const durations = matching.filter(row => row.status === 'success' || row.status === 'fail').map(row => row.durationMs).sort((a, b) => a - b);
        const stats = { total: matching.length, success: count(row => row.status === 'success'), fail: count(row => row.status === 'fail'), pending: count(row => row.status === 'pending'), other: count(row => row.status === 'other'), completed: durations.length,
            p99DurationMs: durations[Math.ceil(durations.length * .99) - 1] ?? null, maxDurationMs: durations.at(-1) ?? null,
            averageDurationMs: durations.length ? durations.reduce((sum, value) => sum + value, 0) / durations.length : null,
            cacheHits: count(row => row.cacheStatus === 'hit'), cacheMisses: count(row => row.cacheStatus === 'miss'), cacheUnknown: count(row => row.cacheStatus === 'unknown') };
        matching.sort((a, b) => {
            const left = a[sort]; const right = b[sort];
            const delta = left instanceof Date || typeof left === 'number' ? Number(left || 0) - Number(right || 0) : String(left || '').localeCompare(String(right || ''));
            return direction === 'asc' ? delta : -delta;
        });
        const totalPages = Math.max(1, Math.ceil(matching.length / pageSize));
        const page = Math.min(totalPages, Math.max(1, Number(query.page) || 1));
        return { ...selected, rows: matching.slice((page - 1) * pageSize, page * pageSize), total: matching.length, page, totalPages, stats, window };
    }
});
// Express removes this mount prefix before the route sees req.path, just as the
// production reverse proxy does. The browser must retain it when following links.
app.use('/train-track', admin);
app.use(admin);
app.listen(4197, '127.0.0.1', () => console.log('Synthetic admin UI: http://127.0.0.1:4197/train-track/admin/journey-planner (also available without /train-track)'));
