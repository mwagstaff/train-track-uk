import { COLLECTIONS, getMongoCollection } from './mongo-client.js';

function normalizeDeviceId(value) {
    return typeof value === 'string' ? value.trim() : '';
}

export const holidayModeStore = {
    async set(deviceId, enabled) {
        const normalizedDeviceId = normalizeDeviceId(deviceId);
        if (!normalizedDeviceId) {
            throw new Error('deviceId is required');
        }
        const collection = await getMongoCollection(COLLECTIONS.holidayMode);
        await collection.updateOne(
            { _id: normalizedDeviceId },
            { $set: { _id: normalizedDeviceId, deviceId: normalizedDeviceId, enabled: Boolean(enabled), updatedAt: new Date().toISOString() } },
            { upsert: true }
        );
    },

    async listEnabledDeviceIds() {
        const collection = await getMongoCollection(COLLECTIONS.holidayMode);
        const documents = await collection.find({ enabled: true }).project({ deviceId: 1 }).toArray();
        return documents.map((doc) => doc.deviceId).filter(Boolean);
    }
};
