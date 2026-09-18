import test from 'node:test';
import assert from 'node:assert/strict';
import { refreshRouteBoard, selectRouteBoardJourneys } from '../lib/planner/route-board-live.js';
import { SavedRouteLive, earliestRouteJourneys } from '../lib/planner/saved-route-live.js';
import { createTubeResolver } from '../lib/planner/tube-routing.js';
import { findJourneys, findJourneysAsync } from '../lib/planner/router.js';
import { normalizeRequest } from '../lib/planner/contract.js';
import { createConnectionIndex } from '../lib/planner/connections.js';

const MINUTE = 60000;
const now = Date.parse('2026-09-17T11:00:00Z');
const iso = minutes => new Date(now + minutes * MINUTE).toISOString();
const clear = { status: 'goodService', coverage: 'complete', issues: [], sources: [] };
const railProvider = { fetchBoards: async () => ({ boards: [], errors: [] }),
    fetchDetails: async () => ({ details: [], errors: [] }) };

function fixture({ mode = 'tubeTransfer', maxChanges = 5, services = [], origin = 'PAD', destination = 'VIC' } = {}) {
    const stations = ['ORG', 'PAD', 'VIC', 'DST'].map(crs => ({ crs, name: crs, minimumChangeMinutes: 0 }));
    const network = { services, stations: new Map(stations.map(station => [station.crs, station])),
        rules: { tsi: [], links: [{ id: 'LINK', origin: 'PAD', destination: 'VIC', mode, minutes: 10 }] } };
    const request = normalizeRequest({ origin, destination, time: iso(0), timeType: 'departAfter', maxChanges });
    const candidates = findJourneys(request, network).journeys;
    assert.ok(candidates.length);
    return { network, request, profile: { request, candidates }, plan: {
        result: { dataset: { version: 'test', warnings: [] }, journeys: candidates, search: {}, warnings: [] },
        connections: { stations, rules: network.rules }
    } };
}

function tubeProvider(options, { expiresAt = iso(0.5), onLookup } = {}) {
    const calls = [];
    return { calls, mapping: () => ({ exitMinutes: 3, entryMinutes: 4 }),
        async lookup(query) {
            calls.push(query);
            onLookup?.(query);
            query.budget.used++;
            return { status: 'available', expiresAt, meta: { updatedAt: iso(0) },
                journeys: options.map(({ id, minutes = 10, boardings = 1, disruption = clear }) => {
                    const start = Date.parse(query.time) - (query.timeMode === 'arriveBy' ? minutes * MINUTE : 0);
                    const at = offset => new Date(start + offset * MINUTE).toISOString();
                    const legs = Array.from({ length: boardings }, (_, index) => ({ id: String(index), mode: 'tube',
                        departureTime: at(index * minutes / boardings), arrivalTime: at((index + 1) * minutes / boardings),
                        from: { id: index ? 'CHANGE' : 'PAD', name: index ? 'Change station' : 'Paddington' },
                        to: { id: index === boardings - 1 ? 'VIC' : 'CHANGE', name: index === boardings - 1 ? 'Victoria' : 'Change station' },
                        lines: [{ id: 'circle', name: 'Circle' }], instruction: 'Circle line', disruption }));
                    return { id, departureTime: at(0), arrivalTime: at(minutes), legs, disruption };
                }) };
        }
    };
}

const refreshBoard = (f, provider, options = {}) => refreshRouteBoard({ ...f, time: iso(0),
    resolveTubeConnection: provider && createTubeResolver(provider, { now: () => now }), ...options },
{ provider: railProvider, now: () => now });
const refreshSaved = (f, provider, options = {}) => new SavedRouteLive({ now: () => now, tubeProvider: provider,
    provider: railProvider, getDepartures: async () => ({ departures: [], dataStatus: 'unavailable' }) })
    .refresh(f.plan, f.request, options);

for (const [name, refresh] of [['route board', refreshBoard], ['saved route', refreshSaved]]) {
    test(`${name} refresh retains TfL times and chooses a direct alternative within maxChanges`, async () => {
        const f = fixture({ maxChanges: 0 });
        const provider = tubeProvider([{ id: 'two-services', minutes: 10, boardings: 2 }, { id: 'direct', minutes: 14 }]);
        const before = JSON.stringify(f.profile);
        const result = await refresh(f, provider);
        assert.equal(result.journeys.length, 1);
        const journey = result.journeys[0], leg = journey.legs[0];
        assert.equal(leg.localJourney.id, 'direct');
        assert.equal(journey.changes, 0);
        assert.equal(journey.arrival, iso(21));
        assert.equal(leg.movementDeparture, iso(3));
        assert.equal(leg.movementArrival, iso(17));
        assert.equal(leg.breakdown.entryMinutes, 4);
        assert.equal(leg.genericTransfer, false);
        assert.ok(!leg.warnings.some(warning => /generic transfer/.test(warning)));
        assert.equal(result.live.expiresAt, iso(0.5));
        assert.equal(JSON.stringify(f.profile), before);
    });

    test(`${name} refresh counts separate services even when they use the same line name`, async () => {
        const result = await refresh(fixture(), tubeProvider([{ id: 'two-services', boardings: 2 }]));
        assert.equal(result.journeys[0].changes, 1);
        assert.equal(result.journeys[0].legs[0].localJourney.changes, 1);
    });

    test(`${name} refresh preserves contingency and disruption explanations`, async () => {
        const minor = { ...clear, status: 'minorIssues', issues: [{ id: 'minor', severity: 'minor', description: 'Signal delays' }] };
        const result = await refresh(fixture(), tubeProvider([{ id: 'minor', disruption: minor }]));
        const leg = result.journeys[0].legs[0];
        assert.equal(result.journeys[0].arrival, iso(22));
        assert.equal(leg.localJourney.contingencyMinutes, 5);
        assert.match(leg.localJourney.notes.join(' '), /extra 5 minutes/);
        assert.deepEqual(leg.localJourney.warnings, ['Signal delays']);
    });

    test(`${name} refresh never queries TfL for a National Rail walking link`, async () => {
        const provider = tubeProvider([{ id: 'should-not-be-used' }]);
        const result = await refresh(fixture({ mode: 'walk' }), provider);
        assert.equal(result.journeys[0].legs[0].mode, 'walk');
        assert.equal(provider.calls.length, 0);
    });

    test(`${name} refresh removes closed Tube options instead of restoring the generic transfer`, async () => {
        const closed = { ...clear, status: 'majorIssues', issues: [{ id: 'closed', severity: 'major',
            statusDescription: 'Closed', affectsLeg: true, description: 'Line closed' }] };
        const result = await refresh(fixture(), tubeProvider([{ id: 'closed', disruption: closed }]));
        assert.equal(result.journeys.length, 0);
        if (name === 'route board') assert.equal(result.needsReplan, true);
    });

    test(`${name} no-provider refresh does not leave obsolete TfL directions attached to generic times`, async () => {
        const f = fixture();
        f.profile.candidates[0].legs[0].localJourney = { status: 'available', steps: [], id: 'expired' };
        const result = await refresh(f, null);
        assert.equal(result.journeys.length, 1);
        assert.equal(result.journeys[0].legs[0].localJourney, undefined);
    });

    test(`${name} unavailable TfL uses ten-minute endpoint allowances when station times are missing`, async () => {
        const f = fixture();
        for (const station of f.network.stations.values()) delete station.minimumChangeMinutes;
        const provider = { mapping: () => ({}), lookup: async () => ({ status: 'unavailable', journeys: [],
            meta: { reason: 'connectivity' }, expiresAt: null }) };
        const result = await refresh(f, provider);
        assert.equal(result.journeys.length, 1);
        const leg = result.journeys[0].legs[0];
        assert.equal(leg.localJourney.status, 'unavailable');
        assert.equal(leg.breakdown.exitMinutes, 10);
        assert.equal(leg.breakdown.entryMinutes, 10);
        assert.equal(result.journeys[0].arrival, iso(30));
    });
}

test('saved refresh shares one Tube request budget and memo across onward train alternatives', async () => {
    const train = (id, from, to, departure, arrival) => ({ id, uid: id, originDate: '2026-09-17', mode: 'rail', operator: 'SN',
        calls: [{ station: from, sequence: 0, departure: Date.parse(iso(departure)), canBoard: true, canAlight: false },
            { station: to, sequence: 1, arrival: Date.parse(iso(arrival)), canBoard: false, canAlight: true }] });
    const f = fixture({ services: [train('IN', 'ORG', 'PAD', 5, 15), train('OUT1', 'VIC', 'DST', 45, 60),
        train('OUT2', 'VIC', 'DST', 50, 65)], origin: 'ORG', destination: 'DST' });
    const provider = tubeProvider([{ id: 'direct' }]);
    const result = await refreshSaved(f, provider);
    assert.ok(result.journeys.length);
    assert.equal(provider.calls.length, 1, 'same inbound arrival reuses TfL lookup for later onward departures');
    assert.equal(provider.calls[0].budget.limit, 32);
    assert.equal(result.journeys[0].changes, 2);
});

test('saved refresh propagates cancellation during Tube lookup', async () => {
    const controller = new AbortController();
    const provider = tubeProvider([{ id: 'direct' }], { onLookup: query => {
        assert.equal(query.signal, controller.signal);
        controller.abort();
    } });
    await assert.rejects(refreshSaved(fixture(), provider, { signal: controller.signal }), { code: 'SEARCH_CANCELLED' });
});

test('saved and route board selection prefer feasible clear routes over faster major disruption', () => {
    const legs = [{ kind: 'vehicle', mode: 'rail', serviceId: 'same', from: { crs: 'ORG' }, to: { crs: 'DST' },
        departure: iso(5), arrival: iso(30), localJourney: { disruption: { status: 'majorIssues' } } }];
    const affected = { departure: iso(5), arrival: iso(30), changes: 0, legs };
    const clearJourney = { ...affected, arrival: iso(40), legs: [{ ...legs[0], arrival: iso(40), localJourney: { disruption: clear } }] };
    assert.equal(selectRouteBoardJourneys([affected, clearJourney])[0], clearJourney);
    assert.deepEqual(earliestRouteJourneys([affected, clearJourney]), [clearJourney]);
    const sameTime = { ...clearJourney, arrival: affected.arrival, legs: [{ ...clearJourney.legs[0], arrival: affected.arrival }] };
    assert.deepEqual(selectRouteBoardJourneys([affected, sameTime]), [sameTime]);
});

test('arrive-by minor-delay retry retains the earliest expiry and observation of both responses', async () => {
    const minor = { ...clear, status: 'minorIssues', issues: [{ id: 'minor', severity: 'minor', description: 'Signal delays' }] };
    const provider = tubeProvider([{ id: 'minor', disruption: minor }]);
    const lookup = provider.lookup.bind(provider);
    provider.lookup = async query => {
        const response = await lookup(query);
        return { ...response, expiresAt: iso(provider.calls.length === 1 ? 0.5 : 0.1),
            meta: { ...response.meta, updatedAt: iso(provider.calls.length === 1 ? 0 : -0.1) } };
    };
    const f = fixture(), resolve = createTubeResolver(provider, { now: () => now });
    const options = await resolve(createConnectionIndex(f.network), { from: 'PAD', to: 'VIC',
        direction: 'latest', departure: Date.parse(iso(60)), allowedModes: ['tubeTransfer'] });
    assert.equal(provider.calls.length, 2);
    assert.ok(options.length);
    assert.ok(options.every(option => option.end <= Date.parse(iso(60))));
    assert.ok(options.every(option => option.localJourney.expiresAt === iso(0.1)));
    assert.ok(options.every(option => option.localJourney.updatedAt === iso(-0.1)));
});

test('arrive-by minor-delay retry rejects an expired earlier response', async () => {
    const minor = { ...clear, status: 'minorIssues', issues: [{ id: 'minor', severity: 'minor', description: 'Signal delays' }] };
    const provider = tubeProvider([{ id: 'minor', disruption: minor }]);
    const lookup = provider.lookup.bind(provider);
    provider.lookup = async query => {
        const response = await lookup(query);
        return { ...response, expiresAt: iso(provider.calls.length === 1 ? 0.5 : -0.1) };
    };
    const f = fixture(), resolve = createTubeResolver(provider, { now: () => now });
    const options = await resolve(createConnectionIndex(f.network), { from: 'PAD', to: 'VIC',
        direction: 'latest', departure: Date.parse(iso(60)), allowedModes: ['tubeTransfer'] });
    assert.ok(options.every(option => option.localJourney.status === 'unavailable'));
    assert.ok(options.every(option => option.localJourney.steps.length === 0));
});

test('future station-scoped part closure remains advisory without evidence it closes this leg', async () => {
    const future = 2 * 24 * 60;
    const disruption = { ...clear, status: 'majorIssues', sources: [{ source: 'plannedWorks', status: 'available' },
        { source: 'realtime', status: 'notApplicable' }], issues: [{ id: 'part-closure', severity: 'major',
        scope: 'station', statusDescription: 'Part Closure', description: 'Part of the line is closed for engineering work.',
        validityPeriods: [{ from: iso(future - 60), to: iso(future + 60) }] }] };
    const provider = tubeProvider([{ id: 'partial', disruption }]);
    const f = fixture(), resolve = createTubeResolver(provider, { now: () => now });
    const options = await resolve(createConnectionIndex(f.network), { from: 'PAD', to: 'VIC',
        direction: 'earliest', arrival: Date.parse(iso(future)), allowedModes: ['tubeTransfer'] });
    assert.equal(options.length, 1);
    assert.equal(options[0].localJourney.id, 'partial');
    assert.match(options[0].localJourney.notes.join(' '), /Major disruption/);
    assert.deepEqual(options[0].localJourney.warnings, ['Part of the line is closed for engineering work.']);
});

test('router retains equal-time TfL alternatives with different boarding and disruption trade-offs', async () => {
    const major = { ...clear, status: 'majorIssues', issues: [{ id: 'delays', severity: 'major', description: 'Severe delays' }] };
    const provider = tubeProvider([{ id: 'clear-two-services', boardings: 2 }, { id: 'affected-direct', disruption: major }]);
    const f = fixture();
    const result = await findJourneysAsync(f.request, f.network,
        { resolveTubeConnection: createTubeResolver(provider, { now: () => now }) });
    assert.ok(result.journeys.some(journey => journey.changes === 1 && journey.legs[0].localJourney.id === 'clear-two-services'));
    assert.ok(result.journeys.some(journey => journey.changes === 0 && journey.legs[0].localJourney.id === 'affected-direct'));
});
