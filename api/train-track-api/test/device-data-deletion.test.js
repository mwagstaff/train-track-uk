import assert from 'node:assert/strict';
import test from 'node:test';

import { DeviceDataDeletionService } from '../lib/device-data-deletion.js';
import { COLLECTIONS } from '../lib/mongo-client.js';
import { NotificationSubscriptionManager } from '../lib/notification-subscription-manager.js';
import {
    allowDeviceData,
    finishDeviceDataDeletion,
    markDeviceDataDeleted,
    referencesDeletedDevice
} from '../lib/device-data-deletion-state.js';

test('delete-all removes device data while retaining shared recent departures', async () => {
    const deviceId = 'installation-1';
    const notificationToken = 'notification-token-1234567890';
    const liveActivityToken = 'live-activity-token-1234567890';
    const pushToStartToken = 'push-to-start-token-1234567890';
    const database = fakeDatabase({
        [COLLECTIONS.notificationSubscriptions]: [
            { _id: 'subscription-1', id: 'subscription-1', deviceId, pushToken: notificationToken },
            { _id: 'subscription-2', id: 'subscription-2', deviceId: 'installation-2', pushToken: 'other-token' }
        ],
        [COLLECTIONS.pushToStartTokens]: [
            { _id: deviceId, deviceId, pushToStartToken },
            { _id: 'installation-2', deviceId: 'installation-2', pushToStartToken: 'other-token' }
        ],
        [COLLECTIONS.liveActivitySessions]: [
            { _id: `${deviceId}::activity-1`, deviceId, activityId: 'activity-1', pushToken: liveActivityToken },
            { _id: 'installation-2::activity-2', deviceId: 'installation-2', activityId: 'activity-2' }
        ],
        [COLLECTIONS.devicePreferences]: [
            { _id: deviceId, device_id: deviceId },
            { _id: 'installation-2', device_id: 'installation-2' }
        ],
        [COLLECTIONS.notificationEvents]: [
            { _id: 'notification-1', device_id: deviceId },
            { _id: 'notification-2', subscription_id: 'subscription-1' },
            { _id: 'notification-3', device_id: 'installation-2' }
        ],
        [COLLECTIONS.pushAuditEvents]: [
            { _id: 'push-1', context: { device_id: deviceId } },
            { _id: 'push-2', token: maskToken(notificationToken) },
            { _id: 'push-3', context: { device_id: 'installation-2' } }
        ],
        [COLLECTIONS.liveActivityPayloads]: [
            { _id: 'payload-1', context: { target_activity_id: 'activity-1' } },
            { _id: 'payload-2', context: { target_activity_id: 'activity-2' } }
        ],
        [COLLECTIONS.subscriptionAuditEvents]: [
            { _id: 'audit-1', before: { deviceId } },
            { _id: 'audit-2', before: { deviceId: 'installation-2' } }
        ],
        [COLLECTIONS.geofenceEvents]: [
            { _id: 'geofence-1', device_id: deviceId },
            { _id: 'geofence-2', device_id: 'installation-2' }
        ],
        [COLLECTIONS.holidayMode]: [
            { _id: deviceId, deviceId },
            { _id: 'installation-2', deviceId: 'installation-2' }
        ],
        [COLLECTIONS.recentDepartures]: [
            { _id: 'KTH:VIC:service-1', serviceID: 'service-1', fromCRS: 'KTH', toCRS: 'VIC' }
        ]
    });
    const calls = [];
    const service = new DeviceDataDeletionService({
        getCollection: async (name) => database.collection(name, calls),
        purgeRuntimeState: async (requestedDeviceId) => {
            calls.push(`runtime:${requestedDeviceId}`);
            return { subscriptions: 2, liveActivities: 1, journeyTracking: 1 };
        },
        deleteAuditLogEntries: async (requestedDeviceId, associations) => {
            calls.push(`audit-log:${requestedDeviceId}`);
            assert.deepEqual(associations, {
                subscriptionIds: ['subscription-1'],
                activityIds: ['activity-1']
            });
            assert.equal(database.documents(COLLECTIONS.notificationSubscriptions).length, 2);
            assert.equal(database.documents(COLLECTIONS.liveActivitySessions).length, 2);
            assert.equal(database.documents(COLLECTIONS.pushToStartTokens).length, 2);
            return { deleted: 3, files: 2 };
        },
        markDeviceDataDeleted: (requestedDeviceId) => {
            calls.push(`mark:${requestedDeviceId}`);
        },
        finishDeviceDataDeletion: (requestedDeviceId) => {
            calls.push(`finish:${requestedDeviceId}`);
        },
        forgetDeviceLastSeen: (requestedDeviceId) => {
            calls.push(`metrics:${requestedDeviceId}`);
            return true;
        }
    });

    const result = await service.deleteAllForDevice(deviceId);

    assert.equal(result.persistedRecords, 12);
    assert.deepEqual(result.auditLog, { deleted: 3, files: 2 });
    assert.equal(result.metricsLastSeen, true);
    assert.deepEqual(result.runtime, { subscriptions: 2, liveActivities: 1, journeyTracking: 1 });
    assert.equal(calls.indexOf(`mark:${deviceId}`) < calls.indexOf(`runtime:${deviceId}`), true);
    assert.equal(calls.indexOf(`runtime:${deviceId}`) < calls.findIndex((call) => call.startsWith('delete:')), true);
    assert.equal(calls.indexOf(`delete:${COLLECTIONS.notificationEvents}`) < calls.indexOf(`audit-log:${deviceId}`), true);
    assert.equal(calls.indexOf(`audit-log:${deviceId}`) < calls.indexOf(`delete:${COLLECTIONS.notificationSubscriptions}`), true);
    assert.equal(calls.at(-2), `metrics:${deviceId}`);
    assert.equal(calls.at(-1), `finish:${deviceId}`);

    for (const collectionName of Object.values(COLLECTIONS).filter((name) => name !== COLLECTIONS.recentDepartures)) {
        assert.equal(
            JSON.stringify(database.documents(collectionName)).includes(deviceId),
            false,
            `${collectionName} retained data for the deleted installation`
        );
    }
    assert.equal(database.documents(COLLECTIONS.notificationSubscriptions).length, 1);
    assert.equal(database.documents(COLLECTIONS.pushAuditEvents).length, 1);
    assert.equal(database.documents(COLLECTIONS.recentDepartures).length, 1);
});

test('delete-all rejects an empty device identifier before touching storage', async () => {
    let touchedStorage = false;
    const service = new DeviceDataDeletionService({
        getCollection: async () => {
            touchedStorage = true;
            throw new Error('should not be called');
        }
    });

    await assert.rejects(() => service.deleteAllForDevice('  '), /deviceId is required/);
    assert.equal(touchedStorage, false);
});

test('concurrent delete-all requests for one installation share a single sweep', async () => {
    const database = fakeDatabase({});
    const calls = [];
    let marks = 0;
    let finishes = 0;
    const service = new DeviceDataDeletionService({
        getCollection: async (name) => database.collection(name, calls),
        markDeviceDataDeleted: () => { marks += 1; },
        finishDeviceDataDeletion: () => { finishes += 1; }
    });

    const [first, second] = await Promise.all([
        service.deleteAllForDevice('installation-concurrent'),
        service.deleteAllForDevice('installation-concurrent')
    ]);

    assert.deepEqual(first, second);
    assert.equal(marks, 1);
    assert.equal(finishes, 1);
    assert.equal(
        calls.filter((call) => call.startsWith('delete:')).length,
        Object.keys(COLLECTIONS).length - 1
    );
});

test('Mongo and audit-log failures retain association sources for a complete retry', async () => {
    const deviceId = 'installation-retry';
    const notificationToken = 'notification-token-retry-123456';
    const pushToStartToken = 'push-to-start-retry-123456';
    const calls = [];
    const database = fakeDatabase({
        [COLLECTIONS.notificationSubscriptions]: [{
            _id: 'subscription-retry',
            id: 'subscription-retry',
            deviceId,
            pushToken: notificationToken
        }],
        [COLLECTIONS.liveActivitySessions]: [{
            _id: `${deviceId}::activity-retry`,
            deviceId,
            activityId: 'activity-retry',
            pushToken: 'live-token-retry-123456'
        }],
        [COLLECTIONS.pushToStartTokens]: [{
            _id: deviceId,
            deviceId,
            pushToStartToken
        }],
        [COLLECTIONS.notificationEvents]: [{
            _id: 'notification-indirect',
            subscription_id: 'subscription-retry'
        }],
        [COLLECTIONS.pushAuditEvents]: [{
            _id: 'push-indirect',
            token: maskToken(pushToStartToken)
        }],
        [COLLECTIONS.liveActivityPayloads]: [{
            _id: 'payload-indirect',
            context: { target_activity_id: 'activity-retry' }
        }]
    });
    let failMongoSweep = true;
    let failAuditLogSweep = true;
    let auditLogAttempts = 0;
    let marks = 0;
    let finishes = 0;
    const service = new DeviceDataDeletionService({
        getCollection: async (name) => {
            const collection = database.collection(name, calls);
            if (name !== COLLECTIONS.pushAuditEvents) return collection;
            return {
                ...collection,
                async deleteMany(filter) {
                    if (failMongoSweep) {
                        failMongoSweep = false;
                        throw new Error('transient Mongo delete failure');
                    }
                    return collection.deleteMany(filter);
                }
            };
        },
        deleteAuditLogEntries: async (_requestedDeviceId, associations) => {
            auditLogAttempts += 1;
            assert.deepEqual(associations, {
                subscriptionIds: ['subscription-retry'],
                activityIds: ['activity-retry']
            });
            if (failAuditLogSweep) {
                failAuditLogSweep = false;
                throw new Error('transient audit-log delete failure');
            }
            return { deletedCount: 1 };
        },
        markDeviceDataDeleted: () => { marks += 1; },
        finishDeviceDataDeletion: () => { finishes += 1; }
    });

    await assert.rejects(
        () => service.deleteAllForDevice(deviceId),
        /transient Mongo delete failure/
    );
    assert.equal(finishes, 0);
    assert.equal(auditLogAttempts, 0);
    assert.equal(database.documents(COLLECTIONS.notificationSubscriptions).length, 1);
    assert.equal(database.documents(COLLECTIONS.liveActivitySessions).length, 1);
    assert.equal(database.documents(COLLECTIONS.pushToStartTokens).length, 1);
    assert.equal(database.documents(COLLECTIONS.pushAuditEvents).length, 1);

    await assert.rejects(
        () => service.deleteAllForDevice(deviceId),
        /transient audit-log delete failure/
    );
    assert.equal(finishes, 0);
    assert.equal(auditLogAttempts, 1);
    assert.equal(database.documents(COLLECTIONS.notificationSubscriptions).length, 1);
    assert.equal(database.documents(COLLECTIONS.liveActivitySessions).length, 1);
    assert.equal(database.documents(COLLECTIONS.pushToStartTokens).length, 1);

    const retry = await service.deleteAllForDevice(deviceId);
    assert.equal(retry.persistedRecords, 3);
    assert.equal(auditLogAttempts, 2);
    assert.equal(marks, 3);
    assert.equal(finishes, 1);
    assert.equal(database.documents(COLLECTIONS.notificationSubscriptions).length, 0);
    assert.equal(database.documents(COLLECTIONS.liveActivitySessions).length, 0);
    assert.equal(database.documents(COLLECTIONS.pushToStartTokens).length, 0);
    assert.equal(database.documents(COLLECTIONS.notificationEvents).length, 0);
    assert.equal(database.documents(COLLECTIONS.pushAuditEvents).length, 0);
    assert.equal(database.documents(COLLECTIONS.liveActivityPayloads).length, 0);
});

test('a notification save already in flight is removed if deletion starts before it completes', async () => {
    let releaseUpdate;
    const updateStarted = new Promise((resolve) => {
        releaseUpdate = resolve;
    });
    let completeUpdate;
    const updateCanComplete = new Promise((resolve) => {
        completeUpdate = resolve;
    });
    const calls = [];
    const collection = {
        async updateOne() {
            calls.push('update-started');
            releaseUpdate();
            await updateCanComplete;
            calls.push('update-completed');
        },
        async deleteOne() {
            calls.push('delete');
        }
    };
    const manager = new NotificationSubscriptionManager({
        getCollection: async () => collection
    });
    const subscription = { id: 'subscription-1', deviceId: 'installation-race' };

    const save = manager._saveSubscription(subscription);
    await updateStarted;
    manager.purgeDeviceRuntimeState(subscription.deviceId);
    completeUpdate();
    await save;

    assert.deepEqual(calls, ['update-started', 'update-completed', 'delete']);
});

test('new device writes stay blocked until an active deletion sweep finishes', () => {
    const deviceId = 'installation-deletion-lock';

    markDeviceDataDeleted(deviceId);
    assert.equal(allowDeviceData(deviceId), false);
    assert.equal(referencesDeletedDevice({ context: { device_id: deviceId } }), true);

    finishDeviceDataDeletion(deviceId);
    assert.equal(allowDeviceData(deviceId), true);
    assert.equal(referencesDeletedDevice({ deviceId }), false);
});

function fakeDatabase(seed) {
    const records = new Map(
        Object.values(COLLECTIONS).map((name) => [name, structuredClone(seed[name] || [])])
    );
    return {
        collection(name, calls) {
            if (!records.has(name)) records.set(name, []);
            return {
                find(filter) {
                    const matches = records.get(name).filter((record) => matchesFilter(record, filter));
                    return {
                        project() {
                            return this;
                        },
                        async toArray() {
                            return structuredClone(matches);
                        }
                    };
                },
                async deleteMany(filter) {
                    calls.push(`delete:${name}`);
                    const before = records.get(name);
                    const retained = before.filter((record) => !matchesFilter(record, filter));
                    records.set(name, retained);
                    return { deletedCount: before.length - retained.length };
                }
            };
        },
        documents(name) {
            return records.get(name) || [];
        }
    };
}

function matchesFilter(record, filter) {
    if (Array.isArray(filter?.$or)) {
        return filter.$or.some((candidate) => matchesFilter(record, candidate));
    }
    return Object.entries(filter || {}).every(([path, expected]) => {
        const actual = valueAtPath(record, path);
        if (expected && typeof expected === 'object' && Array.isArray(expected.$in)) {
            return expected.$in.includes(actual);
        }
        return actual === expected;
    });
}

function valueAtPath(record, path) {
    return path.split('.').reduce((value, key) => value?.[key], record);
}

function maskToken(token) {
    return `${token.slice(0, 8)}...${token.slice(-6)}`;
}
