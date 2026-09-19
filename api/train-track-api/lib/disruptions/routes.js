import express from 'express';
import { MonitorError } from './model.js';

export function registerDisruptionRoutes(app, monitor, { requestMiddleware, now = Date.now } = {}) {
    const router = express.Router(), callers = new Map();
    router.use((req, res, next) => {
        res.set('Cache-Control', 'no-store');
        if (req.method === 'PUT') {
            const key = req.ip || req.socket.remoteAddress || 'unknown', at = now();
            if (callers.size > 2048) for (const [id, entry] of callers) if (at - entry.at > 60000) callers.delete(id);
            const entry = callers.get(key);
            if (entry && at - entry.at < 60000 && entry.count >= 60 || callers.size >= 4096 && !entry) {
                res.set('Retry-After', '60'); return res.status(429).json({ error: { code: 'RATE_LIMITED', message: 'Please retry shortly.' } });
            }
            callers.set(key, entry && at - entry.at < 60000 ? { ...entry, count: entry.count + 1 } : { at, count: 1 });
        }
        next();
    });
    if (requestMiddleware) router.use(requestMiddleware);
    router.get('/', async (req, res, next) => {
        try { res.json(await monitor.get(req.query.device_id)); } catch (error) { next(error); }
    });
    router.get('/future', async (req, res, next) => {
        try {
            if (Object.keys(req.query).some(key => key !== 'stations')) throw new MonitorError('Supply only the journey stations.');
            res.json(await monitor.future(req.query.stations));
        } catch (error) { next(error); }
    });
    router.put('/monitors', (req, res, next) => {
        if (!req.is('application/json')) return next(new MonitorError('Send monitoring preferences as JSON.', 415));
        next();
    }, express.json({ limit: '64kb' }), async (req, res, next) => {
        try { res.json(await monitor.synchronize(req.body)); } catch (error) { next(error); }
    });
    router.use((error, req, res, next) => {
        if (res.headersSent) return next(error);
        const status = error instanceof MonitorError ? error.status
            : error.type === 'entity.too.large' ? 413 : error.type === 'entity.parse.failed' ? 400 : 503;
        res.status(status).json({ error: { code: error instanceof MonitorError ? error.code : status === 503 ? 'MONITOR_UNAVAILABLE' : 'INVALID_REQUEST',
            message: error instanceof MonitorError ? error.message : status === 503 ? 'Advance journey monitoring is temporarily unavailable.' : 'Supply valid monitoring preferences under 64 KB.' } });
    });
    app.use('/api/v2/disruptions', router);
    return monitor;
}
