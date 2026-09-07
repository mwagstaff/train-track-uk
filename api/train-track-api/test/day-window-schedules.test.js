import assert from 'node:assert/strict';
import test from 'node:test';
import { NotificationSubscriptionManager, resolveLegWindow, shouldPollNow } from '../lib/notification-subscription-manager.js';

const weekends = {
    sat: { window_start: '09:00', window_end: '11:00' },
    sun: { window_start: '09:00', window_end: '11:00' }
};

function registration() {
    return {
        deviceId: 'day-window-test', pushToken: 'test-token', routeKey: 'KTH-VIC',
        source: 'scheduled', scheduleKind: 'regular',
        daysOfWeek: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
        notificationTypes: ['summary', 'delays'],
        legs: [{ from: 'KTH', to: 'VIC', enabled: true,
            window_start: '07:00', window_end: '09:00', day_windows: weekends }]
    };
}

function manager() {
    const result = new NotificationSubscriptionManager();
    result._saveSubscription = async () => {};
    result.recordSubscriptionAudit = async () => {};
    result.auditScheduledPushToStartReadiness = async () => {};
    return result;
}

test('day windows persist, round trip through the API, and can be replaced on edit', async () => {
    const store = manager();
    const saved = await store.upsertSubscription(registration());
    assert.deepEqual(saved.legs[0].day_windows, weekends);
    const stored = store.subscriptions.get(saved.id);
    assert.deepEqual(stored.legs[0].dayWindows.sat, { windowStart: '09:00', windowEnd: '11:00' });
    const update = { ...registration(), subscriptionId: saved.id, legs: saved.legs };
    const reloaded = await store.upsertSubscription(update);
    assert.deepEqual(reloaded.legs[0].day_windows, weekends);
    delete update.legs[0].day_windows;
    assert.equal((await store.upsertSubscription(update)).legs[0].day_windows, null);
});

test('weekday and weekend windows control polling in London local time', async () => {
    const store = manager();
    const saved = await store.upsertSubscription(registration());
    const sub = store.subscriptions.get(saved.id);
    const leg = sub.legs[0];
    for (const [iso, expected] of [
        ['2026-09-04T06:00:00Z', true], // Friday 07:00 BST
        ['2026-09-04T08:30:00Z', false],
        ['2026-09-05T06:30:00Z', false], // Saturday 07:30 BST
        ['2026-09-05T08:00:00Z', true],
        ['2026-09-05T10:01:00Z', false],
        ['2026-09-06T09:00:00Z', true],
        ['2026-12-05T08:30:00Z', false], // Saturday, GMT
        ['2026-12-05T09:00:00Z', true]
    ]) assert.equal(shouldPollNow(sub, leg, new Date(iso)), expected, iso);
    sub.daysOfWeek = ['mon'];
    assert.equal(shouldPollNow(sub, leg, new Date('2026-09-05T09:00:00Z')), false);
});

test('resolved alert and live activity windows do not mutate the saved defaults', async () => {
    const store = manager();
    const saved = await store.upsertSubscription(registration());
    const sub = store.subscriptions.get(saved.id);
    const leg = sub.legs[0];
    const effective = resolveLegWindow(sub, leg, new Date('2026-09-05T09:00:00Z'));
    assert.equal(effective.windowStart, '09:00');
    assert.equal(effective.windowEnd, '11:00');
    assert.equal(leg.windowStart, '07:00');
    assert.equal(resolveLegWindow(sub, leg, new Date('2026-09-04T06:00:00Z')).windowStart, '07:00');
    assert.equal(resolveLegWindow({ ...sub, source: 'live_session' }, leg).windowStart, '07:00');
});

test('custom windows are independent for individual days and return legs', async () => {
    const store = manager();
    const request = registration();
    request.legs[0].day_windows = { ...weekends, wed: { window_start: '08:15', window_end: '09:15' } };
    request.legs.push({ from: 'VIC', to: 'KTH', enabled: true, window_start: '16:00', window_end: '18:00',
        day_windows: { sat: { window_start: '12:00', window_end: '13:00' } } });
    const saved = await store.upsertSubscription(request);
    const sub = store.subscriptions.get(saved.id);
    assert.equal(shouldPollNow(sub, sub.legs[0], new Date('2026-09-09T06:30:00Z')), false);
    assert.equal(shouldPollNow(sub, sub.legs[0], new Date('2026-09-09T07:30:00Z')), true);
    assert.equal(shouldPollNow(sub, sub.legs[1], new Date('2026-09-05T11:30:00Z')), true);
    assert.equal(shouldPollNow(sub, sub.legs[0], new Date('2026-09-05T11:30:00Z')), false);
});

test('invalid day names, times, and windows are rejected without saving', async () => {
    for (const dayWindows of [
        [], '09:00', { monday: weekends.sat }, { sat: null },
        { sat: { window_start: '09:00', window_end: '14:01' } },
        { sat: { window_start: '11:00', window_end: '09:00' } },
        { sat: { window_start: '24:00', window_end: '11:00' } },
        { sat: { window_start: '9.5:00', window_end: '11:00' } },
        { sat: { window_start: '09:00' } }
    ]) {
        const store = manager();
        const request = registration();
        request.legs[0].day_windows = dayWindows;
        await assert.rejects(store.upsertSubscription(request), /window|HH:mm/i);
        assert.equal(store.subscriptions.size, 0);
    }
});

test('one-off schedules ignore recurring day overrides', async () => {
    const store = manager();
    const request = registration();
    request.scheduleKind = 'one_off';
    request.daysOfWeek = [];
    request.legs[0].travel_date = '2026-09-05';
    const saved = await store.upsertSubscription(request);
    assert.equal(saved.legs[0].day_windows, null);
    const sub = store.subscriptions.get(saved.id);
    assert.equal(shouldPollNow(sub, sub.legs[0], new Date('2026-09-05T06:30:00Z')), true);
    assert.equal(shouldPollNow(sub, sub.legs[0], new Date('2026-09-05T09:30:00Z')), false);
});


test('regular and one-off schedules accept five hours but reject longer shared windows', async () => {
    for (const scheduleKind of ['regular', 'one_off']) {
        const request = registration();
        request.scheduleKind = scheduleKind;
        request.legs[0].travel_date = '2026-09-05';
        request.legs[0].window_end = '12:00';
        const saved = await manager().upsertSubscription(request);
        assert.equal(saved.legs[0].window_end, '12:00');
        request.legs[0].window_end = '12:01';
        await assert.rejects(manager().upsertSubscription(request), /within 5 hours/);
    }
});

test('per-day windows accept exactly five hours and poll throughout the extended window', async () => {
    const store = manager();
    const request = registration();
    request.legs[0].day_windows = { sat: { window_start: '09:00', window_end: '14:00' } };
    const saved = await store.upsertSubscription(request);
    assert.equal(saved.legs[0].day_windows.sat.window_end, '14:00');
    const sub = store.subscriptions.get(saved.id);
    assert.equal(shouldPollNow(sub, sub.legs[0], new Date('2026-09-05T12:30:00Z')), true);
    assert.equal(shouldPollNow(sub, sub.legs[0], new Date('2026-09-05T13:01:00Z')), false);
    request.legs[0].day_windows.sat.window_end = '14:01';
    await assert.rejects(manager().upsertSubscription(request), /within 5 hours/);
});
