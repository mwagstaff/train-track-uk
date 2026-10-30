import test from 'node:test';
import assert from 'node:assert/strict';
import { PlannerLiveProvider, createLiveRequestBudget } from '../lib/planner/live-provider.js';
import { SavedRouteLive } from '../lib/planner/saved-route-live.js';

const now = Date.parse('2026-10-30T16:05:00Z');
const serviceID = 'staff_202610308088396_VIC_20261030T161200_P';
const raw = () => ({ crs: 'VIC', generatedAt: new Date(now).toISOString(), trainServices: [{
    rid: '202610308088396', std: '2026-10-30T16:12:00', etd: '2026-10-30T16:12:00',
    departureType: 'Forecast', operatorCode: 'SE', platform: '3', length: 8,
    destination: [{ crs: 'ORP', locationName: 'Orpington' }],
    subsequentLocations: [{ crs: 'KTH', sta: '2026-10-30T16:32:00', eta: '2026-10-30T16:32:00', arrivalType: 'Forecast' }]
}] });
function fixture(response = raw()) {
    const calls = [];
    const provider = new PlannerLiveProvider({ now: () => now, credentials: () => ({ staff: 'staff-test' }),
        request: async options => { calls.push(options); return { data: response }; } });
    return { provider, calls };
}

test('staff details select exact dated service through bounded staff lookup and cache', async () => {
    const { provider, calls } = fixture();
    const budget = createLiveRequestBudget(1);
    const refs = [{ station: 'VIC', serviceID }];
    const result = await provider.fetchDetails(refs, { budget });
    assert.equal(result.details.length, 1);
    assert.equal(result.details[0].detail.length, 8);
    assert.equal(result.details[0].detail.platform, '3');
    assert.equal(result.details[0].detail.subsequentCallingPoints[0].callingPoint[0].crs, 'KTH');
    assert.match(calls[0].url, /GetDepBoardWithDetails\/VIC\/20261030T161200\?numRows=149&timeWindow=2&services=P$/);
    assert.equal(calls[0].headers['x-apikey'], 'staff-test');
    assert.equal(calls[0].api, 'rail_staff_departure_board');
    assert.equal(budget.used, 1);
    assert.deepEqual((await provider.fetchDetails(refs, { budget })).details, result.details);
    assert.equal(calls.length, 1);
});

test('staff details never substitute neighbouring trains or bypass request limits', async () => {
    const { provider, calls } = fixture();
    const refs = [{ station: 'VIC', serviceID: serviceID.replace('8088396', '8088397') }];
    assert.equal((await provider.fetchDetails(refs, { budget: createLiveRequestBudget(0) })).limited, true);
    assert.equal(calls.length, 0);
    const result = await provider.fetchDetails(refs);
    assert.equal(result.details.length, 0);
    assert.equal(result.errors[0].reason, 'unavailable');
    await assert.rejects(provider.fetchDetails([{ station: 'KTH', serviceID }]), /Invalid staff service reference/);
});

test('More departures preserves live length, platform and timing for staff-fed trains', async () => {
    const { provider } = fixture();
    const observed = new Date(now).toISOString();
    const live = new SavedRouteLive({ provider, now: () => now, getDepartures: async () => ({
        dataStatus: 'live', siri: { providerObservedAt: observed, fetchedAt: observed },
        departures: [{ serviceID, serviceType: 'train', platform: '3', length: 8,
            departure_time: { scheduled: '16:12', estimated: '16:12' },
            siri: { providerObservedAt: observed, requestedOffsetMinutes: 0 } }]
    }) });
    const departure = '2026-10-30T16:12:00.000Z', arrival = '2026-10-30T16:32:00.000Z';
    const plan = { result: { dataset: { version: 'test', warnings: [] },
        search: { window: { from: observed, to: '2026-10-30T22:05:00.000Z' } },
        journeys: [{ id: 'scheduled', departure, arrival, changes: 0, legs: [{
            kind: 'vehicle', mode: 'rail', from: { crs: 'VIC' }, to: { crs: 'KTH' },
            departure, arrival, serviceId: 'timetable-id'
        }] }] }, connections: { stations: [], rules: { tsi: [], links: [] } } };
    const result = await live.refresh(plan, { origin: 'VIC', destination: 'KTH', time: observed, realtime: 'apply' }, { timeLocked: true });
    assert.equal(result.journeys.length, 1);
    const evidence = result.journeys[0].legs[0].live;
    assert.equal(evidence.length, 8);
    assert.equal(evidence.platform, '3');
    assert.equal(evidence.status, 'onTime');
    assert.equal(result.live.coverage.confirmedRailLegs, 1);
});
