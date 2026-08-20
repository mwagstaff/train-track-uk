import crypto from 'crypto';
import { COLLECTIONS, getMongoCollection } from './mongo-client.js';
import { appendSubscriptionAuditLogEvent } from './subscription-audit-log.js';
import { allowDeviceData, referencesDeletedDevice } from './device-data-deletion-state.js';

const MAX_EVENT_LOG_SIZE = Number(process.env.ADMIN_NOTIFICATION_LOG_MAX || '5000');
const MAX_PUSH_AUDIT_LOG_SIZE = Number(process.env.ADMIN_PUSH_AUDIT_LOG_MAX || '10000');
const MAX_LIVE_ACTIVITY_PAYLOAD_LOG_SIZE = Number(process.env.ADMIN_LIVE_ACTIVITY_PAYLOAD_LOG_MAX || '5000');
const MAX_SUBSCRIPTION_AUDIT_LOG_SIZE = Number(process.env.ADMIN_SUBSCRIPTION_AUDIT_LOG_MAX || '10000');
const MAX_GEOFENCE_EVENT_LOG_SIZE = 100;

export async function listNotificationSubscriptions({ search = '', limit = 500 } = {}) {
    const collection = await getMongoCollection(COLLECTIONS.notificationSubscriptions);
    const safeLimit = clampLimit(limit, 1, 5000);
    const scanLimit = Math.max(safeLimit, Math.min(5000, safeLimit * 5));
    const subscriptions = await collection
        .find({})
        .sort({ createdAt: -1, updatedAt: -1 })
        .limit(scanLimit)
        .toArray();
    const query = normalizeQuery(search);
    return subscriptions
        .map(stripMongoId)
        .filter((subscription) => !query || matchesQuery(subscription, query))
        .slice(0, safeLimit);
}

export async function getNotificationSubscription(id) {
    if (!id) return null;
    const collection = await getMongoCollection(COLLECTIONS.notificationSubscriptions);
    const parsed = await collection.findOne({ _id: id });
    if (!parsed || typeof parsed !== 'object') return null;
    return stripMongoId({ id: parsed.id || id, ...parsed });
}

export async function recordSubscriptionAuditEvent(event = {}) {
    if (referencesDeletedDevice(event)) return null;
    const normalized = {
        id: event.id || crypto.randomUUID(),
        recorded_at: event.recorded_at ? new Date(event.recorded_at) : new Date(),
        action: event.action || 'unknown',
        reason: event.reason || null,
        source: event.source || null,
        request: event.request ?? null,
        subscription_id: event.subscription_id || event.subscription?.id || null,
        device_id: event.device_id || event.subscription?.deviceId || null,
        route_key: event.route_key || event.subscription?.routeKey || null,
        from_station: event.from_station || null,
        to_station: event.to_station || null,
        mongo: event.mongo ?? null,
        before: event.before ? scrubSubscriptionForAudit(event.before) : null,
        after: event.after ? scrubSubscriptionForAudit(event.after) : null,
        subscription: event.subscription ? scrubSubscriptionForAudit(event.subscription) : null,
        metadata: event.metadata ?? null
    };

    try {
        const collection = await getMongoCollection(COLLECTIONS.subscriptionAuditEvents);
        await collection.updateOne(
            { _id: normalized.id },
            { $set: { _id: normalized.id, ...normalized } },
            { upsert: true }
        );
        if (referencesDeletedDevice(normalized)) {
            await collection.deleteOne({ _id: normalized.id });
            return null;
        }
    } catch (error) {
        console.error('[admin] Failed to persist subscription audit event to Mongo:', error?.message || error);
    }

    if (referencesDeletedDevice(normalized)) return null;

    try {
        if (!referencesDeletedDevice(normalized)) {
            await appendSubscriptionAuditLogEvent(normalized, {
                shouldAppend: () => !referencesDeletedDevice(normalized)
            });
        }
    } catch (error) {
        console.error('[admin] Failed to append subscription audit event:', error?.message || error);
    }

    if (referencesDeletedDevice(normalized)) return null;

    console.log('[notifications] subscription_audit', JSON.stringify({
        action: normalized.action,
        reason: normalized.reason,
        subscription_id: normalized.subscription_id,
        device_id: normalized.device_id,
        route_key: normalized.route_key
    }));

    return stripMongoId(normalized);
}

export async function listSubscriptionAuditEvents({ search = '', limit = 500 } = {}) {
    return listEvents({
        collectionName: COLLECTIONS.subscriptionAuditEvents,
        sortField: 'recorded_at',
        search,
        limit,
        maxLogSize: MAX_SUBSCRIPTION_AUDIT_LOG_SIZE
    });
}

export async function recordNotificationEvent(event = {}) {
    if (referencesDeletedDevice(event)) return null;
    const now = new Date();
    const status = event.status ?? null;
    const success = event.success ?? isSuccessStatus(status);
    const normalized = {
        id: event.id || crypto.randomUUID(),
        sent_at: event.sent_at ? new Date(event.sent_at) : now,
        channel: event.channel || 'notification',
        type: event.type || 'unknown',
        success: Boolean(success),
        status,
        error: event.error || null,
        apns_environment: event.apns_environment || 'prod',
        subscription_id: event.subscription_id || null,
        activity_id: event.activity_id || null,
        device_id: event.device_id || null,
        route_key: event.route_key || null,
        from_station: event.from_station || null,
        to_station: event.to_station || null,
        token: event.token || null,
        is_bad_token: Boolean(event.is_bad_token),
        payload: event.payload ?? null,
        response: event.response ?? null,
        metadata: event.metadata ?? null
    };

    try {
        const collection = await getMongoCollection(COLLECTIONS.notificationEvents);
        await collection.updateOne(
            { _id: normalized.id },
            { $set: { _id: normalized.id, ...normalized } },
            { upsert: true }
        );
        if (referencesDeletedDevice(normalized)) {
            await collection.deleteOne({ _id: normalized.id });
            return null;
        }
    } catch (error) {
        console.error('[admin] Failed to persist notification event:', error?.message || error);
    }

    return stripMongoId(normalized);
}

export async function listNotificationEvents({ search = '', limit = 500 } = {}) {
    return listEvents({
        collectionName: COLLECTIONS.notificationEvents,
        sortField: 'sent_at',
        search,
        limit,
        maxLogSize: MAX_EVENT_LOG_SIZE
    });
}

export async function getNotificationEvent(id) {
    return getEventById(COLLECTIONS.notificationEvents, id);
}

export async function recordPushAuditEvent(event = {}) {
    if (referencesDeletedDevice(event)) return null;
    const normalized = {
        id: event.id || crypto.randomUUID(),
        recorded_at: event.recorded_at ? new Date(event.recorded_at) : new Date(),
        channel: event.channel || 'notification',
        event: event.event || 'unknown',
        environment: event.environment || null,
        host: event.host || null,
        topic: event.topic || null,
        push_type: event.push_type || null,
        priority: event.priority || null,
        attempt: Number.isFinite(event.attempt) ? event.attempt : null,
        final: Boolean(event.final),
        token: maskToken(event.token),
        context: event.context ?? null,
        payload: event.payload ?? null,
        response: event.response ?? null,
        error: event.error || null
    };

    try {
        const collection = await getMongoCollection(COLLECTIONS.pushAuditEvents);
        await collection.updateOne(
            { _id: normalized.id },
            { $set: { _id: normalized.id, ...normalized } },
            { upsert: true }
        );
        if (referencesDeletedDevice(normalized)) {
            await collection.deleteOne({ _id: normalized.id });
            return null;
        }
    } catch (error) {
        console.error('[admin] Failed to persist push audit event:', error?.message || error);
    }

    return stripMongoId(normalized);
}

export async function listPushAuditEvents({ search = '', limit = 500 } = {}) {
    return listEvents({
        collectionName: COLLECTIONS.pushAuditEvents,
        sortField: 'recorded_at',
        search,
        limit,
        maxLogSize: MAX_PUSH_AUDIT_LOG_SIZE
    });
}

export async function recordLiveActivityPayload(event = {}) {
    if (referencesDeletedDevice(event)) return null;
    const normalized = {
        id: event.id || crypto.randomUUID(),
        recorded_at: event.recorded_at ? new Date(event.recorded_at) : new Date(),
        channel: 'live_activity',
        event: event.event || event.payload?.aps?.event || 'unknown',
        environment: event.environment || null,
        host: event.host || null,
        topic: event.topic || null,
        token: maskToken(event.token),
        context: event.context ?? null,
        payload: event.payload ?? null,
        response: event.response ?? null,
        replayed_from_id: event.replayed_from_id || null
    };

    try {
        const collection = await getMongoCollection(COLLECTIONS.liveActivityPayloads);
        await collection.updateOne(
            { _id: normalized.id },
            { $set: { _id: normalized.id, ...normalized } },
            { upsert: true }
        );
        if (referencesDeletedDevice(normalized)) {
            await collection.deleteOne({ _id: normalized.id });
            return null;
        }
    } catch (error) {
        console.error('[admin] Failed to persist live activity payload:', error?.message || error);
    }

    return stripMongoId(normalized);
}

export async function listLiveActivityPayloads({ search = '', limit = 500 } = {}) {
    return listEvents({
        collectionName: COLLECTIONS.liveActivityPayloads,
        sortField: 'recorded_at',
        search,
        limit,
        maxLogSize: MAX_LIVE_ACTIVITY_PAYLOAD_LOG_SIZE
    });
}

export async function getLiveActivityPayload(id) {
    return getEventById(COLLECTIONS.liveActivityPayloads, id);
}

export async function recordDevicePreferences({ deviceId, preferences = {} } = {}) {
    const normalizedDeviceId = typeof deviceId === 'string' ? deviceId.trim() : '';
    if (!normalizedDeviceId) {
        throw new Error('deviceId is required');
    }
    if (!allowDeviceData(normalizedDeviceId)) {
        throw new Error('Device data deletion is in progress');
    }
    const record = {
        device_id: normalizedDeviceId,
        preferences: preferences && typeof preferences === 'object' && !Array.isArray(preferences) ? preferences : {},
        updated_at: new Date()
    };
    const collection = await getMongoCollection(COLLECTIONS.devicePreferences);
    await collection.updateOne(
        { _id: normalizedDeviceId },
        { $set: { _id: normalizedDeviceId, ...record } },
        { upsert: true }
    );
    if (referencesDeletedDevice(record)) {
        await collection.deleteOne({ _id: normalizedDeviceId });
        throw new Error('Device data deletion is in progress');
    }
    return stripMongoId(record);
}

export async function getDevicePreferences(deviceId) {
    const normalizedDeviceId = typeof deviceId === 'string' ? deviceId.trim() : '';
    if (!normalizedDeviceId) return null;
    const collection = await getMongoCollection(COLLECTIONS.devicePreferences);
    const parsed = await collection.findOne({ _id: normalizedDeviceId });
    if (!parsed || typeof parsed !== 'object') return null;
    return stripMongoId(parsed);
}

export async function listDevicePreferences() {
    const collection = await getMongoCollection(COLLECTIONS.devicePreferences);
    const records = await collection.find({}).sort({ updated_at: -1 }).limit(5000).toArray();
    return records.map(stripMongoId);
}

export async function recordGeofenceEvent({ deviceId, clientTimestamp, event, regionId, from, to, ip } = {}) {
    if (referencesDeletedDevice({ deviceId })) return;
    const entry = {
        id: crypto.randomUUID(),
        received_at: new Date(),
        device_id: deviceId || null,
        client_timestamp: clientTimestamp || null,
        event: event || null,
        region_id: regionId || null,
        from: from || null,
        to: to || null,
        ip: ip || null
    };
    try {
        const collection = await getMongoCollection(COLLECTIONS.geofenceEvents);
        await collection.insertOne({ _id: entry.id, ...entry });
        if (referencesDeletedDevice(entry)) {
            await collection.deleteOne({ _id: entry.id });
        }
    } catch (error) {
        console.error('[admin] Failed to persist geofence event:', error?.message || error);
    }
}

export async function listGeofenceEvents() {
    const collection = await getMongoCollection(COLLECTIONS.geofenceEvents);
    const records = await collection
        .find({})
        .sort({ received_at: -1 })
        .limit(MAX_GEOFENCE_EVENT_LOG_SIZE)
        .toArray();
    return records.map(stripMongoId);
}

async function listEvents({ collectionName, sortField, search = '', limit = 500, maxLogSize = 5000 }) {
    const safeLimit = clampLimit(limit, 1, maxLogSize);
    const scanLimit = Math.min(maxLogSize, Math.max(safeLimit, safeLimit * 5));
    const collection = await getMongoCollection(collectionName);
    const query = normalizeQuery(search);
    const records = await collection
        .find({})
        .sort({ [sortField]: -1 })
        .limit(scanLimit)
        .toArray();
    const events = [];
    for (const record of records) {
        const event = stripMongoId(record);
        if (query && !matchesQuery(event, query)) continue;
        events.push(event);
        if (events.length >= safeLimit) break;
    }
    return events;
}

async function getEventById(collectionName, id) {
    if (!id) return null;
    const collection = await getMongoCollection(collectionName);
    const parsed = await collection.findOne({ _id: id });
    if (!parsed || typeof parsed !== 'object') return null;
    return stripMongoId(parsed);
}

function matchesQuery(payload, query) {
    const text = JSON.stringify(payload).toLowerCase();
    return text.includes(query);
}

function normalizeQuery(search) {
    return typeof search === 'string' ? search.trim().toLowerCase() : '';
}

function clampLimit(value, min, max) {
    const number = Number(value);
    if (!Number.isFinite(number)) return min;
    return Math.min(max, Math.max(min, Math.floor(number)));
}

function maskToken(token) {
    if (typeof token !== 'string' || token.length === 0) return null;
    if (token.length <= 10) return `${token.slice(0, 3)}***`;
    return `${token.slice(0, 8)}...${token.slice(-6)}`;
}

function isSuccessStatus(status) {
    return typeof status === 'number' && status >= 200 && status < 300;
}

function scrubSubscriptionForAudit(subscription) {
    if (!subscription || typeof subscription !== 'object') return null;
    return {
        ...stripMongoId(subscription),
        pushToken: maskToken(subscription.pushToken)
    };
}

function stripMongoId(value) {
    if (!value || typeof value !== 'object') return value;
    const { _id, ...rest } = value;
    return rest;
}
