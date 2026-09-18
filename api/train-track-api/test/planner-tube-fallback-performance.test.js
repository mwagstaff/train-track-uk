import test from 'node:test';
import assert from 'node:assert/strict';
import { createConnectionIndex } from '../lib/planner/connections.js';
import { createTubeResolver, validateTubeConnection } from '../lib/planner/tube-routing.js';

const MINUTE = 60000;
const zero = Date.parse('2026-09-18T12:00:00Z');
class NonIterableStations extends Map {
    [Symbol.iterator]() { throw new Error('Fallback must not copy the full station map'); }
    entries() { throw new Error('Fallback must not iterate stations'); }
    keys() { throw new Error('Fallback must not iterate stations'); }
    values() { throw new Error('Fallback must not iterate stations'); }
    forEach() { throw new Error('Fallback must not iterate stations'); }
}
function fixture() {
    const stations = new NonIterableStations();
    for (let index = 0; index < 5000; index++) stations.set(`unused:${index}`,
        Object.freeze({ crs: `unused:${index}`, minimumChangeMinutes: 99 }));
    for (const [crs, minutes] of [['AAA', 7], ['BBB', 9], ['CCC', 11]]) {
        stations.set(crs, Object.freeze({ crs, name: `Station ${crs}`, minimumChangeMinutes: minutes }));
    }
    const index = createConnectionIndex({ stations, rules: { links: [
        { id: 'AB', origin: 'AAA', destination: 'BBB', mode: 'tubeTransfer', minutes: 10,
            startTime: '0000', endTime: '2359', sourceRef: { member: 'ALF' } },
        { id: 'BC', origin: 'BBB', destination: 'CCC', mode: 'tubeTransfer', minutes: 20,
            startTime: '0000', endTime: '2359', sourceRef: { member: 'ALF' } }
    ] } });
    return { index, stations };
}
const query = (direction = 'earliest', overrides = {}) => ({ from: 'AAA', to: 'BBB', direction,
    allowedModes: ['tubeTransfer'], extraConnectionMinutes: 2,
    ...(direction === 'latest' ? { departure: zero + 100 * MINUTE } : { arrival: zero }), ...overrides });

test('fallback resolution and validation never iterate unrelated stations, including custom access allowances in both directions', async () => {
    for (const [status, reason] of [['unavailable', 'upstream'], ['unavailable', 'requestLimit'], ['unmapped', 'unmapped']]) {
        for (const direction of ['earliest', 'latest']) {
            const { index, stations } = fixture();
            const beforeA = stations.get('AAA'), beforeB = stations.get('BBB'), unused = stations.get('unused:4999');
            const resolve = createTubeResolver({
                mapping: crs => ({ AAA: { exitMinutes: 3, accessWalkingMinutes: 2 },
                    BBB: { entryMinutes: 4, accessWalkingMinutes: 1 } })[crs],
                lookup: async () => ({ status, journeys: [], meta: { reason } })
            });
            const [connection] = await resolve(index, query(direction));
            assert.ok(connection);
            assert.equal(connection.minutes, 22);
            assert.equal(connection.breakdown.exitMinutes, 5);
            assert.equal(connection.breakdown.entryMinutes, 5);
            assert.equal(connection.breakdown.extraMinutes, 2);
            assert.equal(direction === 'latest' ? connection.end : connection.start,
                direction === 'latest' ? zero + 100 * MINUTE : zero);
            assert.equal(validateTubeConnection(index, connection, 2), true);
            assert.equal(validateTubeConnection(index, { ...connection, end: connection.end + 1 }, 2), false);
            assert.match(connection.localJourney.notes[0], reason === 'requestLimit' ? /search allowance/
                : status === 'unmapped' ? /not available for this station/ : /directions are unavailable/);
            assert.equal(index.stations, stations);
            assert.equal(stations.size, 5003);
            assert.equal(stations.get('AAA'), beforeA);
            assert.equal(stations.get('BBB'), beforeB);
            assert.equal(stations.get('unused:4999'), unused);
        }
    }
});

test('repeated fallback pairs use current endpoint allowances without mutating earlier results or the source map', async () => {
    const { index, stations } = fixture();
    const mappings = { AAA: { exitMinutes: 1 }, BBB: { entryMinutes: 2 } };
    let lookups = 0;
    const resolve = createTubeResolver({ mapping: crs => mappings[crs], lookup: async () => {
        lookups++;
        return { status: 'unavailable', journeys: [], meta: { reason: 'upstream' } };
    } });
    const [first] = await resolve(index, query());
    assert.equal(first.minutes, 15);
    mappings.AAA = { exitMinutes: 8, accessWalkingMinutes: 3 };
    mappings.BBB = { entryMinutes: 9, exitMinutes: 4, accessWalkingMinutes: 2 };
    const [second] = await resolve(index, query());
    assert.equal(second.minutes, 34);
    assert.equal(first.minutes, 15);
    assert.equal(first.breakdown.exitMinutes, 1);
    assert.equal(first.breakdown.entryMinutes, 2);
    mappings.CCC = { entryMinutes: 2, accessWalkingMinutes: 4 };
    const [differentPair] = await resolve(index, query('earliest', { from: 'BBB', to: 'CCC' }));
    assert.equal(differentPair.minutes, 34);
    assert.equal(differentPair.breakdown.exitMinutes, 6);
    assert.equal(differentPair.breakdown.entryMinutes, 6);
    for (const connection of [first, second, differentPair]) assert.equal(validateTubeConnection(index, connection, 2), true);
    assert.equal(lookups, 3, 'Different movement instants and pairs retain independent provider observations');
    assert.equal(stations.get('AAA').minimumChangeMinutes, 7);
    assert.equal(stations.get('BBB').minimumChangeMinutes, 9);
    assert.equal(stations.get('CCC').minimumChangeMinutes, 11);
});

test('fallback optimization retains confirmed closure exclusion and known major-disruption warnings', async () => {
    for (const direction of ['earliest', 'latest']) for (const closed of [true, false]) {
        const { index } = fixture();
        const resolve = createTubeResolver({ lookup: async () => ({ status: 'unavailable',
            meta: { reason: 'requestLimit', disruptionEvidenceForTime: new Date(zero).toISOString() },
            journeys: [{ disruption: { status: 'majorIssues', coverage: 'unknown', issues: [{ id: 'known',
                description: closed ? 'Confirmed closure' : 'Known severe delays', severity: 'major',
                statusDescription: closed ? 'Closed' : 'Severe Delays' }] } }] }) });
        const connections = await resolve(index, query(direction));
        if (closed) {
            assert.deepEqual(connections, []);
            assert.match([...resolve.state.notes].join(' '), /confirmed TfL closure/);
        } else {
            assert.equal(connections.length, 1);
            assert.equal(connections[0].disruptionRank, 2);
            assert.match(connections[0].localJourney.warnings.join(' '), /Known severe delays/);
            assert.match(connections[0].localJourney.notes.join(' '), /Previously reported disruption/);
            assert.equal(validateTubeConnection(index, connections[0], 2), true);
        }
    }
});

test('coincident endpoint overlays retain destination-entry-wins insertion semantics', async () => {
    const { index, stations } = fixture();
    // Self-pairs are not emitted by the importer. Exercise the resolver's
    // existing duplicate-endpoint behavior without changing that policy.
    index.pairs.set('AAA|AAA', [{ id: 'self', origin: 'AAA', destination: 'AAA', mode: 'tubeTransfer',
        minutes: 10, startTime: '0000', endTime: '2359' }]);
    const resolve = createTubeResolver({ mapping: () => ({ exitMinutes: 8, entryMinutes: 3 }),
        lookup: async () => ({ status: 'unavailable', journeys: [], meta: { reason: 'upstream' } }) });
    const [connection] = await resolve(index, query('earliest', { to: 'AAA' }));
    assert.equal(connection.mode, 'interchange');
    assert.equal(connection.minutes, 5, 'The destination entry allowance replaces the origin exit allowance');
    assert.equal(stations.get('AAA').minimumChangeMinutes, 7);
});
