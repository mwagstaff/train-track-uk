import assert from 'node:assert/strict';
import test from 'node:test';

import { LiveActivityManager } from '../lib/live-activity-manager.js';
import { NotificationSubscriptionManager } from '../lib/notification-subscription-manager.js';
import { pushToStartTokenStore } from '../lib/push-to-start-token-store.js';

function activity(overrides = {}) {
    return { deviceId: 'device-1', activityId: 'manual', fromStation: 'VIC', toStation: 'KTH',
        journeyPhase: 'en_route', scheduleKey: null, tokenUpdatedAt: '2026-09-08T14:36:40Z', ...overrides };
}

for (const differentRoute of [false, true]) {
    test(`device keeps ongoing ad hoc activity when schedule registers (${differentRoute ? 'different' : 'same'} route)`, () => {
        const manager = new LiveActivityManager();
        manager.deleteSubscriptionFromMongo = async () => {};
        const manual = activity();
        const scheduled = activity({ activityId: 'scheduled', scheduleKey: 'VIC-KTH|16:00|18:00|2026-09-08',
            fromStation: differentRoute ? 'ECR' : 'VIC', tokenUpdatedAt: '2026-09-08T15:00:17Z' });
        const otherDevice = activity({ deviceId: 'device-2', activityId: 'unrelated' });
        for (const entry of [manual, scheduled, otherDevice]) {
            manager.subscriptions.set(manager.buildKey(entry.deviceId, entry.activityId), entry);
        }
        assert.deepEqual(manager.evictDuplicateSessionsForDevice('device-1', 'scheduled'), [scheduled]);
        assert.deepEqual([...manager.subscriptions.values()], [manual, otherDevice]);
    });
}

test('device has one activity even when only two scheduled activities exist', async () => {
    const manager = new LiveActivityManager();
    manager.deleteSubscriptionFromMongo = async () => {};
    const ended = [];
    manager.sendEndPushForEvictedSubscription = async (entry) => ended.push(entry.activityId);
    for (const entry of [activity({ activityId: 'first', scheduleKey: 'one' }),
        activity({ activityId: 'second', scheduleKey: 'two', tokenUpdatedAt: '2026-09-08T15:00:17Z' })]) {
        manager.subscriptions.set(manager.buildKey(entry.deviceId, entry.activityId), entry);
    }
    await manager.tidyDuplicateSessions();
    assert.deepEqual(ended, ['first']);
    assert.equal(manager.subscriptions.size, 1);
});

test('an arrived ad hoc activity does not displace a new scheduled activity', () => {
    const manager = new LiveActivityManager();
    manager.deleteSubscriptionFromMongo = async () => {};
    for (const entry of [activity({ journeyPhase: 'arrived' }), activity({ activityId: 'scheduled', scheduleKey: 'schedule' })]) {
        manager.subscriptions.set(manager.buildKey(entry.deviceId, entry.activityId), entry);
    }
    assert.equal(manager.evictDuplicateSessionsForDevice('device-1', 'scheduled')[0].activityId, 'manual');
});

test('late scheduled registration is ended before it can be saved or polled', () => {
    const manager = new LiveActivityManager();
    const manual = activity();
    manager.subscriptions.set(manager.buildKey(manual.deviceId, manual.activityId), manual);
    manager.deleteSubscriptionFromMongo = async () => {};
    manager.saveSubscriptionToMongo = async () => assert.fail('rejected activity must not be persisted');
    manager.pollSubscription = async () => assert.fail('rejected activity must not be polled');
    const ended = [];
    manager.sendEndPushForEvictedSubscription = async (entry) => ended.push(entry.activityId);
    manager.registerSubscription(activity({ activityId: 'scheduled', pushToken: 'test-token', scheduleKey: 'schedule' }));
    assert.deepEqual(ended, ['scheduled']);
    assert.deepEqual([...manager.subscriptions.values()], [manual]);
});

function fixture(t, options = {}) {
    t.mock.timers.enable({ apis: ['Date'], now: new Date('2026-09-08T15:00:17Z') });
    const manager = new NotificationSubscriptionManager(options);
    manager._saveSubscription = async () => {};
    manager.recordSubscriptionAudit = async () => {};
    manager.logSendEvent = () => {};
    manager.logLiveActivityStartEvent = () => {};
    manager.scheduleScheduledLiveActivityRegistrationWatchdog = () => {};
    const notifications = [];
    const starts = [];
    manager.pushClient = { sendNotification: async (_, payload) => { notifications.push(payload); return { status: 200 }; } };
    manager.liveActivityPushClient = { sendLiveActivityUpdate: async (_, payload) => { starts.push(payload); return { status: 200 }; } };
    t.mock.method(pushToStartTokenStore, 'get', async () => ({ pushToStartToken: 'test-token' }));
    const leg = { from: 'VIC', to: 'KTH', fromName: 'London Victoria', toName: 'Kent House',
        enabled: true, windowStart: '16:00', windowEnd: '18:00' };
    const scheduled = { id: 'schedule-1', deviceId: 'device-1', pushToken: 'test-token', source: 'scheduled',
        scheduleKind: 'regular', routeKey: 'VIC-KTH', daysOfWeek: ['tue'], notificationTypes: ['summary', 'delays'],
        legs: [leg], lastAutoStartSentByLeg: {}, lastAutoStartSentAtByLeg: {}, lastSummarySentByLeg: {}, lastStateByLeg: {} };
    manager.subscriptions.set(scheduled.id, scheduled);
    const snapshot = { fetchedAt: new Date().toISOString(), departures: [{ serviceID: 'service', scheduled: '16:12', estimated: '16:12' }] };
    return { manager, notifications, starts, scheduled, leg, snapshot };
}

test('VIC-KTH overlap skips whole scheduled occurrence and sends one notice even without departure data', async (t) => {
    let activities = [activity()];
    const { manager, notifications, starts, scheduled } = fixture(t, { getDeviceLiveActivities: () => activities });
    await Promise.all([manager.pollSubscription(scheduled), manager.pollSubscription(scheduled)]);
    activities = [];
    await manager.pollSubscription(scheduled);
    assert.equal(notifications.length, 1);
    assert.equal(notifications[0].alert_type, 'scheduled_journey_skipped');
    assert.match(notifications[0].aps.alert.body, /16:00.*London Victoria.*Kent House.*ad hoc journey/);
    assert.equal(notifications[0].from, undefined, 'notice cannot trigger scheduled journey arming');
    assert.equal(starts.length, 0);
    assert.ok(scheduled.skippedAdHocScheduleKeys['VIC-KTH']);
});

test('manual journeys on other routes and tracking without a Live Activity also block a schedule', async (t) => {
    const { manager, notifications, starts, scheduled, leg, snapshot } = fixture(t, {
        getDeviceTrackingSessions: () => [{ source: 'adhoc', from: 'BTN', to: 'ECR' }]
    });
    assert.equal(await manager.sendScheduledLiveActivityStartIfNeeded(scheduled, leg, 'VIC-KTH', snapshot), false);
    assert.equal(notifications.length, 1);
    assert.equal(starts.length, 0);
});

test('failed skipped notice is retried without permitting a scheduled start', async (t) => {
    const { manager, notifications, starts, scheduled, leg, snapshot } = fixture(t, { getDeviceLiveActivities: () => [activity()] });
    let attempts = 0;
    manager.pushClient.sendNotification = async (_, payload) => {
        notifications.push(payload);
        return { status: ++attempts === 1 ? 500 : 200 };
    };
    for (let i = 0; i < 3; i++) await manager.sendScheduledLiveActivityStartIfNeeded(scheduled, leg, 'VIC-KTH', snapshot);
    assert.equal(notifications.length, 2);
    assert.equal(starts.length, 0);
});

test('simultaneous schedules send at most one push-to-start before token registration', async (t) => {
    const { manager, starts, scheduled, leg, snapshot } = fixture(t);
    const second = { ...scheduled, id: 'schedule-2', routeKey: 'ECR-VIC', legs: [{ ...leg, from: 'ECR', to: 'VIC' }],
        lastAutoStartSentByLeg: {}, lastAutoStartSentAtByLeg: {} };
    manager.subscriptions.set(second.id, second);
    await Promise.all([
        manager.sendScheduledLiveActivityStartIfNeeded(scheduled, leg, 'VIC-KTH', snapshot),
        manager.sendScheduledLiveActivityStartIfNeeded(second, second.legs[0], 'ECR-VIC', snapshot)
    ]);
    assert.equal(starts.length, 1);
});

test('manual registration during token lookup prevents scheduled push-to-start', async (t) => {
    let activities = [];
    const { manager, starts, scheduled, leg, snapshot } = fixture(t, { getDeviceLiveActivities: () => activities });
    pushToStartTokenStore.get = async () => { activities = [activity()]; return { pushToStartToken: 'test-token' }; };
    await manager.sendScheduledLiveActivityStartIfNeeded(scheduled, leg, 'VIC-KTH', snapshot);
    assert.equal(starts.length, 0);
});

test('scheduled registration cannot convert an ongoing manual notification session', async (t) => {
    const { manager, leg } = fixture(t);
    const manual = { id: 'manual-session', deviceId: 'device-1', pushToken: 'test-token', source: 'live_session',
        liveSessionOrigin: 'manual', activeUntil: '2026-09-08T16:00:00Z', routeKey: 'VIC-KTH', legs: [leg] };
    manager.subscriptions.set(manual.id, manual);
    await assert.rejects(manager.upsertSubscription({ ...manual, subscriptionId: manual.id,
        liveSessionOrigin: 'scheduled', notificationTypes: ['delays'] }), /ad hoc journey/);
    assert.equal(manager.subscriptions.get(manual.id).liveSessionOrigin, 'manual');
});

test('expired manual session does not block a new schedule', async (t) => {
    const { manager, starts, scheduled, leg, snapshot } = fixture(t);
    manager.subscriptions.set('expired', { id: 'expired', deviceId: 'device-1', source: 'live_session',
        liveSessionOrigin: 'manual', activeUntil: '2026-09-08T14:59:00Z', legs: [leg] });
    await manager.sendScheduledLiveActivityStartIfNeeded(scheduled, leg, 'VIC-KTH', snapshot);
    assert.equal(starts.length, 1);
});

test('device reports a locally tracked conflict using the same persisted notice deduplication', async (t) => {
    const { manager, notifications, scheduled } = fixture(t);
    const report = { deviceId: 'device-1', scheduleKey: 'VIC-KTH|16:00|18:00|2026-09-08' };
    assert.deepEqual(await manager.reportSkippedSchedule(report), { matched: 1 });
    await manager.reportSkippedSchedule(report);
    await manager.pollSubscription(scheduled);
    assert.equal(notifications.length, 1);
    assert.deepEqual(await manager.reportSkippedSchedule({ ...report, deviceId: 'another-device' }), { matched: 0 });
    assert.deepEqual(await manager.reportSkippedSchedule({ ...report, scheduleKey: 'VIC-KTH|16:00|18:00|2026-09-07' }), { matched: 0 });
});

test('duplicate dismissal works without departures and preserves the current notification session', async () => {
    const manager = new LiveActivityManager();
    const duplicate = activity({ activityId: 'scheduled', pushToken: 'test-token', scheduleKey: 'scheduled' });
    manager.getDeparturesSnapshot = async () => { throw new Error('No departure data'); };
    manager.deleteSubscriptionFromMongo = async () => {};
    manager.logPushEvent = () => {};
    manager.deleteMatchingLiveSessions = async () => assert.fail('must preserve the current journey notifications');
    let sent = false;
    manager.pushClient.sendLiveActivityUpdate = async (_, payload) => {
        assert.equal(payload.aps.event, 'end');
        assert.equal(payload.aps['dismissal-date'], 0);
        sent = true;
        return { status: 200 };
    };
    await manager.sendEndPushForEvictedSubscription(duplicate);
    assert.equal(sent, true);
});

test('a poll awaiting departures cannot update an evicted duplicate', async () => {
    const manager = new LiveActivityManager();
    let releaseSnapshot;
    manager.getDeparturesSnapshot = async () => new Promise((resolve) => { releaseSnapshot = resolve; });
    manager.pushClient.sendLiveActivityUpdate = async () => assert.fail('evicted activity must not receive an update');
    const duplicate = activity();
    const poll = manager.pollSubscription(duplicate);
    duplicate.evicted = true;
    releaseSnapshot({ fetchedAt: new Date().toISOString(), departures: [] });
    assert.deepEqual(await poll, { sent: false, reason: 'activity_evicted' });
});
