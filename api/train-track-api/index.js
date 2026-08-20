import express from 'express';
import cors from 'cors';
import fs from 'fs';
import { getTrainTimes, refreshPastDepartures } from './lib/realtime-trains-api.js';
import { getServiceDetails, getServiceDetailsWithContext } from './lib/service-details.js';
import { getXbarOutput } from './lib/xbar.js';
import { pastDeparturesCache } from './lib/past-departures-cache.js';
import {
    metricsMiddleware,
    getMetrics,
    forgetDeviceLastSeen,
    recordPushTokenRegistration,
    updateNotificationSubscriptionGauges,
    updatePushSubscriptionGauges
} from './lib/metrics.js';
import { liveActivityManager } from './lib/live-activity-manager.js';
import { notificationSubscriptionManager } from './lib/notification-subscription-manager.js';
import { journeyTrackingManager } from './lib/journey-tracking-manager.js';
import { registerAdminRoutes } from './lib/admin-portal.js';
import { listSubscriptionAuditEvents, recordDevicePreferences, recordGeofenceEvent } from './lib/admin-data-store.js';
import { pushToStartTokenStore } from './lib/push-to-start-token-store.js';
import { testServiceHarness } from './lib/test-service-harness.js';
import { formatDepartureJourneyResult, shouldIncludeDepartureStatus } from './lib/departure-response.js';
import { ensureMongoIndexes } from './lib/mongo-client.js';
import { resolveDelayRepayOperator } from './lib/delay-repay-config.js';
import {
    deleteSubscriptionAuditEventsForDevice,
    startSubscriptionAuditLogMaintenance
} from './lib/subscription-audit-log.js';
import { DeviceDataDeletionService } from './lib/device-data-deletion.js';
import { registerDeviceDataDeletionRoute } from './lib/device-data-route.js';
import {
    finishDeviceDataDeletion,
    markDeviceDataDeleted
} from './lib/device-data-deletion-state.js';
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

function normalizeDeviceId(value) {
    return typeof value === 'string' ? value.trim() : '';
}

function resolveRequestDeviceIds(req, deviceId) {
    const bodyDeviceId = normalizeDeviceId(deviceId);
    const headerDeviceId = normalizeDeviceId(req.get('X-Device-Token'));
    const canonicalDeviceId = headerDeviceId || bodyDeviceId;
    const fallbackDeviceIds = bodyDeviceId && headerDeviceId && bodyDeviceId !== headerDeviceId
        ? [bodyDeviceId]
        : [];

    return {
        canonicalDeviceId,
        bodyDeviceId: bodyDeviceId || null,
        headerDeviceId: headerDeviceId || null,
        fallbackDeviceIds,
        hasMismatch: fallbackDeviceIds.length > 0
    };
}

function getInstanceId() {
    return process.env.HOSTNAME || 'unknown';
}

function logNotificationRequest(event, req, extra = {}) {
    const clientIp = req.headers['x-forwarded-for'] || req.ip || 'unknown';
    console.log(
        '[notifications]',
        event,
        JSON.stringify({
            instance_id: getInstanceId(),
            path: req.path,
            method: req.method,
            clientIp,
            ...extra
        })
    );
}

function buildRequestAuditContext(req) {
    if (!req) return null;
    return {
        instance_id: getInstanceId(),
        path: req.path,
        method: req.method,
        clientIp: req.headers?.['x-forwarded-for'] || req.ip || 'unknown',
        user_agent: req.headers?.['user-agent'] || null
    };
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

function logDepartureRequest(event, req, extra = {}) {
    const clientIp = req.headers['x-forwarded-for'] || req.ip || 'unknown';
    console.log(
        '[departures]',
        event,
        JSON.stringify({
            instance_id: getInstanceId(),
            path: req.path,
            method: req.method,
            clientIp,
            ...extra
        })
    );
}

function normalizeDepartureTime(value) {
    return typeof value === 'string' ? value.trim() : '';
}

function isValidDepartureTime(value) {
    return /^\d{2}:\d{2}$/.test(normalizeDepartureTime(value));
}

function isDebugBuildRequest(req) {
    const value = req.get('X-Debug-Build');
    return typeof value === 'string' && ['1', 'true', 'yes'].includes(value.trim().toLowerCase());
}

function findDepartureByTime(departures, departureTime) {
    if (!Array.isArray(departures)) {
        return null;
    }

    const normalizedDepartureTime = normalizeDepartureTime(departureTime);
    return departures.find((departure) => departure?.departure_time?.scheduled === normalizedDepartureTime)
        || departures.find((departure) => departure?.departure_time?.estimated === normalizedDepartureTime)
        || null;
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

function getApnsConfigurationState() {
    const notificationConfigured = notificationSubscriptionManager.pushClient.isConfigured();
    const liveActivityConfigured = liveActivityManager.pushClient.isConfigured();
    const authKeyInlinePresent = Boolean(process.env.APNS_AUTH_KEY);
    const authKeyPath = process.env.APNS_AUTH_KEY_PATH || path.join(process.cwd(), 'certs', 'APNS_AuthKey_SkyNoLimit_SandboxAndProd.p8');
    const authKeyFilePresent = fs.existsSync(authKeyPath);

    return {
        notificationConfigured,
        liveActivityConfigured,
        authKeyInlinePresent,
        authKeyPath,
        authKeyFilePresent
    };
}

// Use Express to create a server
const app = express();
app.use(cors());
app.use(express.json({ limit: '1mb' }));
app.use(express.urlencoded({ extended: false, limit: '1mb' }));

registerAdminRoutes(app);

// Live activity request logging middleware (only logs when DEBUG_CONSOLE_LOGGING_APNS=true)
app.use('/api/v2/live_activities', (req, res, next) => {
    if (!isLiveActivityLoggingEnabled()) return next();
    const body = req.body || {};
    const maskedBody = { ...body };
    if (maskedBody.live_activity_push_token) {
        maskedBody.live_activity_push_token = maskToken(maskedBody.live_activity_push_token);
    }
    if (maskedBody.push_to_start_token) {
        maskedBody.push_to_start_token = maskToken(maskedBody.push_to_start_token);
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

const deviceDataDeletionService = new DeviceDataDeletionService({
    purgeRuntimeState: async (deviceId) => {
        const notification = await notificationSubscriptionManager.purgeDeviceRuntimeState(deviceId);
        const liveActivities = await liveActivityManager.purgeDeviceRuntimeState(deviceId);
        const journeyTracking = await journeyTrackingManager.purgeDeviceRuntimeState(deviceId);
        return {
            notificationSubscriptions: notification.subscriptions,
            holidayMode: notification.holidayMode ? 1 : 0,
            liveActivitySessions: liveActivities,
            journeyTrackingSessions: journeyTracking
        };
    },
    deleteAuditLogEntries: deleteSubscriptionAuditEventsForDevice,
    markDeviceDataDeleted,
    finishDeviceDataDeletion,
    forgetDeviceLastSeen
});
registerDeviceDataDeletionRoute(app, deviceDataDeletionService);

app.get('/healthcheck', (req, res) => {
    const apnsConfig = getApnsConfigurationState();
    res.json({
        status: 'ok',
        apns: {
            notification_configured: apnsConfig.notificationConfigured,
            live_activity_configured: apnsConfig.liveActivityConfigured,
            auth_key_inline_present: apnsConfig.authKeyInlinePresent,
            auth_key_path: apnsConfig.authKeyPath,
            auth_key_file_present: apnsConfig.authKeyFilePresent
        }
    });
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

app.post('/api/v2/device_preferences', async (req, res) => {
    const { device_id, preferences } = req.body || {};
    const { canonicalDeviceId, bodyDeviceId, headerDeviceId, hasMismatch } = resolveRequestDeviceIds(req, device_id);
    if (!canonicalDeviceId) {
        return res.status(400).json({ error: 'device_id is required' });
    }
    if (!preferences || typeof preferences !== 'object' || Array.isArray(preferences)) {
        return res.status(400).json({ error: 'preferences object is required' });
    }

    try {
        const record = await recordDevicePreferences({
            deviceId: canonicalDeviceId,
            preferences
        });
        res.json({
            status: 'ok',
            device_id: record.device_id,
            updated_at: record.updated_at,
            body_device_id: bodyDeviceId,
            header_device_id: headerDeviceId,
            device_id_mismatch: hasMismatch
        });
    } catch (error) {
        console.error('[preferences] Failed to persist device preferences:', error?.message || error);
        res.status(500).json({ error: error?.message || error });
    }
});

app.post('/api/v2/live_activities', async (req, res) => {
    const {
        device_id,
        activity_id,
        live_activity_push_token,
        from,
        to,
        display_name,
        deep_link_from,
        deep_link_to,
        use_sandbox,
        preferred_service_id,
        mute_on_arrival,
        mute_delay_minutes,
        auto_end_on_arrival,
        auto_end_on_departure,
        journey_phase,
        schedule_key,
        journey_updates_enabled,
        window_start,
        window_end
    } = req.body || {};
    const { canonicalDeviceId, bodyDeviceId, headerDeviceId, hasMismatch } = resolveRequestDeviceIds(req, device_id);
    if (!canonicalDeviceId || !activity_id || !live_activity_push_token || !from || !to) {
        logLiveActivityRequest('register_failed_validation', req, {
            device_id: canonicalDeviceId || bodyDeviceId,
            body_device_id: bodyDeviceId,
            header_device_id: headerDeviceId,
            activity_id,
            from,
            to,
            preferred_service_id,
            token: maskToken(live_activity_push_token)
        });
        return res.status(400).json({ error: 'device_id, activity_id, live_activity_push_token, from, and to are required' });
    }

    logLiveActivityRequest('register', req, {
        device_id: canonicalDeviceId,
        body_device_id: bodyDeviceId,
        header_device_id: headerDeviceId,
        device_id_mismatch: hasMismatch,
        activity_id,
        from,
        to,
        display_name,
        deep_link_from,
        deep_link_to,
        preferred_service_id,
        token: maskToken(live_activity_push_token),
        use_sandbox: Boolean(use_sandbox)
    });

    let subscription;
    try {
        subscription = liveActivityManager.registerSubscription({
            deviceId: canonicalDeviceId,
            activityId: activity_id,
            pushToken: live_activity_push_token,
            fromStation: from,
            toStation: to,
            displayName: typeof display_name === 'string' ? display_name : null,
            deepLinkFromStation: typeof deep_link_from === 'string' ? deep_link_from : null,
            deepLinkToStation: typeof deep_link_to === 'string' ? deep_link_to : null,
            preferredServiceId: preferred_service_id,
            useSandbox: Boolean(use_sandbox),
            muteOnArrival: mute_on_arrival === true || mute_on_arrival === 'true',
            muteDelayMinutes: mute_delay_minutes !== undefined ? Number(mute_delay_minutes) : undefined,
            autoEndOnArrival: auto_end_on_arrival === true || auto_end_on_arrival === 'true',
            autoEndOnDeparture: auto_end_on_departure === true || auto_end_on_departure === 'true',
            journeyPhase: typeof journey_phase === 'string' ? journey_phase : null,
            scheduleKey: typeof schedule_key === 'string' ? schedule_key : null,
            journeyUpdatesEnabled: journey_updates_enabled === undefined ? undefined : (journey_updates_enabled === true || journey_updates_enabled === 'true'),
            windowStart: typeof window_start === 'string' ? window_start : null,
            windowEnd: typeof window_end === 'string' ? window_end : null
        });
    } catch (error) {
        const deletionInProgress = error?.message === 'Device data deletion is in progress';
        return res.status(deletionInProgress ? 409 : 400).json({
            error: deletionInProgress ? error.message : 'Unable to register Live Activity'
        });
    }
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
            device_id: canonicalDeviceId,
            activity_id,
            from,
            to,
            display_name: subscription.displayName || null,
            deep_link_from: subscription.deepLinkFromStation || null,
            deep_link_to: subscription.deepLinkToStation || null,
            preferred_service_id: subscription.preferredServiceId || null,
            last_push_at: subscription.lastPushAt,
            created_at: subscription.createdAt,
            scheduled_end_at: subscription.endAt
        },
        next_departures: snapshot.departures,
        last_updated: snapshot.fetchedAt
    });
});

app.post('/api/v2/live_activities/push_to_start_tokens', async (req, res) => {
    const { device_id, push_to_start_token, use_sandbox } = req.body || {};
    const { canonicalDeviceId, bodyDeviceId, headerDeviceId, hasMismatch } = resolveRequestDeviceIds(req, device_id);

    if (!canonicalDeviceId || !push_to_start_token) {
        logLiveActivityRequest('push_to_start_register_failed_validation', req, {
            device_id: canonicalDeviceId || bodyDeviceId,
            body_device_id: bodyDeviceId,
            header_device_id: headerDeviceId,
            push_to_start_token: maskToken(push_to_start_token)
        });
        return res.status(400).json({ error: 'device_id and push_to_start_token are required' });
    }

    logLiveActivityRequest('push_to_start_register', req, {
        device_id: canonicalDeviceId,
        body_device_id: bodyDeviceId,
        header_device_id: headerDeviceId,
        device_id_mismatch: hasMismatch,
        push_to_start_token: maskToken(push_to_start_token),
        use_sandbox: Boolean(use_sandbox)
    });

    try {
        const record = await pushToStartTokenStore.upsert({
            deviceId: canonicalDeviceId,
            pushToStartToken: push_to_start_token,
            useSandbox: Boolean(use_sandbox)
        });
        recordPushTokenRegistration({
            channel: 'live_activity',
            environment: record.useSandbox ? 'sandbox' : 'prod'
        });
        res.json({
            status: 'registered',
            device_id: record.deviceId,
            use_sandbox: record.useSandbox,
            updated_at: record.updatedAt
        });
    } catch (error) {
        logLiveActivityRequest('push_to_start_register_failed', req, {
            device_id: canonicalDeviceId,
            error: error?.message || error
        });
        res.status(500).json({ error: error?.message || error });
    }
});

app.delete('/api/v2/live_activities', async (req, res) => {
    const { device_id, activity_id, preserve_notification_live_session } = req.body || {};
    const { canonicalDeviceId, bodyDeviceId, headerDeviceId, fallbackDeviceIds, hasMismatch } = resolveRequestDeviceIds(req, device_id);
    if (!canonicalDeviceId || !activity_id) {
        logLiveActivityRequest('unregister_failed_validation', req, {
            device_id: canonicalDeviceId || bodyDeviceId,
            body_device_id: bodyDeviceId,
            header_device_id: headerDeviceId,
            activity_id
        });
        return res.status(400).json({ error: 'device_id and activity_id are required' });
    }

    logLiveActivityRequest('unregister', req, {
        device_id: canonicalDeviceId,
        body_device_id: bodyDeviceId,
        header_device_id: headerDeviceId,
        device_id_mismatch: hasMismatch,
        activity_id,
        preserve_notification_live_session: preserve_notification_live_session === true || preserve_notification_live_session === 'true'
    });

    const removedSubscription = liveActivityManager.unregisterSubscription(canonicalDeviceId, activity_id, {
        fallbackDeviceIds,
        preserveNotificationLiveSession: preserve_notification_live_session === true || preserve_notification_live_session === 'true'
    });

    res.json({
        status: removedSubscription ? 'unregistered' : 'not_found',
        device_id: canonicalDeviceId,
        activity_id
    });
});

app.post('/api/v2/live_activities/checkin', async (req, res) => {
    const { device_id, force_refresh } = req.body || {};
    const { canonicalDeviceId, bodyDeviceId, headerDeviceId, fallbackDeviceIds, hasMismatch } = resolveRequestDeviceIds(req, device_id);
    if (!canonicalDeviceId) {
        logLiveActivityRequest('checkin_failed_validation', req, {
            device_id: canonicalDeviceId || bodyDeviceId,
            body_device_id: bodyDeviceId,
            header_device_id: headerDeviceId
        });
        return res.status(400).json({ error: 'device_id is required' });
    }

    logLiveActivityRequest('checkin', req, {
        device_id: canonicalDeviceId,
        body_device_id: bodyDeviceId,
        header_device_id: headerDeviceId,
        device_id_mismatch: hasMismatch,
        force_refresh: force_refresh !== false
    });

    try {
        const result = await liveActivityManager.handleDeviceCheckIn(canonicalDeviceId, {
            forceRefresh: force_refresh !== false,
            fallbackDeviceIds,
            canonicalDeviceId
        });
        res.json({
            status: 'ok',
            device_id: canonicalDeviceId,
            ...result
        });
    } catch (error) {
        const message = error?.message || error;
        console.error(`[live-activity] checkin failed for ${canonicalDeviceId}: ${message}`);
        res.status(500).json({ error: message });
    }
});

app.post('/api/v2/live_activities/arrive', async (req, res) => {
    const { device_id, from, to } = req.body || {};
    const { canonicalDeviceId, bodyDeviceId, headerDeviceId, fallbackDeviceIds, hasMismatch } = resolveRequestDeviceIds(req, device_id);
    if (!canonicalDeviceId) {
        logLiveActivityRequest('arrive_failed_validation', req, {
            device_id: canonicalDeviceId || bodyDeviceId,
            body_device_id: bodyDeviceId,
            header_device_id: headerDeviceId
        });
        return res.status(400).json({ error: 'device_id is required' });
    }

    logLiveActivityRequest('arrive', req, {
        device_id: canonicalDeviceId,
        body_device_id: bodyDeviceId,
        header_device_id: headerDeviceId,
        device_id_mismatch: hasMismatch,
        from,
        to
    });

    try {
        const result = await liveActivityManager.handleArrival(canonicalDeviceId, {
            fromStation: from || null,
            toStation: to || null,
            fallbackDeviceIds
        });
        res.json({
            status: 'ok',
            device_id: canonicalDeviceId,
            ...result
        });
    } catch (error) {
        const message = error?.message || error;
        console.error(`[live-activity] arrive failed for ${canonicalDeviceId}: ${message}`);
        res.status(500).json({ error: message });
    }
});

app.post('/api/v2/live_activities/depart', async (req, res) => {
    const { device_id, from, to } = req.body || {};
    const { canonicalDeviceId, bodyDeviceId, headerDeviceId, fallbackDeviceIds, hasMismatch } = resolveRequestDeviceIds(req, device_id);
    if (!canonicalDeviceId) {
        logLiveActivityRequest('depart_failed_validation', req, {
            device_id: canonicalDeviceId || bodyDeviceId,
            body_device_id: bodyDeviceId,
            header_device_id: headerDeviceId
        });
        return res.status(400).json({ error: 'device_id is required' });
    }

    logLiveActivityRequest('depart', req, {
        device_id: canonicalDeviceId,
        body_device_id: bodyDeviceId,
        header_device_id: headerDeviceId,
        device_id_mismatch: hasMismatch,
        from,
        to
    });

    try {
        const result = await liveActivityManager.handleDeparture(canonicalDeviceId, {
            fromStation: from || null,
            toStation: to || null,
            fallbackDeviceIds
        });
        res.json({
            status: 'ok',
            device_id: canonicalDeviceId,
            ...result
        });
    } catch (error) {
        const message = error?.message || error;
        console.error(`[live-activity] depart failed for ${canonicalDeviceId}: ${message}`);
        res.status(500).json({ error: message });
    }
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

    const apnsConfig = getApnsConfigurationState();
    if (!apnsConfig.notificationConfigured || !apnsConfig.liveActivityConfigured) {
        const error = 'Journey updates are temporarily unavailable because APNs credentials are not configured on the server.';
        logNotificationRequest('register_unavailable', req, {
            device_id,
            route_key,
            notification_apns_configured: apnsConfig.notificationConfigured,
            live_activity_apns_configured: apnsConfig.liveActivityConfigured,
            auth_key_inline_present: apnsConfig.authKeyInlinePresent,
            auth_key_path: apnsConfig.authKeyPath,
            auth_key_file_present: apnsConfig.authKeyFilePresent
        });
        return res.status(503).json({ error });
    }

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
            muteOnArrival: Boolean(mute_on_arrival),
            source: 'scheduled',
            auditContext: buildRequestAuditContext(req)
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
    const subscriptions = notificationSubscriptionManager.listSubscriptions(device_id, { source: 'scheduled' });
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
        subscriptionId: subscription_id,
        reason: 'api_delete_scheduled_subscription',
        metadata: { request: buildRequestAuditContext(req) }
    });
    res.json({ status: removed ? 'deleted' : 'not_found' });
});

app.post('/api/v2/notifications/live_sessions', async (req, res) => {
    const {
        device_id,
        push_token,
        route_key,
        days_of_week,
        notification_types,
        legs,
        subscription_id,
        use_sandbox,
        mute_on_arrival,
        live_session_origin,
        active_until
    } = req.body || {};

    logNotificationRequest('register_live_session', req, {
        device_id,
        route_key,
        subscription_id,
        notification_types,
        use_sandbox: Boolean(use_sandbox),
        mute_on_arrival: Boolean(mute_on_arrival),
        live_session_origin,
        active_until,
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
            muteOnArrival: Boolean(mute_on_arrival),
            source: 'live_session',
            liveSessionOrigin: live_session_origin,
            activeUntil: active_until,
            auditContext: buildRequestAuditContext(req)
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
        logNotificationRequest('register_live_session_failed', req, {
            device_id,
            route_key,
            error: error?.message || error
        });
        res.status(400).json({ error: error?.message || error });
    }
});

app.get('/api/v2/notifications/live_sessions', (req, res) => {
    const { device_id } = req.query || {};
    logNotificationRequest('list_live_sessions', req, { device_id });
    if (!device_id) {
        return res.status(400).json({ error: 'device_id is required' });
    }
    const subscriptions = notificationSubscriptionManager.listSubscriptions(device_id, { source: 'live_session' });
    res.json({ subscriptions });
});

app.delete('/api/v2/notifications/live_sessions', async (req, res) => {
    const { device_id, subscription_id } = req.body || {};
    logNotificationRequest('delete_live_session', req, { device_id, subscription_id });
    if (!device_id || !subscription_id) {
        return res.status(400).json({ error: 'device_id and subscription_id are required' });
    }
    const liveSession = await notificationSubscriptionManager.getSubscription({
        deviceId: device_id,
        subscriptionId: subscription_id,
        source: 'live_session'
    });
    const removed = await notificationSubscriptionManager.deleteSubscription({
        deviceId: device_id,
        subscriptionId: subscription_id,
        reason: 'api_delete_live_session',
        metadata: { request: buildRequestAuditContext(req) }
    });
    let mutedScheduledLegs = [];
    if (removed && liveSession) {
        mutedScheduledLegs = await notificationSubscriptionManager.muteScheduledLegsForToday({
            deviceId: device_id,
            legs: liveSession.legs,
            reason: 'api_delete_live_session',
            metadata: {
                request: buildRequestAuditContext(req),
                live_session_id: subscription_id
            }
        });
    }
    res.json({
        status: removed ? 'deleted' : 'not_found',
        muted_scheduled_legs: mutedScheduledLegs
    });
});

app.post('/api/v2/notifications/holiday-mode', async (req, res) => {
    const { device_id, enabled } = req.body || {};
    logNotificationRequest('holiday_mode', req, { device_id, enabled });
    if (!device_id || typeof enabled !== 'boolean') {
        return res.status(400).json({ error: 'device_id and enabled (boolean) are required' });
    }
    try {
        const result = await notificationSubscriptionManager.setHolidayMode({
            deviceId: device_id,
            enabled,
            auditContext: buildRequestAuditContext(req)
        });
        let terminatedLiveActivities = { requested: 0, ended: 0 };
        let removedLiveSessions = 0;
        if (enabled) {
            terminatedLiveActivities = await liveActivityManager.endAllForDevice(device_id, {
                reason: 'holiday_mode',
                trigger: 'holiday_mode_enabled'
            });
            removedLiveSessions = await notificationSubscriptionManager.deleteLiveSessionsForDevice({
                deviceId: device_id,
                reason: 'holiday_mode'
            });
        }
        res.json({
            status: 'ok',
            ...result,
            terminated_live_activities: terminatedLiveActivities,
            removed_live_sessions: removedLiveSessions
        });
    } catch (error) {
        logNotificationRequest('holiday_mode_failed', req, {
            device_id,
            enabled,
            error: error?.message || error
        });
        res.status(400).json({ error: error?.message || error });
    }
});

app.post('/api/v2/notifications/terminate', async (req, res) => {
    const {
        device_id,
        subscription_id,
        from,
        to,
        date,
        reason,
        transition,
        detection_source,
        journey_notification_body
    } = req.body || {};
    logNotificationRequest('terminate', req, {
        device_id,
        subscription_id,
        from,
        to,
        date,
        reason,
        transition,
        detection_source,
        journey_notification_body
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
        date,
        reason,
        transition,
        detectionSource: detection_source,
        journeyNotificationBody: journey_notification_body
    });
    if (!result) {
        return res.status(404).json({ error: 'Subscription or leg not found' });
    }
    res.json({
        status: 'muted',
        date: result.date,
        reason: reason || null,
        transition: result.transition,
        detection_source: result.detectionSource
    });
});

app.post('/api/v2/notifications/geofence-event', async (req, res) => {
    const { device_id, timestamp, event, region_id, from, to } = req.body || {};
    const ip = req.headers['x-forwarded-for'] || req.ip || null;
    logNotificationRequest('geofence_event', req, { device_id, event, from, to });
    await recordGeofenceEvent({ deviceId: device_id, clientTimestamp: timestamp, event, regionId: region_id, from, to, ip });
    res.json({ status: 'ok' });
});

// Ephemeral service monitoring for an in-progress journey. Journey history remains
// local to the device; this state exists only to deliver official timing updates.
app.post('/api/v2/journey_tracking/sessions', (req, res) => {
    const {
        journey_id,
        subscription_id,
        device_id,
        push_token,
        service_id,
        from,
        to,
        destination_crs,
        use_sandbox
    } = req.body || {};
    const { canonicalDeviceId } = resolveRequestDeviceIds(req, device_id);
    if (!canonicalDeviceId) {
        return res.status(400).json({ error: 'device_id is required' });
    }
    try {
        const session = journeyTrackingManager.upsertSession({
            journeyId: journey_id,
            subscriptionId: subscription_id,
            deviceId: canonicalDeviceId,
            pushToken: push_token,
            serviceId: service_id,
            from,
            to,
            destinationCRS: destination_crs,
            useSandbox: Boolean(use_sandbox)
        });
        res.json({
            status: 'registered',
            poll_interval_seconds: Math.round(journeyTrackingManager.pollIntervalMs / 1000),
            session
        });
    } catch (error) {
        res.status(400).json({ error: error?.message || error });
    }
});

app.get('/api/v2/journey_tracking/sessions', (req, res) => {
    const { device_id } = req.query || {};
    const { canonicalDeviceId } = resolveRequestDeviceIds(req, device_id);
    if (!canonicalDeviceId) {
        return res.status(400).json({ error: 'device_id is required' });
    }
    res.json({ sessions: journeyTrackingManager.listSessions(canonicalDeviceId) });
});

app.delete('/api/v2/journey_tracking/sessions/:id', (req, res) => {
    const { device_id } = req.query || {};
    const { canonicalDeviceId } = resolveRequestDeviceIds(req, device_id);
    if (!canonicalDeviceId) {
        return res.status(400).json({ error: 'device_id is required' });
    }
    const removed = journeyTrackingManager.deleteSession({
        id: req.params.id,
        deviceId: canonicalDeviceId
    });
    res.json({ status: removed ? 'deleted' : 'not_found' });
});

app.post('/api/v2/live_activities/status', async (req, res) => {
    const { device_id, from, to, phase } = req.body || {};
    const { canonicalDeviceId, fallbackDeviceIds } = resolveRequestDeviceIds(req, device_id);
    const validPhases = new Set(['pending_start', 'at_start', 'en_route', 'arrived']);
    if (!canonicalDeviceId || !validPhases.has(phase)) {
        return res.status(400).json({ error: 'device_id and a valid phase are required' });
    }

    try {
        const result = await liveActivityManager.handleJourneyPhase(canonicalDeviceId, {
            fromStation: from || null,
            toStation: to || null,
            phase,
            fallbackDeviceIds
        });
        res.json({
            status: 'ok',
            device_id: canonicalDeviceId,
            phase,
            ...result
        });
    } catch (error) {
        const message = error?.message || error;
        console.error(`[live-activity] status update failed for ${canonicalDeviceId}: ${message}`);
        res.status(500).json({ error: message });
    }
});

// Debug notification endpoints
app.get('/api/v2/notifications/debug/subscriptions', (req, res) => {
    logNotificationRequest('debug_list', req);
    res.json({ subscriptions: notificationSubscriptionManager.listAllSubscriptions() });
});

app.get('/api/v2/notifications/debug/subscription-audit', async (req, res) => {
    const { q, limit } = req.query || {};
    logNotificationRequest('debug_subscription_audit', req, { q, limit });
    const events = await listSubscriptionAuditEvents({ search: q || '', limit: limit || 500 });
    res.json({ events });
});

app.delete('/api/v2/notifications/debug/subscriptions', async (req, res) => {
    const { subscription_id } = req.body || {};
    logNotificationRequest('debug_delete', req, { subscription_id });
    if (!subscription_id) {
        return res.status(400).json({ error: 'subscription_id is required' });
    }
    const removed = await notificationSubscriptionManager.deleteSubscription({
        subscriptionId: subscription_id,
        reason: 'api_debug_delete_subscription',
        metadata: { request: buildRequestAuditContext(req) }
    });
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

app.get('/api/v2/departures/from/:fromStation/to/:toStation/at/:departureTime', async (req, res) => {
    const { fromStation, toStation, departureTime } = req.params;
    const normalizedTime = normalizeDepartureTime(departureTime);
    const deviceId = normalizeDeviceId(req.get('X-Device-Token')) || null;

    if (!isValidDepartureTime(normalizedTime)) {
        logDepartureRequest('fetch_v2_single_failed_validation', req, {
            device_id: deviceId,
            from: fromStation,
            to: toStation,
            departure_time: normalizedTime
        });
        return res.status(400).json({ error: 'Invalid departure time. Use HH:mm format.' });
    }

    const startedAt = Date.now();
    logDepartureRequest('fetch_v2_single', req, {
        device_id: deviceId,
        from: fromStation,
        to: toStation,
        departure_time: normalizedTime
    });

    try {
        const data = await getTrainTimes(fromStation, toStation);
        if (data?.error) {
            logDepartureRequest('fetch_v2_single_failed', req, {
                device_id: deviceId,
                from: fromStation,
                to: toStation,
                departure_time: normalizedTime,
                duration_ms: Date.now() - startedAt,
                error: data.error
            });
            return res.status(502).json({ error: data.error });
        }

        const departure = findDepartureByTime(data?.departures, normalizedTime);
        if (!departure) {
            logDepartureRequest('fetch_v2_single_not_found', req, {
                device_id: deviceId,
                from: fromStation,
                to: toStation,
                departure_time: normalizedTime,
                duration_ms: Date.now() - startedAt
            });
            return res.status(404).json({ error: `No service found for departure time ${normalizedTime}` });
        }

        logDepartureRequest('fetch_v2_single_completed', req, {
            device_id: deviceId,
            from: fromStation,
            to: toStation,
            departure_time: normalizedTime,
            duration_ms: Date.now() - startedAt,
            service_id: departure.serviceID
        });
        return res.json(departure);
    } catch (error) {
        logDepartureRequest('fetch_v2_single_failed', req, {
            device_id: deviceId,
            from: fromStation,
            to: toStation,
            departure_time: normalizedTime,
            duration_ms: Date.now() - startedAt,
            error: error?.message || error
        });
        throw error;
    }
});

// V2 API - New array format supporting multiple journeys
app.get('/api/v2/departures/from/:fromStation/to/:toStation*', async (req, res) => {
    const path = req.path;
    const deviceId = normalizeDeviceId(req.get('X-Device-Token')) || null;
    const includeStatus = shouldIncludeDepartureStatus(req.query.includeStatus);

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
        logDepartureRequest('fetch_v2_failed_validation', req, {
            device_id: deviceId,
            journey_count: 0
        });
        return res.status(400).json({ error: 'No valid from/to pairs found in request' });
    }

    const startedAt = Date.now();
    logDepartureRequest('fetch_v2', req, {
        device_id: deviceId,
        journey_count: journeyPairs.length,
        journey_pairs: journeyPairs.map((pair) => `${pair.from}_${pair.to}`)
    });

    try {
        // Fetch all journeys in parallel and return as array
        const results = await Promise.all(
            journeyPairs.map(async (pair) => {
                const data = await getTrainTimes(pair.from, pair.to);
                const key = `${pair.from}_${pair.to}`;
                return formatDepartureJourneyResult(key, data, includeStatus);
            })
        );

        logDepartureRequest('fetch_v2_completed', req, {
            device_id: deviceId,
            journey_count: journeyPairs.length,
            duration_ms: Date.now() - startedAt
        });
        res.json(results);
    } catch (error) {
        logDepartureRequest('fetch_v2_failed', req, {
            device_id: deviceId,
            journey_count: journeyPairs.length,
            duration_ms: Date.now() - startedAt,
            error: error?.message || error
        });
        throw error;
    }
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

    const context = serviceDetailsContextFromQuery(req.query);

    // Fetch all service IDs in parallel and return as array
    const results = await Promise.all(
        serviceIds.map(async (serviceId) => {
            const serviceDetails = await getServiceDetailsWithContext(serviceId, context);
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

function serviceDetailsContextFromQuery(query) {
    const destinationCRSs = String(query?.destinationCRS || '')
        .split(',')
        .map((value) => value.trim().toUpperCase())
        .filter(Boolean);
    return {
        fromCRS: normalizedQueryValue(query?.fromCRS),
        toCRS: normalizedQueryValue(query?.toCRS),
        originCRS: normalizedQueryValue(query?.originCRS),
        operator: normalizedQueryValue(query?.operator),
        destinationCRSs,
        length: Number(query?.length) || null
    };
}

function normalizedQueryValue(value) {
    return typeof value === 'string' ? value.trim() : '';
}

// V2 API - Stations endpoint
app.get('/api/v2/stations', async (req, res) => {
    res.setHeader('Content-Type', 'application/json');
    if (isDebugBuildRequest(req)) {
        try {
            const __dirname = path.resolve();
            const stationsPath = path.join(__dirname, 'resources', 'stations.json');
            const stations = JSON.parse(fs.readFileSync(stationsPath, 'utf8'));
            return res.json([
                ...stations,
                ...testServiceHarness.getStations()
            ]);
        } catch (error) {
            console.error('[stations] Failed to append test stations:', error?.message || error);
            return res.status(500).json({ error: 'Failed to load stations' });
        }
    }
    const __dirname = path.resolve();
    res.sendFile(path.join(__dirname, 'resources', 'stations.json'));
});

// V2 API - Client configuration endpoint
// Returns server-side limits so clients can stay in sync without app updates.
app.get('/api/v2/config', (req, res) => {
    const maxPerDevice = Number(process.env.NOTIFICATION_MAX_SUBSCRIPTIONS || '5');
    res.json({
        max_subscriptions_per_device: maxPerDevice,
        max_live_sessions_per_device: maxPerDevice,
    });
});

app.get('/api/v2/delay-repay/operator', (req, res) => {
    const operatorCode = typeof req.query.operator_code === 'string' ? req.query.operator_code : '';
    const operatorName = typeof req.query.operator_name === 'string' ? req.query.operator_name : '';
    if (!operatorCode.trim() && !operatorName.trim()) {
        return res.status(400).json({ error: 'operator_code or operator_name is required' });
    }

    try {
        const operator = resolveDelayRepayOperator({ operatorCode, operatorName });
        if (!operator) {
            return res.status(404).json({ error: 'Delay Repay URL unavailable for this operator' });
        }
        res.set('Cache-Control', 'public, max-age=3600');
        return res.json(operator);
    } catch (error) {
        console.error('[delay-repay] Failed to resolve operator:', error?.message || error);
        return res.status(500).json({ error: 'Delay Repay configuration unavailable' });
    }
});

app.get('/api/v1/xbar/from/:fromStation/to/:toStation/max_departures/:maxDepartures/return_after/:returnAfter?', async (req, res) => {
    res.send(await getXbarOutput(req.params.fromStation, req.params.toStation, req.params.maxDepartures, req.params.returnAfter));
});

// Hydrate persistent push state from Mongo before accepting requests.
await ensureMongoIndexes();
await startSubscriptionAuditLogMaintenance();
await liveActivityManager.init();
await notificationSubscriptionManager.init();
journeyTrackingManager.startPollingLoop();

const port = process.env.PORT || 3012;
app.listen(port, () => {
    console.log(`Server running on port ${port}`);
    logLiveActivityStartup();
});
