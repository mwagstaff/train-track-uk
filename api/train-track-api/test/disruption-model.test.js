import assert from 'node:assert/strict';
import test from 'node:test';
import { normalizeMonitors, windowChunks, londonInstant, isQuietTime, profileJob, disruptionConfig } from '../lib/disruptions/model.js';
import { BankHolidayCalendar } from '../lib/disruptions/holidays.js';

const input = extra => ({ device_id: 'installation-1', monitors: [{ id: 'route-1', stations: ['KTH', 'VIC'], ...extra }] });
const incidentsURL = 'https://api1.raildata.org.uk/1010-knowlegebase-incidents-xml-feed1_0/incidents.xml';

test('Marketplace API key selects the subscribed Incidents XML endpoint and x-apikey header', () => {
    const config = disruptionConfig({ TRAIN_TRACK_UK_DISRUPTIONS_API_KEY: ' test-marketplace-key ' });
    assert.equal(config.noticeEndpoint, incidentsURL);
    assert.deepEqual(config.noticeHeaders, { 'x-apikey': 'test-marketplace-key' });
    assert.equal(disruptionConfig({}).noticeEndpoint, undefined);
    assert.equal(disruptionConfig({ TRAIN_TRACK_UK_DISRUPTIONS_API_KEY: '  ' }).noticeEndpoint, undefined);
    assert.deepEqual(disruptionConfig({ DISRUPTION_NOTICE_URL: incidentsURL }).noticeHeaders, {});
});

test('implicit Marketplace credentials are scoped to the exact official feed destination', () => {
    for (const endpoint of ['https://example.test/incidents.xml',
        incidentsURL.replace('api1.raildata.org.uk', 'api1.raildata.org.uk.example.test'),
        incidentsURL.replace('https:', 'http:'), incidentsURL.replace('/incidents.xml', '/other.xml'),
        incidentsURL.replace('https://', 'https://user:pass@'), `${incidentsURL}?redirect=other`, 'invalid', '']) {
        const config = disruptionConfig({ TRAIN_TRACK_UK_DISRUPTIONS_API_KEY: 'test-marketplace-key', DISRUPTION_NOTICE_URL: endpoint });
        assert.equal(config.noticeEndpoint, endpoint);
        assert.deepEqual(config.noticeHeaders, {});
    }
    assert.equal(disruptionConfig({ TRAIN_TRACK_UK_DISRUPTIONS_API_KEY: 'test-marketplace-key',
        DISRUPTION_NOTICE_URL: incidentsURL }).noticeHeaders['x-apikey'], 'test-marketplace-key');
});

test('explicit provider headers and authorization retain precedence and compatibility', () => {
    const config = disruptionConfig({ TRAIN_TRACK_UK_DISRUPTIONS_API_KEY: 'test-marketplace-key',
        DISRUPTION_NOTICE_HEADERS_JSON: '{"X-ApiKey":"explicit-key","x-provider-header":"value"}',
        DISRUPTION_NOTICE_AUTHORIZATION: 'Bearer explicit-token',
        DISRUPTION_NOTICE_USERNAME: 'explicit-user', DISRUPTION_NOTICE_PASSWORD: 'explicit-password' });
    assert.deepEqual(config.noticeHeaders, { 'X-ApiKey': 'explicit-key', 'x-provider-header': 'value' });
    assert.equal(config.noticeAuthorization, 'Bearer explicit-token');
    assert.equal(config.noticeUsername, 'explicit-user');
    assert.equal(config.noticePassword, 'explicit-password');
    const custom = disruptionConfig({ TRAIN_TRACK_UK_DISRUPTIONS_API_KEY: 'test-marketplace-key',
        DISRUPTION_NOTICE_URL: 'https://example.test/incidents.xml',
        DISRUPTION_NOTICE_HEADERS_JSON: '{"x-apikey":"custom-key"}' });
    assert.deepEqual(custom.noticeHeaders, { 'x-apikey': 'custom-key' });
});

test('all-day defaults cover every minute exactly once including the last hour', () => {
    const monitor = normalizeMonitors(input()).monitors[0];
    assert.deepEqual(monitor.days, [1, 2, 3, 4, 5, 6, 7]);
    assert.equal(monitor.push_enabled, false);
    const chunks = windowChunks(monitor, '2026-09-21');
    assert.equal(chunks.length, 24);
    assert.equal(chunks.reduce((sum, c) => sum + c.endMinutes - c.startMinutes, 0), 1440);
    assert.equal(chunks.at(-1).endMinutes, 1440);
});

test('overnight custom windows cover exact minutes without gaps or duplicate midnight chunks', () => {
    const monitor = normalizeMonitors(input({ days: [1], window_start: '23:37', window_end: '02:10' })).monitors[0];
    assert.deepEqual(windowChunks(monitor, '2026-09-21'), [
        { date: '2026-09-21', startMinutes: 1417, endMinutes: 1440 },
        { date: '2026-09-22', startMinutes: 0, endMinutes: 37 },
        { date: '2026-09-22', startMinutes: 37, endMinutes: 97 },
        { date: '2026-09-22', startMinutes: 97, endMinutes: 130 }
    ]);
    assert.deepEqual(windowChunks(monitor, '2026-09-22'), []);
});

test('per-day override and dated journeys do not silently widen travel times', () => {
    const monitor = normalizeMonitors(input({ days: [1], day_windows: { 1: { start: '08:05', end: '08:06' } } })).monitors[0];
    assert.deepEqual(windowChunks(monitor, '2026-09-21'), [{ date: '2026-09-21', startMinutes: 485, endMinutes: 486 }]);
    const dated = normalizeMonitors(input({ days: [1], travel_date: '2026-09-22' })).monitors[0];
    assert.equal(windowChunks(dated, '2026-09-21').length, 0);
    assert.equal(windowChunks(dated, '2026-09-22').length, 24);
});

test('invalid preferences cannot create runaway or permanently invalid searches', () => {
    for (const extra of [ { stations: ['KTH', 'VIC', 'KTH'] }, { days: [] }, { days: [0] },
        { enabled: 'true' }, { push_enabled: 'false' }, { window_start: '24:00' },
        { window_start: '07:00', window_end: '07:00' }, { travel_date: '2026-02-30' },
        { day_windows: { 9: { start: '07:00', end: '09:00' } } } ]) {
        assert.throws(() => normalizeMonitors(input(extra)));
    }
    const duplicate = input(); duplicate.monitors.push({ ...duplicate.monitors[0], id: 'other' });
    assert.throws(() => normalizeMonitors(duplicate));
});

test('shared profile identity separates direction, vias, date, exact window and source version', () => {
    const chunk = { date: '2026-09-21', startMinutes: 420, endMinutes: 480 };
    const make = (stations, window = chunk, version = 'v1') => profileJob(stations, window, version, Date.now());
    const normal = make(['KTH', 'VIC']);
    assert.equal(normal._id, make(['KTH', 'VIC'])._id);
    for (const other of [make(['VIC', 'KTH']), make(['KTH', 'HER', 'VIC']), make(['KTH', 'VIC'], { ...chunk, endMinutes: 479 }),
        make(['KTH', 'VIC'], { ...chunk, date: '2026-09-22' }), make(['KTH', 'VIC'], chunk, 'v2')]) assert.notEqual(normal._id, other._id);
    assert.equal(JSON.stringify(normal).includes('installation'), false);
});

test('London clocks handle summer, winter, midnight and ambiguous clock-change hour', () => {
    assert.equal(new Date(londonInstant('2026-09-21', 420)).toISOString(), '2026-09-21T06:00:00.000Z');
    assert.equal(new Date(londonInstant('2026-12-21', 420)).toISOString(), '2026-12-21T07:00:00.000Z');
    assert.equal(new Date(londonInstant('2026-09-21', 1440)).toISOString(), '2026-09-21T23:00:00.000Z');
    assert.throws(() => londonInstant('2026-10-25', 90));
    assert.equal(isQuietTime(Date.parse('2026-09-21T21:00:00Z')), true);
    assert.equal(isQuietTime(Date.parse('2026-09-21T06:00:00Z')), false);
    assert.equal(disruptionConfig({}).mode, 'off');
});

test('official holiday calendar fails closed and excludes regional holidays from baselines', async () => {
    const now = Date.parse('2026-09-01T00:00:00Z');
    const body = Object.fromEntries(['england-and-wales', 'scotland', 'northern-ireland'].map(region =>
        [region, { events: [{ date: region === 'scotland' ? '2026-09-21' : '2026-12-25' }] }]));
    const calendar = new BankHolidayCalendar({ now: () => now, fetchImpl: async () => new Response(JSON.stringify(body)) });
    assert.equal(calendar.ordinary('2026-09-22'), false);
    await calendar.refresh();
    assert.equal(calendar.ordinary('2026-09-21'), false);
    assert.equal(calendar.ordinary('2026-09-22'), true);
    assert.equal(calendar.ordinary('2027-09-22'), false);
});
