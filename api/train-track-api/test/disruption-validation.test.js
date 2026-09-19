import assert from 'node:assert/strict';
import test from 'node:test';
import { validateDisruptions } from '../scripts/disruptions.js';

const now = () => Date.parse('2026-09-20T12:00:00Z');
const incident = (id, start, end) => `<PtIncident><Planned>true</Planned><IncidentNumber>${id}</IncidentNumber>
<Summary>Engineering work</Summary><Affects><RoutesAffected>Clock House to London Bridge</RoutesAffected></Affects>
<ValidityPeriod><StartTime>${start}</StartTime><EndTime>${end}</EndTime></ValidityPeriod></PtIncident>`;

test('read-only validation reports feed quality, route coverage and chronological examples without credentials', async () => {
    const xml = `<Incidents>${incident('later', '2026-11-01T00:00:00Z', '2026-11-02T00:00:00Z')}
${incident('earlier', '2026-09-21T00:00:00Z', '2026-09-22T00:00:00Z')}
${incident('past', '2026-09-01T00:00:00Z', '2026-09-02T00:00:00Z')}
${incident('invalid', '2026-10-02T00:00:00Z', '2026-10-01T00:00:00Z')}</Incidents>`;
    let calls = 0;
    const result = await validateDisruptions({ env: { TRAIN_TRACK_UK_DISRUPTIONS_API_KEY: 'test-only-secret' },
        stations: 'CLK,LBG', now, fetchImpl: async (url, options) => {
            calls++;
            assert.equal(options.headers['x-apikey'], 'test-only-secret');
            return new Response(xml, { headers: { 'content-type': 'text/xml' } });
        } });
    assert.equal(calls, 1);
    assert.equal(result.monitoringMode, 'shadow');
    assert.equal(result.feed.status, 'partial');
    assert.equal(result.feed.httpStatus, 200);
    assert.equal(result.feed.validPlannedIncidents, 3);
    assert.equal(result.feed.unexpiredPlannedIncidents, 2);
    assert.equal(result.feed.quarantinedIncidents, 1);
    assert.equal(result.route.matchingIncidents, 2);
    assert.equal(result.route.firstNotices[0].startAt, '2026-09-21T00:00:00.000Z');
    assert.equal(JSON.stringify(result).includes('test-only-secret'), false);
});

test('missing credentials and invalid route inputs do not make network requests', async () => {
    const fetchImpl = async () => { assert.fail('No upstream request expected'); };
    const result = await validateDisruptions({ env: {}, now, fetchImpl });
    assert.equal(result.feed.status, 'unavailable');
    assert.equal(result.feed.httpStatus, null);
    assert.equal(result.feed.reason, 'not_configured');
    await assert.rejects(validateDisruptions({ env: {}, stations: 'CLK,CLK', now, fetchImpl }));
});

test('access denial is distinct from an empty healthy feed and never exposes the key', async () => {
    const result = await validateDisruptions({ env: { TRAIN_TRACK_UK_DISRUPTIONS_API_KEY: 'private-key' },
        stations: 'CLK,LBG', now, fetchImpl: async () => new Response('Denied private-key', { status: 403 }) });
    assert.equal(result.feed.status, 'unavailable');
    assert.equal(result.feed.httpStatus, 403);
    assert.equal(result.feed.reason, 'access_denied');
    assert.equal(result.route.status, 'unavailable');
    assert.equal(JSON.stringify(result).includes('private-key'), false);
});
