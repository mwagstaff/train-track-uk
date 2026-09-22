import { Worker } from 'node:worker_threads';
import { randomUUID } from 'node:crypto';
import os from 'node:os';
import path from 'node:path';
import { PlannerError, normalizeRequest, decodeCursor } from './contract.js';
import { londonDate } from './time.js';
import { PlannerUpstreamBroker } from './upstream-broker.js';

const defaultWorkerURL = new URL('./worker.js', import.meta.url);
const MAX_WORKERS = 8;

// Each routing worker keeps its own national graph and indexes (roughly
// 0.5 GiB RSS once warm, with a separate V8 heap cap). `auto` allows one
// worker per two CPUs and per 4 GiB of RAM on this host, from two to six.
function plannerWorkerCount(value) {
    if (value === 'auto') {
        const cpus = os.availableParallelism?.() ?? os.cpus().length;
        return Math.max(2, Math.min(6, Math.floor(cpus / 2), Math.floor(os.totalmem() / 4 / 1024 ** 3)));
    }
    const count = Number(value);
    return Number.isInteger(count) && count >= 1 && count <= MAX_WORKERS ? count : 2;
}

export function plannerConfig(env = process.env) {
    function number(name, fallback, min, max) {
        const value = Number(env[name] ?? fallback);
        return Number.isFinite(value) && value >= min && value <= max ? value : fallback;
    }
    const workerCount = plannerWorkerCount(env.PLANNER_WORKERS);
    return {
        dataDirectory: path.resolve(env.PLANNER_DATA_DIR || path.join(os.homedir(), '.local/share/train-track-api/planner')),
        datasetPath: env.PLANNER_DATASET_PATH ? path.resolve(env.PLANNER_DATASET_PATH) : null,
        enabled: env.PLANNER_ENABLED !== 'false',
        raptorOnly: env.PLANNER_RAPTOR_ONLY === 'true',
        tubeTrackEnabled: env.PLANNER_TUBETRACK_ENABLED !== 'false',
        // Prototype defaults for the agreed monthly full-feed cadence; configure before production.
        warnAgeDays: number('PLANNER_WARN_AGE_DAYS', 35, 1, 365),
        maxStaleDays: number('PLANNER_MAX_STALE_DAYS', 45, 1, 365),
        timeoutMs: number('PLANNER_TIMEOUT_MS', 30000, 100, 120000),
        // Admission scales with the pool so extra workers are not left idle.
        maxQueue: number('PLANNER_MAX_QUEUE', Math.max(8, workerCount * 4), 1, 100),
        // Independently bounded routing isolates share the immutable SQLite snapshot.
        workerCount,
        maxOldGenerationSizeMb: number('PLANNER_HEAP_MB', 1024, 128, 8192),
        dateCacheSize: number('PLANNER_DATE_CACHE_SIZE', 6, 1, 14),
        // Broader long-distance searches need more graph work; elapsed time and
        // worker heap remain independently capped at 30 seconds and 1024 MB.
        maxOperations: number('PLANNER_MAX_OPERATIONS', 10000000, 1000, 100000000),
        jobTimeoutMs: number('PLANNER_JOB_TIMEOUT_MS', 600000, 1000, 900000),
        jobQueueTimeoutMs: number('PLANNER_JOB_QUEUE_TIMEOUT_MS', 480000, 1000, 900000),
        jobMaxOperations: number('PLANNER_JOB_MAX_OPERATIONS', 1000000000, 1000, 2000000000),
        // The routing worker is its own thread; Express is not blocked by it.
        // Throttle only when the host must reserve CPU for other services.
        jobCpuDutyCycle: number('PLANNER_JOB_CPU_DUTY_CYCLE', 1, 0.1, 1),
        maintenanceTimeoutMs: number('PLANNER_MAINTENANCE_TIMEOUT_MS', 10000, 100, 30000),
        maintenanceMaxOperations: number('PLANNER_MAINTENANCE_MAX_OPERATIONS', 10000000, 1000, 100000000),
        maintenanceMinFreeMemoryMb: number('PLANNER_MAINTENANCE_MIN_FREE_MEMORY_MB', 512, 0, 65536),
        maintenanceMaxLoadPerCpu: number('PLANNER_MAINTENANCE_MAX_LOAD_PER_CPU', 0.8, 0.1, 4),
        maxLiveWaiters: number('PLANNER_MAX_LIVE_WAITERS', 1, 0, 1),
        maxSearchJobs: number('PLANNER_MAX_SEARCH_JOBS', 20, 1, 32),
        // Resolve the current dates and build the national index before the
        // first search of the day asks for them.
        prewarm: env.PLANNER_PREWARM !== 'false'
    };
}

export function normalizeSearchPayload(body, raptorOnly = false) {
    const payload = body?.cursor === undefined
        ? { request: normalizeRequest(raptorOnly && body?.algorithm === undefined
            && body && typeof body === 'object' && !Array.isArray(body)
            ? { ...body, algorithm: 'raptor' } : body) }
        : decodeCursor(body.cursor);
    if (raptorOnly && payload.request.algorithm !== 'raptor') {
        throw new PlannerError('UNSUPPORTED_REQUEST', 'This planner supports RAPTOR depart-after searches only.', 400);
    }
    return payload;
}

// One shared admission queue; CPU and SQLite work stay in bounded routing isolates.
export class PlannerService {
    constructor(config = plannerConfig(), { workerURL = defaultWorkerURL, metadataOnly = false, maintenanceHeadroom } = {}) {
        this.config = config;
        this.workerURL = workerURL;
        this.workerCount = !metadataOnly && Number.isInteger(config.workerCount)
            && config.workerCount >= 1 && config.workerCount <= MAX_WORKERS ? config.workerCount : 1;
        this.slots = Array.from({ length: this.workerCount }, (_, id) => ({ id,
            worker: null, active: null, parked: new Map(), restarting: false, dateKey: null }));
        this.queue = [];
        this.snapshotOwners = new Map();
        this.searchOwners = new Map();
        this.upstream = new Map();
        this.upstreamBroker = new PlannerUpstreamBroker();
        this.sequence = 0;
        this.closed = false;
        this.metadataOnly = metadataOnly;
        this.standardWorker = workerURL.href === defaultWorkerURL.href;
        this.supportsProfileChunks = this.standardWorker && !metadataOnly;
        this.supportsIOYield = this.standardWorker && !metadataOnly;
        this.metadataService = null;
        this.journeys = new Map();
        this.maintenanceHeadroom = maintenanceHeadroom ?? (() => os.freemem() >= (config.maintenanceMinFreeMemoryMb ?? 512) * 1048576
            && os.loadavg()[0] / (os.availableParallelism?.() ?? os.cpus().length) < (config.maintenanceMaxLoadPerCpu ?? 0.8));
        this.loadAdmissionOverride = null;
    }

    get maxQueue() { return this.loadAdmissionOverride?.maxQueue ?? this.config.maxQueue; }

    acquireLoadAdmissionCap(maxQueue) {
        if (!Number.isInteger(maxQueue) || maxQueue < 1 || maxQueue > 100) {
            throw new PlannerError('INVALID_REQUEST', 'Admission cap must be an integer from 1 to 100.', 400);
        }
        if (this.closed) throw new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is unavailable.', 503);
        if (this.loadAdmissionOverride) throw new PlannerError('LOAD_TEST_ACTIVE', 'Another planner load test is active.', 409);
        const leaseId = randomUUID(), configuredMaxQueue = this.config.maxQueue;
        const expiresAt = new Date(Date.now() + 300000).toISOString();
        const timer = setTimeout(() => this.releaseLoadAdmissionCap(leaseId), 300000);
        timer.unref();
        this.loadAdmissionOverride = { leaseId, maxQueue, timer };
        return { leaseId, configuredMaxQueue, maxQueue, expiresAt };
    }

    releaseLoadAdmissionCap(leaseId) {
        const active = this.loadAdmissionOverride;
        if (active && active.leaseId !== leaseId) {
            throw new PlannerError('LOAD_TEST_ACTIVE', 'A different planner load test owns the admission override.', 409);
        }
        if (active) clearTimeout(active.timer);
        this.loadAdmissionOverride = null;
        return { restored: Boolean(active), maxQueue: this.config.maxQueue };
    }

    metadata() {
        if (!this.metadataService) this.metadataService = new PlannerService({ ...this.config,
            timeoutMs: 5000, maxQueue: 16, maxOldGenerationSizeMb: 256, prewarm: false
        }, { metadataOnly: true });
        return this.metadataService;
    }

    async status(options) {
        const status = this.closed ? await this.call('status', {}, options)
            : this.standardWorker && !this.metadataOnly
                ? await this.metadata().call('status', {}, options) : await this.call('status', {}, options);
        return this.config.raptorOnly ? { ...status, capabilities: { ...status.capabilities,
            algorithms: ['raptor'], timeTypes: ['departAfter'] } } : status;
    }
    stations(query, options) {
        if (typeof query !== 'string' || query.length > 100) {
            return Promise.reject(new PlannerError('INVALID_REQUEST', 'Station search must be at most 100 characters.'));
        }
        if (this.closed) return this.call('stations', { query }, options);
        return this.standardWorker && !this.metadataOnly
            ? this.metadata().call('stations', { query }, options) : this.call('stations', { query }, options);
    }
    search(body, options) {
        try {
            const payload = normalizeSearchPayload(body, this.config.raptorOnly);
            return this.call('search', payload, options);
        } catch (error) { return Promise.reject(error); }
    }
    clearSearchCache(options) { return this.call('clearSearchCache', {}, options); }
    disruptionProfile(body, options = {}) {
        return this.call('disruptionProfile', body, { ...options, priority: 'maintenance',
            execution: { timeoutMs: this.config.maintenanceTimeoutMs ?? 10000,
                maxOperations: this.config.maintenanceMaxOperations ?? 10000000, cpuDutyCycle: 0.25 } });
    }
    async journey(id, options) {
        if (this.closed) throw new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is unavailable.', 503);
        if (typeof id !== 'string' || !/^[a-f0-9]{64}\.[a-f0-9]{32}$/.test(id)) {
            return Promise.reject(new PlannerError('JOURNEY_EXPIRED', 'This journey has expired. Please search again.', 410));
        }
        if (!this.standardWorker) return this.call('journey', { id }, options);
        const cached = this.journeys.get(id);
        if (!cached || Date.now() - cached.at > 3600000) {
            this.journeys.delete(id);
            throw new PlannerError('JOURNEY_EXPIRED', 'This journey has expired. Please search again.', 410);
        }
        const live = cached.live && { ...cached.live, warnings: [...cached.live.warnings,
            ...(Date.parse(cached.live.expiresAt) < Date.now() ? ['These live times are from an earlier search. Search again to refresh them.'] : [])] };
        const dataset = await this.metadata().call('metadata', { version: cached.version, live }, options);
        return { journey: cached.journey, dataset, ...(live ? { live } : {}) };
    }

    // Single-worker diagnostics remain available to scheduling tests and tooling.
    get worker() { return this.slots[0].worker; }
    get active() { return this.slots.find(slot => slot.active)?.active ?? null; }
    get parked() { return new Map(this.slots.flatMap(slot => [...slot.parked])); }

    pendingCount({ includeMaintenance = true } = {}) {
        return new Set([...this.queue, ...this.slots.flatMap(slot =>
            [...slot.parked.values(), ...(slot.active ? [slot.active] : [])])]
            .filter(job => includeMaintenance || job.priority !== 'maintenance')).size;
    }

    maintenanceAvailable() {
        return !this.closed && !this.queue.length && this.slots.every(slot => !slot.active && !slot.parked.size && !slot.restarting)
            && this.maintenanceHeadroom();
    }

    deferMaintenance() {
        for (const job of new Set([...this.queue, ...this.slots.flatMap(slot =>
            [...slot.parked.values(), ...(slot.active ? [slot.active] : [])])])) {
            if (job.priority === 'maintenance') this.cancel(job,
                new PlannerError('SEARCH_DEFERRED', 'Background monitoring yielded to journey searches.', 503));
        }
    }

    call(method, payload = {}, options = {}, targetSlot) {
        const { signal, execution, onStart, onProgress, onTelemetry, queueTimeoutMs, priority = 'interactive' } = options;
        if (this.closed) return Promise.reject(new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is unavailable.', 503));
        if (method === 'search' && this.config.raptorOnly && payload.request?.algorithm !== 'raptor') {
            return Promise.reject(new PlannerError('UNSUPPORTED_REQUEST', 'This planner supports RAPTOR depart-after searches only.', 400));
        }
        if (signal?.aborted) return Promise.reject(new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499));
        // The persistent monitor owns its backlog. Maintenance never queues up
        // inside foreground admission, never ages, and gives way to all demand.
        if (priority === 'maintenance') {
            if (!this.maintenanceAvailable()) return Promise.reject(new PlannerError('SEARCH_DEFERRED', 'Background monitoring is waiting for spare capacity.', 503));
            // Future-date graph preparation cannot evict the first worker's hot
            // foreground index. With one worker, cooperative cancellation applies.
            targetSlot = this.slots.at(-1);
        } else this.deferMaintenance();
        if (this.workerCount > 1 && targetSlot === undefined && ['clearSearchCache', 'runtime'].includes(method)) {
            const slots = this.slots.filter(slot => slot.worker);
            // A cold slot has no result cache or runtime allocations to inspect.
            if (this.pendingCount({ includeMaintenance: false }) + slots.length > this.maxQueue) {
                return Promise.reject(new PlannerError('SEARCH_BUSY', 'Journey planning is busy. Please try again shortly.', 429));
            }
            return Promise.all(slots.map(slot => this.call(method, payload, options, slot))).then(results => {
                if (method === 'clearSearchCache') return { clearedSearches: results.reduce((sum, result) => sum + result.clearedSearches, 0) };
                const caches = {}, memoryBytes = { rss: process.memoryUsage().rss };
                for (const result of results) {
                    for (const [key, value] of Object.entries(result.caches ?? {})) caches[key] = (caches[key] ?? 0) + value;
                    for (const [key, value] of Object.entries(result.memoryBytes ?? {})) {
                        if (key !== 'rss') memoryBytes[key] = (memoryBytes[key] ?? 0) + value;
                    }
                }
                return { searches: results.reduce((sum, result) => sum + (result.searches ?? 0), 0),
                    cacheHits: results.reduce((sum, result) => sum + (result.cacheHits ?? 0), 0),
                    datePreparations: results.reduce((sum, result) => sum + (result.datePreparations ?? 0), 0),
                    caches, memoryBytes, workerCount: this.workerCount,
                    workers: results.map((result, index) => ({ slot: slots[index].id, ...result })) };
            });
        }
        if (priority !== 'maintenance' && this.pendingCount({ includeMaintenance: false }) >= this.maxQueue) {
            return Promise.reject(new PlannerError('SEARCH_BUSY', 'Journey planning is busy. Please try again shortly.', 429));
        }
        if (method === 'search' && (payload.liveSnapshotId || payload.tubeSnapshotId)) {
            const owner = this.snapshotOwners.get(this.snapshotKey(payload));
            if (this.workerCount > 1 && (!owner || owner.slot.worker !== owner.worker)) {
                return Promise.reject(new PlannerError('CURSOR_EXPIRED', 'The information for this search has expired. Please search again.', 410));
            }
            targetSlot = owner?.slot ?? this.slots[0];
        }
        return new Promise((resolve, reject) => {
            const job = { id: ++this.sequence, method, payload, resolve, reject, signal, slot: targetSlot,
                cancelBuffer: new SharedArrayBuffer(4), settled: false, execution, onStart, onProgress, onTelemetry,
                priority, enqueuedAt: Date.now(), dateKey: method === 'disruptionProfile' ? `monitor:${payload.date}` : this.dateKey(payload), searchKey: method === 'search'
                    ? JSON.stringify([payload, Boolean(execution?.timetableOnly), Boolean(execution?.excludeDirect)]) : null };
            job.abort = () => this.cancel(job, new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499));
            job.timer = setTimeout(() => this.cancel(job,
                new PlannerError('SEARCH_TIMEOUT', 'The search took too long. Please try again shortly.', 504)),
            execution ? (queueTimeoutMs ?? this.config.jobQueueTimeoutMs) : this.config.timeoutMs);
            signal?.addEventListener('abort', job.abort, { once: true });
            this.queue.push(job);
            this.pump();
        });
    }

    dateKey(payload) {
        const request = payload.request ?? payload.profile?.request;
        if (!request || !Number.isFinite(Date.parse(request.time))) return null;
        const time = Date.parse(request.time), window = (request.windowMinutes ?? 360) * 60000;
        const lower = request.timeType === 'arriveBy' ? time - window - 86400000 : time;
        const upper = request.timeType === 'arriveBy' ? time : time + window + 86400000;
        // Timetable lookback is constant within a version, so these endpoints
        // identify matching graph ranges without loading metadata on Express.
        return `${payload.version ?? payload.profile?.version ?? 'active'}:${londonDate(lower)}:${londonDate(upper)}`;
    }

    snapshotKey(payload) {
        return `${payload.version}:${payload.liveSnapshotId ? 'live:' + payload.liveSnapshotId : 'tube:' + payload.tubeSnapshotId}`;
    }

    rememberOwner(map, key, slot, maximum) {
        map.delete(key);
        map.set(key, { slot, worker: slot.worker });
        while (map.size > maximum) map.delete(map.keys().next().value);
    }

    settle(job, error, result) {
        if (job.settled) return;
        job.settled = true;
        clearTimeout(job.timer);
        job.signal?.removeEventListener('abort', job.abort);
        if (!error && job.method === 'prewarm' && result?.warmed) job.slot.dateKey = null;
        const presented = ['routeBoardProfileChunk', 'savedRoutePlan'].includes(job.method) ? result?.result : result;
        if (!error && ['search', 'routeBoardRefresh', 'routeBoardReplan', 'routeBoardPreview', 'routeBoardProfileChunk', 'savedRoutePlan'].includes(job.method)) {
            this.retainResult(presented);
            if (job.searchKey) this.rememberOwner(this.searchOwners, job.searchKey, job.slot, 256);
            for (const cursor of Object.values(presented?.pagination ?? {})) {
                if (typeof cursor !== 'string') continue;
                try {
                    const payload = decodeCursor(cursor);
                    if (payload.liveSnapshotId || payload.tubeSnapshotId) {
                        this.rememberOwner(this.snapshotOwners, this.snapshotKey(payload), job.slot, 128);
                    }
                } catch { /* Pagination may also contain non-cursor values. */ }
            }
        }
        error ? job.reject(error) : job.resolve(result);
    }

    retainResult(result) {
        if (!result?.dataset) return;
        for (const journey of [...(result.journeys ?? []), ...(result.disruptedJourneys ?? [])]) {
            this.journeys.delete(journey.id);
            this.journeys.set(journey.id, { journey, version: result.dataset.version, at: Date.now(), live: result.live });
        }
        while (this.journeys.size > 500) this.journeys.delete(this.journeys.keys().next().value);
    }

    cancel(job, error) {
        if (job.settled) return;
        const cancelled = new Int32Array(job.cancelBuffer);
        Atomics.store(cancelled, 0, 1);
        Atomics.notify(cancelled, 0);
        this.settle(job, error);
        this.queue = this.queue.filter(item => item !== job || job.resuming);
        const slot = job.slot;
        if (slot?.active === job) {
            // Also bound non-cooperative work, such as a blocked SQLite call.
            job.killTimer = setTimeout(() => {
                if (slot.active === job) this.resetWorker(error, slot);
            }, job.priority === 'maintenance' ? 100 : 1000);
        }
    }

    startWorker(slot) {
        const worker = new Worker(this.workerURL, {
            workerData: this.config,
            resourceLimits: { maxOldGenerationSizeMb: this.config.maxOldGenerationSizeMb }
        });
        slot.worker = worker;
        worker.on('message', message => {
            if (worker !== slot.worker) return;
            if (message.upstream) { void this.requestUpstream(worker, message); return; }
            if (message.cancelUpstream) { this.upstream.get(message.requestId)?.abort(); return; }
            const job = message.id === slot.active?.id ? slot.active : slot.parked.get(message.id);
            if (!job) return;
            if (message.progress) { job.onProgress?.(message.progress); return; }
            if (message.telemetry) {
                // A cached result/snapshot need not touch the resident graph.
                if (message.telemetry.cacheStatus === 'hit' && slot.active === job) slot.dateKey = job.previousDateKey;
                job.onTelemetry?.(message.telemetry);
                return;
            }
            if (message.waitingForIO) {
                // At most one suspended context. It retains its immutable network;
                // avoid admitting a second network during existing heap pressure.
                if (slot.active === job && this.parked.size < (this.config.maxLiveWaiters ?? 1)
                    && message.heapRatio < 0.55) {
                    slot.parked.set(job.id, job);
                    slot.active = null;
                    this.pump();
                }
                return;
            }
            if (message.readyToResume) {
                if (slot.active === job) worker.postMessage({ id: job.id, resume: true });
                else if (!job.resuming) {
                    job.resuming = true;
                    job.resumeQueuedAt = Date.now();
                    this.queue.push(job);
                    this.pump();
                }
                return;
            }
            clearTimeout(job.killTimer);
            if (slot.active === job) slot.active = null;
            slot.parked.delete(job.id);
            this.settle(job, message.error
                ? Object.assign(new PlannerError(message.error.code, message.error.message, message.error.status),
                    message.error.reason ? { reason: message.error.reason } : {}) : null, message.result);
            this.pump();
        });
        worker.on('error', error => {
            console.error('Planner worker failed:', error.code || error.name);
            if (worker === slot.worker) this.resetWorker(new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is temporarily unavailable.', 503), slot);
        });
        worker.on('exit', () => {
            if (worker === slot.worker) this.resetWorker(new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is temporarily unavailable.', 503), slot);
        });
        if (this.config.prewarm && this.standardWorker && !this.metadataOnly) {
            const warm = () => {
                if (slot.worker === worker && !slot.active && !slot.parked.size && !this.queue.length) {
                    void this.call('prewarm', {}, { priority: 'background' }, slot).catch(() => {});
                }
            };
            slot.warmTimer = setTimeout(warm, 2000);
            slot.warmTimer.unref();
            slot.warmInterval = setInterval(warm, 60000);
            slot.warmInterval.unref();
        }
    }

    async requestUpstream(worker, message) {
        const controller = new AbortController();
        controller.worker = worker;
        this.upstream.set(message.requestId, controller);
        try {
            // Run on Express's asynchronous I/O path, sharing request spacing
            // and upstream metrics with existing departure-board consumers.
            const result = await this.upstreamBroker.request(message.upstream, { signal: controller.signal });
            if (this.slots.some(slot => slot.worker === worker)) worker.postMessage({ requestId: message.requestId, upstreamResult: { data: result.data } });
        } catch (error) {
            if (this.slots.some(slot => slot.worker === worker)) worker.postMessage({ requestId: message.requestId, upstreamError: {
                code: error.code, name: error.name, status: error.response?.status
            } });
        } finally {
            if (this.upstream.get(message.requestId) === controller) this.upstream.delete(message.requestId);
        }
    }

    pump() {
        if (this.closed) return;
        while (true) {
            const available = this.slots.filter(slot => !slot.active && !slot.restarting);
            const eligible = job => !job.slot || available.includes(job.slot);
            // Share priority and ageing across the whole pool. A pinned resume
            // cannot block unrelated work that another isolate can execute.
            const old = this.queue.findIndex(job => eligible(job) && job.priority === 'background'
                && Date.now() - job.enqueuedAt >= 120000);
            const interactive = this.queue.findIndex(job => eligible(job) && !['background', 'maintenance'].includes(job.priority));
            const index = old >= 0 ? old : interactive >= 0 ? interactive : this.queue.findIndex(eligible);
            if (!available.length || index < 0) {
                for (const slot of available) if (!slot.parked.size) slot.worker?.unref();
                return;
            }
            const [job] = this.queue.splice(index, 1);
            const cached = job.searchKey && this.searchOwners.get(job.searchKey);
            const slot = job.slot ?? (cached?.slot.worker === cached?.worker && available.includes(cached?.slot) ? cached.slot : null)
                ?? available.find(slot => job.dateKey && slot.dateKey === job.dateKey)
                ?? available.find(slot => slot.worker && slot.lastPriority !== 'maintenance') ?? available[0];
            job.slot = slot;
            try {
                if (!slot.worker) this.startWorker(slot);
                slot.worker.ref();
                slot.active = job;
                slot.lastPriority = job.priority;
                if (job.resuming) {
                    job.resuming = false;
                    slot.parked.delete(job.id);
                    if (job.settled) job.killTimer = setTimeout(() => {
                        if (slot.active === job) this.resetWorker(new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499), slot);
                    }, 1000);
                    job.onTelemetry?.({ metricsDelta: { resumeQueueMs: Date.now() - job.resumeQueuedAt } });
                    slot.worker.postMessage({ id: job.id, resume: true });
                    continue;
                }
                job.previousDateKey = slot.dateKey;
                if (job.dateKey) slot.dateKey = job.dateKey;
                if (job.execution) {
                    clearTimeout(job.timer);
                    job.timer = setTimeout(() => this.cancel(job,
                        new PlannerError('SEARCH_TIMEOUT', 'This search could not finish within the available processing time. Please try a different time.', 504)), job.execution.timeoutMs);
                }
                job.onStart?.();
                job.onTelemetry?.({ metricsDelta: { queueWaitMs: Date.now() - job.enqueuedAt } });
                slot.worker.postMessage({ id: job.id, method: job.method, payload: job.payload,
                    cancelBuffer: job.cancelBuffer, execution: job.execution });
            } catch {
                slot.active = job;
                this.resetWorker(new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is unavailable on this server.', 503), slot);
            }
        }
    }

    resetWorker(error, slot = this.slots[0]) {
        const worker = slot.worker;
        slot.worker = null;
        slot.dateKey = null;
        clearTimeout(slot.warmTimer);
        clearInterval(slot.warmInterval);
        for (const [key, controller] of this.upstream) if (controller.worker === worker || this.workerCount === 1) {
            controller.abort();
            this.upstream.delete(key);
        }
        for (const map of [this.snapshotOwners, this.searchOwners]) {
            for (const [key, owner] of map) if (owner.slot === slot) map.delete(key);
        }
        if (slot.active) {
            clearTimeout(slot.active.killTimer);
            this.settle(slot.active, error);
            slot.active = null;
        }
        for (const job of slot.parked.values()) this.settle(job, error);
        slot.parked.clear();
        // Only this isolate's state is lost. Keep unstarted work through one
        // recovery with its original deadline; other workers continue normally.
        this.queue = this.queue.filter(job => {
            if (job.slot && job.slot !== slot) return true;
            const lostOwner = job.slot === slot || this.workerCount === 1;
            if (this.closed || job.settled || lostOwner && (job.workerRestarts = (job.workerRestarts ?? 0) + 1) > 1) {
                this.settle(job, error);
                return false;
            }
            return true;
        });
        slot.restarting = true;
        Promise.resolve(worker?.terminate()).catch(() => {}).finally(() => {
            slot.restarting = false;
            this.pump();
        });
    }

    close() {
        this.closed = true;
        if (this.loadAdmissionOverride) this.releaseLoadAdmissionCap(this.loadAdmissionOverride.leaseId);
        this.searchJobs?.close();
        this.routeBoards?.close();
        this.savedRouteBoards?.close();
        this.metadataService?.close();
        this.journeys.clear();
        const error = new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is closed.', 503);
        for (const slot of this.slots) this.resetWorker(error, slot);
        this.upstreamBroker.close();
    }
}
