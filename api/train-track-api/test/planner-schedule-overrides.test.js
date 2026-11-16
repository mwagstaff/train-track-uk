import test from 'node:test';
import assert from 'node:assert/strict';
import { plannerConflicts, preparePlannerOverrides, permanentReplacement, occurrenceIsReplaced } from '../lib/planner-schedule-overrides.js';
import { LiveActivityManager } from '../lib/live-activity-manager.js';
import { NotificationSubscriptionManager, notificationSubscriptionManager } from '../lib/notification-subscription-manager.js';
import { normalizePlannerSchedule } from '../lib/planner-journey-schedule.js';

const date = '2030-11-19'; // Tuesday
const regular = () => ({ id: 'regular', deviceId: 'device', source: 'scheduled', scheduleKind: 'regular',
    routeKey: 'KTH-VIC', daysOfWeek: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
    notificationTypes: ['summary', 'delays'], muteOnArrival: true, updatedAt: '2030-11-18T12:00:00.000Z',
    legs: [{ from: 'KTH', to: 'VIC', fromName: 'Kent House', toName: 'London Victoria', enabled: true,
        windowStart: '07:00', windowEnd: '09:00', dayWindows: { sat: { windowStart: '08:30', windowEnd: '12:30' }, sun: { windowStart: '08:30', windowEnd: '12:30' } } },
        { from: 'VIC', to: 'KTH', enabled: true, windowStart: '17:00', windowEnd: '19:00' }] });
const train = (from, to, departure, arrival) => ({ kind: 'vehicle', mode: 'rail',
    from: { crs: from, name: from }, to: { crs: to, name: to }, departure, arrival,
    uid: 'A12345', originDate: departure.slice(0, 10), operator: 'SE', calls: [] });
const input = () => ({ leadMinutes: 60, legs: [train('KTH', 'BFR', `${date}T09:03:00Z`, `${date}T09:27:00Z`)] });
const plan = () => normalizePlannerSchedule(input(), Date.parse(`${date}T00:00:00Z`));

test('09:03 overlaps via the lead time and skips only the complete morning occurrence', () => {
    const conflicts = plannerConflicts([regular()], 'device', plan());
    assert.equal(conflicts.length, 1);
    assert.equal(conflicts[0].start, `${date}T07:00:00.000Z`);
    assert.equal(occurrenceIsReplaced(conflicts, regular().legs[0], new Date(`${date}T07:00Z`)), true);
    assert.equal(occurrenceIsReplaced(conflicts, regular().legs[1], new Date(`${date}T18:00Z`)), false);
    assert.equal(occurrenceIsReplaced(conflicts, regular().legs[0], new Date('2030-11-20T08:00Z')), false);
    assert.equal(plannerConflicts([regular()], 'other-device', plan()).length, 0);
});

test('permanent route replacement retains weekend windows, return journey and preferences', () => {
    const original = regular(), selected = plan();
    preparePlannerOverrides([original], 'device', selected, { replacementMode: 'permanent', replacements: plannerConflicts([original], 'device', selected) });
    const changed = permanentReplacement(original, selected);
    assert.equal(changed.legs[0].to, 'BFR');
    assert.equal(changed.routeKey, 'BFR-KTH');
    assert.equal(changed.directionSplitIndex, 1);
    assert.deepEqual(changed.legs[0].dayWindows, original.legs[0].dayWindows);
    assert.deepEqual(changed.legs[1], original.legs[1]);
    assert.deepEqual(changed.notificationTypes, original.notificationTypes);
    assert.equal(changed.muteOnArrival, true);
    assert.equal(original.legs[0].to, 'VIC');
});

test('connected itinerary replaces the route with all selected train legs', () => {
    const selected = normalizePlannerSchedule({ leadMinutes: 60, legs: [
        train('KTH', 'HNH', `${date}T09:03Z`, `${date}T09:15Z`),
        train('HNH', 'BFR', `${date}T09:20Z`, `${date}T09:35Z`)
    ] }, Date.parse(`${date}T00:00Z`));
    selected.replacements = plannerConflicts([regular()], 'device', selected);
    assert.deepEqual(permanentReplacement(regular(), selected).legs.map(l => [l.from, l.to]), [['KTH', 'HNH'], ['HNH', 'BFR'], ['VIC', 'KTH']]);
});

test('server rejects stale or cross-device replacement selections', () => {
    const selected = plan(), conflicts = plannerConflicts([regular()], 'device', selected);
    assert.throws(() => preparePlannerOverrides([regular()], 'device', selected, { replacementMode: 'once', replacements: [] }), /changed/);
    const changed = regular(); changed.updatedAt = 'new revision';
    assert.throws(() => preparePlannerOverrides([changed], 'device', selected, { replacementMode: 'once', replacements: conflicts }), /changed/);
    assert.throws(() => preparePlannerOverrides([regular()], 'other', selected, { replacementMode: 'once', replacements: conflicts }), /changed/);
});

test('London occurrences honour summer time and overnight windows', () => {
    const original = regular();
    const selected = { startsAt: '2030-07-16T07:03:00Z', arrival: '2030-07-16T08:27:00Z' };
    assert.equal(plannerConflicts([original], 'device', selected)[0].start, '2030-07-16T06:00:00.000Z');
    original.legs[0].windowStart = '23:00'; original.legs[0].windowEnd = '01:00';
    const overnight = plannerConflicts([original], 'device', { startsAt: '2030-11-19T23:30:00Z', arrival: '2030-11-20T00:30:00Z' });
    assert.equal(overnight[0].end, '2030-11-20T01:00:00.000Z');
});

function harness() {
    const manager = new NotificationSubscriptionManager();
    const saved = new Map();
    manager._saveSubscription = async sub => saved.set(sub.id, structuredClone(sub));
    manager._deleteFromMongo = async id => saved.delete(id);
    manager.recordSubscriptionAudit = async () => {};
    manager.auditScheduledPushToStartReadiness = async () => {};
    manager.subscriptions.set('regular', regular());
    return { manager, saved };
}
function request(manager, mode = 'once') {
    const selected = input();
    selected.replacementMode = mode;
    selected.replacements = manager.plannerConflicts('device', selected);
    return { deviceId: 'device', pushToken: 'token', source: 'scheduled', scheduleKind: 'one_off',
        notificationTypes: ['summary'], daysOfWeek: [], plannerJourney: selected,
        legs: [{ from: 'KTH', to: 'BFR', enabled: true, windowStart: '09:03', windowEnd: '09:27', travelDate: date }] };
}

test('save, restart and cancellation keep temporary exceptions attached to the plan', async () => {
    const { manager, saved } = harness();
    const created = await manager.upsertSubscription(request(manager));
    const time = new Date(`${date}T07:30Z`);
    assert.equal(manager.isReplaced(manager.subscriptions.get('regular'), regular().legs[0], time), true);
    const restarted = harness().manager;
    restarted.subscriptions.set(created.id, saved.get(created.id));
    assert.equal(restarted.isReplaced(restarted.subscriptions.get('regular'), regular().legs[0], time), true);
    await restarted.deleteSubscription({ deviceId: 'device', subscriptionId: created.id });
    assert.equal(restarted.isReplaced(restarted.subscriptions.get('regular'), regular().legs[0], time), false);
});

test('failed initial save leaves the regular schedule intact and no exception', async () => {
    const { manager } = harness();
    manager._saveSubscription = async () => { throw new Error('disk unavailable'); };
    await assert.rejects(manager.upsertSubscription(request(manager, 'permanent')), /disk unavailable/);
    assert.equal(manager.subscriptions.size, 1);
    assert.equal(manager.subscriptions.get('regular').legs[0].to, 'VIC');
    assert.deepEqual(manager.replacedOccurrences(regular()), []);
});

test('permanent edits survive cancellation and retries do not duplicate the selected journey', async () => {
    const { manager } = harness();
    const payload = request(manager, 'permanent');
    const created = await manager.upsertSubscription(payload);
    const repeated = await manager.upsertSubscription(payload);
    assert.equal(created.id, repeated.id);
    assert.equal(manager.subscriptions.size, 2);
    const changed = manager.subscriptions.get('regular');
    assert.equal(changed.legs[0].to, 'BFR');
    assert.equal(manager.isReplaced(changed, changed.legs[0], new Date(`${date}T07:30Z`)), true);
    await manager.deleteSubscription({ deviceId: 'device', subscriptionId: created.id });
    assert.equal(manager.subscriptions.get('regular').legs[0].to, 'BFR');
});

test('a committed permanent change recovers after failure before updating the regular record', async () => {
    const { manager, saved } = harness();
    const save = manager._saveSubscription;
    manager._saveSubscription = async sub => { if (sub.id === 'regular') throw new Error('interrupted'); await save(sub); };
    await assert.rejects(manager.upsertSubscription(request(manager, 'permanent')), /interrupted/);
    const restarted = harness().manager;
    for (const [id, sub] of saved) restarted.subscriptions.set(id, sub);
    await restarted.applyPendingPlannerChanges();
    assert.equal(restarted.subscriptions.get('regular').legs[0].to, 'BFR');
    assert.equal(restarted.subscriptions.size, 2);
});


test('cancelling after tracking was due retains the exception until the occurrence ends', async t => {
    const { manager } = harness();
    const created = await manager.upsertSubscription(request(manager));
    let now = Date.parse(`${date}T08:30:00Z`);
    t.mock.method(Date, 'now', () => now);
    await manager.deleteSubscription({ deviceId: 'device', subscriptionId: created.id });
    assert.equal(manager.subscriptions.get(created.id).hiddenFromSchedules, true);
    assert.equal(manager.listSubscriptions('device').some(s => s.id === created.id), false);
    assert.equal(manager.isReplaced(manager.subscriptions.get('regular'), regular().legs[0], new Date(Date.now())), true);
    assert.equal(manager.plannerScheduler.find('device', `planner:${created.id}`), null);
    now = Date.parse(`${date}T12:00:00Z`);
    await manager.deleteSubscription({ deviceId: 'device', subscriptionId: created.id });
    assert.equal(manager.subscriptions.has(created.id), false);
});

test('simultaneous saves are idempotent and conflicting selected journeys are rejected', async () => {
    const { manager } = harness();
    const payload = request(manager);
    const [a, b] = await Promise.all([manager.upsertSubscription(payload), manager.upsertSubscription(payload)]);
    assert.equal(a.id, b.id);
    assert.equal(manager.subscriptions.size, 2);
    const overlapping = request(manager);
    overlapping.plannerJourney.legs[0].departure = `${date}T09:05:00Z`;
    await assert.rejects(manager.upsertSubscription(overlapping), /overlaps/);
});

test('clock-change occurrences cover both instances of the repeated hour', () => {
    const original = regular();
    original.legs[0].dayWindows = null;
    original.legs[0].windowStart = '01:00'; original.legs[0].windowEnd = '02:30';
    const conflicts = plannerConflicts([original], 'device', { startsAt: '2030-10-27T00:15:00Z', arrival: '2030-10-27T02:00:00Z' });
    assert.equal(conflicts[0].start, '2030-10-27T00:00:00.000Z');
    assert.equal(conflicts[0].end, '2030-10-27T02:30:00.000Z');
    assert.equal(occurrenceIsReplaced(conflicts, original.legs[0], new Date('2030-10-27T01:15:00Z')), true);
    const spring = plannerConflicts([original], 'device', { startsAt: '2030-03-31T00:45:00Z', arrival: '2030-03-31T02:00:00Z' });
    assert.equal(spring[0].start, '2030-03-31T01:00:00.000Z');
});


test('replaced regular cards can be released without ending a boarded journey', async t => {
    const manager = new LiveActivityManager();
    clearInterval(manager.pollTimer);
    t.mock.method(notificationSubscriptionManager, 'isReplacedScheduleKey', () => true);
    const ended = [];
    manager.sendEndUpdate = async sub => { ended.push(sub.activityId); manager.subscriptions.delete(sub.activityId); };
    const pending = { deviceId: 'device', activityId: 'regular-card', scheduleKey: 'KTH-VIC|07:00|09:00|2030-11-19', journeyPhase: 'at_start' };
    const boarded = { ...pending, activityId: 'boarded', journeyPhase: 'en_route' };
    manager.subscriptions.set(pending.activityId, pending);
    manager.subscriptions.set(boarded.activityId, boarded);
    await manager.releaseReplacedActivities('device');
    assert.deepEqual(ended, ['regular-card']);
    assert.equal(manager.subscriptions.has('boarded'), true);
    const lateEnds = [];
    manager.sendEndPushForEvictedSubscription = async sub => { lateEnds.push(sub.activityId); };
    const late = manager.registerSubscription({ deviceId: 'device', activityId: 'late', pushToken: 'test',
        fromStation: 'KTH', toStation: 'VIC', scheduleKey: pending.scheduleKey });
    assert.equal(late.evicted, true);
    assert.deepEqual(lateEnds, ['late']);
    assert.equal(manager.subscriptions.has('device::late'), false);
});
