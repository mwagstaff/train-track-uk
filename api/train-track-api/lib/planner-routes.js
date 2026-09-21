import express from 'express';
import { PlannerService } from './planner/service.js';
import { API_VERSION, CAPABILITIES, decodeCursor, PlannerError } from './planner/contract.js';
import { PlannerSearchJobs } from './planner/search-jobs.js';
import { PlannerRouteBoards } from './planner/route-boards.js';
import { SavedRouteBoards } from './planner/saved-route-boards.js';
import { isIP } from 'node:net';
import { plannerSearchLog } from './planner-search-log.js';

export function registerPlannerRoutes(app, { service = new PlannerService(), recordRequest = () => {}, requestMiddleware,
    searchLog = plannerSearchLog, routeBoards = new PlannerRouteBoards(service, { searchLog }),
    savedRouteBoards = new SavedRouteBoards(service, { searchLog }), resolveCaller } = {}) {
    const router = express.Router();
    const jobs = new PlannerSearchJobs(service, { searchLog });
    service.searchJobs = jobs;
    service.routeBoards = routeBoards;
    service.savedRouteBoards = savedRouteBoards;
    const observeRequest = operation => (req, res, next) => {
        const started = performance.now();
        req.plannerStartedAt = new Date();
        let recorded = false;
        const record = () => {
            if (recorded) return;
            recorded = true;
            recordRequest(operation, res.writableEnded ? res.statusCode : 499, performance.now() - started);
        };
        res.once('finish', record);
        res.once('close', record);
        res.set('Cache-Control', 'no-store');
        next();
    };
    const beforeRequest = operation => [...(requestMiddleware ? [requestMiddleware] : []), observeRequest(operation)];
    const rejectedSearch = (req, errorCode) => {
        const source = req.path === '/search' ? 'search' : req.path === '/search-jobs' ? 'search-job' : 'saved-route';
        searchLog.start({ source, request: req.body, startedAt: req.plannerStartedAt }).finish({ status: 'fail', outcome: 'rejected', errorCode });
    };
    const requireJSON = (req, res, next) => {
        if (!req.is('application/json')) {
            rejectedSearch(req, 'INVALID_REQUEST');
            res.status(415).json({ error: { code: 'INVALID_REQUEST', message: 'Send the journey search as application/json.' } });
            return;
        }
        next();
    };
    const parseError = (error, req, res, next) => {
        if (error.type === 'entity.too.large') {
            rejectedSearch(req, 'REQUEST_TOO_LARGE');
            res.status(413).json({ error: { code: 'REQUEST_TOO_LARGE', message: 'The journey search must be no larger than 16 KB.' } });
        } else if (error.type === 'entity.parse.failed') {
            rejectedSearch(req, 'INVALID_REQUEST');
            res.status(400).json({ error: { code: 'INVALID_REQUEST', message: 'Supply valid JSON for the journey search.' } });
        } else if (error.status === 415) {
            rejectedSearch(req, 'INVALID_REQUEST');
            res.status(415).json({ error: { code: 'INVALID_REQUEST', message: 'The journey search encoding is not supported.' } });
        } else next(error);
    };
    const handle = method => async (req, res) => {
        const controller = new AbortController();
        let request = req.body;
        if (method === 'search' && request?.cursor !== undefined) {
            try { request = decodeCursor(request.cursor).request; } catch { /* Validation remains owned by the service. */ }
        }
        const observation = method === 'search' ? searchLog.start({ source: 'search', request,
            startedAt: req.plannerStartedAt }) : null;
        const disconnected = () => {
            if (!res.writableEnded) {
                controller.abort();
                observation?.finish({ status: 'other', outcome: 'cancelled', errorCode: 'SEARCH_CANCELLED' });
            }
        };
        res.once('close', disconnected);
        res.set('Cache-Control', 'no-store');
        try {
            const options = { signal: controller.signal,
                ...(observation ? { onStart: () => observation.update({ phase: 'running' }),
                    onTelemetry: telemetry => observation.update(telemetry) } : {}) };
            let result;
            if (method === 'status') result = await service.status(options);
            if (method === 'stations') result = await service.stations(req.query.q ?? '', options);
            if (method === 'search') result = await service.search(req.body, options);
            if (method === 'journey') result = await service.journey(req.params.id, options);
            if (!controller.signal.aborted) {
                res.json(result);
                observation?.finish({ status: 'success', outcome: result.journeys?.length ? 'completed' : 'empty',
                    resultCount: result.journeys?.length ?? 0, datasetVersion: result.dataset?.version });
            }
        } catch (error) {
            if (controller.signal.aborted) return;
            const known = error instanceof PlannerError;
            const status = known ? error.status : 503;
            observation?.finish({ status: error.code === 'SEARCH_CANCELLED' ? 'other' : 'fail',
                outcome: error.code === 'SEARCH_CANCELLED' ? 'cancelled' : 'failed', errorCode: known ? error.code : 'DATASET_UNAVAILABLE' });
            if (method === 'status' && status === 503) {
                res.json({ available: false, apiVersion: API_VERSION, capabilities: CAPABILITIES,
                    reason: 'Journey planning is temporarily unavailable.' });
            } else {
                if (status === 429) res.set('Retry-After', '5');
                res.status(status).json({ error: {
                    code: known ? error.code : 'DATASET_UNAVAILABLE',
                    message: known ? error.message : 'Journey planning is temporarily unavailable.'
                } });
            }
        } finally {
            res.removeListener('close', disconnected);
        }
    };
    router.get('/status', ...beforeRequest('status'), handle('status'));
    router.get('/stations', ...beforeRequest('stations'), handle('stations'));
    router.post('/search', ...beforeRequest('search'), requireJSON, express.json({ limit: '16kb' }), parseError, handle('search'));
    router.get('/journeys/:id', ...beforeRequest('journey'), handle('journey'));
    const caller = req => {
        if (resolveCaller) return resolveCaller(req);
        if (req.plannerTrustedCaller) return req.plannerTrustedCaller;
        const remote = req.socket.remoteAddress || 'unknown';
        const forwarded = req.get('CF-Connecting-IP');
        const network = ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remote) && isIP(forwarded || '') ? forwarded : remote;
        const installation = req.get('X-Planner-Client');
        const client = /^[A-Za-z0-9_-]{8,128}$/.test(installation || '') ? installation : network;
        return { client, network };
    };
    router.post('/route-boards', ...beforeRequest('route-boards'), requireJSON, express.json({ limit: '16kb' }), parseError,
        async (req, res) => {
            try { res.json(await routeBoards.get(req.body, caller(req))); }
            catch (error) {
                const known = error instanceof PlannerError;
                const status = known ? error.status : 503;
                if (status === 429) res.set('Retry-After', '5');
                res.status(status).json({ error: { code: known ? error.code : 'DATASET_UNAVAILABLE',
                    message: known ? error.message : 'Saved journey planning is temporarily unavailable.' } });
            }
        });
    const jobHandler = method => async (req, res) => {
        try {
            let result;
            if (method === 'submit') {
                result = await jobs.submit(req.body, { ...caller(req), idempotencyKey: req.get('Idempotency-Key') });
                res.status(202);
            } else if (method === 'get') result = jobs.get(req.params.id);
            else { jobs.cancel(req.params.id); res.status(204).end(); return; }
            res.set('Retry-After', '1').json(result);
        } catch (error) {
            const known = error instanceof PlannerError;
            const status = known ? error.status : 503;
            if (status === 429) res.set('Retry-After', '5');
            res.status(status).json({ error: { code: known ? error.code : 'DATASET_UNAVAILABLE',
                message: known ? error.message : 'Journey planning is temporarily unavailable.' } });
        }
    };
    router.post('/search-jobs', ...beforeRequest('job-submit'), requireJSON, express.json({ limit: '16kb' }), parseError, jobHandler('submit'));
    router.get('/search-jobs/:id', ...beforeRequest('job-status'), jobHandler('get'));
    router.delete('/search-jobs/:id', ...beforeRequest('job-cancel'), jobHandler('cancel'));
    // No aliases or middleware on any existing API namespace.
    app.use('/api/v3/journey-planner', router);
    // New apps opt into direct-first saved departures. Existing planner and
    // departure endpoints keep their established response and routing behavior.
    app.post('/api/v4/journey-planner/route-boards', ...beforeRequest('saved-route-boards-v4'),
        requireJSON, express.json({ limit: '16kb' }), parseError, async (req, res) => {
            try { res.json(await savedRouteBoards.get(req.body, caller(req))); }
            catch (error) {
                const known = error instanceof PlannerError;
                const status = known ? error.status : 503;
                if (status === 429) res.set('Retry-After', '5');
                res.status(status).json({ error: { code: known ? error.code : 'DATASET_UNAVAILABLE',
                    message: known ? error.message : 'Saved departures are temporarily unavailable.' } });
            }
        });
    return service;
}
