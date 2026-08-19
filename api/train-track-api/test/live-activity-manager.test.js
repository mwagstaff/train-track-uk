import assert from 'node:assert/strict';
import test from 'node:test';

import { minutesUntilDeparture } from '../lib/live-activity-departure-order.js';
import { liveActivityManager } from '../lib/live-activity-manager.js';

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
