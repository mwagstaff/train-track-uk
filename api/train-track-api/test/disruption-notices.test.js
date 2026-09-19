import assert from 'node:assert/strict';
import test from 'node:test';
import { createPlannedEngineeringProvider, matchEngineeringNotices, parseEngineeringNotices } from '../lib/disruptions/notices.js';
import { disruptionConfig } from '../lib/disruptions/model.js';

const stationDefinitions = [{ crs: 'VIC', name: 'London Victoria' }, { crs: 'KTH', name: 'Kent House' },
    { crs: 'HOV', name: 'Hove' }, { crs: 'WVF', name: 'West Hove' },
    { crs: 'CLK', name: 'Clock House' }, { crs: 'LBG', name: 'London Bridge' }, { crs: 'NWD', name: 'Norwood Junction' },
    { crs: 'CST', name: 'London Cannon Street' }, { crs: 'GNW', name: 'Greenwich' }, { crs: 'HYS', name: 'Hayes (Kent)' },
    { crs: 'LEW', name: 'Lewisham' }, { crs: 'LAD', name: 'Ladywell' }, { crs: 'NWX', name: 'New Cross' },
    { crs: 'ABC', name: 'Ambiguous' }, { crs: 'DEF', name: 'Ambiguous' }];
const period = (from = '2026-09-21T07:00:00+01:00', to = '2026-09-21T10:00:00+01:00') =>
    `<ValidityPeriod><com:StartTime>${from}</com:StartTime>${to ? `<com:EndTime>${to}</com:EndTime>` : ''}</ValidityPeriod>`;
const incident = ({ id = 'notice-1', planned = 'true', validity = period(), routes = 'Between London Victoria and Kent House',
    extra = '', body = '<p>Buses replace trains while a line is closed. Tickets accepted to Hove.</p>' } = {}) =>
    `<PtIncident><IncidentNumber>${id}</IncidentNumber><Planned>${planned}</Planned>${validity}
    <Summary><![CDATA[Planned changes &amp; advice]]></Summary><Description><![CDATA[${body}]]></Description>
    <Affects><Operators><AffectedOperator><OperatorRef>SE</OperatorRef></AffectedOperator></Operators><RoutesAffected><![CDATA[${routes}]]></RoutesAffected></Affects>
    <ChangeHistory><com:LastChangedDate>2026-09-19T09:00:00Z</com:LastChangedDate></ChangeHistory>
    <InfoLinks><InfoLink><Uri>https://www.nationalrail.co.uk/engineering/notice-1/</Uri><Label>nationalrail.co.uk</Label></InfoLink></InfoLinks>${extra}</PtIncident>`;
const feed = (...incidents) => `<?xml version="1.0"?><Incidents xmlns="http://nationalrail.co.uk/xml/incident" xmlns:com="http://nationalrail.co.uk/xml/common">${incidents.join('')}</Incidents>`;
const parse = xml => parseEngineeringNotices(xml, { stationDefinitions });
const window = { stations: ['KTH', 'VIC'], date: '2026-09-21', startMinutes: 420, endMinutes: 540 };

test('official planned flag is authoritative; title/body prose never invents closure or bus type', () => {
    const [notice] = parse(feed(incident()));
    assert.equal(notice.kind, 'engineering');
    assert.equal(notice.planned, true);
    assert.equal(notice.title, 'Planned changes & advice');
    assert.equal(notice.startAt, '2026-09-21T06:00:00.000Z');
    assert.deepEqual(notice.stationCRS, ['KTH', 'VIC']);
    assert.deepEqual(notice.affectedStationClauses, [['KTH', 'VIC']]);
    assert.deepEqual(notice.closedStationCRS, []);
    assert.doesNotMatch(notice.body, /<p>/);
    assert.equal(notice.updatedAt, '2026-09-19T09:00:00.000Z');
});

test('unplanned, explicitly cleared and Progress closed incidents are excluded', () => {
    assert.deepEqual(parse(feed(incident({ planned: 'false' }), incident({ extra: '<ClearedIncident>true</ClearedIncident>' }),
        incident({ extra: '<Progress>closed</Progress>' }))), []);
});

test('all repeating validity intervals are preserved independently', () => {
    const result = parse(feed(incident({ validity: period() + period('2026-09-28T07:00:00+01:00', '2026-09-28T10:00:00+01:00') })));
    assert.equal(result.length, 2);
    assert.notEqual(result[0].id, result[1].id);
    assert.equal(result[0].incidentId, 'notice-1');
    assert.equal(result[0].incidentId, result[1].incidentId);
    assert.equal(matchEngineeringNotices(result, window).length, 1);
});

test('matching requires route stations and overlapping London-local window', () => {
    const notices = parse(feed(incident()));
    assert.equal(matchEngineeringNotices(notices, window).length, 1);
    assert.equal(matchEngineeringNotices(notices, { ...window, stations: ['HOV', 'VIC'] }).length, 0);
    assert.equal(matchEngineeringNotices(notices, { ...window, startMinutes: 600, endMinutes: 660 }).length, 0);
    assert.equal(matchEngineeringNotices(notices, { ...window, date: '2026-09-22' }).length, 0);
    assert.equal(matchEngineeringNotices(notices, { ...window, stations: [] }).length, 0);
});

test('affected-service clauses require the whole selected route, not a shared hub or endpoints in separate services', () => {
    const selected = { ...window, stations: ['CLK', 'LBG'] };
    for (const routes of [
        '<p>Southern services between London Bridge and Norwood Junction</p>',
        '<p>Southeastern services between London Cannon Street and Greenwich via London Bridge</p>',
        '<p>Southeastern services between Clock House and Hayes (Kent)</p><p>Southeastern services between London Bridge and Greenwich</p>',
        'Between Clock House and Hayes (Kent);between London Bridge and Greenwich',
        'Clock House to Hayes (Kent) and London Bridge to Greenwich',
        'London Bridge - Caterham and Clock House - London Charing Cross',
        'London Bridge – Caterham and Clock House – London Charing Cross',
        'Southeastern services between Clock House and Hayes (Kent) and Southeastern services between London Bridge and Greenwich',
        'Between Clock House and Hayes (Kent). Between London Bridge and Greenwich'
    ]) assert.equal(matchEngineeringNotices(parse(feed(incident({ routes }))), selected).length, 0, routes);
    const explicit = parse(feed(incident({ routes: '<p>Southeastern services between Clock House and London Bridge via New Cross</p>' })));
    assert.equal(matchEngineeringNotices(explicit, selected).length, 1);
    assert.equal(matchEngineeringNotices(explicit, { ...selected, stations: ['LBG', 'CLK'] }).length, 1);
    assert.equal(matchEngineeringNotices(explicit, { ...selected, stations: ['CLK', 'NWX', 'LBG'] }).length, 1);
    assert.equal(matchEngineeringNotices(explicit, { ...selected, stations: ['CLK', 'LEW', 'LBG'] }).length, 0);
    const legacy = explicit.map(({ affectedStationClauses, closedStationCRS, ...notice }) => notice);
    assert.equal(matchEngineeringNotices(legacy, selected).length, 0, 'legacy flattened metadata cannot establish route relevance');
});

test('an explicitly labelled whole-station closure list identifies Clock House without inferring the Hayes branch', () => {
    const routes = '<p>All Southeastern services to / from Hayes (Kent)</p>';
    for (const heading of ['The following stations will be closed all weekend and will only be served by replacement buses:',
        '<strong>The following stations will be closed and will only be served by replacement buses:</strong>']) {
        const body = '<p>Engineering work is taking place between Ladywell and Hayes (Kent), closing all lines.</p>'
            + `<p>${heading}</p><ul><li>Ladywell</li><li>Clock House</li><li>Hayes (Kent)</li></ul>`
            + '<p>Use alternative trains to London Victoria.</p>';
        const notices = parse(feed(incident({ routes, body })));
        assert.deepEqual(notices[0].closedStationCRS, ['CLK', 'HYS', 'LAD']);
        assert.deepEqual(notices[0].affectedStationClauses, [['HYS']]);
        assert.equal(matchEngineeringNotices(notices, { ...window, stations: ['CLK', 'LBG'] }).length, 1);
        assert.equal(matchEngineeringNotices(notices, { ...window, stations: ['VIC', 'LBG'] }).length, 0);
    }
    const withoutEvidence = parse(feed(incident({ routes,
        body: '<p>Engineering work is taking place between Ladywell and Hayes (Kent), closing all lines.</p>' })));
    assert.equal(matchEngineeringNotices(withoutEvidence, { ...window, stations: ['CLK', 'LBG'] }).length, 0);
});

test('body advice, replacement stops and facility closures cannot masquerade as a whole-station closure', () => {
    const routes = '<p>Between London Cannon Street and Greenwich via London Bridge</p>';
    for (const body of [
        '<p>You can use alternative services from Clock House to London Bridge.</p>',
        '<p>Tickets are accepted on buses from Clock House.</p>',
        '<p>Replacement buses will call at the following stations:</p><ul><li>Clock House</li></ul>',
        '<p>The following stations will be closed all weekend:</p><p>Instead use:</p><ul><li>Clock House</li></ul>',
        '<p>The following stations will be closed all weekend:</p><ul><li>Walk to Clock House</li></ul>',
        '<p>The following stations will be closed at the ticket office:</p><ul><li>Clock House</li></ul>',
        '<p>Clock House station will be closed at the entrance only.</p>',
        '<p>Clock House station will be closed at platforms 1 and 2.</p>',
        '<p>Clock House station will be closed to Southern services only.</p>',
        '<p>Clock House station will be closed if engineering work overruns.</p>',
        '<p>The following stations will be closed to Southern services only:</p><ul><li>Clock House</li></ul>',
        '<p>The following stations will be closed if engineering work overruns:</p><ul><li>Clock House</li></ul>',
        '<p>The following stations will be closed at entrances and lifts:</p><ul><li>Clock House</li></ul>'
    ]) {
        const notices = parse(feed(incident({ routes, body })));
        assert.deepEqual(notices[0].closedStationCRS, [], body);
        assert.equal(matchEngineeringNotices(notices, { ...window, stations: ['CLK', 'LBG'] }).length, 0, body);
    }
    const explicit = parse(feed(incident({ routes, body: '<p>Clock House station will be closed all weekend.</p>' })));
    assert.deepEqual(explicit[0].closedStationCRS, ['CLK']);
    assert.equal(matchEngineeringNotices(explicit, { ...window, stations: ['CLK', 'LBG'] }).length, 1);
});

test('station references come only from exact unambiguous RoutesAffected names', () => {
    assert.deepEqual(parse(feed(incident({ routes: 'All Southeastern services' })))[0].stationCRS, []);
    assert.deepEqual(parse(feed(incident({ routes: 'Between West Hove and Ambiguous' })))[0].stationCRS, ['WVF']);
    assert.deepEqual(parse(feed(incident({ routes: 'Kent Houses' })))[0].stationCRS, []);
    assert.deepEqual(parseEngineeringNotices(feed(incident({ routes: 'West Hove' })), {
        stationDefinitions: [...stationDefinitions, { crs: 'XYZ', name: 'West Hove' }]
    })[0].stationCRS, []);
});

test('open-ended and overnight official notices match their actual validity', () => {
    const notices = parse(feed(incident({ validity: period('2026-09-21T23:30:00+01:00', '2026-09-22T01:00:00+01:00') })));
    assert.equal(matchEngineeringNotices(notices, { ...window, startMinutes: 1380, endMinutes: 1500 }).length, 1);
    const open = parse(feed(incident({ validity: period('2026-09-21T07:00:00+01:00', null) })));
    assert.equal(matchEngineeringNotices(open, { ...window, date: '2026-10-21' }).length, 1);
});

test('malformed documents, DTDs, missing planned flags and invalid dates are unavailable', () => {
    for (const xml of ['<html/>', '<Incidents><OtherSchema/></Incidents>', '<Incidents><PtIncident></Incidents>',
        '<!DOCTYPE Incidents [<!ENTITY attack "a">]><Incidents/>',
        feed(incident({ planned: 'maybe' })), feed(incident({ validity: period('2026-02-30T07:00:00Z') })),
        feed(incident({ validity: period('2026-09-21T24:00:00Z', null) })),
        feed(incident({ validity: period('2026-09-21T10:00:00Z', '2026-09-21T09:00:00Z') }))]) {
        assert.throws(() => parse(xml), { code: 'invalid_feed' });
    }
    assert.deepEqual(parse(feed()), []);
});

test('strict parsing still rejects reversed and zero-length live-feed validity ranges', () => {
    for (const [from, to] of [
        ['2026-09-27T00:00:00+01:00', '2026-09-24T23:59:00+01:00'],
        ['2026-10-12T00:00:00+01:00', '2026-07-16T23:59:00+01:00'],
        ['2026-11-12T00:00:00Z', '2026-11-12T00:00:00Z']
    ]) assert.throws(() => parse(feed(incident(), incident({ id: 'bad', validity: period(from, to) }))), { code: 'invalid_feed' });
});

test('opt-in quarantine keeps valid incidents and reports only bounded incident metadata', () => {
    const failures = [];
    const xml = feed(incident({ id: 'good' }),
        incident({ id: 'reversed', validity: period('2026-09-27T00:00:00+01:00', '2026-09-24T23:59:00+01:00') }),
        incident({ id: 'expired-end', validity: period('2026-10-12T00:00:00+01:00', '2026-07-16T23:59:00+01:00') }),
        incident({ id: 'zero-length', validity: period() + period('2026-11-12T00:00:00Z', '2026-11-12T00:00:00Z') }));
    const notices = parseEngineeringNotices(xml, { stationDefinitions, onInvalidIncident: failure => failures.push(failure) });
    assert.deepEqual(notices.map(notice => notice.incidentId), ['good']);
    assert.deepEqual(failures, ['reversed', 'expired-end', 'zero-length'].map(incidentId => ({ incidentId, reason: 'invalid_incident' })));
    assert.doesNotMatch(JSON.stringify(failures), /Description|ValidityPeriod|Buses/);
});

test('missing or oversized identifiers are quarantined without leaking content into diagnostics', () => {
    for (const id of ['', 'x'.repeat(257)]) {
        const failures = [];
        const notices = parseEngineeringNotices(feed(incident({ id: 'good' }), incident({ id })), {
            stationDefinitions, onInvalidIncident: failure => failures.push(failure)
        });
        assert.equal(notices.length, 1);
        assert.deepEqual(failures, [{ incidentId: null, reason: 'invalid_incident' }]);
    }
});

test('a quarantined incident cannot survive through another duplicate identifier record', () => {
    const notices = parseEngineeringNotices(feed(incident({ id: 'good' }), incident({ id: 'duplicate' }),
        incident({ id: 'duplicate', validity: period('2026-11-12T00:00:00Z', '2026-11-12T00:00:00Z') })), {
        stationDefinitions, onInvalidIncident: () => {}
    });
    assert.deepEqual(notices.map(notice => notice.incidentId), ['good']);
});

test('quarantine never turns an invalid envelope or entirely invalid planned feed into a healthy empty result', () => {
    const failures = [];
    for (const xml of ['<html/>', '<Incidents><OtherSchema/></Incidents>', '<Incidents><PtIncident></Incidents>']) {
        assert.throws(() => parseEngineeringNotices(xml, { onInvalidIncident: failure => failures.push(failure) }), { code: 'invalid_feed' });
    }
    assert.deepEqual(failures, []);
    assert.throws(() => parseEngineeringNotices(feed(incident({ id: 'bad', validity: period('2026-11-12T00:00:00Z', '2026-11-12T00:00:00Z') }),
        incident({ id: 'unplanned', planned: 'false' })), { onInvalidIncident: failure => failures.push(failure) }), { code: 'invalid_feed' });
    assert.deepEqual(failures, [{ incidentId: 'bad', reason: 'invalid_incident' }]);
});

test('only validated official source links are exposed', () => {
    const xml = feed(incident()).replace('https://www.nationalrail.co.uk/engineering/notice-1/', 'javascript:alert(1)');
    assert.equal(parse(xml)[0].sourceURL, 'https://www.nationalrail.co.uk/status-and-disruptions/');
});

test('unconfigured and forbidden access never look like healthy empty feeds', async () => {
    assert.equal((await createPlannedEngineeringProvider().getSnapshot()).available, false);
    const provider = createPlannedEngineeringProvider({ endpoint: 'https://example.test/incidents',
        fetchImpl: async () => new Response('', { status: 403 }) });
    assert.deepEqual((await provider.getSnapshot()).notices, []);
    assert.equal((await provider.getSnapshot()).reason, 'access_denied');
});

test('provider sends server credentials without following redirects and reuses five-minute snapshots', async () => {
    let calls = 0, clock = Date.parse('2026-09-19T12:00:00Z');
    const provider = createPlannedEngineeringProvider({ endpoint: 'https://example.test/incidents', authorization: 'Bearer server-secret',
        stationDefinitions, now: () => clock, fetchImpl: async (url, options) => {
            calls++; assert.equal(options.headers.authorization, 'Bearer server-secret'); assert.equal(options.redirect, 'error');
            return new Response(feed(incident()));
        } });
    const first = await provider.getSnapshot();
    assert.equal(first.available, true);
    first.notices.length = 0;
    assert.equal((await provider.getSnapshot()).notices.length, 1);
    assert.equal(calls, 1);
    clock += 300000;
    await provider.getSnapshot();
    assert.equal(calls, 2);
});

test('Marketplace environment configuration reaches the XML provider without exposing its key in snapshots', async () => {
    const config = disruptionConfig({ TRAIN_TRACK_UK_DISRUPTIONS_API_KEY: 'test-marketplace-key' });
    const provider = createPlannedEngineeringProvider({ endpoint: config.noticeEndpoint, headers: config.noticeHeaders,
        stationDefinitions, fetchImpl: async (url, options) => {
            assert.equal(url, 'https://api1.raildata.org.uk/1010-knowlegebase-incidents-xml-feed1_0/incidents.xml');
            assert.equal(options.headers['x-apikey'], 'test-marketplace-key');
            assert.equal(options.headers.accept, 'application/xml, text/xml');
            assert.equal(options.redirect, 'error');
            return new Response(feed(incident()));
        } });
    const snapshot = await provider.getSnapshot();
    assert.equal(snapshot.available, true);
    assert.equal(snapshot.notices.length, 1);
    assert.doesNotMatch(JSON.stringify(snapshot), /test-marketplace-key/);
});

test('provider reports partial coverage for quarantined incidents and full coverage after a clean refresh', async () => {
    let xml = feed(incident({ id: 'good' }),
        incident({ id: 'bad', validity: period('2026-09-27T00:00:00+01:00', '2026-09-24T23:59:00+01:00') }),
        incident({ id: 'bad', validity: period('2026-11-12T00:00:00Z', '2026-11-12T00:00:00Z') }));
    const provider = createPlannedEngineeringProvider({ endpoint: 'https://example.test/incidents', stationDefinitions,
        fetchImpl: async () => new Response(xml) });
    const partial = await provider.getSnapshot();
    assert.equal(partial.available, true);
    assert.equal(partial.complete, false);
    assert.equal(partial.reason, 'partial_feed');
    assert.deepEqual(partial.notices.map(notice => notice.incidentId), ['good']);
    assert.deepEqual(partial.unverifiedIncidentIds, ['bad']);
    partial.unverifiedIncidentIds.length = 0;
    assert.deepEqual((await provider.getSnapshot()).unverifiedIncidentIds, ['bad']);
    xml = feed(incident({ id: 'good' }));
    const healthy = await provider.getSnapshot({ force: true });
    assert.equal(healthy.available, true);
    assert.equal(healthy.complete, true);
    assert.equal(healthy.reason, null);
    assert.deepEqual(healthy.unverifiedIncidentIds, []);
});

test('provider preserves unknown identity metadata and rejects all-invalid planned feeds', async () => {
    const missingID = incident({ id: '' });
    const partial = await createPlannedEngineeringProvider({ endpoint: 'https://example.test/incidents',
        fetchImpl: async () => new Response(feed(incident(), missingID)) }).getSnapshot();
    assert.equal(partial.available, true);
    assert.equal(partial.complete, false);
    assert.deepEqual(partial.unverifiedIncidentIds, [null]);
    const invalid = await createPlannedEngineeringProvider({ endpoint: 'https://example.test/incidents',
        fetchImpl: async () => new Response(feed(missingID)) }).getSnapshot();
    assert.equal(invalid.available, false);
    assert.equal(invalid.reason, 'invalid_feed');
    assert.deepEqual(invalid.notices, []);
});

test('oversized streams, invalid XML and network errors return bounded reasons', async () => {
    for (const [fetchImpl, reason] of [
        [async () => new Response('x'.repeat(33)), 'feed_too_large'],
        [async () => new Response('<html/>'), 'invalid_feed'],
        [async () => { throw new Error('secret upstream details'); }, 'upstream_unavailable']
    ]) {
        const result = await createPlannedEngineeringProvider({ endpoint: 'https://example.test/incidents', maximumBytes: 32, fetchImpl }).getSnapshot();
        assert.equal(result.available, false);
        assert.equal(result.reason, reason);
        assert.doesNotMatch(JSON.stringify(result), /secret/);
    }
});

test('concurrent callers share one fetch and cancellation does not poison another caller', async () => {
    let resolve, calls = 0;
    const provider = createPlannedEngineeringProvider({ endpoint: 'https://example.test/incidents', fetchImpl: () => {
        calls++; return new Promise(done => { resolve = done; });
    } });
    const controller = new AbortController();
    const first = provider.getSnapshot({ signal: controller.signal });
    const second = provider.getSnapshot();
    controller.abort();
    assert.equal((await first).reason, 'cancelled');
    resolve(new Response(feed()));
    assert.equal((await second).available, true);
    assert.equal(calls, 1);
});

test('timeouts abort transport and report unavailable rather than clearing notices', async () => {
    const provider = createPlannedEngineeringProvider({ endpoint: 'https://example.test/incidents', timeoutMs: 5,
        fetchImpl: (url, { signal }) => new Promise((resolve, reject) => {
            signal.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })), { once: true });
        }) });
    const keepAlive = setTimeout(() => {}, 1000);
    try { assert.equal((await provider.getSnapshot()).reason, 'timeout'); }
    finally { clearTimeout(keepAlive); }
});
