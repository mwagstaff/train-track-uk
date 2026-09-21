import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { registerPlannerSearchAdminRoutes, renderPlannerSearchPage } from '../lib/planner-search-admin.js';
import { normalizePlannerSearchLogQuery } from '../lib/planner-search-log.js';

const shell = ({ title, body }) => `<title>${title}</title>${body}`;
const now = new Date('2026-09-17T12:00:00Z');

test('public planner admin shows target status but cannot change the target', async () => {
    let handler;
    const posts = [];
    const plannerTargets = {
        describe: () => ({ targetId: 'mini', revision: 2, forced: false, targets: [
            { id: 'sky', label: 'Sky (embedded)' }, { id: 'mini', label: 'Mini', health: { ready: true } }
        ] }),
        health: async () => ({ ready: true })
    };
    registerPlannerSearchAdminRoutes({ get(_path, callback) { handler = callback; }, post(path) { posts.push(path); } }, {
        listSearches: async () => data(), renderShell: shell, plannerTargets
    });
    const res = response();
    await handler({ query: {} }, res);
    assert.equal(res.statusCode, 200);
    assert.match(res.html, /Target changes require the Sky operator command/);
    assert.equal(res.html.includes('planner-target-form'), false);
    assert.equal(res.html.includes('data-planner-target-controls'), false);
    assert.equal(res.html.includes('planner-cache-clear'), false);
    assert.deepEqual(posts, []);
});

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

test('linked headings are sortable, Algorithm is a plain heading and latest searches sort first by default', () => {
    const html = render(data());
    for (const field of ['origin', 'destination', 'host', 'startedAt', 'finishedAt', 'status', 'cacheStatus', 'durationMs', 'source']) {
        assert.match(html, new RegExp(`sort=${field}&amp;direction=asc&amp;page=1`));
    }
    assert.match(html, /aria-sort="descending"[^>]*>\s*<a[^>]*sort=startedAt/);
    assert.match(html, /Sort From by station code, ascending/);
    assert.match(html, /<th scope="col">Algorithm<\/th>/);
    assert.equal(html.includes('sort=algorithm'), false);
    assert.match(html, /role="region" aria-label="Journey planner search history, scroll horizontally for all columns" tabindex="0"/);
});

test('summary uses all-query statistics and explains the actual denominators', () => {
    const html = render(data());
    assert.match(html, /90\.0% \/ 10\.0%/);
    assert.match(html, /75\.0%/);
    assert.match(html, /2m 15s/);
    assert.match(html, /All matching searches in this database, across every page/);
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

test('algorithm column distinguishes RAPTOR, original and legacy records without reflecting unknown values', () => {
    const html = render(data({ rows: [
        { algorithm: 'raptor' },
        { algorithm: 'original' },
        {},
        { algorithm: 'RAPTOR' },
        { algorithm: '<script>private-algorithm</script>' }
    ].map(row => ({ source: 'search', ...row })) }));
    const body = html.match(/<tbody>([\s\S]*?)<\/tbody>/)[1];
    assert.equal((body.match(/<td>RAPTOR<\/td>/g) || []).length, 1);
    assert.equal((body.match(/<td>Original<\/td>/g) || []).length, 2, 'Historical rows used the original engine');
    assert.equal((body.match(/<td>Unknown<\/td>/g) || []).length, 2);
    assert.equal(html.includes('private-algorithm'), false);
    assert.equal(html.includes('<script>'), false);
    for (const row of body.matchAll(/<tr>([\s\S]*?)<\/tr>/g)) assert.equal((row[1].match(/<td(?:\s|>)/g) || []).length, 10);
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
    assert.match(html, /<td colspan="10" class="empty">/);
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
    assert.match(res.html, /href="\.\/journey-planner\?range=24h[^\"]*">Try again/);
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
            assert.equal(links.length, 12, 'refresh, nine sorts and both pagination directions');
            for (const link of links) {
                assert.equal(link.pathname, `${prefix}/admin/journey-planner`);
                assert.equal(link.searchParams.get('range'), '24h');
                assert.equal(link.searchParams.get('source'), 'all');
                assert.equal(link.searchParams.get('host'), 'all');
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

test('custom period fields explicitly use UTC and canonical bookmarks survive every sort, refresh and page link', () => {
    const chosen = normalizePlannerSearchLogQuery({ q: 'custom', from: '2026-10-25T01:15:00+01:00', to: '2026-10-25T01:45:00Z', source: 'saved-route' });
    const html = render(data({ ...chosen, page: 2, window: { from: chosen.from, to: chosen.to } }));
    assert.match(html, /Table times Europe\/London/);
    assert.match(html, /<option value="custom" selected>/);
    assert.match(html, /<details class="planner-custom" open>/);
    assert.match(html, /From \(UTC\)/);
    assert.match(html, /name="timezone" value="UTC"/);
    assert.match(html, /name="from"[^>]*value="2026-10-25T00:15:00\.000"/);
    assert.match(html, /name="to"[^>]*value="2026-10-25T01:45:00\.000"/);
    const links = [...html.matchAll(/href="([^"]+)"/g)].map(match => new URL(match[1].replaceAll('&amp;', '&'), 'https://example.test/train-track/admin/journey-planner'));
    assert.equal(links.length, 12);
    for (const link of links) {
        assert.equal(link.pathname, '/train-track/admin/journey-planner');
        assert.equal(link.searchParams.get('q'), 'custom');
        assert.equal(link.searchParams.get('from'), '2026-10-25T00:15:00.000Z');
        assert.equal(link.searchParams.get('to'), '2026-10-25T01:45:00.000Z');
        assert.equal(link.searchParams.get('source'), 'saved-route');
        assert.equal(link.searchParams.get('per_page'), '50');
    }
});

test('relative URL ranges and non-preset durations remain selected and preserved through links', () => {
    for (const q of ['-5m', '-2h']) {
        const html = render(data({ ...normalizePlannerSearchLogQuery({ q, source: 'search-job' }) }));
        assert.match(html, new RegExp(`<option value="${q}" selected>`));
        const links = [...html.matchAll(/href="([^"]+)"/g)];
        for (const [, href] of links) {
            const query = new URL(href.replaceAll('&amp;', '&'), 'https://example.test/admin/journey-planner').searchParams;
            assert.equal(query.get('q'), q);
            assert.equal(query.get('source'), 'search-job');
        }
    }
});

test('invalid ranges return a correctable 400 form while unavailable custom-range requests preserve their retry URL', async () => {
    let handler;
    registerPlannerSearchAdminRoutes({ get(_path, callback) { handler = callback; } }, {
        listSearches: async query => { normalizePlannerSearchLogQuery(query); throw new Error('offline'); },
        renderShell: shell, logger: { error() {} }
    });
    const query = { q: 'custom', timezone: 'UTC', from: '2026-09-17T11:00', to: '2026-09-17T10:00', source: 'saved-route', sort: 'durationMs', direction: 'asc', per_page: '25' };
    const invalid = response();
    await handler({ path: '/admin/journey-planner/', query }, invalid);
    assert.equal(invalid.statusCode, 400);
    assert.match(invalid.html, /The end must be later than the start/);
    assert.match(invalid.html, /name="from"[^>]*value="2026-09-17T11:00:00\.000"/);
    assert.match(invalid.html, /name="to"[^>]*value="2026-09-17T10:00:00\.000"/);
    assert.match(invalid.html, /option value="saved-route" selected/);

    query.to = '2026-09-17T12:00';
    const offline = response();
    await handler({ path: '/admin/journey-planner/', query }, offline);
    assert.equal(offline.statusCode, 503);
    const href = offline.html.match(/href="([^"]+)">Try again/)[1].replaceAll('&amp;', '&');
    const target = new URL(href, 'https://example.test/train-track/admin/journey-planner/');
    assert.equal(target.pathname, '/train-track/admin/journey-planner');
    for (const [key, value] of Object.entries(query)) assert.equal(target.searchParams.get(key), value);
});

test('optional timing diagnostics separate queue, routing, live I/O, CPU and sampled memory without changing legacy rows', () => {
    assert.equal(render(data()).includes('<summary>Timing details</summary>'), false);
    const html = render(data({ rows: [{ origin: 'KTH', destination: 'VIC', status: 'success', durationMs: 2600, firstResultMs: 1900,
        metrics: { admissionQueueMs: 800, queueWaitMs: 200, resumeQueueMs: 0, preparationMs: 200, routingMs: 950, liveLookupMs: 450,
            cpuMs: 725, routeCalls: 2, operations: 123456, labels: 200, candidates: 12 },
        resourcePeaks: { heapUsedBytes: 256 * 1048576, rssBytes: 1024 * 1048576 } }] }));
    assert.match(html, /<summary>Timing details<\/summary>/);
    assert.match(html, /First results<\/dt><dd>1\.9 s/);
    assert.match(html, /Admission queue<\/dt><dd>800 ms/);
    assert.match(html, /Worker queue<\/dt><dd>200 ms/);
    assert.match(html, /Queue wait between stages<\/dt><dd>0 ms/);
    assert.match(html, /Route calculation<\/dt><dd>950 ms/);
    assert.match(html, /Live lookups<\/dt><dd>450 ms/);
    assert.match(html, /CPU time \(excludes I\/O\)<\/dt><dd>725 ms/);
    assert.match(html, /Routing operations<\/dt><dd>123,456/);
    assert.match(html, /Sampled heap peak<\/dt><dd>256\.0 MiB/);
    assert.match(html, /Sampled process memory peak \(RSS\)<\/dt><dd>1024\.0 MiB/);
    assert.match(html, /Memory peaks are sampled and may miss brief spikes/);
    assert.equal(html.includes('Topology-bound scans'), false, 'Missing profile values are not invented for older rows');
    assert.equal(html.includes('Transfer resolution<'), false);
    assert.equal(html.includes('Result assembly<'), false);
    assert.equal(html.includes('Routing phase timings are wall-clock'), false);
    const malicious = render(data({ rows: [{ firstResultMs: '<img src=x>', metrics: { admissionQueueMs: -5, queueWaitMs: '<img src=x>', routeCalls: Infinity, operations: -5 }, resourcePeaks: { rssBytes: '<script>' } }] }));
    assert.equal(malicious.includes('<summary>Timing details</summary>'), false);
    assert.equal(malicious.includes('<img'), false);
    assert.equal(malicious.includes('<script>'), false);
});

test('routing profile details distinguish phase wall time, bound cache reuse and internal route passes', () => {
    const html = render(data({ rows: [{ metrics: { indexBuildMs: 12, topologyBoundsMs: 34, temporalBoundsMs: 56,
        labelExpansionMs: 1200, transferResolutionMs: 800, resultAssemblyMs: 0,
        topologyBoundsBuilds: 1, topologyBoundsCacheHits: 3, temporalBoundsBuilds: 2,
        temporalBoundsCacheHits: 4, internalRoutePasses: 5 } }] }));
    for (const [label, value] of [['Routing index build', '12 ms'], ['Topology-bound scans', '34 ms'],
        ['Temporal-bound scans', '56 ms'], ['Routing-state expansion', '1.2 s'],
        ['Transfer resolution', '800 ms'], ['Result assembly', '0 ms'], ['Topology-bound builds', '1'],
        ['Topology-bound cache hits', '3'], ['Temporal-bound builds', '2'], ['Temporal-bound cache hits', '4'],
        ['Internal routing passes', '5']]) {
        assert.ok(html.includes(`<dt>${label}</dt><dd>${value}</dd>`), `${label} shows its measured value`);
    }
    assert.match(html, /Routing phase timings are wall-clock measurements within Route calculation, not extra durations to add to it/);
    assert.match(html, /Internal routing passes include TfL retries/);
    assert.match(html, /Transfer resolution includes provider waits/);

    const partial = render(data({ rows: [{ metrics: { temporalBoundsCacheHits: 0 } }] }));
    assert.match(partial, /Temporal-bound cache hits<\/dt><dd>0<\/dd>/);
    assert.equal(partial.includes('Temporal-bound scans'), false);
    assert.equal(partial.includes('Internal routing passes<'), false);
    assert.equal(partial.includes('Transfer resolution<'), false);
    assert.equal(partial.includes('Result assembly<'), false);
    const invalid = render(data({ rows: [{ metrics: { indexBuildMs: -1, topologyBoundsMs: NaN, temporalBoundsMs: Infinity,
        labelExpansionMs: '<img src=x>', transferResolutionMs: -1, resultAssemblyMs: '<script>',
        topologyBoundsBuilds: -1, topologyBoundsCacheHits: 1.5,
        temporalBoundsBuilds: '5', temporalBoundsCacheHits: null, internalRoutePasses: Number.MAX_SAFE_INTEGER + 1 } }] }));
    assert.equal(invalid.includes('<summary>Timing details</summary>'), false);
    assert.equal(invalid.includes('<img'), false);
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
