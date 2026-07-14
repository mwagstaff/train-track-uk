import { MongoClient } from 'mongodb';

const DEFAULT_URI = 'mongodb://localhost:27017/train_track_uk';
const MONGODB_URI = process.env.MONGODB_URI_TRAIN_TRACK_UK || DEFAULT_URI;
const DB_NAME = resolveDatabaseName(MONGODB_URI) || 'train_track_uk';

let clientPromise = null;
let indexesPromise = null;

export const COLLECTIONS = Object.freeze({
    notificationSubscriptions: 'notification_subscriptions',
    pushToStartTokens: 'push_to_start_tokens',
    liveActivitySessions: 'live_activity_sessions',
    devicePreferences: 'device_preferences',
    notificationEvents: 'notification_events',
    pushAuditEvents: 'push_audit_events',
    liveActivityPayloads: 'live_activity_payloads',
    subscriptionAuditEvents: 'subscription_audit_events',
    geofenceEvents: 'geofence_events',
    holidayMode: 'holiday_mode'
});

export async function getMongoClient() {
    if (!clientPromise) {
        const client = new MongoClient(MONGODB_URI, {
            maxPoolSize: Number(process.env.MONGODB_MAX_POOL_SIZE || '10'),
            serverSelectionTimeoutMS: Number(process.env.MONGODB_SERVER_SELECTION_TIMEOUT_MS || '30000')
        });
        clientPromise = client.connect()
            .then((connected) => {
                console.log('[mongo] connected');
                return connected;
            })
            .catch((error) => {
                clientPromise = null;
                console.error('[mongo] connection error', error?.message || error);
                throw error;
            });
    }
    return clientPromise;
}

export async function getMongoDb() {
    const client = await getMongoClient();
    return client.db(DB_NAME);
}

export async function getMongoCollection(name) {
    const db = await getMongoDb();
    return db.collection(name);
}

export async function ensureMongoIndexes() {
    if (!indexesPromise) {
        indexesPromise = createIndexes().catch((error) => {
            indexesPromise = null;
            throw error;
        });
    }
    return indexesPromise;
}

async function createIndexes() {
    const db = await getMongoDb();
    await Promise.all([
        db.collection(COLLECTIONS.notificationSubscriptions).createIndexes([
            { key: { deviceId: 1, source: 1 }, name: 'device_source' },
            { key: { source: 1, activeUntil: 1 }, name: 'source_active_until' },
            { key: { deviceId: 1, routeKey: 1, source: 1 }, name: 'device_route_source' },
            { key: { updatedAt: -1 }, name: 'updated_at_desc' }
        ]),
        db.collection(COLLECTIONS.pushToStartTokens).createIndexes([
            { key: { expiresAt: 1 }, name: 'expires_at_ttl', expireAfterSeconds: 0 },
            { key: { updatedAt: -1 }, name: 'updated_at_desc' }
        ]),
        db.collection(COLLECTIONS.liveActivitySessions).createIndexes([
            { key: { deviceId: 1 }, name: 'device_id' },
            { key: { expiresAt: 1 }, name: 'expires_at_ttl', expireAfterSeconds: 0 },
            { key: { tokenUpdatedAt: -1 }, name: 'token_updated_at_desc' }
        ]),
        db.collection(COLLECTIONS.devicePreferences).createIndexes([
            { key: { updated_at: -1 }, name: 'updated_at_desc' }
        ]),
        db.collection(COLLECTIONS.notificationEvents).createIndexes([
            { key: { sent_at: 1 }, name: 'sent_at_ttl', expireAfterSeconds: ttlSeconds('ADMIN_NOTIFICATION_LOG_TTL_SECONDS', 14) },
            { key: { sent_at: -1 }, name: 'sent_at_desc' },
            { key: { device_id: 1, sent_at: -1 }, name: 'device_sent_at' },
            { key: { subscription_id: 1, sent_at: -1 }, name: 'subscription_sent_at' },
            { key: { activity_id: 1, sent_at: -1 }, name: 'activity_sent_at' }
        ]),
        db.collection(COLLECTIONS.pushAuditEvents).createIndexes([
            { key: { recorded_at: 1 }, name: 'recorded_at_ttl', expireAfterSeconds: ttlSeconds('ADMIN_PUSH_AUDIT_LOG_TTL_SECONDS', 7) },
            { key: { recorded_at: -1 }, name: 'recorded_at_desc' }
        ]),
        db.collection(COLLECTIONS.liveActivityPayloads).createIndexes([
            { key: { recorded_at: 1 }, name: 'recorded_at_ttl', expireAfterSeconds: ttlSeconds('ADMIN_LIVE_ACTIVITY_PAYLOAD_LOG_TTL_SECONDS', 7) },
            { key: { recorded_at: -1 }, name: 'recorded_at_desc' }
        ]),
        db.collection(COLLECTIONS.subscriptionAuditEvents).createIndexes([
            { key: { recorded_at: 1 }, name: 'recorded_at_ttl', expireAfterSeconds: ttlSeconds('ADMIN_SUBSCRIPTION_AUDIT_LOG_TTL_SECONDS', 30) },
            { key: { recorded_at: -1 }, name: 'recorded_at_desc' },
            { key: { device_id: 1, recorded_at: -1 }, name: 'device_recorded_at' },
            { key: { subscription_id: 1, recorded_at: -1 }, name: 'subscription_recorded_at' }
        ]),
        db.collection(COLLECTIONS.geofenceEvents).createIndexes([
            { key: { received_at: 1 }, name: 'received_at_ttl', expireAfterSeconds: ttlSeconds('ADMIN_GEOFENCE_LOG_TTL_SECONDS', 30) },
            { key: { received_at: -1 }, name: 'received_at_desc' },
            { key: { device_id: 1, received_at: -1 }, name: 'device_received_at' }
        ])
    ]);
    console.log('[mongo] indexes ready');
}

function ttlSeconds(envName, defaultDays) {
    return Number(process.env[envName] || String(defaultDays * 24 * 60 * 60));
}

function resolveDatabaseName(uri) {
    try {
        const parsed = new URL(uri);
        const pathName = parsed.pathname.replace(/^\/+/, '');
        return pathName ? decodeURIComponent(pathName) : null;
    } catch {
        return null;
    }
}
