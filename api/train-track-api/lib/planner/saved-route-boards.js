import { createHash } from 'node:crypto';
import { PlannerError, POLICY_VERSION, londonDate } from './contract.js';
import { normalizeRouteBoards } from './route-boards.js';
import { RouteBoardCache } from './route-board-cache.js';
import { SavedRouteLive, earliestRouteJourneys } from './saved-route-live.js';
import { TubeTrackProvider } from './tube-provider.js';
import { getMongoCollection } from '../mongo-client.js';
import { noOpPlannerSearchLog } from '../planner-search-log.js';

const PLAN_MS = 2 * 3600000;
const LIVE_MS = 30000;
const LEASE_MS = 120000;
const MAX_PLAN_BYTES = 256 * 1024;
const POLICY = 'saved-route-direct-first-v1';
const digest = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const identity = request => ({ origin: request.origin, destination: request.destination, via: request.via,
    maxChanges: request.maxChanges, allowedModes: request.allowedModes,
    extraConnectionMinutes: request.extraConnectionMinutes, windowMinutes: request.windowMinutes });
const errorValue = error => ({ code: error?.code ?? 'LIVE_UNAVAILABLE',
    message: error instanceof PlannerError ? error.message : 'Live departures are temporarily unavailable. Please try again.' });

export function savedRoutePlanKey(request, version, { timeLocked = false } = {}) {
    return digest({ policy: POLICY, routing: POLICY_VERSION, excludeDirect: !timeLocked, version,
        date: londonDate(request.time), ...(timeLocked ? { time: request.time } : {}), request: identity(request) });
}

// V4 checks the lightweight direct board before touching timetable metadata or
// the planner. Only a successful empty board can admit one fallback calculation.
export class SavedRouteBoards {
    constructor(service, { live = new SavedRouteLive({ tubeProvider: service?.config?.tubeTrackEnabled ? new TubeTrackProvider() : null }), cache = new RouteBoardCache({
        collection: () => getMongoCollection('planner_saved_route_plans_v1'), maxEntries: 64, maxBytes: 8 * 1024 * 1024
    }), now = Date.now, searchLog = noOpPlannerSearchLog, maxEntries = 64, maxLive = 4,
    maxPending = 8, maxPerClient = 2, maxPerNetwork = 4 } = {}) {
        Object.assign(this, { service, live, cache, now, searchLog, maxEntries, maxLive, maxPending, maxPerClient, maxPerNetwork });
        this.entries = new Map();
        this.jobs = new Map();
        this.queue = [];
        this.liveQueue = [];
        this.activeLive = new Set();
        this.active = null;
        this.closed = false;
        this.sweep = setInterval(() => { this.prune(); this.pumpLive(); this.pump(); }, 10000);
        this.sweep.unref();
    }

    async get(body, { client = 'anonymous', network = client } = {}) {
        const now = this.now();
        const routes = normalizeRouteBoards(body, now);
        if (this.closed) throw new PlannerError('DATASET_UNAVAILABLE', 'Saved journeys are unavailable.', 503);
        this.prune();
        const boards = routes.map(route => {
            const key = digest({ date: londonDate(route.request.time),
                ...(route.timeLocked ? { time: route.request.time } : {}), request: identity(route.request), mode: route.realtime });
            let entry = this.entries.get(key);
            if (!entry) {
                if (this.entries.size >= this.maxEntries) {
                    return { id: route.id, source: 'direct', status: 'queued', pollAfterMs: 5000,
                        progress: { phase: 'queued', queuedAt: new Date(now).toISOString() } };
                }
                entry = { key, request: route.request, timeLocked: route.timeLocked, mode: route.realtime, source: 'direct', callers: new Map(),
                    lastRequested: now, nextCheckAt: 0, owner: { client, network } };
                this.entries.set(key, entry);
            }
            entry.lastRequested = now;
            if (!entry.callers.has(client) && entry.callers.size >= 128) entry.callers.delete(entry.callers.keys().next().value);
            entry.callers.set(client, { network, at: now });
            const expiry = entry.value?.expiresAt ?? entry.value?.result?.live?.expiresAt;
            if (!entry.livePending && (now >= entry.nextCheckAt || !entry.error && expiry && Date.parse(expiry) <= now)) this.schedule(entry);
            return this.present(entry, route.id);
        });
        this.pumpLive();
        return { apiVersion: 4, boards };
    }

    schedule(entry) {
        if (this.closed || entry.livePending || this.entries.get(entry.key) !== entry) return;
        entry.livePending = true;
        entry.queuedAt = this.now();
        this.liveQueue.push(entry);
    }

    present(entry, id) {
        const now = this.now();
        const fresh = entry.value && now - entry.value.at < (entry.value.source === 'direct' ? 60000 : 90000)
            && (!entry.value.expiresAt || Date.parse(entry.value.expiresAt) > now)
            && (!entry.value.result?.live?.expiresAt || Date.parse(entry.value.result.live.expiresAt) > now);
        const value = fresh ? entry.value : null;
        const job = entry.job;
        const busy = entry.livePending || job;
        const progress = job ? { phase: job.phase, queuedAt: new Date(job.queuedAt).toISOString(),
            ...(job.startedAt != null ? { startedAt: new Date(job.startedAt).toISOString() } : {}),
            ...(job !== this.active ? { queuePosition: [...this.jobs.values()].filter(value => value !== this.active)
                .sort((a, b) => a.queuedAt - b.queuedAt).indexOf(job) + 1 } : {}) }
            : entry.livePending ? { phase: this.activeLive.has(entry) ? 'live' : 'queued', queuedAt: new Date(entry.queuedAt).toISOString() } : null;
        return { id, source: value?.source ?? entry.source,
            status: value ? (busy || entry.error ? 'refreshing' : 'ready') : entry.error && !busy ? 'unavailable' : 'queued',
            pollAfterMs: busy ? 1000 : entry.error ? 5000 : 20000,
            ...(progress ? { progress } : {}), ...(entry.error ? { error: entry.error } : {}),
            ...(value?.direct ? { direct: value.direct } : {}),
            ...(value?.result ? { result: { ...value.result,
                journeys: earliestRouteJourneys(value.result.journeys.filter(journey => Date.parse(journey.departure) >= now)),
                ...(value.result.disruptedJourneys ? { disruptedJourneys: earliestRouteJourneys(value.result.disruptedJourneys
                    .filter(journey => Date.parse(journey.departure) >= now)) } : {}) } } : {}),
            ...(entry.plan ? { computedAt: new Date(entry.plan.computedAt).toISOString(),
                expiresAt: new Date(entry.plan.expiresAt).toISOString() } : {}) };
    }

    pumpLive() {
        while (!this.closed && this.activeLive.size < this.maxLive && this.liveQueue.length) {
            const entry = this.liveQueue.shift();
            if (this.entries.get(entry.key) !== entry) continue;
            const controller = new AbortController();
            entry.liveController = controller;
            this.activeLive.add(entry);
            this.update(entry, controller.signal).catch(error => {
                if (!controller.signal.aborted) {
                    entry.error = errorValue(error);
                    entry.nextCheckAt = this.now() + 10000;
                }
            }).finally(() => {
                this.activeLive.delete(entry);
                entry.livePending = false;
                entry.liveController = null;
                this.pumpLive();
            });
        }
    }

    async metadata() {
        if (!this.statusPromise || this.now() - this.statusAt >= 1000) {
            this.statusAt = this.now();
            this.statusPromise = this.service.status().catch(error => { this.statusPromise = null; throw error; });
        }
        return this.statusPromise;
    }

    async update(entry, signal) {
        const request = { ...entry.request,
            time: entry.timeLocked ? entry.request.time : new Date(this.now()).toISOString(), realtime: entry.mode };
        if (!entry.timeLocked) {
            const direct = await this.live.direct(request, { signal });
            if (signal.aborted) return;
            entry.nextCheckAt = this.now() + LIVE_MS;
            if (direct.status === 'available') {
                this.detach(entry, 'superseded');
                entry.source = 'direct';
                entry.value = { source: 'direct', direct: direct.snapshot, expiresAt: direct.expiresAt, at: this.now() };
                entry.error = null;
                return;
            }
            if (direct.status !== 'empty') {
                // An outage cannot establish the absence of direct trains, and must
                // never turn every saved route into an expensive planner request.
                entry.error = direct.error ?? errorValue();
                entry.nextCheckAt = this.now() + 10000;
                return;
            }
        }
        entry.source = 'planned';
        // A successful fresh empty response replaces the old direct board;
        // those earlier departures are no longer current options.
        if (entry.value?.source === 'direct') entry.value = null;
        const metadata = await this.metadata();
        if (signal.aborted) return;
        if (!metadata.available || !metadata.dataset?.version) {
            throw new PlannerError('DATASET_UNAVAILABLE', metadata.reason || 'The timetable is temporarily unavailable.', 503);
        }
        const version = metadata.dataset.version;
        const key = savedRoutePlanKey(request, version, { timeLocked: entry.timeLocked });
        if (entry.job && entry.job.key !== key) this.detach(entry, 'superseded');
        // Polls can check for the return of direct trains while this shared job
        // runs, but must not race its cache write or replace its final result.
        if (entry.job?.key === key) return;
        if (entry.plan?.key !== key || entry.plan.expiresAt <= this.now()) entry.plan = null;
        let observation;
        if (!entry.plan) {
            const stored = await this.cache.get(key);
            if (signal.aborted) return;
            if (stored?.expiresAt > this.now() && this.validPlan(stored.profile, version)) {
                entry.plan = { ...stored, key };
                observation = this.searchLog.start({ source: 'saved-route', request,
                    startedAt: new Date(this.now()), datasetVersion: version, cacheStatus: 'hit' });
            }
        }
        if (!entry.plan) {
            this.plan(entry, { ...request, realtime: 'off',
                ...(entry.timeLocked && !request.via.length ? { algorithm: 'raptor' } : {}) }, version, key);
            return;
        }
        this.detach(entry, 'superseded');
        try {
            const result = await this.live.refresh(entry.plan.profile, request, { signal });
            if (signal.aborted) {
                observation?.finish({ status: 'other', outcome: 'cancelled', finishedAt: new Date(this.now()) });
                return;
            }
            this.service.retainResult?.(result);
            entry.value = { source: 'planned', result, at: this.now() };
            entry.error = null;
            observation?.finish({ status: 'success', outcome: result.journeys.length ? 'completed' : 'empty',
                resultCount: result.journeys.length, firstResultAt: new Date(this.now()), finishedAt: new Date(this.now()) });
        } catch (error) {
            observation?.finish({ status: signal.aborted ? 'other' : 'fail', outcome: signal.aborted ? 'cancelled' : 'failed',
                errorCode: error.code ?? 'LIVE_UNAVAILABLE', finishedAt: new Date(this.now()) });
            throw error;
        }
    }

    validPlan(profile, version) {
        return Array.isArray(profile?.result?.journeys) && profile.result.dataset?.version === version
            && Buffer.byteLength(JSON.stringify(profile)) <= MAX_PLAN_BYTES;
    }

    plan(entry, request, version, key) {
        let job = this.jobs.get(key);
        if (!job) {
            job = { key, request, version, ...entry.owner, entries: new Set(), queuedAt: this.now(), phase: 'queued',
                controller: new AbortController(), observation: this.searchLog.start({ source: 'saved-route', request,
                    startedAt: new Date(this.now()), datasetVersion: version, cacheStatus: 'miss' }) };
            this.jobs.set(key, job);
        } else if (!job.entries.has(entry)) job.observation.update({ coalesced: true });
        job.entries.add(entry);
        entry.job = job;
        entry.error = null;
        this.pump();
    }

    pump() {
        if (this.closed) return;
        const admitted = this.active ? [this.active] : [];
        this.queue = [];
        for (const job of [...this.jobs.values()].sort((a, b) => a.queuedAt - b.queuedAt)) {
            if (job === this.active || job.controller.signal.aborted) continue;
            if (admitted.length >= this.maxPending) break;
            if (admitted.filter(value => value.client === job.client).length >= this.maxPerClient
                || admitted.filter(value => value.network === job.network).length >= this.maxPerNetwork) continue;
            admitted.push(job);
            this.queue.push(job);
        }
        if (this.active || !this.queue.length) return;
        const job = this.queue.shift();
        this.active = job;
        const config = this.service.config ?? {};
        job.observation.update({ metricsDelta: { admissionQueueMs: Math.max(0, this.now() - job.queuedAt) } });
        Promise.resolve().then(() => this.service.call('savedRoutePlan', { request: job.request, version: job.version,
            includeDirect: job.entries.values().next().value?.timeLocked === true }, {
            priority: 'background', signal: job.controller.signal, queueTimeoutMs: config.jobQueueTimeoutMs ?? 480000,
            execution: { timeoutMs: config.jobTimeoutMs ?? 600000, maxOperations: config.jobMaxOperations ?? 1000000000,
                cpuDutyCycle: config.jobCpuDutyCycle ?? 0.5 },
            onStart: () => { job.startedAt = this.now(); job.phase = 'preparing'; job.observation.update({ phase: 'preparing' }); },
            onProgress: value => {
                const phase = typeof value === 'string' ? value : value?.phase;
                if (['preparing', 'searching'].includes(phase)) { job.phase = phase; job.observation.update({ phase }); }
            },
            onTelemetry: value => job.observation.update(value)
        })).then(async profile => {
            if (job.controller.signal.aborted) return;
            if (!this.validPlan(profile, job.version)) {
                throw new PlannerError('PROFILE_TOO_LARGE', 'This saved route could not be cached. Please use the journey planner.', 422);
            }
            const computedAt = this.now();
            const record = { profile, computedAt, expiresAt: computedAt + PLAN_MS };
            // One planner completion writes at a time, so the shared cache's
            // bounded Mongo writer is not flooded by concurrent route results.
            await this.cache.set(job.key, record);
            if (job.controller.signal.aborted) return;
            for (const entry of job.entries) {
                entry.plan = { ...record, key: job.key };
                const warning = 'Live times are being checked; scheduled times are shown.';
                const result = { ...profile.result, search: { ...profile.result.search, provisional: true },
                    warnings: [...new Set([...(profile.result.warnings ?? []), warning])],
                    live: { mode: entry.mode, status: 'unavailable', windowHours: 4, warnings: [warning] } };
                this.service.retainResult?.(result);
                entry.value = { source: 'planned', result, at: this.now() };
                entry.nextCheckAt = 0;
            }
            job.observation.finish({ status: 'success', outcome: profile.result.journeys.length ? 'completed' : 'empty',
                resultCount: profile.result.journeys.length, firstResultAt: new Date(this.now()), finishedAt: new Date(this.now()) });
        }).catch(error => {
            if (job.controller.signal.aborted) return;
            for (const entry of job.entries) {
                entry.error = errorValue(error);
                entry.nextCheckAt = this.now() + 20000;
            }
            job.observation.finish({ status: 'fail', outcome: 'failed', errorCode: error.code || 'DATASET_UNAVAILABLE',
                finishedAt: new Date(this.now()) });
        }).finally(() => {
            if (this.jobs.get(job.key) === job) this.jobs.delete(job.key);
            for (const entry of job.entries) {
                if (entry.job === job) entry.job = null;
                if (entry.plan && !entry.error) this.schedule(entry);
            }
            this.active = null;
            this.pumpLive();
            this.pump();
        });
    }

    detach(entry, outcome) {
        const job = entry.job;
        if (!job) return;
        job.entries.delete(entry);
        entry.job = null;
        if (job.entries.size) return;
        job.controller.abort();
        job.observation.finish({ status: 'other', outcome, finishedAt: new Date(this.now()) });
        if (this.jobs.get(job.key) === job) this.jobs.delete(job.key);
        this.queue = this.queue.filter(value => value !== job);
    }

    prune() {
        const now = this.now();
        for (const entry of this.entries.values()) {
            for (const [client, caller] of entry.callers) if (now - caller.at > LEASE_MS) entry.callers.delete(client);
            if (now - entry.lastRequested <= LEASE_MS && londonDate(entry.request.time) === londonDate(now)) continue;
            entry.liveController?.abort();
            this.detach(entry, 'expired');
            this.entries.delete(entry.key);
        }
        this.liveQueue = this.liveQueue.filter(entry => this.entries.get(entry.key) === entry);
    }

    close() {
        this.closed = true;
        clearInterval(this.sweep);
        for (const entry of this.entries.values()) {
            entry.liveController?.abort();
            this.detach(entry, 'closed');
        }
        this.entries.clear();
        this.queue = [];
        this.liveQueue = [];
    }
}
