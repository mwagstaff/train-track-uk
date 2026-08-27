import assert from 'node:assert/strict';
import test from 'node:test';

import { NotificationSubscriptionManager } from '../lib/notification-subscription-manager.js';

test('scheduled live-session origin is returned to clients', async () => {
    const manager = testManager();

    const subscription = await manager.upsertSubscription(registration({
        liveSessionOrigin: 'scheduled'
    }));

    assert.equal(subscription.source, 'live_session');
    assert.equal(subscription.live_session_origin, 'scheduled');
});

test('live sessions without an origin remain manual', async () => {
    const manager = testManager();

    const subscription = await manager.upsertSubscription(registration());

    assert.equal(subscription.live_session_origin, 'manual');
});

test('scheduled live-session registration is idempotent for a device route', async () => {
    const manager = testManager();

    const first = await manager.upsertSubscription(registration({
        liveSessionOrigin: 'scheduled'
    }));
    const second = await manager.upsertSubscription(registration({
        liveSessionOrigin: 'scheduled'
    }));

    assert.equal(second.id, first.id);
    assert.equal(manager.listAllSubscriptions().length, 1);
});

test('scheduled live-session registration removes legacy duplicates for the route', async () => {
    const manager = testManager();
    manager._deleteFromMongo = async () => {};

    await manager.upsertSubscription(victoriaToKentHouseLiveRegistration());
    await manager.upsertSubscription(victoriaToKentHouseLiveRegistration());
    await manager.upsertSubscription(victoriaToKentHouseLiveRegistration());
    for (const subscription of manager.subscriptions.values()) {
        subscription.liveSessionOrigin = 'scheduled';
    }

    const retained = await manager.upsertSubscription(victoriaToKentHouseLiveRegistration({
        liveSessionOrigin: 'scheduled'
    }));

    assert.equal(manager.listAllSubscriptions().length, 1);
    assert.equal(manager.listAllSubscriptions()[0].id, retained.id);
});

test('station exit retires every live session for the muted leg', async () => {
    const manager = testManager();
    manager._deleteFromMongo = async () => {};
    manager.pushClient = {
        sendNotification: async () => ({ status: 200 })
    };
    manager.logSendEvent = () => {};

    const scheduled = await manager.upsertSubscription(scheduledRegistration());
    await manager.upsertSubscription(victoriaToKentHouseLiveRegistration());
    await manager.upsertSubscription(victoriaToKentHouseLiveRegistration());
    await manager.upsertSubscription(victoriaToKentHouseLiveRegistration());

    const result = await manager.muteLegForDate({
        deviceId: 'device-1',
        subscriptionId: scheduled.id,
        from: 'VIC',
        to: 'KTH',
        reason: 'station_exit',
        transition: 'station_exit',
        detectionSource: 'continuous_location',
        journeyNotificationBody: "You’re on the 17:42 to Kent House. Enjoy your journey!"
    });

    assert.equal(result.removedLiveSessions, 3);
    assert.equal(
        manager.listAllSubscriptions().filter((subscription) => subscription.source === 'live_session').length,
        0
    );
});

test('an in-flight poll save cannot recreate a retired live session', async () => {
    let releaseUpdate;
    let markUpdateStarted;
    const updateStarted = new Promise((resolve) => {
        markUpdateStarted = resolve;
    });
    const updateGate = new Promise((resolve) => {
        releaseUpdate = resolve;
    });
    const deletedIds = [];
    const collection = {
        updateOne: async () => {
            markUpdateStarted();
            await updateGate;
        },
        deleteOne: async ({ _id }) => {
            deletedIds.push(_id);
        }
    };
    const manager = new NotificationSubscriptionManager({
        getCollection: async () => collection
    });
    const subscription = { id: 'live-session-1', deviceId: 'device-1' };
    manager.subscriptions.set(subscription.id, subscription);

    const save = manager._saveSubscription(subscription);
    await updateStarted;
    manager.subscriptions.delete(subscription.id);
    releaseUpdate();
    await save;

    assert.deepEqual(deletedIds, [subscription.id]);
});

function testManager() {
    const manager = new NotificationSubscriptionManager();
    manager._saveSubscription = async () => {};
    manager.recordSubscriptionAudit = async () => {};
    return manager;
}

function registration(overrides = {}) {
    return {
        deviceId: 'device-1',
        pushToken: 'push-token',
        routeKey: 'KTH-VIC',
        daysOfWeek: ['mon'],
        notificationTypes: ['delays', 'platform'],
        legs: [{
            from: 'KTH',
            to: 'VIC',
            fromName: 'Kent House',
            toName: 'London Victoria',
            enabled: true,
            windowStart: '00:00',
            windowEnd: '23:59'
        }],
        source: 'live_session',
        activeUntil: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
        ...overrides
    };
}

function scheduledRegistration(overrides = {}) {
    return {
        deviceId: 'device-1',
        pushToken: 'push-token',
        routeKey: 'VIC-KTH',
        scheduleKind: 'regular',
        daysOfWeek: ['wed'],
        notificationTypes: ['summary', 'delays', 'platform'],
        legs: [{
            from: 'VIC',
            to: 'KTH',
            fromName: 'London Victoria',
            toName: 'Kent House',
            enabled: true,
            windowStart: '16:00',
            windowEnd: '18:00'
        }],
        source: 'scheduled',
        ...overrides
    };
}

function victoriaToKentHouseLiveRegistration(overrides = {}) {
    return registration({
        routeKey: 'VIC-KTH',
        legs: [{
            from: 'VIC',
            to: 'KTH',
            fromName: 'London Victoria',
            toName: 'Kent House',
            enabled: true,
            windowStart: '00:00',
            windowEnd: '23:59'
        }],
        ...overrides
    });
}
