import express from 'express';
import { PlannerService } from './planner/service.js';
import { API_VERSION, CAPABILITIES, PlannerError } from './planner/contract.js';
import { PlannerSearchJobs } from './planner/search-jobs.js';
import { PlannerRouteBoards } from './planner/route-boards.js';
import { isIP } from 'node:net';

export function registerPlannerRoutes(app, { service = new PlannerService(), recordRequest = () => {}, requestMiddleware,
    routeBoards = new PlannerRouteBoards(service) } = {}) {
    const router = express.Router();
    const jobs = new PlannerSearchJobs(service);
    service.searchJobs = jobs;
    service.routeBoards = routeBoards;
    const observeRequest = operation => (req, res, next) => {
        const started = performance.now();
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
    const requireJSON = (req, res, next) => {
        if (!req.is('application/json')) {
            res.status(415).json({ error: { code: 'INVALID_REQUEST', message: 'Send the journey search as application/json.' } });
            return;
        }
        next();
    };
    const parseError = (error, req, res, next) => {
        if (error.type === 'entity.too.large') {
            res.status(413).json({ error: { code: 'REQUEST_TOO_LARGE', message: 'The journey search must be no larger than 16 KB.' } });
        } else if (error.type === 'entity.parse.failed') {
            res.status(400).json({ error: { code: 'INVALID_REQUEST', message: 'Supply valid JSON for the journey search.' } });
        } else if (error.status === 415) {
            res.status(415).json({ error: { code: 'INVALID_REQUEST', message: 'The journey search encoding is not supported.' } });
        } else next(error);
    };
    const handle = method => async (req, res) => {
        const controller = new AbortController();
        const disconnected = () => { if (!res.writableEnded) controller.abort(); };
        res.once('close', disconnected);
        res.set('Cache-Control', 'no-store');
        try {
            const options = { signal: controller.signal };
            let result;
            if (method === 'status') result = await service.status(options);
            if (method === 'stations') result = await service.stations(req.query.q ?? '', options);
            if (method === 'search') result = await service.search(req.body, options);
            if (method === 'journey') result = await service.journey(req.params.id, options);
            if (!controller.signal.aborted) res.json(result);
        } catch (error) {
            if (controller.signal.aborted) return;
            const known = error instanceof PlannerError;
            const status = known ? error.status : 503;
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
    return service;
}
