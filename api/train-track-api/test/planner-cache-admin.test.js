import assert from 'node:assert/strict';
import test from 'node:test';
import { runInNewContext } from 'node:vm';
import express from 'express';
import cors from 'cors';
import { registerPlannerSearchAdminRoutes, renderPlannerSearchPage } from '../lib/planner-search-admin.js';
import { PlannerError } from '../lib/planner/contract.js';

const data = { rows: [], total: 0, page: 1, pageSize: 50, totalPages: 1,
    sort: 'startedAt', direction: 'desc', range: '24h', source: 'all', stats: {} };
const shell = ({ body }) => body;

async function fixture(t) {
    const app = express();
    app.use(cors()); // Match the public API: preflight must not bypass the gate.
    const state = { calls: 0, error: null, clearedSearches: 7, logged: [] };
    const options = { listSearches: async () => data, renderShell: shell,
        clearSearchCache: async () => {
            state.calls++;
            if (state.error) throw state.error;
            return { clearedSearches: state.clearedSearches };
        }, logger: { error: (...args) => state.logged.push(args) } };
    registerPlannerSearchAdminRoutes(app, options);
    const router = express.Router();
    registerPlannerSearchAdminRoutes(router, options);
    app.use('/train-track', router);
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    return { state, origin: `http://127.0.0.1:${server.address().port}` };
}

function control(html, currentUrl) {
    const url = new URL(html.match(/data-clear-url="([^"]+)"/)[1], currentUrl);
    const token = html.match(/data-csrf-token="([^"]+)"/)[1];
    assert.match(token, /^[a-f0-9]{64}$/);
    return { url, headers: { 'Content-Type': 'application/json',
        'X-TrainTrack-Admin-CSRF': token, 'Sec-Fetch-Site': 'same-origin' } };
}

test('cache clearing is POST-only and preserves proxy prefixes and trailing-slash entry points', async t => {
    const { state, origin } = await fixture(t);
    for (const prefix of ['', '/train-track']) for (const suffix of ['', '/']) {
        const currentUrl = `${origin}${prefix}/admin/journey-planner${suffix}?q=-1h&page=2`;
        const response = await fetch(currentUrl);
        assert.equal(response.headers.get('cache-control'), 'no-store');
        const html = await response.text();
        assert.match(html, /Clear search cache<\/button>/);
        assert.match(html, /aria-describedby="planner-cache-help"/);
        assert.match(html, /role="status" aria-live="polite" aria-atomic="true"/);
        assert.match(html, /Timetable indexes stay warm/);
        assert.match(html, /start a new app search/);
        const { url, headers } = control(html, currentUrl);
        assert.equal(url.pathname, `${prefix}/admin/journey-planner/cache/clear`);
        const count = state.calls;
        assert.equal((await fetch(url)).status, 404);
        assert.equal(state.calls, count, 'A GET or refresh must never clear results');
        const cleared = await fetch(url, { method: 'POST', headers, body: '{}' });
        assert.equal(cleared.status, 200);
        assert.equal(cleared.headers.get('cache-control'), 'no-store');
        assert.deepEqual(await cleared.json(), { clearedSearches: 7 });
        assert.equal(state.calls, count + 1);
    }
});

test('cache clear rejects forms, missing or invalid page tokens and cross-origin fetches despite permissive CORS', async t => {
    const { state, origin } = await fixture(t);
    const currentUrl = `${origin}/admin/journey-planner`;
    const { url, headers } = control(await (await fetch(currentUrl)).text(), currentUrl);
    const changes = [
        { 'Content-Type': 'application/x-www-form-urlencoded' },
        { 'X-TrainTrack-Admin-CSRF': undefined }, { 'X-TrainTrack-Admin-CSRF': 'invalid' },
        { 'Sec-Fetch-Site': undefined }, { 'Sec-Fetch-Site': 'none' },
        { 'Sec-Fetch-Site': 'same-site' }, { 'Sec-Fetch-Site': 'cross-site', Origin: 'https://hostile.example' }
    ];
    for (const change of changes) {
        const incoming = { ...headers, ...change };
        for (const [key, value] of Object.entries(incoming)) if (value === undefined) delete incoming[key];
        const response = await fetch(url, { method: 'POST', headers: incoming, body: '{}' });
        assert.equal(response.status, 403);
        assert.equal(response.headers.get('cache-control'), 'no-store');
        assert.equal((await response.json()).error.code, 'INVALID_ADMIN_REQUEST');
    }
    const preflight = await fetch(url, { method: 'OPTIONS', headers: { Origin: 'https://hostile.example',
        'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'content-type,x-traintrack-admin-csrf' } });
    assert.equal(preflight.status, 204);
    assert.equal(state.calls, 0);
});

test('worker failures never confirm success or expose private error details', async t => {
    const { state, origin } = await fixture(t);
    const currentUrl = `${origin}/admin/journey-planner`;
    const { url, headers } = control(await (await fetch(currentUrl)).text(), currentUrl);
    state.error = new Error('private worker path and configuration');
    let response = await fetch(url, { method: 'POST', headers, body: '{}' });
    assert.equal(response.status, 503);
    const error = await response.text();
    assert.equal(error.includes('private worker'), false);
    assert.match(error, /could not be cleared/);
    state.error = new PlannerError('SEARCH_BUSY', 'private queue diagnostics', 429);
    response = await fetch(url, { method: 'POST', headers, body: '{}' });
    assert.equal(response.status, 429);
    assert.match((await response.json()).error.message, /Wait for searches to finish/);
    assert.equal(state.logged.length, 2);
    state.error = null;
    state.clearedSearches = 0;
    response = await fetch(url, { method: 'POST', headers, body: '{}' });
    assert.deepEqual(await response.json(), { clearedSearches: 0 }, 'Clearing an empty cache is successful');
});

function browserController(fetch) {
    const attributes = new Map(), listeners = new Map();
    const button = { disabled: true, textContent: 'Clear search cache',
        dataset: { clearUrl: './journey-planner/cache/clear', csrfToken: 'page-token' },
        addEventListener: (type, callback) => listeners.set(type, callback),
        setAttribute: (name, value) => attributes.set(name, value), removeAttribute: name => attributes.delete(name) };
    const status = { textContent: '', dataset: {} };
    const html = renderPlannerSearchPage(data, { renderShell: shell, cacheClearToken: 'page-token' });
    const script = html.match(/<script data-planner-cache-controls>([\s\S]*?)<\/script>/)[1];
    runInNewContext(script, { document: { querySelector: selector => selector === '#planner-cache-clear' ? button : status }, fetch });
    return { button, status, attributes, click: () => listeners.get('click')() };
}

test('cache button waits for worker confirmation, prevents double clicks and reports success without navigating away', async () => {
    let finish, calls = 0;
    const controller = browserController(async (url, options) => {
        calls++;
        assert.equal(url, './journey-planner/cache/clear');
        assert.equal(options.method, 'POST');
        assert.equal(options.credentials, 'same-origin');
        assert.equal(options.headers['X-TrainTrack-Admin-CSRF'], 'page-token');
        assert.equal(options.body, '{}');
        return new Promise(resolve => { finish = resolve; });
    });
    assert.equal(controller.button.disabled, false);
    const request = controller.click();
    assert.equal(controller.button.disabled, true);
    assert.equal(controller.attributes.get('aria-busy'), 'true');
    assert.equal(controller.status.dataset.state, 'pending');
    assert.match(controller.status.textContent, /Waiting for the routing worker/);
    await controller.click();
    assert.equal(calls, 1);
    finish({ ok: true, json: async () => ({ clearedSearches: 7 }) });
    await request;
    assert.equal(controller.status.dataset.state, 'success');
    assert.match(controller.status.textContent, /Search cache cleared \(7 entries\)/);
    assert.match(controller.status.textContent, /new app search/);
    assert.equal(controller.button.disabled, false);
    assert.equal(controller.attributes.has('aria-busy'), false);
    assert.equal(controller.button.textContent, 'Clear search cache');
});

test('cache button restores retry controls for rejected, malformed and disconnected responses', async () => {
    for (const result of [
        { ok: false, json: async () => ({ error: { message: 'Refresh this admin page.' } }) },
        { ok: true, json: async () => ({ clearedSearches: -1 }) },
        { ok: true, json: async () => ({}) },
        { ok: false, json: async () => { throw new Error('Gateway HTML, not JSON'); } },
        null
    ]) {
        const controller = browserController(async () => {
            if (!result) throw new Error('Disconnected');
            return result;
        });
        await controller.click();
        assert.equal(controller.status.dataset.state, 'error');
        assert.match(controller.status.textContent, /Cache clearing was not confirmed/);
        assert.equal(controller.button.disabled, false);
        assert.equal(controller.attributes.has('aria-busy'), false);
    }
});
