import express from 'express';
import { isIP } from 'node:net';
import { API_VERSION, CAPABILITIES, PlannerError } from './planner/contract.js';

const MAX_RESPONSE_BYTES = 10 * 1024 * 1024;
const INTERNAL_HEADERS = ['authorization', 'x-planner-caller-network', 'x-planner-forwarded', 'x-planner-host-id'];

export function registerPlannerGateway(app, { targets, ownership, recordRequest = () => {}, requestMiddleware } = {}) {
    if (!targets || !ownership) throw new Error('Planner gateway requires target selection and routing ownership.');
    const mount = (namespace, allowed) => app.use(namespace, ...requestMiddleware ? [requestMiddleware] : [],
        createHandler(namespace, allowed, { targets, ownership, recordRequest }));
    mount('/api/v3/journey-planner', new Map([
        ['GET /status', 'status'], ['GET /stations', 'stations'], ['POST /search', 'search'],
        ['POST /search-jobs', 'job-submit'], ['GET /search-jobs/:id', 'job'],
        ['DELETE /search-jobs/:id', 'job'], ['GET /journeys/:id', 'journey'],
        ['POST /route-boards', 'route-boards']
    ]));
    mount('/api/v4/journey-planner', new Map([['POST /route-boards', 'saved-route-boards-v4']]));
}

function createHandler(namespace, allowed, dependencies) {
    const parser = express.json({ limit: '16kb', strict: true });
    return (req, res, next) => {
        const match = matchOperation(req.method, req.path, allowed);
        if (!match) return next();
        res.set('Cache-Control', 'no-store');
        const started = performance.now();
        let recorded = false;
        const record = () => {
            if (recorded) return;
            recorded = true;
            dependencies.recordRequest(match.operation, res.writableEnded ? res.statusCode : 499, performance.now() - started);
        };
        res.once('finish', record); res.once('close', record);
        if (!['POST', 'PUT', 'PATCH'].includes(req.method)) {
            void dispatch(req, res, next, namespace, match, dependencies);
            return;
        }
        if (!req.is('application/json')) {
            res.status(415).json({ error: { code: 'INVALID_REQUEST', message: 'Send the journey search as application/json.' } });
            return;
        }
        parser(req, res, error => {
            if (error) {
                const tooLarge = error.type === 'entity.too.large';
                const unsupported = error.status === 415;
                res.status(tooLarge ? 413 : unsupported ? 415 : 400).json({ error: {
                    code: tooLarge ? 'REQUEST_TOO_LARGE' : 'INVALID_REQUEST',
                    message: tooLarge ? 'The journey search must be no larger than 16 KB.'
                        : unsupported ? 'The journey search encoding is not supported.' : 'Supply valid JSON for the journey search.'
                } });
                return;
            }
            void dispatch(req, res, next, namespace, match, dependencies);
        });
    };
}

async function dispatch(req, res, next, namespace, match, { targets, ownership }) {
    try {
        const selected = await targets.pin();
        const caller = plannerCaller(req);
        const targetId = await ownership.targetFor({ operation: match.operation, artifact: match.artifact,
            cursor: findRequestCursor(req.body), caller: caller.client, idempotencyKey: req.get('Idempotency-Key'),
            requestBody: req.body === undefined ? '' : JSON.stringify(req.body), selectedTargetId: selected.targetId });
        const pin = targetId === selected.targetId ? selected : await targets.pin(targetId);
        if (pin.target.mode === 'embedded') {
            rememberLocalResponse(res, ownership, pin.targetId, match.operation);
            req.plannerTrustedCaller = caller;
            return next();
        }
        await forward(req, res, namespace, match.operation, pin.target, caller, ownership);
    } catch (error) { sendGatewayError(res, match.operation, error); }
}

function rememberLocalResponse(res, ownership, targetId, operation) {
    const send = res.json.bind(res);
    res.json = payload => {
        res.json = send;
        if (res.statusCode >= 200 && res.statusCode < 300) {
            ownership.rememberResponse(targetId, operation, payload)
                .then(() => send(payload))
                .catch(() => sendOwnershipFailure(res));
        } else send(payload);
        return res;
    };
}

async function forward(req, res, namespace, operation, target, caller, ownership) {
    const controller = new AbortController();
    const deadline = setTimeout(() => controller.abort(), operation === 'search' ? 35000 : 10000);
    const disconnected = () => { if (!res.writableEnded) controller.abort(); };
    res.once('close', disconnected);
    try {
        const headers = { Authorization: `Bearer ${target.token}`, Accept: 'application/json',
            'X-Planner-Forwarded': 'gateway-v1', 'X-Planner-Caller-Network': caller.network };
        const client = req.get('X-Planner-Client');
        if (/^[A-Za-z0-9_-]{8,128}$/.test(client ?? '')) headers['X-Planner-Client'] = client;
        const idempotencyKey = req.get('Idempotency-Key');
        if (typeof idempotencyKey === 'string' && idempotencyKey.length <= 200) headers['Idempotency-Key'] = idempotencyKey;
        if (req.body !== undefined) headers['Content-Type'] = 'application/json';
        const response = await fetch(`${target.baseUrl}${namespace}${req.url}`, { method: req.method,
            redirect: 'manual', signal: controller.signal, headers,
            ...(req.body !== undefined ? { body: JSON.stringify(req.body) } : {}) });
        if (response.status >= 300 && response.status < 400) throw new PlannerError('DATASET_UNAVAILABLE', 'The planner destination returned an unsafe redirect.', 503);
        const content = await readResponse(response, MAX_RESPONSE_BYTES);
        let payload = null;
        if (content.length) {
            try { payload = JSON.parse(content); }
            catch { throw new PlannerError('DATASET_UNAVAILABLE', 'The planner destination returned an invalid response.', 503); }
        }
        if (response.ok && payload) await ownership.rememberResponse(target.id, operation, payload);
        for (const header of ['cache-control', 'retry-after']) {
            const value = response.headers.get(header); if (value) res.set(header, value);
        }
        res.status(response.status);
        if (response.status === 204) res.end();
        else res.type('application/json').send(JSON.stringify(payload ?? {}));
    } catch (error) {
        if (controller.signal.aborted && !res.writableEnded) {
            sendGatewayError(res, operation, new PlannerError('SEARCH_TIMEOUT', 'The planner destination did not respond in time.', 504));
        } else if (!res.writableEnded) sendGatewayError(res, operation, error);
    } finally {
        clearTimeout(deadline);
        res.removeListener('close', disconnected);
    }
}

function matchOperation(method, path, allowed) {
    for (const [pattern, operation] of allowed) {
        const [expectedMethod, template] = pattern.split(' ');
        if (method !== expectedMethod) continue;
        const expression = new RegExp(`^${template.replace(/:[^/]+/g, '([^/]+)')}/?$`);
        const match = expression.exec(path);
        if (match) return { operation, artifact: match[1] ? decodeURIComponent(match[1]) : null };
    }
    return null;
}

export function plannerCaller(req) {
    if (req.plannerTrustedCaller) return req.plannerTrustedCaller;
    const remote = req.socket.remoteAddress || 'unknown';
    const forwarded = req.get('CF-Connecting-IP');
    const network = ['127.0.0.1', '::1', '::ffff:127.0.0.1'].includes(remote) && isIP(forwarded || '') ? forwarded : remote;
    const installation = req.get('X-Planner-Client');
    return { client: /^[A-Za-z0-9_-]{8,128}$/.test(installation || '') ? installation : network, network };
}

export function trustedPlannerCaller(req) {
    const network = req.get('X-Planner-Caller-Network');
    if (req.get('X-Planner-Forwarded') !== 'gateway-v1' || typeof network !== 'string' || network.length > 128) return plannerCaller(req);
    const installation = req.get('X-Planner-Client');
    return { client: /^[A-Za-z0-9_-]{8,128}$/.test(installation || '') ? installation : network, network };
}

function findRequestCursor(body) { return typeof body?.cursor === 'string' ? body.cursor : null; }

async function readResponse(response, maximum) {
    const reader = response.body?.getReader();
    if (!reader) return '';
    const chunks = []; let length = 0;
    while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        length += value.byteLength;
        if (length > maximum) { await reader.cancel(); throw new PlannerError('DATASET_UNAVAILABLE', 'The planner destination returned an oversized response.', 503); }
        chunks.push(Buffer.from(value));
    }
    return Buffer.concat(chunks).toString('utf8');
}

function sendOwnershipFailure(res) {
    if (!res.headersSent) res.status(503).json({ error: { code: 'DATASET_UNAVAILABLE',
        message: 'The journey was created but its routing ownership could not be saved. Retry with the same idempotency key.' } });
}

function sendGatewayError(res, operation, error) {
    if (res.headersSent || res.writableEnded) return;
    const known = error instanceof PlannerError;
    const status = known ? error.status : 503;
    if (operation === 'status') {
        res.status(200).json({ available: false, apiVersion: API_VERSION, capabilities: CAPABILITIES,
            reason: 'Journey planning is temporarily unavailable.' });
        return;
    }
    if (status === 429) res.set('Retry-After', '5');
    res.status(status).json({ error: { code: known ? error.code : 'DATASET_UNAVAILABLE',
        message: known ? error.message : 'Journey planning is temporarily unavailable.' } });
}

export const plannerInternalHeaders = INTERNAL_HEADERS;
