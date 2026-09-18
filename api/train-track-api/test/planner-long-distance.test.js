import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { openDataset } from '../lib/planner/repository.js';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';
import { decodeCursor, normalizeRequest } from '../lib/planner/contract.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { TubeTrackProvider } from '../lib/planner/tube-provider.js';

const datasetPath = process.env.PLANNER_FULL_DATASET;
const fixtureMetadata = datasetPath ? JSON.parse(await readFile(join(datasetPath, 'metadata.json'), 'utf8')) : null;
// Pin the same source/parser fixture in both supported storage formats.
const VERSION = {
    1: '3d9d573635ed619ac3808338176858077f4d35650846ba0a0e829ed53ad64f5c',
    2: 'e9a2be699c4acf8c72f08a2c7edcf19cc950770ea1c5bd9c2502bd58b2400988'
}[fixtureMetadata?.schemaVersion ?? 1];
const SOURCE_HASH = '75dacf80a357fe5878cead08e8b043671006ea96de29f315c6dad9d5ca440784';
const MINUTE = 60_000;
const DAY = 86_400_000;
const id = (line, date = '2026-09-15') => `${VERSION}:MCA:${line}:${date}`;
const request = { origin: 'KTH', destination: 'INV', time: '2026-09-15T15:10:00+01:00', timeType: 'departAfter' };

// Independently transcribed public times and variant identities from RJTTF939 MCA.
// C04568 is a complete EUS–INV overlay; its EDB dividing associations must not
// manufacture a passenger interchange or replace it with another train portion.
const sleeperId = id(2569729);
const knownLegs = [
    { serviceId: id(560538), from: 'KGX', to: 'EDB', departure: '2026-09-15T15:30:00.000Z', arrival: '2026-09-15T19:36:00.000Z' },
    { serviceId: id(638272), from: 'EDB', to: 'ABD', departure: '2026-09-15T20:29:00.000Z', arrival: '2026-09-15T23:09:00.000Z' },
    { serviceId: id(371315, '2026-09-16'), from: 'ABD', to: 'INV', departure: '2026-09-16T05:14:00.000Z', arrival: '2026-09-16T07:26:00.000Z' }
];
const vehicles = journey => journey.legs.filter(leg => leg.kind === 'vehicle');
const localDate = instant => new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(instant));

test('optional RJTTF939 Clock House earliest arrival stays on the first live page when TfL lookups are exhausted', {
    skip: !datasetPath, timeout: 60_000, concurrency: false
}, async t => {
    const config = plannerConfig({});
    const now = () => Date.parse('2026-09-18T00:28:00Z');
    const provider = new TubeTrackProvider({ now, fetch: () => { throw new Error('No external fixture requests'); } });
    const lookup = provider.lookup.bind(provider);
    let tubeLookups = 0, liveLookups = 0;
    // The deployed search spends its bounded TfL budget before reaching Victoria.
    // Exercise the real fallback adapter with TubeTrack and live routing enabled.
    provider.lookup = query => {
        tubeLookups++;
        return lookup({ ...query, budget: { limit: 0, used: 0 } });
    };
    const engine = new PlannerEngine({ ...config, datasetPath }, { now, tubeProvider: provider,
        liveProvider: {
            async fetchBoards() { liveLookups++; return { boards: [], errors: [] }; },
            async fetchDetails() { return { details: [], errors: [] }; }
        } });
    t.after(() => engine.close());
    const response = await engine.search({ request: normalizeRequest({ origin: 'CLK', destination: 'BRI',
        time: '2026-09-18T01:28:00+01:00', timeType: 'departAfter', realtime: 'apply', limit: 5 }) },
    undefined, { timeoutMs: config.jobTimeoutMs, maxOperations: config.jobMaxOperations });
    assert.equal(response.dataset.version, VERSION);
    assert.ok(tubeLookups > 0);
    assert.ok(liveLookups > 0);
    assert.equal(response.live.mode, 'apply');
    assert.equal(response.journeys.length, 5);
    const journey = response.journeys[0];
    assert.equal(journey.departure, '2026-09-18T03:59:00.000Z');
    assert.equal(journey.arrival, '2026-09-18T07:05:00.000Z');
    assert.equal(journey.durationMinutes, 186);
    assert.deepEqual(journey.legs.filter(leg => leg.mode !== 'interchange')
        .map(leg => [leg.mode, leg.from.crs, leg.to.crs]), [
        ['walk', 'CLK', 'KTH'], ['rail', 'KTH', 'VIC'],
        ['tubeTransfer', 'VIC', 'PAD'], ['rail', 'PAD', 'BRI']
    ]);
    const transfer = journey.legs.find(leg => leg.mode === 'tubeTransfer');
    assert.equal(transfer.localJourney.status, 'unavailable');
    assert.match(transfer.localJourney.notes.join(' '), /National Rail transfer allowance/);
    assert.equal(response.search.searchTruncated, true, 'Unverified TfL coverage must remain visible');
});

function assertSleeper(journey) {
    const leg = vehicles(journey).find(value => value.serviceId === sleeperId);
    assert.ok(leg, 'The independently identified C04568 overlay must be present');
    assert.equal(leg.from.crs, 'EUS');
    assert.equal(leg.to.crs, 'INV');
    assert.equal(leg.operator, 'CS');
    assert.equal(leg.originDate, '2026-09-15');
    assert.equal(leg.departure, '2026-09-15T20:15:00.000Z');
    assert.equal(leg.arrival, '2026-09-16T07:45:00.000Z'); // Advertised 08:45, not working 08:35.
    assert.equal(localDate(leg.arrival), '2026-09-16');
    assert.equal(leg.callingPoints.at(-1).station.crs, 'INV');
    assert.equal(leg.callingPoints.at(-1).arrival, leg.arrival);
    assert.equal(leg.callingPoints.some(call => call.station.crs === 'EDB'), false, 'EDB is an operational split, not an advertised call');
    assert.equal(journey.legs.some(value => [id(2580051, '2026-09-16'), id(2580107, '2026-09-16')].includes(value.serviceId)), false);
    assert.equal(journey.arrival, leg.arrival);
}

function assertFeasible(response, stations, tsi) {
    assert.equal(response.dataset.version, VERSION);
    assert.equal(response.search.searchTruncated, false);
    for (const journey of response.journeys) {
        assert.equal(journey.legs[0].from.crs, response.search.origin);
        assert.equal(journey.legs.at(-1).to.crs, response.search.destination);
        assert.equal(journey.departure, journey.legs[0].departure);
        assert.equal(journey.arrival, journey.legs.at(-1).arrival);
        assert.equal(journey.durationMinutes, (Date.parse(journey.arrival) - Date.parse(journey.departure)) / MINUTE);
        assert.ok(journey.durationMinutes <= 1440);
        assert.ok(journey.changes <= response.search.maxChanges);
        const event = Date.parse(response.search.timeType === 'arriveBy' ? journey.arrival : journey.departure);
        assert.ok(event >= Date.parse(response.search.window.from));
        assert.ok(event <= Date.parse(response.search.window.to));
        if (response.search.window.toInclusive === false) assert.ok(event < Date.parse(response.search.window.to));
        let boardings = 0;
        const usedServices = new Set();
        for (let i = 0; i < journey.legs.length; i++) {
            const leg = journey.legs[i];
            const start = Date.parse(leg.departure), end = Date.parse(leg.arrival);
            assert.ok(end >= start);
            if (i) {
                assert.equal(journey.legs[i - 1].to.crs, leg.from.crs);
                assert.ok(start >= Date.parse(journey.legs[i - 1].arrival));
            }
            if (leg.kind === 'vehicle') {
                boardings++;
                assert.equal(usedServices.has(leg.serviceId), false);
                usedServices.add(leg.serviceId);
                assert.ok(leg.serviceId.startsWith(`${VERSION}:MCA:`));
                assert.equal(leg.callingPoints[0].station.crs, leg.from.crs);
                assert.equal(leg.callingPoints[0].departure, leg.departure);
                assert.equal(leg.callingPoints.at(-1).station.crs, leg.to.crs);
                assert.equal(leg.callingPoints.at(-1).arrival, leg.arrival);
                continue;
            }
            assert.equal(leg.kind, 'transfer');
            const allowance = leg.transfer;
            assert.equal(allowance.extraMinutes, response.search.extraConnectionMinutes);
            if (leg.mode === 'interchange') {
                const before = journey.legs[i - 1], after = journey.legs[i + 1];
                assert.equal(before.kind, 'vehicle');
                assert.equal(after.kind, 'vehicle');
                const overrides = tsi.filter(rule => rule.station === leg.from.crs
                    && rule.arrivingOperator === before.operator && rule.departingOperator === after.operator);
                const minimum = overrides.length ? overrides[0].minutes : stations.get(leg.from.crs).minimumChangeMinutes;
                assert.equal(allowance.interchangeMinutes, minimum);
                assert.equal((end - start) / MINUTE, minimum + allowance.extraMinutes);
                assert.ok(Date.parse(after.departure) - Date.parse(before.arrival) >= (minimum + allowance.extraMinutes) * MINUTE);
            } else {
                if (leg.mode !== 'walk') boardings++;
                assert.equal(allowance.exitMinutes, leg.mode === 'walk' && i === 0 ? 0 : stations.get(leg.from.crs).minimumChangeMinutes);
                assert.equal(allowance.entryMinutes, leg.mode === 'walk' && i === journey.legs.length - 1 ? 0 : stations.get(leg.to.crs).minimumChangeMinutes);
                assert.ok(allowance.travelMinutes > 0);
                assert.ok(allowance.waitingMinutes >= 0);
                assert.equal((end - start) / MINUTE, allowance.exitMinutes + allowance.travelMinutes
                    + allowance.entryMinutes + allowance.extraMinutes + allowance.waitingMinutes);
            }
        }
        assert.equal(journey.changes, Math.max(0, boardings - 1));
    }
}

test('optional RJTTF939 long-distance searches retain real overnight journeys and explicit limits', {
    skip: !datasetPath, timeout: 60_000, concurrency: false
}, async t => {
    const repo = await openDataset(datasetPath);
    let stations, tsi, generationDate;
    try {
        assert.equal(repo.version, VERSION, 'This regression requires the supplied RJTTF939 v3 fixture');
        assert.equal(repo.metadata.source.contentHash, SOURCE_HASH);
        stations = new Map(repo.allStations.map(station => [station.crs, station]));
        tsi = repo.rules.tsi;
        generationDate = repo.metadata.source.generationDate;
    } finally { repo.close(); }
    const config = plannerConfig({});
    // Relax fixture freshness and use the supplied fixed links so this historical
    // oracle stays reproducible without external TfL results. Production freshness
    // tests and all search budgets are unchanged.
    const ageDays = Math.floor((Date.now() - Date.parse(`${generationDate}T00:00:00Z`)) / DAY);
    const service = new PlannerService({ ...config, datasetPath, tubeTrackEnabled: false,
        maxStaleDays: Math.max(config.maxStaleDays, ageDays + 1) });
    t.after(() => service.close());
    let broadSleeper;

    await t.test('Clock House to Bristol includes the earlier arrival via the supplied Kent House walk', async () => {
        const response = await service.search({ origin: 'CLK', destination: 'BRI',
            time: '2026-09-18T00:43:00+01:00', timeType: 'departAfter' });
        assertFeasible(response, stations, tsi);
        const journey = response.journeys[0];
        assert.equal(journey.departure, '2026-09-18T03:59:00.000Z');
        assert.equal(journey.arrival, '2026-09-18T07:05:00.000Z');
        assert.equal(journey.durationMinutes, 186);
        const walk = journey.legs[0];
        assert.equal(walk.mode, 'walk');
        assert.equal(walk.from.crs, 'CLK');
        assert.equal(walk.to.crs, 'KTH');
        assert.deepEqual(walk.transfer, { exitMinutes: 0, travelMinutes: 9, entryMinutes: 4, extraMinutes: 0, waitingMinutes: 0 });
        assert.deepEqual(vehicles(journey).map(leg => [leg.from.crs, leg.to.crs]), [['KTH', 'VIC'], ['PAD', 'BRI']]);
    });

    await t.test('defaults find legitimate overnight arrivals', async () => {
        const response = await service.search(request);
        assert.equal(response.search.maxChanges, 5);
        assert.equal(response.search.windowMinutes, 360);
        assert.ok(response.journeys.length > 0);
        assertFeasible(response, stations, tsi);
        const daytime = response.journeys.find(journey => journey.arrival === '2026-09-16T07:26:00.000Z');
        assert.ok(daytime, 'The supported Edinburgh/Aberdeen overnight connection should be found');
        for (const expected of knownLegs) {
            const leg = vehicles(daytime).find(value => value.serviceId === expected.serviceId);
            assert.ok(leg, `Missing independently identified service ${expected.serviceId}`);
            assert.equal(leg.departure, expected.departure);
            assert.equal(leg.arrival, expected.arrival);
            assert.equal(leg.from.crs, expected.from);
            assert.equal(leg.to.crs, expected.to);
        }
        assert.equal(vehicles(daytime).at(-1).originDate, '2026-09-16');
        const edinburgh = daytime.legs.find(leg => leg.kind === 'transfer' && leg.from.crs === 'EDB');
        const aberdeen = daytime.legs.find(leg => leg.kind === 'transfer' && leg.from.crs === 'ABD');
        assert.equal(edinburgh.transfer.interchangeMinutes, 10); // MSN line 1034.
        assert.equal(aberdeen.transfer.interchangeMinutes, 5); // MSN line 14.
    });

    await t.test('explicit two changes find the through sleeper with the later feeder', async () => {
        const response = await service.search({ ...request, maxChanges: 2, windowMinutes: 360 });
        assert.equal(response.search.maxChanges, 2);
        assertFeasible(response, stations, tsi);
        broadSleeper = response.journeys.find(journey => vehicles(journey).some(leg => leg.serviceId === sleeperId));
        assert.ok(broadSleeper);
        assertSleeper(broadSleeper);
        assert.equal(broadSleeper.departure, '2026-09-15T18:57:00.000Z');
        const transfer = broadSleeper.legs.find(leg => leg.kind === 'transfer');
        assert.equal(transfer.from.crs, 'VIC');
        assert.equal(transfer.to.crs, 'EUS');
        assert.deepEqual(transfer.transfer, { exitMinutes: 15, travelMinutes: 14, entryMinutes: 15, extraMinutes: 0, waitingMinutes: 0 });
        const detail = await service.journey(broadSleeper.id);
        assert.deepEqual(detail.journey, broadSleeper);
        assert.equal(detail.dataset.version, VERSION);
        assertSleeper(detail.journey);
    });

    await t.test('16:00 and 16:05 searches complete within normal budgets and retain the sleeper', async () => {
        // These adjacent queries previously exceeded the work budget even though
        // the 15:10 query passed. Reuse one worker while keeping exact search keys.
        for (const time of ['2026-09-15T16:00:00+01:00', '2026-09-15T16:05:00+01:00']) {
            const response = await service.search({ ...request, time });
            assert.equal(response.search.maxChanges, 5);
            assert.equal(response.search.windowMinutes, 360);
            assert.equal(response.search.time, new Date(time).toISOString());
            assertFeasible(response, stations, tsi);
            const journey = response.journeys.find(value => vehicles(value).some(leg => leg.serviceId === sleeperId));
            assert.ok(journey, `The supported sleeper should be found after ${time}`);
            assertSleeper(journey);
            assert.ok(Date.parse(journey.departure) >= Date.parse(time));
            const detail = await service.journey(journey.id);
            assert.deepEqual(detail.journey, journey);
        }
    });

    await t.test('a narrow explicit window retains an earlier feeder and exact pagination', async () => {
        const response = await service.search({ ...request, maxChanges: 2, windowMinutes: 120 });
        assert.equal(response.search.maxChanges, 2);
        assert.equal(response.search.windowMinutes, 120);
        assertFeasible(response, stations, tsi);
        const journey = response.journeys.find(value => vehicles(value).some(leg => leg.serviceId === sleeperId));
        assert.ok(journey);
        assertSleeper(journey);
        assert.equal(journey.departure, '2026-09-15T15:59:00.000Z');
        assert.ok(Date.parse(journey.departure) < Date.parse(broadSleeper.departure));
        assert.equal(journey.arrival, broadSleeper.arrival);
        assert.equal(journey.legs.find(leg => leg.kind === 'transfer').transfer.travelMinutes, 9);
        for (const [direction, time] of [['earlier', '2026-09-15T12:10:00.000Z'], ['later', '2026-09-15T16:10:00.000Z']]) {
            const cursor = decodeCursor(response.pagination[direction]);
            assert.equal(cursor.version, VERSION);
            assert.equal(cursor.request.time, time);
            assert.equal(cursor.request.maxChanges, 2);
            assert.equal(cursor.request.windowMinutes, 120);
        }
    });

    await t.test('arrive-by finds paths from the previous day and preserves details', async () => {
        const response = await service.search({ ...request, timeType: 'arriveBy', time: '2026-09-16T09:00:00+01:00' });
        assert.ok(response.journeys.length > 0);
        assertFeasible(response, stations, tsi);
        const overnight = response.journeys.find(journey => localDate(journey.departure) === '2026-09-15' && localDate(journey.arrival) === '2026-09-16');
        assert.ok(overnight);
        assert.ok(Date.parse(overnight.arrival) <= Date.parse('2026-09-16T08:00:00Z'));
        const detail = await service.journey(overnight.id);
        assert.deepEqual(detail.journey, overnight);
        if (vehicles(overnight).some(leg => leg.serviceId === sleeperId)) assertSleeper(detail.journey);
    });

    await t.test('East Croydon to Burnley arrive-by searches avoid repeated national preprocessing', async () => {
        // These searches previously rebuilt 159 national reachability envelopes
        // for 40 completion horizons, consuming most of the request deadline.
        for (const date of ['2026-09-16', '2026-09-17']) {
            const response = await service.search({ origin: 'ECR', destination: 'BYM',
                time: `${date}T18:09:00+01:00`, timeType: 'arriveBy' });
            assert.equal(response.search.maxChanges, 5);
            assert.equal(response.search.windowMinutes, 360);
            assertFeasible(response, stations, tsi);
            assert.equal(response.journeys.length, 5);
            const latest = response.journeys[0];
            assert.equal(latest.departure, `${date}T12:45:00.000Z`);
            assert.equal(latest.arrival, `${date}T17:02:00.000Z`);
            assert.equal(latest.changes, 2);
            assert.deepEqual(vehicles(latest).map(leg => [leg.from.crs, leg.to.crs]),
                [['ECR', 'SVG'], ['SVG', 'LDS'], ['LDS', 'BYM']]);
            const detail = await service.journey(latest.id);
            assert.deepEqual(detail.journey, latest);
            const next = decodeCursor(response.pagination.more);
            assert.equal(next.version, VERSION);
            assert.equal(next.request.time, `${date}T17:09:00.000Z`);
            assert.equal(next.offset, 5);
        }
    });

});
