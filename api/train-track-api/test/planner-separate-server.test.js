import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import { registerPlannerGateway } from '../lib/planner-gateway.js';
import { PlannerRoutingStore } from '../lib/planner-routing-store.js';
import { plannerServiceAuthentication, registerPlannerInternalRoutes } from '../lib/planner-internal-routes.js';
import { PlannerTargetManager } from '../lib/planner-targets.js';
import { compressLargeResponses, createPlannerServer } from '../planner-server.js';
import http from 'node:http';
import { noOpPlannerSearchLog } from '../lib/planner-search-log.js';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';

const token = 'test-planner-token-long-enough';
const secret = 'test-routing-secret-long-enough';
const jobId = '11111111-1111-4111-8111-111111111111';

function memoryCollection() {
    const rows = new Map();
    return { rows,
        async findOne(filter) { return structuredClone(rows.get(filter._id) ?? null); },
        async insertOne(row) {
            if (rows.has(row._id)) throw Object.assign(new Error('duplicate'), { code: 11000 });
            rows.set(row._id, structuredClone(row));
        },
        async updateOne(filter, update, options) {
            let row = rows.get(filter._id);
            if (!row && !options?.upsert) return { matchedCount: 0 };
            row ??= { _id: filter._id };
            Object.assign(row, structuredClone(update.$set ?? {}));
            for (const [key, value] of Object.entries(update.$addToSet ?? {})) {
                row[key] = [...new Set([...(row[key] ?? []), value])];
            }
            rows.set(row._id, row);
            return { matchedCount: 1 };
        },
        async bulkWrite(operations) {
            this.bulkWrites = (this.bulkWrites ?? 0) + 1;
            for (const { updateOne } of operations) await this.updateOne(updateOne.filter, updateOne.update, { upsert: updateOne.upsert });
            return { ok: 1 };
        }
    };
}

test('ownership skips legacy-target artifacts and records other targets in one batch', async () => {
    const db = memoryCollection();
    const ownership = new PlannerRoutingStore({ secret, getCollection: async () => db, legacyTargetId: 'mini' });
    const journeys = Array.from({ length: 40 }, (_, index) => ({ id: `${index.toString(16).padStart(64, '0')}.${'a'.repeat(32)}` }));
    const payload = { apiVersion: 4, boards: [{ result: { journeys } }] };
    await ownership.rememberResponse('mini', 'saved-route-boards-v4', payload);
    assert.equal(db.rows.size, 0);
    assert.equal(await ownership.targetFor({ operation: 'journey', artifact: journeys[0].id }), 'mini');
    await ownership.rememberResponse('sky', 'saved-route-boards-v4', payload);
    assert.equal(db.bulkWrites, 1);
    assert.equal(db.rows.size, 40);
    assert.equal(await ownership.targetFor({ operation: 'journey', artifact: journeys[39].id }), 'sky');
});

async function listen(t, app) {
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    return `http://127.0.0.1:${server.address().port}`;
}

test('gateway keeps jobs and idempotent retries on their issuing target after selection changes', async t => {
    const remoteApp = express();
    remoteApp.use((req, res, next) => req.get('Authorization') === `Bearer ${token}` ? next() : res.sendStatus(401));
    remoteApp.use(express.json());
    let submissions = 0, polls = 0, forwardedNetwork;
    remoteApp.post('/api/v3/journey-planner/search-jobs', (req, res) => {
        submissions++;
        forwardedNetwork = req.get('X-Planner-Caller-Network');
        res.status(202).set('Retry-After', '1').json({ id: jobId, status: 'queued' });
    });
    remoteApp.get(`/api/v3/journey-planner/search-jobs/${jobId}`, (_req, res) => {
        polls++; res.json({ id: jobId, status: 'completed', result: { journeys: [] } });
    });
    const remoteUrl = await listen(t, remoteApp);
    const targetsById = new Map([
        ['sky', { id: 'sky', mode: 'embedded' }],
        ['mini', { id: 'mini', mode: 'remote', baseUrl: remoteUrl, token }]
    ]);
    let active = 'mini';
    const targets = { async pin(id) { const targetId = id ?? active; return { targetId, target: targetsById.get(targetId), revision: 1 }; } };
    const db = memoryCollection();
    const ownership = new PlannerRoutingStore({ secret, getCollection: async () => db, legacyTargetId: 'sky' });
    const gatewayApp = express();
    registerPlannerGateway(gatewayApp, { targets, ownership });
    let localCalls = 0;
    gatewayApp.use(express.json());
    gatewayApp.post('/api/v3/journey-planner/search-jobs', (_req, res) => { localCalls++; res.status(202).json({ id: 'local' }); });
    gatewayApp.get('/api/v3/journey-planner/status', (_req, res) => { localCalls++; res.json({ available: true, host: 'sky' }); });
    const gatewayUrl = await listen(t, gatewayApp);
    const headers = { 'Content-Type': 'application/json', 'Idempotency-Key': 'stable-key',
        'X-Planner-Client': 'test-client-123' };
    const first = await fetch(`${gatewayUrl}/api/v3/journey-planner/search-jobs`, { method: 'POST', headers,
        body: JSON.stringify({ origin: 'KTH', destination: 'VIC' }) });
    assert.equal(first.status, 202, await first.clone().text());
    assert.equal((await first.json()).id, jobId);
    assert.equal(await ownership.owner('job', jobId), 'mini');
    assert.ok(forwardedNetwork);
    active = 'sky';
    const poll = await fetch(`${gatewayUrl}/api/v3/journey-planner/search-jobs/${jobId}`);
    assert.equal(poll.status, 200, await poll.clone().text());
    assert.equal((await poll.json()).status, 'completed');
    const retry = await fetch(`${gatewayUrl}/api/v3/journey-planner/search-jobs`, { method: 'POST', headers,
        body: JSON.stringify({ origin: 'KTH', destination: 'VIC' }) });
    assert.equal(retry.status, 202, await retry.clone().text());
    const conflict = await fetch(`${gatewayUrl}/api/v3/journey-planner/search-jobs`, { method: 'POST', headers,
        body: JSON.stringify({ origin: 'KTH', destination: 'ECR' }) });
    assert.equal(conflict.status, 409, await conflict.clone().text());
    assert.equal((await conflict.json()).error.code, 'IDEMPOTENCY_CONFLICT');
    const status = await fetch(`${gatewayUrl}/api/v3/journey-planner/status`);
    assert.equal(status.status, 200, await status.clone().text());
    assert.equal((await status.json()).host, 'sky');
    assert.equal(submissions, 2);
    assert.equal(polls, 1);
    assert.equal(localCalls, 1);
});

test('large planner responses cross the gateway gzipped and arrive unchanged', async t => {
    const journeys = Array.from({ length: 200 }, (_, index) => ({ id: `${index.toString(16).padStart(64, '0')}.${'b'.repeat(32)}`,
        departure: '2026-09-22T21:18:19.000Z', legs: [{ kind: 'vehicle', from: { crs: 'KTH' }, to: { crs: 'VIC' } }] }));
    const board = { apiVersion: 4, boards: [{ id: 'saved', status: 'ready', result: { journeys } }] };
    const remoteApp = express();
    remoteApp.use((req, res, next) => req.get('Authorization') === `Bearer ${token}` ? next() : res.sendStatus(401));
    remoteApp.use(compressLargeResponses);
    remoteApp.post('/api/v4/journey-planner/route-boards', (_req, res) => res.json(board));
    remoteApp.get('/small', (_req, res) => res.json({ ok: true }));
    const remoteUrl = await listen(t, remoteApp);
    const encodingOf = (method, path, acceptEncoding) => new Promise((resolve, reject) => {
        const request = http.request(`${remoteUrl}${path}`, { method,
            headers: { Authorization: `Bearer ${token}`, 'Accept-Encoding': acceptEncoding } }, response => {
            response.resume(); response.once('end', () => resolve(response.headers['content-encoding'] ?? null));
        });
        request.once('error', reject); request.end();
    });
    const targets = { async pin() { return { targetId: 'mini', revision: 1,
        target: { id: 'mini', mode: 'remote', baseUrl: remoteUrl, token } }; } };
    const ownership = new PlannerRoutingStore({ secret, getCollection: async () => memoryCollection(), legacyTargetId: 'mini' });
    const gatewayApp = express();
    registerPlannerGateway(gatewayApp, { targets, ownership });
    const gatewayUrl = await listen(t, gatewayApp);
    const response = await fetch(`${gatewayUrl}/api/v4/journey-planner/route-boards`, { method: 'POST',
        headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ routes: [{ id: 'saved', origin: 'KTH', destination: 'VIC' }] }) });
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), board);
    const boards = '/api/v4/journey-planner/route-boards';
    assert.equal(await encodingOf('POST', boards, 'gzip'), 'gzip');
    assert.equal(await encodingOf('POST', boards, 'identity'), null);
    assert.equal(await encodingOf('GET', '/small', 'gzip'), null);
});

test('standalone operations authenticate before planner work and return sanitized readiness', async t => {
    let calls = 0;
    const service = { config: { dataDirectory: '/private/never-return' },
        status: async () => { calls++; return { available: true, apiVersion: 3,
            dataset: { version: 'dataset-one', sourceGenerationDate: '2026-09-20' } }; },
        maintenanceAvailable: () => true, pendingCount: () => 0,
        disruptionProfile: async body => ({ ...body, datasetVersion: 'dataset-one' }),
        clearSearchCache: async () => ({ clearedSearches: 4 }) };
    const app = express();
    app.use(plannerServiceAuthentication(token));
    registerPlannerInternalRoutes(app, { service, hostId: 'mikes-mac-mini', buildRevision: 'abc123',
        listSearches: async query => ({ rows: [{ host: 'mikes-mac-mini' }], page: Number(query.page ?? 1) }),
        now: () => Date.parse('2026-09-21T11:00:00Z'),
        readIngestion: async () => ({ schemaVersion: 1, enabled: true, inProgress: false,
            lastSuccessfulCheckAt: '2026-09-21T10:00:00Z', privatePath: '/private/secret', pendingGap: null,
            active: { metadata: { version: 'dataset-one', source: { generationDate: '2026-09-20', private: 'secret' } },
                validation: { valid: true, checkedAt: '2026-09-21T09:00:00Z', errors: ['/private'] } } }) });
    const url = await listen(t, app);
    const denied = await fetch(`${url}/internal/planner/v1/health`);
    assert.equal(denied.status, 401);
    assert.equal(calls, 0);
    const options = { headers: { Authorization: `Bearer ${token}` } };
    const health = await (await fetch(`${url}/internal/planner/v1/health`, options)).json();
    assert.deepEqual({ hostId: health.hostId, protocolVersion: health.protocolVersion, ready: health.ready },
        { hostId: 'mikes-mac-mini', protocolVersion: 1, ready: true });
    const readiness = await (await fetch(`${url}/internal/planner/v1/readiness`, options)).json();
    assert.equal(readiness.ingestion.active.validation.valid, true);
    assert.equal(JSON.stringify(readiness).includes('/private'), false);
    const clear = await fetch(`${url}/internal/planner/v1/cache/clear`, { method: 'POST', ...options,
        headers: { ...options.headers, 'Content-Type': 'application/json' }, body: '{}' });
    assert.deepEqual(await clear.json(), { clearedSearches: 4 });
    const historyPath = '/internal/planner/v1/admin/searches?page=2';
    assert.equal((await fetch(`${url}${historyPath}`)).status, 401);
    const history = await (await fetch(`${url}${historyPath}`, options)).json();
    assert.deepEqual(history, { rows: [{ host: 'mikes-mac-mini' }], page: 2 });
});

test('load admission override is authenticated, exclusive, and restores the configured cap', async t => {
    const service = new PlannerService(plannerConfig({}));
    t.after(() => service.close());
    const app = express();
    app.use(plannerServiceAuthentication(token));
    registerPlannerInternalRoutes(app, { service, hostId: 'mikes-mac-mini' });
    const url = await listen(t, app);
    const endpoint = `${url}/internal/planner/v1/load/admission`;
    const body = JSON.stringify({ maxQueue: 20 });
    assert.equal((await fetch(endpoint, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body })).status, 401);
    const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
    const invalid = await fetch(endpoint, { method: 'POST', headers, body: JSON.stringify({ maxQueue: 101 }) });
    assert.equal(invalid.status, 400);
    const acquired = await fetch(endpoint, { method: 'POST', headers, body });
    assert.equal(acquired.status, 200);
    const lease = await acquired.json();
    assert.equal(lease.configuredMaxQueue, 8);
    assert.equal(service.maxQueue, 20);
    assert.equal((await fetch(endpoint, { method: 'POST', headers, body })).status, 409);
    const wrong = await fetch(endpoint, { method: 'DELETE', headers, body: JSON.stringify({ leaseId: 'wrong' }) });
    assert.equal(wrong.status, 409);
    assert.equal(service.maxQueue, 20);
    const released = await fetch(endpoint, { method: 'DELETE', headers,
        body: JSON.stringify({ leaseId: lease.leaseId }) });
    assert.deepEqual(await released.json(), { restored: true, maxQueue: 8 });
    assert.equal(service.maxQueue, 8);
});

test('gateway reads Mini history over authenticated HTTP while selection stays on sky', async t => {
    const app = express();
    app.use(plannerServiceAuthentication(token));
    app.get('/internal/planner/v1/admin/searches', (req, res) => res.json({ rows: [{ host: 'mikes-mac-mini' }],
        page: Number(req.query.page), pageSize: Number(req.query.per_page), q: req.query.q, stats: { total: 1 } }));
    const url = await listen(t, app);
    const targets = [
        { id: 'sky', mode: 'embedded', expectedHostId: 'sky', service: {} },
        { id: 'mini', mode: 'remote', expectedHostId: 'mikes-mac-mini', baseUrl: url, token }
    ];
    const manager = new PlannerTargetManager({ targets, defaultTargetId: 'sky', forceTargetId: 'sky' });
    const rows = await manager.listSearches({ historyTarget: 'mini', page: '2', per_page: '25', q: '-1h' });
    assert.equal(rows.historyTarget, 'mini');
    assert.equal(rows.page, 2);
    assert.equal(rows.pageSize, 25);
    assert.equal(rows.q, '-1h');
    assert.equal(rows.rows[0].host, 'mikes-mac-mini');
    assert.equal((await manager.pin()).targetId, 'sky');
    await assert.rejects(manager.listSearches({ historyTarget: 'unconfigured' }), /configured planner history source/);
});

test('target activation checks readiness and uses revision comparison before changing admissions', async () => {
    const row = { _id: 'active', targetId: 'sky', revision: 3, updatedAt: new Date(), previousTargetId: null };
    const db = { async findOne() { return structuredClone(row); },
        async findOneAndUpdate(filter, update) {
            if (filter.revision !== row.revision) return null;
            Object.assign(row, structuredClone(update.$set)); row.revision += update.$inc.revision;
            return structuredClone(row);
        }, async insertOne() {} };
    const service = { config: {}, status: async () => ({ available: true, apiVersion: 3,
        dataset: { version: 'dataset', sourceGenerationDate: '2026-09-21' } }), clearSearchCache: async () => ({ clearedSearches: 0 }) };
    const targets = [
        { id: 'sky', mode: 'embedded', label: 'Sky', expectedHostId: 'sky', protocolVersion: 1, service },
        { id: 'mini', mode: 'embedded', label: 'Mini', expectedHostId: 'mikes-mac-mini', protocolVersion: 1, service }
    ];
    const manager = new PlannerTargetManager({ targets, getCollection: async () => db, defaultTargetId: 'sky',
        now: () => Date.parse('2026-09-21T11:00:00Z'), readIngestion: async () => ({ schemaVersion: 1,
            enabled: true, inProgress: false, pendingGap: null, lastSuccessfulCheckAt: '2026-09-21T10:00:00Z',
            active: { metadata: { version: 'dataset', source: { generationDate: '2026-09-21' } },
                validation: { valid: true } } }) });
    await manager.init();
    const selected = await manager.select({ targetId: 'mini', revision: 3, operator: 'tester' });
    assert.equal(selected.targetId, 'mini');
    assert.equal(selected.revision, 4);
    assert.equal(row.previousTargetId, 'sky');
    await assert.rejects(manager.select({ targetId: 'sky', revision: 3 }), { code: 'TARGET_REVISION_CONFLICT' });
});

test('explicit memory persistence starts the production planner without Mongo for isolated measurements', async () => {
    let closed = false;
    const service = { config: { dataDirectory: '/tmp/planner-service-test' }, close() { closed = true; } };
    const runtime = await createPlannerServer({ env: { NODE_ENV: 'production', PLANNER_HOST_ID: 'mini-planner',
        PLANNER_SERVICE_TOKEN: token, PLANNER_INGESTION_ENABLED: 'false', PLANNER_PERSISTENCE_MODE: 'memory',
        PLANNER_DATA_DIR: '/tmp/planner-service-test' }, service });
    assert.equal(runtime.persistenceMode, 'memory');
    assert.equal(runtime.searchLog, noOpPlannerSearchLog);
    await runtime.close();
    assert.equal(closed, true);
});

test('production planner accepts the dedicated Mongo URI variable', async () => {
    const env = { NODE_ENV: 'production', PLANNER_HOST_ID: 'mini', PLANNER_SERVICE_TOKEN: token,
        PLANNER_INGESTION_ENABLED: 'false', PLANNER_DATA_DIR: '/tmp/planner-mongo-env-test' };
    const service = { config: { dataDirectory: env.PLANNER_DATA_DIR }, close() {} };
    await assert.rejects(createPlannerServer({ env, service, searchLog: noOpPlannerSearchLog,
        initializeMongo: false }), /MONGODB_URI_JOURNEY_PLANNER is required/);
    const runtime = await createPlannerServer({ env: { ...env,
        MONGODB_URI_JOURNEY_PLANNER: 'mongodb://127.0.0.1:27017/train_track_planner' },
        service, searchLog: noOpPlannerSearchLog, initializeMongo: false });
    assert.equal(runtime.persistenceMode, 'mongo');
    await runtime.close();
});
