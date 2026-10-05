import assert from 'node:assert/strict';
import { mock, test } from 'node:test';
import axios from 'axios';

let upstream;
const client = mock.method(axios, 'create', () => ({ get: (...args) => upstream(...args) }));
const { getTrainTimes } = await import('../lib/realtime-trains-api.js');
const { staffDepartures } = await import('../lib/staff-departures.js');
const { recentDeparturesRepository } = await import('../lib/recent-departures-repository.js');
client.mock.restore();

function service(serviceID, operator, operatorCode) {
    return { serviceID, operator, operatorCode, std: '12:00', etd: '12:04', platform: '2',
        isCancelled: false, origin: [{ crs: 'ORP', locationName: 'Orpington' }],
        destination: [{ crs: 'VIC', locationName: 'London Victoria' }] };
}

test('station boards include every operator, deduplicate windows and reuse the cache without persisting a journey', async t => {
    t.mock.getter(staffDepartures, 'enabled', () => false);
    const persist = t.mock.method(recentDeparturesRepository, 'recordDepartures', async () => {});
    const urls = [];
    upstream = async url => {
        urls.push(new URL(url));
        return { data: { generatedAt: new Date().toISOString(), trainServices: [
            service('se-1', 'Southeastern', 'SE'), service('tl-1', 'Thameslink', 'TL')
        ] } };
    };
    const result = await getTrainTimes('KTH');
    assert.equal(result.dataStatus, 'live');
    assert.deepEqual(result.departures.map(d => d.operator), ['Southeastern', 'Thameslink']);
    assert.equal(result.departures[0].operatorCode, 'SE');
    assert.equal(result.departures[0].platform, '2');
    assert.equal(result.departures[0].departure_time.estimated, '12:04');
    assert.equal(result.departures[0].destination.crs, 'VIC');
    assert.equal(urls.length, 2);
    assert.deepEqual(urls.map(url => url.searchParams.get('timeOffset')), ['0', '119']);
    for (const url of urls) {
        assert.equal(url.searchParams.has('filterCrs'), false);
        assert.equal(url.searchParams.get('numRows'), '149');
    }
    assert.deepEqual(await getTrainTimes('KTH'), result);
    assert.equal(urls.length, 2);
    assert.equal(persist.mock.callCount(), 0);
});

test('station boards use staff data without a destination filter', async t => {
    t.mock.getter(staffDepartures, 'enabled', () => true);
    const calls = [];
    t.mock.method(staffDepartures, 'getBoard', async (from, to, offset) => {
        calls.push({ from, to, offset });
        return { generatedAt: new Date().toISOString(), trainServices: [service('staff-1', 'Southeastern', 'SE')] };
    });
    const result = await getTrainTimes('BKH');
    assert.equal(result.dataStatus, 'live');
    assert.equal(result.departures.length, 1);
    assert.deepEqual(calls, [{ from: 'BKH', to: undefined, offset: 0 }, { from: 'BKH', to: undefined, offset: 119 }]);
});

test('station provider failures remain unavailable rather than an apparently empty live board', async t => {
    t.mock.getter(staffDepartures, 'enabled', () => false);
    upstream = async () => { throw Object.assign(new Error('Forbidden'), { response: { status: 403 } }); };
    const result = await getTrainTimes('EUS');
    assert.equal(result.dataStatus, 'unavailable');
    assert.deepEqual(result.departures, []);
    assert.equal(result.lastSuccessfulUpdate, null);
});

test('journey-pair requests retain their destination filter and persistence', async t => {
    t.mock.getter(staffDepartures, 'enabled', () => false);
    const persist = t.mock.method(recentDeparturesRepository, 'recordDepartures', async () => {});
    upstream = async url => {
        assert.equal(new URL(url).searchParams.get('filterCrs'), 'VIC');
        return { data: { generatedAt: new Date().toISOString(), trainServices: [service('pair-1', 'Southeastern', 'SE')] } };
    };
    const result = await getTrainTimes('KTH', 'VIC');
    assert.equal(result.dataStatus, 'live');
    assert.equal(result.departures.length, 1);
    assert.equal(persist.mock.callCount(), 1);
    assert.deepEqual(persist.mock.calls[0].arguments.slice(0, 2), ['KTH', 'VIC']);
});
