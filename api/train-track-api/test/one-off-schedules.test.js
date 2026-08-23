import assert from 'node:assert/strict';
import test from 'node:test';

import {
    isExpiredOneOffSchedule,
    NotificationSubscriptionManager,
    shouldPollNow
} from '../lib/notification-subscription-manager.js';

test('one-off schedules accept travel dates without weekdays', async () => {
    const manager = testManager();
    const subscription = await manager.upsertSubscription(registration());

    assert.equal(subscription.schedule_type, 'one_off');
    assert.deepEqual(subscription.days_of_week, []);
    assert.deepEqual(
        subscription.legs.map((leg) => leg.travel_date),
        ['2026-08-21', '2026-08-22']
    );
});

test('one-off schedules require a valid date for every enabled leg', async () => {
    const manager = testManager();
    const missingDate = registration();
    delete missingDate.legs[0].travelDate;

    await assert.rejects(
        manager.upsertSubscription(missingDate),
        /valid travel date is required for leg 1/
    );

    const invalidDate = registration();
    invalidDate.legs[0].travelDate = '2026-02-30';
    await assert.rejects(
        manager.upsertSubscription(invalidDate),
        /valid travel date is required for leg 1/
    );
});

test('one-off polling only runs on the leg travel date and inside its window', () => {
    const subscription = {
        source: 'scheduled',
        scheduleKind: 'one_off',
        daysOfWeek: []
    };
    const leg = {
        travelDate: '2026-08-21',
        windowStart: '08:00',
        windowEnd: '10:00'
    };

    assert.equal(shouldPollNow(subscription, leg, new Date('2026-08-21T08:00:00Z')), true);
    assert.equal(shouldPollNow(subscription, leg, new Date('2026-08-22T08:00:00Z')), false);
    assert.equal(shouldPollNow(subscription, leg, new Date('2026-08-21T10:00:00Z')), false);
});

test('legacy regular schedules still use weekdays', () => {
    const subscription = {
        source: 'scheduled',
        daysOfWeek: ['fri']
    };
    const leg = {
        windowStart: '08:00',
        windowEnd: '10:00'
    };

    assert.equal(shouldPollNow(subscription, leg, new Date('2026-08-21T08:00:00Z')), true);
    assert.equal(shouldPollNow(subscription, leg, new Date('2026-08-22T08:00:00Z')), false);
});

test('one-off schedules expire after their final enabled travel window', () => {
    const subscription = {
        source: 'scheduled',
        scheduleKind: 'one_off',
        legs: [
            { enabled: true, travelDate: '2026-08-21', windowEnd: '19:43' },
            { enabled: true, travelDate: '2026-08-21', windowEnd: '19:47' }
        ]
    };

    assert.equal(isExpiredOneOffSchedule(subscription, new Date('2026-08-21T18:47:00Z')), false);
    assert.equal(isExpiredOneOffSchedule(subscription, new Date('2026-08-21T18:48:00Z')), true);

    subscription.legs[1].travelDate = '2026-08-22';
    assert.equal(isExpiredOneOffSchedule(subscription, new Date('2026-08-21T18:48:00Z')), false);
});

test('expired one-off schedules are pruned from server state', async () => {
    const manager = testManager();
    const subscription = await manager.upsertSubscription(registration());
    manager._deleteFromMongo = async () => {};

    await manager.pruneExpiredOneOffSchedules(new Date('2026-08-23T12:00:00Z'));

    assert.equal(manager.listSubscriptions('device-1', { source: 'scheduled' }).length, 0);
    assert.equal(manager.getSubscriptionCount(), 0);
    assert.equal(subscription.schedule_type, 'one_off');
});

function testManager() {
    const manager = new NotificationSubscriptionManager();
    manager._saveSubscription = async () => {};
    manager.recordSubscriptionAudit = async () => {};
    manager.auditScheduledPushToStartReadiness = async () => {};
    return manager;
}

function registration() {
    return {
        deviceId: 'device-1',
        pushToken: 'push-token',
        routeKey: 'KTH-VIC',
        scheduleKind: 'one_off',
        daysOfWeek: [],
        notificationTypes: ['summary', 'delays', 'platform'],
        legs: [
            {
                from: 'KTH',
                to: 'VIC',
                enabled: true,
                windowStart: '07:00',
                windowEnd: '09:00',
                travelDate: '2026-08-21'
            },
            {
                from: 'VIC',
                to: 'KTH',
                enabled: true,
                windowStart: '16:00',
                windowEnd: '18:00',
                travelDate: '2026-08-22'
            }
        ],
        source: 'scheduled'
    };
}
