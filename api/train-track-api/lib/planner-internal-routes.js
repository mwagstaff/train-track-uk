import express from 'express';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { timingSafeEqual } from 'node:crypto';
import { API_VERSION, PlannerError } from './planner/contract.js';
import { assessTimetableReadiness } from './disruptions/policy.js';

export const PLANNER_INTERNAL_PROTOCOL_VERSION = 1;

export function plannerServiceAuthentication(token) {
    if (typeof token !== 'string' || token.length < 16) throw new Error('PLANNER_SERVICE_TOKEN must contain at least 16 characters.');
    const expected = Buffer.from(`Bearer ${token}`);
    return (req, res, next) => {
        const supplied = Buffer.from(req.get('Authorization') ?? '');
        if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) {
            res.set('Cache-Control', 'no-store').status(401).json({ error: {
                code: 'PLANNER_AUTHENTICATION_REQUIRED', message: 'Planner service authentication is required.'
            } });
            return;
        }
        next();
    };
}

export function registerPlannerInternalRoutes(app, { service, hostId, buildRevision = process.env.BUILD_REVISION || null,
    readIngestion = defaultIngestionReader(service), listSearches, getMetrics, now = Date.now } = {}) {
    if (!service || !validHostId(hostId)) throw new Error('A planner service and stable PLANNER_HOST_ID are required.');
    const router = express.Router();
    const json = express.json({ limit: '16kb', strict: true });
    const readiness = async () => {
        const [status, ingestion] = await Promise.all([
            service.status().catch(() => ({ available: false, apiVersion: API_VERSION })),
            readIngestion().catch(() => null)
        ]);
        const assessment = plannerReadiness(status, ingestion, now);
        return { hostId, protocolVersion: PLANNER_INTERNAL_PROTOCOL_VERSION, buildRevision,
            ready: assessment.ready, readinessReason: assessment.reason, status, ingestion: sanitizeIngestion(ingestion),
            capacity: { maintenanceAvailable: service.maintenanceAvailable?.() !== false,
                pending: service.pendingCount?.() ?? null } };
    };
    router.get('/health', async (_req, res) => {
        const state = await readiness();
        res.set('Cache-Control', 'no-store').json({ process: 'train-track-planner', hostId,
            protocolVersion: PLANNER_INTERNAL_PROTOCOL_VERSION, buildRevision, ready: state.ready,
            apiVersion: state.status?.apiVersion ?? API_VERSION, dataset: state.status?.dataset ?? null });
    });
    router.get('/readiness', async (_req, res) => res.set('Cache-Control', 'no-store').json(await readiness()));
    if (typeof listSearches === 'function') router.get('/admin/searches', async (req, res) => operation(res,
        () => listSearches(req.query)));
    router.post('/disruption-profile', json, async (req, res) => operation(res,
        () => service.disruptionProfile(req.body, { signal: requestSignal(req, res) })));
    router.post('/cache/clear', json, async (_req, res) => operation(res, () => service.clearSearchCache()));
    if (typeof service.acquireLoadAdmissionCap === 'function') {
        router.post('/load/admission', json, async (req, res) => operation(res,
            () => service.acquireLoadAdmissionCap(req.body?.maxQueue)));
        router.delete('/load/admission', json, async (req, res) => operation(res,
            () => service.releaseLoadAdmissionCap(req.body?.leaseId)));
    }
    router.use((error, _req, res, _next) => {
        const tooLarge = error?.type === 'entity.too.large';
        res.status(tooLarge ? 413 : 400).json({ error: { code: tooLarge ? 'REQUEST_TOO_LARGE' : 'INVALID_REQUEST',
            message: tooLarge ? 'The internal planner request must be no larger than 16 KB.' : 'Supply valid JSON.' } });
    });
    app.use('/internal/planner/v1', router);
    if (typeof getMetrics === 'function') app.get('/internal/planner/metrics', async (_req, res) => {
        res.type('text/plain; version=0.0.4; charset=utf-8').send(await getMetrics());
    });
}

function requestSignal(req, res) {
    const controller = new AbortController();
    const close = () => { if (!res.writableEnded) controller.abort(); };
    res.once('close', close);
    controller.signal.addEventListener('abort', () => res.removeListener('close', close), { once: true });
    return controller.signal;
}

async function operation(res, action) {
    try { res.set('Cache-Control', 'no-store').json(await action()); }
    catch (error) {
        const known = error instanceof PlannerError;
        const invalidRange = error?.code === 'INVALID_SEARCH_RANGE';
        if (known && error.status === 429) res.set('Retry-After', '5');
        res.status(known ? error.status : invalidRange ? 400 : 503).json({ error: {
            code: known || invalidRange ? error.code : 'DATASET_UNAVAILABLE',
            message: known || invalidRange ? error.message : 'Journey planning is temporarily unavailable.'
        } });
    }
}

function defaultIngestionReader(service) {
    return async () => JSON.parse(await readFile(join(service.config.dataDirectory, 'ingestion-state.json'), 'utf8'));
}

export function sanitizeIngestion(value) {
    if (!value || typeof value !== 'object') return null;
    const active = value.active && typeof value.active === 'object' ? {
        version: value.active.version ?? null,
        metadata: value.active.metadata && typeof value.active.metadata === 'object' ? {
            version: value.active.metadata.version ?? null,
            source: { generationDate: value.active.metadata.source?.generationDate ?? null },
            coverage: value.active.metadata.coverage ?? null
        } : null,
        validation: value.active.validation && typeof value.active.validation === 'object'
            ? { valid: value.active.validation.valid === true, checkedAt: value.active.validation.checkedAt ?? null } : null
    } : null;
    return { schemaVersion: value.schemaVersion ?? null, enabled: value.enabled === true,
        inProgress: value.inProgress === true, pendingGap: value.pendingGap ? {
            expectedSequence: value.pendingGap.expectedSequence ?? null,
            actualSequence: value.pendingGap.actualSequence ?? null,
            missingCount: value.pendingGap.missingCount ?? null
        } : null, lastResult: value.lastResult ?? null, lastErrorCode: value.lastErrorCode ?? null,
        lastSuccessfulCheckAt: value.lastSuccessfulCheckAt ?? null, active };
}

export function plannerReadiness(status, ingestion, now = Date.now) {
    return assessTimetableReadiness(status, ingestion, { now });
}

function validHostId(value) { return typeof value === 'string' && /^[a-z0-9][a-z0-9._-]{0,63}$/i.test(value); }
