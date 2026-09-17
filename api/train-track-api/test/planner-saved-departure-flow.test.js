import test from 'node:test';
import assert from 'node:assert/strict';
import { SavedRouteBoards } from '../lib/planner/saved-route-boards.js';
import { SavedRouteLive } from '../lib/planner/saved-route-live.js';

test('saved departures plan once, reuse the route for new live trains, then return to direct departures', async t => {
    let now = Date.parse('2026-09-17T11:00:00Z'), phase = 0, calculations = 0;
    const station = crs => ({ crs, name: crs, minimumChangeMinutes: 5 });
    const time = minutes => new Date(now + minutes * 60000).toISOString();
    const clock = minutes => new Date(now + (minutes + 60) * 60000).toISOString().slice(11, 16);
    const trains = () => [
        { from: 'ORG', to: 'MID', id: `first-${phase}`, departure: 5, arrival: 20 },
        { from: 'MID', to: 'DST', id: `second-${phase}`, departure: 25, arrival: 45 },
        ...(phase === 2 ? [{ from: 'ORG', to: 'DST', id: 'through', departure: 6, arrival: 40 }] : [])
    ];
    const live = new SavedRouteLive({ now: () => now,
        getDepartures: async (from, to) => ({ dataStatus: 'live', lastSuccessfulUpdate: time(0),
            siri: { providerObservedAt: time(0), fetchedAt: time(0) },
            departures: trains().filter(train => train.from === from && train.to === to).map(train => ({
                serviceID: train.id, operator: 'Southern', serviceType: 'train', platform: '2',
                departure_time: { scheduled: clock(train.departure), estimated: 'On time' },
                siri: { providerObservedAt: time(0), requestedOffsetMinutes: 0 }
            })) }),
        provider: { fetchDetails: async refs => ({ details: refs.map(ref => {
            const train = trains().find(train => train.id === ref.serviceID);
            return { station: ref.station, serviceID: train.id, generatedAt: time(0),
                detail: { crs: train.from, std: clock(train.departure), operatorCode: 'SN',
                    subsequentCallingPoints: [{ callingPoint: [
                        ...(train.id === 'through' ? [{ crs: 'MID', st: clock(20), et: 'On time' }] : []),
                        { crs: train.to, st: clock(train.arrival), et: 'On time' }
                    ] }] } };
        }) }) }
    });
    const records = new Map(), retained = new Map();
    const cache = { get: async key => records.get(key), set: async (key, value) => records.set(key, value) };
    const service = {
        status: async () => ({ available: true, dataset: { version: 'a'.repeat(64) } }),
        retainResult: result => result.journeys.forEach(journey => retained.set(journey.id, journey)),
        call: async (method, payload) => {
            calculations++;
            assert.equal(method, 'savedRoutePlan');
            assert.deepEqual(payload.request.via, ['MID']);
            const vehicle = (from, to, departure, arrival) => ({ kind: 'vehicle', mode: 'rail', operator: 'SN',
                from: station(from), to: station(to), departure: time(departure), arrival: time(arrival),
                serviceId: `scheduled-${from}`, callingPoints: [
                    { station: station(from), departure: time(departure) }, { station: station(to), arrival: time(arrival) }
                ] });
            const legs = [vehicle('ORG', 'MID', 5, 20), { kind: 'transfer', mode: 'interchange',
                from: station('MID'), to: station('MID'), departure: time(20), arrival: time(25) }, vehicle('MID', 'DST', 25, 45)];
            return { result: { dataset: { version: payload.version, warnings: [], scheduledOnly: true },
                search: payload.request, pagination: {}, warnings: [],
                journeys: [{ id: 'scheduled', departure: time(5), arrival: time(45), changes: 1, legs }] },
            connections: { stations: ['ORG', 'MID', 'DST'].map(station), rules: { tsi: [], links: [] } } };
        }
    };
    const manager = new SavedRouteBoards(service, { live, cache, now: () => now });
    t.after(() => manager.close());
    const body = { routes: [{ id: 'saved', origin: 'ORG', destination: 'DST', via: ['MID'] }] };
    async function board(client = 'first') {
        await manager.get(body, { client });
        for (let i = 0; i < 100 && (manager.active || manager.activeLive.size || manager.liveQueue.length); i++) {
            await new Promise(resolve => setImmediate(resolve));
        }
        assert.equal(manager.activeLive.size, 0);
        return (await manager.get(body, { client })).boards[0];
    }
    const first = await board();
    assert.equal(first.status, 'ready');
    assert.equal(first.source, 'planned');
    assert.equal(first.result.journeys[0].legs[0].serviceId, 'live:ORG:first-0');
    assert.equal(calculations, 1);
    assert.equal(records.size, 1);

    // Another client arrives after the original first train has departed. The
    // same topology now supplies different services without a routing call.
    phase = 1;
    now += 10 * 60000;
    const refreshed = await board('second');
    assert.equal(calculations, 1);
    assert.equal(refreshed.result.journeys[0].legs[0].serviceId, 'live:ORG:first-1');
    assert.equal(refreshed.result.journeys[0].departure, time(5));
    assert.equal(refreshed.result.live.status, 'live');
    assert.ok(retained.has(refreshed.result.journeys[0].id), 'refreshed details are available to the app');

    // A through train calling at the saved required stop takes the quick path.
    phase = 2;
    now += 31000;
    const direct = await board();
    assert.equal(direct.source, 'direct');
    assert.equal(direct.direct.departures[0].serviceID, 'through');
    assert.equal(direct.result, undefined);
    assert.equal(calculations, 1);
});
