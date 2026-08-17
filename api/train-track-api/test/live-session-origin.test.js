import assert from 'node:assert/strict';
import test from 'node:test';

import { NotificationSubscriptionManager } from '../lib/notification-subscription-manager.js';

test('scheduled live-session origin is returned to clients', async () => {
    const manager = testManager();

    const subscription = await manager.upsertSubscription(registration({
        liveSessionOrigin: 'scheduled'
    }));

    assert.equal(subscription.source, 'live_session');
    assert.equal(subscription.live_session_origin, 'scheduled');
});

test('live sessions without an origin remain manual', async () => {
    const manager = testManager();

    const subscription = await manager.upsertSubscription(registration());

    assert.equal(subscription.live_session_origin, 'manual');
});

function testManager() {
    const manager = new NotificationSubscriptionManager();
    manager._saveSubscription = async () => {};
    manager.recordSubscriptionAudit = async () => {};
    return manager;
}

function registration(overrides = {}) {
    return {
        deviceId: 'device-1',
        pushToken: 'push-token',
        routeKey: 'KTH-VIC',
        daysOfWeek: ['mon'],
        notificationTypes: ['delays', 'platform'],
        legs: [{
            from: 'KTH',
            to: 'VIC',
            fromName: 'Kent House',
            toName: 'London Victoria',
            enabled: true,
            windowStart: '00:00',
            windowEnd: '23:59'
        }],
        source: 'live_session',
        activeUntil: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
        ...overrides
    };
}
