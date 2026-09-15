import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import axios from 'axios';
import {
    boardObservation,
    departureObservation,
    qualifySiriResult,
    waitForSiriResult
} from '../lib/siri-departure-policy.js';
import { formatDepartureJourneyResult } from '../lib/departure-response.js';

// Exercise the real cache/parser path without contacting the railway feed or Mongo.
let upstream;
const createClient = mock.method(axios, 'create', () => ({
    get: (...args) => upstream(...args)
}));
const { getTrainTimes, mergeJourneyDepartureResponses, parseResponseDataLiveDepartureBoard } = await import('../lib/realtime-trains-api.js');
createClient.mock.restore();

const observedAt = '2026-09-15T11:00:00.000Z';

function board({ generatedAt = new Date().toISOString(), platform = '2', actual, serviceID = 'service-1' } = {}) {
    return {
        generatedAt,
        trainServices: [{
            std: '12:02', etd: '12:03', ...(actual ? { atd: actual } : {}),
            serviceType: 'train', platform, serviceID, isCancelled: false,
            origin: [{ crs: 'AAA', locationName: 'Origin' }],
            destination: [{ crs: 'CCC', locationName: 'Final destination' }]
        }]
    };
}

test('board metadata preserves provider time, actual departure and source offset without inventing dates or coverage', async () => {
    const result = await parseResponseDataLiveDepartureBoard(board({ generatedAt: observedAt, actual: '12:03' }), {
        requestedOffsetMinutes: 119,
        fetchedAt: '2026-09-15T11:00:04Z'
    });
    assert.equal(result.siri.providerObservedAt, observedAt);
    assert.equal(result.siri.fetchedAt, '2026-09-15T11:00:04.000Z');
    assert.equal(result.siri.searchWindowMinutes, null);
    assert.equal(result.siri.complete, false);
    assert.equal(result.departures[0].departure_time.actual, '12:03');
    assert.deepEqual(result.departures[0].siri, {
        providerObservedAt: observedAt,
        requestedOffsetMinutes: 119,
        platformSource: 'reported',
        platformObservedAt: observedAt
    });
    assert.equal(result.departures[0].operatingDate, undefined);
    assert.equal(result.departures[0].scheduledDepartureAt, undefined);
});

test('new HTTP fetch time cannot freshen an old, unknown or future provider observation', () => {
    const now = Date.parse('2026-09-15T11:02:00Z');
    const result = {
        departures: [], dataStatus: 'live',
        siri: boardObservation({ generatedAt: observedAt }, 0, '2026-09-15T11:02:00Z')
    };
    assert.equal(qualifySiriResult(result, now).siri.failureReason, 'stale');
    assert.equal(qualifySiriResult(result, now).dataStatus, 'stale');
    result.siri.providerObservedAt = null;
    assert.equal(qualifySiriResult(result, now).siri.failureReason, 'unknownFreshness');
    result.siri.providerObservedAt = '2026-09-15T11:03:00Z';
    assert.equal(qualifySiriResult(result, now).siri.failureReason, 'stale');
});

test('oldest successful board observation governs freshness and partial coverage stays explicit', () => {
    const current = { departures: [], siri: boardObservation({ generatedAt: observedAt }, 0, observedAt) };
    const old = { departures: [], siri: boardObservation({ generatedAt: '2026-09-15T10:58:00Z' }, 119, observedAt) };
    const merged = mergeJourneyDepartureResponses(current, old, observedAt);
    assert.equal(merged.siri.providerObservedAt, '2026-09-15T10:58:00.000Z');
    assert.equal(qualifySiriResult(merged, Date.parse(observedAt)).siri.failureReason, 'stale');
    const partial = mergeJourneyDepartureResponses(current, { error: 'failed', failureReason: 'rateLimited' }, observedAt);
    assert.equal(partial.dataStatus, 'partial');
    assert.equal(partial.siri.complete, false);
    assert.equal(partial.siri.providerObservedAt, observedAt);
});

test('platform observations do not claim an announcement without a valid provider time', () => {
    const unknown = boardObservation({}, 0, observedAt);
    assert.equal(departureObservation({ platform: '2' }, unknown).platformObservedAt, null);
    assert.equal(departureObservation({ platform: 'TBC' }, unknown).platformSource, 'unknown');
    assert.equal(departureObservation({}, unknown).platformSource, 'unknown');
});

test('the provider bus collection identifies replacement transport even without a serviceType field', async () => {
    const result = await parseResponseDataLiveDepartureBoard({
        generatedAt: observedAt,
        busServices: [{ std: '12:02', etd: 'On time', serviceID: 'bus-1', destination: [{ locationName: 'Destination' }] }]
    });
    assert.equal(result.departures[0].serviceType, 'bus');
});

test('fresh reads share in-flight upstream work, reuse a fresh snapshot and preserve legacy envelopes', async () => {
    let calls = 0;
    upstream = async () => { calls += 1; return { data: board(), status: 200 }; };
    const [first, concurrent] = await Promise.all([
        getTrainTimes('FRA', 'FRB', { requireFresh: true }),
        getTrainTimes('FRA', 'FRB', { requireFresh: true })
    ]);
    assert.equal(calls, 2); // Existing now/future board requests, shared by both callers.
    assert.equal(first.siri.failureReason, null);
    assert.deepEqual(first, concurrent);
    const cached = await getTrainTimes('FRA', 'FRB', { requireFresh: true });
    assert.equal(calls, 2);
    assert.equal(cached.siri.fetchedAt, first.siri.fetchedAt);
    const legacy = await getTrainTimes('FRA', 'FRB');
    assert.equal(legacy.siri, undefined);
    assert.equal(legacy.departures[0].siri, undefined);
    assert.deepEqual(formatDepartureJourneyResult('FRA_FRB', legacy, false), { FRA_FRB: legacy.departures });
    assert.equal(formatDepartureJourneyResult('FRA_FRB', first, true).FRA_FRB.siri.providerObservedAt, first.siri.providerObservedAt);
});

test('a stale provider response is rejected even though the server just refreshed it', async () => {
    let calls = 0;
    upstream = async () => {
        calls += 1;
        return { data: board({ generatedAt: new Date(Date.now() - 61_000).toISOString() }), status: 200 };
    };
    const first = await getTrainTimes('STA', 'STB', { requireFresh: true });
    assert.equal(first.dataStatus, 'stale');
    assert.equal(first.siri.failureReason, 'stale');
    await getTrainTimes('STA', 'STB', { requireFresh: true });
    assert.equal(calls, 4); // An unacceptable cached observation is not returned as fresh.
});

test('platform fallback retains its original provenance and observation time', async () => {
    // Put the service inside the established platform-retention window.
    const departureTime = new Intl.DateTimeFormat('en-GB', {
        hour: '2-digit', minute: '2-digit', hourCycle: 'h23'
    }).format(new Date());
    const firstObservation = new Date(Date.now() - 61_000).toISOString();
    let announced = true;
    upstream = async () => {
        const response = board({ generatedAt: firstObservation, platform: announced ? '2' : undefined });
        if (!announced) delete response.trainServices[0].platform;
        response.trainServices[0].std = departureTime;
        return { data: response, status: 200 };
    };
    await getTrainTimes('PLA', 'PLB', { requireFresh: true });
    announced = false;
    const refreshed = await getTrainTimes('PLA', 'PLB', { requireFresh: true });
    assert.equal(refreshed.departures[0].platform, '2');
    assert.equal(refreshed.departures[0].siri.platformSource, 'retained');
    assert.equal(refreshed.departures[0].siri.platformObservedAt, firstObservation);
});

test('fresh upstream requests disable retries and propagate typed throttling failure', async () => {
    let calls = 0;
    upstream = async (_url, options) => {
        calls += 1;
        assert.ok(options.timeout <= 7_500);
        assert.ok(options.signal);
        throw Object.assign(new Error('throttled'), { response: { status: 429 } });
    };
    const result = await getTrainTimes('RTA', 'RTB', { requireFresh: true });
    assert.equal(calls, 2);
    assert.equal(result.dataStatus, 'unavailable');
    assert.equal(result.siri.failureReason, 'rateLimited');
});

test('timeout and cancellation stop individual waiters without cancelling shared work', async () => {
    const controller = new AbortController();
    let complete;
    const shared = new Promise((resolve) => { complete = resolve; });
    const cancelled = waitForSiriResult(shared, { signal: controller.signal });
    const other = waitForSiriResult(shared);
    controller.abort();
    assert.equal((await cancelled).siri.failureReason, 'cancelled');
    const timestamp = new Date().toISOString();
    complete({ departures: [], dataStatus: 'live', siri: boardObservation({ generatedAt: timestamp }, 0, timestamp) });
    assert.equal((await other).siri.failureReason, null);
    const timeout = await waitForSiriResult(new Promise(() => {}), { timeoutMs: 5 });
    assert.equal(timeout.siri.failureReason, 'timeout');
});

test('a cold fresh lookup aborts its upstream work at the overall deadline', async () => {
    let aborted = 0;
    upstream = async (_url, { signal }) => new Promise((_resolve, reject) => {
        signal.addEventListener('abort', () => {
            aborted += 1;
            reject(Object.assign(new Error('cancelled'), { code: 'ERR_CANCELED' }));
        }, { once: true });
    });
    const startedAt = Date.now();
    const result = await getTrainTimes('TMA', 'TMB', { requireFresh: true });
    assert.equal(result.siri.failureReason, 'timeout');
    assert.equal(result.dataStatus, 'unavailable');
    assert.equal(aborted, 2);
    assert.ok(Date.now() - startedAt < 8_500);
});
