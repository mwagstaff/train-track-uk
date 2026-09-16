import test from 'node:test';
import assert from 'node:assert/strict';
import { PlannerEngine } from '../lib/planner/engine.js';
import { PlannerService, plannerConfig } from '../lib/planner/service.js';
import { normalizeRequest, decodeCursor } from '../lib/planner/contract.js';
import { createLiveRequestBudget } from '../lib/planner/live-provider.js';
import { findJourneys } from '../lib/planner/router.js';

const VERSION = 'c'.repeat(64);
const DATE = '2026-09-16';
const at = clock => Date.parse(`${DATE}T${clock}:00+01:00`);
const iso = clock => new Date(at(clock)).toISOString();
const localClock = timestamp => new Date(timestamp + 3600000).toISOString().slice(11, 16);
const request = changes => normalizeRequest({ origin: 'ORG', destination: 'DST', time: iso('12:00'),
  timeType: 'departAfter', windowMinutes: 120, realtime: 'apply', ...changes });
const config = { ...plannerConfig({}), datasetPath: '/synthetic/live-fixture', timeoutMs: 5000 };

function train(uid, stops) {
  return { id: `fixture:${uid}:${DATE}`, uid, variantId: uid, originDate: DATE, operator: 'SE', mode: 'rail',
    calls: stops.map(([station, arrival, departure], sequence) => ({ station, sequence, tiploc: station,
      arrival: arrival ? at(arrival) : null, departure: departure ? at(departure) : null,
      canBoard: Boolean(departure), canAlight: Boolean(arrival) })) };
}
const direct = (uid, departure, arrival) => train(uid, [['ORG', null, departure], ['DST', arrival, null]]);

/** The real engine and router consume this small date-resolved repository.
 * Only the external provider and storage opening are replaced; all route
 * feasibility, overlays, pagination and public presentation execute normally.
 */
function fixture(t, services, updates = {}) {
  let clock = at('12:00');
  const calls = { boards: [], details: [] };
  const state = { updates, unavailable: false, onBoards: null };
  const stations = ['ORG', 'MID', 'DST', 'ALT'].map(crs => ({ crs, name: crs, aliases: [], minimumChangeMinutes: 5 }));
  const repo = {
    version: VERSION, stations, allStations: stations, rules: { tsi: [], links: [] },
    metadata: { source: { generationDate: '2026-09-01' }, importedAt: '2026-09-01T12:00:00Z', maxEventDayOffset: 0,
      coverage: { startDate: '2026-09-01', endDate: '2026-09-30', basis: 'Integration fixture' }, limitations: [] },
    resolveServices: date => ({ services: date === DATE ? services : [], diagnostics: { counts: {} } }), close() {}
  };
  const observation = (service, call) => state.updates[service.uid]?.[call.station] ?? {};
  const generatedAt = () => state.generatedAt === undefined ? new Date(clock).toISOString() : state.generatedAt;
  const serviceID = (service, station) => `live:${service.uid}:${station}`;
  const provider = {
    async fetchBoards(stationCodes, options) {
      calls.boards.push({ stations: [...stationCodes], options });
      await state.onBoards?.(options);
      if (state.unavailable) return { boards: [], errors: [{ reason: 'connectivity' }], requestCount: stationCodes.length, limited: false };
      return { boards: stationCodes.map(station => ({ station, generatedAt: generatedAt(), fetchedAt: new Date(clock).toISOString(),
        window: { offsetMinutes: -119, windowMinutes: 119, numRows: 149 }, areServicesAvailable: true,
        services: services.flatMap(service => service.calls.filter(call => call.station === station && call.canBoard).map(call => ({
          serviceID: serviceID(service, station), serviceType: 'train', operatorCode: service.operator,
          origin: [{ crs: service.calls[0].station }], destination: [{ crs: service.calls.at(-1).station }],
          std: localClock(call.departure), etd: observation(service, call).etd ?? 'On time',
          isCancelled: observation(service, call).isCancelled ?? false,
          ...(call.arrival ? { sta: localClock(call.arrival), eta: observation(service, call).eta ?? 'On time' } : {})
        }))) })), errors: [], requestCount: stationCodes.length, limited: false };
    },
    async fetchDetails(references, options) {
      calls.details.push({ references: [...references], options });
      return { details: references.map(reference => {
        const service = services.find(value => serviceID(value, reference.station) === reference.serviceID);
        assert.ok(service, 'Discovery requested a known live service');
        const index = service.calls.findIndex(call => call.station === reference.station && call.canBoard);
        const anchor = service.calls[index];
        const point = (call, direction) => ({ crs: call.station,
          st: localClock(direction === 'previous' ? call.departure : call.arrival),
          et: observation(service, call)[direction === 'previous' ? 'etd' : 'eta'] ?? 'On time',
          isCancelled: observation(service, call).isCancelled ?? false });
        return { ...reference, generatedAt: generatedAt(), fetchedAt: new Date(clock).toISOString(), detail: {
          crs: reference.station, operatorCode: service.operator, serviceType: 'train',
          std: localClock(anchor.departure), etd: observation(service, anchor).etd ?? 'On time',
          isCancelled: observation(service, anchor).isCancelled ?? false,
          ...(anchor.arrival ? { sta: localClock(anchor.arrival), eta: observation(service, anchor).eta ?? 'On time' } : {}),
          previousCallingPoints: [{ callingPoint: service.calls.slice(0, index).map(call => point(call, 'previous')) }],
          subsequentCallingPoints: [{ callingPoint: service.calls.slice(index + 1).map(call => point(call, 'subsequent')) }]
        } };
      }), errors: [], requestCount: references.length, limited: false };
    }
  };
  const engine = new PlannerEngine(config, { openDataset: async () => repo, now: () => clock, liveProvider: provider,
    createLiveBudget: createLiveRequestBudget });
  t.after(() => engine.close());
  return { engine, services, calls, state, repo, provider, now: () => clock, setNow: value => { clock = value; },
    search: (changes, signal, execution) => engine.search({ request: request(changes) }, signal, execution) };
}


function failPublicDetails(f, failures) {
  const fetch = f.provider.fetchDetails;
  f.provider.fetchDetails = async (references, options) => {
    const result = await fetch(references, options);
    return { ...result, details: result.details.filter(detail => !failures[detail.serviceID]),
      errors: references.filter(reference => failures[reference.serviceID])
        .map(reference => ({ ...reference, reason: failures[reference.serviceID] })) };
  };
}

function staffRecord(service, station, { observedAt = at('12:00'), delayMinutes = 0, cancelled = false } = {}) {
  const locations = service.calls.map(call => ({ crs: call.station, tiploc: call.tiploc, isCancelled: cancelled,
    ...(Number.isFinite(call.arrival) ? { sta: new Date(call.arrival).toISOString(),
      eta: new Date(call.arrival + delayMinutes * 60000).toISOString(), arrivalType: 'Forecast' } : {}),
    ...(Number.isFinite(call.departure) ? { std: new Date(call.departure).toISOString(),
      etd: new Date(call.departure + delayMinutes * 60000).toISOString(), departureType: 'Forecast' } : {}) }));
  const anchor = service.calls.findIndex(call => call.station === station && call.canBoard);
  assert.ok(anchor >= 0);
  return { station, generatedAt: new Date(observedAt).toISOString(), fetchedAt: iso('12:00'), services: [{
    uid: service.uid, rid: `20260916${service.uid}`, sdd: service.originDate, operatorCode: service.operator,
    isPassengerService: true, ...locations[anchor], previousLocations: locations.slice(0, anchor),
    subsequentLocations: locations.slice(anchor + 1) }] };
}

function enableStaffRecovery(f, records) {
  f.calls.staff = [];
  f.provider.supportsStaffRecovery = () => true;
  f.provider.fetchStaffBoards = async (targets, options) => {
    f.calls.staff.push({ targets, options });
    return { boards: typeof records === 'function' ? await records(targets, options) : records,
      errors: [], limited: false, requestCount: targets.length };
  };
}

function ids(journey) { return journey.legs.filter(leg => leg.kind === 'vehicle').map(leg => leg.scheduledServiceId ?? leg.serviceId); }

test('busy boards do not spend detail lookups on unrelated on-time trains or create blanket match warnings', async t => {
  const useful = direct('USEFUL', '12:10', '12:30');
  const unrelated = Array.from({ length: 80 }, (_, index) => train(`OTHER${index}`,
    [['ORG', null, '12:15'], ['ALT', '12:35', null]]));
  const f = fixture(t, [useful, ...unrelated]);
  const response = await f.search();
  assert.deepEqual(response.journeys.map(ids), [[useful.id]]);
  assert.deepEqual(f.calls.details.flatMap(call => call.references.map(reference => reference.serviceID)), ['live:USEFUL:ORG']);
  assert.equal(response.live.status, 'live');
  assert.ok(response.warnings.every(warning => !/matched safely|lookup limit|could not be retrieved/.test(warning)));
});

test('rerouting checks newly useful trains even when their boarding station was already visited', async t => {
  const first = direct('FIRST', '12:05', '12:25');
  const second = direct('SECOND', '12:04', '12:45');
  const third = direct('THIRD', '12:03', '13:00');
  const f = fixture(t, [first, second, third], {
    FIRST: { ORG: { isCancelled: true }, DST: { isCancelled: true } },
    SECOND: { ORG: { isCancelled: true }, DST: { isCancelled: true } }
  });
  const response = await f.search();
  assert.deepEqual(response.journeys.map(ids), [[third.id]]);
  assert.equal(response.journeys[0].legs[0].live.status, 'onTime');
  assert.equal(f.calls.boards.length, 1);
  assert.deepEqual(f.calls.details.flatMap(call => call.references.map(reference => reference.serviceID)),
    ['live:FIRST:ORG', 'live:SECOND:ORG', 'live:THIRD:ORG']);
});

test('past clock estimates do not trigger expired service-detail requests for unrelated trains', async t => {
  const departed = direct('DEPARTED', '11:00', '11:30');
  const useful = direct('UPCOMING', '12:10', '12:30');
  const f = fixture(t, [departed, useful], { DEPARTED: { ORG: { etd: '11:05' }, DST: { eta: '11:35' } } });
  const response = await f.search();
  assert.deepEqual(response.journeys.map(ids), [[useful.id]]);
  assert.deepEqual(f.calls.details.flatMap(call => call.references.map(reference => reference.serviceID)), ['live:UPCOMING:ORG']);
  assert.equal(response.live.status, 'live');
});

test('apply removes a cancelled direct service and routes a later usable alternative', async t => {
  const fast = direct('A00001', '12:05', '12:25'), later = direct('A00002', '12:10', '12:35');
  const f = fixture(t, [fast, later], { A00001: { ORG: { isCancelled: true }, DST: { isCancelled: true } } });
  const response = await f.search();
  assert.deepEqual(response.journeys.map(ids), [[later.id]]);
  assert.equal(response.journeys[0].arrival, iso('12:35'));
  assert.equal(response.live.mode, 'apply');
  assert.equal(response.live.status, 'live');
  assert.equal(response.dataset.scheduledOnly, false);
  assert.ok(response.disruptedJourneys.some(journey => ids(journey).includes(fast.id) && journey.legs.some(leg => leg.live?.cancelled)));
});

test('a delayed arrival that misses minimum interchange time cannot retain the scheduled connection', async t => {
  const feeder = train('A00003', [['ORG', null, '12:05'], ['MID', '12:15', null]]);
  const onward = train('A00004', [['MID', null, '12:22'], ['DST', '12:40', null]]);
  const alternative = direct('A00005', '12:15', '13:00');
  const f = fixture(t, [feeder, onward, alternative], { A00003: { MID: { eta: '12:25' } } });
  const scheduled = await f.search({ realtime: 'off' });
  assert.ok(scheduled.journeys.some(journey => ids(journey).includes(onward.id)));
  const response = await f.search();
  assert.deepEqual(response.journeys.map(ids), [[alternative.id]]);
  assert.ok(response.disruptedJourneys.some(journey => journey.warnings?.some(warning => warning.includes('connect'))));
});

test('an unknown outgoing live departure warns about uncertainty without declaring a certain missed connection', async t => {
  const feeder = train('A00027', [['ORG', null, '12:05'], ['MID', '12:15', null]]);
  const onward = train('A00028', [['MID', null, '12:22'], ['DST', '12:40', null]]);
  const f = fixture(t, [feeder, onward], {
    A00027: { MID: { eta: '12:25' } }, A00028: { MID: { etd: 'Delayed' }, DST: { eta: '12:50' } }
  });
  const response = await f.search({ realtime: 'ignore' });
  assert.equal(response.journeys.length, 1);
  assert.equal(response.journeys[0].legs.filter(leg => leg.kind === 'vehicle')[1].live.departure, undefined);
  assert.ok(response.journeys[0].warnings.some(warning => warning.includes('cannot be confirmed')));
  assert.ok(response.journeys[0].warnings.every(warning => !warning.includes('do not allow enough time to connect')));
});

test('ignore arrival-deadline warnings include the live inbound arrival and the final fixed-transfer allowance', async t => {
  const feeder = train('A00029', [['ORG', null, '12:05'], ['MID', '12:15', null]]);
  const f = fixture(t, [feeder], { A00029: { MID: { eta: '12:35' } } });
  f.repo.rules.links.push({ id: 'last-walk', origin: 'MID', destination: 'DST', mode: 'walk', minutes: 5,
    priority: 1, startTime: '0000', endTime: '2359', days: '1111111' });
  const response = await f.search({ realtime: 'ignore', timeType: 'arriveBy', time: iso('12:40'), windowMinutes: 60 });
  assert.equal(response.journeys.length, 1);
  const journey = response.journeys[0];
  assert.equal(journey.legs.at(-1).mode, 'walk');
  assert.equal(journey.arrival, iso('12:30'));
  assert.equal(journey.legs[0].live.arrival, iso('12:35'));
  const transfer = journey.legs.at(-1).transfer;
  assert.equal(transfer.exitMinutes + transfer.travelMinutes + transfer.entryMinutes, 15);
  assert.ok(journey.warnings.some(warning => warning.includes('later than your requested arrival time')));
});

test('unfiltered discovery can make a train scheduled before the request newly catchable', async t => {
  const delayed = direct('A00006', '11:55', '12:20'), later = direct('A00007', '12:10', '12:50');
  const f = fixture(t, [delayed, later], { A00006: { ORG: { etd: '12:05' }, DST: { eta: '12:30' } } });
  const scheduled = await f.search({ realtime: 'off' });
  assert.ok(scheduled.journeys.every(journey => !ids(journey).includes(delayed.id)));
  const response = await f.search();
  const found = response.journeys.find(journey => ids(journey).includes(delayed.id));
  assert.ok(found);
  assert.equal(found.departure, iso('12:05'));
  assert.equal(found.arrival, iso('12:30'));
  assert.equal(found.legs[0].scheduledDeparture, iso('11:55'));
  assert.equal(found.legs[0].live.departureDelayMinutes, 10);
});

test('arrive-by applies live arrival deadlines and reranks to an earlier departure', async t => {
  const late = direct('A00008', '12:30', '12:55'), early = direct('A00009', '12:10', '12:50');
  const f = fixture(t, [late, early], { A00008: { DST: { eta: '13:10' } } });
  const response = await f.search({ timeType: 'arriveBy', time: iso('13:00'), windowMinutes: 60 });
  assert.deepEqual(response.journeys.map(ids), [[early.id]]);
  assert.equal(response.journeys[0].departure, iso('12:10'));
  assert.ok(response.disruptedJourneys.some(journey => ids(journey).includes(late.id)));
});

test('arrive-by discovers a delayed train even when its only scheduled departure is in the past', async t => {
  const delayed = direct('A00019', '11:55', '12:20');
  const f = fixture(t, [delayed], { A00019: { ORG: { etd: '12:05' }, DST: { eta: '12:30' } } });
  const response = await f.search({ timeType: 'arriveBy', time: iso('12:40'), windowMinutes: 60 });
  assert.ok(f.calls.boards.length > 0);
  assert.deepEqual(response.journeys.map(ids), [[delayed.id]]);
  assert.equal(response.journeys[0].departure, iso('12:05'));
});

test('apply never boards a train that has departed before completion while ignore retains the scheduled choice', async t => {
  const departed = direct('A00020', '11:50', '12:20');
  const f = fixture(t, [departed]);
  const query = { timeType: 'arriveBy', time: iso('12:40'), windowMinutes: 60 };
  assert.deepEqual((await f.search(query)).journeys, []);
  assert.deepEqual((await f.search({ ...query, realtime: 'ignore' })).journeys.map(ids), [[departed.id]]);
});

test('ignore preserves scheduled routing with live annotations and never mutates scheduled caches', async t => {
  const fast = direct('A00010', '12:05', '12:25'), later = direct('A00011', '12:10', '12:35');
  const f = fixture(t, [fast, later], { A00010: { ORG: { isCancelled: true }, DST: { isCancelled: true } } });
  const initialServices = structuredClone(f.services);
  const before = await f.search({ realtime: 'off' });
  await f.search();
  const ignored = await f.search({ realtime: 'ignore' });
  const cancelled = ignored.journeys.find(journey => ids(journey).includes(fast.id));
  assert.ok(cancelled?.legs[0].live.cancelled);
  assert.equal(cancelled.departure, iso('12:05'));
  assert.equal(ignored.live.mode, 'ignore');
  const after = await f.search({ realtime: 'off' });
  assert.deepEqual(after, before);
  assert.deepEqual(f.services, initialServices);
});

test('future searches outside four hours and requests omitting realtime never call the provider', async t => {
  const f = fixture(t, [direct('A00012', '17:10', '17:30')]);
  const future = await f.search({ time: iso('17:00') });
  assert.equal(future.live.status, 'outsideWindow');
  assert.equal(future.dataset.scheduledOnly, true);
  assert.equal(f.calls.boards.length, 0);
  const omitted = request({ time: iso('17:00'), realtime: undefined });
  const explicit = request({ time: iso('17:00'), realtime: 'off' });
  assert.deepEqual(omitted, explicit);
  const older = await f.engine.search({ request: omitted });
  assert.equal(older.live, undefined);
  assert.equal(older.disruptedJourneys, undefined);
  assert.equal(f.calls.boards.length, 0);
});

test('outside-window More retains its scheduled context across the four-hour boundary then expires', async t => {
  const trains = [direct('A00033', '16:02', '16:22'), direct('A00034', '16:03', '16:23'), direct('A00035', '16:04', '16:24')];
  const f = fixture(t, trains);
  const first = await f.search({ time: iso('16:01'), windowMinutes: 15, limit: 1 });
  assert.equal(first.live.status, 'outsideWindow');
  assert.equal(first.live.updatedAt, undefined);
  assert.equal(first.live.expiresAt, undefined);
  assert.deepEqual(first.journeys.map(ids), [[trains[0].id]]);
  const more = decodeCursor(first.pagination.more);
  assert.ok(more.liveSnapshotId);
  assert.equal(f.engine.livePlanner.snapshots.get(more.liveSnapshotId).expiresAt, at('12:00') + 90_000);
  assert.equal(f.calls.boards.length, 0);
  assert.equal(decodeCursor(first.pagination.earlier).liveSnapshotId, undefined);
  assert.equal(decodeCursor(first.pagination.later).liveSnapshotId, undefined);

  f.setNow(at('12:01') + 1000); // The same requested time is now within four hours.
  f.state.updates.A00034 = { ORG: { isCancelled: true }, DST: { isCancelled: true } };
  const second = await f.engine.search(more);
  assert.deepEqual(second.live, first.live);
  assert.equal(second.dataset.scheduledOnly, true);
  assert.deepEqual(second.journeys.map(ids), [[trains[1].id]]);
  assert.equal(second.journeys[0].legs[0].live, undefined);
  assert.equal(decodeCursor(second.pagination.more).liveSnapshotId, more.liveSnapshotId);
  assert.equal(f.calls.boards.length, 0);
  assert.equal(f.calls.details.length, 0);

  const freshEarlier = await f.engine.search(decodeCursor(first.pagination.earlier));
  assert.equal(freshEarlier.live.mode, 'apply');
  assert.ok(f.calls.boards.length > 0);
  const lookups = f.calls.boards.length;
  f.setNow(at('12:00') + 90_001);
  await assert.rejects(f.engine.search(more), { code: 'CURSOR_EXPIRED' });
  assert.equal(f.calls.boards.length, lookups);
});

test('provider failure falls back to scheduled journeys with explicit unavailable coverage', async t => {
  const f = fixture(t, [direct('A00013', '12:10', '12:30')]);
  f.state.unavailable = true;
  const response = await f.search();
  assert.equal(response.journeys.length, 1);
  assert.equal(response.live.status, 'unavailable');
  assert.equal(response.dataset.scheduledOnly, true);
  assert.ok(response.warnings.some(warning => warning.includes('scheduled times')));
  assert.ok(response.journeys[0].legs[0].warnings.some(warning => warning.includes('scheduled times')));
});

test('missing, stale and future provider timestamps cannot become fresh because they were fetched now', async t => {
  for (const timestamp of [null, '2026-09-16T10:57:00Z', '2026-09-16T11:05:00Z']) {
    const f = fixture(t, [direct('A00021', '12:10', '12:30')], { A00021: { ORG: { isCancelled: true }, DST: { isCancelled: true } } });
    f.state.generatedAt = timestamp;
    const response = await f.search();
    assert.equal(response.live.status, 'unavailable');
    assert.equal(response.dataset.scheduledOnly, true);
    assert.equal(response.journeys.length, 1);
    assert.equal(response.journeys[0].legs[0].live, undefined);
  }
});

test('more pages pin a live snapshot, fresh searches and later windows stay independent, expired pages fail', async t => {
  const trains = [direct('A00014', '12:05', '12:25'), direct('A00015', '12:10', '12:30'), direct('A00016', '12:15', '12:35')];
  const f = fixture(t, trains);
  const first = await f.search({ limit: 1 });
  assert.ok(first.pagination.more);
  const cursor = decodeCursor(first.pagination.more);
  assert.ok(cursor.liveSnapshotId);
  const count = f.calls.boards.length;
  f.state.updates.A00015 = { ORG: { isCancelled: true }, DST: { isCancelled: true } };
  const second = await f.engine.search(cursor);
  assert.deepEqual(ids(second.journeys[0]), [trains[1].id]);
  assert.equal(second.journeys[0].legs[0].live.cancelled, false);
  assert.equal(f.calls.boards.length, count);
  const refreshed = await f.search({ limit: 1 });
  assert.notEqual(decodeCursor(refreshed.pagination.more).liveSnapshotId, cursor.liveSnapshotId);
  const later = decodeCursor(first.pagination.later);
  assert.equal(later.liveSnapshotId, undefined);
  assert.equal(later.request.realtime, 'apply');
  await f.engine.search(later);
  assert.ok(f.calls.boards.length > count);
  f.setNow(Date.parse(first.live.expiresAt) + 1);
  await assert.rejects(f.engine.search(cursor), { code: 'CURSOR_EXPIRED' });
});

test('retained pages omit departed trains without shifting the next original offset or duplicating journeys', async t => {
  const trains = [direct('A00022', '12:00', '12:20'), direct('A00023', '12:01', '12:21'), direct('A00024', '12:02', '12:22')];
  const f = fixture(t, trains);
  const first = await f.search({ limit: 1 });
  assert.deepEqual(first.journeys.map(ids), [[trains[0].id]]);
  const secondCursor = decodeCursor(first.pagination.more);
  assert.equal(secondCursor.offset, 1);
  f.setNow(at('12:01') + 1000);
  assert.ok(f.now() < Date.parse(first.live.expiresAt));
  const second = await f.engine.search(secondCursor);
  assert.deepEqual(second.journeys, []);
  assert.ok(second.warnings.some(warning => /depart|passed/i.test(warning)));
  const thirdCursor = decodeCursor(second.pagination.more);
  assert.equal(thirdCursor.offset, 2);
  assert.equal(thirdCursor.liveSnapshotId, secondCursor.liveSnapshotId);
  const third = await f.engine.search(thirdCursor);
  assert.deepEqual(third.journeys.map(ids), [[trains[2].id]]);
  const returned = [...first.journeys, ...second.journeys, ...third.journeys].map(journey => journey.id);
  assert.equal(new Set(returned).size, returned.length);
  assert.equal(third.pagination.more, undefined);
});

test('observations that expire during computation cannot produce an immediately expired more cursor', async t => {
  const f = fixture(t, [direct('A00025', '12:05', '12:25'), direct('A00026', '12:10', '12:30')]);
  f.engine.findJourneys = (query, network, options) => {
    const result = findJourneys(query, network, options);
    if (network.live) f.setNow(f.now() + 120_000);
    return result;
  };
  const response = await f.search({ limit: 1 });
  assert.ok(Date.parse(response.live.expiresAt) < f.now());
  assert.equal(response.pagination.more, undefined);
  assert.ok(response.warnings.some(warning => /aged|out of date|expired/i.test(warning)));
});

test('journey details retain the exact live result context while full service stops remain dated', async t => {
  const f = fixture(t, [direct('A00017', '12:05', '12:25')], { A00017: { ORG: { etd: '12:10' }, DST: { eta: '12:30' } } });
  const response = await f.search();
  const journey = response.journeys[0];
  const details = await f.engine.journey(journey.id);
  assert.deepEqual(details.live, response.live);
  assert.equal(details.dataset.scheduledOnly, false);
  assert.equal(details.journey.legs[0].departure, iso('12:10'));
  assert.equal(details.journey.legs[0].scheduledDeparture, iso('12:05'));
  assert.equal(details.journey.legs[0].serviceCallingPoints.at(-1).arrival, iso('12:25'));

  // Exercise the production parent cache and metadata lookup without starting a
  // real worker: only transport is injected, while settle/journey are unchanged.
  t.mock.method(Date, 'now', f.now);
  const service = new PlannerService(config);
  service.metadataService = { call: async (_method, payload) => f.engine.publicMetadata(f.repo, payload.live), close() {} };
  t.after(() => service.close());
  service.settle({ method: 'search', resolve() {}, reject: error => { throw error; }, settled: false }, null, response);
  const parentDetails = await service.journey(journey.id);
  assert.deepEqual(parentDetails.live, response.live);
  assert.deepEqual(parentDetails.journey, journey);
  assert.equal(parentDetails.dataset.scheduledOnly, false);
  assert.ok(parentDetails.dataset.warnings.every(warning => !warning.includes('Scheduled timetable only')));
});

test('identical timetable journeys retain separate off, apply, ignore and unavailable detail contexts', async t => {
  const f = fixture(t, [direct('A00030', '12:05', '12:25')]);
  const responses = [await f.search({ realtime: 'off' }), await f.search(), await f.search({ realtime: 'ignore' })];
  f.state.unavailable = true;
  responses.push(await f.search(), await f.search({ realtime: 'ignore' }));
  const identifiers = responses.map(response => response.journeys[0].id);
  assert.equal(new Set(identifiers).size, responses.length);
  assert.ok(responses.every(response => response.journeys[0].departure === iso('12:05') && response.journeys[0].arrival === iso('12:25')));
  t.mock.method(Date, 'now', f.now);
  const service = new PlannerService(config);
  service.metadataService = { call: async (_method, payload) => f.engine.publicMetadata(f.repo, payload.live), close() {} };
  t.after(() => service.close());
  for (const response of responses) {
    service.settle({ method: 'search', resolve() {}, reject: error => { throw error; }, settled: false }, null, response);
  }
  for (const response of responses) {
    const id = response.journeys[0].id;
    const engineDetails = await f.engine.journey(id);
    const parentDetails = await service.journey(id);
    assert.deepEqual(engineDetails.live, response.live);
    assert.deepEqual(parentDetails.live, response.live);
    assert.deepEqual(parentDetails.journey, response.journeys[0]);
  }
});

test('live reroutes share one operation budget even when each individual route pass fits', async t => {
  const services = [direct('A00031', '12:05', '12:25'), direct('A00032', '12:10', '12:30')];
  const measured = fixture(t, services);
  const operations = [];
  measured.engine.findJourneys = (query, network, options) => {
    const result = findJourneys(query, network, options);
    operations.push(result.metrics.operations);
    return result;
  };
  await measured.search();
  assert.ok(operations.length >= 2);
  const budget = Math.max(...operations) + 1;
  assert.ok(operations.reduce((sum, count) => sum + count, 0) > budget);
  const bounded = fixture(t, services);
  bounded.engine.config = { ...config, maxOperations: budget };
  await assert.rejects(bounded.search(), { code: 'SEARCH_TIMEOUT' });
});

test('cancelling while the provider is pending aborts the search and does not retain partial results', async t => {
  const f = fixture(t, [direct('A00018', '12:05', '12:25')]);
  const controller = new AbortController();
  let started;
  const pending = new Promise(resolve => { started = resolve; });
  f.state.onBoards = ({ signal }) => new Promise((resolve, reject) => {
    started();
    signal.addEventListener('abort', () => reject(Object.assign(new Error('Cancelled'), { code: 'SEARCH_CANCELLED' })), { once: true });
  });
  const search = f.search({}, controller.signal, { abortSignal: controller.signal });
  await pending;
  controller.abort();
  await assert.rejects(search, { code: 'SEARCH_CANCELLED' });
  assert.equal(f.engine.journeys.size, 0);
  assert.equal(f.engine.livePlanner.snapshots.size, 0);
});


test('staff recovery verifies a requested public upstream failure and applies complete dated forecasts', async t => {
  const service = direct('S00001', '12:05', '12:25');
  const f = fixture(t, [service]);
  failPublicDetails(f, { 'live:S00001:ORG': 'upstream' });
  enableStaffRecovery(f, [staffRecord(service, 'ORG', { delayMinutes: 10 })]);
  const response = await f.search();
  assert.equal(response.live.status, 'live');
  assert.equal(response.journeys[0].departure, iso('12:15'));
  assert.equal(response.journeys[0].arrival, iso('12:35'));
  assert.equal(response.journeys[0].legs[0].scheduledDeparture, iso('12:05'));
  assert.equal(response.journeys[0].legs[0].live.departureDelayMinutes, 10);
  assert.ok(response.warnings.every(warning => !warning.includes('could not be retrieved')));
  assert.deepEqual(f.calls.staff[0].targets, [{ station: 'ORG', departure: at('12:05') }]);
  assert.equal(f.calls.staff[0].options.budget, f.calls.boards[0].options.budget);
  assert.equal(f.calls.staff[0].options.budget.limit, 64);
  const ignored = await f.search({ realtime: 'ignore' });
  assert.equal(ignored.journeys[0].departure, iso('12:05'));
  assert.equal(ignored.journeys[0].legs[0].live.departure, iso('12:15'));
  assert.ok(ignored.live.warnings.some(warning => warning.includes('scheduled times')));
});

test('staff cancellation recovery reroutes while an already verified public service always wins', async t => {
  const first = direct('S00002', '12:05', '12:25'), later = direct('S00003', '12:10', '12:30');
  const f = fixture(t, [first, later]);
  failPublicDetails(f, { 'live:S00002:ORG': 'unavailable' });
  // The staff board also lists the publicly verified alternative as cancelled.
  // Recovery is allowlisted to failed public occurrences, so it must not replace it.
  enableStaffRecovery(f, [staffRecord(first, 'ORG', { cancelled: true }), staffRecord(later, 'ORG', { cancelled: true })]);
  const response = await f.search();
  assert.deepEqual(response.journeys.map(ids), [[later.id]]);
  assert.equal(response.journeys[0].legs[0].live.cancelled, false);
  assert.ok(response.disruptedJourneys.some(journey => ids(journey).includes(first.id) && journey.legs[0].live.cancelled));
  assert.deepEqual(f.calls.staff[0].targets, [{ station: 'ORG', departure: at('12:05') }]);
});

test('staff recovery is optional and only upstream or unavailable public detail failures trigger it', async t => {
  for (const reason of ['credentialsUnavailable', 'authentication', 'malformed', 'timeout', 'rateLimited', 'connectivity', 'requestLimit']) {
    const service = direct('S00004', '12:10', '12:30');
    const f = fixture(t, [service]);
    failPublicDetails(f, { 'live:S00004:ORG': reason });
    enableStaffRecovery(f, [staffRecord(service, 'ORG')]);
    const response = await f.search();
    assert.equal(f.calls.staff.length, 0, reason);
    assert.equal(response.journeys[0].legs[0].live, undefined);
  }
  for (const support of [false, undefined]) {
    const service = direct('S00005', '12:10', '12:30');
    const f = fixture(t, [service]);
    failPublicDetails(f, { 'live:S00005:ORG': 'upstream' });
    enableStaffRecovery(f, [staffRecord(service, 'ORG')]);
    f.provider.supportsStaffRecovery = support === undefined ? undefined : () => support;
    const response = await f.search();
    assert.equal(f.calls.staff.length, 0);
    assert.equal(response.live.status, 'unavailable');
  }
});

test('staff queries are capped across rounds and unchanged recovered observations do not reroute again', async t => {
  const services = Array.from({ length: 25 }, (_, index) => direct(`S${String(index + 100).padStart(5, '0')}`,
    `12:${String(index + 1).padStart(2, '0')}`, `13:${String(index + 1).padStart(2, '0')}`));
  const f = fixture(t, services);
  failPublicDetails(f, Object.fromEntries(services.map(service => [`live:${service.uid}:ORG`, 'upstream'])));
  const observation = at('12:00') - 30000;
  enableStaffRecovery(f, [staffRecord(services[0], 'ORG', { observedAt: observation })]);
  let routes = 0;
  f.engine.findJourneys = (...args) => { routes++; return findJourneys(...args); };
  const response = await f.search({ limit: 5 });
  assert.equal(f.calls.staff.length, 1);
  assert.equal(f.calls.staff[0].targets.length, 8);
  assert.equal(new Set(f.calls.staff[0].targets.map(target => `${target.station}:${target.departure}`)).size, 8);
  assert.equal(f.calls.details.length, 2);
  assert.equal(routes, 2); // One scheduled route, one changed overlay; next pass has the same hash.
  assert.equal(response.live.updatedAt, new Date(observation).toISOString());
  assert.equal(Date.parse(response.live.expiresAt), observation + 90000);
  const retained = [...f.engine.livePlanner.snapshots.values()][0];
  assert.equal(retained.coverageContext.limited, true);
  assert.ok(retained.coverageContext.pendingServiceIds.includes(services.at(-1).id));
});

test('staff queries deduplicate failed services at the same station and exact departure minute', async t => {
  const first = direct('S00006', '12:10', '12:30'), second = direct('S00007', '12:10', '12:40');
  const f = fixture(t, [first, second]);
  failPublicDetails(f, { 'live:S00006:ORG': 'upstream', 'live:S00007:ORG': 'upstream' });
  enableStaffRecovery(f, [staffRecord(first, 'ORG')]);
  const response = await f.search();
  assert.deepEqual(f.calls.staff.flatMap(call => call.targets), [{ station: 'ORG', departure: at('12:10') }]);
  assert.equal(response.journeys[0].legs[0].live.status, 'onTime');
});

test('stale staff recovery cannot turn failed public details into fresh live coverage', async t => {
  const service = direct('S00008', '12:10', '12:30');
  const f = fixture(t, [service]);
  failPublicDetails(f, { 'live:S00008:ORG': 'upstream' });
  enableStaffRecovery(f, [staffRecord(service, 'ORG', { observedAt: at('11:58'), delayMinutes: 10 })]);
  const response = await f.search();
  assert.equal(response.live.status, 'unavailable');
  assert.equal(response.journeys[0].departure, iso('12:10'));
  assert.equal(response.journeys[0].legs[0].live, undefined);
});

test('cancelling pending staff recovery aborts without retaining a partial result', async t => {
  const service = direct('S00009', '12:10', '12:30');
  const f = fixture(t, [service]);
  failPublicDetails(f, { 'live:S00009:ORG': 'upstream' });
  let started;
  const pending = new Promise(resolve => { started = resolve; });
  enableStaffRecovery(f, (_targets, { signal }) => new Promise((_resolve, reject) => {
    started();
    signal.addEventListener('abort', () => reject(Object.assign(new Error('Cancelled'), { code: 'SEARCH_CANCELLED' })), { once: true });
  }));
  const controller = new AbortController();
  const search = f.search({}, controller.signal, { abortSignal: controller.signal });
  await pending;
  controller.abort();
  await assert.rejects(search, { code: 'SEARCH_CANCELLED' });
  assert.equal(f.engine.livePlanner.snapshots.size, 0);
  assert.equal(f.engine.journeys.size, 0);
});
