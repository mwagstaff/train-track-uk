import redis from './redis-client.js';

const REDIS_KEY_PREFIX = 'tt:live_activity:push_to_start:';

function redisKey(deviceId) {
    return `${REDIS_KEY_PREFIX}${deviceId}`;
}

function normalizeDeviceId(value) {
    return typeof value === 'string' ? value.trim() : '';
}

export const pushToStartTokenStore = {
    async get(deviceId) {
        const normalizedDeviceId = normalizeDeviceId(deviceId);
        if (!normalizedDeviceId) return null;

        try {
            const raw = await redis.get(redisKey(normalizedDeviceId));
            if (!raw) return null;
            const parsed = JSON.parse(raw);
            if (!parsed?.pushToStartToken) return null;
            return parsed;
        } catch (error) {
            console.error('[live-activity] Failed to load push-to-start token from Redis:', error?.message || error);
            return null;
        }
    },

    async upsert({ deviceId, pushToStartToken, useSandbox }) {
        const normalizedDeviceId = normalizeDeviceId(deviceId);
        const normalizedToken = typeof pushToStartToken === 'string' ? pushToStartToken.trim() : '';
        if (!normalizedDeviceId || !normalizedToken) {
            throw new Error('deviceId and pushToStartToken are required');
        }

        const record = {
            deviceId: normalizedDeviceId,
            pushToStartToken: normalizedToken,
            useSandbox: Boolean(useSandbox),
            updatedAt: new Date().toISOString()
        };

        try {
            await redis.set(redisKey(normalizedDeviceId), JSON.stringify(record));
            return record;
        } catch (error) {
            console.error('[live-activity] Failed to save push-to-start token to Redis:', error?.message || error);
            throw error;
        }
    },

    async delete(deviceId) {
        const normalizedDeviceId = normalizeDeviceId(deviceId);
        if (!normalizedDeviceId) return false;

        try {
            const deleted = await redis.del(redisKey(normalizedDeviceId));
            return deleted > 0;
        } catch (error) {
            console.error('[live-activity] Failed to delete push-to-start token from Redis:', error?.message || error);
            return false;
        }
    }
};
