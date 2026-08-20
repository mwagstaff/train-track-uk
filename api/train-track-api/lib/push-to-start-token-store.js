import { recordSubscriptionAuditEvent } from './admin-data-store.js';
import { COLLECTIONS, getMongoCollection } from './mongo-client.js';
import { allowDeviceData, referencesDeletedDevice } from './device-data-deletion-state.js';

const MIN_PUSH_TO_START_TTL_SECONDS = Math.max(
    90 * 24 * 60 * 60,
    Number(process.env.PUSH_TO_START_MIN_TTL_SECONDS || '0') || 0
);
const PUSH_TO_START_TTL_SECONDS = Math.max(
    MIN_PUSH_TO_START_TTL_SECONDS,
    Number(process.env.PUSH_TO_START_TTL_SECONDS || '0') || 0
);

function normalizeDeviceId(value) {
    return typeof value === 'string' ? value.trim() : '';
}

export const pushToStartTokenStore = {
    async get(deviceId) {
        const normalizedDeviceId = normalizeDeviceId(deviceId);
        if (!normalizedDeviceId) return null;

        try {
            const collection = await getMongoCollection(COLLECTIONS.pushToStartTokens);
            const parsed = await collection.findOne({ _id: normalizedDeviceId });
            if (!parsed?.pushToStartToken) return null;
            const ttl = ttlDetailsForRecord(parsed);
            if (ttl.isExpired) {
                await this.delete(normalizedDeviceId, {
                    reason: 'logical_ttl_expired',
                    metadata: {
                        expires_at: ttl.expiresAt
                    }
                });
                return null;
            }
            return {
                ...withoutMongoId(parsed),
                deviceId: parsed.deviceId || normalizedDeviceId,
                ...ttl
            };
        } catch (error) {
            console.error('[live-activity] Failed to load push-to-start token from Mongo:', error?.message || error);
            return null;
        }
    },

    async upsert({ deviceId, pushToStartToken, useSandbox }) {
        const normalizedDeviceId = normalizeDeviceId(deviceId);
        const normalizedToken = typeof pushToStartToken === 'string' ? pushToStartToken.trim() : '';
        if (!normalizedDeviceId || !normalizedToken) {
            throw new Error('deviceId and pushToStartToken are required');
        }
        if (!allowDeviceData(normalizedDeviceId)) {
            throw new Error('Device data deletion is in progress');
        }

        const record = {
            _id: normalizedDeviceId,
            deviceId: normalizedDeviceId,
            pushToStartToken: normalizedToken,
            useSandbox: Boolean(useSandbox),
            updatedAt: new Date().toISOString(),
            expiresAt: new Date(Date.now() + (PUSH_TO_START_TTL_SECONDS * 1000))
        };

        try {
            const collection = await getMongoCollection(COLLECTIONS.pushToStartTokens);
            await collection.updateOne(
                { _id: normalizedDeviceId },
                { $set: record },
                { upsert: true }
            );
            if (referencesDeletedDevice(record)) {
                await collection.deleteOne({ _id: normalizedDeviceId });
                throw new Error('Device data deletion is in progress');
            }
            const ttl = ttlDetailsForRecord(record);
            await recordPushToStartAudit({
                action: 'push_to_start_upsert',
                reason: 'api_register',
                deviceId: normalizedDeviceId,
                useSandbox: record.useSandbox,
                token: normalizedToken,
                updatedAt: record.updatedAt,
                metadata: ttl
            });
            return {
                ...withoutMongoId(record),
                ...ttl
            };
        } catch (error) {
            console.error('[live-activity] Failed to save push-to-start token to Mongo:', error?.message || error);
            throw error;
        }
    },

    async delete(deviceId, { reason = 'delete', metadata = null } = {}) {
        const normalizedDeviceId = normalizeDeviceId(deviceId);
        if (!normalizedDeviceId) return false;

        try {
            const collection = await getMongoCollection(COLLECTIONS.pushToStartTokens);
            const existing = await collection.findOne({ _id: normalizedDeviceId });
            const result = await collection.deleteOne({ _id: normalizedDeviceId });
            const ttl = existing ? ttlDetailsForRecord(existing) : {};
            await recordPushToStartAudit({
                action: 'push_to_start_delete',
                reason,
                deviceId: normalizedDeviceId,
                useSandbox: existing?.useSandbox,
                token: existing?.pushToStartToken,
                metadata: {
                    deleted: result.deletedCount,
                    ttl_seconds: ttl.ttlSeconds,
                    expires_at: ttl.expiresAt,
                    ...metadata
                }
            });
            return result.deletedCount > 0;
        } catch (error) {
            console.error('[live-activity] Failed to delete push-to-start token from Mongo:', error?.message || error);
            return false;
        }
    },

    async list({ limit = 50 } = {}) {
        try {
            const collection = await getMongoCollection(COLLECTIONS.pushToStartTokens);
            const records = [];
            const safeLimit = Math.max(1, Math.min(Number(limit) || 50, 5000));
            const documents = await collection
                .find({})
                .sort({ updatedAt: -1 })
                .limit(safeLimit)
                .toArray();
            for (const parsed of documents) {
                try {
                    if (!parsed?.pushToStartToken) continue;
                    const deviceId = parsed.deviceId || parsed._id;
                    const ttl = ttlDetailsForRecord(parsed);
                    if (ttl.isExpired) {
                        await this.delete(deviceId, {
                            reason: 'logical_ttl_expired_list',
                            metadata: {
                                expires_at: ttl.expiresAt
                            }
                        });
                        continue;
                    }
                    records.push({
                        deviceId,
                        token: maskToken(parsed.pushToStartToken),
                        useSandbox: Boolean(parsed.useSandbox),
                        updatedAt: parsed.updatedAt || null,
                        ...ttl
                    });
                } catch {
                    // Ignore malformed diagnostic rows; the get/upsert path will replace them.
                }
            }
            return records;
        } catch (error) {
            console.error('[live-activity] Failed to list push-to-start tokens from Mongo:', error?.message || error);
            return [];
        }
    }
};

export const pushToStartTokenTtlPolicy = {
    minimumTtlSeconds: MIN_PUSH_TO_START_TTL_SECONDS,
    ttlSeconds: PUSH_TO_START_TTL_SECONDS
};

function ttlDetailsForRecord(record) {
    const expireTimestampMs = expiryTimestampForRecord(record);
    const now = Date.now();
    const ttlSeconds = expireTimestampMs
        ? Math.max(0, Math.ceil((expireTimestampMs - now) / 1000))
        : null;
    return {
        ttlSeconds,
        expiresAt: expireTimestampMs ? new Date(expireTimestampMs).toISOString() : null,
        isExpired: Boolean(expireTimestampMs && expireTimestampMs <= now),
        minimumTtlSeconds: MIN_PUSH_TO_START_TTL_SECONDS,
        configuredTtlSeconds: PUSH_TO_START_TTL_SECONDS
    };
}

function expiryTimestampForRecord(record) {
    const explicit = Date.parse(record?.expiresAt || '');
    if (Number.isFinite(explicit)) {
        return explicit;
    }
    const updated = Date.parse(record?.updatedAt || '');
    if (Number.isFinite(updated)) {
        return updated + (PUSH_TO_START_TTL_SECONDS * 1000);
    }
    return null;
}

function maskToken(token) {
    const text = typeof token === 'string' ? token : '';
    if (text.length <= 12) return text ? '<redacted>' : '';
    return `${text.slice(0, 8)}...${text.slice(-6)}`;
}

function withoutMongoId(record) {
    if (!record || typeof record !== 'object') return record;
    const { _id, ...rest } = record;
    return rest;
}

async function recordPushToStartAudit({ action, reason, deviceId, useSandbox, token, updatedAt = null, metadata = null }) {
    try {
        await recordSubscriptionAuditEvent({
            action,
            reason,
            device_id: deviceId,
            metadata: {
                use_sandbox: Boolean(useSandbox),
                token: maskToken(token),
                updated_at: updatedAt,
                ...metadata
            }
        });
    } catch (error) {
        console.error('[live-activity] Failed to audit push-to-start token event:', error?.message || error);
    }
}
