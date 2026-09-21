import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { COLLECTIONS, getMongoCollection } from './mongo-client.js';
import { API_VERSION, PlannerError } from './planner/contract.js';
import { plannerReadiness, PLANNER_INTERNAL_PROTOCOL_VERSION, sanitizeIngestion } from './planner-internal-routes.js';
import { listPlannerSearchLogs, normalizePlannerSearchLogQuery } from './planner-search-log.js';

const collection = () => getMongoCollection(COLLECTIONS.plannerConfiguration);

export async function loadPlannerTargets(env = process.env, embeddedService) {
    let definitions;
    if (env.PLANNER_TARGETS_FILE) {
        if (!isAbsolute(env.PLANNER_TARGETS_FILE)) throw new Error('PLANNER_TARGETS_FILE must be an absolute path.');
        const parsed = JSON.parse(await readFile(env.PLANNER_TARGETS_FILE, 'utf8'));
        definitions = Array.isArray(parsed) ? parsed : parsed.targets;
    } else {
        definitions = [{ id: 'sky', label: 'Sky (embedded)', mode: 'embedded',
            expectedHostId: env.PLANNER_HOST_ID || 'sky', protocolVersion: PLANNER_INTERNAL_PROTOCOL_VERSION }];
    }
    if (!Array.isArray(definitions) || !definitions.length) throw new Error('PLANNER_TARGETS_FILE must define at least one target.');
    const seen = new Set();
    return definitions.map(definition => {
        const id = text(definition.id, 'target id', /^[a-z0-9][a-z0-9_-]{0,31}$/i);
        if (seen.has(id)) throw new Error(`Duplicate planner target: ${id}`);
        seen.add(id);
        const mode = definition.mode;
        if (!['embedded', 'remote'].includes(mode)) throw new Error(`Planner target ${id} has an invalid mode.`);
        const target = { id, mode, label: text(definition.label ?? id, 'target label', /^.{1,80}$/),
            expectedHostId: text(definition.expectedHostId, 'expected host id', /^[a-z0-9][a-z0-9._-]{0,63}$/i),
            protocolVersion: Number(definition.protocolVersion ?? PLANNER_INTERNAL_PROTOCOL_VERSION) };
        if (target.protocolVersion !== PLANNER_INTERNAL_PROTOCOL_VERSION) {
            throw new Error(`Planner target ${id} uses an unsupported internal protocol.`);
        }
        if (mode === 'embedded') {
            if (!embeddedService) throw new Error(`Planner target ${id} requires the embedded service.`);
            target.service = embeddedService;
        } else {
            const base = new URL(definition.baseUrl);
            if (base.username || base.password || base.search || base.hash || !['https:', 'http:'].includes(base.protocol)
                || base.protocol === 'http:' && !['127.0.0.1', 'localhost', '::1'].includes(base.hostname)) {
                throw new Error(`Planner target ${id} must use HTTPS (or loopback HTTP for local tests) without credentials, query, or fragment.`);
            }
            const tokenEnv = text(definition.tokenEnv ?? 'PLANNER_SERVICE_TOKEN', 'token environment variable', /^[A-Z][A-Z0-9_]{1,127}$/);
            const token = env[tokenEnv];
            if (typeof token !== 'string' || token.length < 16) throw new Error(`Planner target ${id} is missing ${tokenEnv}.`);
            target.baseUrl = base.href.replace(/\/$/, '');
            target.token = token;
        }
        return Object.freeze(target);
    });
}

export class PlannerTargetManager {
    constructor({ targets, getCollection = collection, defaultTargetId = 'sky', forceTargetId = null,
        now = Date.now, cacheMs = 5000, readIngestion } = {}) {
        this.targets = new Map((targets ?? []).map(target => [target.id, target]));
        if (!this.targets.size) throw new Error('At least one planner target is required.');
        if (!this.targets.has(defaultTargetId)) throw new Error(`Unknown PLANNER_DEFAULT_TARGET: ${defaultTargetId}`);
        if (forceTargetId && !this.targets.has(forceTargetId)) throw new Error(`Unknown PLANNER_FORCE_TARGET: ${forceTargetId}`);
        Object.assign(this, { getCollection, defaultTargetId, forceTargetId, now, cacheMs, readIngestion });
        this.selection = forceTargetId ? { targetId: forceTargetId, revision: 0, forced: true,
            updatedAt: new Date(now()), stale: false } : null;
        this.refreshAt = 0;
        this.lastHealth = new Map();
        this.config = [...this.targets.values()].find(target => target.mode === 'embedded')?.service?.config ?? {};
    }

    async init() {
        if (this.forceTargetId) return this.selection;
        try {
            const db = await this.getCollection();
            let row = await db.findOne({ _id: 'active' }, { timeoutMS: 2000 });
            if (!row) {
                const initial = { _id: 'active', targetId: this.defaultTargetId, revision: 1,
                    previousTargetId: null, updatedAt: new Date(this.now()), operator: 'startup-default' };
                try { await db.insertOne(initial, { timeoutMS: 2000 }); row = initial; }
                catch (error) {
                    if (error?.code !== 11000) throw error;
                    row = await db.findOne({ _id: 'active' }, { timeoutMS: 2000 });
                }
            }
            this.useRow(row);
        } catch (error) {
            if (!this.selection) this.selection = { targetId: null, revision: null, forced: false,
                updatedAt: null, stale: true, error: 'Planner target selection is unavailable.' };
            else this.selection = { ...this.selection, stale: true };
            this.refreshAt = this.now() + this.cacheMs;
        }
        return this.selection;
    }

    useRow(row) {
        if (!row || !this.targets.has(row.targetId) || !Number.isSafeInteger(row.revision)) {
            throw new Error('The persisted planner target selection is invalid.');
        }
        this.selection = { targetId: row.targetId, revision: row.revision, forced: false,
            previousTargetId: row.previousTargetId ?? null, updatedAt: row.updatedAt ?? null, stale: false };
        this.refreshAt = this.now() + this.cacheMs;
    }

    async refresh() {
        if (this.forceTargetId || this.now() < this.refreshAt) return this.selection;
        try {
            const row = await (await this.getCollection()).findOne({ _id: 'active' }, { timeoutMS: 2000 });
            this.useRow(row);
        } catch {
            if (this.selection) this.selection = { ...this.selection, stale: true };
            this.refreshAt = this.now() + this.cacheMs;
        }
        return this.selection;
    }

    async pin(targetId) {
        if (targetId) {
            const target = this.targets.get(targetId);
            if (!target) throw unavailable('The planner that owns this request is no longer configured.');
            return { target, targetId, revision: this.selection?.revision ?? null, forced: Boolean(this.forceTargetId) };
        }
        const selection = await this.refresh();
        if (!selection?.targetId) throw unavailable('Journey planning has no available destination.');
        return { ...selection, target: this.targets.get(selection.targetId) };
    }

    describe() {
        return { ...this.selection, targets: [...this.targets.values()].map(target => ({ id: target.id,
            label: target.label, mode: target.mode, expectedHostId: target.expectedHostId,
            health: this.lastHealth.get(target.id) ?? null })) };
    }

    async health(targetId) {
        const { target } = await this.pin(targetId);
        let health;
        if (target.mode === 'embedded') {
            const [status, ingestion] = await Promise.all([target.service.status(), this.localIngestion(target)]);
            const assessment = plannerReadiness(status, ingestion, this.now);
            health = { process: 'train-track-planner', hostId: target.expectedHostId,
                protocolVersion: PLANNER_INTERNAL_PROTOCOL_VERSION, ready: assessment.ready,
                readinessReason: assessment.reason,
                apiVersion: status.apiVersion ?? API_VERSION, dataset: status.dataset ?? null };
        } else health = await requestPlannerTarget(target, '/internal/planner/v1/health', { timeoutMs: 10000 });
        if (health.hostId !== target.expectedHostId || health.protocolVersion !== target.protocolVersion
            || health.process !== 'train-track-planner') throw unavailable('The planner destination reported an unexpected identity or protocol.');
        this.lastHealth.set(target.id, { ...health, checkedAt: new Date(this.now()) });
        return health;
    }

    async select({ targetId, revision, operator = null } = {}) {
        if (this.forceTargetId) throw new PlannerError('TARGET_SELECTION_LOCKED', 'Planner selection is locked by configuration.', 409);
        if (!this.targets.has(targetId) || !Number.isSafeInteger(revision)) {
            throw new PlannerError('INVALID_REQUEST', 'Choose a configured planner target and current revision.', 400);
        }
        const health = await this.health(targetId);
        if (health.ready !== true) throw unavailable('The selected planner is not ready.');
        const previous = await this.pin();
        const updatedAt = new Date(this.now());
        const result = await (await this.getCollection()).findOneAndUpdate({ _id: 'active', revision }, {
            $set: { targetId, previousTargetId: previous.targetId, updatedAt, operator: safeOperator(operator) },
            $inc: { revision: 1 }
        }, { returnDocument: 'after', timeoutMS: 3000 });
        if (!result) throw new PlannerError('TARGET_REVISION_CONFLICT', 'Planner selection changed in another admin session. Refresh and try again.', 409);
        this.useRow(result);
        void this.recordChange({ ...result, _id: `change:${randomUUID()}` });
        return this.describe();
    }

    async recordChange(row) {
        try { await (await this.getCollection()).insertOne(row, { timeoutMS: 2000 }); } catch { /* Audit history is supplementary. */ }
    }

    async status(options = {}) {
        const pin = await this.pin(options.targetId ?? options.targetPin?.targetId);
        if (pin.target.mode === 'embedded') return pin.target.service.status(options);
        return requestPlannerTarget(pin.target, '/api/v3/journey-planner/status', { signal: options.signal, timeoutMs: 10000 });
    }

    async readiness(options = {}) {
        const pin = await this.pin(options.targetId ?? options.targetPin?.targetId);
        if (pin.target.mode === 'remote') {
            return { ...(await requestPlannerTarget(pin.target, '/internal/planner/v1/readiness', { signal: options.signal, timeoutMs: 10000 })),
                targetId: pin.targetId, targetRevision: pin.revision };
        }
        const [status, ingestion] = await Promise.all([pin.target.service.status(options), this.localIngestion(pin.target)]);
        const assessment = plannerReadiness(status, ingestion, this.now);
        return { hostId: pin.target.expectedHostId, protocolVersion: PLANNER_INTERNAL_PROTOCOL_VERSION,
            targetId: pin.targetId, targetRevision: pin.revision, ready: assessment.ready,
            readinessReason: assessment.reason, status,
            ingestion: sanitizeIngestion(ingestion), capacity: {
                maintenanceAvailable: pin.target.service.maintenanceAvailable?.() !== false,
                pending: pin.target.service.pendingCount?.() ?? null
            } };
    }

    async localIngestion(target) {
        if (this.readIngestion) return this.readIngestion(target);
        try { return JSON.parse(await readFile(join(target.service.config.dataDirectory, 'ingestion-state.json'), 'utf8')); }
        catch { return null; }
    }

    async disruptionProfile(body, options = {}) {
        const pin = await this.pin(options.targetId ?? options.targetPin?.targetId);
        if (pin.target.mode === 'embedded') return pin.target.service.disruptionProfile(body, options);
        return requestPlannerTarget(pin.target, '/internal/planner/v1/disruption-profile', {
            method: 'POST', body, signal: options.signal, timeoutMs: 15000
        });
    }

    async clearSearchCache(options = {}) {
        const pin = await this.pin(options.targetId);
        const result = pin.target.mode === 'embedded' ? await pin.target.service.clearSearchCache(options)
            : await requestPlannerTarget(pin.target, '/internal/planner/v1/cache/clear', { method: 'POST', body: {}, timeoutMs: 10000 });
        return { ...result, targetId: pin.targetId, hostId: pin.target.expectedHostId };
    }

    async listSearches(query = {}) {
        const requested = query.historyTarget;
        if (requested !== undefined && (typeof requested !== 'string' || !this.targets.has(requested))) {
            throw new PlannerError('INVALID_REQUEST', 'Choose a configured planner history source.', 400);
        }
        const pin = await this.pin(requested);
        const { historyTarget, ...filters } = query;
        const normalized = normalizePlannerSearchLogQuery(filters);
        const { pageSize, ...parameters } = normalized;
        const data = pin.target.mode === 'embedded' ? await listPlannerSearchLogs(filters)
            : await requestPlannerTarget(pin.target, `/internal/planner/v1/admin/searches?${new URLSearchParams({ ...parameters, per_page: pageSize })}`,
                { timeoutMs: 20000 });
        return { ...data, historyTarget: pin.targetId };
    }

    maintenanceAvailable() { return true; }
}

export async function requestPlannerTarget(target, pathname, { method = 'GET', body, signal, timeoutMs = 10000 } = {}) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    const abort = () => controller.abort();
    signal?.addEventListener('abort', abort, { once: true });
    try {
        const response = await fetch(`${target.baseUrl}${pathname}`, { method, redirect: 'manual', signal: controller.signal,
            headers: { Authorization: `Bearer ${target.token}`, Accept: 'application/json',
                ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}) },
            ...(body !== undefined ? { body: JSON.stringify(body) } : {}) });
        const textValue = await limitedText(response, 10 * 1024 * 1024);
        let payload;
        try { payload = textValue ? JSON.parse(textValue) : {}; }
        catch { throw unavailable('The planner destination returned an invalid response.'); }
        if (!response.ok) {
            const error = payload?.error;
            throw new PlannerError(typeof error?.code === 'string' ? error.code : 'DATASET_UNAVAILABLE',
                typeof error?.message === 'string' ? error.message : 'Journey planning is temporarily unavailable.', response.status);
        }
        return payload;
    } catch (error) {
        if (error instanceof PlannerError) throw error;
        if (controller.signal.aborted) throw new PlannerError('SEARCH_TIMEOUT', 'The planner destination did not respond in time.', 504);
        throw unavailable('The planner destination is unavailable.');
    } finally {
        clearTimeout(timeout);
        signal?.removeEventListener('abort', abort);
    }
}

async function limitedText(response, maximum) {
    const reader = response.body?.getReader();
    if (!reader) return '';
    const chunks = []; let size = 0;
    while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > maximum) { await reader.cancel(); throw unavailable('The planner destination returned an oversized response.'); }
        chunks.push(value);
    }
    return Buffer.concat(chunks.map(value => Buffer.from(value))).toString('utf8');
}

function unavailable(message) { return new PlannerError('DATASET_UNAVAILABLE', message, 503); }
function safeOperator(value) { return typeof value === 'string' && value.length <= 200 ? value : null; }
function text(value, name, pattern) {
    if (typeof value !== 'string' || !pattern.test(value)) throw new Error(`Invalid planner ${name}.`);
    return value;
}
