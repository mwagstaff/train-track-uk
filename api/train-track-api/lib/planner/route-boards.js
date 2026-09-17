import { createHash } from 'node:crypto';
import { API_VERSION, normalizeRequest, PlannerError, POLICY_VERSION, LIVE_POLICY_VERSION } from './contract.js';
import { RouteBoardCache } from './route-board-cache.js';

const HOUR = 3600000;
const LIVE_MS = 30000;
const LEASE_MS = 120000;
const REPLAN_MS = 120000;
const PROFILE_POLICY = 'route-board-v1';
const MAX_PROFILE_BYTES = 4 * 1024 * 1024;
const failure = error => ({ code: error instanceof PlannerError ? error.code : 'DATASET_UNAVAILABLE',
    message: error instanceof PlannerError ? error.message : 'Saved journey planning is temporarily unavailable.' });

export function normalizeRouteBoards(body, now) {
    if (!Array.isArray(body?.routes) || !body.routes.length || body.routes.length > 8) {
        throw new PlannerError('INVALID_REQUEST', 'Supply between one and eight saved journeys.');
    }
    const ids = new Set();
    return body.routes.map(route => {
        if (!route || typeof route.id !== 'string' || !route.id.length || route.id.length > 256 || ids.has(route.id)) {
            throw new PlannerError('INVALID_REQUEST', 'Each saved journey needs a unique ID of at most 256 characters.');
        }
        ids.add(route.id);
        if (route.realtime !== undefined && !['apply', 'ignore'].includes(route.realtime)) {
            throw new PlannerError('INVALID_REQUEST', 'Choose apply or ignore for realtime.');
        }
        const via = route.via ?? [];
        if (!Array.isArray(via) || via.length > 4 || via.some(code => typeof code !== 'string' || !/^[A-Z0-9]{3}$/.test(code.trim().toUpperCase()))) {
            throw new PlannerError('INVALID_STATION', 'Supply at most four required intermediate stations in order.');
        }
        const request = normalizeRequest({ ...route, time: new Date(now).toISOString(), timeType: 'departAfter',
            realtime: 'off', limit: 5, windowMinutes: 360 });
        request.via = via.map(code => code.trim().toUpperCase());
        const stations = [request.origin, ...request.via, request.destination];
        if (new Set(stations).size !== stations.length) throw new PlannerError('INVALID_STATION', 'Choose different stations along the saved journey.');
        return { id: route.id, realtime: route.realtime ?? 'apply', request };
    });
}

export function routeBoardKey(request, version, now) {
    const bucket = Math.floor(now / (2 * HOUR)) * 2 * HOUR;
    const profileRequest = { ...request, time: new Date(bucket - 2 * HOUR).toISOString(), windowMinutes: 480, limit: 512 };
    const identity = { policy: PROFILE_POLICY, routing: POLICY_VERSION, live: LIVE_POLICY_VERSION, version, request: profileRequest };
    return { key: createHash('sha256').update(JSON.stringify(identity)).digest('hex'), request: profileRequest, bucket };
}

// Request-driven refreshes: a POST reads shared state and renews interest; it
// never waits for a national route calculation. All work uses the existing worker.
export class PlannerRouteBoards {
    constructor(service, { cache = new RouteBoardCache(), now = Date.now, maxPending = 8, maxPerClient = 2, maxPerNetwork = 4, maxEntries = 64,
        maxProfileBytes = 32 * 1024 * 1024 } = {}) {
        Object.assign(this, { service, cache, now, maxPending, maxPerClient, maxPerNetwork, maxEntries, maxProfileBytes });
        this.entries = new Map();
        this.queue = [];
        this.active = null;
        this.closed = false;
        this.metrics = { cacheHits: 0, profiles: 0, liveRefreshes: 0, replans: 0, coalesced: 0, failures: 0 };
        this.sweep = setInterval(() => this.prune(), 10000);
        this.sweep.unref();
    }

    async status() {
        if (!this.statusPromise || this.now() - this.statusAt > 1000) {
            this.statusAt = this.now();
            this.statusPromise = this.service.status().catch(error => { this.statusPromise = null; throw error; });
        }
        return this.statusPromise;
    }

    async get(body, { client = 'anonymous', network = client } = {}) {
        const now = this.now();
        const routes = normalizeRouteBoards(body, now);
        if (this.closed) throw new PlannerError('DATASET_UNAVAILABLE', 'Saved journey planning is unavailable.', 503);
        this.prune();
        const metadata = await this.status();
        if (!metadata.available || !metadata.dataset?.version) {
            return { apiVersion: API_VERSION, boards: routes.map(route => ({ id: route.id, status: 'unavailable', pollAfterMs: 20000,
                error: { code: 'DATASET_UNAVAILABLE', message: metadata.reason || 'Saved journey planning is unavailable.' } })) };
        }
        for (const entry of this.entries.values()) {
            if (entry.version !== metadata.dataset.version) {
                entry.pending?.controller.abort();
                this.queue = this.queue.filter(work => work.entry !== entry);
                this.entries.delete(entry.key);
            }
        }
        const boards = routes.map(route => {
            const canonical = routeBoardKey(route.request, metadata.dataset.version, now);
            let entry = this.entries.get(canonical.key);
            let created = false;
            if (!entry) {
                entry = { ...canonical, version: metadata.dataset.version, callers: new Map(), results: new Map(),
                    lastRequested: now, retryAt: 0, lastReplanAt: 0 };
                this.entries.set(entry.key, entry);
                created = true;
            } else if (entry.pending) this.metrics.coalesced++;
            entry.lastRequested = now;
            if (!entry.callers.has(client) && entry.callers.size >= 128) entry.callers.delete(entry.callers.keys().next().value);
            entry.callers.set(client, { network, at: now });
            entry.requestedMode = route.realtime;
            if (!entry.pending && now >= entry.retryAt) {
                if (entry.waitingKind) this.enqueue(entry, entry.waitingKind === 'replan' && route.realtime === 'ignore'
                    ? 'refresh' : entry.waitingKind, route.realtime, { client, network });
                else if (created) this.enqueue(entry, 'load', route.realtime, { client, network });
                else if (!entry.profile || entry.expiresAt <= now) this.enqueue(entry, 'profile', route.realtime, { client, network });
                else if (!entry.results.has(route.realtime) || now - entry.results.get(route.realtime).at >= LIVE_MS
                    || entry.results.get(route.realtime).result.journeys.some(journey => Date.parse(journey.departure) < now)) {
                    this.enqueue(entry, 'refresh', route.realtime, { client, network });
                }
            }
            return this.present(entry, route, now);
        });
        this.pump();
        return { apiVersion: API_VERSION, boards };
    }

    present(entry, route, now) {
        const cached = entry.results.get(route.realtime);
        // Never return an expired observation as a current green/on-time result.
        const expires = cached?.result.live?.expiresAt;
        const usable = cached && now - cached.at < 90000 && (!expires || Date.parse(expires) > now);
        const result = usable ? { ...cached.result,
            journeys: cached.result.journeys.filter(journey => Date.parse(journey.departure) >= now),
            ...(cached.result.disruptedJourneys ? { disruptedJourneys: cached.result.disruptedJourneys.filter(journey => Date.parse(journey.departure) >= now) } : {}) } : null;
        return { id: route.id, status: result ? (entry.pending || entry.waiting || entry.error ? 'refreshing' : 'ready')
            : entry.error && !entry.pending && !entry.waiting ? 'unavailable' : 'queued',
        pollAfterMs: entry.waiting ? 5000 : entry.pending ? 1000 : entry.error ? 5000 : 20000,
        ...(result ? { result } : {}),
        ...(entry.computedAt ? { computedAt: new Date(entry.computedAt).toISOString(), expiresAt: new Date(entry.expiresAt).toISOString() } : {}),
        ...(entry.error ? { error: entry.error } : {}) };
    }

    enqueue(entry, kind, mode, owner) {
        if (entry.pending || this.closed) return false;
        const pending = [...this.queue, ...(this.active ? [this.active] : [])];
        if (pending.length >= this.maxPending || pending.filter(work => work.client === owner.client).length >= this.maxPerClient
            || pending.filter(work => work.network === owner.network).length >= this.maxPerNetwork) {
            entry.waiting = true;
            entry.waitingKind = kind;
            entry.error = { code: 'SEARCH_BUSY', message: 'Saved journeys are waiting to be planned.' };
            entry.retryAt = this.now() + 5000;
            return false;
        }
        entry.waiting = false;
        entry.waitingKind = null;
        entry.pending = { entry, kind, mode, client: owner.client, network: owner.network, controller: new AbortController() };
        this.queue.push(entry.pending);
        return true;
    }

    profileSize(profile) {
        const bytes = Buffer.byteLength(JSON.stringify(profile));
        if (bytes > MAX_PROFILE_BYTES) throw new PlannerError('PROFILE_TOO_LARGE',
            'This saved journey has too many route options to cache. Please use the journey planner.', 422);
        return bytes;
    }

    reserveProfile(entry, bytes, field) {
        let total = [...this.entries.values()].reduce((sum, value) => sum + (value.profileBytes ?? 0)
            + (value.refreshProfileBytes ?? 0), 0) - (entry[field] ?? 0) + bytes;
        for (const other of [...this.entries.values()].sort((a, b) => a.lastRequested - b.lastRequested)) {
            if (total <= this.maxProfileBytes) break;
            if (other === entry || other.pending) continue;
            total -= (other.profileBytes ?? 0) + (other.refreshProfileBytes ?? 0);
            this.entries.delete(other.key);
        }
        if (total > this.maxProfileBytes) throw new PlannerError('SEARCH_BUSY', 'Saved journey planning is busy. Please try again shortly.', 429);
    }

    pump() {
        if (this.active || this.closed) return;
        const work = this.queue.shift();
        if (!work) return;
        this.active = work;
        const { entry, kind, mode, controller } = work;
        let next = null;
        const config = this.service.config ?? {};
        const execution = { timeoutMs: config.jobTimeoutMs ?? 600000, maxOperations: config.jobMaxOperations ?? 1000000000,
            cpuDutyCycle: config.jobCpuDutyCycle ?? 0.5 };
        const call = (method, payload) => this.service.call(method, payload, { signal: controller.signal, execution,
            priority: 'background', queueTimeoutMs: config.jobQueueTimeoutMs ?? 480000 });
        Promise.resolve().then(async () => {
            if (kind === 'load') {
                const stored = await this.cache.get(entry.key);
                if (stored?.profile?.version === entry.version && stored.expiresAt > this.now()) {
                    const bytes = this.profileSize(stored.profile);
                    this.reserveProfile(entry, bytes, 'profileBytes');
                    Object.assign(entry, stored);
                    entry.profileBytes = bytes;
                    this.metrics.cacheHits++;
                    next = 'refresh';
                } else next = 'profile';
                return;
            }
            if (kind === 'profile') {
                this.metrics.profiles++;
                const value = await call('routeBoardProfile', { request: entry.request, version: entry.version });
                if (controller.signal.aborted) return;
                const bytes = this.profileSize(value.profile);
                this.reserveProfile(entry, bytes, 'profileBytes');
                entry.profile = value.profile;
                entry.refreshProfile = null;
                entry.profileBytes = bytes;
                entry.refreshProfileBytes = 0;
                entry.computedAt = this.now();
                entry.expiresAt = this.now() + 2 * HOUR;
                await this.cache.set(entry.key, { profile: entry.profile, computedAt: entry.computedAt, expiresAt: entry.expiresAt });
                next = 'refresh';
                return;
            }
            const replan = kind === 'replan';
            this.metrics[replan ? 'replans' : 'liveRefreshes']++;
            if (replan) entry.lastReplanAt = this.now();
            const value = await call(replan ? 'routeBoardReplan' : 'routeBoardRefresh', {
                profile: mode === 'apply' ? entry.refreshProfile ?? entry.profile : entry.profile,
                time: new Date(this.now()).toISOString(), realtime: mode,
                ...(replan ? { disruptionFingerprint: entry.pendingFingerprint } : {})
            });
            if (controller.signal.aborted) return;
            const { needsReplan, disruptionFingerprint, profile, refreshProfile, ...result } = value;
            if (refreshProfile) {
                const bytes = this.profileSize(refreshProfile);
                this.reserveProfile(entry, bytes, 'refreshProfileBytes');
                entry.refreshProfile = refreshProfile;
                entry.refreshProfileBytes = bytes;
            }
            if (replan) entry.replannedFingerprint = disruptionFingerprint ?? entry.pendingFingerprint;
            entry.results.set(mode, { result, at: this.now() });
            // Replanned candidates may carry live annotations: keep them only for
            // this short-lived result, never persist them as a scheduled profile.
            if (!replan && needsReplan && disruptionFingerprint !== entry.replannedFingerprint
                && this.now() - entry.lastReplanAt >= REPLAN_MS) {
                entry.pendingFingerprint = disruptionFingerprint;
                next = 'replan';
            }
        }).then(() => { entry.error = null; entry.retryAt = 0; }, error => {
            if (!controller.signal.aborted) {
                this.metrics.failures++;
                entry.error = failure(error);
                entry.retryAt = this.now() + (error.code === 'SEARCH_BUSY' ? 5000 : 20000);
            }
        }).finally(() => {
            entry.pending = null;
            this.active = null;
            if (!controller.signal.aborted && next && this.now() - entry.lastRequested < LEASE_MS) this.enqueue(entry, next, mode, work);
            this.prune();
            this.pump();
        });
    }

    prune() {
        const now = this.now();
        for (const entry of this.entries.values()) {
            for (const [client, caller] of entry.callers) if (now - caller.at > LEASE_MS) entry.callers.delete(client);
            if (entry.pending && now - entry.lastRequested > LEASE_MS) {
                entry.pending.controller.abort();
                this.queue = this.queue.filter(work => work.entry !== entry);
                if (this.active?.entry !== entry) entry.pending = null;
            }
            if (!entry.pending && now - entry.lastRequested > LEASE_MS) this.entries.delete(entry.key);
        }
        let bytes = [...this.entries.values()].reduce((total, entry) => total + (entry.profileBytes ?? 0) + (entry.refreshProfileBytes ?? 0), 0);
        for (const entry of [...this.entries.values()].sort((a, b) => a.lastRequested - b.lastRequested)) {
            if (this.entries.size <= this.maxEntries && bytes <= this.maxProfileBytes) break;
            if (!entry.pending) {
                bytes -= (entry.profileBytes ?? 0) + (entry.refreshProfileBytes ?? 0);
                this.entries.delete(entry.key);
            }
        }
    }

    close() {
        this.closed = true;
        clearInterval(this.sweep);
        this.active?.controller.abort();
        this.queue = [];
        this.entries.clear();
    }
}
