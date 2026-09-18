import test from 'node:test';
import assert from 'node:assert/strict';
import { PlannerEngine } from '../lib/planner/engine.js';
import { normalizeRequest, decodeCursor } from '../lib/planner/contract.js';
import { scheduledCandidate } from '../lib/planner/router.js';

const NOW = Date.parse('2026-09-18T10:00:00Z');
const iso = time => new Date(time).toISOString();
const version = 'a'.repeat(64);
const stations = ['PAD', 'VIC'].map(crs => ({ crs, name: crs, minimumChangeMinutes: 5 }));
const request = normalizeRequest({ origin: 'PAD', destination: 'VIC', time: iso(NOW + 60000), timeType: 'departAfter', limit: 1 });
function setup({ tube = true } = {}) {
    let clock = NOW, calls = 0;
    const repo = { version, stations, rules: { tsi: [], links: [] }, close() {},
        metadata: { source: { generationDate: '2026-09-01' }, importedAt: iso(NOW),
            coverage: { startDate: '2026-09-01', endDate: '2026-10-01' }, limitations: [] } };
    const engine = new PlannerEngine({ enabled: true, tubeTrackEnabled: true, datasetPath: '/synthetic',
        timeoutMs: 1000, maxOperations: 100000, maxStaleDays: 45, warnAgeDays: 35, dateCacheSize: 6 },
    { now: () => clock, openDataset: async () => repo, tubeProvider: {} });
    engine.network = async () => ({ diagnostics: { counts: { UNRESOLVED: 1 } } });
    engine.route = async (query, network, options) => {
        calls++;
        assert.equal(Boolean(options.timetableOnly), !tube);
        const journeys = [0, 1, 2].map(i => {
            const departure = iso(NOW + (i + 1) * 60000), arrival = iso(NOW + (i + 21) * 60000);
            return { departure, arrival, durationMinutes: 20, changes: 0,
                legs: [{ kind: 'transfer', mode: 'tubeTransfer', departure, arrival, from: stations[0], to: stations[1],
                    ...(tube ? { localJourney: { status: 'available', id: `${calls}:${i}`, steps: [],
                        updatedAt: iso(clock), expiresAt: iso(clock + 20000) } } : {}) }] };
        });
        return { journeys, ...(tube ? { tubeExpiresAt: clock + 20000 } : {}), warnings: [],
            searchWindow: { from: query.time, to: iso(NOW + 3600000) }, pagination: {}, searchTruncated: false };
    };
    return { engine, get calls() { return calls; }, advance: ms => { clock += ms; } };
}

test('scheduled TfL pages pin alternatives and expire together instead of silently reranking', async () => {
    const fixture = setup();
    const first = await fixture.engine.search({ request });
    assert.equal(first.journeys.length, 1);
    const cursor = decodeCursor(first.pagination.more);
    assert.ok(cursor.tubeSnapshotId);
    fixture.advance(1000);
    const second = await fixture.engine.search(cursor);
    assert.equal(fixture.calls, 1);
    assert.equal(second.journeys[0].legs[0].localJourney.id, '1:1');
    assert.notEqual(second.journeys[0].id, first.journeys[0].id);
    assert.deepEqual(second.warnings, first.warnings);
    fixture.advance(20000);
    await assert.rejects(fixture.engine.search(cursor), { code: 'CURSOR_EXPIRED' });
    await fixture.engine.search({ request });
    assert.equal(fixture.calls, 2);
});

test('selected journey details preserve the original Tube snapshot and its expiry', async () => {
    const fixture = setup();
    const first = await fixture.engine.search({ request });
    fixture.advance(21000);
    const detail = await fixture.engine.journey(first.journeys[0].id);
    assert.deepEqual(detail.journey.legs[0].localJourney, first.journeys[0].legs[0].localJourney);
    assert.equal(detail.journey.legs[0].localJourney.expiresAt, iso(NOW + 20000));
});

test('enabling TfL does not expand a rail-only page beyond the requested limit', async () => {
    const fixture = setup();
    const route = fixture.engine.route;
    fixture.engine.route = async (...args) => {
        const result = await route(...args);
        delete result.tubeExpiresAt;
        for (const journey of result.journeys) for (const leg of journey.legs) delete leg.localJourney;
        return result;
    };
    const first = await fixture.engine.search({ request });
    assert.equal(first.journeys.length, 1);
    const cursor = decodeCursor(first.pagination.more);
    assert.equal(cursor.tubeSnapshotId, undefined);
    const second = await fixture.engine.search(cursor);
    assert.equal(second.journeys.length, 1);
    assert.notEqual(second.journeys[0].id, first.journeys[0].id);
});

test('saved route templates explicitly bypass TfL and cannot persist its forecasts', async () => {
    const fixture = setup({ tube: false });
    fixture.engine.tubeResolver = () => { throw new Error('Stored templates must not query TfL'); };
    const profile = await fixture.engine.savedRoutePlan({ request, version });
    assert.equal(fixture.calls, 1);
    assert.ok(profile.result.journeys.every(journey => journey.legs.every(leg => !leg.localJourney)));
});

test('structural live-replan candidates restore National Rail link allowances and remove TfL forecasts', () => {
    const network = { stations: new Map(stations.map(station => [station.crs, station])), services: [],
        rules: { tsi: [], links: [{ id: 'tube', origin: 'PAD', destination: 'VIC', mode: 'tubeTransfer',
            minutes: 30, startTime: '0000', endTime: '2359' }] } };
    const candidate = scheduledCandidate({ changes: 1, legs: [{ kind: 'transfer', mode: 'tubeTransfer',
        from: stations[0], to: stations[1], departure: iso(NOW), arrival: iso(NOW + 20 * 60000), minutes: 20,
        breakdown: { exitMinutes: 5, travelMinutes: 5, entryMinutes: 5, extraMinutes: 0, contingencyMinutes: 5 },
        localJourney: { status: 'available', steps: [], expiresAt: iso(NOW + 20000) }, warnings: ['Old disruption'] }] }, network);
    assert.ok(candidate);
    assert.equal(candidate.legs[0].localJourney, undefined);
    assert.equal(candidate.legs[0].breakdown.travelMinutes, 30);
    assert.equal(candidate.legs[0].breakdown.contingencyMinutes, undefined);
    assert.equal(candidate.durationMinutes, 40);
    assert.ok(!candidate.legs[0].warnings.includes('Old disruption'));
});
