import express from 'express';
import cors from 'cors';
import fs from 'fs';
import os from 'os';
import { getTrainTimes, refreshPastDepartures } from './lib/realtime-trains-api.js';
import { getServiceDetails } from './lib/service-details.js';
import { getXbarOutput } from './lib/xbar.js';
import { pastDeparturesCache } from './lib/past-departures-cache.js';
import {
    metricsMiddleware,
    getMetrics,
    recordPushTokenRegistration,
    updateNotificationSubscriptionGauges,
    updatePushSubscriptionGauges
} from './lib/metrics.js';
import { liveActivityManager } from './lib/live-activity-manager.js';
import { notificationSubscriptionManager } from './lib/notification-subscription-manager.js';
import { registerAdminRoutes } from './lib/admin-portal.js';
import { recordGeofenceEvent } from './lib/admin-data-store.js';
import path from 'path';

function isLiveActivityLoggingEnabled() {
    const flag = process.env.DEBUG_CONSOLE_LOGGING_APNS;
    return typeof flag === 'string' && flag.toLowerCase() === 'true';
}

function maskToken(token) {
    if (!token || typeof token !== 'string') return token;
    if (token.length <= 10) return `${token.slice(0, 3)}***`;
    return `${token.slice(0, 6)}...${token.slice(-4)}`;
}

function getFlyInstanceId() {
    return process.env.FLY_ALLOC_ID || process.env.HOSTNAME || 'unknown';
}

function logNotificationRequest(event, req, extra = {}) {
    const clientIp = req.headers['x-forwarded-for'] || req.ip || 'unknown';
    console.log(
        '[notifications]',
        event,
        JSON.stringify({
            instance_id: getFlyInstanceId(),
            path: req.path,
            method: req.method,
            clientIp,
            ...extra
        })
    );
}

function logLiveActivityRequest(event, req, extra = {}) {
    if (!isLiveActivityLoggingEnabled()) return;
    const clientIp = req.headers['x-forwarded-for'] || req.ip || 'unknown';
    console.log(
        `[live-activity] ${event}`,
        JSON.stringify({
            path: req.path,
            method: req.method,
            clientIp,
            ...extra
        })
    );
}

function logLiveActivityStartup() {
    const enabled = isLiveActivityLoggingEnabled();
    console.log(
        '[live-activity] debug_logging',
        JSON.stringify({
            enabled,
            env: process.env.DEBUG_CONSOLE_LOGGING_APNS || '<unset>'
        })
    );
}

const ENV_LOG_FILE_PATH = path.join(os.tmpdir(), 'train-track-api-env.log');
const DEBUG_ENV_KEYS = [
    'APNS_KEY_ID',
    'APNS_TEAM_ID',
    'LIVE_DEPARTURE_BOARD_API_KEY',
    'SERVICE_DETAILS_API_KEY'
];

function writeEnvironmentSnapshotToTempLog() {
    const trackedValues = Object.fromEntries(
        DEBUG_ENV_KEYS.map((key) => [key, process.env[key] ?? '<unset>'])
    );
    const allEnvVars = Object.fromEntries(
        Object.entries(process.env).sort(([left], [right]) => left.localeCompare(right))
    );

    const payload = {
        timestamp: new Date().toISOString(),
        pid: process.pid,
        instance_id: getFlyInstanceId(),
        tracked_values: trackedValues,
        env: allEnvVars
    };

    fs.appendFileSync(ENV_LOG_FILE_PATH, `${JSON.stringify(payload)}\n`, 'utf8');
    console.log(`[startup] wrote environment snapshot to ${ENV_LOG_FILE_PATH}`);
}

// Use Express to create a server
const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));

registerAdminRoutes(app);

// Live activity request logging middleware (only logs when DEBUG_CONSOLE_LOGGING_APNS=true)
app.use('/api/v2/live_activities', (req, res, next) => {
    if (!isLiveActivityLoggingEnabled()) return next();
    const body = req.body || {};
    const maskedBody = { ...body };
    if (maskedBody.live_activity_push_token) {
        maskedBody.live_activity_push_token = maskToken(maskedBody.live_activity_push_token);
    }
    console.log(
        '[live-activity] incoming',
        JSON.stringify({
            method: req.method,
            path: req.path,
            query: req.query,
            body: maskedBody
        })
    );
    next();
});

// Add metrics middleware to track all requests
app.use(metricsMiddleware);

app.get('/healthcheck', (req, res) => {
    res.json({ status: 'ok' });
});

app.get('/metrics', async (req, res) => {
    res.set('Content-Type', 'text/plain; version=0.0.4');
    updateNotificationSubscriptionGauges(notificationSubscriptionManager.getActiveCounts());
    updatePushSubscriptionGauges({
        notification: notificationSubscriptionManager.getSubscriptionCount(),
        liveActivity: liveActivityManager.getSubscriptionCount()
    });
    res.send(await getMetrics());
});

app.post('/api/v2/live_activities', async (req, res) => {
    const { device_id, activity_id, live_activity_push_token, from, to, use_sandbox, preferred_service_id, mute_on_arrival } = req.body || {};
    if (!device_id || !activity_id || !live_activity_push_token || !from || !to) {
        logLiveActivityRequest('register_failed_validation', req, {
            device_id,
            activity_id,
            from,
            to,
            preferred_service_id,
            token: maskToken(live_activity_push_token)
        });
        return res.status(400).json({ error: 'device_id, activity_id, live_activity_push_token, from, and to are required' });
    }

    logLiveActivityRequest('register', req, {
        device_id,
        activity_id,
        from,
        to,
        preferred_service_id,
        token: maskToken(live_activity_push_token),
        use_sandbox: Boolean(use_sandbox)
    });

    const subscription = liveActivityManager.registerSubscription({
        deviceId: device_id,
        activityId: activity_id,
        pushToken: live_activity_push_token,
        fromStation: from,
        toStation: to,
        preferredServiceId: preferred_service_id,
        useSandbox: Boolean(use_sandbox),
        muteOnArrival: mute_on_arrival === true || mute_on_arrival === 'true'
    });
    recordPushTokenRegistration({
        channel: 'live_activity',
        environment: Boolean(use_sandbox) ? 'sandbox' : 'prod'
    });

    let snapshot = { departures: [], fetchedAt: null };
    try {
        snapshot = await liveActivityManager.getDeparturesSnapshot(from, to, preferred_service_id);
    } catch (error) {
        console.error(`Failed to fetch departures for live activity registration: ${error?.message || error}`);
    }

    res.json({
        status: 'registered',
        poll_interval_seconds: Math.round(liveActivityManager.pollIntervalMs / 1000),
        apns_configured: liveActivityManager.pushClient.isConfigured(),
        subscription: {
            device_id,
            activity_id,
            from,
            to,
            preferred_service_id: subscription.preferredServiceId || null,
            last_push_at: subscription.lastPushAt,
            created_at: subscription.createdAt,
            scheduled_end_at: subscription.endAt
        },
        next_departures: snapshot.departures,
        last_updated: snapshot.fetchedAt
    });
});

app.delete('/api/v2/live_activities', async (req, res) => {
    const { device_id, activity_id } = req.body || {};
    if (!device_id || !activity_id) {
        logLiveActivityRequest('unregister_failed_validation', req, { device_id, activity_id });
        return res.status(400).json({ error: 'device_id and activity_id are required' });
    }

    logLiveActivityRequest('unregister', req, { device_id, activity_id });

    const removed = liveActivityManager.unregisterSubscription(device_id, activity_id);

    res.json({
        status: removed ? 'unregistered' : 'not_found',
        device_id,
        activity_id
    });
});

// Notification subscription endpoints
app.post('/api/v2/notifications/subscriptions', async (req, res) => {
    const {
        device_id,
        push_token,
        route_key,
        days_of_week,
        notification_types,
        legs,
        subscription_id,
        use_sandbox,
        mute_on_arrival
    } = req.body || {};

    logNotificationRequest('register', req, {
        device_id,
        route_key,
        subscription_id,
        days_of_week,
        notification_types,
        use_sandbox: Boolean(use_sandbox),
        mute_on_arrival: Boolean(mute_on_arrival),
        legs_count: Array.isArray(legs) ? legs.length : 0,
        push_token: maskToken(push_token)
    });

    try {
        const subscription = await notificationSubscriptionManager.upsertSubscription({
            deviceId: device_id,
            pushToken: push_token,
            routeKey: route_key,
            daysOfWeek: days_of_week,
            notificationTypes: notification_types,
            legs,
            subscriptionId: subscription_id,
            useSandbox: Boolean(use_sandbox),
            muteOnArrival: Boolean(mute_on_arrival)
        });
        recordPushTokenRegistration({
            channel: 'notification',
            environment: Boolean(use_sandbox) ? 'sandbox' : 'prod'
        });
        res.json({
            status: 'registered',
            poll_interval_seconds: Math.round(notificationSubscriptionManager.pollIntervalMs / 1000),
            subscription
        });
    } catch (error) {
        logNotificationRequest('register_failed', req, {
            device_id,
            route_key,
            error: error?.message || error
        });
        res.status(400).json({ error: error?.message || error });
    }
});

app.get('/api/v2/notifications/subscriptions', (req, res) => {
    const { device_id } = req.query || {};
    logNotificationRequest('list', req, { device_id });
    if (!device_id) {
        return res.status(400).json({ error: 'device_id is required' });
    }
    const subscriptions = notificationSubscriptionManager.listSubscriptions(device_id);
    res.json({ subscriptions });
});

app.delete('/api/v2/notifications/subscriptions', async (req, res) => {
    const { device_id, subscription_id } = req.body || {};
    logNotificationRequest('delete', req, { device_id, subscription_id });
    if (!device_id || !subscription_id) {
        return res.status(400).json({ error: 'device_id and subscription_id are required' });
    }
    const removed = await notificationSubscriptionManager.deleteSubscription({
        deviceId: device_id,
        subscriptionId: subscription_id
    });
    res.json({ status: removed ? 'deleted' : 'not_found' });
});

app.post('/api/v2/notifications/terminate', async (req, res) => {
    const { device_id, subscription_id, from, to, date } = req.body || {};
    logNotificationRequest('terminate', req, {
        device_id,
        subscription_id,
        from,
        to,
        date
    });
    if (!device_id || !subscription_id || !from || !to) {
        return res.status(400).json({
            error: 'device_id, subscription_id, from, and to are required'
        });
    }
    const result = await notificationSubscriptionManager.muteLegForDate({
        deviceId: device_id,
        subscriptionId: subscription_id,
        from,
        to,
        date
    });
    if (!result) {
        return res.status(404).json({ error: 'Subscription or leg not found' });
    }
    res.json({ status: 'muted', date: result });
});

app.post('/api/v2/notifications/geofence-event', async (req, res) => {
    const { device_id, timestamp, event, region_id, from, to } = req.body || {};
    const ip = req.headers['x-forwarded-for'] || req.ip || null;
    logNotificationRequest('geofence_event', req, { device_id, event, from, to });
    await recordGeofenceEvent({ deviceId: device_id, clientTimestamp: timestamp, event, regionId: region_id, from, to, ip });
    res.json({ status: 'ok' });
});

// Debug notification endpoints
app.get('/api/v2/notifications/debug/subscriptions', (req, res) => {
    logNotificationRequest('debug_list', req);
    res.json({ subscriptions: notificationSubscriptionManager.listAllSubscriptions() });
});

app.delete('/api/v2/notifications/debug/subscriptions', async (req, res) => {
    const { subscription_id } = req.body || {};
    logNotificationRequest('debug_delete', req, { subscription_id });
    if (!subscription_id) {
        return res.status(400).json({ error: 'subscription_id is required' });
    }
    const removed = await notificationSubscriptionManager.deleteSubscription({ subscriptionId: subscription_id });
    res.json({ status: removed ? 'deleted' : 'not_found' });
});

// Debug utility endpoints to manually inspect/trigger Live Activity pushes
app.get('/api/v2/live_activities/debug/subscriptions', (req, res) => {
    logLiveActivityRequest('list_subscriptions', req, {});
    res.json({ subscriptions: liveActivityManager.listSubscriptions() });
});

app.post('/api/v2/live_activities/debug/trigger', async (req, res) => {
    const { device_id, activity_id, dry_run } = req.body || {};
    if (!device_id || !activity_id) {
        logLiveActivityRequest('debug_trigger_failed_validation', req, { device_id, activity_id });
        return res.status(400).json({ error: 'device_id and activity_id are required' });
    }

    const subscription = liveActivityManager.getSubscription(device_id, activity_id);
    if (!subscription) {
        logLiveActivityRequest('debug_trigger_missing_subscription', req, { device_id, activity_id });
        return res.status(404).json({ error: 'No live activity subscription found for that device/activity' });
    }

    logLiveActivityRequest('debug_trigger', req, {
        device_id,
        activity_id,
        dry_run: Boolean(dry_run)
    });

    try {
        const result = await liveActivityManager.pollSubscription(subscription, { force: true, dryRun: Boolean(dry_run) });
        res.json({
            status: result.sent ? 'pushed' : 'skipped',
            reason: result.reason || null,
            snapshot: result.snapshot,
            payload: result.payload,
            push_response: result.pushResponse
        });
    } catch (error) {
        const message = error?.message || error;
        console.error(`Manual live activity trigger failed: ${message}`);
        res.status(500).json({ error: message });
    }
});

app.get('/api/v1/departures/from/:fromStation', async (req, res) => {
    res.json(await getTrainTimes(req.params.fromStation));
});

// V1 API - Original format for backward compatibility
app.get('/api/v1/departures/from/:fromStation/to/:toStation', async (req, res) => {
    res.json(await getTrainTimes(req.params.fromStation, req.params.toStation));
});

// V2 API - New array format supporting multiple journeys
app.get('/api/v2/departures/from/:fromStation/to/:toStation*', async (req, res) => {
    const path = req.path;

    // Parse the path to extract multiple from/to pairs
    // Example: /api/v2/departures/from/ECR/to/VIC/from/EUS/to/WFJ
    const pathParts = path.split('/').filter(part => part.length > 0);

    const journeyPairs = [];
    let currentFrom = null;

    for (let i = 0; i < pathParts.length; i++) {
        if (pathParts[i] === 'from' && i + 1 < pathParts.length) {
            currentFrom = pathParts[i + 1];
            i++; // Skip the station code
        } else if (pathParts[i] === 'to' && i + 1 < pathParts.length && currentFrom) {
            const to = pathParts[i + 1];
            journeyPairs.push({ from: currentFrom, to });
            currentFrom = null;
            i++; // Skip the station code
        }
    }

    // If no valid pairs found, return error
    if (journeyPairs.length === 0) {
        return res.status(400).json({ error: 'No valid from/to pairs found in request' });
    }

    // Fetch all journeys in parallel and return as array
    const results = await Promise.all(
        journeyPairs.map(async (pair) => {
            const data = await getTrainTimes(pair.from, pair.to);
            const key = `${pair.from}_${pair.to}`;
            return { [key]: data.departures || [] };
        })
    );
    res.json(results);
});

app.get('/api/v1/departures/past/from/:fromStation/to/:toStation', async (req, res) => {
    const from = req.params.fromStation;
    const to = req.params.toStation;
    // Serve immediately from cache to avoid client timeouts/cancellations
    const pastDepartures = pastDeparturesCache.getPastDepartures(from, to);
    res.json({ departures: pastDepartures });
    // Kick off a lightweight, deduped background refresh of the cache
    refreshPastDepartures(from, to).catch((e) => {
        const message = e?.message || e;
        console.error(`Background refresh for past departures failed ${from} -> ${to}: ${message}`);
    });
});

app.get('/api/v1/departures/past', async (req, res) => {
    const allPastDepartures = pastDeparturesCache.getAllPastDepartures();
    res.json({ 
        departures: allPastDepartures,
        cacheSize: pastDeparturesCache.getCacheSize(),
        timestamp: new Date().toISOString()
    });
});

app.get('/api/v1/departures/past/all', async (req, res) => {
    const allCacheContents = pastDeparturesCache.getAllCacheContents();
    res.json({ 
        departures: allCacheContents,
        cacheSize: pastDeparturesCache.getCacheSize(),
        timestamp: new Date().toISOString()
    });
});

// Sample data route must be defined before the catch-all service_details routes
app.get('/api/v1/service_details/sample_data/train_divides', async (req, res) => {
    // Serve up the sample data file from train_divides.json as JSON, using the relative filepath
    res.setHeader('Content-Type', 'application/json');
    // Get the script directory
    const __dirname = path.resolve();
    res.sendFile(path.join(__dirname, 'sample_data', 'train_divides.json'));
});

// V1 API - Original format for backward compatibility
app.get('/api/v1/service_details/:serviceId', async (req, res) => {
    const serviceDetails = await getServiceDetails(req.params.serviceId);
    // If we get an error response, then log the error and return a 404 status
    if (serviceDetails.error) {
        console.error(`Failed to get service details for ID ${req.params.serviceId}: ${serviceDetails.error}`);
        res.status(404).json({ error: 'Service not found' });
    }
    else {
        res.json(serviceDetails);
    }
});

// V2 API - New array format supporting multiple service IDs
app.get('/api/v2/service_details/:serviceId*', async (req, res) => {
    const path = req.path;

    // Parse the path to extract multiple service IDs
    // Example: /api/v2/service_details/1729980EUSTON__/1729976EUSTON__/1729978EUSTON__
    const pathParts = path.split('/').filter(part => part.length > 0);

    // Find the index of 'service_details' and collect all parts after it as service IDs
    const serviceDetailsIndex = pathParts.indexOf('service_details');
    const serviceIds = serviceDetailsIndex !== -1 ? pathParts.slice(serviceDetailsIndex + 1) : [];

    // If no service IDs found, return error
    if (serviceIds.length === 0) {
        return res.status(400).json({ error: 'No service ID provided' });
    }

    // Fetch all service IDs in parallel and return as array
    const results = await Promise.all(
        serviceIds.map(async (serviceId) => {
            const serviceDetails = await getServiceDetails(serviceId);
            // If error, return empty object for this service
            if (serviceDetails.error) {
                console.error(`Failed to get service details for ID ${serviceId}: ${serviceDetails.error}`);
                return { [serviceId]: {} };
            }
            return { [serviceId]: serviceDetails };
        })
    );
    res.json(results);
});

// V2 API - Stations endpoint
app.get('/api/v2/stations', async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    const __dirname = path.resolve();
    res.sendFile(path.join(__dirname, 'resources', 'stations.json'));
});

app.get('/api/v1/xbar/from/:fromStation/to/:toStation/max_departures/:maxDepartures/return_after/:returnAfter?', async (req, res) => {
    res.send(await getXbarOutput(req.params.fromStation, req.params.toStation, req.params.maxDepartures, req.params.returnAfter));
});

// Hydrate subscription state from Redis before accepting requests.
await notificationSubscriptionManager.init();

const port = process.env.PORT || 3012;
app.listen(port, () => {
    console.log(`Server running on port ${port}`);
    logLiveActivityStartup();
    writeEnvironmentSnapshotToTempLog();
});
