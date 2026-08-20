import crypto from 'crypto';

const ROUTE_PATH = '/api/v2/device_data';
const MAX_DEVICE_ID_LENGTH = 200;

export function registerDeviceDataDeletionRoute(app, deletionService, options = {}) {
    const apiKey = normalizeSecret(options.apiKey ?? process.env.DEVICE_DATA_DELETION_API_KEY);

    app.delete(ROUTE_PATH, async (req, res) => {
        if (!apiKey) {
            return res.status(503).json({ error: 'Device data deletion is not configured' });
        }
        if (!hasValidBearerAuthorization(req.get('Authorization'), apiKey)) {
            return res.status(401).json({ error: 'Unauthorized' });
        }

        const bodyDeviceId = normalizeDeviceId(req.body?.device_id);

        if (!bodyDeviceId || bodyDeviceId.length > MAX_DEVICE_ID_LENGTH) {
            return res.status(400).json({ error: 'A valid device_id is required' });
        }

        try {
            const result = await deletionService.deleteAllForDevice(bodyDeviceId);
            return res.json({
                status: 'deleted',
                deleted: {
                    persisted_records: result.persistedRecords,
                    audit_log: result.auditLog,
                    runtime: result.runtime,
                    metrics_last_seen: result.metricsLastSeen,
                    collections: result.collections
                }
            });
        } catch (error) {
            console.error('[privacy] Device-data deletion failed', JSON.stringify({
                name: error?.name || 'Error',
                code: error?.code || null
            }));
            return res.status(500).json({ error: 'Unable to delete server data' });
        }
    });
}

export { ROUTE_PATH as DEVICE_DATA_DELETION_ROUTE };

function normalizeDeviceId(value) {
    return typeof value === 'string' ? value.trim() : '';
}

function normalizeSecret(value) {
    return typeof value === 'string' ? value.trim() : '';
}

function hasValidBearerAuthorization(authorization, expectedKey) {
    if (typeof authorization !== 'string') return false;
    const match = /^Bearer\s+(.+)$/i.exec(authorization.trim());
    if (!match) return false;
    const suppliedKey = Buffer.from(match[1], 'utf8');
    const configuredKey = Buffer.from(expectedKey, 'utf8');
    return suppliedKey.length === configuredKey.length
        && crypto.timingSafeEqual(suppliedKey, configuredKey);
}
