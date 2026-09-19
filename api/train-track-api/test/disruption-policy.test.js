import assert from 'node:assert/strict';
import test from 'node:test';
import { assessTimetableReadiness, decideProfileAdvisories } from '../lib/disruptions/policy.js';

const now = Date.parse('2026-09-19T12:00:00Z');
const status = { available: true, dataset: { version: 'current', sourceGenerationDate: '2026-09-18' } };
const ingestion = { schemaVersion: 1, enabled: true, inProgress: false, pendingGap: null, lastResult: 'unchanged',
    lastSuccessfulCheckAt: '2026-09-19T11:00:00Z', active: { version: 'current',
        metadata: { version: 'current', source: { generationDate: '2026-09-18' } }, validation: { valid: true } } };
const profile = { complete: true, datasetVersion: 'current', sourceGenerationDate: '2026-09-18', date: '2026-09-21',
    startMinutes: 420, endMinutes: 540, directTrains: 4, replacementBus: false, railOnlyAvailable: true,
    servicesAvailable: true, minChanges: 0, durationMinutes: 30, stationCRS: ['KTH', 'VIC'] };
const baselines = ['2026-09-07', '2026-09-14'].map(date => ({ ...profile, date }));
const kinds = result => result.advisories.map(value => value.kind);

test('alert readiness requires recent publication and verified active ingestion chain', () => {
    assert.equal(assessTimetableReadiness(status, ingestion, { now }).ready, true);
    assert.equal(assessTimetableReadiness(status, ingestion, { now, maxSourceAgeHours: 24 }).reason, 'timetable_stale');
    assert.equal(assessTimetableReadiness(status, undefined, { now }).reason, 'ingestion_unavailable');
    assert.equal(assessTimetableReadiness({ ...status, available: false }, ingestion, { now }).reason, 'timetable_unavailable');
});

test('recent uploads, imports and successful checks cannot make an old publication fresh', () => {
    const stale = { available: true, dataset: { version: 'current', sourceGenerationDate: '2026-08-25', importedAt: new Date(now).toISOString() } };
    assert.equal(assessTimetableReadiness(stale, ingestion, { now }).reason, 'timetable_stale');
});

test('unknown gap state, updates in progress, stale checks and invalid snapshots fail closed', () => {
    for (const [override, reason] of [
        [{ pendingGap: undefined }, 'timetable_update_gap'],
        [{ pendingGap: { missingCount: 22 } }, 'timetable_update_gap'],
        [{ lastErrorCode: 'UPDATE_GAP' }, 'timetable_update_gap'],
        [{ inProgress: true }, 'ingestion_in_progress'],
        [{ lastSuccessfulCheckAt: '2026-09-18T11:00:00Z' }, 'ingestion_check_stale'],
        [{ active: { ...ingestion.active, validation: null } }, 'timetable_not_validated'],
        [{ active: { ...ingestion.active, metadata: { ...ingestion.active.metadata, version: 'previous' } } }, 'timetable_version_mismatch']
    ]) assert.equal(assessTimetableReadiness(status, { ...ingestion, ...override }, { now }).reason, reason);
});

test('invalid and future publication dates never pass readiness', () => {
    for (const date of ['2026-02-30', 'not-a-date', '2026-09-20']) {
        assert.equal(assessTimetableReadiness({ ...status, dataset: { ...status.dataset, sourceGenerationDate: date } }, ingestion, { now }).ready, false);
    }
});

test('ordinary journeys produce no advisory; required buses do not require a baseline', () => {
    assert.deepEqual(kinds(decideProfileAdvisories(profile, baselines)), []);
    assert.deepEqual(kinds(decideProfileAdvisories({ ...profile, replacementBus: true, railOnlyAvailable: false }, [])), ['replacement_bus']);
    assert.deepEqual(kinds(decideProfileAdvisories({ ...profile, replacementBus: true }, [])), []);
});

test('lost direct services require two distinct comparable days with direct trains', () => {
    const current = { ...profile, directTrains: 0, minChanges: 1 };
    assert.deepEqual(kinds(decideProfileAdvisories(current, baselines)), ['direct_unavailable']);
    for (const previous of [[], [baselines[0]], [baselines[0], baselines[0]],
        [baselines[0], { ...baselines[1], date: current.date }],
        [baselines[0], { ...baselines[1], date: '2026-09-15' }],
        [baselines[0], { ...baselines[1], startMinutes: 480 }],
        [baselines[0], { ...baselines[1], directTrains: 0 }],
        [baselines[0], { ...baselines[1], excluded: true }],
        [baselines[0], { ...baselines[1], sourceGenerationDate: null }]]) {
        assert.deepEqual(kinds(decideProfileAdvisories(current, previous)), []);
    }
});

test('duration alerts use +15 minutes or 25 percent with at least five minutes', () => {
    for (const [normal, future, expected] of [[60, 74, false], [60, 75, true], [20, 25, true],
        [10, 14, false], [120, 135, true], [30, 37.5, true]]) {
        const result = decideProfileAdvisories({ ...profile, durationMinutes: future }, baselines.map(value => ({ ...value, durationMinutes: normal })));
        assert.equal(kinds(result).includes('longer_journey'), expected, `${normal} to ${future}`);
    }
});

test('known holidays and incompatible timetable seasons cannot establish the normal profile', () => {
    const changed = { ...profile, directTrains: 0, durationMinutes: 60 };
    assert.deepEqual(kinds(decideProfileAdvisories({ ...changed, holiday: true }, baselines)), []);
    assert.deepEqual(kinds(decideProfileAdvisories(changed, baselines.map(value => ({ ...value, holiday: true })))), []);
    assert.deepEqual(kinds(decideProfileAdvisories({ ...changed, timetableSeason: 'winter' },
        baselines.map(value => ({ ...value, timetableSeason: 'summer' })))), []);
});

test('comparison readiness counts only distinct eligible baseline evidence', () => {
    assert.equal(decideProfileAdvisories(profile, baselines).comparisonReady, true);
    for (const previous of [[baselines[0], baselines[0]],
        baselines.map(value => ({ ...value, servicesAvailable: false })),
        baselines.map(value => ({ ...value, sourceGenerationDate: null })),
        baselines.map(value => ({ ...value, durationMinutes: null })),
        baselines.map(value => ({ ...value, directTrains: null })),
        baselines.map(value => ({ ...value, excluded: true }))]) {
        assert.equal(decideProfileAdvisories(profile, previous).comparisonReady, false);
    }
    assert.equal(decideProfileAdvisories({ ...profile, durationMinutes: null }, baselines).comparisonReady, false);
    assert.equal(decideProfileAdvisories({ ...profile, complete: false }, baselines).comparisonReady, false);
    assert.equal(decideProfileAdvisories({ ...profile, holiday: true }, baselines).comparisonReady, false);
});

test('duration baseline uses median instead of an unusually quick single observation', () => {
    const result = decideProfileAdvisories({ ...profile, durationMinutes: 50 }, [
        { ...baselines[0], durationMinutes: 10 }, { ...baselines[1], durationMinutes: 40 }, { ...profile, date: '2026-08-31', durationMinutes: 40 }
    ]);
    assert.equal(result.advisories[0].baselineDurationMinutes, 40);
    assert.equal(result.advisories[0].extraMinutes, 10);
});

test('incomplete, empty or unavailable profiles stay unknown and never imply closure', () => {
    for (const current of [{ ...profile, complete: false, reason: 'search_truncated' },
        { ...profile, servicesAvailable: false }, { ...profile, directTrains: undefined }, { ...profile, date: '2026-02-30' }]) {
        const result = decideProfileAdvisories(current, baselines);
        assert.equal(result.state, 'unknown');
        assert.deepEqual(result.advisories, []);
    }
    assert.equal(decideProfileAdvisories(profile, baselines, { readiness: { ready: false, reason: 'timetable_update_gap' } }).state, 'unknown');
});

test('overnight windows retain their local starting-day baseline identity', () => {
    const current = { ...profile, startMinutes: 1380, endMinutes: 1500, directTrains: 0 };
    assert.deepEqual(kinds(decideProfileAdvisories(current, baselines.map(value => ({ ...value, startMinutes: 1380, endMinutes: 1500 })))), ['direct_unavailable']);
});
