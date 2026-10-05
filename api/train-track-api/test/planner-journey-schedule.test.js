import test from 'node:test';
import assert from 'node:assert/strict';
import { MongoClient } from 'mongodb';
import { normalizePlannerSchedule, PlannerJourneyScheduler, PlannerScheduleResolver, plannerContent } from '../lib/planner-journey-schedule.js';
import { NotificationSubscriptionManager, notificationSubscriptionManager, isExpiredOneOffSchedule } from '../lib/notification-subscription-manager.js';
import { LiveActivityManager } from '../lib/live-activity-manager.js';
import { LiveActivityPushClient } from '../lib/live-activity-push-client.js';
import { closeMongoClient } from '../lib/mongo-client.js';

const departure = '2030-10-20T00:25:00+01:00';
const zero = Date.parse(departure);
const at = minutes => new Date(zero + minutes * 60000).toISOString();
const station = crs => ({ crs, name: crs });
const train = (from = 'AAA', to = 'BBB', start = 0, end = 30) => ({
    kind: 'vehicle', mode: 'rail', from: station(from), to: station(to), departure: at(start), arrival: at(end),
    uid: 'A12345', originDate: '2030-10-20', operator: 'OP', calls: [
        { station: station(from), departure: at(start), arrival: null },
        { station: station(to), departure: null, arrival: at(end) }
    ]
});
const plan = (leadMinutes = 60, legs = [train()]) => normalizePlannerSchedule({ leadMinutes, legs }, zero - 86400000);

function harness({ now = zero - 3600000, resolve = async () => null } = {}) {
    const owner = new NotificationSubscriptionManager({ plannerScheduler: { now: () => now, resolver: { resolve } },
        getPlannerPushToken: async () => ({ pushToStartToken: 'token', useSandbox: true }) });
    const saved = new Map(), pushes = [], notices = [];
    owner._saveSubscription = async subscription => saved.set(subscription.id, structuredClone(subscription));
    owner._deleteFromMongo = async id => saved.delete(id);
    owner.recordSubscriptionAudit = async () => {};
    owner.auditScheduledPushToStartReadiness = async () => {};
    owner.liveActivityPushClient = { sendLiveActivityUpdate: async (token, payload) => { pushes.push(payload); return { status: 200 }; } };
    owner.pushClient = { sendNotification: async (token, payload) => { notices.push(payload); return { status: 200 }; } };
    const subscription = { id: 'schedule', deviceId: 'device', plannerJourney: plan(), legs: [], source: 'scheduled', scheduleKind: 'one_off' };
    owner.subscriptions.set(subscription.id, subscription);
    return { owner, subscription, saved, pushes, notices, setNow: value => { now = value; } };
}

test('lead time uses the dated scheduled departure across midnight and both BST transitions', () => {
    assert.equal(plan().startsAt, at(-60));
    assert.equal(plan(120).startsAt, at(-120));
    for (const departure of ['2030-03-31T02:25:00+01:00', '2030-10-27T01:25:00+00:00', '2030-10-27T01:25:00+01:00']) {
        const leg = train();
        leg.departure = departure;
        leg.arrival = new Date(Date.parse(departure) + 1800000).toISOString();
        const value = normalizePlannerSchedule({ leadMinutes: 120, legs: [leg] }, Date.parse(departure) - 86400000);
        assert.equal(Date.parse(value.startsAt), Date.parse(departure) - 7200000);
    }
});

test('rejects invalid offsets, departed services, disconnected and reversed itineraries', () => {
    for (const leadMinutes of [0, -1, 121, 180, '60', NaN]) {
        assert.throws(() => normalizePlannerSchedule({ leadMinutes, legs: [train()] }, zero - 1000));
    }
    assert.throws(() => normalizePlannerSchedule({ leadMinutes: 60, legs: [train()] }, zero), /already departed/);
    assert.throws(() => plan(60, [train(), train('CCC', 'DDD', 45, 60)]), /connected/);
    assert.throws(() => plan(60, [train('AAA', 'BBB', 30, 0)]), /precedes/);
    assert.throws(() => plan(60, [{ ...train(), departure: '2030-10-20T00:25:00' }]), /timezone/);
});

test('identity ignores lead-time edits but distinguishes selected train occurrences', () => {
    assert.equal(plan(60).identity, plan(120).identity);
    assert.notEqual(plan().identity, plan(60, [train('AAA', 'BBB', 15, 45)]).identity);
});

test('all-departures is opt-in and does not change schedule identity or timing', () => {
    const original = plan();
    const enabled = normalizePlannerSchedule({ ...original, showAllDepartures: true }, zero - 86400000);
    assert.equal(original.showAllDepartures, false);
    for (const key of ['identity', 'startsAt', 'departure', 'arrival', 'expiresAt']) assert.equal(enabled[key], original[key]);
    assert.throws(() => normalizePlannerSchedule({ ...original, showAllDepartures: 'true' }, zero - 86400000), /true or false/);
});

test('display preference can change before starting and after departure without resetting the schedule', async t => {
    const h = harness();
    const original = structuredClone(h.subscription.plannerJourney);
    await h.owner.updatePlannerDisplay({ deviceId: 'device', subscriptionId: 'schedule', showAllDepartures: true });
    assert.equal(h.saved.get('schedule').plannerJourney.showAllDepartures, true);
    h.subscription.plannerState = { status: 'started', legIndex: 0, attempts: 1, checkedAt: zero };
    t.mock.method(Date, 'now', () => zero + 5 * 60000);
    await h.owner.updatePlannerDisplay({ deviceId: 'device', subscriptionId: 'schedule', showAllDepartures: false });
    assert.deepEqual(h.subscription.plannerJourney, original);
    assert.equal(h.subscription.plannerState.status, 'started');
    assert.equal(h.subscription.plannerState.attempts, 1);
    await h.owner.plannerScheduler.poll(h.subscription);
    assert.equal(h.pushes.length, 0);
    await assert.rejects(h.owner.updatePlannerDisplay({ deviceId: 'other', subscriptionId: 'schedule', showAllDepartures: true }), /not found/);
    await assert.rejects(h.owner.updatePlannerDisplay({ deviceId: 'device', subscriptionId: 'schedule', showAllDepartures: 'true' }), /true or false/);
});

test('schedules start once at the lead time, including immediately inside the window', async () => {
    const h = harness({ now: zero - 3600001 });
    await h.owner.plannerScheduler.poll(h.subscription);
    assert.equal(h.pushes.length, 0);
    h.setNow(zero - 3600000);
    await Promise.all([h.owner.plannerScheduler.poll(h.subscription), h.owner.plannerScheduler.poll(h.subscription)]);
    assert.equal(h.pushes.length, 1);
    assert.equal(h.pushes[0].aps.event, 'start');
    assert.equal(h.pushes[0].aps['content-state'].scheduledDeparture, '00:25');
    assert.match(h.pushes[0].aps['content-state'].statusText, /unavailable/);
    assert.equal(h.saved.get('schedule').plannerState.status, 'started');
    h.owner.subscriptions.set('schedule', structuredClone(h.saved.get('schedule')));
    await new PlannerJourneyScheduler(h.owner, { now: () => zero - 1800000 }).poll(h.owner.subscriptions.get('schedule'));
    assert.equal(h.pushes.length, 1, 'a server restart must not send a second start');
    const late = harness({ now: zero - 60000 });
    await late.owner.plannerScheduler.poll(late.subscription);
    assert.equal(late.pushes.length, 1);
});

test('another active journey wins and produces one conflict notice', async () => {
    const h = harness();
    h.owner.getDeviceLiveActivities = () => [{ activityId: 'other' }];
    await h.owner.plannerScheduler.poll(h.subscription);
    await h.owner.plannerScheduler.poll(h.subscription);
    assert.equal(h.pushes.length, 0);
    assert.equal(h.notices.length, 1);
    assert.equal(h.subscription.plannerState.status, 'conflict');
});

test('two simultaneous planner schedules cannot both claim one device', async () => {
    const h = harness();
    const second = { ...h.subscription, id: 'second', plannerJourney: plan(60, [train('CCC', 'DDD')]) };
    h.owner.subscriptions.set(second.id, second);
    await Promise.all([h.owner.plannerScheduler.poll(h.subscription), h.owner.plannerScheduler.poll(second)]);
    assert.equal(h.pushes.length, 1);
    assert.equal(h.notices.length, 1);
});

test('cancellation and a manual start during service resolution prevent automatic start', async () => {
    for (const cancel of [true, false]) {
        const h = harness();
        h.owner.plannerScheduler.resolver.resolve = async () => {
            if (cancel) h.owner.subscriptions.delete(h.subscription.id);
            else h.owner.getDeviceLiveActivities = () => [{ activityId: 'manual' }];
            return null;
        };
        await h.owner.plannerScheduler.poll(h.subscription);
        assert.equal(h.pushes.length, 0);
    }
});

test('an uncertain or rejected push does not create duplicate starts', async () => {
    const h = harness();
    let calls = 0;
    h.owner.liveActivityPushClient.sendLiveActivityUpdate = async () => { calls++; throw new Error('connection lost'); };
    await h.owner.plannerScheduler.poll(h.subscription);
    await h.owner.plannerScheduler.poll(h.subscription);
    assert.equal(calls, 1);
    assert.equal(h.saved.get('schedule').plannerState.status, 'unconfirmed');
});

test('APNs rejection is retried with a bounded delay, without retrying successful starts', async () => {
    const h = harness();
    let calls = 0;
    h.owner.liveActivityPushClient.sendLiveActivityUpdate = async () => ({ status: ++calls === 1 ? 503 : 200 });
    await h.owner.plannerScheduler.poll(h.subscription);
    assert.equal(h.subscription.plannerState.status, 'retry');
    await h.owner.plannerScheduler.poll(h.subscription);
    assert.equal(calls, 1);
    h.setNow(zero - 3600000 + 30000);
    await h.owner.plannerScheduler.poll(h.subscription);
    assert.equal(calls, 2);
    assert.equal(h.subscription.plannerState.status, 'started');
});

test('the APNs transport does not silently retry an uncertain planner start', async t => {
    t.mock.method(MongoClient.prototype, 'connect', async () => ({
        db: () => ({ collection: () => ({ updateOne: async () => {} }) }), close: async () => {}
    }));
    t.after(closeMongoClient);
    const h = harness();
    const client = new LiveActivityPushClient({ privateKey: 'test', keyId: 'test', teamId: 'test' });
    client.buildJwt = () => 'test';
    let attempts = 0;
    client.sendSingleRequest = async () => { attempts++; return { status: 'error' }; };
    h.owner.liveActivityPushClient = client;
    await h.owner.plannerScheduler.poll(h.subscription);
    await h.owner.plannerScheduler.poll(h.subscription);
    assert.equal(attempts, 1);
    assert.equal(h.subscription.plannerState.status, 'unconfirmed');
});

test('arrival advances through a transfer to the selected connection, without starting another activity', async () => {
    const h = harness({ now: zero + 31 * 60000, resolve: async () => ({ actualArrival: true, to: { arrival: zero + 30 * 60000 } }) });
    const transfer = { kind: 'transfer', mode: 'interchange', from: station('BBB'), to: station('BBB'), departure: at(30), arrival: at(35), calls: [], transferMinutes: 5 };
    h.subscription.plannerJourney = plan(60, [train(), transfer, train('BBB', 'CCC', 40, 60)]);
    let content = await h.owner.plannerScheduler.snapshot(h.subscription);
    assert.equal(h.subscription.plannerState.legIndex, 1);
    assert.match(content.statusText, /Transfer/);
    h.setNow(zero + 36 * 60000);
    content = await h.owner.plannerScheduler.snapshot(h.subscription);
    assert.equal(h.subscription.plannerState.legIndex, 2);
    assert.equal(content.scheduleKey, 'planner:schedule');
    assert.equal(content.toCRS, 'CCC');
    assert.equal(h.pushes.length, 0);
});

test('a delayed arrival preserves transfer time and reports a confirmed missed connection', async () => {
    const h = harness({ now: zero + 46 * 60000 });
    const transfer = { kind: 'transfer', mode: 'interchange', from: station('BBB'), to: station('BBB'), departure: at(30), arrival: at(35), calls: [], transferMinutes: 5 };
    h.subscription.plannerJourney = plan(60, [train(), transfer, train('BBB', 'CCC', 40, 60)]);
    h.owner.plannerScheduler.resolver.resolve = async leg => leg.from.crs === 'AAA'
        ? { actualArrival: true, to: { arrival: zero + 45 * 60000 } }
        : { actualDeparture: true, from: { departure: zero + 40 * 60000 } };
    await h.owner.plannerScheduler.snapshot(h.subscription);
    h.setNow(zero + 49 * 60000);
    await h.owner.plannerScheduler.snapshot(h.subscription);
    assert.equal(h.subscription.plannerState.legIndex, 1);
    h.setNow(zero + 51 * 60000);
    const content = await h.owner.plannerScheduler.snapshot(h.subscription);
    assert.match(content.statusText, /Connection missed/);
});

test('missing live data never implies departure, arrival or an alternative train', () => {
    const h = harness();
    const content = plannerContent(h.subscription, { legIndex: 0, live: null }, zero + 20 * 60000);
    assert.equal(content.journeyPhase, 'pending_start');
    assert.equal(content.scheduledDeparture, '00:25');
    assert.deepEqual(content.upcomingDepartures, []);
    assert.equal(isExpiredOneOffSchedule(h.subscription, new Date(zero + 31 * 60000)), false);
    assert.equal(isExpiredOneOffSchedule(h.subscription, new Date(zero + 151 * 60000)), true);
});

test('durable subscription storage round-trips the itinerary and deduplicates repeated saves', async () => {
    const h = harness();
    h.owner.subscriptions.clear();
    const payload = { deviceId: 'device', pushToken: 'push', scheduleKind: 'one_off', daysOfWeek: [], notificationTypes: ['summary'],
        plannerJourney: plan(), legs: [{ enabled: true, from: 'AAA', to: 'BBB' }] };
    const first = await h.owner.upsertSubscription(payload);
    const second = await h.owner.upsertSubscription({ ...payload, plannerJourney: plan(120) });
    assert.equal(first.id, second.id);
    assert.equal(second.planner_journey.leadMinutes, 120);
    assert.equal(h.owner.subscriptions.size, 1);
    assert.equal(h.saved.get(first.id).plannerJourney.legs[0].uid, 'A12345');
});

test('a public live match verifies the selected operator, time and ordered calls', async () => {
    const now = zero - 60000;
    const record = { station: 'AAA', serviceID: 'opaque', generatedAt: new Date(now).toISOString(), detail: {
        crs: 'AAA', operatorCode: 'OP', std: '00:25', etd: '00:30',
        subsequentCallingPoints: [{ callingPoint: [{ crs: 'BBB', st: '00:55', et: '01:00' }] }]
    } };
    const provider = { supportsStaffRecovery: () => false,
        fetchBoards: async () => ({ boards: [{ station: 'AAA', generatedAt: record.generatedAt,
            services: [{ serviceID: 'opaque', operatorCode: 'OP', std: '00:25' }] }] }),
        fetchDetails: async () => ({ details: [record] }) };
    const resolver = new PlannerScheduleResolver(provider);
    assert.equal((await resolver.resolve(plan().legs[0], now)).from.departure, zero + 5 * 60000);
    record.detail.operatorCode = 'OTHER';
    assert.equal(await resolver.resolve(plan().legs[0], now), null);
});

test('live updates use the saved train, preserve it across app registration and end when cancelled', async () => {
    const h = harness();
    h.subscription.plannerState = { legIndex: 0, status: 'started' };
    const original = { scheduler: notificationSubscriptionManager.plannerScheduler,
        subscriptions: notificationSubscriptionManager.subscriptions, hydrated: notificationSubscriptionManager.hasHydratedFromMongo };
    const manager = new LiveActivityManager();
    clearInterval(manager.pollTimer);
    const pushes = [];
    manager.pushClient = { sendLiveActivityUpdate: async (token, payload) => { pushes.push(payload); return { status: 200 }; } };
    manager.logPushEvent = () => {};
    manager.saveSubscriptionToMongo = async () => {};
    manager.deleteSubscriptionFromMongo = async () => {};
    manager.getDeparturesSnapshot = async () => { throw new Error('Must not use the next-train board'); };
    const activity = { deviceId: 'device', activityId: 'activity', scheduleKey: 'planner:schedule', pushToken: 'update-token',
        fromStation: 'AAA', toStation: 'BBB', revision: 0, createdAt: new Date().toISOString() };
    manager.subscriptions.set('device::activity', activity);
    try {
        notificationSubscriptionManager.plannerScheduler = h.owner.plannerScheduler;
        notificationSubscriptionManager.subscriptions = h.owner.subscriptions;
        notificationSubscriptionManager.hasHydratedFromMongo = false;
        assert.equal((await manager.pollSubscription(activity)).reason, 'schedules_loading');
        notificationSubscriptionManager.hasHydratedFromMongo = true;
        await manager.pollSubscription(activity, { force: true });
        assert.equal(pushes[0].aps['content-state'].scheduledDeparture, '00:25');
        assert.equal(pushes[0].aps['content-state'].scheduleKey, 'planner:schedule');
        assert.equal(pushes[0].aps['content-state'].activityID, 'activity');
        manager.getDeparturesSnapshot = async (from, to, preferred) => {
            assert.equal(from, 'AAA');
            assert.equal(to, 'BBB');
            assert.equal(preferred, undefined, 'A route board must not pin the selected train');
            return { fetchedAt: new Date().toISOString(), departures: [
                { serviceID: 'earlier', scheduled: '08:55', estimated: 'On time', platform: '1', arrivalTime: '09:28' },
                { serviceID: 'selected', scheduled: '09:25', estimated: 'On time', platform: '2', arrivalTime: '09:58' }
            ] };
        };
        h.owner.plannerScheduler.routeContent = schedule => manager.buildPlannerRouteContent(schedule);
        await h.owner.updatePlannerDisplay({ deviceId: 'device', subscriptionId: 'schedule', showAllDepartures: true });
        await manager.refreshPlannerSchedule('device', 'schedule');
        assert.equal(pushes.at(-1).aps.event, 'update');
        assert.equal(pushes.at(-1).aps['content-state'].scheduledDeparture, '08:55');
        assert.equal(pushes.at(-1).aps['content-state'].upcomingDepartures[0].time, '09:25');
        assert.equal(pushes.at(-1).aps['content-state'].activityID, 'activity');
        await h.owner.updatePlannerDisplay({ deviceId: 'device', subscriptionId: 'schedule', showAllDepartures: false });
        await manager.refreshPlannerSchedule('device', 'schedule');
        assert.equal(pushes.at(-1).aps['content-state'].scheduledDeparture, '00:25');
        assert.deepEqual(pushes.at(-1).aps['content-state'].upcomingDepartures, []);
        assert.equal(h.pushes.length, 0, 'Changing the board must never send another activity start');
        h.owner.subscriptions.delete('schedule');
        await manager.pollSubscription(activity);
        assert.equal(pushes.at(-1).aps.event, 'end');
        assert.equal(manager.subscriptions.size, 0);
    } finally {
        notificationSubscriptionManager.plannerScheduler = original.scheduler;
        notificationSubscriptionManager.subscriptions = original.subscriptions;
        notificationSubscriptionManager.hasHydratedFromMongo = original.hydrated;
        for (const value of manager.subscriptions.values()) manager.clearEndTimer(value);
    }
});

test('all-departures starts with the route board and follows the current train leg', async () => {
    const h = harness();
    h.subscription.plannerJourney = plan(60, [train(), train('BBB', 'CCC', 40, 60)]);
    h.subscription.plannerJourney.showAllDepartures = true;
    const seen = [];
    h.owner.plannerScheduler.routeContent = async subscription => {
        const leg = subscription.plannerJourney.legs[subscription.plannerState.legIndex];
        seen.push(leg.from.crs);
        return { ...plannerContent(subscription, subscription.plannerState), estimated: '08:55' };
    };
    await h.owner.plannerScheduler.poll(h.subscription);
    assert.equal(h.pushes[0].aps['content-state'].estimated, '08:55');
    h.setNow(zero + 31 * 60000);
    h.owner.plannerScheduler.resolver.resolve = async () => ({ actualArrival: true, to: { arrival: zero + 30 * 60000 } });
    const content = await h.owner.plannerScheduler.snapshot(h.subscription);
    assert.equal(content.fromCRS, 'BBB');
    assert.equal(content.toCRS, 'CCC');
    assert.deepEqual(seen, ['AAA', 'BBB']);
});

test('empty or failed route boards never masquerade as the selected service', async () => {
    const h = harness();
    h.subscription.plannerState = { legIndex: 0 };
    const manager = new LiveActivityManager();
    clearInterval(manager.pollTimer);
    manager.getDeparturesSnapshot = async () => ({ departures: [], fetchedAt: new Date().toISOString() });
    assert.equal((await manager.buildPlannerRouteContent(h.subscription)).statusText, 'No upcoming departures');
    manager.getDeparturesSnapshot = async () => { throw new Error('offline'); };
    const unavailable = await manager.buildPlannerRouteContent(h.subscription);
    assert.equal(unavailable.statusText, 'Live departures unavailable');
    assert.equal(unavailable.scheduledDeparture, null);
    assert.deepEqual(unavailable.upcomingDepartures, []);
});

test('final arrival uses the confirmed arrival time and does not reset on a later refresh', async () => {
    const h = harness({ now: zero + 40 * 60000,
        resolve: async () => ({ actualArrival: true, to: { arrival: zero + 35 * 60000 } }) });
    const first = await h.owner.plannerScheduler.snapshot(h.subscription);
    assert.equal(first.journeyPhase, 'arrived');
    assert.equal(first.estimated, '01:00');
    h.setNow(zero + 41 * 60000);
    assert.equal((await h.owner.plannerScheduler.snapshot(h.subscription)).estimated, '01:00');
});
