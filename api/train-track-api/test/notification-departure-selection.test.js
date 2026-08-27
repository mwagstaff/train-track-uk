import assert from 'node:assert/strict';
import test from 'node:test';

import { selectUpcomingNotificationDepartures } from '../lib/notification-subscription-manager.js';

test('scheduled activity start excludes a service that departed in the previous minute', () => {
    const departures = [
        departure('departed', '06:57', '06:59'),
        departure('next', '07:12', '07:12'),
        departure('later', '07:27', '07:27'),
        departure('latest', '07:42', '07:42')
    ];

    const selected = selectUpcomingNotificationDepartures(departures, 7 * 60);

    assert.deepEqual(
        selected.map((item) => item.serviceID),
        ['next', 'later', 'latest']
    );
});

test('scheduled activity start keeps services in the current minute', () => {
    const departures = [
        departure('current', '07:00', '07:00'),
        departure('next', '07:12', '07:12')
    ];

    const selected = selectUpcomingNotificationDepartures(departures, 7 * 60);

    assert.deepEqual(selected.map((item) => item.serviceID), ['current', 'next']);
});

function departure(serviceID, scheduled, estimated) {
    return {
        serviceID,
        departure_time: { scheduled, estimated }
    };
}
