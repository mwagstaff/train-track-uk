import assert from 'node:assert/strict';
import test from 'node:test';

import {
    DEVICE_DATA_DELETION_ROUTE,
    registerDeviceDataDeletionRoute
} from '../lib/device-data-route.js';

test('device-data deletion fails closed when the admin key is not configured', async () => {
    const { handler, service } = registeredHandler({ apiKey: '' });
    const response = responseRecorder();

    await handler(request({ authorization: 'Bearer deletion-test-key', body: 'installation-1' }), response);

    assert.equal(response.statusCode, 503);
    assert.deepEqual(response.payload, { error: 'Device data deletion is not configured' });
    assert.equal(service.calls.length, 0);
});

test('device-data deletion rejects missing or invalid bearer authorization', async () => {
    const { handler, service } = registeredHandler();
    const missingResponse = responseRecorder();
    const invalidResponse = responseRecorder();

    await handler(request({ authorization: '', body: 'installation-1' }), missingResponse);
    await handler(request({ authorization: 'Bearer wrong-key', body: 'installation-1' }), invalidResponse);

    assert.equal(missingResponse.statusCode, 401);
    assert.deepEqual(missingResponse.payload, { error: 'Unauthorized' });
    assert.equal(invalidResponse.statusCode, 401);
    assert.deepEqual(invalidResponse.payload, { error: 'Unauthorized' });
    assert.equal(service.calls.length, 0);
});

test('device-data deletion requires a bounded target identifier', async () => {
    const { handler, service } = registeredHandler();
    const missingResponse = responseRecorder();
    const oversizedResponse = responseRecorder();

    await handler(request({ body: '' }), missingResponse);
    await handler(request({ body: 'x'.repeat(201) }), oversizedResponse);

    assert.equal(missingResponse.statusCode, 400);
    assert.equal(oversizedResponse.statusCode, 400);
    assert.equal(service.calls.length, 0);
});

test('device-data deletion returns counts without echoing the installation ID', async () => {
    const { handler, service } = registeredHandler();
    const response = responseRecorder();

    await handler(request({ body: ' installation-1 ' }), response);

    assert.deepEqual(service.calls, ['installation-1']);
    assert.equal(response.statusCode, 200);
    assert.equal(response.payload.status, 'deleted');
    assert.equal(response.payload.deleted.persisted_records, 8);
    assert.equal(JSON.stringify(response.payload).includes('installation-1'), false);
});

function registeredHandler({ apiKey = 'deletion-test-key' } = {}) {
    let route = null;
    let handler = null;
    const app = {
        delete(registeredRoute, registeredHandler) {
            route = registeredRoute;
            handler = registeredHandler;
        }
    };
    const service = {
        calls: [],
        async deleteAllForDevice(deviceId) {
            this.calls.push(deviceId);
            return {
                persistedRecords: 8,
                auditLog: { deleted: 2 },
                runtime: { subscriptions: 1 },
                metricsLastSeen: true,
                collections: { notification_subscriptions: 1 }
            };
        }
    };
    registerDeviceDataDeletionRoute(app, service, { apiKey });
    assert.equal(route, DEVICE_DATA_DELETION_ROUTE);
    return { handler, service };
}

function request({ authorization = 'Bearer deletion-test-key', body }) {
    return {
        body: { device_id: body },
        get(name) {
            return name === 'Authorization' ? authorization : null;
        }
    };
}

function responseRecorder() {
    return {
        statusCode: 200,
        payload: null,
        status(code) {
            this.statusCode = code;
            return this;
        },
        json(payload) {
            this.payload = payload;
            return this;
        }
    };
}
