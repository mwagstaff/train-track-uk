import test from 'node:test';
import assert from 'node:assert/strict';
import { NotificationSubscriptionManager } from '../lib/notification-subscription-manager.js';

async function setup() {
    const manager = new NotificationSubscriptionManager({ getNotificationPreferences: async () => ({}) });
    const pushes = [];
    manager._saveSubscription = async () => {};
    manager._deleteFromMongo = async () => {};
    manager.recordSubscriptionAudit = async () => {};
    manager.logSendEvent = () => {};
    manager.pushClient.sendNotification = async (_token, payload) => { pushes.push(payload); return { status: 200 }; };
    const created = await manager.upsertSubscription({ deviceId: 'device', pushToken: 'token',
        source: 'live_session', routeKey: 'KTH-HNH-BFR', notificationTypes: ['delays', 'platform'],
        legs: [
            { from: 'KTH', to: 'HNH', fromName: 'Kent House', toName: 'Herne Hill' },
            { from: 'HNH', to: 'BFR', fromName: 'Herne Hill', toName: 'London Blackfriars' }
        ].map(leg => ({ ...leg, enabled: true, windowStart: '00:00', windowEnd: '23:59' })) });
    const subscription = manager.subscriptions.get(created.id);
    const update = async (index, estimated, platform = '2', destination = { locationName: 'Sutton (London)', via: 'Wimbledon' }) => {
        const leg = subscription.legs[index];
        await manager.sendUpdateNotifications(subscription, leg, `${leg.from}-${leg.to}`, {
            departures: [{ serviceID: `train-${index}`, scheduled: '09:27', estimated, platform, destination, isCancelled: false }]
        });
    };
    const phase = (value, context) => manager.recordJourneyPhase('device', {
        fromStation: 'KTH', toStation: 'BFR', phase: value, legContext: context
    });
    return { manager, subscription, pushes, update, phase };
}

test('waiting at Kent House alerts only for Kent House, not the next Herne Hill train', async () => {
    const h = await setup();
    await h.phase('at_start');
    for (const estimate of ['09:27', '09:30', '09:29']) {
        await h.update(0, estimate);
        await h.update(1, estimate, '1');
    }
    assert.equal(h.pushes.length, 2);
    assert.ok(h.pushes.every(push => push.aps.alert.title === '09:27 to Sutton (London) via Wimbledon' && push.aps.alert.subtitle === 'Change at Herne Hill'));
    assert.match(h.pushes[0].aps.alert.body, /Expected 09:30 · 3 min late/);
});

test('interchange arrival enables its departure updates and boarding suppresses them again', async () => {
    const h = await setup();
    const context = { from: 'HNH', to: 'BFR', connection: true, at_station: false };
    await h.phase('en_route', context);
    await h.update(1, '09:27');
    await h.update(1, '09:30');
    assert.equal(h.pushes.length, 0);
    context.at_station = true;
    await h.phase('en_route', context);
    h.manager.getDeviceLiveActivities = () => [{ fromStation: 'KTH', toStation: 'HNH', journeyPhase: 'en_route',
        legContext: { from: 'HNH', to: 'BFR', connection: true, atStation: true,
            remainingConnections: [{ from: 'HNH', to: 'BFR' }] } }];
    await h.update(1, '09:27');
    await h.update(1, '09:30', '3');
    assert.equal(h.pushes.length, 2);
    assert.ok(h.pushes.every(push => push.aps.alert.subtitle === 'Get off at London Blackfriars'));
    assert.equal(h.manager.allowsDepartureAlerts(h.subscription, h.subscription.legs[0]), false);
    context.at_station = false;
    await h.phase('en_route', context);
    await h.update(1, '09:31', '4');
    assert.equal(h.pushes.length, 2);
    assert.equal(h.manager.getActiveSubscriptionForPush(h.subscription.id, h.subscription.legs[1], 'update_pre_send'), null);
});

test('muting a boarded leg retains the live session until the final leg is muted', async () => {
    const h = await setup();
    for (const [index, leg] of h.subscription.legs.entries()) {
        await h.manager.muteLegForDate({ deviceId: 'device', subscriptionId: h.subscription.id,
            from: leg.from, to: leg.to, reason: 'station_exit' });
        assert.equal(h.manager.subscriptions.has(h.subscription.id), index === 0);
    }
});

test('independent scheduled legs and single-leg live journeys retain their alert behavior', async () => {
    const h = await setup();
    assert.equal(h.manager.allowsDepartureAlerts({ ...h.subscription, source: 'scheduled' }, h.subscription.legs[1]), true);
    assert.equal(h.manager.allowsDepartureAlerts({ ...h.subscription, legs: [h.subscription.legs[1]] }, h.subscription.legs[1]), true);
});

test('departure updates identify the advertised train and keep route metadata for navigation', async () => {
    const h = await setup();
    Object.assign(h.subscription.legs[0], { from: 'BFR', fromName: 'London Blackfriars' });
    Object.assign(h.subscription.legs[1], { to: 'KTH', toName: 'Kent House' });
    await h.update(0, '09:27', '1');
    await h.update(0, '09:31', '1', [{ locationName: 'Sutton (London)' }]);
    const push = h.pushes[0];
    assert.deepEqual(push.aps.alert, {
        title: '09:27 to Sutton (London)', subtitle: 'Change at Herne Hill',
        body: 'From London Blackfriars · Platform 1\nExpected 09:31 · 4 min late'
    });
    assert.equal(push.from, 'BFR');
    assert.equal(push.to, 'HNH');
    assert.equal(push.alert_type, 'delay');
});

test('intermediate-leg platform changes retain the train, change station and timing', async () => {
    const h = await setup();
    h.subscription.legs.push({ ...h.subscription.legs[1], from: 'BFR', fromName: 'London Blackfriars', to: 'STP', toName: 'St Pancras' });
    await h.phase('en_route', { from: 'HNH', to: 'BFR', connection: true, at_station: true });
    const destination = { locationName: 'St Albans', via: 'via London Blackfriars' };
    await h.update(1, '09:27', '1', destination);
    await h.update(1, '09:27', '3', destination);
    assert.deepEqual(h.pushes[0].aps.alert, {
        title: '09:27 to St Albans via London Blackfriars', subtitle: 'Change at London Blackfriars',
        body: 'From Herne Hill · Platform 3\nPlatform changed: 1 → 3\nExpected 09:27'
    });
});

test('missing destination and unknown platform do not invent train details', async () => {
    const h = await setup();
    await h.update(0, '09:27', null, null);
    await h.update(0, '09:30', null, null);
    assert.deepEqual(h.pushes[0].aps.alert, {
        title: '09:27 from Kent House', subtitle: 'Change at Herne Hill',
        body: 'From Kent House · Platform TBC\nExpected 09:30 · 3 min late'
    });
    await h.phase('at_start');
    await h.update(0, 'Delayed', '3', null);
    assert.equal(h.pushes.at(-1).aps.alert.body,
        'From Kent House · Platform 3\nPlatform announced\nDelayed · departure time not confirmed');
    await h.update(0, 'On time', '4', null);
    assert.equal(h.pushes.at(-1).aps.alert.body,
        'From Kent House · Platform 4\nPlatform changed: 3 → 4\nExpected 09:27');
});

test('independent scheduled legs do not receive interchange instructions', async () => {
    const h = await setup();
    h.subscription.source = 'scheduled';
    await h.update(0, '09:27');
    await h.update(0, '09:30');
    assert.equal(h.pushes[0].aps.alert.title, 'Kent House → Herne Hill');
    assert.equal(h.pushes[0].aps.alert.subtitle, undefined);
});
