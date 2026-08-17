import assert from 'node:assert/strict';
import test from 'node:test';

import {
    buildMuteNotificationPlan,
    resolveDetectionSource,
    resolveMuteTransition
} from '../lib/notification-mute-policy.js';

test('legacy location fallback is treated as a station exit', () => {
    const context = { reason: 'location_exit_fallback' };

    assert.equal(resolveMuteTransition(context), 'station_exit');
    assert.equal(resolveDetectionSource(context), 'location_fallback');

    const plan = buildMuteNotificationPlan({ stationName: 'London Victoria', ...context });
    assert.equal(plan.length, 1);
    assert.equal(plan[0].type, 'muted_greeting');
    assert.equal(
        plan[0].body,
        "You've left London Victoria station. Enjoy your journey!"
    );
});

test('structured station exit is independent of its detection source', () => {
    const context = {
        reason: 'station_exit',
        transition: 'station_exit',
        detectionSource: 'location_fallback'
    };

    assert.equal(resolveMuteTransition(context), 'station_exit');
    assert.equal(resolveDetectionSource(context), 'location_fallback');

    const plan = buildMuteNotificationPlan({ stationName: 'London Victoria', ...context });
    assert.equal(plan.length, 1);
    assert.match(plan[0].body, /^You've left /);
    assert.equal(plan.some((notification) => notification.type === 'muted_status'), false);
});

test('tracked station exit uses the matched service boarding confirmation', () => {
    const body = "You’re on the delayed 17:27 to Kent House, currently 5 minutes late. Enjoy your journey!";
    const plan = buildMuteNotificationPlan({
        stationName: 'London Victoria',
        reason: 'station_exit',
        transition: 'station_exit',
        journeyNotificationBody: body
    });

    assert.equal(plan.length, 1);
    assert.equal(plan[0].body, body);
});

test('arrival mute retains the welcome and status pair', () => {
    const plan = buildMuteNotificationPlan({
        stationName: 'London Victoria',
        reason: 'mute_on_arrival',
        transition: 'arrival'
    });

    assert.equal(plan.length, 2);
    assert.equal(plan[0].body, 'Welcome to London Victoria station');
    assert.equal(plan[1].type, 'muted_status');
});
