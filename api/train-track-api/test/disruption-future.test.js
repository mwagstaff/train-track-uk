import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { futureDisruptions, normalizeFutureStations } from '../lib/disruptions/future.js';
import { DisruptionMonitor } from '../lib/disruptions/manager.js';
import { createPlannedEngineeringProvider } from '../lib/disruptions/notices.js';
import { registerDisruptionRoutes } from '../lib/disruptions/routes.js';
import { disruptionConfig } from '../lib/disruptions/model.js';

const now = Date.parse('2026-09-20T12:00:00Z'), stations = ['CLK', 'LBG'];
const notice = (id, startAt, endAt, extra = {}) => ({ id: `${id}:${startAt}`, incidentId: id, title: id,
    startAt, endAt, stationCRS: ['CLK', 'LBG'], affectedStationClauses: [['CLK', 'LBG']], closedStationCRS: [],
    planned: true, kind: 'engineering', body: 'Check your journey before travelling.',
    sourceURL: 'https://www.nationalrail.co.uk/status-and-disruptions/', ...extra });
const snapshot = notices => ({ available: true, complete: true, checkedAt: '2026-09-20T11:59:00Z', notices });
const forbidden = new Proxy({}, { get() { throw new Error('Browsing must not access the planner or database.'); } });

async function server(t, monitor) {
    const app = express(); registerDisruptionRoutes(app, monitor);
    const handle = app.listen(0, '127.0.0.1');
    await new Promise(resolve => handle.once('listening', resolve));
    t.after(() => { handle.closeAllConnections(); handle.close(); });
    return `http://127.0.0.1:${handle.address().port}/api/v2/disruptions/future`;
}

test('future journey input retains ordered vias and bounds malformed queries', () => {
    assert.deepEqual(normalizeFutureStations('CLK,NWX,LBG'), ['CLK', 'NWX', 'LBG']);
    assert.deepEqual(normalizeFutureStations('AAA,BBB,CCC,DDD,EEE,FFF'), ['AAA', 'BBB', 'CCC', 'DDD', 'EEE', 'FFF']);
    for (const input of [undefined, null, ['CLK', 'LBG'], {}, 'CLK', 'clk,LBG', 'CLK, LBG', 'CLK,LBG,CLK',
        'CLK,,LBG', 'CLK,LBG,', 'CL1,LBG', 'AAA,BBB,CCC,DDD,EEE,FFF,GGG', 'X'.repeat(10000)]) {
        assert.throws(() => normalizeFutureStations(input), error => error.status === 400 && error.code === 'INVALID_REQUEST');
    }
});

test('future browsing includes ongoing and distant work, excludes expired/unrelated work, and orders remaining periods', () => {
    const source = snapshot([
        notice('next-year', '2027-12-20T01:00:00Z', '2027-12-21T04:00:00Z'),
        notice('tomorrow', '2026-09-21T01:00:00Z', '2026-09-21T04:00:00Z'),
        notice('expired', '2026-09-19T01:00:00Z', '2026-09-20T12:00:00Z'),
        notice('ongoing', '2026-09-20T01:00:00Z', '2026-09-20T14:00:00Z'),
        notice('unrelated', '2026-09-20T13:00:00Z', '2026-09-20T14:00:00Z', { stationCRS: ['VIC'], affectedStationClauses: [['VIC']] }),
        notice('unplanned', '2026-09-20T13:00:00Z', '2026-09-20T14:00:00Z', { planned: false })
    ]);
    const original = structuredClone(source), result = futureDisruptions(source, stations, now);
    assert.deepEqual(result.notices.map(row => row.title), ['ongoing', 'tomorrow', 'next-year']);
    assert.equal(result.status, 'available');
    assert.deepEqual(result.stations, stations);
    assert.equal(result.checkedAt, '2026-09-20T11:59:00.000Z');
    assert.match(result.reason, /may affect/);
    assert.match(result.reason, /may be missing/);
    assert.match(result.notices[0].body, /may affect your journey/);
    assert.deepEqual(source, original, 'response building must not mutate the shared provider snapshot');
});

test('one incident retains disjoint remaining periods, merges overlaps, and has a stable identity', () => {
    const periods = [
        notice('weekends', '2026-09-19T01:00:00Z', '2026-09-19T05:00:00Z'),
        notice('weekends', '2026-10-04T01:00:00Z', '2026-10-04T04:00:00Z'),
        notice('weekends', '2026-09-27T02:00:00+01:00', '2026-09-27T04:00:00+01:00'),
        notice('weekends', '2026-09-27T02:00:00Z', '2026-09-27T05:00:00Z'),
        notice('weekends', '2026-09-27T02:00:00Z', '2026-09-27T05:00:00Z')
    ];
    const result = futureDisruptions(snapshot(periods), stations, now).notices;
    assert.equal(result.length, 1);
    assert.deepEqual(result[0].affectedWindows, [
        { startAt: '2026-09-27T01:00:00.000Z', endAt: '2026-09-27T05:00:00.000Z' },
        { startAt: '2026-10-04T01:00:00.000Z', endAt: '2026-10-04T04:00:00.000Z' }
    ]);
    assert.equal(result[0].startAt, result[0].affectedWindows[0].startAt);
    assert.equal(result[0].endAt, result[0].affectedWindows[1].endAt);
    assert.equal(futureDisruptions(snapshot(periods), stations, Date.parse('2026-09-28T00:00:00Z')).notices[0].id, result[0].id);
});

test('open-ended notices remain open and chronological ties are deterministic', () => {
    const periods = [notice('open', '2026-09-21T01:00:00Z', null),
        notice('open', '2026-10-21T01:00:00Z', '2026-10-21T04:00:00Z'),
        notice('same-date', '2026-09-21T01:00:00Z', '2026-09-21T04:00:00Z')];
    const result = futureDisruptions(snapshot(periods), stations, now).notices;
    const open = result.find(row => row.title === 'open');
    assert.equal(open.endAt, null);
    assert.deepEqual(open.affectedWindows, [{ startAt: '2026-09-21T01:00:00.000Z', endAt: null }]);
    assert.deepEqual(result, futureDisruptions(snapshot([...periods].reverse()), stations, now).notices);
});

test('unavailable and partially parsed feeds never report a definitive empty result', () => {
    const partial = futureDisruptions({ ...snapshot([]), complete: false, reason: 'partial_feed' }, stations, now);
    assert.equal(partial.status, 'partial'); assert.match(partial.reason, /could not be verified/);
    for (const source of [null, { available: false, reason: 'access_denied', checkedAt: 'invalid', notices: [] }]) {
        const response = futureDisruptions(source, stations, now);
        assert.equal(response.status, 'unavailable'); assert.equal(response.checkedAt, null);
        assert.match(response.reason, /temporarily unavailable/); assert.deepEqual(response.notices, []);
    }
    const malformed = futureDisruptions(snapshot([notice('bad', 'invalid', null)]), stations, now);
    assert.equal(malformed.status, 'partial'); assert.deepEqual(malformed.notices, []);
    const malformedEnvelope = futureDisruptions(snapshot({ unexpected: 'object' }), stations, now);
    assert.equal(malformedEnvelope.status, 'partial'); assert.deepEqual(malformedEnvelope.notices, []);
});

test('manual reads work in off and shadow modes without a monitor, preference lookup, routing or persistence', async () => {
    for (const mode of ['off', 'shadow', 'active']) {
        let reads = 0;
        const monitor = new DisruptionMonitor({ planner: forbidden, store: forbidden,
            config: disruptionConfig({ DISRUPTION_MONITOR_MODE: mode }), now: () => now,
            notices: { async getSnapshot() { reads++; return snapshot([notice('via', '2026-09-21T01:00:00Z', null,
                { stationCRS: ['CLK', 'NWX', 'LBG'], affectedStationClauses: [['CLK', 'NWX', 'LBG']] })]); } } });
        const result = await monitor.future('CLK,NWX,LBG');
        assert.equal(result.notices.length, 1); assert.equal(reads, 1);
        assert.deepEqual(result.stations, ['CLK', 'NWX', 'LBG']);
        assert.equal(monitor.timer, null); assert.equal(monitor.running, null);
        assert.deepEqual(monitor.noticeSnapshot.notices, [], 'manual reads do not change monitor state');
    }
});

test('provider failures are sanitized, while a missing feed is reported as unavailable', async () => {
    const common = { planner: forbidden, store: forbidden, now: () => now };
    const failure = await new DisruptionMonitor({ ...common,
        notices: { async getSnapshot() { throw new Error('secret credential'); } } }).future('CLK,LBG');
    assert.equal(failure.status, 'unavailable'); assert.equal(JSON.stringify(failure).includes('secret'), false);
    assert.equal((await new DisruptionMonitor(common).future('CLK,LBG')).status, 'unavailable');
});

test('HTTP reads reuse the shared cached feed, including concurrent requests, and reject malformed queries before fetching', async t => {
    let fetches = 0;
    const xml = '<Incidents><PtIncident><IncidentNumber>work</IncidentNumber><Planned>true</Planned><Summary>Bus replacement</Summary>'
        + '<Affects><RoutesAffected>Between Clock House and London Bridge</RoutesAffected></Affects><ValidityPeriod><StartTime>2026-09-21T01:00:00Z</StartTime>'
        + '<EndTime>2026-09-21T04:00:00Z</EndTime></ValidityPeriod></PtIncident></Incidents>';
    const provider = createPlannedEngineeringProvider({ endpoint: 'https://feed.example/incidents.xml', now: () => now,
        stationDefinitions: [{ crs: 'CLK', name: 'Clock House' }, { crs: 'LBG', name: 'London Bridge' }],
        fetchImpl: async () => { fetches++; return new Response(xml); } });
    const monitor = new DisruptionMonitor({ planner: forbidden, store: forbidden, notices: provider, now: () => now,
        config: disruptionConfig({ DISRUPTION_MONITOR_MODE: 'off' }) });
    const base = await server(t, monitor);
    for (const query of ['', '?stations=CLK', '?stations=clk,LBG', '?stations=CLK,CLK', '?stations=CLK,LBG&stations=VIC,KTH',
        '?stations[]=CLK&stations[]=LBG', '?stations=CLK,LBG&date=2026-09-21']) {
        assert.equal((await fetch(base + query)).status, 400, query);
    }
    assert.equal(fetches, 0);
    const responses = await Promise.all([fetch(`${base}?stations=CLK,LBG`), fetch(`${base}?stations=LBG,CLK`)]);
    for (const response of responses) {
        assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'no-store');
        const body = await response.json(); assert.equal(body.status, 'available'); assert.equal(body.notices.length, 1);
    }
    await fetch(`${base}?stations=CLK,LBG`);
    assert.equal(fetches, 1);
});

test('manual browsing rejects shared hubs, mixed clauses and obsolete station unions, but includes explicit closures', () => {
    const period = ['2026-09-21T01:00:00Z', '2026-09-21T04:00:00Z'];
    const source = snapshot([
        notice('Southern Norwood', ...period, { affectedStationClauses: [['LBG', 'NWD']] }),
        notice('Southeastern Greenwich', ...period, { affectedStationClauses: [['CST', 'LBG', 'GNW']] }),
        notice('different clauses', ...period, { affectedStationClauses: [['CLK', 'HYS'], ['LBG', 'NWD']] }),
        notice('old union', ...period, { affectedStationClauses: undefined, stationCRS: ['CLK', 'LBG'] }),
        notice('whole station closure', ...period, { affectedStationClauses: [['HYS']], closedStationCRS: ['CLK'] }),
        notice('specified service', ...period)
    ]);
    const result = futureDisruptions(source, stations, now);
    assert.deepEqual(result.notices.map(row => row.title).sort(), ['specified service', 'whole station closure']);
    assert.deepEqual(futureDisruptions(source, ['LBG', 'CLK'], now).notices.map(row => row.title).sort(),
        ['specified service', 'whole station closure']);
    assert.deepEqual(futureDisruptions(source, ['CLK', 'NWX', 'LBG'], now).notices.map(row => row.title), ['whole station closure']);
});
