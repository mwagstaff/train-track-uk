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

function testManager() {
    const manager = new NotificationSubscriptionManager();
    manager._saveSubscription = async () => {};
    manager.recordSubscriptionAudit = async () => {};
    manager.auditScheduledPushToStartReadiness = async () => {};
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
