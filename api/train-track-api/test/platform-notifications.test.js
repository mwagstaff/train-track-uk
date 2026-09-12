import assert from 'node:assert/strict';
import test from 'node:test';

import { NotificationSubscriptionManager } from '../lib/notification-subscription-manager.js';

test('notifies when the next train is assigned a platform', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();

    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure(null)
    ), ['platform']);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('2')
    ), ['platform']);

    assert.equal(notifications.length, 1);
    assert.equal(notifications[0].aps.alert.body, 'Platform announced: 17:12 - platform 2.');
});

test('notifies when the next train changes numbered platform', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();

    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('3')
    ), ['platform']);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('5')
    ), ['platform']);

    assert.equal(notifications.length, 1);
    assert.equal(notifications[0].aps.alert.body, 'Platform alteration: 17:12 - now platform 5.');
});

test('does not notify when an assigned platform becomes TBC', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();

    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('3')
    ), ['platform']);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('TBC')
    ), ['platform']);

    assert.equal(notifications.length, 0);
});

async function testSetup() {
    const manager = new NotificationSubscriptionManager();
    const notifications = [];
    manager._saveSubscription = async () => {};
    manager.recordSubscriptionAudit = async () => {};
    manager.auditScheduledPushToStartReadiness = async () => {};
    manager.logSendEvent = () => {};
    manager.pushClient.sendNotification = async (_token, payload) => {
        notifications.push(payload);
        return { status: 200 };
    };

    const created = await manager.upsertSubscription({
        deviceId: 'platform-device',
        pushToken: 'push-token',
        routeKey: 'VIC-KTH',
        scheduleKind: 'regular',
        daysOfWeek: ['mon'],
        notificationTypes: ['platform'],
        legs: [{
            from: 'VIC',
            fromName: 'London Victoria',
            to: 'KTH',
            toName: 'Kent House',
            enabled: true,
            windowStart: '16:30',
            windowEnd: '18:30'
        }],
        source: 'scheduled'
    });
    const subscription = manager.subscriptions.get(created.id);

    return { manager, notifications, subscription, leg: subscription.legs[0] };
}

function departures(...items) {
    return { departures: items, fetchedAt: new Date().toISOString() };
}

function departure(platform) {
    return {
        serviceID: 'service-1',
        scheduled: '17:12',
        estimated: '17:12',
        platform,
        isCancelled: false
    };
}
