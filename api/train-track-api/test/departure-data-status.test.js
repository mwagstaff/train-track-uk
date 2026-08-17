import assert from 'node:assert/strict';
import test from 'node:test';

import { formatDepartureJourneyResult, shouldIncludeDepartureStatus } from '../lib/departure-response.js';
import { mergeJourneyDepartureResponses } from '../lib/realtime-trains-api.js';

const fetchedAt = '2026-08-16T15:53:37.000Z';

test('journey data is live when both departure windows succeed, including an empty board', () => {
    const result = mergeJourneyDepartureResponses(
        { departures: [] },
        { departures: [] },
        fetchedAt
    );

    assert.deepEqual(result, {
        departures: [],
        dataStatus: 'live',
        lastSuccessfulUpdate: fetchedAt
    });
});

test('journey data is partial when only one departure window succeeds', () => {
    const departure = { serviceID: 'service-1' };
    const result = mergeJourneyDepartureResponses(
        { error: 'upstream failed' },
        { departures: [departure] },
        fetchedAt
    );

    assert.deepEqual(result, {
        departures: [departure],
        dataStatus: 'partial',
        lastSuccessfulUpdate: fetchedAt
    });
});

test('journey data is unavailable when both departure windows fail', () => {
    const result = mergeJourneyDepartureResponses(
        { error: 'upstream failed' },
        { error: 'upstream failed' },
        fetchedAt
    );

    assert.deepEqual(result, {
        departures: [],
        dataStatus: 'unavailable',
        lastSuccessfulUpdate: null,
        error: 'Failed to get data from API'
    });
});

test('departure response status is opt-in and preserves the legacy shape', () => {
    const data = {
        departures: [{ serviceID: 'service-1' }],
        dataStatus: 'stale',
        lastSuccessfulUpdate: fetchedAt
    };

    assert.deepEqual(formatDepartureJourneyResult('BTN_ECR', data, false), {
        BTN_ECR: [{ serviceID: 'service-1' }]
    });
    assert.deepEqual(formatDepartureJourneyResult('BTN_ECR', data, true), {
        BTN_ECR: {
            departures: [{ serviceID: 'service-1' }],
            data_status: 'stale',
            last_successful_update: fetchedAt
        }
    });
    assert.equal(shouldIncludeDepartureStatus('true'), true);
    assert.equal(shouldIncludeDepartureStatus('1'), true);
    assert.equal(shouldIncludeDepartureStatus(undefined), false);
});
