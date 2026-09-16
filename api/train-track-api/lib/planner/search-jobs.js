import { randomUUID } from 'node:crypto';
import { decodeCursor, normalizeRequest, PlannerError } from './contract.js';
import { plannerConfig } from './service.js';

const pending = work => work.state === 'queued' || work.state === 'running';

// Job IDs are unguessable per-caller leases. Identical work is shared, but one
// caller cancelling or disappearing must not cancel another caller's search.
export class PlannerSearchJobs {
    constructor(service, { now = Date.now, leaseMs = 120000, resultMs = 600000,
        maxLeases = 128, maxPerClient = 2, maxPerNetwork = 4 } = {}) {
        this.service = service;
        this.config = { ...plannerConfig({}), ...service.config };
        this.now = now;
        Object.assign(this, { leaseMs, resultMs, maxLeases, maxPerClient, maxPerNetwork });
        this.leases = new Map();
        this.work = new Map();
        this.idempotency = new Map();
        this.queue = [];
        this.active = null;
        this.closed = false;
        this.retryTimer = null;
        this.sweep = setInterval(() => this.prune(), Math.min(10000, leaseMs));
        this.sweep.unref();
    }

    async submit(body, { client = 'anonymous', network = client, idempotencyKey } = {}) {
        if (this.closed) throw new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is unavailable.', 503);
        if (idempotencyKey && !/^[A-Za-z0-9_-]{8,128}$/.test(idempotencyKey)) {
            throw new PlannerError('INVALID_REQUEST', 'Use an 8–128 character Idempotency-Key.');
        }
        const payload = body?.cursor === undefined ? { request: normalizeRequest(body) } : decodeCursor(body.cursor);
        const requestedKey = JSON.stringify(payload);
        const retryKey = idempotencyKey ? `${client}:${idempotencyKey}` : null;
        const previous = () => {
            const lease = this.leases.get(this.idempotency.get(retryKey));
            if (!lease) return null;
            if (lease.requestedKey !== requestedKey) throw new PlannerError('INVALID_REQUEST', 'This Idempotency-Key was used for another search.', 409);
            return this.get(lease.id);
        };
        this.prune();
        if (retryKey) { const value = previous(); if (value) return value; }
        // Pin the active timetable at admission, not after an arbitrary queue wait.
        if (!payload.version) {
            const status = await this.service.status();
            if (!status.available || !status.dataset?.version) {
                throw new PlannerError('DATASET_UNAVAILABLE', status.reason || 'Journey planning is unavailable.', 503);
            }
            payload.version = status.dataset.version;
        }
        if (this.closed) throw new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is unavailable.', 503);
        this.prune();
        if (retryKey) { const value = previous(); if (value) return value; }
        const key = JSON.stringify(payload);
        let work = this.work.get(key);
        if (work && !pending(work)) work = null;
        const outstanding = [...this.leases.values()].filter(lease => !lease.cancelled && pending(lease.work));
        if (outstanding.filter(lease => lease.client === client).length >= this.maxPerClient
            || outstanding.filter(lease => lease.network === network).length >= this.maxPerNetwork) {
            throw new PlannerError('SEARCH_BUSY', 'You already have searches waiting. Wait for one to finish or cancel it.', 429);
        }
        if (!work && [...this.work.values()].filter(pending).length >= this.config.maxSearchJobs) {
            throw new PlannerError('SEARCH_BUSY', 'Journey planning is busy. Your app will try again shortly.', 429);
        }
        // Evict only finished leases when the bounded result store is full.
        if (this.leases.size >= this.maxLeases) {
            for (const lease of this.leases.values()) {
                if (lease.cancelled || !pending(lease.work)) this.removeLease(lease);
                if (this.leases.size < this.maxLeases) break;
            }
        }
        if (this.leases.size >= this.maxLeases) throw new PlannerError('SEARCH_BUSY', 'Journey planning is busy. Please try again shortly.', 429);
        // Eviction can remove the last lease of the work we were going to reuse.
        work = this.work.get(key);
        if (work && !pending(work)) work = null;
        if (!work) {
            work = { key, payload, state: 'queued', createdAt: this.now(), leases: new Set(), controller: new AbortController() };
            this.work.set(key, work);
            this.queue.push(work);
        }
        const lease = { id: randomUUID(), work, client, network, retryKey, requestedKey, touchedAt: this.now() };
        this.leases.set(lease.id, lease);
        if (retryKey) this.idempotency.set(retryKey, lease.id);
        work.leases.add(lease.id);
        this.pump();
        return this.get(lease.id);
    }

    get(id) {
        this.prune();
        const lease = this.leases.get(id);
        if (!lease) throw new PlannerError('SEARCH_EXPIRED', 'This search has expired. Please start a new search.', 410);
        lease.touchedAt = this.now();
        const work = lease.work;
        const status = lease.cancelled ? 'cancelled' : work.state;
        return { id, status, pollAfterMs: 1000,
            ...(status === 'queued' ? { queuePosition: work === this.active ? 1 : this.queue.indexOf(work) + 1 + Number(Boolean(this.active)) } : {}),
            ...(status === 'running' && work.phase ? { phase: work.phase } : {}),
            ...(status === 'completed' ? { result: work.result } : {}),
            ...(status === 'failed' ? { error: work.error } : {}) };
    }

    cancel(id) {
        const lease = this.leases.get(id);
        if (!lease) return; // Idempotent cancellation also covers an expired lease.
        lease.cancelled = true;
        lease.cancelledAt = this.now();
        lease.work.leases.delete(id);
        this.releaseWork(lease.work);
    }

    removeLease(lease) {
        this.leases.delete(lease.id);
        if (lease.retryKey) this.idempotency.delete(lease.retryKey);
        lease.work.leases.delete(lease.id);
        this.releaseWork(lease.work);
    }

    releaseWork(work) {
        if (work.leases.size) return;
        work.controller.abort();
        if (this.work.get(work.key) === work) this.work.delete(work.key);
        this.queue = this.queue.filter(value => value !== work);
    }

    prune() {
        const now = this.now();
        for (const lease of this.leases.values()) {
            const expired = lease.cancelled ? now - lease.cancelledAt >= this.resultMs
                : pending(lease.work) ? now - lease.touchedAt >= this.leaseMs
                    : now - lease.work.finishedAt >= this.resultMs;
            if (expired) this.removeLease(lease);
        }
        for (const work of this.work.values()) {
            if (work.state === 'queued' && now - work.createdAt >= this.config.jobQueueTimeoutMs) {
                work.controller.abort();
                work.state = 'failed';
                work.error = { code: 'SEARCH_BUSY', message: 'The search queue stayed busy for too long. Please try again.' };
                work.finishedAt = now;
            }
        }
        this.queue = this.queue.filter(pending);
        this.pump();
    }

    pump() {
        if (this.closed || this.active || this.retryTimer) return;
        const work = this.queue.shift();
        if (!work) return;
        this.active = work;
        const execution = { timeoutMs: this.config.jobTimeoutMs, maxOperations: this.config.jobMaxOperations,
            cpuDutyCycle: this.config.jobCpuDutyCycle };
        const options = { signal: work.controller.signal, execution,
            queueTimeoutMs: Math.max(1, this.config.jobQueueTimeoutMs - (this.now() - work.createdAt)),
            onStart: () => { if (pending(work)) work.state = 'running'; },
            onProgress: progress => { work.phase = progress.phase; } };
        let retry = false;
        Promise.resolve().then(() => this.service.call('search', work.payload, options)).then(result => {
            if (!work.controller.signal.aborted) { work.result = result; work.state = 'completed'; }
        }, error => {
            if (!work.controller.signal.aborted) {
                if (error.code === 'SEARCH_BUSY') {
                    retry = true;
                    work.state = 'queued';
                    this.queue.unshift(work);
                    return;
                }
                work.state = 'failed';
                work.error = { code: error.code || 'DATASET_UNAVAILABLE', message: error instanceof PlannerError
                    ? error.message : 'Journey planning is temporarily unavailable. Please try again.' };
            }
        }).finally(() => {
            if (!retry) work.finishedAt = this.now();
            this.active = null;
            if (retry) {
                this.retryTimer = setTimeout(() => { this.retryTimer = null; this.prune(); }, 1000);
                this.retryTimer.unref();
            } else this.pump();
        });
    }

    close() {
        this.closed = true;
        clearInterval(this.sweep);
        clearTimeout(this.retryTimer);
        this.retryTimer = null;
        for (const work of this.work.values()) work.controller.abort();
        this.queue = [];
        this.leases.clear();
        this.work.clear();
        this.idempotency.clear();
    }
}
