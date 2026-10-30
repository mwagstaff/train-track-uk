import test from 'node:test';
import assert from 'node:assert/strict';
import { MongoClient } from 'mongodb';
import { allowsPlatformNotification, connectionNotification, normalizeNotificationPreferences } from '../lib/journey-notification-policy.js';
import { LiveActivityManager } from '../lib/live-activity-manager.js';
import { notificationSubscriptionManager } from '../lib/notification-subscription-manager.js';
import { closeMongoClient } from '../lib/mongo-client.js';

const delayed = (minutes = 5, extra = {}) => ({ key: 'selected', label: '12:00 London → Brighton', delayMinutes: minutes, ...extra });

test('notification defaults and delay bounds are applied to existing devices', () => {
    assert.deepEqual(normalizeNotificationPreferences(), { platformOnlyNearStation: true, notificationPlatform: true,
        connectionAlerts: true, connectionDelayMinutes: 5, connectionUnknownDelay: true });
    for (const [value, expected] of [[0, 1], [-10, 1], [31, 30], [1, 1], [30, 30], [NaN, 5], ['15', 5]]) {
        assert.equal(normalizeNotificationPreferences({ connectionDelayMinutes: value }).connectionDelayMinutes, expected);
    }
});

test('platform updates use station arrival by default and can opt out', () => {
    assert.equal(allowsPlatformNotification({}, false), false);
    assert.equal(allowsPlatformNotification({}, true), true);
    assert.equal(allowsPlatformNotification({ platformOnlyNearStation: false }, false), true);
    assert.equal(allowsPlatformNotification({ notificationPlatform: false }, true), false);
});

test('connection delays are inclusive at the chosen threshold, including 1 and 30', () => {
    for (const threshold of [1, 5, 30]) {
        const preferences = { connectionDelayMinutes: threshold };
        assert.equal(connectionNotification([delayed(threshold - 1)], {}, preferences).alert, null);
        assert.ok(connectionNotification([delayed(threshold)], {}, preferences).alert);
    }
});

test('unknown delays have an independent default-on preference and cancellations ignore the delay threshold', () => {
    const unknown = delayed(240, { unknownDelay: true });
    assert.match(connectionNotification([unknown]).alert.body, /time not confirmed/);
    assert.equal(connectionNotification([unknown], {}, { connectionUnknownDelay: false }).alert, null);
    assert.match(connectionNotification([delayed(0, { cancelled: true })], {}, {
        connectionUnknownDelay: false, connectionDelayMinutes: 30
    }).alert.body, /cancelled/);
    for (const observation of [unknown, delayed(30), delayed(0, { cancelled: true })]) {
        assert.equal(connectionNotification([observation], {}, { connectionAlerts: false }).alert, null);
    }
});

test('unchanged and improving disruptions are quiet; worsening, cancellation and recovery are handled', () => {
    let { state } = connectionNotification([delayed(10)]);
    assert.equal(connectionNotification([delayed(10)], state).alert, null);
    assert.equal(connectionNotification([delayed(7)], state).alert, null);
    assert.ok(connectionNotification([delayed(11)], state).alert);
    const cancellation = connectionNotification([delayed(0, { cancelled: true })], state);
    assert.match(cancellation.alert.body, /cancelled/);
    assert.equal(connectionNotification([delayed(0, { cancelled: true })], cancellation.state).alert, null);
    state = connectionNotification([delayed(0)], state).state;
    assert.ok(connectionNotification([delayed(10)], state).alert);
});

test('simultaneous disruptions are combined without losing any connection', () => {
    const result = connectionNotification([delayed(), delayed(0, { key: 'second', label: '13:00 Brighton → Lewes', cancelled: true })]);
    assert.match(result.alert.body, /London → Brighton: 5 min late/);
    assert.match(result.alert.body, /Brighton → Lewes: cancelled/);
    assert.equal(Object.keys(result.state).length, 2);
});

function liveHarness(preferences = {}) {
    const details = new Map([['selected', { crs: 'VIC', std: '12:00', etd: '12:05' }]]);
    const manager = new LiveActivityManager({ getNotificationPreferences: async () => preferences,
        getConnectionDetails: async id => details.get(id) });
    const subscription = { deviceId: 'device', activityId: 'activity', pushToken: 'token', fromStation: 'KTH', toStation: 'BTN',
        journeyPhase: 'en_route', journeyUpdatesEnabled: true, legContext: { from: 'VIC', to: 'BTN', connection: true,
            remainingConnections: [{ from: 'VIC', to: 'BTN', fromName: 'Victoria', toName: 'Brighton', serviceID: 'selected', scheduled: '12:00' }] } };
    const snapshot = { fetchedAt: new Date().toISOString(), departures: [{ serviceID: 'alternative', scheduled: '12:30', estimated: '12:30' }] };
    subscription.lastSnapshot = snapshot;
    manager.getDeparturesSnapshot = async () => snapshot;
    manager.shouldRefreshStaleDate = () => false;
    manager.shouldShowAppActive = () => false;
    manager.saveSubscriptionToMongo = async () => {};
    manager.logPushEvent = () => {};
    const pushes = [];
    manager.pushClient.sendLiveActivityUpdate = async (_token, payload) => { pushes.push(payload); return { status: 200 }; };
    return { manager, subscription, details, pushes };
}

test('an unchanged departure board still alerts for an exact remaining connection and persists deduplication', async () => {
    const h = liveHarness();
    assert.equal((await h.manager.pollSubscription(h.subscription)).sent, true);
    assert.match(h.pushes[0].aps.alert.body, /12:00 Victoria → Brighton: 5 min late/);
    assert.equal(h.pushes[0].aps['content-state'].scheduledDeparture, '12:30');
    await h.manager.pollSubscription(h.subscription);
    assert.equal(h.pushes.length, 1);
    const restored = structuredClone(h.subscription);
    await h.manager.pollSubscription(restored);
    assert.equal(h.pushes.length, 1);
    h.details.get('selected').isCancelled = true;
    await h.manager.pollSubscription(restored);
    assert.match(h.pushes[1].aps.alert.body, /cancelled/);
});

test('failed APNs delivery and dry runs do not consume a connection alert', async () => {
    const h = liveHarness();
    const preview = await h.manager.pollSubscription(h.subscription, { dryRun: true });
    assert.ok(preview.payload.aps.alert);
    assert.equal(h.subscription.connectionAlertState, undefined);
    h.manager.pushClient.sendLiveActivityUpdate = async () => ({ status: 503 });
    assert.equal((await h.manager.pollSubscription(h.subscription)).reason, 'push_failed');
    assert.equal(h.subscription.connectionAlertState, undefined);
    h.manager.pushClient.sendLiveActivityUpdate = async () => ({ status: 200 });
    assert.equal((await h.manager.pollSubscription(h.subscription)).sent, true);
    assert.equal(Object.keys(h.subscription.connectionAlertState).length, 1);
});

test('connection observation excludes already departed, mismatched, missing, completed and unstarted services', async () => {
    for (const patch of [{ atd: '12:05' }, { crs: 'ECR' }, { std: '13:00' }, { error: 'unavailable' }]) {
        const h = liveHarness();
        Object.assign(h.details.get('selected'), patch);
        assert.deepEqual(await h.manager.connectionObservations(h.subscription), []);
    }
    for (const phase of ['pending_start', 'at_start', 'arrived']) {
        const h = liveHarness();
        h.subscription.journeyPhase = phase;
        assert.deepEqual(await h.manager.connectionObservations(h.subscription), []);
    }
});

test('in-progress route alternatives cannot bypass connection preferences through legacy alerts', () => {
    const h = liveHarness({ connectionAlerts: false });
    const before = { departures: [{ serviceID: 'alternative', scheduled: '12:00', estimated: '12:00' }, { serviceID: 'later' }] };
    const after = { departures: [{ serviceID: 'alternative', scheduled: '12:00', estimated: '12:30', isCancelled: true }, { serviceID: 'later', isCancelled: true }] };
    assert.equal(h.manager.buildAlert(h.subscription, before, after), null);
});

test('late pre-arrival status cannot reset the welcome boundary', async t => {
    t.mock.method(MongoClient.prototype, 'connect', async () => ({
        db: () => ({ collection: () => ({ updateOne: async () => {} }) }), close: async () => {}
    }));
    t.after(closeMongoClient);
    const h = liveHarness();
    h.subscription.journeyPhase = 'at_start';
    h.subscription.legContext = null;
    h.manager.subscriptions.set(h.manager.buildKey('device', 'activity'), h.subscription);
    h.manager.pollSubscription = async () => ({ sent: true });
    await h.manager.handleJourneyPhase('device', { fromStation: 'KTH', toStation: 'BTN', phase: 'pending_start' });
    assert.equal(h.subscription.journeyPhase, 'at_start');
    h.manager.registerSubscription({ deviceId: 'device', activityId: 'activity', pushToken: 'refreshed',
        fromStation: 'KTH', toStation: 'BTN', journeyPhase: 'pending_start' });
    assert.equal(h.manager.subscriptions.get(h.manager.buildKey('device', 'activity')).journeyPhase, 'at_start');
});

test('journey status validates and retains exact remaining connections for background polling', async () => {
    const h = liveHarness();
    h.manager.subscriptions.set(h.manager.buildKey('device', 'activity'), h.subscription);
    h.manager.pollSubscription = async () => ({ sent: true });
    await h.manager.handleJourneyPhase('device', { fromStation: 'KTH', toStation: 'BTN', phase: 'en_route',
        legContext: { from: 'VIC', to: 'BTN', from_name: 'Victoria', to_name: 'Brighton', route_title: 'Kent House → Brighton',
            connection: true, at_station: true, remaining_connections: [
                { from: 'VIC', to: 'BTN', service_id: 'selected', scheduled: '12:00', from_name: 'Victoria', to_name: 'Brighton' },
                { from: 'VIC', to: 'BTN', service_id: 'invalid-clock', scheduled: '35:00' }
            ] } });
    assert.equal(h.subscription.legContext.atStation, true);
    assert.equal(h.subscription.legContext.remainingConnections.length, 1);
    assert.equal((await h.manager.connectionObservations(h.subscription))[0].delayMinutes, 5);
});

test('planner monitoring checks all remaining rail legs, skipping transfers and boarded services', async t => {
    const h = liveHarness();
    const leg = (from, to, departure) => ({ kind: 'vehicle', mode: 'rail', uid: from, originDate: '2030-07-01',
        from: { crs: from, name: from }, to: { crs: to, name: to }, departure });
    const schedule = { plannerState: { journeyStarted: true, legIndex: 0 }, plannerJourney: { legs: [
        leg('AAA', 'BBB', '2030-07-01T10:00:00+01:00'),
        { kind: 'transfer' }, leg('CCC', 'DDD', '2030-07-01T11:00:00+01:00'),
        leg('DDD', 'EEE', '2030-07-01T12:00:00+01:00')
    ] } };
    const requested = [];
    t.mock.method(notificationSubscriptionManager.plannerScheduler.resolver, 'resolve', async item => {
        requested.push(item.uid);
        return item.uid === 'AAA' ? { actualDeparture: true } : {
            from: { departureUnknown: item.uid === 'CCC', cancelled: item.uid === 'DDD' }
        };
    });
    const observations = await h.manager.plannerConnectionObservations(schedule);
    assert.deepEqual(requested, ['AAA', 'CCC', 'DDD']);
    assert.equal(observations.length, 2);
    assert.match(observations[0].label, /^11:00/);
    assert.match(connectionNotification(observations).alert.body, /time not confirmed/);
    assert.match(connectionNotification(observations).alert.body, /cancelled/);
    schedule.plannerState.completed = true;
    assert.deepEqual(await h.manager.plannerConnectionObservations(schedule), []);
});
