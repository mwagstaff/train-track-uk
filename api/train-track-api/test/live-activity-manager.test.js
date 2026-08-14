import assert from 'node:assert/strict';
import test from 'node:test';

import { minutesUntilDeparture } from '../lib/live-activity-departure-order.js';

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
