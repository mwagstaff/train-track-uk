import assert from 'node:assert/strict';
import test from 'node:test';

import { minutesUntilDeparture } from '../lib/live-activity-departure-order.js';
import { LiveActivityManager, liveActivityManager } from '../lib/live-activity-manager.js';

test('live activity departures remain chronological across midnight', () => {
    const nowMinutes = 21 * 60 + 16;
    const departures = [
        { serviceID: 'after-midnight', scheduled: '00:17' },
        { serviceID: 'next', scheduled: '21:24' },
        { serviceID: 'later', scheduled: '21:52' },
        { serviceID: 'middle', scheduled: '21:23' }
    ];

    const sorted = departures.toSorted((left, right) => (
        minutesUntilDeparture(left.scheduled, nowMinutes)
        - minutesUntilDeparture(right.scheduled, nowMinutes)
    ));

    assert.deepEqual(
        sorted.map((departure) => departure.serviceID),
        ['middle', 'next', 'later', 'after-midnight']
    );
});

test('en-route live activity content shows destination arrival details', () => {
    const content = liveActivityManager.buildContentState({
        activityId: 'activity-1',
        fromStation: 'KTH',
        toStation: 'VIC',
        displayName: 'Kent House → London Victoria',
        preferredServiceId: 'service-1',
        journeyPhase: 'en_route',
        journeyUpdatesEnabled: true
    }, {
        fetchedAt: '2026-08-19T07:30:00.000Z',
        departures: [{
            serviceID: 'service-1',
            scheduled: '08:27',
            estimated: '08:29',
            departedTime: '08:27',
            arrivalTime: '08:57',
            platform: '2',
            arrivalPlatform: '7',
            length: 8,
            destination: [{ locationName: 'London Victoria' }],
            statusText: 'Currently on time, between Kent House and Penge East'
        }, {
            serviceID: 'service-2',
            scheduled: '08:42',
            estimated: '08:42'
        }]
    });

    assert.equal(content.journeyPhase, 'en_route');
    assert.equal(content.journeyStartName, 'Kent House');
    assert.equal(content.journeyDestinationName, 'London Victoria');
    assert.equal(content.estimated, '08:57');
    assert.equal(content.arrivalLabel, 'Departed 08:27');
    assert.equal(content.platform, '7');
    assert.deepEqual(content.upcomingDepartures, []);
    assert.equal(content.statusText, 'Currently on time, between Kent House and Penge East');
});

test('arrived live activity content shows actual arrival and Delay Repay eligibility data', () => {
    const content = liveActivityManager.buildContentState({
        activityId: 'activity-2',
        fromStation: 'BTN',
        toStation: 'ECR',
        displayName: 'Brighton → East Croydon',
        journeyPhase: 'arrived',
        journeyUpdatesEnabled: true
    }, {
        fetchedAt: '2026-08-19T11:20:00.000Z',
        departures: [{
            serviceID: 'service-2',
            scheduled: '10:59',
            estimated: '10:59',
            departedTime: '10:59',
            arrivalTime: '12:06',
            actualArrivalTime: '12:06',
            arrivalDelayMinutes: 15,
            arrivalPlatform: '5',
            length: 12,
            destination: [{ locationName: 'Bedford' }],
            statusText: 'Currently 15 minutes late'
        }]
    });

    assert.equal(content.journeyPhase, 'arrived');
    assert.equal(content.destinationTitle, 'East Croydon');
    assert.equal(content.estimated, '12:06');
    assert.equal(content.arrivalLabel, 'Departed 10:59');
    assert.equal(content.platform, '5');
    assert.equal(content.statusText, null);
    assert.equal(content.arrivalDelayMinutes, 15);
    assert.equal(content.delayMinutes, 15);
});

test('arrived live activity content keeps the client-confirmed arrival when service details are unavailable', () => {
    const content = liveActivityManager.buildContentState({
        activityId: 'activity-confirmed-arrival',
        fromStation: 'KTH',
        toStation: 'VIC',
        journeyPhase: 'arrived',
        journeyUpdatesEnabled: true,
        arrivalTime: '08:05',
        arrivalDelayMinutes: 2
    }, {
        fetchedAt: '2026-08-28T07:06:00.000Z',
        departures: [{
            serviceID: 'departed-service',
            scheduled: '07:42',
            estimated: '07:44'
        }]
    });

    assert.equal(content.estimated, '08:05');
    assert.equal(content.arrivalDelayMinutes, 2);
    assert.equal(content.delayMinutes, 2);
});

test('live activity alerts when a platform is first assigned', () => {
    const manager = new LiveActivityManager();
    const alert = manager.buildAlert({ displayName: 'Kent House → London Victoria' }, {
        departures: [{ serviceID: 'service-1', scheduled: '08:27', platform: null }]
    }, {
        departures: [{ serviceID: 'service-1', scheduled: '08:27', platform: '2' }]
    });

    assert.deepEqual(alert, {
        title: 'Kent House → London Victoria',
        body: 'Platform announced: 08:27 - platform 2.'
    });
});

test('live activity alerts when an assigned platform changes number', () => {
    const manager = new LiveActivityManager();
    const alert = manager.buildAlert({ displayName: 'Kent House → London Victoria' }, {
        departures: [{ serviceID: 'service-1', scheduled: '08:27', platform: '3' }]
    }, {
        departures: [{ serviceID: 'service-1', scheduled: '08:27', platform: '5' }]
    });

    assert.deepEqual(alert, {
        title: 'Kent House → London Victoria',
        body: 'Platform alteration: 08:27 - now platform 5.'
    });
});

test('live activity keeps the last numbered platform when the feed returns TBC', () => {
    const manager = new LiveActivityManager();
    const previousSnapshot = {
        departures: [{ serviceID: 'service-1', scheduled: '08:27', platform: '3' }]
    };
    const snapshot = manager.applyLastKnownPlatforms({
        departures: [{ serviceID: 'service-1', scheduled: '08:27', platform: 'TBC' }]
    }, previousSnapshot);

    assert.equal(snapshot.departures[0].platform, '3');
    assert.equal(manager.buildAlert({}, previousSnapshot, snapshot), null);
});

test('journey phase pins the live activity to the service matched on device', async () => {
    const manager = new LiveActivityManager();
    const subscription = {
        deviceId: 'device-1',
        activityId: 'activity-1',
        fromStation: 'KTH',
        toStation: 'VIC',
        preferredServiceId: 'subsequent-service',
        lastSnapshot: {
            departures: [
                { serviceID: 'boarded-service', scheduled: '07:42' },
                { serviceID: 'subsequent-service', scheduled: '07:57' }
            ]
        }
    };
    manager.subscriptions.set('device-1:activity-1', subscription);
    manager.saveSubscriptionToMongo = async () => {};
    manager.pollSubscription = async (updatedSubscription) => {
        assert.equal(updatedSubscription.preferredServiceId, 'boarded-service');
        return { sent: true };
    };

    const result = await manager.handleJourneyPhase('device-1', {
        fromStation: 'KTH',
        toStation: 'VIC',
        phase: 'en_route',
        preferredServiceId: 'boarded-service'
    });

    assert.equal(subscription.preferredServiceId, 'boarded-service');
    assert.equal(subscription.preferredDepartureSnapshot.serviceID, 'boarded-service');
    assert.deepEqual(result, { updated: 1, pushed: 1 });
});

test('unconfirmed boarding never promotes the next departure and can recover a confirmed service', async () => {
    const manager = new LiveActivityManager();
    const next = { serviceID: 'next-1742', scheduled: '17:42', departedTime: '17:42' };
    const caught = { serviceID: 'caught-1727', scheduled: '17:27', departedTime: '17:27' };
    const subscription = {
        deviceId: 'unconfirmed-device', activityId: 'unconfirmed-activity',
        fromStation: 'VIC', toStation: 'KTH',
        preferredServiceId: next.serviceID, preferredDepartureSnapshot: next,
        lastSnapshot: { departures: [next, caught], fetchedAt: '2026-09-16T16:30:00Z' }
    };
    manager.subscriptions.set('unconfirmed-device:unconfirmed-activity', subscription);
    manager.saveSubscriptionToMongo = async () => {};
    manager.pollSubscription = async () => ({ sent: true });

    await manager.handleJourneyPhase(subscription.deviceId, {
        fromStation: 'VIC', toStation: 'KTH', phase: 'en_route', serviceMatchConfirmed: false,
        statusObservedAtMs: 1000
    });
    assert.equal(subscription.preferredServiceId, null);
    assert.equal(subscription.preferredDepartureSnapshot, null);
    const content = manager.buildContentState(subscription, subscription.lastSnapshot);
    assert.equal(content.scheduledDeparture, null);
    assert.equal(content.arrivalLabel, null);
    assert.equal(content.estimated, '');
    assert.equal(content.statusText, 'Train not yet confirmed');
    assert.equal(manager.serializeSubscription(subscription).serviceMatchConfirmed, false);

    // A later generic phase update must not revive the next train from the board.
    await manager.handleJourneyPhase(subscription.deviceId, { phase: 'en_route' });
    assert.equal(subscription.preferredServiceId, null);

    await manager.handleJourneyPhase(subscription.deviceId, {
        phase: 'en_route', preferredServiceId: caught.serviceID, serviceMatchConfirmed: true,
        statusObservedAtMs: 3000
    });
    assert.equal(subscription.preferredServiceId, caught.serviceID);
    assert.equal(subscription.serviceMatchConfirmed, true);
    assert.equal(subscription.preferredDepartureSnapshot.serviceID, caught.serviceID);

    await manager.handleJourneyPhase(subscription.deviceId, {
        phase: 'en_route', serviceMatchConfirmed: false, statusObservedAtMs: 2000
    });
    assert.equal(subscription.preferredServiceId, caught.serviceID);
    assert.equal(subscription.serviceMatchConfirmed, true);
    // A deliberate later unlisted choice still clears the match.
    await manager.handleJourneyPhase(subscription.deviceId, {
        phase: 'en_route', serviceMatchConfirmed: false, statusObservedAtMs: 4000
    });
    assert.equal(subscription.preferredServiceId, null);
    assert.equal(subscription.serviceMatchConfirmed, false);
});

test('unconfirmed journey pushes a clearing update even with no matching departures', async () => {
    const manager = new LiveActivityManager();
    const subscription = {
        deviceId: 'empty-match-device', activityId: 'empty-match-activity',
        fromStation: 'VIC', toStation: 'KTH', journeyPhase: 'en_route',
        serviceMatchConfirmed: false, preferredServiceId: null,
        lastSnapshot: { departures: [{ serviceID: 'future', scheduled: '17:42' }] }
    };
    manager.getDeparturesSnapshot = async () => ({ departures: [], fetchedAt: '2026-09-16T16:30:00Z' });
    manager.saveSubscriptionToMongo = async () => {};
    manager.logPushEvent = () => {};
    const sent = [];
    manager.pushClient = { sendLiveActivityUpdate: async (_token, payload) => { sent.push(payload); return { status: 200 }; } };
    const result = await manager.pollSubscription(subscription, { force: true });
    assert.equal(result.sent, true);
    assert.equal(sent.length, 1);
    const state = sent[0].aps['content-state'];
    assert.equal(state.scheduledDeparture, null);
    assert.equal(state.arrivalLabel, null);
    assert.equal(state.statusText, 'Train not yet confirmed');

    subscription.journeyPhase = 'arrived';
    subscription.arrivalTime = '17:48';
    await manager.pollSubscription(subscription, { force: true });
    assert.equal(sent[1].aps['content-state'].estimated, '17:48');
});

test('arrived journey phase schedules the live activity to end ten minutes after completion', async () => {
    const manager = new LiveActivityManager();
    const completedAt = new Date(Date.now() - 60_000);
    const subscription = {
        deviceId: 'device-arrived',
        activityId: 'activity-arrived',
        fromStation: 'KTH',
        toStation: 'VIC',
        lastSnapshot: { departures: [{ serviceID: 'service-arrived', scheduled: '07:42' }] }
    };
    manager.subscriptions.set('device-arrived:activity-arrived', subscription);
    manager.saveSubscriptionToMongo = async () => {};
    manager.pollSubscription = async () => ({ sent: true });

    await manager.handleJourneyPhase('device-arrived', {
        fromStation: 'KTH',
        toStation: 'VIC',
        phase: 'arrived',
        preferredServiceId: 'service-arrived',
        arrivalTime: '08:05',
        arrivalDelayMinutes: 2,
        completedAt: completedAt.toISOString()
    });

    assert.equal(subscription.arrivalTime, '08:05');
    assert.equal(subscription.arrivalDelayMinutes, 2);
    assert.equal(subscription.endPolicy, 'journey_arrival_plus_grace');
    assert.ok(Math.abs(Date.parse(subscription.endAt) - (completedAt.getTime() + 10 * 60 * 1000)) < 10);
    manager.clearEndTimer(subscription);
});

test('unregister waits for matching notification live sessions to be deleted', async () => {
    const manager = new LiveActivityManager();
    const subscription = {
        deviceId: 'device-dismissed',
        activityId: 'activity-dismissed',
        fromStation: 'VIC',
        toStation: 'KTH'
    };
    manager.subscriptions.set(manager.buildKey(subscription.deviceId, subscription.activityId), subscription);
    const operations = [];
    manager.deleteSubscriptionFromMongo = async () => {
        await Promise.resolve();
        operations.push('live-activity');
    };
    manager.deleteMatchingLiveSessions = async (removed) => {
        assert.equal(removed, subscription);
        await Promise.resolve();
        operations.push('notification-live-session');
    };

    const removed = await manager.unregisterSubscription(
        'device-dismissed',
        'activity-dismissed'
    );

    assert.equal(removed, subscription);
    assert.deepEqual(operations, ['live-activity', 'notification-live-session']);
    assert.equal(manager.subscriptions.has(manager.buildKey(subscription.deviceId, subscription.activityId)), false);
});

test('unregister preserves notification tracking after the journey starts', async () => {
    const manager = new LiveActivityManager();
    const subscription = {
        deviceId: 'device-en-route',
        activityId: 'activity-en-route',
        fromStation: 'VIC',
        toStation: 'KTH'
    };
    manager.subscriptions.set(manager.buildKey(subscription.deviceId, subscription.activityId), subscription);
    manager.deleteSubscriptionFromMongo = async () => {};
    manager.deleteMatchingLiveSessions = async () => {
        assert.fail('notification live session should be preserved');
    };

    await manager.unregisterSubscription('device-en-route', 'activity-en-route', {
        preserveNotificationLiveSession: true
    });
});

test('unregisters every Live Activity belonging to a dismissed schedule', async () => {
    const manager = new LiveActivityManager();
    const subscriptions = ['activity-1', 'activity-2'].map((activityId) => ({
        deviceId: 'device-scheduled',
        activityId,
        fromStation: 'VIC',
        toStation: 'KTH',
        scheduleKey: 'VIC-KTH|16:30|20:30|2026-09-13'
    }));
    for (const subscription of subscriptions) {
        manager.subscriptions.set(manager.buildKey(subscription.deviceId, subscription.activityId), subscription);
    }
    manager.deleteSubscriptionFromMongo = async () => {};
    manager.deleteMatchingLiveSessions = async () => {};

    const removed = await manager.unregisterSubscriptionsForSchedule(
        'device-scheduled',
        'VIC-KTH|16:30|20:30|2026-09-13'
    );

    assert.equal(removed, 2);
    assert.equal(manager.subscriptions.size, 0);
});
