#!/usr/bin/env node
import express from 'express';
import { pathToFileURL } from 'node:url';
import { PlannerService, plannerConfig } from './lib/planner/service.js';
import { registerPlannerRoutes } from './lib/planner-routes.js';
import { PlannerRouteBoards } from './lib/planner/route-boards.js';
import { SavedRouteBoards } from './lib/planner/saved-route-boards.js';
import { RouteBoardCache } from './lib/planner/route-board-cache.js';
import { noOpPlannerSearchLog, PlannerSearchLog, listPlannerSearchLogs } from './lib/planner-search-log.js';
import { registerPlannerInternalRoutes, plannerServiceAuthentication } from './lib/planner-internal-routes.js';
import { trustedPlannerCaller } from './lib/planner-gateway.js';
import { startTimetableIngestion } from './lib/planner/ingestion-scheduler.js';
import { timetableIngestionConfig } from './lib/planner/ingestion-source.js';
import { closeMongoClient, getMongoDb, ensurePlannerMongoIndexes } from './lib/mongo-client.js';
import { getMetrics, metricsMiddleware, recordPlannerRequest } from './lib/metrics.js';

export async function createPlannerServer({ env = process.env, service, searchLog, initializeMongo } = {}) {
    const hostId = required(env.PLANNER_HOST_ID, 'PLANNER_HOST_ID');
    const token = required(env.PLANNER_SERVICE_TOKEN, 'PLANNER_SERVICE_TOKEN', 16);
    if (!['true', 'false'].includes(env.PLANNER_INGESTION_ENABLED ?? '')) {
        throw new Error('PLANNER_INGESTION_ENABLED must explicitly be true or false for the standalone planner.');
    }
    const persistenceMode = env.PLANNER_PERSISTENCE_MODE || 'mongo';
    if (!['mongo', 'memory'].includes(persistenceMode)) {
        throw new Error('PLANNER_PERSISTENCE_MODE must be mongo or memory.');
    }
    if (env.NODE_ENV === 'production' && persistenceMode === 'mongo'
        && !(env.MONGODB_URI_JOURNEY_PLANNER || env.MONGODB_URI_TRAIN_TRACK_UK)) {
        throw new Error('MONGODB_URI_JOURNEY_PLANNER is required for the production standalone planner.');
    }
    const useMongo = initializeMongo ?? persistenceMode === 'mongo';
    const config = plannerConfig(env);
    const planner = service ?? new PlannerService(config);
    const logger = searchLog ?? (persistenceMode === 'memory' ? noOpPlannerSearchLog
        : new PlannerSearchLog({ host: hostId, buildRevision: env.BUILD_REVISION || null }));
    if (useMongo) {
        await (await getMongoDb()).command({ ping: 1 }, { timeoutMS: 2000 });
        await ensurePlannerMongoIndexes();
    }
    const app = express();
    let draining = false;
    app.disable('x-powered-by');
    // Loopback deployment probes need process liveness without receiving the
    // service credential. No planner state or internal operation is exposed.
    app.get('/healthcheck', (_req, res) => res.set('Cache-Control', 'no-store').json({ status: 'ok' }));
    app.use(plannerServiceAuthentication(token));
    app.use((_req, res, next) => {
        if (!draining) return next();
        res.set('Cache-Control', 'no-store').status(503).json({ error: {
            code: 'DATASET_UNAVAILABLE', message: 'Journey planning is shutting down.'
        } });
    });
    const routeComposition = persistenceMode === 'memory' ? {
        routeBoards: new PlannerRouteBoards(planner, { searchLog: logger,
            cache: new RouteBoardCache({ collection: null }) }),
        savedRouteBoards: new SavedRouteBoards(planner, { searchLog: logger,
            cache: new RouteBoardCache({ collection: null, maxEntries: 64, maxBytes: 8 * 1024 * 1024 }) })
    } : {};
    registerPlannerRoutes(app, { service: planner, searchLog: logger, recordRequest: recordPlannerRequest,
        requestMiddleware: metricsMiddleware, resolveCaller: trustedPlannerCaller, ...routeComposition });
    registerPlannerInternalRoutes(app, { service: planner, hostId, buildRevision: env.BUILD_REVISION || null,
        listSearches: persistenceMode === 'mongo' ? listPlannerSearchLogs : undefined, getMetrics });
    const ingestionConfig = timetableIngestionConfig(env);
    const ingestion = startTimetableIngestion({ config: ingestionConfig });
    let server = null, closing = null;
    const close = () => {
        if (closing) return closing;
        closing = (async () => {
            draining = true;
            ingestion.stop();
            if (server) await Promise.race([
                new Promise(resolve => server.close(resolve)), new Promise(resolve => setTimeout(resolve, 5000))
            ]);
            planner.close();
            await logger.close?.({ timeoutMs: 3000 });
            if (useMongo) await closeMongoClient();
        })();
        return closing;
    };
    const listen = () => {
        const port = validPort(env.PORT ?? '3014');
        const host = env.PLANNER_LISTEN_HOST || '127.0.0.1';
        server = app.listen(port, host, () => console.log(`[planner] listening on http://${host}:${port} as ${hostId}`));
        return server;
    };
    return { app, service: planner, searchLog: logger, ingestion, persistenceMode, listen, close,
        get server() { return server; } };
}

async function main() {
    const runtime = await createPlannerServer();
    runtime.listen();
    let stopping = false;
    for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, async () => {
        if (stopping) return;
        stopping = true;
        await runtime.close();
        process.exit(signal === 'SIGINT' ? 130 : 0);
    });
}

function required(value, name, minimum = 1) {
    if (typeof value !== 'string' || value.length < minimum) throw new Error(`${name} is required.`);
    return value;
}
function validPort(value) {
    const port = Number(value);
    if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be a valid TCP port.');
    return port;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main().catch(error => { console.error('[planner] startup failed:', error?.message || error); process.exitCode = 1; });
}
