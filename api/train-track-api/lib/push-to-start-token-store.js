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
    },

    async list({ limit = 50 } = {}) {
        try {
            const keys = await redis.keys(`${REDIS_KEY_PREFIX}*`);
            const records = [];
            const boundedKeys = keys.slice(0, Math.max(1, Math.min(Number(limit) || 50, 500)));
            for (const key of boundedKeys) {
                const raw = await redis.get(key);
                if (!raw) continue;
                try {
                    const parsed = JSON.parse(raw);
                    if (!parsed?.pushToStartToken) continue;
                    records.push({
                        deviceId: parsed.deviceId || key.slice(REDIS_KEY_PREFIX.length),
                        token: maskToken(parsed.pushToStartToken),
                        useSandbox: Boolean(parsed.useSandbox),
                        updatedAt: parsed.updatedAt || null
                    });
                } catch {
                    // Ignore malformed diagnostic rows; the get/upsert path will replace them.
                }
            }
            records.sort((left, right) => {
                const leftTime = Date.parse(left.updatedAt || '') || 0;
                const rightTime = Date.parse(right.updatedAt || '') || 0;
                return rightTime - leftTime;
            });
            return records;
        } catch (error) {
            console.error('[live-activity] Failed to list push-to-start tokens from Redis:', error?.message || error);
            return [];
        }
    }
};

function maskToken(token) {
    const text = typeof token === 'string' ? token : '';
    if (text.length <= 12) return text ? '<redacted>' : '';
    return `${text.slice(0, 8)}...${text.slice(-6)}`;
}
