import test from 'node:test';
import assert from 'node:assert/strict';
import { createTubeResolver, validateTubeConnection } from '../lib/planner/tube-routing.js';
import { createConnectionIndex } from '../lib/planner/connections.js';

const MINUTE = 60000;
const now = Date.parse('2026-09-19T08:00:00Z');
const iso = minutes => new Date(now + minutes * MINUTE).toISOString();
const clear = { status: 'noIssues', coverage: 'complete', issues: [], sources: [] };
const index = () => createConnectionIndex({ stations: ['PAD', 'VIC'].map(crs => ({ crs, minimumChangeMinutes: 5 })),
    rules: { tsi: [], links: [{ id: 'TUBE', origin: 'PAD', destination: 'VIC', mode: 'tubeTransfer', minutes: 10 }] } });
const query = { from: 'PAD', to: 'VIC', arrival: now + 60 * MINUTE, direction: 'earliest', allowedModes: ['tubeTransfer'] };
const issue = changes => ({ id: 'same-issue', severity: 'minor', statusDescription: 'Minor Delays', description: 'Signal delays', ...changes });
const affected = issues => ({ ...clear, status: 'minorIssues', issues });
function journey(start, disruption = clear, minutes = 10) {
    const time = offset => new Date(start + offset * MINUTE).toISOString();
    return { id: `option-${start}`, departureTime: time(0), arrivalTime: time(minutes), disruption, legs: [{ mode: 'tube',
        from: { id: 'PAD', name: 'Paddington' }, to: { id: 'VIC', name: 'Victoria' },
        departureTime: time(0), arrivalTime: time(minutes), lines: [{ id: 'circle', name: 'Circle' }], disruption }] };
}
function source(make) {
    const calls = [];
    return { calls, lookup: async query => {
        calls.push(query);
        return { status: 'available', expiresAt: iso(1), meta: { updatedAt: iso(0) }, journeys: make(query) };
    } };
}

for (const [name, detail] of [
    ['expired', issue({ validityPeriods: [{ from: iso(0), to: iso(10) }] })],
    ['future', issue({ validityPeriods: [{ from: iso(120), to: iso(180) }] })],
    ['explicitly unaffected', issue({ affectsLeg: false })]
]) {
    test(`${name} issue cannot reintroduce minor delays through aggregate status`, async () => {
        const provider = source(({ time }) => [journey(Date.parse(time), affected([detail]))]);
        const options = await createTubeResolver(provider, { now: () => now })(index(), query);
        assert.equal(options.length, 1);
        assert.equal(options[0].localJourney.contingencyMinutes, 0);
        assert.deepEqual(options[0].localJourney.warnings, []);
        assert.doesNotMatch(options[0].localJourney.notes.join(' '), /extra 5 minutes|Major disruption/);
        assert.ok(validateTubeConnection(index(), options[0]));
    });
}

test('status-only minor delays still reserve contingency when no issue details are supplied', async () => {
    const provider = source(({ time }) => [journey(Date.parse(time), affected([]))]);
    const options = await createTubeResolver(provider, { now: () => now })(index(), query);
    assert.equal(options[0].localJourney.contingencyMinutes, 5);
});

test('unknown disruption status remains uncertain even when source coverage is complete', async () => {
    const provider = source(({ time }) => [journey(Date.parse(time), { ...clear, status: 'unknown',
        sources: [{ source: 'plannedWorks', status: 'available' }, { source: 'realtime', status: 'notApplicable' }] })]);
    const options = await createTubeResolver(provider, { now: () => now })(index(), query);
    assert.equal(options[0].disruptionRank, 0);
    assert.match(options[0].localJourney.notes.join(' '), /cannot be confirmed/);
    assert.doesNotMatch(options[0].localJourney.notes.join(' '), /No planned disruption/);
});

test('a later unaffected copy of an issue cannot erase a confirmed closure on an earlier leg', async () => {
    const provider = source(({ time }) => {
        const value = journey(Date.parse(time));
        const closed = issue({ severity: 'major', statusDescription: 'Part Closure', affectsLeg: true });
        value.legs = [{ ...value.legs[0], arrivalTime: new Date(Date.parse(time) + 5 * MINUTE).toISOString(),
            disruption: { ...clear, status: 'majorIssues', issues: [closed] } },
        { ...value.legs[0], departureTime: new Date(Date.parse(time) + 5 * MINUTE).toISOString(),
            disruption: { ...clear, status: 'majorIssues', issues: [{ ...closed, affectsLeg: false }] } }];
        return [value];
    });
    const resolve = createTubeResolver(provider, { now: () => now });
    assert.deepEqual(await resolve(index(), query), []);
    assert.match([...resolve.state.notes].join(' '), /confirmed TfL closure/);
});

test('a closure outside the affected leg timing does not close a later unaffected leg', async () => {
    const provider = source(({ time }) => {
        const start = Date.parse(time), value = journey(start);
        value.legs = [{ ...value.legs[0], arrivalTime: new Date(start + 5 * MINUTE).toISOString(),
            disruption: { ...clear, status: 'majorIssues', issues: [issue({ severity: 'major', statusDescription: 'Closed',
                validityPeriods: [{ from: new Date(start + 6 * MINUTE).toISOString(), to: new Date(start + 15 * MINUTE).toISOString() }] })] } },
        { ...value.legs[0], departureTime: new Date(start + 5 * MINUTE).toISOString() }];
        return [value];
    });
    const options = await createTubeResolver(provider, { now: () => now })(index(), query);
    assert.equal(options.length, 1);
    assert.equal(options[0].disruptionRank, 0);
});

test('resolver signal cancels a memoized lookup even without a caller check callback', async () => {
    const provider = source(({ time }) => [journey(Date.parse(time))]);
    const controller = new AbortController();
    const resolve = createTubeResolver(provider, { signal: controller.signal, now: () => now });
    await resolve(index(), query);
    controller.abort();
    await assert.rejects(resolve(index(), query), { code: 'SEARCH_CANCELLED' });
    assert.equal(provider.calls.length, 1);
});

test('arrive-by retry cannot publish an initial forecast that expires while waiting for the retry', async () => {
    let clock = now, calls = 0;
    const provider = { lookup: async ({ time }) => {
        const first = ++calls === 1;
        if (!first) clock = now + 2000;
        return { status: 'available', expiresAt: new Date(now + (first ? 1000 : 30000)).toISOString(),
            meta: { updatedAt: iso(0) }, journeys: [journey(Date.parse(time) - 10 * MINUTE, affected([issue({})]))] };
    } };
    const options = await createTubeResolver(provider, { now: () => clock })(index(),
        { from: 'PAD', to: 'VIC', departure: now + 60 * MINUTE, direction: 'latest', allowedModes: ['tubeTransfer'] });
    assert.equal(calls, 2);
    assert.ok(options.every(option => option.localJourney.status === 'unavailable'));
});

test('major-disruption option does not claim no alternative when a clear option is also available', async () => {
    const major = { ...clear, status: 'majorIssues', issues: [issue({ severity: 'major', statusDescription: 'Severe Delays' })] };
    const provider = source(({ time }) => [journey(Date.parse(time), major), journey(Date.parse(time), clear, 20)]);
    const options = await createTubeResolver(provider, { now: () => now })(index(), query);
    const warning = options.find(option => option.disruptionRank === 2).localJourney.notes.join(' ');
    assert.match(warning, /Major disruption/);
    assert.doesNotMatch(warning, /No suitable|no alternative/i);
});
