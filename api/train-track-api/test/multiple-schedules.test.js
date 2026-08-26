import assert from 'node:assert/strict';
import test from 'node:test';

import { NotificationSubscriptionManager } from '../lib/notification-subscription-manager.js';

test('creates multiple schedules for the same journey route', async () => {
    const manager = testManager();

    const weekdaySchedule = await manager.upsertSubscription(registration({
        daysOfWeek: ['mon']
    }));
    const weekendSchedule = await manager.upsertSubscription(registration({
        daysOfWeek: ['sat']
    }));

    assert.notEqual(weekdaySchedule.id, weekendSchedule.id);
    assert.deepEqual(
        manager.listSubscriptions('device-1', { source: 'scheduled' }).map((schedule) => schedule.id),
        [weekdaySchedule.id, weekendSchedule.id]
    );
});

test('updates only the schedule identified by subscription id', async () => {
    const manager = testManager();
    const first = await manager.upsertSubscription(registration({ daysOfWeek: ['mon'] }));
    const second = await manager.upsertSubscription(registration({ daysOfWeek: ['sat'] }));

    const updated = await manager.upsertSubscription(registration({
        subscriptionId: first.id,
        daysOfWeek: ['tue']
    }));
    const schedules = manager.listSubscriptions('device-1', { source: 'scheduled' });

    assert.equal(updated.id, first.id);
    assert.equal(schedules.length, 2);
    assert.deepEqual(schedules.find((schedule) => schedule.id === first.id)?.days_of_week, ['tue']);
    assert.deepEqual(schedules.find((schedule) => schedule.id === second.id)?.days_of_week, ['sat']);
});

test('muting a scheduled leg mutes the same leg in every schedule for the device', async () => {
    const manager = testManager();

    const first = await manager.upsertSubscription(registration({ daysOfWeek: ['mon'] }));
    const second = await manager.upsertSubscription(registration({ daysOfWeek: ['sat'] }));
    manager.pushClient.sendNotification = async () => {
        assert.equal(manager.isMutedToday(manager.subscriptions.get(first.id), 'KTH-VIC'), true);
        assert.equal(manager.isMutedToday(manager.subscriptions.get(second.id), 'KTH-VIC'), true);
        return { status: 200 };
    };

    await manager.muteLegForDate({
        deviceId: 'device-1',
        subscriptionId: first.id,
        from: 'KTH',
        to: 'VIC',
        reason: 'station_exit',
        transition: 'station_exit'
    });

    assert.equal(manager.isMutedToday(manager.subscriptions.get(first.id), 'KTH-VIC'), true);
    assert.equal(manager.isMutedToday(manager.subscriptions.get(second.id), 'KTH-VIC'), true);
});

test('journey completion mutes schedules and removes every matching live session', async () => {
    const manager = testManager();
    manager.pushClient.sendNotification = async () => {
        assert.fail('journey completion reconciliation must be silent');
    };
    const schedule = await manager.upsertSubscription(registration());
    const firstLiveSession = await manager.upsertSubscription(registration({
        source: 'live_session',
        daysOfWeek: [],
        notificationTypes: ['delays'],
        liveSessionOrigin: 'scheduled'
    }));
    const secondLiveSession = await manager.upsertSubscription(registration({
        source: 'live_session',
        daysOfWeek: [],
        notificationTypes: ['platform'],
        liveSessionOrigin: 'manual'
    }));

    const result = await manager.muteLegForDate({
        deviceId: 'device-1',
        subscriptionId: 'already-finished-live-session',
        from: 'KTH',
        to: 'VIC',
        reason: 'journey_completed_reconciliation',
        transition: 'station_exit',
        detectionSource: 'journey_tracking'
    });

    assert.equal(result.transition, 'station_exit');
    assert.equal(manager.isMutedToday(manager.subscriptions.get(schedule.id), 'KTH-VIC'), true);
    assert.equal(manager.subscriptions.has(firstLiveSession.id), false);
    assert.equal(manager.subscriptions.has(secondLiveSession.id), false);
});

function testManager() {
    const manager = new NotificationSubscriptionManager();
    manager._saveSubscription = async () => {};
    manager._deleteFromMongo = async () => {};
    manager.recordSubscriptionAudit = async () => {};
    manager.auditScheduledPushToStartReadiness = async () => {};
    manager.logSendEvent = () => {};
    return manager;
}

function registration(overrides = {}) {
    return {
        deviceId: 'device-1',
        pushToken: 'push-token',
        routeKey: 'KTH-VIC',
        scheduleKind: 'regular',
        daysOfWeek: ['mon'],
        notificationTypes: ['summary', 'delays'],
        legs: [{
            from: 'KTH',
            to: 'VIC',
            enabled: true,
            windowStart: '07:00',
            windowEnd: '09:00'
        }],
        source: 'scheduled',
        ...overrides
    };
}
