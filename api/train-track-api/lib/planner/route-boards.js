import { createHash } from 'node:crypto';
import { API_VERSION, normalizeRequest, PlannerError, POLICY_VERSION, LIVE_POLICY_VERSION } from './contract.js';
import { RouteBoardCache } from './route-board-cache.js';
import { noOpPlannerSearchLog } from '../planner-search-log.js';
import { mergeRouteBoardProfiles, PROFILE_BUILD_WARNING } from './route-board-engine.js';

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

export function routeBoardFragmentKey(request, version, from, to) {
    const identity = { policy: `${PROFILE_POLICY}-hourly-v1`, routing: POLICY_VERSION, version,
        request: { ...request, time: from, windowMinutes: (Date.parse(to) - Date.parse(from)) / 60000, limit: 512 } };
    return createHash('sha256').update(JSON.stringify(identity)).digest('hex');
}

// Request-driven refreshes: a POST reads shared state and renews interest; it
// never waits for a national route calculation. All work uses the existing worker.
export class PlannerRouteBoards {
    constructor(service, { cache = new RouteBoardCache(), now = Date.now, maxPending = 8, maxPerClient = 2, maxPerNetwork = 4, maxEntries = 64,
        maxProfileBytes = 32 * 1024 * 1024, searchLog = noOpPlannerSearchLog } = {}) {
        Object.assign(this, { service, cache, now, maxPending, maxPerClient, maxPerNetwork, maxEntries, maxProfileBytes, searchLog });
        this.entries = new Map();
        this.queue = [];
        this.active = null;
        this.sequence = 0;
        this.closed = false;
        this.metrics = { cacheHits: 0, profiles: 0, liveRefreshes: 0, replans: 0, coalesced: 0, failures: 0 };
        this.sweep = setInterval(() => { this.prune(); this.admitWaiting(); this.pump(); }, 10000);
        this.sweep.unref();
    }

    async status() {
        if (!this.statusPromise || this.now() - this.statusAt > 1000) {
            this.statusAt = this.now();
            this.statusPromise = this.service.status().catch(error => { this.statusPromise = null; throw error; });
        }
        return this.statusPromise;
    }

    async get(body, options = {}) {
        const startedAt = new Date(this.now());
        try { return await this.readBoards(body, options, startedAt); }
        catch (error) {
            this.recordRejected(body, error.code || 'DATASET_UNAVAILABLE', startedAt);
            throw error;
        }
    }

    recordRejected(body, errorCode, startedAt = new Date(this.now())) {
        const requests = Array.isArray(body?.routes) && body.routes.length ? body.routes.slice(0, 8) : [null];
        for (const request of requests) this.searchLog.start({ source: 'saved-route', request, startedAt })
            .finish({ status: 'fail', outcome: 'rejected', errorCode, finishedAt: new Date(this.now()) });
    }

    async readBoards(body, { client = 'anonymous', network = client } = {}, startedAt) {
        let now = this.now();
        const routes = normalizeRouteBoards(body, now);
        if (this.closed) throw new PlannerError('DATASET_UNAVAILABLE', 'Saved journey planning is unavailable.', 503);
        this.prune();
        const metadata = await this.status();
        now = this.now();
        if (!metadata.available || !metadata.dataset?.version) {
            this.recordRejected(body, 'DATASET_UNAVAILABLE', startedAt);
            return { apiVersion: API_VERSION, boards: routes.map(route => ({ id: route.id, status: 'unavailable', pollAfterMs: 20000,
                error: { code: 'DATASET_UNAVAILABLE', message: metadata.reason || 'Saved journey planning is unavailable.' } })) };
        }
        for (const entry of this.entries.values()) {
            if (entry.version !== metadata.dataset.version || entry.bucket !== Math.floor(now / (2 * HOUR)) * 2 * HOUR) {
                this.cancelEntry(entry, 'superseded');
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
            const queued = entry.waiting ?? (entry.pending !== this.active ? entry.pending : null);
            if (queued) {
                queued.mode = route.realtime;
                if (queued.kind === 'replan' && route.realtime === 'ignore') {
                    this.finishObservation(queued, { status: 'other', outcome: 'superseded' });
                    queued.kind = 'refresh';
                    queued.observation = this.observe(entry, 'refresh', route.realtime, startedAt);
                    queued.observationFinished = false;
                }
            }
            if (!entry.pending && !entry.waiting && now >= entry.retryAt) {
                const owner = { client, network, logStartedAt: startedAt };
                if (created) this.enqueue(entry, 'load', route.realtime, owner);
                else if (!entry.profile || entry.expiresAt <= now) this.enqueue(entry, 'profile', route.realtime, owner);
                else if (!entry.results.has(route.realtime) || now - entry.results.get(route.realtime).at >= LIVE_MS
                    || entry.results.get(route.realtime).result.journeys.some(journey => Date.parse(journey.departure) < now)) {
                    this.enqueue(entry, 'refresh', route.realtime, owner);
                }
            }
            return this.present(entry, route, now);
        });
        this.admitWaiting();
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
        const work = entry.pending ?? entry.waiting;
        const waiting = this.outstanding().filter(value => value !== this.active || value.phase === 'queued');
        const position = work ? waiting.indexOf(work) + 1 : 0;
        const progress = work && { phase: entry.waiting && entry.retryAt > now ? 'retrying' : work.phase,
            queuedAt: new Date(work.queuedAt).toISOString(),
            ...(work.startedAt != null ? { startedAt: new Date(work.startedAt).toISOString() } : {}),
            ...(position > 0 ? { queuePosition: position } : {}),
            ...(work.completedWindows != null ? { completedWindows: work.completedWindows, totalWindows: work.totalWindows } : {}) };
        return { id: route.id, status: result ? (entry.pending || entry.waiting || entry.error ? 'refreshing' : 'ready')
            : entry.error && !entry.pending ? 'unavailable' : 'queued',
        pollAfterMs: entry.waiting ? 5000 : entry.pending ? 1000 : entry.error ? 5000 : 20000,
        ...(progress ? { progress } : {}),
        ...(entry.profile?.profile?.coverage ? { coverage: entry.profile.profile.coverage } : {}),
        ...(result ? { result } : {}),
        ...(entry.computedAt ? { computedAt: new Date(entry.computedAt).toISOString(), expiresAt: new Date(entry.expiresAt).toISOString() } : {}),
        ...(entry.error ? { error: entry.error } : {}) };
    }

    observe(entry, kind, mode, startedAt = new Date(this.now())) {
        return this.searchLog.start({
            source: kind === 'refresh' ? 'saved-refresh' : kind === 'replan' ? 'saved-replan' : 'saved-route',
            request: { ...entry.request, time: new Date(this.now()).toISOString(), realtime: mode, windowMinutes: 360, limit: 5 },
            startedAt, datasetVersion: entry.version
        });
    }

    enqueue(entry, kind, mode, owner) {
        if (entry.pending || entry.waiting || this.closed) return false;
        if (kind === 'replan' && mode === 'ignore') kind = 'refresh';
        const observation = owner.observation && !owner.observationFinished ? owner.observation
            : this.observe(entry, kind, mode, owner.logStartedAt);
        entry.waiting = { entry, kind, mode, client: owner.client, network: owner.network, observation,
            queuedAt: owner.queuedAt ?? this.now(), order: owner.order ?? ++this.sequence,
            stageQueuedAt: this.now(),
            ...(entry.build ? { completedWindows: entry.build.completed, totalWindows: entry.build.total } : {}),
            phase: 'queued', controller: new AbortController() };
        return true;
    }

    outstanding() {
        const waiting = [...this.entries.values()].map(entry => entry.waiting).filter(Boolean);
        return [...(this.active ? [this.active] : []), ...this.queue, ...waiting].sort((a, b) => {
            if (a === this.active) return -1;
            if (b === this.active) return 1;
            // Preserve age across polls, with initial boards winning a same-poll
            // tie. New cold routes cannot continually overtake an older refresh.
            return a.queuedAt - b.queuedAt || Number(a.entry.results.has(a.mode)) - Number(b.entry.results.has(b.mode))
                || a.order - b.order;
        });
    }

    admitWaiting() {
        if (this.closed) return;
        // Reconsider waiting worker slots together with deferred intents. This
        // prevents an early card's repeated polls from overtaking a cold card.
        for (const work of this.queue.splice(0)) {
            work.entry.pending = null;
            work.entry.waiting = work;
        }
        const admitted = this.active ? [this.active] : [];
        for (const work of this.outstanding()) {
            if (work === this.active || work.entry.retryAt > this.now()) continue;
            if (admitted.length >= this.maxPending) break;
            if (admitted.filter(value => value.client === work.client).length >= this.maxPerClient
                || admitted.filter(value => value.network === work.network).length >= this.maxPerNetwork) continue;
            work.entry.waiting = null;
            work.entry.pending = work;
            work.entry.error = null;
            this.queue.push(work);
            admitted.push(work);
        }
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
            if (other === entry || this.active?.entry === other) continue;
            const retainedBytes = (other.profileBytes ?? 0) + (other.refreshProfileBytes ?? 0);
            if (!retainedBytes) continue;
            total -= retainedBytes;
            const work = other.pending ?? other.waiting;
            if (work) {
                // Queued work does not yet use its profile. Release those bytes
                // while preserving its place and reload the scheduled cache at
                // its turn, instead of making a cold route wait for idle cards.
                work.kind = 'load';
                other.profile = null;
                other.profileBytes = 0;
                other.build = null;
                if (other.refreshProfile) other.replannedFingerprint = null;
                other.refreshProfile = null;
                other.refreshProfileBytes = 0;
            } else this.entries.delete(other.key);
        }
        if (total > this.maxProfileBytes) throw new PlannerError('SEARCH_BUSY', 'Saved journey planning is busy. Please try again shortly.', 429);
    }

    async profileChunk(entry, work, call) {
        if (!entry.build) {
            const begin = Date.parse(entry.request.time), end = begin + entry.request.windowMinutes * 60000;
            const windows = [];
            for (let from = begin; from < end; from += HOUR) windows.push({ from: new Date(from).toISOString(),
                to: new Date(Math.min(end, from + HOUR)).toISOString() });
            const currentHour = Math.floor(this.now() / HOUR) * HOUR;
            // Current departures first, then upcoming hours, then the lookback
            // that can recover trains running late. No interval is omitted.
            windows.sort((a, b) => {
                const rank = value => Date.parse(value.from) >= currentHour
                    ? Date.parse(value.from) - currentHour : end - Date.parse(value.from);
                return rank(a) - rank(b);
            });
            entry.build = { windows, completed: 0, total: windows.length };
            entry.profile = null;
            entry.profileBytes = 0;
            entry.refreshProfile = null;
            entry.refreshProfileBytes = 0;
        }
        const build = entry.build;
        const chunk = build.windows[0];
        const key = routeBoardFragmentKey(entry.request, entry.version, chunk.from, chunk.to);
        const stored = await this.cache.get(key);
        if (work.controller.signal.aborted) return;
        let fragment, provisional;
        if (stored?.profile?.version === entry.version && stored.expiresAt > this.now()
            && stored.profile.searchWindow?.from === chunk.from && stored.profile.searchWindow?.to === chunk.to) {
            fragment = stored.profile;
            work.observation.update({ cacheStatus: 'hit' });
            this.metrics.cacheHits++;
        } else {
            work.observation.update({ cacheStatus: 'miss' });
            this.metrics.profiles++;
            const value = await call('routeBoardProfileChunk', { request: entry.request, version: entry.version, chunk,
                time: new Date(this.now()).toISOString(), realtime: work.mode,
                ...(build.chunkMinutes ? { chunkMinutes: build.chunkMinutes } : {}) });
            if (work.controller.signal.aborted) return;
            fragment = value.profile;
            provisional = value.result;
            this.profileSize(fragment);
            // A future hour remains immutable while it moves into the next
            // two-hour bucket. Versioned keys isolate timetable activations.
            await this.cache.set(key, { profile: fragment, computedAt: this.now(),
                expiresAt: Math.max(this.now() + 2 * HOUR, Date.parse(chunk.to) + 2 * HOUR) });
        }
        if (work.controller.signal.aborted) return;
        const chunkMinutes = fragment.profile?.routingChunkMinutes;
        if (Number.isFinite(chunkMinutes) && chunkMinutes >= 1 / 60 && chunkMinutes <= 60) {
            build.chunkMinutes = Math.min(build.chunkMinutes ?? 60, chunkMinutes);
        }
        const profile = mergeRouteBoardProfiles(entry.profile, fragment, entry.request, {
            completedWindows: build.completed + 1, totalWindows: build.total, now: this.now() });
        const bytes = this.profileSize(profile);
        this.reserveProfile(entry, bytes, 'profileBytes');
        entry.profile = profile;
        entry.profileBytes = bytes;
        entry.computedAt = this.now();
        entry.expiresAt = this.now() + 2 * HOUR;
        build.windows.shift();
        build.completed++;
        work.completedWindows = build.completed;
        work.totalWindows = build.total;
        if (!entry.results.has(work.mode)) {
            if (build.completed > 1) provisional = undefined; // A mode change needs all completed hours, not just the newest one.
            provisional ??= await call('routeBoardPreview', { profile, time: new Date(this.now()).toISOString(), realtime: work.mode });
            if (work.controller.signal.aborted) return;
            entry.results.set(work.mode, { at: this.now(), result: { ...provisional,
                warnings: [...new Set([...(provisional.warnings ?? []), ...(!profile.profile.coverage.complete ? [PROFILE_BUILD_WARNING] : [])])],
                search: { ...provisional.search,
                provisional: true, window: profile.searchWindow, searchTruncated: profile.searchTruncated,
                profileCoverage: profile.profile.coverage } } });
            work.observation.update({ firstResultAt: new Date(this.now()) });
        }
        if (!build.windows.length) {
            entry.build = null;
            await this.cache.set(entry.key, { profile, computedAt: entry.computedAt, expiresAt: entry.expiresAt });
        }
    }

    pump() {
        if (this.active || this.closed) return;
        const work = this.queue.shift();
        if (!work) return;
        this.active = work;
        work.observation.update({ metricsDelta: { admissionQueueMs: Math.max(0, this.now() - work.stageQueuedAt) } });
        const { entry, kind, mode, controller } = work;
        let next = null;
        const config = this.service.config ?? {};
        const execution = { timeoutMs: config.jobTimeoutMs ?? 600000, maxOperations: config.jobMaxOperations ?? 1000000000,
            cpuDutyCycle: config.jobCpuDutyCycle ?? 0.5 };
        const onStart = () => {
            work.startedAt = this.now(); work.phase = kind === 'refresh' ? 'live' : 'preparing';
            work.observation.update({ phase: work.phase });
        };
        const onProgress = progress => {
            const value = typeof progress === 'string' ? { phase: progress } : progress;
            if (!['preparing', 'searching', 'live'].includes(value?.phase)) return;
            work.phase = value.phase;
            work.observation.update({ phase: value.phase });
            if (Number.isInteger(value.completedWindows) && Number.isInteger(value.totalWindows)
                && value.completedWindows >= 0 && value.completedWindows <= value.totalWindows && value.totalWindows <= 8) {
                work.completedWindows = value.completedWindows;
                work.totalWindows = value.totalWindows;
            }
        };
        const call = (method, payload) => this.service.call(method, payload, { signal: controller.signal, execution,
            priority: 'background', queueTimeoutMs: config.jobQueueTimeoutMs ?? 480000, onStart, onProgress,
            onTelemetry: telemetry => work.observation.update(telemetry) });
        Promise.resolve().then(async () => {
            if (kind === 'load') {
                onStart();
                const stored = await this.cache.get(entry.key);
                if (stored?.profile?.version === entry.version && stored.expiresAt > this.now()) {
                    work.observation.update({ cacheStatus: 'hit' });
                    const bytes = this.profileSize(stored.profile);
                    this.reserveProfile(entry, bytes, 'profileBytes');
                    Object.assign(entry, stored);
                    entry.profileBytes = bytes;
                    this.metrics.cacheHits++;
                    if (this.service.supportsProfileChunks && !entry.results.has(mode)) {
                        const result = await call('routeBoardPreview', { profile: entry.profile,
                            time: new Date(this.now()).toISOString(), realtime: mode });
                        if (controller.signal.aborted) return;
                        entry.results.set(mode, { result, at: this.now() });
                        work.observation.update({ firstResultAt: new Date(this.now()) });
                    }
                    next = 'refresh';
                } else { work.observation.update({ cacheStatus: 'miss' }); next = 'profile'; }
                return;
            }
            if (kind === 'profile') {
                if (this.service.supportsProfileChunks) {
                    await this.profileChunk(entry, work, call);
                    if (controller.signal.aborted) return;
                    const previous = entry.results.get(mode);
                    next = !entry.build || !previous || previous.result.search?.provisional
                        || this.now() - previous.at >= LIVE_MS ? 'refresh' : 'profile';
                    return;
                }
                work.observation.update({ cacheStatus: 'miss' });
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
            work.observation.update({ cacheStatus: replan ? 'miss' : 'hit' });
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
            work.observation.update({ firstResultAt: new Date(this.now()) });
            this.finishObservation(work, { status: 'success', outcome: result.journeys?.length ? 'completed' : 'empty',
                resultCount: result.journeys?.length ?? 0 });
            if (entry.build) { next = 'profile'; return; }
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
                if (error.code === 'SEARCH_BUSY') work.observation.update({ phase: 'retrying' });
                else this.finishObservation(work, { status: 'fail', outcome: 'failed', errorCode: error.code || 'DATASET_UNAVAILABLE' });
                entry.error = failure(error);
                entry.retryAt = this.now() + (error.code === 'SEARCH_BUSY' ? 5000 : 20000);
                next = kind;
            }
        }).finally(() => {
            if (controller.signal.aborted) this.finishObservation(work, { status: 'other', outcome: 'cancelled' });
            entry.pending = null;
            this.active = null;
            if (!entry.error && entry.requestedMode !== mode && next !== 'profile') next = 'refresh';
            if (!controller.signal.aborted && next && this.now() - entry.lastRequested < LEASE_MS) {
                // A successful first result releases its place before a replan;
                // automatic retries also go behind older outstanding routes.
                const owner = next === 'replan' || entry.error || (next === 'profile' && entry.build) ? { client: work.client, network: work.network,
                    ...(next === 'profile' && entry.build && !work.observationFinished ? { observation: work.observation } : {}),
                    ...(entry.error?.code === 'SEARCH_BUSY' ? { observation: work.observation } : {}) } : work;
                this.enqueue(entry, next, entry.requestedMode ?? mode, owner);
            } else if (next) this.finishObservation(work, { status: 'other', outcome: 'expired' });
            this.prune();
            this.admitWaiting();
            this.pump();
        });
    }

    finishObservation(work, fields) {
        work.observationFinished = true;
        work.observation.finish({ ...fields, finishedAt: new Date(this.now()) });
    }

    cancelEntry(entry, outcome) {
        for (const work of [entry.pending, entry.waiting].filter(Boolean)) {
            this.finishObservation(work, { status: 'other', outcome });
            work.controller.abort();
        }
    }

    prune() {
        const now = this.now();
        for (const entry of this.entries.values()) {
            if (entry.bucket !== Math.floor(now / (2 * HOUR)) * 2 * HOUR) {
                this.cancelEntry(entry, 'superseded');
                this.queue = this.queue.filter(work => work.entry !== entry);
                this.entries.delete(entry.key);
                continue;
            }
            for (const [client, caller] of entry.callers) if (now - caller.at > LEASE_MS) entry.callers.delete(client);
            if (entry.pending && now - entry.lastRequested > LEASE_MS) {
                this.cancelEntry(entry, 'expired');
                this.queue = this.queue.filter(work => work.entry !== entry);
                if (this.active?.entry !== entry) entry.pending = null;
            }
            if (!entry.pending && now - entry.lastRequested > LEASE_MS) {
                this.cancelEntry(entry, 'expired');
                this.entries.delete(entry.key);
            }
        }
        let bytes = [...this.entries.values()].reduce((total, entry) => total + (entry.profileBytes ?? 0) + (entry.refreshProfileBytes ?? 0), 0);
        for (const entry of [...this.entries.values()].sort((a, b) => a.lastRequested - b.lastRequested)) {
            if (this.entries.size <= this.maxEntries && bytes <= this.maxProfileBytes) break;
            if (!entry.pending) {
                this.cancelEntry(entry, 'evicted');
                bytes -= (entry.profileBytes ?? 0) + (entry.refreshProfileBytes ?? 0);
                this.entries.delete(entry.key);
            }
        }
    }

    close() {
        this.closed = true;
        clearInterval(this.sweep);
        for (const entry of this.entries.values()) this.cancelEntry(entry, 'closed');
        this.active?.controller.abort();
        this.queue = [];
        this.entries.clear();
    }
}
