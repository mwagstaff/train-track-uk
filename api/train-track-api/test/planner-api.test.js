import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { registerPlannerRoutes } from '../lib/planner-routes.js';
import { noOpPlannerSearchLog } from '../lib/planner-search-log.js';
import { normalizeRequest, encodeCursor, decodeCursor, PlannerError, CAPABILITIES } from '../lib/planner/contract.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';

const version = 'a'.repeat(64);
const request = { origin: 'KTH', destination: 'VIC', time: '2026-09-08T07:00:00+01:00', timeType: 'departAfter' };
const config = { ...plannerConfig({}), datasetPath: '/synthetic/planner', timeoutMs: 1000 };
const now = () => Date.parse('2026-09-15T12:00:00Z');
function repository(id = version) {
    return { version: id,
        metadata: { source: { generationDate: '2026-08-25', path: '/private/source', archiveSha256: 'private' },
            importedAt: '2026-09-15T10:00:00Z', maxEventDayOffset: 1,
            coverage: { startDate: '2026-05-17', endDate: '2027-05-15', basis: 'Test fixtures' }, limitations: [] },
        stations: [{ crs: 'KTH', name: 'Kent House', aliases: ['Kent'], minimumChangeMinutes: 4 },
            { crs: 'VIC', name: 'London Victoria', aliases: [], minimumChangeMinutes: 15 },
            { crs: 'ABW', name: 'Abbey Wood', aliases: ['ABX'], minimumChangeMinutes: 5 }],
        rules: { tsi: [], links: [] },
        resolveServices: () => ({ services: [], diagnostics: { counts: {} } }), close() {} };
}
function result(req) {
    return { journeys: [{ departure: req.time, arrival: new Date(Date.parse(req.time) + 21 * 60000).toISOString(),
        durationMinutes: 21, changes: 0, legs: [{ kind: 'vehicle', mode: 'rail', operator: 'SE',
            from: { crs: 'KTH', name: 'Kent House' }, to: { crs: 'VIC', name: 'London Victoria' },
            departure: req.time, arrival: new Date(Date.parse(req.time) + 21 * 60000).toISOString(),
            serviceId: 'source-id', sourceRef: { path: '/private/archive', line: 713229 }, variantId: 'private-variant',
            callingPoints: [{ station: { crs: 'KTH', name: 'Kent House' }, departure: req.time }] }] }],
        searchWindow: { from: req.time, to: new Date(Date.parse(req.time) + 120 * 60000).toISOString() },
        searchTruncated: false, warnings: [], pagination: { nextOffset: 5,
            earlierTime: new Date(Date.parse(req.time) - 120 * 60000).toISOString(),
            laterTime: new Date(Date.parse(req.time) + 120 * 60000).toISOString() } };
}
function engine(overrides = {}) {
    return new PlannerEngine(config, { openDataset: async () => repository(), findJourneys: result, now, ...overrides });
}

test('strict public request validation preserves exact requested instant and bounds', () => {
    const value = normalizeRequest({ ...request, origin: ' kth ', time: '2026-09-08T07:00:00.125+01:00' });
    assert.equal(value.origin, 'KTH');
    assert.equal(value.time, '2026-09-08T06:00:00.125Z');
    for (const change of [{ time: '2026-09-08T07:00:00' }, { time: '2026-02-30T07:00:00Z' },
        { time: '2026-99-99T07:00:00Z' }, { time: '2026-09-08T25:00:00Z' },
        { maxChanges: 6 }, { maxChanges: '2' }, { extraConnectionMinutes: -1 }, { limit: 100 },
        { allowedModes: ['ferryTransfer'] }, { allowedModes: [] }, { timeType: 'whenever' }]) {
        assert.throws(() => normalizeRequest({ ...request, ...change }), PlannerError);
    }
});

test('long-distance defaults allow five changes and six hours while explicit limits and cursors stay exact', () => {
    const defaults = normalizeRequest(request);
    assert.equal(defaults.maxChanges, 5);
    assert.equal(defaults.windowMinutes, 360);
    assert.equal(CAPABILITIES.maxChanges, 5);
    for (const maxChanges of [0, 2, 5]) {
        const bounded = normalizeRequest({ ...request, maxChanges, windowMinutes: 120 });
        assert.equal(bounded.maxChanges, maxChanges);
        assert.equal(bounded.windowMinutes, 120);
        assert.deepEqual(decodeCursor(encodeCursor(bounded, version)).request, bounded);
    }
});

test('cursors preserve version, exact query policy and within-window offset', () => {
    const normalized = normalizeRequest(request);
    assert.deepEqual(decodeCursor(encodeCursor(normalized, version, 5)), { version, request: normalized, offset: 5 });
    assert.throws(() => decodeCursor('!'), { code: 'INVALID_REQUEST' });
    for (const policy of ['scheduled-v1', 'scheduled-v2']) {
        const wrongPolicy = Buffer.from(JSON.stringify({ policy, version, request, offset: 5 })).toString('base64url');
        assert.throws(() => decodeCursor(wrongPolicy), { code: 'CURSOR_EXPIRED' });
    }
});

test('public metadata, stations and journeys never expose source paths or raw records', async () => {
    const instance = engine();
    const status = await instance.status();
    assert.equal(status.available, true);
    assert.equal(status.apiVersion, 3);
    const response = await instance.search({ request: normalizeRequest(request) });
    assert.equal(response.dataset.version, version);
    assert.equal(response.journeys.length, 1);
    assert.equal(JSON.stringify(response).includes('/private'), false);
    assert.equal(JSON.stringify(response).includes('private-variant'), false);
    assert.deepEqual((await instance.stationList('kent')).stations.map(station => station.crs), ['KTH']);
    const details = await instance.journey(response.journeys[0].id);
    assert.deepEqual(details.journey, response.journeys[0]);
    assert.equal(details.dataset.sourceGenerationDate, '2026-08-25');
});

test('saved-route discovery performs one ordinary search, preserves vias and exports only relevant connection rules', async () => {
    const repo = repository();
    repo.stations.push({ crs: 'EUS', name: 'Euston', minimumChangeMinutes: 15 });
    repo.rules.tsi = [{ station: 'VIC', arrivingOperator: 'SE', departingOperator: 'SN', minutes: 10 },
        { station: 'EUS', arrivingOperator: 'VT', departingOperator: 'SR', minutes: 15 }];
    repo.rules.links = [{ origin: 'VIC', destination: 'KTH', mode: 'walk', minutes: 30 },
        { origin: 'EUS', destination: 'VIC', mode: 'tubeTransfer', minutes: 15 }];
    const calls = [];
    const instance = engine({ openDataset: async () => repo, findJourneys: (query, network, options) => {
        calls.push({ query, options }); return result(query);
    } });
    const plan = await instance.savedRoutePlan({ request: { ...request, via: ['ABW'], realtime: 'apply' }, version });
    assert.equal(calls.length, 1);
    assert.deepEqual(calls[0].query.via, ['ABW']);
    assert.equal(calls[0].query.realtime, undefined);
    assert.notEqual(calls[0].options.departureProfile, true);
    assert.equal(calls[0].options.excludeDirect, true);
    assert.equal(plan.result.journeys.length, 1);
    assert.deepEqual(plan.connections.stations.map(station => station.crs), ['KTH', 'VIC']);
    assert.deepEqual(plan.connections.rules.tsi, repo.rules.tsi.slice(0, 1));
    assert.deepEqual(plan.connections.rules.links, repo.rules.links.slice(0, 1));
    assert.equal(plan.result.connections, undefined, 'Internal rule context must not change public search results');
    await assert.rejects(instance.savedRoutePlan({ request: { ...request, via: ['ABX'] }, version }), { code: 'INVALID_STATION' });
    await assert.rejects(instance.savedRoutePlan({ request: { ...request, via: ['KTH'] }, version }), { code: 'INVALID_STATION' });
});

test('journey details include the full dated service without changing the travelled stops', async () => {
    const repo = repository();
    repo.resolveServices = date => ({ services: [{ id: 'full-service', calls: [
        { station: 'ABW', departure: Date.parse('2026-09-08T05:30:00Z') },
        { station: 'KTH', departure: Date.parse('2026-09-08T06:00:00Z') },
        { station: 'VIC', arrival: Date.parse('2026-09-08T06:21:00Z') }
    ] }], diagnostics: {} });
    const instance = engine({ openDataset: async () => repo });
    const journey = instance.publicJourney(result(normalizeRequest(request)).journeys[0]);
    journey.id = 'detail-test';
    journey.legs[0].serviceId = 'full-service';
    journey.legs[0].originDate = '2026-09-08';
    instance.retainJourney(journey, version);
    const details = await instance.journey(journey.id);
    assert.deepEqual(details.journey.legs[0].callingPoints, journey.legs[0].callingPoints);
    assert.deepEqual(details.journey.legs[0].serviceCallingPoints.map(call => call.station.crs), ['ABW', 'KTH', 'VIC']);
    assert.equal(details.journey.legs[0].serviceCallingPoints[2].arrival, '2026-09-08T06:21:00.000Z');
    assert.equal(journey.legs[0].serviceCallingPoints, undefined);
    assert.equal(JSON.stringify(details).includes('/private'), false);
    await assert.rejects(instance.journey(journey.id, { aborted: true }), { code: 'SEARCH_CANCELLED' });
});

test('saved-route plans retain the full passenger pattern for tracking without another routing calculation', async () => {
    const repo = repository();
    let preparations = 0, routes = 0;
    repo.resolveServices = date => {
        preparations++;
        return { services: [{ id: `service-${date}`, calls: [
            { station: 'ABW', departure: Date.parse(`${date}T05:30:00Z`), canBoard: true },
            { station: 'PASS', departure: Date.parse(`${date}T05:45:00Z`), canBoard: false, canAlight: false },
            { station: 'KTH', departure: Date.parse(`${date}T06:00:00Z`), canBoard: true },
            { station: 'VIC', arrival: Date.parse(`${date}T06:21:00Z`), canAlight: true }
        ] }], diagnostics: { counts: {} } };
    };
    let preparedAtSearch;
    const instance = engine({ openDataset: async () => repo, findJourneys: query => {
        routes++;
        preparedAtSearch = preparations;
        const found = result(query);
        Object.assign(found.journeys[0].legs[0], { serviceId: 'service-2026-09-08', originDate: '2026-09-08' });
        return found;
    } });
    const plan = await instance.savedRoutePlan({ request, version });
    assert.equal(routes, 1);
    assert.equal(preparations, preparedAtSearch, 'Tracking metadata reuses the dates prepared for discovery');
    const leg = plan.result.journeys[0].legs[0];
    assert.deepEqual(leg.serviceCallingPoints.map(point => point.station.crs), ['ABW', 'KTH', 'VIC']);
    assert.equal(leg.callingPoints[0].station.crs, 'KTH', 'The travelled segment remains unchanged');
    assert.equal(leg.tracking, undefined, 'A timetable pattern is not a verified live provider reference');
});

test('cache keys distinguish exact times and page offsets; repeated result retains detail', async () => {
    let calls = 0;
    const instance = engine({ findJourneys(req, network, options) { calls++; return result(req); } });
    const normalized = normalizeRequest(request);
    const telemetry = [];
    const execution = { onTelemetry: value => telemetry.push(value) };
    const first = await instance.search({ request: normalized }, undefined, execution);
    const repeated = await instance.search({ request: normalized }, undefined, execution);
    assert.deepEqual(telemetry, [{ algorithm: 'original' }, { cacheStatus: 'miss', datasetVersion: version },
        { algorithm: 'original' }, { cacheStatus: 'hit', datasetVersion: version }]);
    assert.equal(first.cacheStatus, undefined, 'Internal cache observations must not change the public response');
    assert.equal(calls, 1);
    assert.equal(first.journeys[0].id, repeated.journeys[0].id);
    const next = decodeCursor(first.pagination.more);
    assert.equal(next.offset, 5);
    assert.equal(next.request.time, normalized.time);
    await instance.search(next);
    await instance.search({ request: { ...normalized, time: '2026-09-08T06:00:00.001Z' } });
    assert.equal(calls, 3);
});

test('station aliases normalize without changing existing station catalogue and dates are bounded', async () => {
    const instance = engine();
    const repo = repository();
    assert.equal(instance.checkQuery(repo, normalizeRequest({ ...request, origin: 'ABX' })).origin, 'ABW');
    assert.throws(() => instance.checkQuery(repo, normalizeRequest({ ...request, origin: 'ZZZ' })), { code: 'INVALID_STATION' });
    assert.throws(() => instance.checkQuery(repo, normalizeRequest({ ...request, time: '2028-01-01T07:00:00Z' })), { code: 'UNSUPPORTED_DATE' });
    const same = await instance.search({ request: normalizeRequest({ ...request, destination: 'KTH' }) });
    assert.deepEqual(same.journeys, []);
    assert.ok(same.warnings.some(warning => warning.includes('already')));
    repo.stations[0].aliases.push('ABX');
    assert.throws(() => instance.checkQuery(repo, normalizeRequest({ ...request, origin: 'ABX' })), { code: 'INVALID_STATION' });
    assert.equal(instance.checkQuery(repo, normalizeRequest(request)).origin, 'KTH');
});

test('coverage-edge windows report partial results and suppress out-of-range pagination', async () => {
    const instance = engine();
    const response = await instance.search({ request: normalizeRequest({ ...request, time: '2027-05-15T23:30:00+01:00' }) });
    assert.equal(response.search.searchTruncated, true);
    assert.equal(response.pagination.later, undefined);
    assert.ok(response.pagination.earlier);
    assert.ok(response.warnings.some(warning => warning.includes('outside the available timetable')));
});

test('monthly source age is not reset by recent import time; stale search and missing dataset differ', async () => {
    const stale = engine({ now: () => Date.parse('2026-11-01T12:00:00Z') });
    assert.equal((await stale.status()).available, false);
    await assert.rejects(stale.search({ request: normalizeRequest(request) }), { code: 'DATASET_STALE' });
    const missing = engine({ openDataset: async () => { throw new Error('/secret/path unavailable'); } });
    const status = await missing.status();
    assert.equal(status.available, false);
    assert.equal(JSON.stringify(status).includes('/secret'), false);
});

test('normal timetable cancellations do not imply unresolved records; unsafe variants do', async () => {
    for (const code of ['CANCELLED', 'CONFLICTING_VARIANTS']) {
        const repo = repository();
        repo.resolveServices = () => ({ services: [], diagnostics: { counts: { [code]: 4 }, examples: [] } });
        const instance = engine({ openDataset: async () => repo });
        const response = await instance.search({ request: normalizeRequest(request) });
        assert.equal(response.warnings.some(warning => warning.includes('resolved safely')), code !== 'CANCELLED');
    }
});

test('cached searches refresh freshness metadata and stop when the source ages out', async () => {
    let current = Date.parse('2026-09-29T23:59:59Z');
    const instance = engine({ now: () => current });
    const first = await instance.search({ request: normalizeRequest(request) });
    assert.equal(first.dataset.freshness, 'fresh');
    current += 2000;
    const second = await instance.search({ request: normalizeRequest(request) });
    assert.equal(second.dataset.freshness, 'stale');
    assert.ok(second.warnings.some(warning => warning.includes('older than expected')));
    current += 11 * 86400000;
    await assert.rejects(instance.search({ request: normalizeRequest(request) }), { code: 'DATASET_STALE' });
});

test('pagination bounds report truncation instead of silently hiding remaining results', async () => {
    const instance = engine({ findJourneys(req) { return { ...result(req), pagination: { nextOffset: 1005 } }; } });
    const response = await instance.search({ request: normalizeRequest(request), offset: 1000 });
    assert.equal(response.search.searchTruncated, true);
    assert.equal(response.pagination.more, undefined);
    assert.ok(response.warnings.some(warning => warning.includes('result limit')));
});

test('date preparation includes previous service date for overnight trains', async () => {
    const dates = [];
    const repo = repository();
    repo.resolveServices = date => { dates.push(date); return { services: [], diagnostics: {} }; };
    const instance = engine({ openDataset: async () => repo });
    await instance.search({ request: normalizeRequest({ ...request, time: '2026-09-08T00:05:00+01:00' }) });
    assert.ok(dates.includes('2026-09-07'));
    assert.ok(dates.includes('2026-09-09'));
});

test('activation keeps prior cursor pinned, then expires it once no longer retained', async t => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'planner-api-version-'));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    const other = 'b'.repeat(64);
    const pointer = path.join(directory, 'active.json');
    await fs.writeFile(pointer, JSON.stringify({ path: '/a', version }));
    const instance = new PlannerEngine({ ...config, datasetPath: null, dataDirectory: directory }, {
        openDataset: async name => repository(name === '/a' ? version : other), findJourneys: result, now
    });
    const first = await instance.search({ request: normalizeRequest(request) });
    await fs.writeFile(pointer, JSON.stringify({ path: '/b', version: other, previousPath: '/a', previousVersion: version }));
    assert.equal((await instance.search(decodeCursor(first.pagination.more))).dataset.version, version);
    await fs.writeFile(pointer, JSON.stringify({ path: '/b', version: other }));
    await assert.rejects(instance.search(decodeCursor(first.pagination.more)), { code: 'CURSOR_EXPIRED' });
});

test('adding planner routes preserves legacy route payloads and accepts requests without auth', async t => {
    const app = express();
    const legacy = { departures: [{ serviceID: 'unchanged', departure_time: { scheduled: '07:12' } }] };
    app.get('/api/v1/departures/from/KTH', (req, res) => res.json(legacy));
    app.get('/api/v2/stations', (req, res) => res.json([{ crs: 'KTH', name: 'Kent House' }]));
    app.get('/api/v2/config', (req, res) => res.json({ max_subscriptions_per_device: 3 }));
    const instance = engine();
    registerPlannerRoutes(app, { searchLog: noOpPlannerSearchLog, service: {
        status: () => instance.status(), stations: query => instance.stationList(query),
        search: body => instance.search({ request: normalizeRequest(body) }), journey: id => instance.journey(id)
    } });
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    const base = `http://127.0.0.1:${server.address().port}`;
    assert.deepEqual(await (await fetch(`${base}/api/v1/departures/from/KTH`)).json(), legacy);
    assert.deepEqual(await (await fetch(`${base}/api/v2/config`)).json(), { max_subscriptions_per_device: 3 });
    assert.deepEqual(await (await fetch(`${base}/api/v2/stations`)).json(), [{ crs: 'KTH', name: 'Kent House' }]);
    assert.equal((await fetch(`${base}/api/v2/journey-planner/status`)).status, 404);
    const response = await fetch(`${base}/api/v3/journey-planner/search`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(request)
    });
    assert.equal(response.status, 200);
    const payload = await response.json();
    assert.equal(payload.journeys.length, 1);
    const bad = await fetch(`${base}/api/v3/journey-planner/search`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
    });
    assert.equal(bad.status, 400);
    assert.equal((await bad.json()).error.code, 'INVALID_STATION');
});

test('worker failures and missing dataset leave the HTTP process usable', async () => {
    const service = new PlannerService({ ...config, datasetPath: '/does-not-exist', timeoutMs: 5000 });
    try {
        const status = await service.status();
        assert.equal(status.available, false);
        assert.equal(status.apiVersion, 3);
        await assert.rejects(service.search(request), { code: 'DATASET_UNAVAILABLE' });
        assert.equal((await service.status()).available, false);
    } finally { service.close(); }
});

test('direct-first saved boards are versioned separately and preserve existing v3 behavior', async t => {
    const app = express(), calls = [];
    const direct = { apiVersion: 4, boards: [{ id: 'home', status: 'ready', source: 'direct',
        direct: { departures: [{ serviceID: 'existing-live-id', departure_time: { scheduled: '14:57', estimated: '14:59' } }],
            dataStatus: 'live', lastSuccessfulUpdate: '2026-09-17T13:40:00Z' } }] };
    const planned = { apiVersion: 3, boards: [{ id: 'home', status: 'queued' }] };
    const service = registerPlannerRoutes(app, { service: { config }, searchLog: noOpPlannerSearchLog,
        savedRouteBoards: { get: async (body, caller) => { calls.push({ body, caller }); return direct; } },
        routeBoards: { get: async () => planned } });
    t.after(() => service.searchJobs.close());
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    const base = `http://127.0.0.1:${server.address().port}`;
    const options = { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Planner-Client': 'test-device' },
        body: JSON.stringify({ routes: [{ id: 'home', origin: 'KTH', destination: 'VIC' }] }) };
    const response = await fetch(`${base}/api/v4/journey-planner/route-boards`, options);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), direct);
    assert.equal(calls[0].caller.client, 'test-device');
    assert.deepEqual(await (await fetch(`${base}/api/v3/journey-planner/route-boards`, options)).json(), planned);
    assert.equal((await fetch(`${base}/api/v4/journey-planner/search`, options)).status, 404);
    assert.equal((await fetch(`${base}/api/v4/journey-planner/route-boards`, { method: 'POST', body: '{}' })).status, 415);
    assert.equal((await fetch(`${base}/api/v4/journey-planner/route-boards`, { ...options,
        body: JSON.stringify({ padding: 'x'.repeat(17000) }) })).status, 413);
    assert.equal(calls.length, 1, 'Invalid requests must never reach saved departure lookups');
});

test('bounded queue rejects overload and an aborted queued request does not execute', async t => {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'planner-worker-'));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    const filename = path.join(directory, 'slow-worker.mjs');
    await fs.writeFile(filename, "import {parentPort} from 'node:worker_threads'; parentPort.on('message',m=>setTimeout(()=>parentPort.postMessage({id:m.id,result:{ok:true}}),200));");
    const service = new PlannerService({ ...config, workerCount: 1, maxQueue: 2, timeoutMs: 2000 }, { workerURL: new URL(`file://${filename}`) });
    t.after(() => service.close());
    const first = service.status();
    const controller = new AbortController();
    const second = service.status({ signal: controller.signal });
    const cancelled = assert.rejects(second, { code: 'SEARCH_CANCELLED' });
    await assert.rejects(service.status(), { code: 'SEARCH_BUSY' });
    controller.abort();
    await cancelled;
    assert.deepEqual(await first, { ok: true });
    assert.deepEqual(await service.status(), { ok: true });
});
