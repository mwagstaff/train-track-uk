import test from 'node:test';
import assert from 'node:assert/strict';
import { SavedRouteLive, earliestRouteJourneys } from '../lib/planner/saved-route-live.js';

const now = Date.parse('2026-09-17T11:00:00Z');
const iso = clock => `2026-09-17T${clock}:00+01:00`;
const utc = clock => new Date(iso(clock)).toISOString();
const request = { origin: 'ORG', destination: 'DST', via: [], realtime: 'apply', maxChanges: 5, extraConnectionMinutes: 0 };
const place = crs => ({ crs, name: crs });
const leg = (from, to, departure, arrival) => ({ kind: 'vehicle', mode: 'rail', from: place(from), to: place(to),
    departure: utc(departure), arrival: utc(arrival), operator: 'SN', serviceId: `cached:${from}:${departure}`,
    originDate: '2026-09-17', callingPoints: [{ station: place(from), departure: utc(departure), arrival: null },
        { station: place(to), arrival: utc(arrival), departure: null }] });
const transfer = crs => ({ kind: 'transfer', mode: 'interchange', from: place(crs), to: place(crs),
    departure: utc('12:20'), arrival: utc('12:25'), transfer: { interchangeMinutes: 5 } });
const plan = legs => ({ result: { dataset: { version: 'v1', warnings: [] }, search: { searchTruncated: false }, pagination: {}, warnings: [],
    journeys: [{ id: 'original', departure: legs[0].departure, arrival: legs.at(-1).arrival, legs, changes: 1 }] },
    connections: { stations: ['ORG', 'MID', 'ALT', 'DST'].map(crs => ({ ...place(crs), minimumChangeMinutes: 5 })), rules: { tsi: [], links: [] } } });
const row = (id, departure, changes = {}) => ({ serviceID: id, serviceType: 'train', operator: 'Southern',
    departure_time: { scheduled: departure, estimated: departure }, platform: '2', isCancelled: false, ...changes });
const point = (crs, st, changes = {}) => ({ crs, st, et: 'On time', ...changes });

function fixture({ clock = now } = {}) {
    const boards = new Map(), records = new Map(), calls = { boards: [], details: [] };
    const board = (from, to, departures, changes = {}) => boards.set(`${from}:${to}`, { departures,
        dataStatus: 'live', lastSuccessfulUpdate: new Date(clock).toISOString(), siri: { providerObservedAt: new Date(clock).toISOString(),
            fetchedAt: new Date(clock).toISOString(), failureReason: null }, ...changes });
    const details = (station, id, departure, points, changes = {}) => records.set(`${station}:${id}`, {
        station, serviceID: id, generatedAt: new Date(clock).toISOString(), detail: { crs: station, std: departure,
            etd: 'On time', operatorCode: 'SN', subsequentCallingPoints: [{ callingPoint: points }], ...changes } });
    const helper = new SavedRouteLive({ now: () => clock,
        getDepartures: async (from, to, options) => {
            calls.boards.push({ from, to, options });
            const value = structuredClone(boards.get(`${from}:${to}`) ?? { departures: [], dataStatus: 'unavailable' });
            for (const departure of value.departures) departure.siri ??= { providerObservedAt: new Date(clock).toISOString(), requestedOffsetMinutes: 0 };
            return value;
        },
        provider: { async fetchDetails(refs, options) {
            calls.details.push({ refs, options });
            const selected = refs.filter(() => options.budget.used++ < options.budget.limit);
            return { details: selected.map(ref => structuredClone(records.get(`${ref.station}:${ref.serviceID}`))).filter(Boolean), errors: [] };
        } }
    });
    return { helper, board, details, calls, boards, records };
}

test('direct departures use the shared fresh pair lookup without detail requests', async () => {
    const f = fixture();
    f.board('ORG', 'DST', [row('D1', '12:05')]);
    const result = await f.helper.direct(request);
    assert.equal(result.status, 'available');
    assert.equal(result.snapshot.departures[0].serviceID, 'D1');
    assert.equal(result.snapshot.departures[0].siri, undefined);
    assert.equal(f.calls.boards[0].options.requireFresh, true);
    assert.equal(f.calls.details.length, 0);
    assert.equal(result.expiresAt, new Date(now + 60000).toISOString());
});

test('only successful fresh empty boards trigger fallback planning', async () => {
    const f = fixture();
    f.board('ORG', 'DST', []);
    assert.equal((await f.helper.direct(request)).status, 'empty');
    f.board('ORG', 'DST', [], { dataStatus: 'partial' });
    assert.equal((await f.helper.direct(request)).status, 'unknown');
    f.board('ORG', 'DST', [], { dataStatus: 'stale' });
    assert.equal((await f.helper.direct(request)).status, 'unknown');
    f.board('ORG', 'DST', [], { siri: { providerObservedAt: new Date(now - 61000).toISOString(), fetchedAt: new Date(now).toISOString() } });
    assert.equal((await f.helper.direct(request)).status, 'unknown');
});

test('cancelled direct rows remain visible while apply and ignore choose different fallback behavior', async () => {
    const f = fixture();
    f.board('ORG', 'DST', [row('C', '12:05', { isCancelled: true })]);
    const applied = await f.helper.direct(request);
    assert.equal(applied.status, 'empty');
    assert.equal(applied.snapshot.departures[0].isCancelled, true);
    assert.equal((await f.helper.direct({ ...request, realtime: 'ignore' })).status, 'available');
    f.board('ORG', 'DST', [row('LATE', '11:55', { departure_time: { scheduled: '11:55', estimated: 'Delayed' } })]);
    assert.equal((await f.helper.direct(request)).status, 'available', 'unknown delay does not silently remove a waiting train');
});

test('required vias stay in order on one through portion and cancelled required stops trigger fallback', async () => {
    const f = fixture(), query = { ...request, via: ['MID'] };
    f.board('ORG', 'DST', [row('VIA', '12:05')]);
    f.details('ORG', 'VIA', '12:05', [], { subsequentCallingPoints: [
        { callingPoint: [point('MID', '12:15'), point('ALT', '12:25')] },
        { callingPoint: [point('DST', '12:30')] }
    ] });
    assert.equal((await f.helper.direct(query)).status, 'empty', 'branches cannot be flattened into a through service');
    f.details('ORG', 'VIA', '12:05', [point('MID', '12:15'), point('DST', '12:30')]);
    assert.equal((await f.helper.direct(query)).status, 'available');
    f.details('ORG', 'VIA', '12:05', [point('MID', '12:15', { isCancelled: true }), point('DST', '12:30')]);
    const cancelled = await f.helper.direct(query);
    assert.equal(cancelled.status, 'empty');
    assert.equal(cancelled.snapshot.departures[0].isCancelled, true);
    assert.equal((await f.helper.direct({ ...query, realtime: 'ignore' })).status, 'available');
    f.records.clear();
    assert.equal((await f.helper.direct(query)).status, 'unknown');
});

test('cached route topology composes newly departing trains rather than only refreshing the original services', async () => {
    const f = fixture();
    const original = plan([leg('ORG', 'MID', '11:05', '11:20'), transfer('MID'), leg('MID', 'DST', '11:25', '11:45')]);
    f.board('ORG', 'MID', [row('NEW1', '12:05')]);
    f.details('ORG', 'NEW1', '12:05', [point('MID', '12:20')]);
    f.board('MID', 'DST', [row('NEW2', '12:25')]);
    f.details('MID', 'NEW2', '12:25', [point('DST', '12:45')]);
    const untouched = JSON.stringify(original);
    const result = await f.helper.refresh(original, request);
    assert.equal(result.journeys.length, 1);
    assert.equal(result.journeys[0].departure, utc('12:05'));
    assert.equal(result.journeys[0].arrival, utc('12:45'));
    assert.deepEqual(result.journeys[0].legs.filter(value => value.kind === 'vehicle').map(value => value.serviceId), ['live:ORG:NEW1', 'live:MID:NEW2']);
    assert.equal(result.live.status, 'live');
    assert.ok(result.journeys[0].id.startsWith('v1.'));
    assert.equal(result.journeys[0].legs[0].uid, undefined);
    assert.equal(result.journeys[0].legs[0].tracking, undefined);
    assert.equal(JSON.stringify(original), untouched);
});

test('live refresh retains planned departures beyond a shallow live board without duplicating matched trains', async () => {
    const f = fixture();
    const original = plan([leg('ORG', 'DST', '12:05', '12:25')]);
    original.result.journeys = [
        plan([leg('ORG', 'DST', '12:05', '12:25')]).result.journeys[0],
        plan([leg('ORG', 'DST', '12:35', '12:55')]).result.journeys[0],
        plan([leg('ORG', 'DST', '13:05', '13:25')]).result.journeys[0]
    ];
    f.board('ORG', 'DST', [row('FIRST', '12:05'), row('SECOND', '12:35')]);
    f.details('ORG', 'FIRST', '12:05', [point('DST', '12:25')]);
    f.details('ORG', 'SECOND', '12:35', [point('DST', '12:55')]);

    const result = await f.helper.refresh(original, request);

    assert.deepEqual(result.journeys.map(journey => journey.legs[0].serviceId),
        ['live:ORG:FIRST', 'live:ORG:SECOND', 'cached:ORG:13:05']);
    assert.match(result.journeys[2].warnings.join(' '), /scheduled times are shown/i);
});

test('same starting train and route keeps the earliest arrival without changing cached candidates', () => {
    const option = (departure, arrival) => plan([leg('ORG', 'MID', '12:05', '12:20'), transfer('MID'),
        leg('MID', 'DST', departure, arrival)]).result.journeys[0];
    const earlier = option('12:25', '12:45'), later = option('12:35', '12:55');
    const last = option('12:45', '13:05');
    const input = [last, earlier, later];
    const original = JSON.stringify(input);
    assert.deepEqual(earliestRouteJourneys(input), [earlier]);
    assert.equal(JSON.stringify(input), original);
    const otherTrain = structuredClone(later);
    otherTrain.legs[0].serviceId = 'another-train-at-the-same-time';
    const otherRoute = structuredClone(later);
    otherRoute.legs[2].callingPoints.splice(1, 0, { station: place('ALT'), arrival: utc('12:40') });
    const otherOperator = structuredClone(later);
    otherOperator.legs[2].operator = 'SE';
    const unknownTrain = structuredClone(later);
    delete unknownTrain.legs[0].serviceId;
    const nextDay = structuredClone(later);
    nextDay.departure = '2026-09-18T11:05:00Z';
    assert.deepEqual(earliestRouteJourneys([later, earlier, otherTrain, otherRoute, otherOperator, unknownTrain, nextDay]),
        [earlier, otherTrain, otherRoute, otherOperator, unknownTrain, nextDay]);
});

test('connection duplicates are removed before the result limit so later departures remain available', async () => {
    const f = fixture(), original = plan([leg('ORG', 'MID', '12:05', '12:20'), transfer('MID'), leg('MID', 'DST', '12:25', '12:45')]);
    f.board('ORG', 'MID', [row('FIRST', '12:05'), row('SECOND', '12:10'), row('THIRD', '12:15')]);
    for (const [id, departure] of [['FIRST', '12:05'], ['SECOND', '12:10'], ['THIRD', '12:15']]) {
        f.details('ORG', id, departure, [point('MID', '12:20')]);
    }
    f.board('MID', 'DST', [row('SOON', '12:25'), row('LATER', '12:35'), row('LAST', '12:45')]);
    for (const [id, departure, arrival] of [['SOON', '12:25', '12:45'], ['LATER', '12:35', '12:55'], ['LAST', '12:45', '13:05']]) {
        f.details('MID', id, departure, [point('DST', arrival)]);
    }
    const result = await f.helper.refresh(original, request);
    assert.equal(result.journeys.length, 3);
    assert.deepEqual(result.journeys.map(journey => journey.legs[0].serviceId), ['live:ORG:FIRST', 'live:ORG:SECOND', 'live:ORG:THIRD']);
    assert.ok(result.journeys.every(journey => journey.arrival === utc('12:45')));
    assert.equal(result.live.coverage.nearTermRailLegs, 4, 'Coverage describes only the displayed trains');
});

test('earliest connection follows live arrival or scheduled override and keeps disrupted options separate', async () => {
    const f = fixture(), original = plan([leg('ORG', 'MID', '12:05', '12:20'), transfer('MID'), leg('MID', 'DST', '12:25', '12:45')]);
    f.board('ORG', 'MID', [row('FIRST', '12:05')]);
    f.details('ORG', 'FIRST', '12:05', [point('MID', '12:20')]);
    f.board('MID', 'DST', [row('DELAYED', '12:25'), row('QUICKER', '12:35')]);
    f.details('MID', 'DELAYED', '12:25', [point('DST', '12:45', { et: '13:05' })]);
    f.details('MID', 'QUICKER', '12:35', [point('DST', '12:55')]);
    const live = await f.helper.refresh(original, request);
    assert.equal(live.journeys.length, 1);
    assert.equal(live.journeys[0].legs.at(-1).serviceId, 'live:MID:QUICKER');
    const ignored = await f.helper.refresh(original, { ...request, realtime: 'ignore' });
    assert.equal(ignored.journeys.length, 1);
    assert.equal(ignored.journeys[0].legs.at(-1).serviceId, 'live:MID:DELAYED');
    assert.equal(ignored.journeys[0].legs.at(-1).live.status, 'delayed');
    f.details('MID', 'DELAYED', '12:25', [point('DST', '12:45', { isCancelled: true })]);
    const cancelled = await f.helper.refresh(original, request);
    assert.equal(cancelled.journeys.length, 1);
    assert.equal(cancelled.journeys[0].legs.at(-1).serviceId, 'live:MID:QUICKER');
    assert.equal(cancelled.disruptedJourneys.length, 1);
});

test('missed connections use the next valid train; ignore preserves scheduled connection with a warning', async () => {
    const f = fixture(), original = plan([leg('ORG', 'MID', '12:05', '12:20'), transfer('MID'), leg('MID', 'DST', '12:25', '12:45')]);
    f.board('ORG', 'MID', [row('FEEDER', '12:05')]);
    f.details('ORG', 'FEEDER', '12:05', [point('MID', '12:20', { et: '12:24' })]);
    f.board('MID', 'DST', [row('EARLY', '12:25'), row('NEXT', '12:35')]);
    f.details('MID', 'EARLY', '12:25', [point('DST', '12:45')]);
    f.details('MID', 'NEXT', '12:35', [point('DST', '12:55')]);
    const result = await f.helper.refresh(original, request);
    assert.equal(result.journeys.length, 1);
    assert.equal(result.journeys[0].legs.at(-1).serviceId, 'live:MID:NEXT');
    const ignored = await f.helper.refresh(original, { ...request, realtime: 'ignore' });
    assert.equal(ignored.journeys[0].legs.at(-1).serviceId, 'live:MID:EARLY');
    assert.match(ignored.journeys[0].warnings.join(' '), /no longer allow this connection/);
    original.connections.stations.find(value => value.crs === 'MID').minimumChangeMinutes = undefined;
    assert.equal((await f.helper.refresh(original, request)).journeys.length, 0, 'missing connection allowances are never guessed');
});

test('refresh preserves through-portion isolation and never routes through a cancelled required via', async () => {
    const f = fixture(), original = plan([leg('ORG', 'DST', '12:05', '12:40')]);
    f.board('ORG', 'DST', [row('PORTION', '12:05')]);
    f.details('ORG', 'PORTION', '12:05', [], { subsequentCallingPoints: [
        { callingPoint: [point('MID', '12:20')] }, { callingPoint: [point('DST', '12:40')] }
    ] });
    assert.equal((await f.helper.refresh(original, { ...request, via: ['MID'] })).journeys.length, 0);
    f.details('ORG', 'PORTION', '12:05', [point('MID', '12:20', { isCancelled: true }), point('DST', '12:40')]);
    assert.equal((await f.helper.refresh(original, { ...request, via: ['MID'] })).journeys.length, 0);
    assert.equal((await f.helper.refresh(original, { ...request, via: ['MID'], realtime: 'ignore' })).journeys.length, 1);
});

test('overnight live calls retain the next day and later scheduled legs need no live lookup', async () => {
    const clock = Date.parse('2026-09-17T22:40:00Z'), f = fixture({ clock });
    const original = plan([leg('ORG', 'MID', '23:45', '23:59'), transfer('MID'), {
        ...leg('MID', 'DST', '06:00', '07:00'), departure: '2026-09-18T05:00:00Z', arrival: '2026-09-18T06:00:00Z'
    }]);
    f.board('ORG', 'MID', [row('NIGHT', '23:45')]);
    f.details('ORG', 'NIGHT', '23:45', [point('MID', '00:10')]);
    const result = await f.helper.refresh(original, request);
    assert.equal(result.journeys.length, 1);
    assert.equal(result.journeys[0].legs[0].arrival, '2026-09-17T23:10:00.000Z');
    assert.equal(result.journeys[0].arrival, '2026-09-18T06:00:00Z');
    assert.deepEqual(f.calls.boards.map(value => `${value.from}:${value.to}`), ['ORG:MID']);
    assert.equal(result.live.coverage.scheduledLaterRailLegs, 1);
});

test('fresh cancellations become disrupted options and outages retain scheduled options honestly', async () => {
    const f = fixture(), original = plan([leg('ORG', 'DST', '12:05', '12:25')]);
    f.board('ORG', 'DST', [row('CANCELLED', '12:05', { isCancelled: true })]);
    f.details('ORG', 'CANCELLED', '12:05', [point('DST', '12:25')]);
    const applied = await f.helper.refresh(original, request);
    assert.equal(applied.journeys.length, 0);
    assert.equal(applied.disruptedJourneys.length, 1);
    assert.equal(applied.disruptedJourneys[0].legs[0].live.cancelled, true);
    assert.equal((await f.helper.refresh(original, { ...request, realtime: 'ignore' })).journeys.length, 1);
    f.board('ORG', 'DST', [], { dataStatus: 'unavailable' });
    const fallback = await f.helper.refresh(original, request);
    assert.equal(fallback.journeys.length, 1);
    assert.equal(fallback.journeys[0].legs[0].live, undefined);
    assert.equal(fallback.live.status, 'unavailable');
});

test('cancellation is propagated before issuing live requests', async () => {
    const f = fixture(), controller = new AbortController();
    controller.abort();
    await assert.rejects(f.helper.direct(request, { signal: controller.signal }), { code: 'SEARCH_CANCELLED' });
    assert.equal(f.calls.boards.length, 0);
});

test('ignore mode orders departures by timetable and allowed modes apply to direct and composed options', async () => {
    const f = fixture();
    f.board('ORG', 'DST', [row('LATE', '12:05', { departure_time: { scheduled: '12:05', estimated: '12:50' } }),
        row('NEXT', '12:10'), row('BUS', '12:02', { serviceType: 'bus' })]);
    assert.deepEqual((await f.helper.direct({ ...request, realtime: 'ignore', allowedModes: ['rail'] })).snapshot.departures.map(value => value.serviceID), ['LATE', 'NEXT']);
    assert.deepEqual((await f.helper.direct({ ...request, allowedModes: ['rail'] })).snapshot.departures.map(value => value.serviceID), ['NEXT', 'LATE']);
    f.details('ORG', 'BUS', '12:02', [point('DST', '12:22')]);
    f.details('ORG', 'LATE', '12:05', [point('DST', '12:25', { et: '13:10' })]);
    f.details('ORG', 'NEXT', '12:10', [point('DST', '12:30')]);
    const value = await f.helper.refresh(plan([leg('ORG', 'DST', '11:00', '11:20')]), { ...request, allowedModes: ['replacementBus'] });
    assert.equal(value.journeys.length, 1);
    assert.equal(value.journeys[0].legs[0].mode, 'replacementBus');
});

test('unknown live delay cannot establish a feasible connection while ignore retains the uncertainty warning', async () => {
    const f = fixture(), original = plan([leg('ORG', 'MID', '12:05', '12:20'), transfer('MID'), leg('MID', 'DST', '12:25', '12:45')]);
    f.board('ORG', 'MID', [row('UNKNOWN', '12:05')]);
    f.details('ORG', 'UNKNOWN', '12:05', [point('MID', '12:20', { et: 'Delayed' })]);
    f.board('MID', 'DST', [row('CONNECT', '12:25')]);
    f.details('MID', 'CONNECT', '12:25', [point('DST', '12:45')]);
    const applied = await f.helper.refresh(original, request);
    assert.equal(applied.journeys.length, 0);
    assert.equal(applied.disruptedJourneys.length, 1);
    assert.equal(applied.live.status, 'partial');
    const ignored = await f.helper.refresh(original, { ...request, realtime: 'ignore' });
    assert.equal(ignored.journeys.length, 1);
    assert.match(ignored.journeys[0].warnings.join(' '), /not confirmed/);
    assert.ok(!ignored.journeys[0].warnings.some(value => /no longer allow/.test(value)));
});

test('composition stays within 24 hours and live dataset metadata includes disrupted observations', async () => {
    const f = fixture(), original = plan([leg('ORG', 'MID', '12:05', '12:20'), transfer('MID'), {
        ...leg('MID', 'DST', '13:00', '14:00'), departure: '2026-09-18T12:00:00Z', arrival: '2026-09-18T13:00:00Z'
    }]);
    f.board('ORG', 'MID', [row('FIRST', '12:05')]);
    f.details('ORG', 'FIRST', '12:05', [point('MID', '12:20')]);
    assert.equal((await f.helper.refresh(original, request)).journeys.length, 0);
    f.board('ORG', 'DST', [row('CANCEL', '12:05', { isCancelled: true })]);
    f.details('ORG', 'CANCEL', '12:05', [point('DST', '12:25')]);
    const directPlan = plan([leg('ORG', 'DST', '12:05', '12:25')]);
    directPlan.result.dataset = { version: 'v1', scheduledOnly: true, warnings: ['Scheduled timetable only. Live delays and changes are not included.'] };
    const cancelled = await f.helper.refresh(directPlan, request);
    assert.equal(cancelled.live.status, 'live');
    assert.equal(cancelled.dataset.scheduledOnly, false);
    assert.deepEqual(cancelled.dataset.warnings, []);
    assert.equal(cancelled.live.coverage.confirmedRailLegs, 1);
});

test('required-via checking detects destination and associated-portion cancellation', async () => {
    const f = fixture(), query = { ...request, via: ['MID'] };
    f.board('ORG', 'DST', [row('PART', '12:05')]);
    f.details('ORG', 'PART', '12:05', [point('MID', '12:15'), point('DST', '12:30', { isCancelled: true })]);
    assert.equal((await f.helper.direct(query)).status, 'empty');
    f.details('ORG', 'PART', '12:05', [], { subsequentCallingPoints: [
        { assocIsCancelled: true, callingPoint: [point('MID', '12:15'), point('DST', '12:30')] }
    ] });
    assert.equal((await f.helper.direct(query)).status, 'empty');
    assert.equal((await f.helper.direct({ ...query, realtime: 'ignore' })).status, 'available');
    f.details('ORG', 'PART', '12:06', [point('MID', '12:15'), point('DST', '12:30')]);
    assert.equal((await f.helper.direct(query)).status, 'unknown', 'reused or mismatched IDs are not route evidence');
});

test('bounded live choices mark partial search coverage and expiry uses the oldest relevant observation', async () => {
    const f = fixture();
    const rows = Array.from({ length: 10 }, (_, index) => row(`T${index}`, `12:${String(index + 1).padStart(2, '0')}`));
    f.board('ORG', 'DST', rows);
    for (const item of rows) f.details('ORG', item.serviceID, item.departure_time.scheduled, [point('MID', '12:20'), point('DST', '12:40')]);
    const result = await f.helper.refresh(plan([leg('ORG', 'DST', '11:00', '11:30')]), request);
    assert.equal(f.calls.details.length, 8);
    assert.equal(result.search.searchTruncated, true);
    f.board('ORG', 'DST', rows.slice(0, 1));
    f.records.get('ORG:T0').generatedAt = new Date(now - 55000).toISOString();
    assert.equal((await f.helper.direct({ ...request, via: ['MID'] })).expiresAt, new Date(now + 5000).toISOString());
});

test('live legs retain the entire selected passenger branch for independent tracking verification', async () => {
    const f = fixture(), original = plan([leg('ORG', 'DST', '12:05', '12:30')]);
    f.board('ORG', 'DST', [row('THROUGH', '12:05')]);
    f.details('ORG', 'THROUGH', '12:05', [], { previousCallingPoints: [
        { callingPoint: [point('BEF', '11:45'), point('PRE', '11:55')] },
        { callingPoint: [point('JON', '11:50')] }
    ], subsequentCallingPoints: [
        { callingPoint: [point('MID', '12:15'), point('DST', '12:30'), point('END', '12:45')] },
        { callingPoint: [point('MID', '12:15'), point('ALT', '12:35')] }
    ] });
    const result = await f.helper.refresh(original, request), actual = result.journeys[0].legs[0];
    assert.deepEqual(actual.callingPoints.map(call => call.station.crs), ['ORG', 'MID', 'DST']);
    assert.deepEqual(actual.serviceCallingPoints.map(call => [call.station.crs, call.departure ?? call.arrival]), [
        ['BEF', utc('11:45')], ['PRE', utc('11:55')], ['ORG', utc('12:05')], ['MID', utc('12:15')],
        ['DST', utc('12:30')], ['END', utc('12:45')]
    ]);
    assert.equal(actual.uid, undefined);
    assert.equal(actual.tracking, undefined);
});

test('full branch dates span midnight in both directions and malformed outside-section times cannot enable tracking', async () => {
    const f = fixture({ clock: Date.parse('2026-09-17T23:00:00Z') });
    const original = plan([{ ...leg('ORG', 'DST', '00:05', '00:30'), departure: '2026-09-17T23:05:00Z', arrival: '2026-09-17T23:30:00Z' }]);
    f.board('ORG', 'DST', [row('NIGHT', '00:05')]);
    f.details('ORG', 'NIGHT', '00:05', [point('DST', '00:30'), point('END', '01:00')], {
        previousCallingPoints: [{ callingPoint: [point('BEF', '23:45')] }]
    });
    let actual = (await f.helper.refresh(original, request)).journeys[0].legs[0];
    assert.deepEqual(actual.serviceCallingPoints.map(call => call.departure ?? call.arrival), [
        '2026-09-17T22:45:00.000Z', '2026-09-17T23:05:00.000Z', '2026-09-17T23:30:00.000Z', '2026-09-18T00:00:00.000Z'
    ]);
    f.records.get('ORG:NIGHT').detail.subsequentCallingPoints[0].callingPoint.at(-1).st = 'Unknown';
    actual = (await f.helper.refresh(original, request)).journeys[0].legs[0];
    assert.equal(actual.serviceCallingPoints, undefined);
    assert.equal(actual.callingPoints.length, 2, 'valid ridden section remains available');
});
