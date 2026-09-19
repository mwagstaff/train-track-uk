import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { registerPlannerRoutes } from '../lib/planner-routes.js';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';
import { noOpPlannerSearchLog } from '../lib/planner-search-log.js';

async function server(t) {
    const app = express();
    let plannerCalls = 0;
    let metricCalls = 0;
    const operations = [];
    // Match index.js: the planner owns its strict parser, and the existing
    // namespaces continue to use their larger JSON and form parsers afterwards.
    registerPlannerRoutes(app, {
        searchLog: noOpPlannerSearchLog,
        service: { search: async body => { plannerCalls++; return { body }; } },
        requestMiddleware: (req, res, next) => { metricCalls++; next(); },
        recordRequest: (operation, status) => operations.push({ operation, status })
    });
    app.use(express.json({ limit: '1mb' }));
    app.use(express.urlencoded({ extended: false, limit: '1mb' }));
    app.post('/api/v2/legacy', (req, res) => res.json({ body: req.body }));
    app.use((error, req, res, next) => res.status(error.status || 500).send('Legacy parser error'));
    const listener = app.listen(0, '127.0.0.1');
    await new Promise(resolve => listener.once('listening', resolve));
    t.after(() => new Promise(resolve => listener.close(resolve)));
    return {
        url: `http://127.0.0.1:${listener.address().port}`,
        plannerCalls: () => plannerCalls, metricCalls: () => metricCalls, operations
    };
}

test('production parser order enforces 16 KB planner JSON while legacy calls retain 1 MB', async t => {
    // Guard the real integration order as well as exercising that order below.
    const entry = await fs.readFile(new URL('../index.js', import.meta.url), 'utf8');
    assert.ok(entry.indexOf('registerPlannerRoutes(app,') < entry.indexOf("app.use(express.json({ limit: '1mb' }))"));
    const instance = await server(t);
    const send = (endpoint, body) => fetch(`${instance.url}${endpoint}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
    });
    const large = { padding: 'x'.repeat(100_000) };
    const planner = await send('/api/v3/journey-planner/search', large);
    assert.equal(planner.status, 413);
    assert.equal((await planner.json()).error.code, 'REQUEST_TOO_LARGE');
    assert.equal(instance.plannerCalls(), 0);
    const legacy = await send('/api/v2/legacy', large);
    assert.equal(legacy.status, 200);
    assert.deepEqual((await legacy.json()).body, large);
    const beyondLegacyLimit = await send('/api/v2/legacy', { padding: 'x'.repeat(1_100_000) });
    assert.equal(beyondLegacyLimit.status, 413);
    const small = await send('/api/v3/journey-planner/search', { origin: 'KTH', destination: 'VIC' });
    assert.equal(small.status, 200);
    assert.equal(instance.plannerCalls(), 1);
    assert.equal(instance.metricCalls(), 2);
    assert.deepEqual(instance.operations, [{ operation: 'search', status: 413 }, { operation: 'search', status: 200 }]);
});

test('malformed planner JSON has a structured error, and form bodies cannot bypass its parser', async t => {
    const instance = await server(t);
    const malformed = await fetch(`${instance.url}/api/v3/journey-planner/search`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{bad'
    });
    assert.equal(malformed.status, 400);
    assert.equal((await malformed.json()).error.code, 'INVALID_REQUEST');
    const form = await fetch(`${instance.url}/api/v3/journey-planner/search`, {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'origin=KTH&destination=VIC'
    });
    assert.equal(form.status, 415);
    assert.equal((await form.json()).error.code, 'INVALID_REQUEST');
    assert.equal(instance.plannerCalls(), 0);
    const legacy = await fetch(`${instance.url}/api/v2/legacy`, {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, body: 'origin=KTH&destination=VIC'
    });
    assert.equal(legacy.status, 200);
    assert.deepEqual((await legacy.json()).body, { origin: 'KTH', destination: 'VIC' });
});

test('a blocked active worker times out, is terminated, and a later request recovers', async t => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'planner-blocked-worker-'));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    const marker = path.join(directory, 'blocked-once');
    const filename = path.join(directory, 'worker.mjs');
    await fs.writeFile(filename, `
        import { parentPort } from 'node:worker_threads';
        import fs from 'node:fs';
        const marker = ${JSON.stringify(marker)};
        parentPort.on('message', message => {
            if (!fs.existsSync(marker)) {
                fs.writeFileSync(marker, 'blocked');
                Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0);
            }
            parentPort.postMessage({ id: message.id, result: { recovered: true } });
        });
    `);
    const service = new PlannerService({ ...plannerConfig({}), workerCount: 1, timeoutMs: 500 }, { workerURL: pathToFileURL(filename) });
    t.after(() => service.close());
    await assert.rejects(service.status(), { code: 'SEARCH_TIMEOUT' });
    const deadline = Date.now() + 4000;
    while (service.worker && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 20));
    assert.equal(service.worker, null, 'The unresponsive worker must be terminated after cancellation grace');
    service.config.timeoutMs = 2000;
    assert.deepEqual(await service.status(), { recovered: true });
});
