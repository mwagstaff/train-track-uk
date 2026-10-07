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

test('busy station boards retain intervening trains even when the ten-row staff provider is enabled', async t => {
    t.mock.getter(staffDepartures, 'enabled', () => true);
    const servicesFor = offset => Array.from({ length: 60 }, (_, index) => {
        const minute = offset + index * 2;
        const time = `${12 + Math.floor(minute / 60)}:${String(minute % 60).padStart(2, '0')}`;
        return { ...service(`wat-${minute}`, 'South Western Railway', 'SW'), std: time, etd: time };
    });
    // WithDetails silently caps each two-hour window at ten rows. The old path
    // therefore jumped from 12:18 to 13:59 and lost all intervening departures.
    const staff = t.mock.method(staffDepartures, 'getBoard', async (from, to, offset) => ({
        generatedAt: new Date().toISOString(), trainServices: servicesFor(offset).slice(0, 10)
    }));
    const urls = [];
    upstream = async url => {
        const request = new URL(url);
        urls.push(request);
        return { data: { generatedAt: new Date().toISOString(),
            trainServices: servicesFor(Number(request.searchParams.get('timeOffset')))
                .slice(0, Number(request.searchParams.get('numRows'))) } };
    };
    const result = await getTrainTimes('WAT');
    assert.equal(result.dataStatus, 'live');
    assert.equal(result.departures.length, 120);
    assert.deepEqual(result.departures.slice(0, 60).map(d => d.serviceID), servicesFor(0).map(s => s.serviceID));
    assert.equal(result.departures[10].departure_time.scheduled, '12:20');
    assert.equal(result.departures[59].departure_time.scheduled, '13:58');
    assert.equal(result.departures[60].departure_time.scheduled, '13:59');
    assert.equal(staff.mock.callCount(), 0);
    assert.equal(urls.length, 2);
    for (const url of urls) {
        assert.ok(url.pathname.endsWith('/GetDepartureBoard/WAT'));
        assert.equal(url.searchParams.get('numRows'), '149');
        assert.equal(url.searchParams.has('filterCrs'), false);
    }
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
