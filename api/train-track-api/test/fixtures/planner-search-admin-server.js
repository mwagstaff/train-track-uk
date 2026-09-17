// Local synthetic UI fixture. Run from the API directory:
// node test/fixtures/planner-search-admin-server.js
// This server does not read or write search logs, or run planner searches.
import express from 'express';
import { renderAdminShell } from '../../lib/admin-portal.js';
import { registerPlannerSearchAdminRoutes } from '../../lib/planner-search-admin.js';

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
        durationMs, source: sources[index % sources.length], resultCount: index % 13 === 0 ? 0 : 5, coalesced: index % 4 === 0 };
});

registerPlannerSearchAdminRoutes(admin, {
    renderShell: renderAdminShell,
    listSearches: async query => {
        if (query.fixture === 'error') throw new Error('Synthetic repository unavailable');
        const range = ['1h', '24h', '7d'].includes(query.range) ? query.range : '24h';
        const source = sources.includes(query.source) ? query.source : 'all';
        const sort = ['origin', 'destination', 'startedAt', 'finishedAt', 'status', 'cacheStatus', 'durationMs', 'source'].includes(query.sort) ? query.sort : 'startedAt';
        const direction = query.direction === 'asc' ? 'asc' : 'desc';
        const pageSize = [25, 50, 100].includes(Number(query.per_page)) ? Number(query.per_page) : 25;
        const matching = query.fixture === 'empty' ? [] : rows.filter(row => (source === 'all' || row.source === source) && (range !== '1h' || row.startedAt >= now - 3600000));
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
        return { rows: matching.slice((page - 1) * pageSize, page * pageSize), total: matching.length, page, pageSize, totalPages, range, source, sort, direction, stats };
    }
});
// Express removes this mount prefix before the route sees req.path, just as the
// production reverse proxy does. The browser must retain it when following links.
app.use('/train-track', admin);
app.use(admin);
app.listen(4197, '127.0.0.1', () => console.log('Synthetic admin UI: http://127.0.0.1:4197/train-track/admin/journey-planner (also available without /train-track)'));
