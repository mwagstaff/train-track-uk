import crypto from 'crypto';
import redis from './redis-client.js';

const REDIS_SUB_IDS_KEY = 'tt:notification:sub_ids';
const redisSubKey = (id) => `tt:notification:sub:${id}`;

const REDIS_EVENT_IDS_KEY = 'tt:admin:notification:event_ids';
const redisEventKey = (id) => `tt:admin:notification:event:${id}`;
const MAX_EVENT_LOG_SIZE = Number(process.env.ADMIN_NOTIFICATION_LOG_MAX || '5000');
const EVENT_TTL_SECONDS = Number(process.env.ADMIN_NOTIFICATION_LOG_TTL_SECONDS || String(14 * 24 * 60 * 60));

const REDIS_PUSH_AUDIT_IDS_KEY = 'tt:admin:push_audit:event_ids';
const redisPushAuditKey = (id) => `tt:admin:push_audit:event:${id}`;
const MAX_PUSH_AUDIT_LOG_SIZE = Number(process.env.ADMIN_PUSH_AUDIT_LOG_MAX || '10000');
const PUSH_AUDIT_TTL_SECONDS = Number(process.env.ADMIN_PUSH_AUDIT_LOG_TTL_SECONDS || String(7 * 24 * 60 * 60));

const REDIS_LIVE_ACTIVITY_PAYLOAD_IDS_KEY = 'tt:admin:live_activity_payload:event_ids';
const redisLiveActivityPayloadKey = (id) => `tt:admin:live_activity_payload:event:${id}`;
const MAX_LIVE_ACTIVITY_PAYLOAD_LOG_SIZE = Number(process.env.ADMIN_LIVE_ACTIVITY_PAYLOAD_LOG_MAX || '5000');
const LIVE_ACTIVITY_PAYLOAD_TTL_SECONDS = Number(process.env.ADMIN_LIVE_ACTIVITY_PAYLOAD_TTL_SECONDS || String(7 * 24 * 60 * 60));

const REDIS_DEVICE_PREF_IDS_KEY = 'tt:admin:device_preferences:ids';
const redisDevicePreferencesKey = (deviceId) => `tt:admin:device_preferences:${deviceId}`;

export async function listNotificationSubscriptionsFromRedis({ search = '', limit = 500 } = {}) {
    const ids = await redis.smembers(REDIS_SUB_IDS_KEY);
    if (!Array.isArray(ids) || ids.length === 0) {
        return [];
    }

    const pipeline = redis.pipeline();
    for (const id of ids) {
        pipeline.get(redisSubKey(id));
    }
    const results = await pipeline.exec();

    const query = normalizeQuery(search);
    const subscriptions = [];
    for (let i = 0; i < results.length; i++) {
        const [error, value] = results[i];
        if (error || !value) continue;
        const parsed = safeParseJson(value);
        if (!parsed || typeof parsed !== 'object') continue;
        const normalized = {
            id: parsed.id || ids[i],
            ...parsed
        };
        if (query && !matchesQuery(normalized, query)) {
            continue;
        }
        subscriptions.push(normalized);
    }

    subscriptions.sort((left, right) => {
        const leftTime = Date.parse(left.createdAt || '') || 0;
        const rightTime = Date.parse(right.createdAt || '') || 0;
        return rightTime - leftTime;
    });

    return subscriptions.slice(0, clampLimit(limit, 1, 5000));
}

export async function getNotificationSubscriptionFromRedis(id) {
    if (!id) return null;
    const raw = await redis.get(redisSubKey(id));
    if (!raw) return null;
    const parsed = safeParseJson(raw);
    if (!parsed || typeof parsed !== 'object') return null;
    return {
        id: parsed.id || id,
        ...parsed
    };
}

export async function recordNotificationEvent(event = {}) {
    const now = new Date().toISOString();
    const status = event.status ?? null;
    const success = event.success ?? isSuccessStatus(status);
    const normalized = {
        id: event.id || crypto.randomUUID(),
        sent_at: event.sent_at || now,
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
        const tx = redis.multi();
        tx.set(redisEventKey(normalized.id), JSON.stringify(normalized), 'EX', EVENT_TTL_SECONDS);
        tx.lpush(REDIS_EVENT_IDS_KEY, normalized.id);
        tx.ltrim(REDIS_EVENT_IDS_KEY, 0, Math.max(0, MAX_EVENT_LOG_SIZE - 1));
        await tx.exec();
    } catch (error) {
        console.error('[admin] Failed to persist notification event:', error?.message || error);
    }

    return normalized;
}

export async function listNotificationEvents({ search = '', limit = 500 } = {}) {
    const safeLimit = clampLimit(limit, 1, 5000);
    const scanLimit = Math.min(MAX_EVENT_LOG_SIZE, Math.max(safeLimit, safeLimit * 5));
    const ids = await redis.lrange(REDIS_EVENT_IDS_KEY, 0, scanLimit - 1);
    if (!Array.isArray(ids) || ids.length === 0) {
        return [];
    }

    const query = normalizeQuery(search);
    const pipeline = redis.pipeline();
    for (const id of ids) {
        pipeline.get(redisEventKey(id));
    }
    const results = await pipeline.exec();

    const events = [];
    for (let i = 0; i < results.length; i++) {
        const [error, value] = results[i];
        if (error || !value) continue;
        const event = safeParseJson(value);
        if (!event || typeof event !== 'object') continue;
        if (query && !matchesQuery(event, query)) continue;
        events.push(event);
        if (events.length >= safeLimit) break;
    }

    return events;
}

export async function getNotificationEvent(id) {
    if (!id) return null;
    const raw = await redis.get(redisEventKey(id));
    if (!raw) return null;
    const parsed = safeParseJson(raw);
    if (!parsed || typeof parsed !== 'object') return null;
    return parsed;
}

export async function recordPushAuditEvent(event = {}) {
    const normalized = {
        id: event.id || crypto.randomUUID(),
        recorded_at: event.recorded_at || new Date().toISOString(),
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
        const tx = redis.multi();
        tx.set(redisPushAuditKey(normalized.id), JSON.stringify(normalized), 'EX', PUSH_AUDIT_TTL_SECONDS);
        tx.lpush(REDIS_PUSH_AUDIT_IDS_KEY, normalized.id);
        tx.ltrim(REDIS_PUSH_AUDIT_IDS_KEY, 0, Math.max(0, MAX_PUSH_AUDIT_LOG_SIZE - 1));
        await tx.exec();
    } catch (error) {
        console.error('[admin] Failed to persist push audit event:', error?.message || error);
    }

    return normalized;
}

export async function listPushAuditEvents({ search = '', limit = 500 } = {}) {
    return listJsonLog({
        idsKey: REDIS_PUSH_AUDIT_IDS_KEY,
        keyForId: redisPushAuditKey,
        search,
        limit,
        maxLogSize: MAX_PUSH_AUDIT_LOG_SIZE
    });
}

export async function recordLiveActivityPayload(event = {}) {
    const normalized = {
        id: event.id || crypto.randomUUID(),
        recorded_at: event.recorded_at || new Date().toISOString(),
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
        const tx = redis.multi();
        tx.set(redisLiveActivityPayloadKey(normalized.id), JSON.stringify(normalized), 'EX', LIVE_ACTIVITY_PAYLOAD_TTL_SECONDS);
        tx.lpush(REDIS_LIVE_ACTIVITY_PAYLOAD_IDS_KEY, normalized.id);
        tx.ltrim(REDIS_LIVE_ACTIVITY_PAYLOAD_IDS_KEY, 0, Math.max(0, MAX_LIVE_ACTIVITY_PAYLOAD_LOG_SIZE - 1));
        await tx.exec();
    } catch (error) {
        console.error('[admin] Failed to persist live activity payload:', error?.message || error);
    }

    return normalized;
}

export async function listLiveActivityPayloads({ search = '', limit = 500 } = {}) {
    return listJsonLog({
        idsKey: REDIS_LIVE_ACTIVITY_PAYLOAD_IDS_KEY,
        keyForId: redisLiveActivityPayloadKey,
        search,
        limit,
        maxLogSize: MAX_LIVE_ACTIVITY_PAYLOAD_LOG_SIZE
    });
}

export async function getLiveActivityPayload(id) {
    if (!id) return null;
    const raw = await redis.get(redisLiveActivityPayloadKey(id));
    if (!raw) return null;
    const parsed = safeParseJson(raw);
    if (!parsed || typeof parsed !== 'object') return null;
    return parsed;
}

export async function recordDevicePreferences({ deviceId, preferences = {} } = {}) {
    const normalizedDeviceId = typeof deviceId === 'string' ? deviceId.trim() : '';
    if (!normalizedDeviceId) {
        throw new Error('deviceId is required');
    }
    const record = {
        device_id: normalizedDeviceId,
        preferences: preferences && typeof preferences === 'object' && !Array.isArray(preferences) ? preferences : {},
        updated_at: new Date().toISOString()
    };
    await redis.multi()
        .set(redisDevicePreferencesKey(normalizedDeviceId), JSON.stringify(record))
        .sadd(REDIS_DEVICE_PREF_IDS_KEY, normalizedDeviceId)
        .exec();
    return record;
}

export async function getDevicePreferences(deviceId) {
    const normalizedDeviceId = typeof deviceId === 'string' ? deviceId.trim() : '';
    if (!normalizedDeviceId) return null;
    const raw = await redis.get(redisDevicePreferencesKey(normalizedDeviceId));
    if (!raw) return null;
    const parsed = safeParseJson(raw);
    if (!parsed || typeof parsed !== 'object') return null;
    return parsed;
}

export async function listDevicePreferences() {
    const ids = await redis.smembers(REDIS_DEVICE_PREF_IDS_KEY);
    if (!Array.isArray(ids) || ids.length === 0) {
        return [];
    }
    const pipeline = redis.pipeline();
    for (const id of ids) {
        pipeline.get(redisDevicePreferencesKey(id));
    }
    const results = await pipeline.exec();
    return results
        .map(([error, value]) => (error || !value ? null : safeParseJson(value)))
        .filter((record) => record && typeof record === 'object');
}

function safeParseJson(input) {
    try {
        return JSON.parse(input);
    } catch {
        return null;
    }
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

async function listJsonLog({ idsKey, keyForId, search = '', limit = 500, maxLogSize = 5000 }) {
    const safeLimit = clampLimit(limit, 1, maxLogSize);
    const scanLimit = Math.min(maxLogSize, Math.max(safeLimit, safeLimit * 5));
    const ids = await redis.lrange(idsKey, 0, scanLimit - 1);
    if (!Array.isArray(ids) || ids.length === 0) {
        return [];
    }

    const query = normalizeQuery(search);
    const pipeline = redis.pipeline();
    for (const id of ids) {
        pipeline.get(keyForId(id));
    }
    const results = await pipeline.exec();

    const events = [];
    for (const [error, value] of results) {
        if (error || !value) continue;
        const event = safeParseJson(value);
        if (!event || typeof event !== 'object') continue;
        if (query && !matchesQuery(event, query)) continue;
        events.push(event);
        if (events.length >= safeLimit) break;
    }

    return events;
}

function maskToken(token) {
    if (typeof token !== 'string' || token.length === 0) return null;
    if (token.length <= 10) return `${token.slice(0, 3)}***`;
    return `${token.slice(0, 8)}...${token.slice(-6)}`;
}

function isSuccessStatus(status) {
    return typeof status === 'number' && status >= 200 && status < 300;
}

// ── Geofence event log ─────────────────────────────────────────────────────

const REDIS_GEOFENCE_EVENT_LOG_KEY = 'tt:notification:geofence_event_log';
const MAX_GEOFENCE_EVENT_LOG_SIZE = 100;

export async function recordGeofenceEvent({ deviceId, clientTimestamp, event, regionId, from, to, ip } = {}) {
    const entry = JSON.stringify({
        received_at: new Date().toISOString(),
        device_id: deviceId || null,
        client_timestamp: clientTimestamp || null,
        event: event || null,
        region_id: regionId || null,
        from: from || null,
        to: to || null,
        ip: ip || null
    });
    try {
        const tx = redis.multi();
        tx.lpush(REDIS_GEOFENCE_EVENT_LOG_KEY, entry);
        tx.ltrim(REDIS_GEOFENCE_EVENT_LOG_KEY, 0, MAX_GEOFENCE_EVENT_LOG_SIZE - 1);
        await tx.exec();
    } catch (error) {
        console.error('[admin] Failed to persist geofence event:', error?.message || error);
    }
}

export async function listGeofenceEvents() {
    const raw = await redis.lrange(REDIS_GEOFENCE_EVENT_LOG_KEY, 0, MAX_GEOFENCE_EVENT_LOG_SIZE - 1);
    if (!Array.isArray(raw)) return [];
    return raw.map((entry) => safeParseJson(entry)).filter(Boolean);
}
