import assert from 'node:assert/strict';
import test from 'node:test';

import { NotificationSubscriptionManager } from '../lib/notification-subscription-manager.js';

test('announces an initially cancelled next train and the next available service', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();
    const snapshot = departures(
        departure('cancelled-next', '17:12', true),
        departure('also-cancelled', '17:27', true),
        departure('next-running', '17:42')
    );

    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', snapshot, ['delays']);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', snapshot, ['delays']);

    assert.equal(notifications.length, 1);
    assert.equal(
        notifications[0].aps.alert.body,
        '‼️ 17:12 to Kent House cancelled, next service 17:42'
    );
});

test('announces when a previously running service becomes cancelled', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();

    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('first', '17:12'),
        departure('later', '17:42'),
        departure('following', '18:12')
    ), ['delays']);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('first', '17:12'),
        departure('later', '17:42', true),
        departure('following', '18:12')
    ), ['delays']);

    assert.equal(notifications.length, 1);
    assert.equal(
        notifications[0].aps.alert.body,
        '‼️ 17:42 to Kent House cancelled, next service 18:12'
    );
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
        deviceId: 'device-1',
        pushToken: 'push-token',
        routeKey: 'VIC-KTH',
        scheduleKind: 'regular',
        daysOfWeek: ['mon'],
        notificationTypes: ['delays'],
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

function departure(serviceID, scheduled, isCancelled = false) {
    return {
        serviceID,
        scheduled,
        estimated: scheduled,
        platform: '2',
        isCancelled
    };
}
