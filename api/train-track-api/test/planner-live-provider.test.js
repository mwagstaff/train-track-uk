import assert from 'node:assert/strict';
import test from 'node:test';
import { PlannerLiveProvider, createLiveRequestBudget, staffBoardKey } from '../lib/planner/live-provider.js';

const now = Date.parse('2026-09-16T12:00:00Z');
const credentials = () => ({ board: 'test-board', details: 'test-details' });
const board = (crs = 'ECR') => ({ crs, generatedAt: '2026-09-16T12:59:50+01:00', trainServices: [{
  serviceID: 'opaque/station+id', rsid: 'SN123400', operatorCode: 'SN', std: '12:45', etd: '13:10',
  isCancelled: false, futureCancellation: true, currentDestinations: [{ crs: 'BTN' }], platform: '2', length: 8
}] });
const details = (crs = 'ECR') => ({ crs, generatedAt: '2026-09-16T11:59:55Z', std: '12:45', etd: 'Delayed',
  operatorCode: 'SN', isCancelled: true,
  previousCallingPoints: [{ callingPoint: [{ crs: 'VIC', st: '12:20', at: '12:40' }] }],
  subsequentCallingPoints: [
    { callingPoint: [{ crs: 'GTW', st: '13:00', et: '13:25', isCancelled: true }, { crs: 'BTN', st: '13:40', et: 'Delayed' }] },
    { serviceChangeRequired: false, assocIsCancelled: true, callingPoint: [{ crs: 'LIT', st: '14:10', et: 'Cancelled' }] }
  ]
});

test('overlapping searches share a live lookup and one caller cancelling does not cancel the other', async () => {
  let release, count = 0, upstreamSignal;
  const provider = new PlannerLiveProvider({ credentials, now: () => now, request: async ({ signal }) => {
    count++; upstreamSignal = signal;
    await new Promise(resolve => { release = resolve; });
    return { data: board() };
  } });
  const controller = new AbortController();
  const budget = createLiveRequestBudget(1);
  const first = provider.fetchBoards(['ECR'], { offsets: [0], signal: controller.signal, budget });
  const second = provider.fetchBoards(['ECR'], { offsets: [0], budget: createLiveRequestBudget(0) });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(count, 1);
  controller.abort();
  await assert.rejects(first, { code: 'SEARCH_CANCELLED' });
  assert.equal(upstreamSignal.aborted, false);
  release();
  const result = await second;
  assert.equal(result.boards.length, 1);
  assert.equal(result.requestCount, 0);
  assert.equal(result.limited, false);
  assert.equal(budget.used, 1);
  assert.equal(provider.inflight.size, 0);
});

test('shared observations are independent copies and failures are retried rather than cached', async () => {
  let calls = 0;
  const provider = new PlannerLiveProvider({ credentials, now: () => now, request: async () => {
    calls++;
    await new Promise(resolve => setImmediate(resolve));
    if (calls === 1) throw Object.assign(new Error('Unavailable'), { response: { status: 503 } });
    return { data: board() };
  } });
  const options = { offsets: [0] };
  const failed = await Promise.all([provider.fetchBoards(['ECR'], options), provider.fetchBoards(['ECR'], options)]);
  assert.ok(failed.every(value => value.errors[0].reason === 'upstream'));
  assert.equal(calls, 1);
  const [one, two] = await Promise.all([provider.fetchBoards(['ECR'], options), provider.fetchBoards(['ECR'], options)]);
  assert.equal(calls, 2);
  one.boards[0].services[0].platform = 'changed';
  assert.equal(two.boards[0].services[0].platform, '2');
});

test('raw boards explicitly request unfiltered bounded past/current/future windows and retain live identity', async () => {
  const requests = [];
  const provider = new PlannerLiveProvider({ credentials, now: () => now, request: async request => {
    requests.push(request); return { data: board() };
  } });
  const result = await provider.fetchBoards(['ecr', 'ECR']);
  assert.equal(result.requestCount, 3);
  assert.equal(result.boards.length, 3);
  assert.deepEqual(requests.map(value => Number(new URL(value.url).searchParams.get('timeOffset'))).sort((a, b) => a - b), [-119, 0, 118]);
  for (const request of requests) {
    const url = new URL(request.url);
    assert.equal(url.searchParams.get('numRows'), '149');
    assert.equal(url.searchParams.get('timeWindow'), '119');
    assert.equal(url.searchParams.has('filterCrs'), false);
    assert.equal(request.timeoutMs, 3000);
    assert.equal(request.maxRetries, 0);
    assert.ok(request.signal instanceof AbortSignal);
  }
  const observation = result.boards[0];
  assert.equal(observation.generatedAt, '2026-09-16T11:59:50.000Z');
  assert.equal(observation.fetchedAt, new Date(now).toISOString());
  assert.equal(observation.services[0].operatorCode, 'SN');
  assert.equal(observation.services[0].rsid, 'SN123400');
  assert.equal(observation.services[0].futureCancellation, true);
  assert.deepEqual(observation.services[0].currentDestinations, [{ crs: 'BTN' }]);
  assert.equal(observation.services[0].uid, undefined);
  assert.equal(observation.services[0].originDate, undefined);
  assert.equal(observation.services[0].std, '12:45');
  assert.equal(observation.services[0].platform, '2');
  assert.equal(observation.services[0].length, 8);
});

test('details preserve through and branch groups and call-specific cancellations without merging', async () => {
  let url;
  const provider = new PlannerLiveProvider({ credentials, now: () => now, request: async request => {
    url = request.url; return { data: details() };
  } });
  const result = await provider.fetchDetails([{ serviceID: 'opaque/station+id', station: 'ECR' }]);
  assert.ok(url.endsWith('opaque%2Fstation%2Bid'));
  assert.equal(result.details[0].detail.std, '12:45');
  assert.equal(result.details[0].detail.etd, 'Delayed');
  assert.deepEqual(result.details[0].detail.subsequentCallingPoints, details().subsequentCallingPoints);
  assert.equal(result.details[0].detail.isCancelled, true);
  assert.equal(result.details[0].cancelledService, undefined);
});

test('one budget bounds all discovery rounds and details while cached observations cost no requests', async () => {
  const provider = new PlannerLiveProvider({ credentials, now: () => now, request: async ({ url }) => ({ data: url.includes('GetDepartureBoard') ? board() : details() }) });
  const budget = createLiveRequestBudget(4);
  assert.equal((await provider.fetchBoards(['ECR'], { budget })).requestCount, 3);
  assert.equal((await provider.fetchDetails([{ serviceID: 'a', station: 'ECR' }, { serviceID: 'b', station: 'ECR' }], { budget })).limited, true);
  assert.equal(budget.used, 4);
  assert.equal((await provider.fetchBoards(['ECR'], { budget })).requestCount, 0);
  assert.equal((await provider.fetchBoards(['VIC'], { budget })).errors.length, 3);
});

test('cache is bounded, immutable to consumers, expires after 30 seconds and preserves provider observation age', async () => {
  let clock = now, requests = 0;
  const provider = new PlannerLiveProvider({ credentials, now: () => clock, request: async () => { requests++; return { data: board() }; } });
  const first = await provider.fetchBoards(['ECR'], { offsets: [0] });
  first.boards[0].services[0].etd = '00:00';
  clock += 29_999;
  const cached = await provider.fetchBoards(['ECR'], { offsets: [0] });
  assert.equal(cached.boards[0].services[0].etd, '13:10');
  assert.equal(cached.boards[0].fetchedAt, new Date(now).toISOString());
  assert.equal(requests, 1);
  clock++;
  await provider.fetchBoards(['ECR'], { offsets: [0] });
  assert.equal(requests, 2);
  for (let i = 0; i < 257; i++) provider.remember(`test:${i}`, { i }, clock);
  assert.equal(provider.cache.size, 256);
  assert.equal(provider.cached('test:0', clock), null);
});

test('parallel batches share the two-request concurrency limit', async () => {
  let active = 0, peak = 0;
  const provider = new PlannerLiveProvider({ credentials, request: async ({ url }) => {
    peak = Math.max(peak, ++active);
    await new Promise(resolve => setTimeout(resolve, 5));
    active--;
    return { data: url.includes('GetDepartureBoard') ? board() : details() };
  } });
  await Promise.all([
    provider.fetchBoards(['ECR']),
    provider.fetchDetails([{ serviceID: 'one', station: 'ECR' }, { serviceID: 'two', station: 'ECR' }])
  ]);
  assert.equal(peak, 2);
  assert.equal(provider.active, 0);
  assert.equal(provider.queue.length, 0);
});

test('missing credentials return immediately without upstream requests or budget consumption', async () => {
  const provider = new PlannerLiveProvider({ credentials: () => ({}), request: () => assert.fail('Unexpected request') });
  const budget = createLiveRequestBudget();
  const result = await provider.fetchBoards(['ECR'], { budget });
  assert.equal(result.boards.length, 0);
  assert.ok(result.errors.every(value => value.reason === 'credentialsUnavailable'));
  assert.equal(budget.used, 0);
});

test('caller cancellation reaches active and queued requests without becoming missing live coverage', async () => {
  const controller = new AbortController();
  const provider = new PlannerLiveProvider({ credentials, request: async ({ signal }) => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => reject(signal.reason), { once: true });
  }) });
  const first = provider.fetchBoards(['ECR'], { signal: controller.signal });
  const second = provider.fetchDetails([{ serviceID: 'one', station: 'ECR' }], { signal: controller.signal });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(provider.active, 2);
  assert.equal(provider.queue.length, 1);
  controller.abort();
  const results = await Promise.allSettled([first, second]);
  assert.ok(results.every(result => result.status === 'rejected' && result.reason.code === 'SEARCH_CANCELLED'));
  assert.equal(provider.active, 0);
  assert.equal(provider.queue.length, 0);
});

test('failure types remain explicit and malformed or missing details cannot enter cache', async () => {
  for (const [raw, reason] of [[null, 'unavailable'], [{ crs: 'VIC' }, 'malformed'], [{ ...details(), subsequentCallingPoints: {} }, 'malformed']]) {
    const provider = new PlannerLiveProvider({ credentials, request: async () => ({ data: raw }) });
    const result = await provider.fetchDetails([{ serviceID: 'one', station: 'ECR' }]);
    assert.equal(result.errors[0].reason, reason);
    assert.equal(provider.cache.size, 0);
  }
  for (const [status, reason] of [[429, 'rateLimited'], [401, 'authentication'], [500, 'upstream']]) {
    const provider = new PlannerLiveProvider({ credentials, request: async () => { throw { response: { status } }; } });
    const result = await provider.fetchBoards(['ECR'], { offsets: [0] });
    assert.equal(result.errors[0].reason, reason);
  }
});

test('unknown or stale observation times and suppressed/truncated boards remain explicit', async () => {
  const raw = { ...board(), generatedAt: '13:00', areServicesAvailable: false, trainServices: Array(149).fill(board().trainServices[0]) };
  const provider = new PlannerLiveProvider({ credentials, request: async () => ({ data: raw }) });
  const result = await provider.fetchBoards(['ECR'], { offsets: [0] });
  assert.equal(result.boards[0].generatedAt, null);
  assert.equal(result.boards[0].areServicesAvailable, false);
  assert.equal(result.boards[0].possiblyTruncated, true);
});

const staffBoard = () => ({ crs: 'VIC', generatedAt: '2026-09-16T12:59:50+01:00', trainServices: [{
  uid: 'G26231', rid: '202609167126231', sdd: '2026-09-16', operatorCode: 'SN',
  std: '2026-09-16T13:05:00', stdSpecified: true, etd: '2026-09-16T13:07:00',
  departureType: 'Forecast', etdSpecified: true,
  subsequentLocations: [{ crs: 'ECR', sta: '2026-09-16T13:23:00', staSpecified: true,
    eta: '2026-09-16T13:25:00', etaSpecified: true, arrivalType: 'Forecast', isCancelled: false }]
}] });

test('staff recovery requests a bounded dated board with its separate key and preserves full forecast fields', async () => {
  const requests = [];
  const provider = new PlannerLiveProvider({ credentials: () => ({ ...credentials(), staff: 'test-staff' }), now: () => now,
    request: async request => { requests.push(request); return { data: staffBoard() }; } });
  const target = { station: 'VIC', departure: Date.parse('2026-09-16T12:05:00Z') };
  assert.equal(provider.supportsStaffRecovery(), true);
  const budget = createLiveRequestBudget(1);
  const first = await provider.fetchStaffBoards([target, { ...target, departure: target.departure + 30_000 }], { budget });
  assert.equal(first.requestCount, 1);
  assert.equal(budget.used, 1);
  const url = new URL(requests[0].url);
  assert.ok(url.pathname.endsWith('/GetDepBoardWithDetails/VIC/20260916T130500'));
  assert.deepEqual(Object.fromEntries(url.searchParams), { numRows: '9', timeWindow: '2', services: 'P' });
  assert.equal(requests[0].headers['x-apikey'], 'test-staff');
  assert.equal(requests[0].timeoutMs, 3000);
  assert.equal(requests[0].maxRetries, 0);
  assert.deepEqual(first.boards[0].services, staffBoard().trainServices);
  assert.equal(first.boards[0].generatedAt, '2026-09-16T11:59:50.000Z');
  first.boards[0].services[0].subsequentLocations[0].eta = 'changed';
  const cached = await provider.fetchStaffBoards([target], { budget });
  assert.equal(cached.requestCount, 0);
  assert.equal(cached.boards[0].services[0].subsequentLocations[0].eta, '2026-09-16T13:25:00');
  const blocked = await provider.fetchStaffBoards([{ ...target, departure: target.departure + 60_000 }], { budget });
  assert.equal(blocked.limited, true);
  assert.equal(blocked.errors[0].reason, 'requestLimit');
  assert.equal(blocked.errors[0].source, 'staff');
});

test('staff recovery is optional, validates targets and cannot expose suppressed or malformed boards', async () => {
  const target = { station: 'VIC', departure: now };
  const absent = new PlannerLiveProvider({ credentials, request: () => assert.fail('No staff entitlement') });
  assert.equal(absent.supportsStaffRecovery(), false);
  assert.equal((await absent.fetchStaffBoards([target])).errors[0].reason, 'credentialsUnavailable');
  for (const invalid of [{ ...target, station: 'VIC/other' }, { ...target, departure: NaN }, { ...target, departure: 1e99 }]) {
    await assert.rejects(absent.fetchStaffBoards([invalid]), /Invalid staff board reference/);
  }
  assert.equal(staffBoardKey({ station: 'VIC', departure: Date.parse('2026-12-16T13:05:00Z') }), 'VIC:20261216T130500');
  for (const raw of [{ ...staffBoard(), crs: 'ECR' }, { ...staffBoard(), trainServices: {} },
    { ...staffBoard(), trainServices: [{ subsequentLocations: {} }] },
    { ...staffBoard(), trainServices: [{ subsequentLocations: [null] }] }]) {
    const provider = new PlannerLiveProvider({ credentials: () => ({ staff: 'test-staff' }), request: async () => ({ data: raw }) });
    assert.equal((await provider.fetchStaffBoards([target])).errors[0].reason, 'malformed');
    assert.equal(provider.cache.size, 0);
  }
  const provider = new PlannerLiveProvider({ credentials: () => ({ staff: 'test-staff' }), request: async () => ({
    data: { ...staffBoard(), servicesAreUnavailable: true }
  }) });
  assert.deepEqual((await provider.fetchStaffBoards([target])).boards[0].services, []);
  const hidden = new PlannerLiveProvider({ credentials: () => ({ staff: 'test-staff' }), request: async () => ({
    data: { ...staffBoard(), platformsAreHidden: true }
  }) });
  assert.equal((await hidden.fetchStaffBoards([target])).boards[0].services[0].platformIsHidden, true);
});

test('public and staff recovery share concurrency, cancellation and budget limits', async () => {
  const controller = new AbortController();
  const provider = new PlannerLiveProvider({ credentials: () => ({ ...credentials(), staff: 'test-staff' }),
    request: async ({ signal }) => new Promise((resolve, reject) => {
      signal.addEventListener('abort', () => reject(signal.reason), { once: true });
    }) });
  const budget = createLiveRequestBudget(4);
  const publicBoards = provider.fetchBoards(['ECR'], { signal: controller.signal, budget });
  const recovery = provider.fetchStaffBoards([{ station: 'VIC', departure: now }], { signal: controller.signal, budget });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(provider.active, 2);
  assert.equal(provider.queue.length, 1);
  controller.abort();
  const results = await Promise.allSettled([publicBoards, recovery]);
  assert.ok(results.every(result => result.status === 'rejected' && result.reason.code === 'SEARCH_CANCELLED'));
  assert.equal(provider.active, 0);
  assert.equal(provider.queue.length, 0);
  assert.ok(budget.used <= 4);
});
