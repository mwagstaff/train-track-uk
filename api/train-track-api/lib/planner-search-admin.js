import { readFileSync } from 'node:fs';
import { createAdminUrl } from './admin-url.js';

const ROUTE = '/admin/journey-planner';
const SOURCES = [
    ['all', 'All searches'],
    ['search', 'Search'],
    ['search-job', 'Queued search'],
    ['saved-route', 'Saved route'],
    ['saved-refresh', 'Live refresh'],
    ['saved-replan', 'Route replan']
];
const RANGES = [['1h', 'Last hour'], ['24h', 'Last 24 hours'], ['7d', 'Last 7 days']];
const COLUMNS = [
    ['origin', 'From'], ['destination', 'To'], ['startedAt', 'Search started'],
    ['finishedAt', 'Results returned'], ['status', 'Status'], ['cacheStatus', 'Cache'],
    ['durationMs', 'Duration'], ['source', 'Source']
];
const stationNames = loadStationNames();
const dateFormatter = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London', day: '2-digit', month: 'short', year: 'numeric'
});
const timeFormatter = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23'
});

export function registerPlannerSearchAdminRoutes(app, { listSearches, renderShell, logger = console }) {
    app.get(ROUTE, async (req, res) => {
        res.set('Cache-Control', 'no-store');
        const requestPath = req.path || ROUTE;
        try {
            const data = await listSearches(req.query || {});
            res.type('html').send(renderPlannerSearchPage(data, { renderShell, requestPath }));
        } catch (error) {
            logger.error('[admin] Failed to load journey planner searches:', error?.message || error);
            res.status(503).type('html').send(renderShell({
                requestPath,
                title: 'Journey planner searches · Train Track Admin',
                extraStyle: styles,
                body: `<main class="wrap planner-admin"><h1>Journey planner searches</h1>
                    <section class="planner-error" role="alert"><h2>Search logs are unavailable</h2>
                    <p>The search history could not be loaded. Try refreshing this page.</p>
                    <a class="planner-button" href="${escapeHtml(createAdminUrl(requestPath)(ROUTE))}">Try again</a></section></main>`
            }));
        }
    });
}

export function renderPlannerSearchPage(data, { renderShell, now = new Date(), requestPath = ROUTE }) {
    const url = createAdminUrl(requestPath);
    const { rows, total, page, pageSize, totalPages, sort, direction, range, source, stats } = data;
    const filteredLabel = RANGES.find(([value]) => value === range)?.[1] || 'Last 24 hours';
    const successRate = percentage(stats.success, stats.completed);
    const failureRate = percentage(stats.fail, stats.completed);
    const cacheRate = percentage(stats.cacheHits, stats.cacheHits + stats.cacheMisses);
    const cards = [
        ['Searches', number(stats.total), `${number(stats.pending)} unfinished · ${number(stats.other)} other`],
        ['Success / failure', `${successRate} / ${failureRate}`, `${number(stats.completed)} successful or failed searches`],
        ['99th percentile', duration(stats.p99DurationMs), '99% finished within this time'],
        ['Longest search', duration(stats.maxDurationMs), 'Includes waiting in the queue'],
        ['Average duration', duration(stats.averageDurationMs), 'Successful and failed searches'],
        ['Cache hit rate', cacheRate, `${number(stats.cacheHits)} hits · ${number(stats.cacheMisses)} misses`]
    ];
    const tableHead = COLUMNS.map(([key, label]) => {
        const active = sort === key;
        const nextDirection = active && direction === 'asc' ? 'desc' : 'asc';
        const arrow = active ? (direction === 'asc' ? '↑' : '↓') : '↕';
        const stationHint = key === 'origin' || key === 'destination' ? ' by station code' : '';
        return `<th scope="col" aria-sort="${active ? (direction === 'asc' ? 'ascending' : 'descending') : 'none'}">
            <a href="${href(url, data, { sort: key, direction: nextDirection, page: 1 })}" aria-label="Sort ${escapeHtml(label)}${stationHint}, ${nextDirection === 'asc' ? 'ascending' : 'descending'}">${label}<span class="sort-arrow" aria-hidden="true">${arrow}</span></a></th>`;
    }).join('');
    const first = total ? (page - 1) * pageSize + 1 : 0;
    const last = Math.min(page * pageSize, total);
    return renderShell({
        requestPath,
        title: 'Journey planner searches · Train Track Admin',
        extraStyle: styles,
        body: `<main class="wrap planner-admin">
            <header class="planner-heading"><div><p class="planner-eyebrow">Train Track Admin</p>
                <h1>Journey planner searches</h1>
                <p class="meta">Seven days of search history · All times Europe/London</p></div>
                <a class="planner-button secondary" href="${href(url, data)}">Refresh</a>
            </header>
            <form class="planner-filters" action="${escapeHtml(url(ROUTE))}" method="GET">
                <div class="planner-filter"><label for="planner-period">Period</label><select id="planner-period" name="range">${options(RANGES, range)}</select></div>
                <div class="planner-filter"><label for="planner-source">Source</label><select id="planner-source" name="source">${options(SOURCES, source)}</select></div>
                <div class="planner-filter"><label for="planner-page-size">Rows per page</label><select id="planner-page-size" name="per_page">${options([[25, '25'], [50, '50'], [100, '100']], pageSize)}</select></div>
                <input type="hidden" name="sort" value="${escapeHtml(sort)}">
                <input type="hidden" name="direction" value="${escapeHtml(direction)}">
                <button type="submit">Apply filters</button>
                <span class="planner-updated">Figures checked ${formatTime(stats.asOf || now, false)}</span>
            </form>
            <section aria-labelledby="planner-summary-title">
                <h2 id="planner-summary-title" class="planner-section-title">${escapeHtml(filteredLabel)}<span>All matching searches, across every page</span></h2>
                <dl class="planner-stats">${cards.map(([label, value, detail]) => `<div><dt>${label}</dt><dd>${value}</dd><p>${detail}</p></div>`).join('')}</dl>
                <details class="planner-definitions"><summary>How these figures are calculated</summary>
                    <p>Durations run from search submission to completion on the server, including queue time. They do not include delivery to the device. The 99th percentile is the observed nearest-rank value; small samples may equal the longest search. Success, failure and duration figures include successful and failed searches only. A search returning no journeys still counts as successful.</p>
                    <p>Unfinished searches, cancellations and expired work are excluded from success and failure percentages. Unfinished searches may be queued, running or interrupted by a server restart. Cache hit rate uses known hits and misses only; ${number(stats.cacheUnknown)} searches have no cache result. Results returned shows server completion time, including failures. Station columns sort by station code. Summary figures may be cached for 15 seconds.</p>
                </details>
            </section>
            <section class="panel planner-results" aria-labelledby="planner-table-title">
                <div class="planner-table-heading"><h2 id="planner-table-title">Search history</h2><span>${number(first)}–${number(last)} of ${number(total)}</span></div>
                <div class="table-wrap" role="region" aria-label="Journey planner search history, scroll horizontally for all columns" tabindex="0">
                    <table><caption class="sr-only">Journey planner searches. Select a column heading to sort. All dates are in Europe/London.</caption>
                    <thead><tr>${tableHead}</tr></thead>
                    <tbody>${rows.length ? rows.map(renderRow).join('') : `<tr><td colspan="8" class="empty"><strong>No searches in this period</strong><p>New journey planner searches will appear here. Try a longer period or another source.</p></td></tr>`}</tbody></table>
                </div>
            </section>
            <nav class="pager planner-pager" aria-label="Search history pages">
                ${page > 1 ? `<a href="${href(url, data, { page: page - 1 })}" rel="prev">Previous</a>` : '<span aria-disabled="true">Previous</span>'}
                <span>Page ${number(page)} of ${number(totalPages)}</span>
                ${page < totalPages ? `<a href="${href(url, data, { page: page + 1 })}" rel="next">Next</a>` : '<span aria-disabled="true">Next</span>'}
            </nav>
        </main>`
    });
}

function renderRow(row) {
    const status = ['success', 'fail', 'pending', 'other'].includes(row.status) ? row.status : 'other';
    const statusLabel = { success: 'Success', fail: 'Failed', pending: 'Unfinished', other: 'Other' }[status];
    const cache = ['hit', 'miss'].includes(row.cacheStatus) ? row.cacheStatus : 'unknown';
    const detail = row.errorCode || (status === 'pending' ? row.phase : row.outcome);
    const resultDetail = status === 'success' && Number.isFinite(row.resultCount)
        ? `${number(row.resultCount)} ${row.resultCount === 1 ? 'journey' : 'journeys'}` : null;
    const sourceLabel = SOURCES.find(([value]) => value === row.source)?.[1] || row.source || 'Unknown';
    return `<tr>
        <td class="planner-station">${station(row.origin)}${Array.isArray(row.via) && row.via.length ? `<small>via ${escapeHtml(row.via.join(' → '))}</small>` : ''}</td>
        <td class="planner-station">${station(row.destination)}</td>
        <td class="planner-date">${formatTime(row.startedAt)}</td>
        <td class="planner-date">${row.finishedAt ? formatTime(row.finishedAt) : '<span class="planner-muted">—</span>'}</td>
        <td><span class="planner-status status-${status}">${statusLabel}</span>${detail && !['success', 'fail'].includes(detail) ? `<small class="planner-outcome">${escapeHtml(humanize(detail))}</small>` : ''}${resultDetail ? `<small>${resultDetail}</small>` : ''}</td>
        <td><span class="planner-cache cache-${cache}">${cache === 'unknown' ? 'Unknown' : cache === 'hit' ? 'Hit' : 'Miss'}</span>${row.coalesced ? '<small>Shared work</small>' : ''}</td>
        <td class="planner-duration">${duration(row.durationMs)}</td>
        <td>${escapeHtml(sourceLabel)}</td>
    </tr>`;
}

function station(code) {
    const name = stationNames.get(code);
    return `<strong>${escapeHtml(code || '—')}</strong>${name ? `<small>${escapeHtml(name)}</small>` : ''}`;
}

function loadStationNames() {
    try {
        return new Map(JSON.parse(readFileSync(new URL('../resources/stations.json', import.meta.url), 'utf8')).map(station => [station.crs, station.name]));
    } catch {
        return new Map();
    }
}

function formatTime(input, includeDate = true) {
    const date = new Date(input);
    if (!input || !Number.isFinite(date.getTime())) return '—';
    return `<time datetime="${date.toISOString()}">${timeFormatter.format(date)}${includeDate ? `<small>${dateFormatter.format(date)}</small>` : ''}</time>`;
}

function duration(value) {
    if (value === null || value === undefined || !Number.isFinite(value)) return '—';
    if (value < 1000) return `${Math.round(value)} ms`;
    if (value < 60000) return `${(value / 1000).toFixed(1)} s`;
    return `${Math.floor(value / 60000)}m ${Math.floor((value % 60000) / 1000)}s`;
}

function percentage(numerator, denominator) {
    return denominator ? `${((numerator / denominator) * 100).toFixed(1)}%` : '—';
}

function number(value) { return Number(value || 0).toLocaleString('en-GB'); }
function humanize(value) { return String(value).replace(/[_-]+/g, ' '); }
function options(values, selected) { return values.map(([value, label]) => `<option value="${escapeHtml(value)}"${String(value) === String(selected) ? ' selected' : ''}>${escapeHtml(label)}</option>`).join(''); }
function href(url, data, overrides = {}) {
    const next = { ...data, ...overrides };
    const query = new URLSearchParams({ range: next.range, source: next.source, sort: next.sort, direction: next.direction, page: next.page, per_page: next.pageSize });
    return escapeHtml(url(`${ROUTE}?${query}`));
}
function escapeHtml(value) { return String(value ?? '').replace(/[&<>"']/g, character => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[character])); }

const styles = `
    .planner-admin { max-width: 1500px; }
    .planner-admin :is(a,button,select,summary,[tabindex]):focus-visible { outline: 3px solid #0057b8; outline-offset: 3px; }
    .planner-heading { display:flex; align-items:center; justify-content:space-between; gap:20px; }
    .planner-eyebrow { margin:0 0 8px; color:var(--muted); font-size:12px; letter-spacing:.08em; text-transform:uppercase; font-weight:600; }
    .planner-heading h1 { margin:0 0 8px; font-size:clamp(25px,3vw,34px); letter-spacing:-.025em; }
    .planner-heading .meta { margin:0; font-size:14px; line-height:1.5; }
    .planner-button { display:inline-block; padding:10px 15px; border-radius:7px; border:1px solid var(--accent); background:var(--accent); color:#fff; font-size:14px; text-decoration:none; }
    .planner-button.secondary { background:var(--panel); border-color:var(--line); color:var(--text); }
    .planner-filters { display:flex; flex-wrap:wrap; align-items:end; gap:12px; padding:24px 0 22px; border-bottom:1px solid var(--line); }
    .planner-filter { display:grid; gap:6px; }
    .planner-filters label { font-size:12px; font-weight:600; color:var(--muted); }
    .planner-filters select { min-height:39px; border:1px solid var(--line); background:var(--panel); color:var(--text); border-radius:7px; padding:8px 34px 8px 10px; font:inherit; font-size:14px; font-weight:400; }
    .planner-filters button { min-height:39px; font-size:14px; }
    .planner-updated { margin-left:auto; align-self:end; padding-bottom:10px; font-size:12px; color:var(--muted); }
    .planner-section-title { margin:23px 0 14px; font-size:15px; font-weight:600; }
    .planner-section-title span { margin-left:12px; font-size:12px; font-weight:400; color:var(--muted); }
    .planner-stats { display:grid; grid-template-columns:repeat(6,minmax(0,1fr)); gap:12px; margin:0; }
    .planner-stats div { background:var(--panel); border:1px solid var(--line); border-radius:8px; padding:17px 15px 15px; }
    .planner-stats dt { color:var(--muted); font-size:12px; font-weight:600; }
    .planner-stats dd { margin:10px 0 8px; font-size:clamp(20px,2vw,28px); font-weight:650; letter-spacing:-.03em; font-variant-numeric:tabular-nums; white-space:nowrap; }
    .planner-stats div:nth-child(2) dd { font-size:clamp(19px,1.7vw,25px); }
    .planner-stats p { margin:0; min-height:32px; color:var(--muted); font-size:11px; line-height:1.45; }
    .planner-definitions { margin:13px 0 26px; color:var(--muted); font-size:12px; max-width:1000px; line-height:1.65; }
    .planner-definitions summary { cursor:pointer; width:fit-content; color:var(--accent); }
    .planner-definitions p { margin:8px 0; }
    .planner-results { box-shadow:none; border-radius:9px; }
    .planner-table-heading { display:flex; align-items:center; justify-content:space-between; padding:15px 16px; border-bottom:1px solid var(--line); }
    .planner-table-heading h2 { padding:0; border:0; background:none; font-size:16px; }
    .planner-table-heading>span { color:var(--muted); font-size:12px; }
    .planner-results table { min-width:1100px; }
    .planner-results th { padding:0; }
    .planner-results th a { display:flex; align-items:center; gap:9px; padding:12px 14px; color:inherit; white-space:nowrap; }
    .planner-results th[aria-sort="ascending"], .planner-results th[aria-sort="descending"] { color:var(--accent); background:#eef4fc; }
    .planner-results th a:hover { background:#e8eff9; }
    .sort-arrow { color:var(--muted); font-size:14px; }
    .planner-results td { padding:14px; font-size:13px; line-height:1.4; }
    .planner-results small { display:block; font-size:11px; line-height:1.4; margin-top:4px; color:var(--muted); }
    .planner-station { min-width:100px; max-width:180px; }
    .planner-station strong { letter-spacing:.04em; }
    .planner-date { white-space:nowrap; font-variant-numeric:tabular-nums; }
    .planner-duration { font-weight:600; white-space:nowrap; font-variant-numeric:tabular-nums; }
    .planner-status, .planner-cache { display:inline-block; border-radius:4px; padding:3px 7px; font-size:11px; line-height:1.4; font-weight:600; white-space:nowrap; }
    .status-success { background:#e1f2e8; color:#17633b; }
    .status-fail { background:#fbe7e6; color:#a22b27; }
    .status-pending { background:#e6effc; color:#245b9b; }
    .status-other { background:#eceef2; color:#505d70; }
    .cache-hit { color:#17633b; background:#e1f2e8; }
    .cache-miss, .cache-unknown { background:#f0f2f5; color:#536176; }
    .planner-outcome { max-width:180px; overflow-wrap:anywhere; }
    .planner-muted { color:var(--muted); }
    .planner-results .empty { padding:38px 20px; text-align:center; }
    .planner-results .empty strong { font-size:15px; color:var(--text); }
    .planner-results .empty p { margin:8px 0 0; }
    .planner-pager { margin-top:20px; }
    .planner-error { margin-top:28px; padding:24px; background:var(--panel); border:1px solid var(--line); border-radius:8px; }
    .planner-error h2 { font-size:19px; margin-top:0; }
    .planner-error p { color:var(--muted); line-height:1.5; }
    .sr-only { position:absolute; width:1px; height:1px; padding:0; overflow:hidden; clip:rect(0,0,0,0); white-space:nowrap; border:0; }
    @media(max-width:1150px) { .planner-stats { grid-template-columns:repeat(3,minmax(0,1fr)); } .planner-stats dd { font-size:27px; } .planner-stats div:nth-child(2) dd { font-size:25px; } }
    @media(max-width:640px) { .planner-stats { grid-template-columns:repeat(2,minmax(0,1fr)); gap:8px; } .planner-stats div { padding:14px 12px; } .planner-stats dd { font-size:25px; } .planner-stats div:nth-child(2) dd { font-size:20px; } .planner-heading { align-items:start; gap:12px; } .planner-heading .meta { font-size:12px; } .planner-section-title span { display:block; margin:7px 0 0; } .planner-updated { width:100%; margin:0; padding:0; } .planner-filters { gap:12px 10px; } .planner-pager { gap:5px; } .planner-pager a,.planner-pager span { padding:10px; font-size:12px; } }
`;
