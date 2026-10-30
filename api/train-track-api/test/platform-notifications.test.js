import assert from 'node:assert/strict';
import test from 'node:test';

import { NotificationSubscriptionManager } from '../lib/notification-subscription-manager.js';

test('default platform preference waits for welcome arrival and does not replay suppressed changes', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();
    subscription.journeyPhaseByLeg = {};
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(departure('1')), ['platform']);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(departure('2')), ['platform']);
    assert.equal(notifications.length, 0);
    await manager.recordJourneyPhase(subscription.deviceId, { fromStation: 'VIC', toStation: 'KTH', phase: 'at_start' });
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(departure('2')), ['platform']);
    assert.equal(notifications.length, 0);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(departure('3')), ['platform']);
    assert.equal(notifications.length, 1);
});

test('station state is scoped to the route, day and most recent phase', async () => {
    const { manager, subscription, leg } = await testSetup();
    subscription.journeyPhaseByLeg = {};
    await manager.recordJourneyPhase(subscription.deviceId, { fromStation: 'KTH', toStation: 'VIC', phase: 'at_start' });
    assert.equal(manager.isAtStation(subscription, leg, 'VIC-KTH'), false);
    await manager.recordJourneyPhase(subscription.deviceId, { fromStation: 'VIC', toStation: 'KTH', phase: 'at_start', statusObservedAtMs: Date.now() - 86400000 });
    assert.equal(manager.isAtStation(subscription, leg, 'VIC-KTH'), false);
    await manager.recordJourneyPhase(subscription.deviceId, { fromStation: 'VIC', toStation: 'KTH', phase: 'at_start', statusObservedAtMs: Date.now() - 1000 });
    assert.equal(manager.isAtStation(subscription, leg, 'VIC-KTH'), true);
    await manager.recordJourneyPhase(subscription.deviceId, { fromStation: 'VIC', toStation: 'KTH', phase: 'pending_start' });
    assert.equal(manager.isAtStation(subscription, leg, 'VIC-KTH'), true);
    await manager.recordJourneyPhase(subscription.deviceId, { fromStation: 'VIC', toStation: 'KTH', phase: 'en_route' });
    await manager.recordJourneyPhase(subscription.deviceId, { fromStation: 'VIC', toStation: 'KTH', phase: 'at_start', statusObservedAtMs: Date.now() - 2000 });
    assert.equal(manager.isAtStation(subscription, leg, 'VIC-KTH'), false);
});

test('opting out permits platform notifications before station arrival', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();
    subscription.journeyPhaseByLeg = {};
    manager.getNotificationPreferences = async () => ({ platformOnlyNearStation: false });
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(departure('1')), ['platform']);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(departure('2')), ['platform']);
    assert.equal(notifications.length, 1);
});

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

test('scheduled alerts identify a remotely started Live Activity', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();

    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure(null)
    ), ['platform']);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('2')
    ), ['platform']);
    const scheduleDate = notifications[0].schedule_key.split('|').at(-1);
    subscription.lastAutoStartSentByLeg = { 'VIC-KTH': scheduleDate };
    subscription.lastAutoStartSentAtByLeg = { 'VIC-KTH': '2026-09-13T16:30:00.000Z' };

    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('3')
    ), ['platform']);

    assert.equal(notifications[1].live_activity_auto_started, true);
    assert.equal(notifications[1].live_activity_auto_started_at, '2026-09-13T16:30:00.000Z');
});

test('dismissing a scheduled occurrence mutes that occurrence and deletes its live session', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure(null)
    ), ['platform']);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('2')
    ), ['platform']);
    const scheduleKey = notifications[0].schedule_key;
    let removedLiveSessions = 0;
    manager.deleteLiveSessionsForLeg = async ({ from, to }) => {
        assert.equal(from, 'VIC');
        assert.equal(to, 'KTH');
        removedLiveSessions += 1;
        return 1;
    };

    const result = await manager.dismissScheduledOccurrence({
        deviceId: subscription.deviceId,
        scheduleKey
    });

    assert.deepEqual(result, { matched: 1, removedLiveSessions: 1 });
    assert.equal(manager.isMutedToday(subscription, 'VIC-KTH'), true);
    assert.equal(removedLiveSessions, 1);

    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(
        departure('3')
    ), ['platform']);
    assert.equal(notifications.length, 1);
});

test('boarding the 16:42 suppresses a later 16:57 platform announcement after schedule refresh', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();
    await manager.muteLegForDate({
        deviceId: subscription.deviceId, subscriptionId: subscription.id,
        from: 'VIC', to: 'KTH', reason: 'station_exit'
    });
    notifications.length = 0;
    manager.getDeviceTrackingSessions = (deviceId) => deviceId === subscription.deviceId
        ? [{ source: 'scheduled', from: 'VIC', to: 'KTH', service_id: 'service-1642' }]
        : [];
    await manager.upsertSubscription({ ...subscription, subscriptionId: subscription.id });
    const refreshed = manager.subscriptions.get(subscription.id);
    const later = { ...departure(null), serviceID: 'service-1657', scheduled: '16:57', estimated: '16:57' };
    await manager.sendUpdateNotifications(refreshed, leg, 'VIC-KTH', departures(later), ['platform']);
    await manager.sendUpdateNotifications(refreshed, leg, 'VIC-KTH', departures({ ...later, platform: '3' }), ['platform']);
    assert.equal(notifications.length, 0);
});

test('an en-route Live Activity suppresses platform alerts without a tracking session', async () => {
    const { manager, notifications, subscription, leg } = await testSetup();
    manager.getDeviceLiveActivities = () => [{
        fromStation: 'VIC', toStation: 'KTH', journeyPhase: 'en_route',
        endAt: new Date(Date.now() + 60_000).toISOString()
    }];
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(departure(null)), ['platform']);
    await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(departure('3')), ['platform']);
    assert.equal(notifications.length, 0);
});

for (const activity of [
    { fromStation: 'VIC', toStation: 'KTH', journeyPhase: 'at_start' },
    { fromStation: 'KTH', toStation: 'VIC', journeyPhase: 'en_route' },
    { fromStation: 'VIC', toStation: 'KTH', journeyPhase: 'en_route', endAt: '2000-01-01T00:00:00Z' }
]) {
    test(`platform alerts remain available for ${JSON.stringify(activity)}`, async () => {
        const { manager, notifications, subscription, leg } = await testSetup();
        manager.getDeviceTrackingSessions = () => [{ from: 'KTH', to: 'VIC' }];
        manager.getDeviceLiveActivities = () => [activity];
        await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(departure(null)), ['platform']);
        await manager.sendUpdateNotifications(subscription, leg, 'VIC-KTH', departures(departure('3')), ['platform']);
        assert.equal(notifications.length, 1);
    });
}

async function testSetup() {
    const manager = new NotificationSubscriptionManager({ getNotificationPreferences: async () => ({}) });
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
    await manager.recordJourneyPhase(subscription.deviceId, { fromStation: 'VIC', toStation: 'KTH', phase: 'at_start' });

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
