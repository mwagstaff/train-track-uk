import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import { registerPlannerRoutes } from '../lib/planner-routes.js';
import { noOpPlannerSearchLog } from '../lib/planner-search-log.js';

test('v5 queued searches use the isolated combined method even on a RAPTOR-only service', async t => {
    const calls = [];
    const service = { config: { raptorOnly: true }, workerCount: 1,
        status: async () => ({ available: true, dataset: { version: 'a'.repeat(64) } }),
        call: async (method, payload) => { calls.push({ method, payload }); return { apiVersion: 5, journeys: [], warnings: [] }; }
    };
    const app = express();
    app.get('/api/v1/example', (_req, res) => res.json({ legacy: true }));
    registerPlannerRoutes(app, { service, searchLog: noOpPlannerSearchLog });
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => { server.close(); service.searchJobs.close(); service.combinedJobs.close(); service.routeBoards.close(); service.savedRouteBoards.close(); });
    const base = `http://127.0.0.1:${server.address().port}`;
    const response = await fetch(`${base}/api/v5/journey-planner/search-jobs`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ origin: 'nr:KTH', destination: '940GZZLUOXC', time: '2026-10-09T12:00:00Z', timeType: 'arriveBy' }) });
    assert.equal(response.status, 202);
    const submitted = await response.json();
    await new Promise(resolve => setTimeout(resolve, 10));
    const status = await (await fetch(`${base}/api/v5/journey-planner/search-jobs/${submitted.id}`)).json();
    assert.equal(status.status, 'completed');
    assert.equal(calls[0].method, 'combinedSearch');
    assert.equal(calls[0].payload.request.timeType, 'arriveBy');
    assert.equal(calls[0].payload.request.realtime, 'apply');
    assert.deepEqual(await (await fetch(`${base}/api/v1/example`)).json(), { legacy: true });
    assert.equal((await fetch(`${base}/api/v5/journey-planner/search-jobs/${submitted.id}`, { method: 'DELETE' })).status, 204);
});
