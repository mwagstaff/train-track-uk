import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import { StaffDepartures, normalizeStaffDepartureBoard, staffServiceReference, parseStaffServiceReference, staffDepartures } from '../lib/staff-departures.js';
import { parseResponseDataLiveDepartureBoard } from '../lib/realtime-trains-api.js';
import { getServiceDetailsWithContext } from '../lib/service-details.js';

const captured = JSON.parse(fs.readFileSync(new URL('./fixtures/brighton-short-terminations.json', import.meta.url)));
const context = { station: 'ECR', destination: 'BTN' };
const firstID = 'staff_202609266702771_ECR_20260926T235200_P';
const secondID = 'staff_202609268745509_ECR_20260927T002800_P';

function fixture() { return structuredClone(captured); }
function responseFor(url, board = fixture()) {
    if (new URL(url).searchParams.get('services') === 'B') return { data: { ...board, trainServices: undefined, busServices: [] } };
    return { data: board };
}

test('captured overnight departures retain destination cancellations and usable calling points', async () => {
    const result = normalizeStaffDepartureBoard(fixture(), context);
    const parsed = await parseResponseDataLiveDepartureBoard(result.board);
    assert.deepEqual(parsed.departures.map(s => s.serviceID), [firstID, secondID]);
    for (const departure of parsed.departures) {
        assert.equal(departure.isCancelled, false);
        assert.equal(departure.filterLocationCancelled, true);
        assert.equal(departure.filterCRS, 'BTN');
        assert.equal(departure.filterLocationName, 'Brighton');
        const details = result.details.get(departure.serviceID);
        const calls = details.subsequentCallingPoints[0].callingPoint;
        assert.equal(calls.at(-1).crs, 'BTN');
        assert.equal(calls.at(-1).isCancelled, true);
        assert.equal(calls.at(-1).et, 'Cancelled');
        assert.equal(calls.some(c => c.locationName === 'BALCMTJ'), false);
    }
    assert.equal(parsed.departures[0].destination.crs, 'HHE');
    assert.equal(parsed.departures[1].destination.crs, 'TBD');
});

test('staff-first board primes the map cache without any service-detail request', async () => {
    let now = Date.parse(captured.generatedAt);
    const calls = [];
    const provider = new StaffDepartures({ now: () => now, credentials: () => 'test', request: async ({ url }) => {
        calls.push(url); return responseFor(url);
    } });
    await provider.getBoard('ECR', 'BTN', 0);
    assert.equal(calls.length, 2); // trains and replacement buses
    assert.ok(calls.every(url => url.includes('GetDepBoardWithDetails/ECR/20260927T014006')));
    assert.equal((await provider.getDetails(firstID)).subsequentCallingPoints[0].callingPoint.at(-1).crs, 'BTN');
    assert.equal(calls.length, 2);
    now += 31_000;
    const [first, same] = await Promise.all([provider.getDetails(firstID), provider.getDetails(firstID)]);
    assert.deepEqual(first, same);
    assert.equal(calls.length, 3);
    assert.ok(calls[2].includes('/ECR/20260926T235200?'));
    assert.ok(calls[2].includes('timeWindow=2'));
});

test('a cold cache recovers by exact dated reference and never chooses a neighbouring service', async () => {
    const provider = new StaffDepartures({ credentials: () => 'test', request: async ({url}) => responseFor(url) });
    const details = await provider.getDetails(secondID);
    assert.equal(details.std, '00:28');
    assert.equal(details.subsequentCallingPoints[0].callingPoint.find(p => p.crs === 'HHE').isCancelled, true);
    const absent = await provider.getDetails(secondID.replace('20260927T002800', '20260928T002800'));
    assert.equal(absent.unavailable, true);
    assert.equal((await provider.getDetails('staff_invalid')).unavailable, true);
    assert.equal(parseStaffServiceReference('9121839ECROYDN_'), null);
});

test('staff unavailable is distinct from a transport/provider error', async () => {
    const provider = new StaffDepartures({ credentials: () => 'test', request: async () => { throw new Error('HTTP 500'); } });
    assert.deepEqual(await provider.getDetails(firstID), { error: 'Staff service lookup failed' });
    await assert.rejects(provider.getBoard('ECR', 'BTN', 0));
});

test('hidden platforms, suppressed services and unknown forecasts are not published as live facts', async () => {
    const raw = fixture();
    const service = raw.trainServices[0];
    service.platformIsHidden = true;
    service.departureType = 'NoLog';
    service.etd = service.std; // placeholder is NOT an on-time forecast
    service.subsequentLocations.find(l => l.crs === 'GTW').platformIsHidden = true;
    raw.trainServices[1].serviceIsSupressed = true;
    const result = normalizeStaffDepartureBoard(raw, context);
    const parsed = await parseResponseDataLiveDepartureBoard(result.board);
    assert.equal(parsed.departures.length, 1);
    assert.equal(parsed.departures[0].platform, undefined);
    assert.equal(parsed.departures[0].platformIsHidden, true);
    assert.equal(parsed.departures[0].departure_time.estimated, 'Delayed');
    assert.equal(result.details.get(firstID).subsequentCallingPoints[0].callingPoint.find(p => p.crs === 'GTW').platform, undefined);
});

test('actual timestamps are preserved; unknown and cancelled forecasts do not look on time', () => {
    const raw = fixture();
    raw.trainServices[0].departureType = 'Actual';
    raw.trainServices[0].atd = '2026-09-27T02:02:30';
    raw.trainServices[0].atdSpecified = true;
    raw.trainServices[1].isCancelled = true;
    const result = normalizeStaffDepartureBoard(raw, context);
    assert.equal(result.board.trainServices[0].atd, '02:02');
    assert.equal(result.board.trainServices[1].etd, 'Cancelled');
});

test('reject incomplete, wrongly filtered and unrepresented split boards so public fallback can run', () => {
    for (const change of [{ isTruncated: true }, { servicesAreUnavailable: true }, { crs: 'VIC' }, { filtercrs: 'HHE' }]) {
        assert.throws(() => normalizeStaffDepartureBoard({ ...fixture(), ...change }, context));
    }
    const split = fixture();
    split.trainServices[0].destination.push({ crs: 'LIT', locationName: 'Littlehampton' });
    assert.throws(() => normalizeStaffDepartureBoard(split, context), /branches/);
    // An unrelated split train must not break a selected train's direct refresh.
    const selected = normalizeStaffDepartureBoard(split, { station: 'ECR', serviceID: secondID });
    assert.deepEqual([...selected.details.keys()], [secondID]);
});

test('replacement bus query is included and its failure cannot silently hide buses', async () => {
    const busBoard = fixture();
    busBoard.busServices = [busBoard.trainServices[0]];
    delete busBoard.trainServices;
    const result = normalizeStaffDepartureBoard(busBoard, { ...context, type: 'B' });
    assert.equal(result.board.busServices[0].serviceType, 'bus');
    assert.equal(staffServiceReference(busBoard.busServices[0], 'ECR', 'B'), firstID.replace(/P$/, 'B'));
    const provider = new StaffDepartures({ credentials: () => 'test', request: async ({url}) => {
        if (new URL(url).searchParams.get('services') === 'B') throw new Error('bus query failed');
        return responseFor(url);
    } });
    await assert.rejects(provider.getBoard('ECR', 'BTN', 0), /bus query failed/);
});

test('public fallback also preserves the destination-specific cancellation flag', async () => {
    const result = await parseResponseDataLiveDepartureBoard({ filtercrs: 'BTN', filterLocationName: 'Brighton', trainServices: [{
        std: '23:52', etd: '01:53', origin: [{ crs: 'BDM' }], destination: [{ crs: 'HHE' }],
        serviceID: '9095985ECROYDN_', isCancelled: false, filterLocationCancelled: true
    }] });
    assert.equal(result.departures[0].filterLocationCancelled, true);
    assert.equal(result.departures[0].filterCRS, 'BTN');
    assert.equal(result.departures[0].isCancelled, false);
});

test('existing service-details API dispatch serves a staff reference from the board cache', async () => {
    const raw = fixture();
    raw.generatedAt = new Date().toISOString();
    const result = normalizeStaffDepartureBoard(raw, context);
    staffDepartures.remember(result.details);
    const details = await getServiceDetailsWithContext(firstID, { fromCRS: 'ECR', toCRS: 'BTN' });
    assert.equal(details.crs, 'ECR');
    assert.equal(details.subsequentCallingPoints[0].callingPoint.at(-1).isCancelled, true);
});
