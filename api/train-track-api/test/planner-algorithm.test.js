import test from 'node:test';
import assert from 'node:assert/strict';
import express from 'express';
import { CAPABILITIES, POLICY_VERSION, LIVE_POLICY_VERSION, RAPTOR_POLICY_VERSION,
    normalizeRequest, encodeCursor, decodeCursor } from '../lib/planner/contract.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { PlannerService, plannerConfig, normalizeSearchPayload } from '../lib/planner/service.js';
import { PlannerSearchJobs } from '../lib/planner/search-jobs.js';
import { findJourneys } from '../lib/planner/router.js';
import { registerPlannerRoutes } from '../lib/planner-routes.js';
import { noOpPlannerSearchLog } from '../lib/planner-search-log.js';

const version = 'a'.repeat(64), snapshot = '12345678-1234-1234-1234-123456789abc';
const body = { origin: 'AAA', destination: 'CCC', time: '2026-09-18T07:00:00Z', timeType: 'departAfter',
    allowedModes: ['rail'], maxChanges: 0, windowMinutes: 120, limit: 2 };
const cursorValue = value => Buffer.from(JSON.stringify(value)).toString('base64url');
const tick = () => new Promise(resolve => setImmediate(resolve));
const config = { ...plannerConfig({}), datasetPath: '/synthetic/algorithm', tubeTrackEnabled: false,
    prewarm: false, timeoutMs: 1000 };

function fixture(t, overrides = {}) {
    const stations = ['AAA', 'BBB', 'CCC'].map(crs => ({ crs, name: `Station ${crs}`, minimumChangeMinutes: 5 }));
    const services = Array.from({ length: 6 }, (_, index) => {
        const departure = Date.parse(body.time) + (index * 10 + 1) * 60000;
        return { id: `train-${index}`, uid: `train-${index}`, originDate: '2026-09-18', operator: 'OP', mode: 'rail',
            calls: [{ station: 'AAA', departure, arrival: null, canBoard: true, canAlight: false },
                { station: 'CCC', arrival: departure + 20 * 60000, departure: null, canBoard: false, canAlight: true }] };
    });
    const repo = { version, stations, rules: { tsi: [], links: [] },
        metadata: { source: { generationDate: '2026-09-18' }, importedAt: '2026-09-18T05:00:00Z', maxEventDayOffset: 1,
            coverage: { startDate: '2026-09-01', endDate: '2026-10-01', basis: 'Synthetic fixtures' }, limitations: [] },
        resolveServices: date => ({ services: date === '2026-09-18' ? services : [], diagnostics: { counts: {} } }),
        close() {} };
    let originalCalls = 0;
    const engine = new PlannerEngine(config, { openDataset: async () => repo, now: () => Date.parse('2026-09-18T06:00:00Z'),
        findJourneys: (request, network, options) => { originalCalls++; return findJourneys(request, network, options); },
        ...overrides });
    t.after(() => engine.close());
    return { engine, repo, originalCalls: () => originalCalls };
}

test('algorithm selection defaults to original without changing established normalized identity', () => {
    const original = normalizeRequest(body);
    assert.equal(original.algorithm, undefined);
    assert.deepEqual(normalizeRequest({ ...body, algorithm: 'original' }), original);
    assert.deepEqual(normalizeRequest({ ...body, algorithm: 'raptor', realtime: 'off', via: [] }),
        { ...original, algorithm: 'raptor' });
    assert.deepEqual(CAPABILITIES.algorithms, ['original', 'raptor']);
    for (const algorithm of ['', 'RAPTOR', null, 1, {}, ['raptor'], 'other']) {
        assert.throws(() => normalizeRequest({ ...body, algorithm }), { code: 'INVALID_REQUEST' });
    }
});

test('RAPTOR-only policy defaults interactive searches to RAPTOR and rejects original cursors and arrive-by', async t => {
    assert.equal(plannerConfig({ PLANNER_RAPTOR_ONLY: 'true' }).raptorOnly, true);
    assert.equal(normalizeSearchPayload(body, true).request.algorithm, 'raptor');
    assert.throws(() => normalizeSearchPayload({ ...body, algorithm: 'original' }, true), { code: 'UNSUPPORTED_REQUEST' });
    assert.throws(() => normalizeSearchPayload({ ...body, timeType: 'arriveBy' }, true), { code: 'UNSUPPORTED_REQUEST' });
    assert.throws(() => normalizeSearchPayload({ cursor: encodeCursor(normalizeRequest(body), version) }, true),
        { code: 'UNSUPPORTED_REQUEST' });
    assert.equal(normalizeSearchPayload({ cursor: encodeCursor(normalizeRequest({ ...body, algorithm: 'raptor' }), version) }, true)
        .request.algorithm, 'raptor');

    const calls = [];
    const service = { config: { ...config, raptorOnly: true },
        status: async () => ({ available: true, dataset: { version } }),
        call(method, payload, options) {
            options.onStart();
            calls.push({ method, payload });
            return Promise.resolve({ journeys: [], search: { algorithm: payload.request.algorithm } });
        } };
    const jobs = new PlannerSearchJobs(service, { searchLog: noOpPlannerSearchLog });
    t.after(() => jobs.close());
    await assert.rejects(jobs.submit({ ...body, algorithm: 'original' }), { code: 'UNSUPPORTED_REQUEST' });
    await jobs.submit(body);
    await tick();
    assert.equal(calls[0].payload.request.algorithm, 'raptor');
});

test('RAPTOR accepts live departure searches and normalizes ordered via stations', () => {
    for (const realtime of ['apply', 'ignore']) {
        assert.equal(normalizeRequest({ ...body, algorithm: 'raptor', realtime }).realtime, realtime);
    }
    assert.deepEqual(normalizeRequest({ ...body, algorithm: 'raptor', via: [' bbb '] }).via, ['BBB']);
    assert.throws(() => normalizeRequest({ ...body, algorithm: 'raptor', timeType: 'arriveBy' }), { code: 'UNSUPPORTED_REQUEST' });
    for (const via of ['BBB', null, ['BB'], Array(9).fill('BBB')]) {
        assert.throws(() => normalizeRequest({ ...body, algorithm: 'raptor', via }), { code: 'INVALID_STATION' });
    }
    for (const via of [['BBB', 'BBB'], ['AAA'], ['CCC']]) {
        assert.throws(() => normalizeRequest({ ...body, algorithm: 'raptor', via }), { code: 'INVALID_STATION' });
    }
    assert.throws(() => normalizeRequest({ ...body, algorithm: 'raptor', destination: 'AAA', via: ['BBB'] }),
        { code: 'INVALID_STATION' });
    assert.equal(normalizeRequest({ ...body, algorithm: 'original', timeType: 'arriveBy', realtime: 'apply' }).realtime, 'apply');
});

test('RAPTOR pagination cursors pin their algorithm and policy while legacy cursors remain compatible', () => {
    const original = normalizeRequest(body), raptor = normalizeRequest({ ...body, algorithm: 'raptor' });
    const raptorVia = normalizeRequest({ ...body, algorithm: 'raptor', via: ['BBB'] });
    assert.deepEqual(decodeCursor(encodeCursor(original, version, 2)), { version, request: original, offset: 2 });
    assert.deepEqual(decodeCursor(encodeCursor(raptor, version, 4)), { version, request: raptor, offset: 4 });
    assert.deepEqual(decodeCursor(encodeCursor(raptorVia, version, 6)), { version, request: raptorVia, offset: 6 });
    assert.notEqual(encodeCursor(raptorVia, version), encodeCursor(raptor, version));
    assert.equal(JSON.parse(Buffer.from(encodeCursor(raptor, version), 'base64url').toString()).policy, RAPTOR_POLICY_VERSION);
    for (const value of [
        { policy: POLICY_VERSION, version, request: raptor },
        { policy: LIVE_POLICY_VERSION, version, request: raptor },
        { policy: RAPTOR_POLICY_VERSION, version, request: original },
        { policy: RAPTOR_POLICY_VERSION, version, request: { ...raptor, algorithm: 'original' } },
        { policy: RAPTOR_POLICY_VERSION, version, request: raptor, liveSnapshotId: snapshot },
        { policy: RAPTOR_POLICY_VERSION, version, request: raptor, tubeSnapshotId: snapshot }
    ]) assert.throws(() => decodeCursor(cursorValue(value)), { code: 'INVALID_REQUEST' });
    assert.throws(() => encodeCursor(raptor, version, 0, snapshot), { code: 'INVALID_REQUEST' });
    assert.throws(() => encodeCursor(raptor, version, 0, undefined, snapshot), { code: 'INVALID_REQUEST' });
    assert.throws(() => decodeCursor(cursorValue({ policy: 'raptor-poc-v0', version, request: raptor })), { code: 'CURSOR_EXPIRED' });
    const live = normalizeRequest({ ...body, realtime: 'apply' });
    assert.equal(decodeCursor(encodeCursor(live, version, 0, snapshot)).liveSnapshotId, snapshot);
    const liveRaptor = normalizeRequest({ ...body, algorithm: 'raptor', realtime: 'apply' });
    assert.equal(decodeCursor(encodeCursor(liveRaptor, version, 0, snapshot)).liveSnapshotId, snapshot);
    assert.equal(decodeCursor(encodeCursor(original, version, 0, undefined, snapshot)).tubeSnapshotId, snapshot);
});

test('the actual selected router is reported and result caches are isolated by algorithm', async t => {
    const { engine, originalCalls } = fixture(t);
    const telemetry = [];
    const execution = { onTelemetry: value => telemetry.push(value) };
    const original = await engine.search({ request: normalizeRequest(body) }, undefined, execution);
    const raptor = await engine.search({ request: normalizeRequest({ ...body, algorithm: 'raptor' }) }, undefined, execution);
    const explicitOriginal = await engine.search({ request: normalizeRequest({ ...body, algorithm: 'original' }) }, undefined, execution);
    const repeatedRaptor = await engine.search({ request: normalizeRequest({ ...body, algorithm: 'raptor' }) }, undefined, execution);
    const viaRaptor = await engine.search({ request: normalizeRequest({ ...body, algorithm: 'raptor', via: ['BBB'] }) }, undefined, execution);
    const repeatedViaRaptor = await engine.search({ request: normalizeRequest({ ...body, algorithm: 'raptor', via: ['BBB'] }) }, undefined, execution);
    assert.equal(original.search.algorithm, 'original');
    assert.equal(raptor.search.algorithm, 'raptor');
    assert.deepEqual(explicitOriginal, original);
    assert.deepEqual(repeatedRaptor, raptor);
    assert.deepEqual(repeatedViaRaptor, viaRaptor);
    assert.deepEqual(viaRaptor.search.via, ['BBB']);
    assert.deepEqual(viaRaptor.journeys, []);
    assert.equal(originalCalls(), 1, 'Selecting RAPTOR must run its router rather than silently call the original');
    assert.equal(engine.searches.size, 3);
    assert.deepEqual(telemetry.filter(value => value.cacheStatus).map(value => value.cacheStatus), ['miss', 'miss', 'hit', 'hit', 'miss', 'hit']);
    assert.ok(telemetry.some(value => value.algorithm === 'raptor'));
    assert.ok(telemetry.some(value => value.algorithm === 'original'));
    assert.equal(raptor.search.window.from, normalizeRequest(body).time);
    assert.equal(raptor.search.window.to, new Date(Date.parse(body.time) + body.windowMinutes * 60000).toISOString());
    assert.equal(raptor.search.searchTruncated, false);
    assert.ok(raptor.warnings.includes('Detailed TfL routing is not included.'));
});

test('RAPTOR more, earlier and later pages preserve the algorithm and complete journey frontier', async t => {
    const { engine } = fixture(t);
    const collect = async algorithm => {
        let page = await engine.search({ request: normalizeRequest({ ...body, algorithm }) });
        const first = page, journeys = [...page.journeys];
        while (page.pagination.more) {
            const next = decodeCursor(page.pagination.more);
            assert.equal(next.request.algorithm, algorithm === 'raptor' ? 'raptor' : undefined);
            page = await engine.search(next);
            assert.equal(page.search.algorithm, algorithm);
            journeys.push(...page.journeys);
        }
        return { first, journeys };
    };
    const original = await collect('original'), raptor = await collect('raptor');
    const frontier = value => value.journeys.map(journey => `${journey.departure}|${journey.arrival}|${journey.changes}`).sort();
    assert.equal(raptor.journeys.length, 6);
    assert.deepEqual(frontier(raptor), frontier(original));
    assert.equal(new Set(raptor.journeys.map(journey => journey.id)).size, 6);
    for (const direction of ['earlier', 'later']) {
        const decoded = decodeCursor(raptor.first.pagination[direction]);
        assert.equal(decoded.request.algorithm, 'raptor');
        assert.equal(decoded.version, version);
    }
    assert.equal((await engine.journey(raptor.journeys[0].id)).journey.legs[0].serviceCallingPoints.length, 2);
});

test('RAPTOR supports live rail overlays without constructing a TfL resolver', async t => {
    const { engine } = fixture(t, { liveProvider: { collect: () => assert.fail('Live provider must not run') },
        tubeProvider: { journey: () => assert.fail('TfL provider must not run') } });
    engine.tubeResolver = async () => assert.fail('RAPTOR must not construct a TfL resolver');
    const request = normalizeRequest({ ...body, algorithm: 'raptor' });
    const response = await engine.search({ request });
    assert.equal(response.live, undefined);
    assert.equal(response.search.algorithm, 'raptor');
    await assert.rejects(engine.search({ request: { ...request, timeType: 'arriveBy' } }), { code: 'UNSUPPORTED_REQUEST' });
    const viaResponse = await engine.search({ request: { ...request, via: ['BBB'] } });
    assert.deepEqual(viaResponse.search.via, ['BBB']);
    assert.deepEqual(viaResponse.journeys, []);
    await assert.rejects(engine.search({ request, liveSnapshotId: snapshot }), { code: 'UNSUPPORTED_REQUEST' });
    await assert.rejects(engine.search({ request, tubeSnapshotId: snapshot }), { code: 'UNSUPPORTED_REQUEST' });
    await assert.rejects(engine.search({ request }, undefined, { excludeDirect: true }), { code: 'UNSUPPORTED_REQUEST' });
    await assert.rejects(engine.search({ request }, { aborted: true }), { code: 'SEARCH_CANCELLED' });

    const liveFixture = fixture(t, { liveProvider: {
        fetchBoards: async () => ({ boards: [], errors: [] }),
        fetchDetails: async () => ({ details: [], errors: [] })
    }, createLiveBudget: limit => ({ limit, used: 0 }) });
    liveFixture.engine.tubeResolver = async () => assert.fail('RAPTOR must not construct a TfL resolver');
    const liveRequest = normalizeRequest({ ...body, algorithm: 'raptor', realtime: 'apply' });
    const liveResponse = await liveFixture.engine.search({ request: liveRequest });
    assert.equal(liveResponse.search.algorithm, 'raptor');
    assert.equal(liveResponse.search.realtime, 'apply');
    assert.equal(liveResponse.live.mode, 'apply');
    assert.equal(liveResponse.live.status, 'unavailable');
});

test('RAPTOR enforces ordered via stations across vehicle calls and fixed transfers', async t => {
    const base = Date.parse(body.time);
    const at = minutes => base + minutes * 60000;
    const service = (id, calls) => ({ id, uid: id, originDate: '2026-09-18', operator: 'OP', mode: 'rail',
        calls: calls.map(([station, arrival, departure]) => ({ station,
            arrival: arrival == null ? null : at(arrival), departure: departure == null ? null : at(departure),
            canBoard: departure != null, canAlight: arrival != null })) });
    const repository = (services, links = []) => ({ version,
        stations: ['AAA', 'BBB', 'CCC', 'DDD'].map(crs => ({ crs, name: `Station ${crs}`, minimumChangeMinutes: 0 })),
        rules: { tsi: [], links },
        metadata: { source: { generationDate: '2026-09-18' }, importedAt: '2026-09-18T05:00:00Z', maxEventDayOffset: 1,
            coverage: { startDate: '2026-09-01', endDate: '2026-10-01', basis: 'Synthetic fixtures' }, limitations: [] },
        resolveServices: date => ({ services: date === '2026-09-18' ? services : [], diagnostics: { counts: {} } }), close() {} });

    const through = service('through-vias', [['AAA', null, 2], ['BBB', 5, 6], ['DDD', 9, 10], ['CCC', 20, null]]);
    const skipped = service('skips-vias', [['AAA', null, 1], ['CCC', 12, null]]);
    const vehicleFixture = fixture(t, { openDataset: async () => repository([skipped, through]) });
    const orderedRequest = normalizeRequest({ ...body, algorithm: 'raptor', allowedModes: ['rail'], via: ['BBB', 'DDD'] });
    const ordered = await vehicleFixture.engine.search({ request: orderedRequest });
    assert.equal(ordered.journeys.length, 1);
    assert.equal(ordered.journeys[0].legs[0].serviceId, 'through-vias');
    assert.deepEqual(ordered.search.via, ['BBB', 'DDD']);
    assert.deepEqual(decodeCursor(ordered.pagination.later).request.via, ['BBB', 'DDD']);
    const reversed = await vehicleFixture.engine.search({ request: normalizeRequest({ ...body, algorithm: 'raptor',
        allowedModes: ['rail'], via: ['DDD', 'BBB'] }) });
    assert.deepEqual(reversed.journeys, []);
    const valid = normalizeRequest({ ...body, algorithm: 'raptor' });
    for (const request of [{ ...valid, via: ['BBB', 'BBB'] }, { ...valid, via: ['AAA'] },
        { ...valid, via: ['CCC'] }, { ...valid, destination: 'AAA', via: ['BBB'] }]) {
        await assert.rejects(vehicleFixture.engine.search({ request }), { code: 'INVALID_STATION' });
    }

    const onward = service('after-link', [['BBB', null, 10], ['CCC', 20, null]]);
    const walk = { id: 'ALF:via', origin: 'AAA', destination: 'BBB', mode: 'walk', minutes: 5,
        startTime: '0000', endTime: '2359', days: '1111111', priority: 1 };
    const transferFixture = fixture(t, { openDataset: async () => repository([skipped, onward], [walk]) });
    const linked = await transferFixture.engine.search({ request: normalizeRequest({ ...body, algorithm: 'raptor',
        allowedModes: ['rail', 'walk'], via: ['BBB'] }) });
    assert.equal(linked.journeys.length, 1);
    assert.deepEqual(linked.journeys[0].legs.map(leg => [leg.kind, leg.from.crs, leg.to.crs]),
        [['transfer', 'AAA', 'BBB'], ['vehicle', 'BBB', 'CCC']]);
});

test('RAPTOR index compilation obeys the shared work budget and a failed compile never falls back or poisons the cache', async t => {
    const { engine, originalCalls } = fixture(t);
    const request = normalizeRequest({ ...body, algorithm: 'raptor' });
    await assert.rejects(engine.search({ request }, undefined, { maxOperations: 1 }), { code: 'SEARCH_TIMEOUT' });
    assert.equal(originalCalls(), 0);
    assert.equal(engine.raptorIndex?.index, undefined);
    assert.equal(engine.searches.size, 0);
    const result = await engine.search({ request });
    assert.equal(result.search.algorithm, 'raptor');
    assert.equal(result.journeys.length, body.limit);
    const index = engine.raptorIndex;
    await assert.rejects(engine.search({ request: { ...request, time: '2026-09-18T07:00:01.000Z' } },
        undefined, { maxOperations: 1 }), { code: 'SEARCH_TIMEOUT' });
    assert.equal(engine.raptorIndex, index, 'A failed query may retain the successfully compiled immutable graph');
    assert.equal(originalCalls(), 0);
});

test('RAPTOR indexing is lazy, reuses an immutable dated graph and releases it when the date range changes', async t => {
    const { engine } = fixture(t);
    await engine.search({ request: normalizeRequest(body) });
    assert.equal(engine.raptorIndex?.index, undefined);
    await engine.search({ request: normalizeRequest({ ...body, algorithm: 'raptor' }) });
    const first = engine.raptorIndex;
    assert.ok(first.index);
    await engine.search({ request: normalizeRequest({ ...body, algorithm: 'raptor', time: '2026-09-18T07:00:01Z' }) });
    assert.equal(engine.raptorIndex, first);
    await engine.search({ request: normalizeRequest({ ...body, algorithm: 'raptor', time: '2026-09-19T07:00:00Z' }) });
    assert.notEqual(engine.raptorIndex.network, first.network);
    assert.equal(engine.networks.size, 1);
});

test('time-locked saved-route work can include direct RAPTOR journeys', async t => {
    const { engine, originalCalls } = fixture(t);
    const profile = await engine.savedRoutePlan({
        request: { ...body, algorithm: 'raptor', via: [] },
        version,
        includeDirect: true
    });
    assert.equal(profile.result.search.algorithm, 'raptor');
    assert.ok(profile.result.journeys.length > 0);
    assert.equal(originalCalls(), 0);
});

test('queued work coalesces default and explicit original but never coalesces RAPTOR, and cancellation stays independent', async t => {
    const calls = [];
    const service = { config,
        status: async () => ({ available: true, dataset: { version } }),
        call(method, payload, options) {
            options.onStart();
            return new Promise(resolve => calls.push({ payload, options, resolve }));
        } };
    const jobs = new PlannerSearchJobs(service, { searchLog: noOpPlannerSearchLog });
    t.after(() => jobs.close());
    const first = await jobs.submit(body, { client: 'original-one', idempotencyKey: 'algorithm-test' });
    const shared = await jobs.submit({ ...body, algorithm: 'original' }, { client: 'original-two' });
    const raptor = await jobs.submit({ ...body, algorithm: 'raptor' }, { client: 'raptor-one' });
    await tick();
    assert.equal(jobs.work.size, 2);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].payload.request.algorithm, undefined);
    await assert.rejects(jobs.submit({ ...body, algorithm: 'raptor' },
        { client: 'original-one', idempotencyKey: 'algorithm-test' }), { status: 409 });
    jobs.cancel(first.id);
    assert.equal(calls[0].options.signal.aborted, false);
    calls[0].resolve({ journeys: [], search: { algorithm: 'original' } });
    await tick();
    assert.equal(jobs.get(shared.id).status, 'completed');
    assert.equal(calls.length, 2);
    assert.equal(calls[1].payload.request.algorithm, 'raptor');
    calls[1].resolve({ journeys: [], search: { algorithm: 'raptor' } });
    await tick();
    assert.equal(jobs.get(raptor.id).result.search.algorithm, 'raptor');
});

test('service and HTTP searches retain RAPTOR through queued polling and reject unsupported requests before routing', async t => {
    const { engine, originalCalls } = fixture(t);
    const service = new PlannerService(config);
    service.status = () => engine.status();
    service.call = async (method, payload, options = {}) => {
        options.onStart?.();
        if (method === 'search') return engine.search(payload, options.signal, { ...options.execution, onTelemetry: options.onTelemetry });
        if (method === 'status') return engine.status();
        assert.fail(`Unexpected worker method: ${method}`);
    };
    const app = express();
    registerPlannerRoutes(app, { service, searchLog: noOpPlannerSearchLog });
    t.after(() => service.close());
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => new Promise(resolve => server.close(resolve)));
    const url = `http://127.0.0.1:${server.address().port}/api/v3/journey-planner`;
    const post = (route, request) => fetch(`${url}${route}`, { method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Planner-Client': 'algorithm-testing' }, body: JSON.stringify(request) });
    const response = await post('/search', { ...body, algorithm: 'raptor' });
    assert.equal(response.status, 200);
    const first = await response.json();
    assert.equal(first.search.algorithm, 'raptor');
    const more = await post('/search', { cursor: first.pagination.more });
    assert.equal((await more.json()).search.algorithm, 'raptor');
    const submit = await post('/search-jobs', { ...body, algorithm: 'raptor' });
    assert.equal(submit.status, 202);
    const job = await submit.json();
    await tick();
    const poll = await fetch(`${url}/search-jobs/${job.id}`);
    const completed = await poll.json();
    assert.equal(completed.status, 'completed');
    assert.equal(completed.result.search.algorithm, 'raptor');
    assert.equal(completed.result.live, undefined);
    for (const route of ['/search', '/search-jobs']) {
        const rejected = await post(route, { ...body, algorithm: 'raptor', timeType: 'arriveBy' });
        assert.equal(rejected.status, 400);
        assert.equal((await rejected.json()).error.code, 'UNSUPPORTED_REQUEST');
    }
    assert.equal(originalCalls(), 0, 'HTTP and queued RAPTOR searches never silently fall back to the original');
});
