import assert from 'node:assert/strict';
import test from 'node:test';
import express from 'express';
import { createIncidentProvider, engineeringSnapshot, parseIncidentNotices } from '../lib/disruptions/notices.js';
import { createLiveDisruptions } from '../lib/disruptions/live.js';
import { registerDisruptionRoutes } from '../lib/disruptions/routes.js';
import { disruptionConfig } from '../lib/disruptions/model.js';

const initialTime = Date.parse('2026-10-06T12:00:00Z');
const feed = (...items) => `<Incidents>${items.join('')}</Incidents>`;
function incident({ id = 'signal-failure', planned = false, start = '2026-10-06T12:00:00+01:00', end,
    operator = 'SE', allOperators = false, priority = '1', extra = '', title = 'Signal failure' } = {}) {
    return `<PtIncident><IncidentNumber>${id}</IncidentNumber><Planned>${planned}</Planned>
        <Summary>${title}</Summary><Description><![CDATA[<p>Trains are delayed.</p><script>bad()</script>]]></Description>
        <ValidityPeriod><StartTime>${start}</StartTime>${end ? `<EndTime>${end}</EndTime>` : ''}</ValidityPeriod>
        <ChangeHistory><LastChangedDate>2026-10-06T11:30:00Z</LastChangedDate></ChangeHistory>
        <Affects><Operators>${allOperators ? '<AllOperators/>' : `<AffectedOperator><OperatorRef>${operator}</OperatorRef><OperatorName>Rail operator</OperatorName></AffectedOperator>`}</Operators>
        <RoutesAffected><![CDATA[<p>Between London and Kent</p>]]></RoutesAffected></Affects>
        <InfoLinks><InfoLink><Uri>https://www.nationalrail.co.uk/disruptions/signal-failure/</Uri></InfoLink></InfoLinks>
        <IncidentPriority>${priority}</IncidentPriority>${extra}</PtIncident>`;
}
function setup(t, xml = feed(incident()), options = {}) {
    const state = { clock: initialTime, xml, calls: 0, status: 200 };
    const provider = createIncidentProvider({ endpoint: 'https://example.test/incidents', now: () => state.clock,
        fetchImpl: async () => { state.calls++; return new Response(state.xml, { status: state.status }); }, ...options });
    t.after(() => provider.stop());
    const live = createLiveDisruptions({ provider, now: () => state.clock });
    return { state, provider, live };
}

test('live feed excludes planned, cleared, expired and future incidents and preserves public fields', async t => {
    const { live, provider } = setup(t, feed(incident(), incident({ id: 'planned', planned: true }),
        incident({ id: 'cleared', extra: '<ClearedIncident>true</ClearedIncident>' }),
        incident({ id: 'closed', extra: '<Progress>closed</Progress>' }),
        incident({ id: 'ended', end: '2026-10-06T12:00:00Z' }),
        incident({ id: 'future', start: '2026-10-06T14:00:00Z' })));
    const response = await live.get();
    assert.equal(response.status, 'available');
    assert.equal(response.stale, false);
    assert.equal(response.ageSeconds, 0);
    assert.deepEqual(response.incidents, [{ id: 'signal-failure', title: 'Signal failure', body: 'Trains are delayed.',
        sourceURL: 'https://www.nationalrail.co.uk/disruptions/signal-failure/',
        operators: [{ code: 'SE', name: 'Rail operator' }], allOperators: false,
        routesAffected: 'Between London and Kent', priority: 1, updatedAt: '2026-10-06T11:30:00.000Z',
        startAt: '2026-10-06T11:00:00.000Z', endAt: null }]);
    assert.deepEqual(engineeringSnapshot(await provider.getSnapshot()).notices.map(item => item.incidentId), ['planned']);
});

test('operator filter includes all-operator incidents; priority zero sorts first and unknown sorts last', async t => {
    const { live } = setup(t, feed(incident(), incident({ id: 'other', operator: 'SN' }),
        incident({ id: 'nationwide', allOperators: true, priority: '0' }), incident({ id: 'unknown', priority: '' })));
    assert.deepEqual((await live.get('SE')).incidents.map(item => item.id), ['nationwide', 'signal-failure', 'unknown']);
    assert.deepEqual((await live.get('XX')).incidents.map(item => item.id), ['nationwide']);
    assert.equal((await live.get()).incidents.length, 4);
});

test('complete refresh updates incidents and removes disappeared or cleared incidents', async t => {
    const { state, provider, live } = setup(t, feed(incident(), incident({ id: 'removed' }), incident({ id: 'cleared' })));
    await live.get();
    state.clock += 60000;
    state.xml = feed(incident({ title: 'Service recovering' }), incident({ id: 'cleared', extra: '<ClearedIncident>1</ClearedIncident>' }));
    await provider.getSnapshot();
    const result = await live.get();
    assert.deepEqual(result.incidents.map(item => item.id), ['signal-failure']);
    assert.equal(result.incidents[0].title, 'Service recovering');
    state.xml = feed();
    await provider.getSnapshot({ force: true });
    assert.deepEqual((await live.get()).incidents, []);
    assert.equal((await live.get()).status, 'available');
});

test('malformed records mark partial coverage; unknown operator and cleared flags cannot look authoritative', async t => {
    const { live } = setup(t, feed(incident(), incident({ id: 'bad-date', end: '2026-10-05T00:00:00Z' }),
        incident({ id: 'bad-operator', operator: '' }), incident({ id: 'bad-flag', extra: '<ClearedIncident>maybe</ClearedIncident>' })));
    const result = await live.get();
    assert.equal(result.status, 'partial');
    assert.equal(result.reason, 'partial_feed');
    assert.deepEqual(result.incidents.map(item => item.id), ['signal-failure']);
});

test('invalid live records do not change engineering coverage; invalid engineering records remain quarantined', async t => {
    const { provider, state } = setup(t, feed(incident({ planned: true }), incident({ id: 'invalid-live', operator: '' })));
    const engineering = engineeringSnapshot(await provider.getSnapshot());
    assert.equal(engineering.available, true);
    assert.equal(engineering.complete, true);
    assert.deepEqual(engineering.unverifiedIncidentIds, []);
    assert.equal(engineering.notices.length, 1);
    state.xml = feed(incident(), incident({ id: 'invalid-planned', planned: true, end: '2026-10-01T00:00:00Z' }));
    const invalid = engineeringSnapshot(await provider.getSnapshot({ force: true }));
    assert.equal(invalid.available, false);
    assert.deepEqual(invalid.notices, []);
});

test('an entirely malformed feed is unavailable and expired incidents do not survive stale fallback', async t => {
    const { provider, live, state } = setup(t, feed(incident({ end: '2026-10-06T12:00:30Z' })));
    assert.equal((await live.get()).incidents.length, 1);
    state.clock += 60000;
    state.xml = feed(incident({ operator: '' }));
    assert.equal((await provider.getSnapshot()).available, false);
    const stale = await live.get();
    assert.equal(stale.stale, true);
    assert.deepEqual(stale.incidents, []);
    const { live: cold } = setup(t, state.xml);
    assert.equal((await cold.get()).status, 'unavailable');
});

test('outage fallback retains original check time, expires after ten minutes, and recovers', async t => {
    const { state, provider, live } = setup(t);
    const first = await live.get();
    state.status = 503; state.clock += 60000;
    await provider.getSnapshot();
    const stale = await live.get();
    assert.equal(stale.stale, true);
    assert.equal(stale.checkedAt, first.checkedAt);
    assert.equal(stale.ageSeconds, 60);
    assert.notEqual(stale.lastAttemptAt, stale.checkedAt);
    assert.equal(stale.reason, 'upstream_unavailable');
    assert.equal(stale.incidents.length, 1);
    state.clock += 540001;
    await provider.getSnapshot();
    const expired = await live.get();
    assert.equal(expired.status, 'unavailable');
    assert.deepEqual(expired.incidents, []);
    state.status = 200; state.xml = feed();
    await provider.getSnapshot({ force: true });
    assert.equal((await live.get()).stale, false);
    assert.deepEqual((await live.get()).incidents, []);
});

test('missing access and invalid feeds are unavailable without a previous snapshot', async t => {
    for (const options of [{ endpoint: undefined }, { fetchImpl: async () => new Response('', { status: 403 }) },
        { fetchImpl: async () => new Response('<html/>') }]) {
        const { live } = setup(t, undefined, options);
        const result = await live.get();
        assert.equal(result.status, 'unavailable');
        assert.equal(result.checkedAt, null);
        assert.deepEqual(result.incidents, []);
    }
});

test('warm reads return immediately during one shared refresh; cancelling a caller does not abort the feed', async t => {
    let resolve, calls = 0;
    const { state, provider, live } = setup(t, undefined, { fetchImpl: async () => {
        calls++;
        if (calls === 1) return new Response(feed(incident()));
        return new Promise(done => { resolve = done; });
    } });
    await live.get();
    state.clock += 60000;
    const result = await live.get();
    assert.equal(result.stale, true);
    assert.equal(result.incidents.length, 1);
    assert.equal((await live.get()).incidents.length, 1);
    const controller = new AbortController();
    const engineering = provider.getSnapshot({ signal: controller.signal });
    controller.abort();
    assert.equal((await engineering).reason, 'cancelled');
    const waiting = provider.getSnapshot();
    resolve(new Response(feed()));
    await waiting;
    assert.equal(calls, 2);
    assert.deepEqual((await live.get()).incidents, []);
});

test('background refresh starts without requests and shutdown aborts transport', async t => {
    let signal, started;
    const called = new Promise(resolve => { started = resolve; });
    const { provider } = setup(t, undefined, { fetchImpl: (url, options) => {
        signal = options.signal; started();
        return new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true }));
    } });
    provider.start(); provider.start();
    await called;
    const flight = provider.getSnapshot();
    provider.stop();
    await flight;
    assert.equal(signal.aborted, true);
    assert.equal((await provider.getSnapshot()).reason, 'cancelled');
});

test('background polling refreshes at the configured interval and stops after shutdown', async t => {
    t.mock.timers.enable({ apis: ['setTimeout'] });
    const outcomes = [];
    const { provider, state } = setup(t, undefined, { observe: value => outcomes.push(value) });
    provider.start();
    await new Promise(setImmediate);
    assert.equal(state.calls, 1);
    state.clock += 59999;
    t.mock.timers.tick(59999);
    await new Promise(setImmediate);
    assert.equal(state.calls, 1);
    state.clock++;
    t.mock.timers.tick(1);
    await new Promise(setImmediate);
    assert.equal(state.calls, 2);
    assert.equal(outcomes.length, 2);
    assert.equal(outcomes[1].checkedAt, new Date(state.clock).toISOString());
    provider.stop();
    state.clock += 60000;
    t.mock.timers.tick(60000);
    await new Promise(setImmediate);
    assert.equal(state.calls, 2);
});

test('timestamps respect explicit BST and GMT offsets at the autumn clock change', () => {
    const notices = parseIncidentNotices(feed(
        incident({ id: 'bst', start: '2026-10-25T01:30:00+01:00' }),
        incident({ id: 'gmt', start: '2026-10-25T01:30:00Z' })));
    assert.equal(Date.parse(notices[1].startAt) - Date.parse(notices[0].startAt), 3600000);
});

test('live HTTP contract validates filters, needs no device, and maps unavailable to 503', async t => {
    const { live, provider, state } = setup(t);
    const app = express();
    registerDisruptionRoutes(app, {}, { liveDisruptions: live });
    const server = app.listen(0, '127.0.0.1');
    await new Promise(resolve => server.once('listening', resolve));
    t.after(() => { server.closeAllConnections(); server.close(); });
    const url = `http://127.0.0.1:${server.address().port}/api/v2/disruptions/live`;
    const response = await fetch(url);
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.equal((await response.json()).incidents.length, 1);
    assert.deepEqual((await (await fetch(`${url}?operator=SN`)).json()).incidents, []);
    for (const query of ['operator=se', 'operator=ABC', 'operator=SE&operator=SN', 'operator[x]=SE', 'stations=CLK,LBG', 'device_id=test']) {
        assert.equal((await fetch(`${url}?${query}`)).status, 400, query);
    }
    state.status = 503; state.clock += 600001;
    await provider.getSnapshot();
    const failed = await fetch(url);
    assert.equal(failed.status, 503);
    assert.equal(failed.headers.get('retry-after'), '60');
    assert.equal((await failed.json()).status, 'unavailable');
});

test('refresh configuration cannot poll more frequently than once per minute', () => {
    assert.equal(disruptionConfig({}).noticeRefreshMs, 60000);
    assert.equal(disruptionConfig({ DISRUPTION_NOTICE_REFRESH_SECONDS: '10' }).noticeRefreshMs, 60000);
    assert.equal(disruptionConfig({ DISRUPTION_NOTICE_REFRESH_SECONDS: '300' }).noticeRefreshMs, 300000);
});
