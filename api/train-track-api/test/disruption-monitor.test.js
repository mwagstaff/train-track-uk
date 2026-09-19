import assert from 'node:assert/strict';
import test from 'node:test';
import { DisruptionMonitor } from '../lib/disruptions/manager.js';
import { disruptionConfig, hash, profileJob } from '../lib/disruptions/model.js';
import { ENGINEERING_RELEVANCE_VERSION } from '../lib/disruptions/relevance.js';

const copy = value => value == null ? value : structuredClone(value);
const NOW = Date.parse('2026-09-19T12:00:00Z');
const TRAVEL = '2026-09-21';
let sequence = 0;

// Model the durable store's compare-and-set and lease behavior. Keeping this
// object across manager instances exercises restarts without a live Mongo DB.
class MemoryStore {
    constructor() { this.saved = new Map(); this.work = new Map(); this.deliveries = new Map(); this.sequence = 0; this.deferred = []; }
    async getDevice(id) { return copy(this.saved.get(id)); }
    async saveDevice(input, now) {
        await this.beforeSaveDevice?.(input);
        const previous = this.saved.get(input.deviceId);
        const pushToken = input.pushToken === undefined ? previous?.pushToken ?? null : input.pushToken;
        const useSandbox = input.useSandbox ?? previous?.useSandbox ?? false;
        const value = { ...previous, ...copy(input), _id: input.deviceId, pushToken, useSandbox,
            revision: hash([input.monitors, pushToken, useSandbox]), updatedAt: new Date(now) };
        if (hash(previous?.monitors) === hash(input.monitors) && previous?.stateRevision === previous?.revision) value.stateRevision = value.revision;
        this.saved.set(input.deviceId, value);
        return copy(value);
    }
    async *devices() {
        for (const device of [...this.saved.values()]) if (device.monitors.some(row => row.enabled)) yield copy(device);
    }
    async saveState(device, state) {
        await this.beforeSaveState?.(device, state);
        const current = this.saved.get(device.deviceId);
        if (!current || current.revision !== device.revision) return false;
        current.state = copy(state); current.stateRevision = device.revision;
        return true;
    }
    async enqueue(jobs, now) {
        for (const job of jobs) {
            const row = this.work.get(job._id) ?? copy(job);
            row.demandedUntil = new Date(now + 3600000);
            row.priority = job.priority;
            this.work.set(job._id, row);
        }
    }
    async profiles(ids) { return [...new Set(ids)].map(id => copy(this.work.get(id))).filter(Boolean); }
    async historicalProfiles(stations, chunks, currentVersion) {
        const wanted = new Set(chunks.map(chunk => `${chunk.date}:${chunk.startMinutes}:${chunk.endMinutes}`));
        const results = new Map();
        const rows = [...this.work.values()].filter(row => row.routeKey === hash(stations)
            && row.datasetVersion !== currentVersion && row.status === 'complete' && row.profile?.complete)
            .sort((a, b) => +b.checkedAt - +a.checkedAt);
        for (const row of rows) {
            const key = `${row.date}:${row.startMinutes}:${row.endMinutes}`;
            if (wanted.has(key) && !results.has(key)) results.set(key, copy(row));
        }
        return [...results.values()];
    }
    async claim(version, now) {
        const candidates = [...this.work.values()].filter(row => row.datasetVersion === version && +row.demandedUntil > now
            && +row.retryAt <= now && (row.status === 'pending' || row.status === 'running' && +row.leaseUntil < now));
        candidates.sort((a, b) => a.priority - b.priority || a.date.localeCompare(b.date) || a.startMinutes - b.startMinutes || +a.createdAt - +b.createdAt);
        const row = candidates[0];
        if (!row) return null;
        Object.assign(row, { status: 'running', lease: `work-${++this.sequence}`, leaseUntil: new Date(now + 120000) });
        return copy(row);
    }
    async complete(job, profile, now) {
        const row = this.work.get(job._id);
        if (row?.lease !== job.lease) return;
        Object.assign(row, { status: 'complete', profile: copy(profile), checkedAt: new Date(now) });
        delete row.lease; delete row.leaseUntil;
    }
    async defer(job, now, reason) {
        const row = this.work.get(job._id);
        if (row?.lease !== job.lease) return;
        Object.assign(row, { status: 'pending', retryAt: new Date(now + (reason === 'deferred' ? 30000 : 300000)), reason,
            attempts: (row.attempts ?? 0) + 1 });
        if (reason !== 'deferred') row.failures = (row.failures ?? 0) + 1;
        delete row.lease; delete row.leaseUntil;
        this.deferred.push({ id: job._id, reason });
    }
    async claimDelivery(device, advisory, fingerprint, now) {
        const id = hash([device.deviceId, advisory.monitorId, advisory.id]);
        let row = this.deliveries.get(id);
        if (!row) {
            row = { _id: id, deviceId: device.deviceId, sentFingerprint: null, retryAt: new Date(0) };
            this.deliveries.set(id, row);
        }
        if (row.sentFingerprint === fingerprint || +row.retryAt > now || row.leaseUntil && +row.leaseUntil >= now) return null;
        Object.assign(row, { lease: `delivery-${++this.sequence}`, leaseUntil: new Date(now + 120000) });
        await this.afterClaimDelivery?.(device, advisory);
        return copy(row);
    }
    async finishDelivery(receipt, fingerprint, sent, now) {
        const row = this.deliveries.get(receipt._id);
        if (row?.lease !== receipt.lease) return;
        if (sent) Object.assign(row, { sentFingerprint: fingerprint, sentAt: new Date(now), retryAt: new Date(now) });
        else row.retryAt = new Date(now + 300000);
        delete row.lease; delete row.leaseUntil;
    }
    async clearPushToken(device, now) {
        const current = this.saved.get(device.deviceId);
        if (current?.revision !== device.revision || current.pushToken !== device.pushToken) return;
        const revision = hash([device.monitors, null, device.useSandbox ?? false]);
        Object.assign(current, { pushToken: null, revision, updatedAt: new Date(now),
            ...(device.stateRevision === device.revision ? { stateRevision: revision } : {}) });
    }
    removeDevice(id) {
        this.saved.delete(id);
        for (const [key, receipt] of this.deliveries) if (receipt.deviceId === id) this.deliveries.delete(key);
    }
}

function fixture(options = {}) {
    let now = options.now ?? NOW;
    const id = `disruption-test-${++sequence}`;
    const store = options.store ?? new MemoryStore();
    const calls = [], pushes = [], observations = [];
    const state = {
        status: { available: true, dataset: { version: 'v1', sourceGenerationDate: '2026-09-18' } },
        ingestion: { schemaVersion: 1, enabled: true, inProgress: false, pendingGap: null, lastResult: 'unchanged',
            lastSuccessfulCheckAt: new Date(now).toISOString(), active: { version: 'v1',
                metadata: { version: 'v1', source: { generationDate: '2026-09-18' } }, validation: { valid: true } } },
        notices: { available: true, checkedAt: new Date(now).toISOString(), notices: [], reason: null },
        holidayMode: false,
        ordinary: () => true,
        ...(options.state ?? {})
    };
    const planner = { config: {}, status: async () => copy(state.status), disruptionProfile: async (request, execution) => {
        calls.push(copy(request));
        if (options.plan) return options.plan(request, execution);
        return profile(request.date, { ...request, datasetVersion: state.status.dataset.version });
    } };
    const config = { ...disruptionConfig({}), mode: options.mode ?? 'active', refreshMs: 300000 };
    const dependencies = { planner, store, config, now: () => now,
        notices: { getSnapshot: async () => copy(state.notices) },
        holidays: { refresh: async () => {}, ordinary: date => state.ordinary(date) },
        readIngestion: options.readIngestion ?? (async () => copy(state.ingestion)),
        isHolidayMode: () => state.holidayMode,
        pushClient: { isConfigured: () => true, sendNotification: async (...args) => {
            pushes.push(copy(args)); await options.onPush?.(...args); return options.pushResult ?? { status: 200 };
        } },
        observe: value => observations.push(copy(value)), logger: { warn() {} } };
    const monitor = new DisruptionMonitor(dependencies);
    return { id, store, state, planner, config, dependencies, monitor, calls, pushes, observations,
        now: () => now, advance: milliseconds => { now += milliseconds; state.ingestion.lastSuccessfulCheckAt = new Date(now).toISOString(); } };
}

function registration(id, overrides = {}) {
    return { device_id: id, push_token: 'a'.repeat(64), monitors: [{ id: 'commute', name: 'My commute', stations: ['KTH', 'VIC'],
        days: [1], window_start: '07:00', window_end: '08:00', enabled: true, push_enabled: false, ...overrides }] };
}
function profile(date = TRAVEL, overrides = {}) {
    return { complete: true, date, startMinutes: 420, endMinutes: 480, datasetVersion: 'v1', sourceGenerationDate: '2026-09-18',
        directTrains: 4, replacementBus: false, railOnlyAvailable: true, servicesAvailable: true,
        minChanges: 0, durationMinutes: 30, stationCRS: ['KTH', 'VIC'], diagnosticCodes: [], ...overrides };
}
function seed(f, date = TRAVEL, overrides = {}) {
    const value = profile(date, overrides);
    const job = profileJob(['KTH', 'VIC'], { date, startMinutes: value.startMinutes, endMinutes: value.endMinutes }, value.datasetVersion, f.now());
    f.store.work.set(job._id, { ...job, status: 'complete', profile: value, checkedAt: new Date(f.now()) });
    return job._id;
}
function seedComparison(f, current = {}) {
    seed(f, TRAVEL, current); seed(f, '2026-09-14'); seed(f, '2026-09-07');
}
async function reconcile(f) {
    f.monitor.refreshAt = 0;
    await f.monitor.refreshSources();
    await f.monitor.reconcileDevice(await f.store.getDevice(f.id));
    return f.monitor.get(f.id);
}
function official(overrides = {}) {
    return { id: 'official-1', title: 'Planned engineering work near Kent House', body: 'See National Rail for details.',
        kind: 'engineering', planned: true, stationCRS: ['KTH', 'VIC'], affectedStationClauses: [['KTH', 'VIC']],
        sourceURL: 'https://www.nationalrail.co.uk/engineering/example/',
        startAt: '2026-09-21T00:00:00Z', endAt: '2026-09-21T23:00:00Z', ...overrides };
}
function advisory(overrides = {}) {
    return { id: 'advisory-1', monitorId: 'commute', kind: 'replacement_bus', title: 'Replacement bus in your journey',
        body: 'Allow extra time.', startAt: '2026-09-21T06:00:00Z', endAt: '2026-09-21T07:00:00Z',
        confidence: 'timetable', extraMinutes: null, ...overrides };
}

test('registering saved monitors persists preferences without routing or sending a push', async () => {
    const f = fixture();
    const result = await f.monitor.synchronize(registration(f.id));
    assert.equal(result.monitors[0].status, 'pending');
    assert.equal(f.calls.length, 0); assert.equal(f.pushes.length, 0);
    assert.equal((await f.store.getDevice(f.id)).monitors[0].push_enabled, false);
});

test('different installations share durable jobs and a restarted manager reuses completed work', async () => {
    const f = fixture();
    await f.monitor.synchronize(registration(f.id));
    await f.monitor.synchronize(registration(`${f.id}-second`));
    for (let i = 0; i < 4; i++) await f.monitor.tick();
    assert.equal(f.calls.length, 3);
    assert.equal(f.store.work.size, 3);
    assert.deepEqual(new Set(f.calls.map(value => value.date)), new Set([TRAVEL, '2026-09-14', '2026-09-07']));
    f.monitor.stop();
    const restarted = new DisruptionMonitor(f.dependencies);
    await restarted.tick();
    assert.equal(f.calls.length, 3);
    assert.equal((await restarted.get(f.id)).monitors[0].status, 'checked');
});

test('a restarted manager reclaims a crashed calculation after its durable lease expires', async () => {
    const f = fixture(); await f.monitor.synchronize(registration(f.id));
    const job = profileJob(['KTH', 'VIC'], { date: TRAVEL, startMinutes: 420, endMinutes: 480 }, 'v1', f.now());
    await f.store.enqueue([job], f.now());
    const abandoned = await f.store.claim('v1', f.now());
    assert.equal(abandoned.status, 'running');
    f.advance(120001);
    await new DisruptionMonitor(f.dependencies).tick();
    assert.equal(f.calls[0].date, TRAVEL);
    assert.equal(f.store.work.get(job._id).status, 'complete');
});

test('two trusted historical weekdays from another snapshot establish a baseline without new routing jobs', async () => {
    const f = fixture(); await f.monitor.synchronize(registration(f.id));
    f.state.status.dataset.version = 'v2'; f.state.ingestion.active.version = 'v2'; f.state.ingestion.active.metadata.version = 'v2';
    seed(f, TRAVEL, { datasetVersion: 'v2', directTrains: 0, minChanges: 1 });
    seed(f, '2026-09-14'); seed(f, '2026-09-07');
    const response = await reconcile(f);
    assert.equal(response.monitors[0].status, 'checked');
    assert.ok(response.advisories.some(value => value.kind === 'direct_unavailable'));
    assert.equal(f.calls.length, 0);
    assert.equal(f.store.work.size, 3);
    assert.equal([...f.store.work.values()].filter(row => row.datasetVersion === 'v2').length, 1);
    assert.equal([...f.store.work.values()].every(row => row.status === 'complete'), true);
});

test('stale publications and update gaps leave checks unavailable without planner work', async () => {
    for (const change of [f => { f.state.status.dataset.sourceGenerationDate = '2026-08-25'; },
        f => { f.state.ingestion.pendingGap = { missingCount: 22 }; }]) {
        const f = fixture(); change(f);
        await f.monitor.synchronize(registration(f.id));
        await f.monitor.tick();
        assert.equal(f.calls.length, 0); assert.equal(f.store.work.size, 0);
        assert.equal((await f.monitor.get(f.id)).monitors[0].status, 'unavailable');
    }
});

test('an import starting between source refresh and admission prevents CPU work', async () => {
    let reads = 0;
    const f = fixture({ readIngestion: async () => ({ ...copy(f.state.ingestion), inProgress: ++reads > 1 }) });
    await f.monitor.synchronize(registration(f.id));
    await f.monitor.tick();
    assert.equal(f.calls.length, 0);
    assert.ok(f.store.work.size > 0);
    assert.equal([...f.store.work.values()].every(row => row.status === 'pending'), true);
});

test('foreground preemption defers a leased job instead of recording an empty journey result', async () => {
    const f = fixture({ plan: async () => { throw Object.assign(new Error('foreground work'), { code: 'SEARCH_DEFERRED' }); } });
    await f.monitor.synchronize(registration(f.id));
    await f.monitor.tick();
    assert.equal(f.store.deferred[0].reason, 'deferred');
    const row = f.store.work.get(f.store.deferred[0].id);
    assert.equal(row.status, 'pending'); assert.equal(row.profile, undefined);
    assert.equal(+row.retryAt, f.now() + 30000);
    assert.equal(row.failures ?? 0, 0, 'foreground preemption spends no upstream failure budget');
    assert.deepEqual((await f.monitor.get(f.id)).advisories, []);
});

test('persistent provider failures finish as unknown after three retries rather than looping forever', async () => {
    const f = fixture({ plan: async () => { throw new Error('provider unavailable'); } });
    f.state.ordinary = () => false;
    await f.monitor.synchronize(registration(f.id));
    for (let attempt = 0; attempt < 4; attempt++) {
        if (attempt) f.advance(300000);
        await f.monitor.tick();
    }
    assert.equal(f.calls.length, 4);
    assert.equal(f.store.deferred.length, 3);
    const row = [...f.store.work.values()][0];
    assert.equal(row.failures, 3);
    assert.equal(row.status, 'complete');
    assert.equal(row.profile.complete, false);
    f.advance(300000); await f.monitor.tick();
    assert.equal(f.calls.length, 4);
    assert.equal((await f.monitor.get(f.id)).monitors[0].status, 'unavailable');
});

test('no maintenance capacity leaves durable work untouched until a later tick', async () => {
    const f = fixture(); await f.monitor.synchronize(registration(f.id));
    f.planner.maintenanceAvailable = () => false;
    await f.monitor.tick();
    assert.equal(f.calls.length, 0);
    assert.equal([...f.store.work.values()].some(row => row.status === 'running'), false);
});

test('a calculation finishing against another timetable version is retried', async () => {
    const f = fixture({ plan: async request => profile(request.date, { ...request, datasetVersion: 'v2' }) });
    await f.monitor.synchronize(registration(f.id)); await f.monitor.tick();
    assert.equal(f.store.deferred[0].reason, 'dataset_changed');
    assert.equal(f.monitor.refreshAt, 0);
});

test('deleting a device during state publication cannot recreate its data or send a push', async () => {
    const f = fixture();
    await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
    seedComparison(f, { replacementBus: true, railOnlyAvailable: false });
    let deletion;
    f.store.beforeSaveState = async () => {
        // The external deletion request marks the installation immediately,
        // waits for in-flight fanout, then removes its durable records.
        deletion = f.monitor.purgeDevice(f.id).then(() => f.store.removeDevice(f.id));
    };
    await f.monitor.tick();
    await deletion;
    assert.equal(await f.store.getDevice(f.id), undefined);
    assert.equal(f.pushes.length, 0);
    assert.equal(f.store.deliveries.size, 0);
});

test('deletion waits for a racing registration before its durable records are removed', async () => {
    const f = fixture();
    let release, entered;
    const blocked = new Promise(resolve => { release = resolve; });
    const began = new Promise(resolve => { entered = resolve; });
    f.store.beforeSaveDevice = async () => { entered(); await blocked; };
    const saving = f.monitor.synchronize(registration(f.id));
    await began;
    const deletion = f.monitor.purgeDevice(f.id).then(() => f.store.removeDevice(f.id));
    const rejected = assert.rejects(saving, { code: 'DEVICE_DELETED' });
    release();
    await Promise.all([deletion, rejected]);
    assert.equal(await f.store.getDevice(f.id), undefined);
    await assert.rejects(f.monitor.synchronize(registration(f.id)), { code: 'DEVICE_DELETED' });
});

test('deletion or push opt-out after receipt claim is rechecked before transport', async () => {
    for (const action of ['delete', 'opt-out']) {
        const f = fixture();
        await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
        const device = await f.store.getDevice(f.id);
        f.store.afterClaimDelivery = async () => {
            if (action === 'delete') { await f.monitor.purgeDevice(f.id); f.store.removeDevice(f.id); }
            else await f.monitor.synchronize(registration(f.id, { push_enabled: false }));
        };
        await f.monitor.deliver(device, [advisory()]);
        assert.equal(f.pushes.length, 0, action);
        if (action === 'delete') assert.equal(f.store.deliveries.size, 0);
    }
});

test('quiet hours, holiday mode, disabled routes, opt-out and shadow mode suppress push', async () => {
    for (const option of ['quiet', 'holiday', 'disabled', 'opt-out', 'shadow']) {
        const f = fixture({ now: option === 'quiet' ? Date.parse('2026-09-19T22:00:00Z') : NOW, mode: option === 'shadow' ? 'shadow' : 'active' });
        await f.monitor.synchronize(registration(f.id, { push_enabled: option !== 'opt-out', enabled: option !== 'disabled' }));
        f.state.holidayMode = option === 'holiday';
        await f.monitor.deliver(await f.store.getDevice(f.id), [advisory()]);
        assert.equal(f.pushes.length, 0, option);
    }
});

test('successful delivery receipts prevent duplicate pushes across repeated scans and restart', async () => {
    const f = fixture();
    await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
    const device = await f.store.getDevice(f.id);
    await f.monitor.deliver(device, [advisory()]);
    await f.monitor.deliver(device, [advisory()]);
    await new DisruptionMonitor(f.dependencies).deliver(device, [advisory()]);
    assert.equal(f.pushes.length, 1);
    assert.equal(f.pushes[0][1].alert_type, 'upcoming_disruption');
    assert.equal(f.pushes[0][2].collapseId.length, 64);
});

test('co-occurring bus, lost-direct and duration warnings send only the highest-severity push', async () => {
    const f = fixture(); await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
    const device = await f.store.getDevice(f.id);
    const warnings = [advisory({ id: 'longer', kind: 'longer_journey', extraMinutes: 25 }),
        advisory({ id: 'direct', kind: 'direct_unavailable' }), advisory({ id: 'bus', kind: 'replacement_bus' })];
    await f.monitor.deliver(device, warnings);
    assert.equal(f.pushes.length, 1);
    assert.equal(f.pushes[0][1].advisory_id, 'bus');
    await f.monitor.deliver(device, warnings);
    assert.equal(f.pushes.length, 1);
});

test('disjoint official validity windows do not suppress an independent warning in their gap', async () => {
    const f = fixture(); await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
    const device = await f.store.getDevice(f.id);
    await f.monitor.deliver(device, [advisory({ id: 'official', kind: 'engineering', confidence: 'confirmed',
        relevanceVersion: ENGINEERING_RELEVANCE_VERSION,
        startAt: '2026-09-21T06:00:00Z', endAt: '2026-09-21T11:00:00Z', affectedWindows: [
            { startAt: '2026-09-21T06:00:00Z', endAt: '2026-09-21T07:00:00Z' },
            { startAt: '2026-09-21T10:00:00Z', endAt: '2026-09-21T11:00:00Z' }
        ] }), advisory({ id: 'gap-warning', kind: 'longer_journey', extraMinutes: 20,
        startAt: '2026-09-21T08:00:00Z', endAt: '2026-09-21T09:00:00Z' })]);
    assert.deepEqual(new Set(f.pushes.map(value => value[1].advisory_id)), new Set(['official', 'gap-warning']));
});

test('timetable copy changes and estimates within the same five-minute band do not repeat a push', async () => {
    const f = fixture(); await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
    const device = await f.store.getDevice(f.id);
    await f.monitor.deliver(device, [advisory({ kind: 'longer_journey', extraMinutes: 15 })]);
    await f.monitor.deliver(device, [advisory({ kind: 'longer_journey', title: 'Updated wording', body: 'Clearer wording.', extraMinutes: 16 })]);
    assert.equal(f.pushes.length, 1);
    await f.monitor.deliver(device, [advisory({ kind: 'longer_journey', extraMinutes: 20 })]);
    assert.equal(f.pushes.length, 2, 'a materially larger allowance produces an update');
});

test('rolling past the first hour of an ongoing contiguous warning preserves its identity and push receipt', async () => {
    const f = fixture({ now: Date.parse('2026-09-21T06:10:00Z') });
    f.state.status.dataset.sourceGenerationDate = '2026-09-20';
    f.state.ingestion.active.metadata.source.generationDate = '2026-09-20';
    f.state.ordinary = () => false;
    await f.monitor.synchronize(registration(f.id, { window_start: '07:00', window_end: '09:00', push_enabled: true }));
    for (const startMinutes of [420, 480]) seed(f, TRAVEL, { startMinutes, endMinutes: startMinutes + 60,
        sourceGenerationDate: '2026-09-20', directTrains: 0, replacementBus: true, railOnlyAvailable: false });
    const initial = await reconcile(f);
    assert.equal(initial.advisories.length, 1); assert.equal(f.pushes.length, 1);
    f.advance(3600000);
    const later = await reconcile(f);
    assert.equal(later.advisories.length, 1);
    assert.equal(later.advisories[0].id, initial.advisories[0].id);
    assert.equal(later.advisories[0].startAt, initial.advisories[0].startAt);
    assert.equal(later.advisories[0].endAt, initial.advisories[0].endAt);
    assert.equal(f.pushes.length, 1);
});

test('failed push delivery retries only after its durable backoff', async () => {
    const f = fixture({ pushResult: { status: 503 } });
    await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
    const device = await f.store.getDevice(f.id);
    await f.monitor.deliver(device, [advisory()]); await f.monitor.deliver(device, [advisory()]);
    assert.equal(f.pushes.length, 1);
    f.advance(300001); await f.monitor.deliver(device, [advisory()]);
    assert.equal(f.pushes.length, 2);
});

test('a bad-token response cannot overwrite preferences edited while the push was being sent', async () => {
    const f = fixture({ pushResult: { status: 410, isBadToken: true }, onPush: async () => {
        await f.monitor.synchronize(registration(f.id, { push_enabled: false, name: 'Updated commute',
            window_start: '09:00', window_end: '10:00' }));
    } });
    await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
    const old = await f.store.getDevice(f.id);
    await f.monitor.deliver(old, [advisory()]);
    const current = await f.store.getDevice(f.id);
    assert.notEqual(current.revision, old.revision);
    assert.equal(current.monitors[0].push_enabled, false);
    assert.equal(current.monitors[0].name, 'Updated commute');
    assert.equal(current.monitors[0].window_start, '09:00');
    assert.equal(current.pushToken, old.pushToken, 'only the exact attempted revision may have its token cleared');
});

test('official notices remain useful while timetable readiness is unavailable', async () => {
    const f = fixture();
    f.state.status.dataset.sourceGenerationDate = '2026-08-25';
    f.state.notices.notices = [official()];
    await f.monitor.synchronize(registration(f.id)); await f.monitor.tick();
    const response = await f.monitor.get(f.id);
    assert.equal(f.calls.length, 0);
    assert.equal(response.monitors[0].status, 'unavailable');
    assert.equal(response.advisories.length, 1);
    assert.equal(response.advisories[0].confidence, 'confirmed');
    assert.equal(response.advisories[0].sourceURL, official().sourceURL);
});

test('shared terminals and profile station unions do not target unrelated engineering warnings', async () => {
    const f = fixture();
    await f.monitor.synchronize(registration(f.id, { stations: ['CLK', 'LBG'], push_enabled: true }));
    f.state.notices.notices = [
        official({ id: 'southern', title: 'Southern work at Norwood Junction', stationCRS: ['LBG', 'CAT'],
            affectedStationClauses: [['LBG', 'CAT']] }),
        official({ id: 'greenwich', title: 'Cannon Street and Greenwich work', stationCRS: ['CST', 'GNW', 'LBG'],
            affectedStationClauses: [['CST', 'GNW'], ['LBG']] }),
        official({ id: 'branches', stationCRS: ['CLK', 'LBG'], affectedStationClauses: [['CLK'], ['LBG']] }),
        official({ id: 'hayes', title: 'Buses replace trains on the Hayes line', stationCRS: ['HYS'],
            affectedStationClauses: [['HYS']], closedStationCRS: ['CLK'] })
    ];
    await f.monitor.refreshSources();
    const device = await f.store.getDevice(f.id);
    const records = new Map([['profile', { profile: { stationCRS: ['CLK', 'LBG', 'CAT', 'CST', 'GNW'] } }]]);
    const results = f.monitor.officialAdvisories(device.monitors[0], records, f.now());
    assert.deepEqual(results.map(row => row.title), ['Buses replace trains on the Hayes line']);
    assert.equal(results[0].relevanceVersion, ENGINEERING_RELEVANCE_VERSION);
    await f.monitor.deliver(device, results);
    assert.equal(f.pushes.length, 1);
    assert.match(f.pushes[0][1].aps.alert.body, /Hayes line/);
});

test('unrelated works at a shared terminal do not exclude an otherwise valid comparison baseline', async () => {
    const f = fixture();
    await f.monitor.synchronize(registration(f.id));
    seedComparison(f, { directTrains: 0, minChanges: 1 });
    f.state.notices.notices = [official({ stationCRS: ['VIC', 'BTN'], affectedStationClauses: [['VIC', 'BTN']],
        startAt: '2026-09-07T00:00:00Z', endAt: '2026-09-15T00:00:00Z' })];
    const result = await reconcile(f);
    assert.ok(result.advisories.some(row => row.kind === 'direct_unavailable'));
    assert.equal(f.monitor.matchNotices({ stations: ['KTH', 'VIC'] },
        { date: '2026-09-14', startMinutes: 420, endMinutes: 480 }, profile(undefined, { stationCRS: ['KTH', 'VIC', 'BTN'] })).length, 0);
    f.state.notices.notices[0].affectedStationClauses = [['KTH', 'VIC']];
    f.monitor.noticeSnapshot = copy(f.state.notices);
    assert.equal(f.monitor.matchNotices({ stations: ['KTH', 'VIC'] },
        { date: '2026-09-14', startMinutes: 420, endMinutes: 480 }, profile()).length, 1);
});

test('legacy broad-match warnings are hidden and cannot be retained or pushed during a source failure', async () => {
    for (const snapshot of [
        { available: false, notices: [] },
        { available: true, complete: false, unverifiedIncidentIds: [null], notices: [] },
        { available: true, complete: false, unverifiedIncidentIds: ['official-1'], notices: [] }
    ]) {
        const f = fixture();
        await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
        const device = f.store.saved.get(f.id);
        const legacy = advisory({ id: hash([['KTH', 'VIC'], 'official-1']), kind: 'engineering', confidence: 'confirmed' });
        device.stateRevision = device.revision;
        device.state = { checkedAt: new Date(f.now()).toISOString(), monitors: [], advisories: [legacy, advisory()] };
        assert.deepEqual((await f.monitor.get(f.id)).advisories.map(row => row.confidence), ['timetable']);
        await f.monitor.deliver(await f.store.getDevice(f.id), [legacy]);
        assert.equal(f.pushes.length, 0);
        f.state.notices = snapshot;
        const response = await reconcile(f);
        assert.equal(response.advisories.some(row => row.confidence === 'confirmed'), false);
        assert.equal(response.advisories.some(row => row.confidence === 'timetable'), true);
        assert.equal((await f.store.getDevice(f.id)).state.advisories.some(row => row.confidence === 'confirmed'), false);
    }
});

test('open-ended official notices have bounded presentation and one incident push', async () => {
    const f = fixture();
    f.state.status.dataset.sourceGenerationDate = '2026-08-25';
    f.state.notices.notices = [official({ endAt: null })];
    await f.monitor.synchronize(registration(f.id, { push_enabled: true })); await f.monitor.tick();
    const response = await f.monitor.get(f.id);
    assert.equal(response.advisories.length, 1);
    assert.ok(response.advisories.every(value => Number.isFinite(Date.parse(value.endAt))));
    assert.ok(Date.parse(response.advisories[0].endAt) < f.now() + 85 * 86400000);
    assert.equal(f.pushes.length, 1);
    await reconcile(f);
    assert.equal(f.pushes.length, 1);
    f.advance(7 * 86400000);
    f.state.notices.checkedAt = new Date(f.now()).toISOString();
    await reconcile(f);
    assert.equal(f.pushes.length, 1, 'rolling dates do not create another incident push');
});

test('repeating validity periods from one official incident share one advisory and push receipt', async () => {
    const f = fixture();
    f.state.status.dataset.sourceGenerationDate = '2026-08-25';
    f.state.notices.notices = [official({ id: 'period-one', incidentId: 'repeating-work' }),
        official({ id: 'period-two', incidentId: 'repeating-work', startAt: '2026-09-28T00:00:00Z', endAt: '2026-09-28T23:00:00Z' })];
    await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
    await f.monitor.tick();
    assert.equal((await f.monitor.get(f.id)).advisories.length, 1);
    assert.equal(f.pushes.length, 1);
    f.state.notices.notices.reverse();
    await reconcile(f);
    assert.equal(f.pushes.length, 1, 'source period ordering is not a meaningful notice change');
});

test('an official notice description edit is visible in-app without another push', async () => {
    const f = fixture(); f.state.status.dataset.sourceGenerationDate = '2026-08-25';
    f.state.notices.notices = [official()];
    await f.monitor.synchronize(registration(f.id, { push_enabled: true }));
    await reconcile(f); assert.equal(f.pushes.length, 1);
    f.state.notices.notices[0].body = 'Updated explanatory wording.';
    const response = await reconcile(f);
    assert.match(response.advisories[0].body, /Updated explanatory wording/);
    assert.equal(f.pushes.length, 1);
});

test('a partial notice feed retains quarantined incidents, clears unrelated resolved work and publishes valid new work', async () => {
    const f = fixture(); await f.monitor.synchronize(registration(f.id)); seedComparison(f);
    f.state.notices = { ...f.state.notices, complete: true, unverifiedIncidentIds: [], notices: [
        official({ id: 'quarantined-period', incidentId: 'quarantined-incident', title: 'Earlier work awaiting verification' }),
        official({ id: 'resolved-period', incidentId: 'resolved-incident', title: 'Resolved earlier work' })
    ] };
    let response = await reconcile(f);
    assert.equal(response.advisories.length, 2);
    const previous = response.advisories.find(value => value.title === 'Earlier work awaiting verification');
    f.state.notices = { ...f.state.notices, complete: false, unverifiedIncidentIds: ['quarantined-incident'], notices: [
        official({ id: 'new-period', incidentId: 'new-incident', title: 'New valid engineering work' })
    ] };
    response = await reconcile(f);
    assert.deepEqual(new Set(response.advisories.map(value => value.title)),
        new Set(['Earlier work awaiting verification', 'New valid engineering work']));
    assert.equal(response.advisories.find(value => value.title === previous.title).id, previous.id);
    assert.match(response.monitors[0].reason, /notice/i);
    assert.match(response.monitors[0].reason, /unavailable|could not|unverified/i);
});

test('an unidentified invalid incident preserves all previous warnings while valid new notices remain visible', async () => {
    const f = fixture(); await f.monitor.synchronize(registration(f.id)); seedComparison(f);
    f.state.notices = { ...f.state.notices, complete: true, unverifiedIncidentIds: [], notices: [
        official({ id: 'first-period', incidentId: 'first-incident', title: 'First prior work' }),
        official({ id: 'second-period', incidentId: 'second-incident', title: 'Second prior work' })
    ] };
    await reconcile(f);
    const next = official({ id: 'third-period', incidentId: 'third-incident', title: 'Valid newly published work' });
    f.state.notices = { ...f.state.notices, complete: false, unverifiedIncidentIds: [null], notices: [next] };
    let response = await reconcile(f);
    assert.deepEqual(new Set(response.advisories.map(value => value.title)),
        new Set(['First prior work', 'Second prior work', 'Valid newly published work']));
    f.state.notices = { ...f.state.notices, complete: true, unverifiedIncidentIds: [], notices: [next] };
    response = await reconcile(f);
    assert.deepEqual(response.advisories.map(value => value.title), ['Valid newly published work']);
});

test('a replacement snapshot with missing baselines cannot falsely clear a prior comparison warning', async () => {
    const f = fixture(); await f.monitor.synchronize(registration(f.id));
    seedComparison(f, { directTrains: 0, minChanges: 1 });
    let response = await reconcile(f);
    assert.ok(response.advisories.some(value => value.kind === 'direct_unavailable'));
    // Simulate missing/expired historical observations, rather than complete
    // prior snapshots that can legitimately supply the same baseline.
    for (const [id, row] of f.store.work) if (row.date !== TRAVEL) f.store.work.delete(id);
    f.state.status.dataset.version = 'v2'; f.state.ingestion.active.version = 'v2'; f.state.ingestion.active.metadata.version = 'v2';
    seed(f, TRAVEL, { datasetVersion: 'v2' });
    response = await reconcile(f);
    assert.ok(response.advisories.some(value => value.kind === 'direct_unavailable'));
    seed(f, '2026-09-14', { datasetVersion: 'v2' }); seed(f, '2026-09-07', { datasetVersion: 'v2' });
    response = await reconcile(f);
    assert.equal(response.advisories.some(value => value.kind === 'direct_unavailable'), false);
});

test('two completed but ineligible baseline rows cannot clear an existing comparison warning', async () => {
    const f = fixture(); await f.monitor.synchronize(registration(f.id));
    seedComparison(f, { directTrains: 0, minChanges: 1 });
    let response = await reconcile(f);
    assert.ok(response.advisories.some(value => value.kind === 'direct_unavailable'));
    seed(f, TRAVEL);
    for (const date of ['2026-09-14', '2026-09-07']) seed(f, date, {
        complete: true, servicesAvailable: false, directTrains: 0, minChanges: null, durationMinutes: null
    });
    response = await reconcile(f);
    assert.ok(response.advisories.some(value => value.kind === 'direct_unavailable'));
    assert.equal(response.monitors[0].status, 'pending');
    seed(f, '2026-09-14'); seed(f, '2026-09-07');
    response = await reconcile(f);
    assert.equal(response.advisories.some(value => value.kind === 'direct_unavailable'), false);
});

test('incomplete all-day coverage still publishes a positive required-bus finding for a completed hour', async () => {
    const f = fixture();
    await f.monitor.synchronize(registration(f.id, { window_start: '00:00', window_end: '24:00', push_enabled: true }));
    seed(f, TRAVEL, { startMinutes: 420, endMinutes: 480, directTrains: 0, replacementBus: true, railOnlyAvailable: false });
    const response = await reconcile(f);
    assert.equal(response.monitors[0].status, 'pending');
    assert.ok(response.advisories.some(value => value.kind === 'replacement_bus'));
    assert.equal(f.pushes.length, 0, 'partial-day warnings wait for complete grouping before push');
});

test('an overnight selection from yesterday still receives its remaining official warning', async () => {
    const f = fixture({ now: Date.parse('2026-09-22T00:10:00Z') });
    f.state.notices.notices = [official({ startAt: '2026-09-21T22:00:00Z', endAt: '2026-09-22T01:00:00Z' })];
    await f.monitor.synchronize(registration(f.id, { window_start: '23:00', window_end: '02:00' }));
    await f.monitor.tick();
    const response = await f.monitor.get(f.id);
    assert.equal(response.advisories.length, 1);
    assert.equal(response.advisories[0].endAt, '2026-09-22T01:00:00.000Z');
});

test('a successful recheck clears a resolved after-midnight warning from yesterday\'s window', async () => {
    const f = fixture({ now: Date.parse('2026-09-22T00:10:00Z') });
    f.state.status.dataset.sourceGenerationDate = '2026-09-21';
    f.state.ingestion.active.metadata.source.generationDate = '2026-09-21';
    await f.monitor.synchronize(registration(f.id, { window_start: '23:00', window_end: '02:00' }));
    const timing = { startMinutes: 60, endMinutes: 120, sourceGenerationDate: '2026-09-21' };
    seed(f, '2026-09-22', { ...timing, replacementBus: true, railOnlyAvailable: false });
    seed(f, '2026-09-15', timing); seed(f, '2026-09-08', timing);
    let response = await reconcile(f);
    assert.ok(response.advisories.some(value => value.kind === 'replacement_bus'));
    seed(f, '2026-09-22', timing);
    response = await reconcile(f);
    assert.equal(response.advisories.some(value => value.kind === 'replacement_bus'), false);
});

test('loss of official feed access retains an existing unexpired authoritative warning', async () => {
    const f = fixture(); f.state.notices.notices = [official()];
    await f.monitor.synchronize(registration(f.id));
    let response = await reconcile(f); assert.equal(response.advisories.length, 1);
    f.state.notices = { available: false, checkedAt: new Date(f.now()).toISOString(), notices: [], reason: 'access_denied' };
    response = await reconcile(f); assert.equal(response.advisories.length, 1);
});
