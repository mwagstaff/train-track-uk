import assert from 'node:assert/strict';
import test from 'node:test';

import {
    getMetrics,
    recordJourneyEvent,
    updateJourneyGauges
} from '../lib/metrics.js';

test('journey metrics expose actions, known station names, and current counts', async () => {
    recordJourneyEvent({
        event: 'saved',
        journeyType: 'scheduled',
        stations: [
            { crs: 'VIC', role: 'origin' },
            { crs: 'KTH', role: 'destination' },
            { crs: 'NOT-A-STATION', role: 'origin' }
        ]
    });
    updateJourneyGauges({
        savedScheduled: 3,
        savedOneOff: 2,
        activeScheduled: 1,
        activeAdhoc: 4,
        trackedScheduled: 1,
        trackedAdhoc: 2
    });

    const metrics = await getMetrics();

    assert.match(metrics, /journey_events_total\{[^}]*event="saved"[^}]*journey_type="scheduled"[^}]*\} 1/);
    assert.match(metrics, /journey_station_events_total\{[^}]*station="VIC"[^}]*station_name="London Victoria"[^}]*role="origin"[^}]*\} 1/);
    assert.match(metrics, /journey_station_events_total\{[^}]*station="KTH"[^}]*station_name="Kent House"[^}]*role="destination"[^}]*\} 1/);
    assert.doesNotMatch(metrics, /NOT-A-STATION/);
    assert.match(metrics, /journeys_current\{[^}]*state="saved"[^}]*journey_type="scheduled"[^}]*\} 3/);
    assert.match(metrics, /journeys_current\{[^}]*state="active"[^}]*journey_type="adhoc"[^}]*\} 4/);
    assert.match(metrics, /journeys_current\{[^}]*state="tracked"[^}]*journey_type="adhoc"[^}]*\} 2/);
});
