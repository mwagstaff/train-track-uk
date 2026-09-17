import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { registerPlannerSearchAdminRoutes, renderPlannerSearchPage } from '../lib/planner-search-admin.js';

const shell = ({ title, body }) => `<title>${title}</title>${body}`;
const now = new Date('2026-09-17T12:00:00Z');

test('admin search page delegates sorting, filters and pagination to the repository', async () => {
    const query = { sort: 'durationMs', direction: 'desc', range: '7d', source: 'saved-route', page: '2', per_page: '25' };
    let received;
    let handler;
    registerPlannerSearchAdminRoutes({ get(path, callback) {
        assert.equal(path, '/admin/journey-planner');
        handler = callback;
    } }, { listSearches: async input => { received = input; return data({ ...query, page: 2, pageSize: 25, total: 65, totalPages: 3 }); }, renderShell: shell });
    const res = response();
    await handler({ query }, res);
    assert.deepEqual(received, query);
    assert.equal(res.headers['Cache-Control'], 'no-store');
    assert.equal(res.statusCode, 200);
    assert.match(res.html, /aria-sort="descending"[^>]*>\s*<a[^>]*sort=durationMs&amp;direction=asc&amp;page=1/);
    assert.match(res.html, /page=1&amp;per_page=25" rel="prev"/);
    assert.match(res.html, /page=3&amp;per_page=25" rel="next"/);
    assert.match(res.html, /26–50 of 65/);
});

test('every displayed heading is sortable and latest searches sort first by default', () => {
    const html = render(data());
    for (const field of ['origin', 'destination', 'startedAt', 'finishedAt', 'status', 'cacheStatus', 'durationMs', 'source']) {
        assert.match(html, new RegExp(`sort=${field}&amp;direction=asc&amp;page=1`));
    }
    assert.match(html, /aria-sort="descending"[^>]*>\s*<a[^>]*sort=startedAt/);
    assert.match(html, /Sort From by station code, ascending/);
    assert.match(html, /role="region" aria-label="Journey planner search history, scroll horizontally for all columns" tabindex="0"/);
});

test('summary uses all-query statistics and explains the actual denominators', () => {
    const html = render(data());
    assert.match(html, /90\.0% \/ 10\.0%/);
    assert.match(html, /75\.0%/);
    assert.match(html, /2m 15s/);
    assert.match(html, /All matching searches, across every page/);
    assert.match(html, /including queue time/);
    assert.match(html, /Unfinished searches, cancellations and expired work are excluded/);
    assert.match(html, /queued, running or interrupted by a server restart/);
    assert.match(html, /5 searches have no cache result/);
    assert.match(html, /nearest-rank value/);
});

test('rows show station names, UK completion times and distinguish zero results from failure', () => {
    const html = render(data());
    assert.match(html, /<strong>KTH<\/strong><small>Kent House<\/small>/);
    assert.match(html, /13:00:00<small>17 Sept 2026<\/small>/);
    assert.match(html, /13:00:01<small>17 Sept 2026<\/small>/);
    assert.match(html, /status-success">Success/);
    assert.match(html, /<small>0 journeys<\/small>/);
    assert.match(html, /cache-hit">Hit/);
    assert.match(html, /1\.2 s/);
});

test('pending, cancelled, expired and failed records have truthful status and missing durations', () => {
    const html = render(data({ rows: [
        { origin: 'VIC', destination: 'ECR', status: 'pending', phase: 'queued', cacheStatus: 'unknown', startedAt: now, durationMs: null },
        { origin: 'VIC', destination: 'INV', status: 'other', outcome: 'cancelled', cacheStatus: 'miss', durationMs: 500 },
        { origin: 'KTH', destination: 'INV', status: 'other', outcome: 'expired', cacheStatus: 'unknown', durationMs: null },
        { origin: 'ECR', destination: 'BYM', status: 'fail', errorCode: 'SEARCH_TIMEOUT', cacheStatus: 'miss', durationMs: 90000 }
    ] }));
    assert.match(html, /status-pending">Unfinished<\/span><small class="planner-outcome">queued/);
    assert.match(html, /status-other">Other<\/span><small class="planner-outcome">cancelled/);
    assert.match(html, /status-other">Other<\/span><small class="planner-outcome">expired/);
    assert.match(html, /status-fail">Failed<\/span><small class="planner-outcome">SEARCH TIMEOUT/);
    assert.match(html, /class="planner-duration">—<\/td>/);
    assert.match(html, /1m 30s/);
});

test('station, source, error and route text are escaped and never exposed as raw markup', () => {
    const payload = '<img src=x onerror="alert(1)">';
    const html = render(data({ rows: [{ origin: payload, destination: payload, via: [payload], source: payload, status: 'fail', errorCode: payload }] }));
    assert.equal(html.includes('<img'), false);
    assert.match(html, /&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt;/);
});

test('empty samples show unavailable statistics rather than misleading zero latency or rates', () => {
    const stats = { total: 0, pending: 0, other: 0, completed: 0, success: 0, fail: 0, cacheHits: 0, cacheMisses: 0, cacheUnknown: 0, p99DurationMs: null, maxDurationMs: null, averageDurationMs: null };
    const html = render(data({ rows: [], stats, total: 0 }));
    assert.match(html, /No searches in this period/);
    assert.match(html, /<dd>— \/ —<\/dd>/);
    assert.match(html, /<dt>99th percentile<\/dt><dd>—<\/dd>/);
    assert.match(html, /0–0 of 0/);
    assert.equal(html.includes('NaN'), false);
});

test('repository failure returns an accessible retry page without leaking error details', async () => {
    let handler;
    let logged;
    registerPlannerSearchAdminRoutes({ get(_path, callback) { handler = callback; } }, {
        listSearches: async () => { throw new Error('private Mongo address'); },
        renderShell: shell,
        logger: { error(...args) { logged = args; } }
    });
    const res = response();
    await handler({ query: {} }, res);
    assert.equal(res.statusCode, 503);
    assert.match(res.html, /role="alert"/);
    assert.match(res.html, /Search logs are unavailable/);
    assert.match(res.html, /href="\.\/journey-planner">Try again/);
    assert.equal(res.html.includes('private Mongo address'), false);
    assert.match(logged[1], /private Mongo address/);
});

test('all search controls preserve root or proxy-mounted URLs, including trailing-slash entry points', async t => {
    const app = express();
    const router = express.Router();
    const options = { listSearches: async () => data({ page: 2, totalPages: 3 }), renderShell: shell };
    registerPlannerSearchAdminRoutes(app, options);
    registerPlannerSearchAdminRoutes(router, options);
    app.use('/train-track', router);
    const server = app.listen(0, '127.0.0.1');
    t.after(() => new Promise(resolve => server.close(resolve)));
    await new Promise(resolve => server.once('listening', resolve));
    const origin = `http://127.0.0.1:${server.address().port}`;

    for (const prefix of ['', '/train-track']) {
        for (const suffix of ['', '/']) {
            const currentUrl = `${origin}${prefix}/admin/journey-planner${suffix}?page=2`;
            const response = await fetch(currentUrl);
            assert.equal(response.status, 200);
            const html = await response.text();
            const links = [...html.matchAll(/href="([^"]+)"/g)].map(match => new URL(match[1].replaceAll('&amp;', '&'), currentUrl));
            assert.equal(links.length, 11, 'refresh, eight sorts and both pagination directions');
            for (const link of links) {
                assert.equal(link.pathname, `${prefix}/admin/journey-planner`);
                assert.equal(link.searchParams.get('range'), '24h');
                assert.equal(link.searchParams.get('source'), 'all');
                assert.equal(link.searchParams.get('per_page'), '50');
                assert.equal((await fetch(link)).status, 200);
            }
            const filterAction = html.match(/class="planner-filters" action="([^"]+)"/)[1];
            const filterUrl = new URL(filterAction, currentUrl);
            assert.equal(filterUrl.pathname, `${prefix}/admin/journey-planner`);
            assert.equal((await fetch(filterUrl)).status, 200);
        }
    }
});

test('retry links and shell navigation receive the current request depth', async () => {
    for (const requestPath of ['/admin/journey-planner', '/admin/journey-planner/']) {
        let handler;
        let shellRequestPath;
        registerPlannerSearchAdminRoutes({ get(_path, callback) { handler = callback; } }, {
            listSearches: async () => { throw new Error('unavailable'); },
            renderShell: options => { shellRequestPath = options.requestPath; return shell(options); },
            logger: { error() {} }
        });
        const res = response();
        await handler({ path: requestPath, query: {} }, res);
        assert.equal(shellRequestPath, requestPath);
        const href = res.html.match(/href="([^"]+)">Try again/)[1];
        for (const prefix of ['', '/train-track']) {
            assert.equal(new URL(href, `https://example.test${prefix}${requestPath}`).pathname, `${prefix}/admin/journey-planner`);
        }
        renderPlannerSearchPage(data(), { requestPath, renderShell: options => { shellRequestPath = options.requestPath; return shell(options); } });
        assert.equal(shellRequestPath, requestPath);
    }
});

function render(input) { return renderPlannerSearchPage(input, { renderShell: shell, now }); }
function data(overrides = {}) {
    return {
        rows: [{ id: 'search-1', origin: 'KTH', destination: 'VIC', startedAt: now, finishedAt: new Date(now.getTime() + 1200), status: 'success', resultCount: 0, cacheStatus: 'hit', durationMs: 1200, source: 'search-job' }],
        total: 115, page: 1, pageSize: 50, totalPages: 3, sort: 'startedAt', direction: 'desc', range: '24h', source: 'all',
        stats: { total: 115, success: 90, fail: 10, other: 10, pending: 5, completed: 100, p99DurationMs: 135000, maxDurationMs: 150000, averageDurationMs: 3250, cacheHits: 75, cacheMisses: 25, cacheUnknown: 5 },
        ...overrides
    };
}
function response() {
    return { statusCode: 200, headers: {}, html: null, set(key, value) { this.headers[key] = value; return this; }, status(value) { this.statusCode = value; return this; }, type(value) { this.contentType = value; return this; }, send(value) { this.html = value; return this; } };
}
