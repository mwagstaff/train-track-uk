import test from 'node:test';
import assert from 'node:assert/strict';
import { refreshRouteBoard, selectRouteBoardJourneys } from '../lib/planner/route-board-live.js';
import { findJourneys } from '../lib/planner/router.js';
import { normalizeRequest } from '../lib/planner/contract.js';
import { PlannerLiveProvider } from '../lib/planner/live-provider.js';

const DATE = '2026-09-17';
const at = clock => Date.parse(`${DATE}T${clock}:00+01:00`);
const iso = clock => new Date(at(clock)).toISOString();
const hhmm = time => new Date(time + 3600000).toISOString().slice(11, 16);
const train = (uid, stops) => ({ id: uid, uid, variantId: uid, originDate: DATE, operator: 'SN', mode: 'rail',
    calls: stops.map(([station, arrival, departure], sequence) => ({ station, tiploc: station, sequence,
        arrival: arrival ? at(arrival) : null, departure: departure ? at(departure) : null,
        canBoard: Boolean(departure), canAlight: Boolean(arrival) })) });
const direct = (uid, departure, arrival) => train(uid, [['ORG', null, departure], ['DST', arrival, null]]);

function fixture(services, selected = services.map(service => [service])) {
    const request = normalizeRequest({ origin: 'ORG', destination: 'DST', time: iso('11:00'), timeType: 'departAfter', windowMinutes: 360 });
    const network = { services, rules: { tsi: [], links: [] }, stations: new Map(['ORG', 'MID', 'ALT', 'DST'].map(crs =>
        [crs, { crs, name: crs, minimumChangeMinutes: 5 }])) };
    const candidates = selected.map(values => findJourneys(request, { ...network, services: values }).journeys[0]);
    assert.ok(candidates.every(Boolean));
    const profile = { request, candidates };
    let clock = at('12:00');
    const state = { updates: {}, failed: new Set(), unavailable: false, generatedAt: null };
    const calls = { boards: [], details: [], staff: [] };
    const observation = (service, station) => state.updates[service.id]?.[station] ?? {};
    const generatedAt = () => state.generatedAt ?? new Date(clock).toISOString();
    const provider = {
        async fetchBoards(stations, options) {
            calls.boards.push({ stations, options });
            if (state.unavailable) return { boards: [], errors: [{ station: 'ORG', reason: 'connectivity' }] };
            return { errors: [], boards: stations.map(station => ({ station, generatedAt: generatedAt(), window: { offsetMinutes: 0 },
                services: services.flatMap(service => service.calls.filter(call => call.station === station && call.canBoard).map(call => ({
                    serviceID: `${service.id}:${station}`, operatorCode: service.operator, std: hhmm(call.departure),
                    etd: 'On time', ...(call.arrival ? { sta: hhmm(call.arrival), eta: 'On time' } : {}),
                    ...observation(service, station)
                }))) })) };
        },
        async fetchDetails(references, options) {
            calls.details.push({ references, options });
            const errors = references.filter(reference => state.failed.has(reference.serviceID)).map(reference => ({ ...reference, reason: 'upstream' }));
            const details = references.filter(reference => !state.failed.has(reference.serviceID)).map(reference => {
                const service = services.find(value => `${value.id}:${reference.station}` === reference.serviceID);
                const index = service.calls.findIndex(call => call.station === reference.station);
                const current = service.calls[index];
                const point = (call, previous) => ({ crs: call.station, st: hhmm(previous ? call.departure : call.arrival),
                    et: observation(service, call.station)[previous ? 'etd' : 'eta'] ?? 'On time',
                    isCancelled: observation(service, call.station).isCancelled ?? false });
                return { ...reference, generatedAt: generatedAt(), detail: { crs: reference.station, operatorCode: service.operator,
                    std: hhmm(current.departure), etd: 'On time', ...observation(service, reference.station),
                    ...(current.arrival ? { sta: hhmm(current.arrival), eta: observation(service, reference.station).eta ?? 'On time' } : {}),
                    previousCallingPoints: [{ callingPoint: service.calls.slice(0, index).map(call => point(call, true)) }],
                    subsequentCallingPoints: [{ callingPoint: service.calls.slice(index + 1).map(call => point(call, false)) }] } };
            });
            return { details, errors };
        }
    };
    return { profile, network, provider, calls, state, setNow: value => { clock = value; },
        refresh: options => refreshRouteBoard({ profile, network, time: new Date(clock).toISOString(), ...options }, { provider, now: () => clock }) };
}

test('refresh retimes and ranks actual cached trains, preserves source and stable disruption fingerprint', async () => {
    const first = direct('FIRST', '12:05', '12:25'), second = direct('SECOND', '12:10', '12:30');
    const f = fixture([first, second]);
    const before = JSON.stringify([f.profile, f.network.services]);
    f.state.updates.FIRST = { ORG: { etd: '12:20' }, DST: { eta: '12:40' } };
    const value = await f.refresh();
    assert.deepEqual(value.journeys.map(journey => journey.legs[0].serviceId), ['SECOND', 'FIRST']);
    assert.equal(value.journeys[1].departure, iso('12:20'));
    assert.equal(value.journeys[1].legs[0].live.status, 'delayed');
    assert.deepEqual(value.journeys[1].legs[0].tracking, { providerServiceId: 'FIRST:ORG', station: 'ORG',
        uid: 'FIRST', originDate: DATE, verifiedAt: iso('12:00') });
    assert.equal(value.live.status, 'live');
    assert.equal(value.needsReplan, true);
    f.setNow(at('12:00') + 30000);
    assert.equal((await f.refresh()).disruptionFingerprint, value.disruptionFingerprint);
    assert.equal(JSON.stringify([f.profile, f.network.services]), before);
});

test('cancelled and missed-connection candidates are disrupted; ignore retains routes with warnings', async () => {
    const feeder = train('FEEDER', [['ORG', null, '12:05'], ['MID', '12:20', null]]);
    const connection = train('NEXT', [['MID', null, '12:25'], ['DST', '12:40', null]]);
    const cancelled = direct('CANCELLED', '12:08', '12:35');
    const f = fixture([feeder, connection, cancelled], [[feeder, connection], [cancelled]]);
    f.state.updates.FEEDER = { MID: { eta: '12:23' } };
    f.state.updates.CANCELLED = { ORG: { isCancelled: true } };
    const applied = await f.refresh();
    assert.equal(applied.journeys.length, 0);
    assert.equal(applied.disruptedJourneys.length, 2);
    assert.equal(applied.needsReplan, true);
    const ignored = await f.refresh({ realtime: 'ignore' });
    assert.equal(ignored.journeys.length, 2);
    assert.equal(ignored.needsReplan, false);
    assert.equal(ignored.disruptionFingerprint, null);
    assert.ok(ignored.journeys.some(journey => journey.warnings?.some(warning => /connection/.test(warning))));
    assert.ok(ignored.journeys.some(journey => journey.legs[0].live.cancelled));
});

test('unknown outgoing time never claims a certain missed connection', async () => {
    const feeder = train('FEEDER', [['ORG', null, '12:05'], ['MID', '12:20', null]]);
    const next = train('NEXT', [['MID', null, '12:25'], ['DST', '12:40', null]]);
    const f = fixture([feeder, next], [[feeder, next]]);
    f.state.updates.NEXT = { MID: { etd: 'Delayed' } };
    const applied = await f.refresh();
    assert.equal(applied.journeys.length, 0);
    assert.match(applied.disruptedJourneys[0].warnings.join(' '), /cannot confirm/);
    const ignored = await f.refresh({ realtime: 'ignore' });
    assert.ok(!ignored.journeys[0].warnings.some(warning => /no longer allow/.test(warning)));
});

test('public errors recover through exact UID/date staff observations under the same budget', async () => {
    const service = direct('STAFF', '12:05', '12:25');
    const f = fixture([service]);
    f.state.failed.add('STAFF:ORG');
    f.provider.supportsStaffRecovery = () => true;
    f.provider.fetchStaffBoards = async (targets, options) => {
        f.calls.staff.push({ targets, options });
        return { boards: [{ station: 'ORG', generatedAt: iso('12:00'), services: [{ uid: service.uid, rid: '20260917RID',
            sdd: DATE, operatorCode: 'SN', std: iso('12:05'), etd: iso('12:06'), departureType: 'Forecast',
            subsequentLocations: [{ crs: 'DST', tiploc: 'DST', sta: iso('12:25'), eta: iso('12:26'), arrivalType: 'Forecast' }] }] }], errors: [] };
    };
    const value = await f.refresh();
    assert.equal(value.live.status, 'live');
    assert.equal(value.journeys[0].arrival, iso('12:26'));
    assert.equal(value.journeys[0].legs[0].tracking, undefined, 'Staff RID is not a public service ID');
    assert.equal(f.calls.staff[0].options.budget, f.calls.boards[0].options.budget);
    assert.equal(f.calls.staff[0].options.budget, f.calls.details[0].options.budget);
});

test('matching includes competing trains outside profile and never makes an ambiguous observation live', async () => {
    const a = direct('A', '12:05', '12:25'), b = direct('B', '12:05', '12:25');
    const f = fixture([a, b], [[a]]);
    const result = await f.refresh();
    assert.equal(result.journeys.length, 1);
    assert.equal(result.live.status, 'unavailable');
    assert.equal(result.journeys[0].legs[0].live, undefined);
    assert.equal(result.journeys[0].legs[0].tracking, undefined);
});

test('delayed scheduled-past departures become catchable; newly discovered trains request a replan', async () => {
    const late = direct('LATE', '11:55', '12:25');
    const f = fixture([late]);
    f.state.updates.LATE = { ORG: { etd: '12:05' }, DST: { eta: '12:35' } };
    const value = await f.refresh();
    assert.equal(value.journeys[0].departure, iso('12:05'));
    assert.equal(value.needsReplan, true);
    const other = direct('NEW', '12:10', '12:20'), cached = direct('CACHED', '12:15', '12:30');
    const next = fixture([other, cached], [[cached]]);
    const result = await next.refresh();
    assert.equal(result.journeys.length, 1);
    assert.equal(result.journeys[0].legs[0].serviceId, 'CACHED');
    assert.equal(result.needsReplan, true);
});

test('refresh bounds next-train detail requests and uses honest fallback for unavailable or stale data', async () => {
    const trains = Array.from({ length: 30 }, (_, index) => direct(`T${index}`, `12:${String(index + 1).padStart(2, '0')}`, `13:${String(index + 1).padStart(2, '0')}`));
    const f = fixture(trains);
    await f.refresh();
    assert.equal(f.calls.details[0].references.length, 20);
    assert.ok(f.calls.boards[0].stations.length <= 8);
    f.state.unavailable = true;
    const unavailable = await f.refresh();
    assert.equal(unavailable.journeys.length, 5);
    assert.equal(unavailable.live.status, 'unavailable');
    assert.equal(unavailable.needsReplan, false);
    f.state.unavailable = false;
    f.state.generatedAt = new Date(at('12:00') - 91000).toISOString();
    assert.equal((await f.refresh()).live.status, 'unavailable');
});

test('detail selection prioritizes visible boarding trains regardless of board completion order', async () => {
    const trains = Array.from({ length: 30 }, (_, index) => direct(`T${index}`, `12:${String(index + 1).padStart(2, '0')}`,
        index >= 25 ? `12:${index + 15}` : `14:${String(index + 1).padStart(2, '0')}`));
    const f = fixture(trains);
    const fetchBoards = f.provider.fetchBoards;
    f.provider.fetchBoards = async (...args) => {
        const result = await fetchBoards(...args);
        result.boards.forEach(board => board.services.reverse());
        return result;
    };
    const result = await f.refresh();
    assert.deepEqual(f.calls.details[0].references.slice(0, 5).map(value => value.serviceID),
        ['T25:ORG', 'T26:ORG', 'T27:ORG', 'T28:ORG', 'T29:ORG']);
    assert.deepEqual(result.journeys.map(journey => journey.legs[0].serviceId), ['T25', 'T26', 'T27', 'T28', 'T29']);
    assert.equal(f.calls.details[0].references.length, 20);
    assert.equal(result.live.status, 'live');
});

test('later trains skip live polling; tube-only transfer needs no rail verification', async () => {
    const f = fixture([direct('LATER', '16:05', '16:25')]);
    const result = await f.refresh();
    assert.equal(f.calls.boards.length, 0);
    assert.equal(result.live.status, 'outsideWindow');
    const request = normalizeRequest({ origin: 'ORG', destination: 'DST', time: iso('12:00'), timeType: 'departAfter' });
    const network = { services: [], stations: new Map(['ORG', 'DST'].map(crs => [crs, { crs, minimumChangeMinutes: 0 }])),
        rules: { tsi: [], links: [{ id: 'TUBE', origin: 'ORG', destination: 'DST', mode: 'tubeTransfer', minutes: 10 }] } };
    const candidates = findJourneys(request, network).journeys;
    assert.equal(candidates.length, 1);
    const onlyTube = await refreshRouteBoard({ profile: { request, candidates }, network, time: iso('12:00') }, {
        now: () => at('12:00'), provider: { fetchBoards() { assert.fail('No rail polling for tube transfer'); } } });
    assert.equal(onlyTube.journeys.length, 1);
    assert.equal(onlyTube.live.coverage.nearTermRailLegs, 0);
});

test('direct preference retains a connection saving at least ten minutes', () => {
    const journeys = [{ id: 'direct', changes: 0, departure: iso('12:10'), arrival: iso('13:00') },
        { id: 'nine', changes: 1, departure: iso('12:05'), arrival: iso('12:51') },
        { id: 'ten', changes: 1, departure: iso('12:04'), arrival: iso('12:50') }];
    assert.deepEqual(selectRouteBoardJourneys(journeys).map(journey => journey.id), ['ten', 'direct', 'nine']);
    const interleaved = [
        { id: 'near-direct', changes: 0, departure: iso('12:00'), arrival: iso('12:30') },
        { id: 'late-direct', changes: 0, departure: iso('12:20'), arrival: iso('13:30') },
        { id: 'connection', changes: 1, departure: iso('12:05'), arrival: iso('12:40') },
        { id: 'exact-ten', changes: 1, departure: iso('12:10'), arrival: iso('13:20') }
    ];
    assert.deepEqual(selectRouteBoardJourneys(interleaved).map(journey => journey.id),
        ['near-direct', 'connection', 'exact-ten', 'late-direct']);
});

test('selection deduplicates identical retimed paths but preserves different trains at the same time', () => {
    const f = fixture([direct('FIRST', '12:05', '12:25'), direct('SECOND', '12:05', '12:25')]);
    const [first, second] = f.profile.candidates;
    const result = selectRouteBoardJourneys([first, structuredClone(first), second]);
    assert.deepEqual(result.map(journey => journey.legs[0].serviceId), ['FIRST', 'SECOND']);
});

test('cancelled refresh does not return a partially updated board', async () => {
    const f = fixture([direct('A', '12:05', '12:25')]);
    const controller = new AbortController();
    f.provider.fetchBoards = async () => { controller.abort(); return { boards: [], errors: [] }; };
    await assert.rejects(f.refresh({ abortSignal: controller.signal }), { code: 'SEARCH_CANCELLED' });
});

test('fixed tube transfers are retimed with both station allowances and revalidated after delay', async () => {
    const first = train('FIRST', [['ORG', null, '12:05'], ['MID', '12:20', null]]);
    const second = train('SECOND', [['ALT', null, '12:50'], ['DST', '13:10', null]]);
    const placeholder = direct('PLACEHOLDER', '12:10', '13:00');
    const f = fixture([first, placeholder], [[placeholder]]);
    f.network.services.splice(1, 1, second);
    f.network.rules.links.push({ id: 'TUBE', origin: 'MID', destination: 'ALT', mode: 'tubeTransfer', minutes: 10 });
    f.profile.candidates = findJourneys(f.profile.request, f.network).journeys;
    assert.equal(f.profile.candidates.length, 1);
    f.state.updates.FIRST = { MID: { eta: '12:25' } };
    const safe = await f.refresh();
    const link = safe.journeys[0].legs[1];
    assert.equal(link.departure, iso('12:25'));
    assert.equal(link.arrival, iso('12:45'));
    assert.deepEqual([link.breakdown.exitMinutes, link.breakdown.travelMinutes, link.breakdown.entryMinutes], [5, 10, 5]);
    f.state.updates.FIRST.MID.eta = '12:35';
    const missed = await f.refresh();
    assert.equal(missed.journeys.length, 0);
    assert.match(missed.disruptedJourneys[0].warnings.join(' '), /connection/);
});

test('a shared actual provider reuses successful responses for 30 seconds across refreshes', async () => {
    const f = fixture([direct('A', '12:05', '12:25')]);
    let clock = at('12:00'), count = 0;
    const provider = new PlannerLiveProvider({ now: () => clock, credentials: () => ({ board: 'fixture', details: 'fixture' }),
        request: async options => {
            count++;
            const target = decodeURIComponent(new URL(options.url).pathname.split('/').at(-1));
            if (options.operation === 'get_departure_board') {
                const board = (await f.provider.fetchBoards([target], {})).boards[0];
                return { data: { crs: target, generatedAt: board.generatedAt, trainServices: board.services } };
            }
            const detail = (await f.provider.fetchDetails([{ station: 'ORG', serviceID: target }], {})).details[0];
            return { data: { ...detail.detail, generatedAt: detail.generatedAt } };
        } });
    const refresh = () => refreshRouteBoard({ profile: f.profile, network: f.network, time: new Date(clock).toISOString() }, { provider, now: () => clock });
    await refresh();
    assert.equal(count, 4);
    clock += 20000; f.setNow(clock);
    await refresh();
    assert.equal(count, 4, 'Second 20-second poll uses the provider cache');
    clock += 11000; f.setNow(clock);
    await refresh();
    assert.equal(count, 8);
});
