import test from 'node:test';
import assert from 'node:assert/strict';
import { presentLivePage } from '../lib/planner/live-coverage.js';

const now = Date.parse('2026-09-16T12:00:00+01:00');
const iso = minutes => new Date(now + minutes * 60000).toISOString();
const station = crs => ({ crs, name: crs });
const rail = (values = {}) => ({ kind: 'vehicle', mode: 'rail', serviceId: 'train',
    from: station('AAA'), to: station('BBB'), departure: iso(10), arrival: iso(30), ...values });
const liveTimes = (values = {}) => ({ status: 'onTime', departure: iso(10), arrival: iso(30),
    cancelled: false, partCancelled: false, warnings: [], ...values });
const journey = legs => ({ departure: legs[0].departure, arrival: legs.at(-1).arrival, legs });
const metadata = { mode: 'apply', status: 'partial', updatedAt: iso(0), expiresAt: iso(1), windowHours: 4,
    warnings: ['Live updates are available for some services. Other services and later connections use scheduled times.'] };
const context = values => ({ now, diagnostics: [], errors: [], visited: ['AAA'], limited: false, pendingServiceIds: [], ...values });
const diagnostic = (reason, values = {}) => ({ reason, station: 'AAA', serviceID: 'opaque', candidateServiceIds: ['train'], ...values });

test('Tube and walking transfers do not create live rail gaps or failure warnings', () => {
    const legs = [rail({ live: liveTimes() }),
        { kind: 'transfer', mode: 'tubeTransfer', from: station('BBB'), to: station('CCC'), departure: iso(30), arrival: iso(50) },
        { kind: 'transfer', mode: 'walk', from: station('CCC'), to: station('DDD'), departure: iso(50), arrival: iso(55) }];
    const result = presentLivePage([journey(legs)], { ...metadata, warnings: [...metadata.warnings,
        'Some live updates could not be retrieved.', 'The live lookup limit was reached; some services have not been checked.'] },
    context({ limited: true, diagnostics: [diagnostic('mismatch', { candidateServiceIds: ['unrelated'] })] }));
    assert.equal(result.live.status, 'live');
    assert.deepEqual(result.live.coverage, { nearTermRailLegs: 1, confirmedRailLegs: 1, scheduledLaterRailLegs: 0 });
    assert.deepEqual(result.live.warnings, []);
    assert.ok(result.journeys[0].legs.every(leg => !leg.warnings?.length));
});

test('later rail services remain normal scheduled context, with no live-failure note', () => {
    const legs = [rail({ live: liveTimes() }), rail({ serviceId: 'later', from: station('BBB'),
        to: station('DDD'), departure: iso(241), arrival: iso(300) })];
    const result = presentLivePage([journey(legs)], metadata, context({ limited: true, pendingServiceIds: ['later'] }));
    assert.equal(result.live.status, 'live');
    assert.deepEqual(result.live.coverage, { nearTermRailLegs: 1, confirmedRailLegs: 1, scheduledLaterRailLegs: 1 });
    assert.equal(result.journeys[0].legs[1].warnings, undefined);
    assert.deepEqual(result.live.warnings, ['Later trains use scheduled times; live updates are checked nearer departure.']);
});

test('a real unannotated rail gap gets a neutral note and is counted once across journeys', () => {
    const original = [journey([rail()]), journey([rail()])];
    const copy = structuredClone(original);
    const result = presentLivePage(original, metadata, context());
    assert.equal(result.live.status, 'unavailable');
    assert.deepEqual(result.live.coverage, { nearTermRailLegs: 1, confirmedRailLegs: 0, scheduledLaterRailLegs: 0 });
    assert.match(result.journeys[0].legs[0].warnings[0], /not yet available/);
    assert.deepEqual(original, copy);
});

test('only genuine relevant identity failures produce an unsafe-match note', () => {
    for (const reason of ['ambiguous', 'mismatch']) {
        const result = presentLivePage([journey([rail()])], metadata, context({ diagnostics: [diagnostic(reason)] }));
        assert.match(result.journeys[0].legs[0].warnings[0], /matched safely/);
    }
    for (const diagnostics of [[diagnostic('missingDetail')], [diagnostic('staleDetail')],
        [diagnostic('mismatch', { candidateServiceIds: ['unrelated'] })]]) {
        const result = presentLivePage([journey([rail()])], metadata, context({ diagnostics }));
        assert.match(result.journeys[0].legs[0].warnings[0], /not yet available/);
        assert.ok(result.live.warnings.every(warning => !warning.includes('matched safely')));
    }
});

test('failed detail retrieval is scoped by both station and opaque service ID', () => {
    const relevant = context({ diagnostics: [diagnostic('missingDetail')],
        errors: [{ station: 'AAA', serviceID: 'opaque', reason: 'timeout' }] });
    assert.match(presentLivePage([journey([rail()])], metadata, relevant).journeys[0].legs[0].warnings[0], /could not be retrieved/);
    for (const error of [{ station: 'AAA', serviceID: 'other', reason: 'timeout' },
        { station: 'BBB', serviceID: 'opaque', reason: 'timeout' }, { station: 'AAA', reason: 'timeout' }]) {
        const result = presentLivePage([journey([rail()])], metadata, { ...relevant, errors: [error] });
        assert.match(result.journeys[0].legs[0].warnings[0], /not yet available/);
    }
});

test('lookup limits are reported only for deferred trains or their unvisited boarding station', () => {
    for (const values of [{ pendingServiceIds: ['train'] }, { visited: ['CCC'] }]) {
        const result = presentLivePage([journey([rail()])], metadata, context({ limited: true, ...values }));
        assert.match(result.journeys[0].legs[0].warnings[0], /lookup limit/);
    }
    const unrelated = presentLivePage([journey([rail()])], metadata, context({ limited: true, pendingServiceIds: ['other'] }));
    assert.match(unrelated.journeys[0].legs[0].warnings[0], /not yet available/);
    assert.ok(unrelated.live.warnings.every(warning => !warning.includes('lookup limit')));
});

test('partial annotations remain uncertainty, even if another observation failed to match', () => {
    const leg = rail({ live: liveTimes({ status: 'unknown', arrival: undefined }), warnings: ['Arrival time is not confirmed.'] });
    const result = presentLivePage([journey([leg])], metadata, context({ diagnostics: [diagnostic('mismatch')] }));
    assert.equal(result.live.status, 'partial');
    assert.equal(result.live.coverage.confirmedRailLegs, 0);
    assert.deepEqual(result.journeys[0].legs[0].warnings, ['Arrival time is not confirmed.']);
});

test('on-time labels alone never establish forecasts, while known cancellation is verified information', () => {
    const incomplete = presentLivePage([journey([rail({ live: { status: 'onTime' } })])], metadata, context());
    assert.equal(incomplete.live.status, 'partial');
    assert.equal(incomplete.live.coverage.confirmedRailLegs, 0);
    const cancelled = presentLivePage([journey([rail({ live: { status: 'cancelled', cancelled: true } })])], metadata, context());
    assert.equal(cancelled.live.status, 'live');
    assert.equal(cancelled.live.coverage.confirmedRailLegs, 1);
});

test('no eligible rail legs means outside-window without fabricated observation times', () => {
    const result = presentLivePage([journey([rail({ departure: iso(241), arrival: iso(300) })])], metadata, context());
    assert.equal(result.live.status, 'outsideWindow');
    assert.equal(result.live.updatedAt, undefined);
    assert.equal(result.live.expiresAt, undefined);
    assert.deepEqual(result.live.warnings, ['Later trains use scheduled times; live updates are checked nearer departure.']);
});

test('an empty result preserves the actual search status and observation context', () => {
    for (const status of ['partial', 'unavailable', 'outsideWindow']) {
        const result = presentLivePage([], { ...metadata, status }, context());
        assert.equal(result.live.status, status);
        assert.equal(result.live.updatedAt, metadata.updatedAt);
        assert.equal(result.live.expiresAt, metadata.expiresAt);
        assert.deepEqual(result.live.coverage, { nearTermRailLegs: 0, confirmedRailLegs: 0, scheduledLaterRailLegs: 0 });
        assert.deepEqual(result.live.warnings, []);
    }
});

test('effective departures define the live interval, and supplied operational warnings survive', () => {
    const warning = 'The live observations aged while this search was running. Search again to refresh them.';
    const ignore = 'Delays and cancellations are shown, but these routes use scheduled times.';
    const leg = rail({ mode: 'replacementBus', scheduledDeparture: iso(-121), departure: iso(-121),
        live: liveTimes({ departure: iso(-119), arrival: iso(-100) }) });
    const result = presentLivePage([journey([leg])], { ...metadata, warnings: [...metadata.warnings, warning, ignore] }, context());
    assert.equal(result.live.coverage.nearTermRailLegs, 1);
    assert.equal(result.live.status, 'live');
    assert.deepEqual(result.live.warnings, [warning, ignore]);
});
