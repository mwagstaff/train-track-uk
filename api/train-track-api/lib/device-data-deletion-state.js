const deletedDeviceIds = new Set();
const deletingDeviceIds = new Set();

export function markDeviceDataDeleted(deviceId) {
    const normalizedDeviceId = normalizeDeviceId(deviceId);
    if (!normalizedDeviceId) return;
    deletedDeviceIds.add(normalizedDeviceId);
    deletingDeviceIds.add(normalizedDeviceId);
}

export function finishDeviceDataDeletion(deviceId) {
    const normalizedDeviceId = normalizeDeviceId(deviceId);
    if (normalizedDeviceId) deletingDeviceIds.delete(normalizedDeviceId);
}

export function allowDeviceData(deviceId) {
    const normalizedDeviceId = normalizeDeviceId(deviceId);
    if (!normalizedDeviceId || deletingDeviceIds.has(normalizedDeviceId)) return false;
    deletedDeviceIds.delete(normalizedDeviceId);
    return true;
}

export function referencesDeletedDevice(value) {
    return referencedDeviceIds(value).some((deviceId) => deletedDeviceIds.has(deviceId));
}

function referencedDeviceIds(value) {
    if (!value || typeof value !== 'object') return [];
    if (Array.isArray(value)) return value.flatMap(referencedDeviceIds);

    const deviceIds = [];
    for (const [key, entry] of Object.entries(value)) {
        if (DEVICE_ID_KEYS.has(key)) {
            const deviceId = normalizeDeviceId(entry);
            if (deviceId) deviceIds.push(deviceId);
        } else if (entry && typeof entry === 'object') {
            deviceIds.push(...referencedDeviceIds(entry));
        }
    }
    return deviceIds;
}

const DEVICE_ID_KEYS = new Set([
    'device_id',
    'deviceId',
    'target_device_id',
    'targetDeviceId'
]);

function normalizeDeviceId(value) {
    return typeof value === 'string' ? value.trim() : '';
}
