import test from 'node:test';
import assert from 'node:assert/strict';
import { PlannerEngine } from '../lib/planner/engine.js';
import { plannerConfig } from '../lib/planner/service.js';

const DATE = '2026-09-19', VERSION = 'd'.repeat(64), MINUTE = 60000;
const zero = Date.parse(`${DATE}T08:00:00Z`);
const at = minutes => zero + minutes * MINUTE;
function train(id, calls, mode = 'rail') {
    return { id, uid: id, variantId: id, originDate: DATE, operator: 'OP', mode,
        calls: calls.map(([station, arrival, departure = arrival], sequence) => ({ station, tiploc: station, sequence,
            arrival: arrival === null ? null : at(arrival), departure: departure === null ? null : at(departure),
            canBoard: departure !== null, canAlight: arrival !== null })) };
}
function fixture(t, services, diagnostics = {}, links = []) {
    const stations = ['AAA', 'BBB', 'CCC', 'DDD'].map(crs => ({ crs, name: crs, minimumChangeMinutes: 5 }));
    const repo = { version: VERSION, stations, allStations: stations, rules: { tsi: [], links },
        metadata: { source: { generationDate: DATE }, importedAt: new Date(zero).toISOString(), maxEventDayOffset: 1,
            coverage: { startDate: '2026-01-01', endDate: '2026-12-31', basis: 'Fixture' }, limitations: [] },
        resolveServices: date => ({ services: date === DATE ? services : [], diagnostics: { counts: diagnostics } }), close() {} };
    const engine = new PlannerEngine({ ...plannerConfig({}), datasetPath: '/fixture/monitor', tubeTrackEnabled: true },
        { openDataset: async () => repo, now: () => zero,
            liveProvider: { fetchBoards() { throw new Error('Monitoring must not call live sources'); } },
            tubeProvider: { request() { throw new Error('Monitoring must not call Tube sources'); } } });
    t.after(() => engine.close());
    return engine;
}
const window = values => ({ from: 'AAA', to: 'DDD', date: DATE, startMinutes: 540, endMinutes: 600, ...values });

test('full monitoring window retains late direct trains beyond public result limits', async t => {
    const services = Array.from({ length: 12 }, (_, n) => train(`early${n}`,
        [['AAA', null, n], ['DDD', n + 10, null]]));
    services.push(train('late', [['AAA', null, 59], ['DDD', 89, null]]), train('boundary', [['AAA', null, 60], ['DDD', 65, null]]));
    const result = await fixture(t, services).disruptionProfile(window());
    assert.equal(result.complete, true);
    assert.equal(result.directTrains, 13);
    assert.equal(result.durationMinutes, 10);
    assert.equal(result.minChanges, 0);
    assert.equal(result.railOnlyAvailable, true);
    assert.equal(result.replacementBus, false);
    assert.equal(result.datasetVersion, VERSION);
    assert.equal(result.sourceGenerationDate, DATE);
});

test('ordered intermediate stations and journey direction constrain direct counts and routing', async t => {
    const engine = fixture(t, [train('wrong', [['AAA', null, 0], ['CCC', 5, 6], ['BBB', 10, 11], ['DDD', 20, null]]),
        train('right', [['AAA', null, 30], ['BBB', 35, 36], ['CCC', 40, 41], ['DDD', 50, null]])]);
    const result = await engine.disruptionProfile(window({ via: ['BBB', 'CCC'] }));
    assert.equal(result.complete, true);
    assert.equal(result.directTrains, 1);
    assert.deepEqual(result.stationCRS, ['AAA', 'BBB', 'CCC', 'DDD']);
    const reverse = await engine.disruptionProfile(window({ from: 'DDD', to: 'AAA', via: ['CCC', 'BBB'] }));
    assert.equal(reverse.complete, true);
    assert.equal(reverse.directTrains, 0);
    assert.equal(reverse.servicesAvailable, false);
    assert.equal(reverse.durationMinutes, null);
});

test('a fast bus must not conceal an ordinary connecting rail alternative', async t => {
    const engine = fixture(t, [train('bus', [['AAA', null, 0], ['DDD', 10, null]], 'replacementBus'),
        train('feeder', [['AAA', null, 0], ['BBB', 20, null]]),
        train('connection', [['BBB', null, 30], ['DDD', 60, null]])]);
    const result = await engine.disruptionProfile(window());
    assert.equal(result.complete, true);
    assert.equal(result.servicesAvailable, true);
    assert.equal(result.railOnlyAvailable, true);
    assert.equal(result.replacementBus, false);
    assert.equal(result.directTrains, 0);
});

test('a replacement bus is reported only when supported routes require it', async t => {
    const engine = fixture(t, [train('bus', [['AAA', null, 5], ['BBB', 20, 21], ['DDD', 65, null]], 'replacementBus')]);
    const result = await engine.disruptionProfile(window({ via: ['BBB'] }));
    assert.equal(result.complete, true);
    assert.equal(result.replacementBus, true);
    assert.equal(result.railOnlyAvailable, false);
    assert.equal(result.durationMinutes, 60);
    const rail = await engine.disruptionProfile(window({ allowedModes: ['rail', 'walk'] }));
    assert.equal(rail.servicesAvailable, false);
    assert.equal(rail.replacementBus, false);
});

test('overnight windows include previous-origin-date trains and half-open boundaries', async t => {
    const engine = fixture(t, [train('overnight', [['AAA', null, 900], ['BBB', 920, 921], ['DDD', 950, null]]),
        train('edge', [['AAA', null, 915], ['DDD', 960, null]])]);
    const result = await engine.disruptionProfile(window({ startMinutes: 1425, endMinutes: 1455 }));
    assert.equal(result.complete, true);
    assert.equal(result.directTrains, 1);
    assert.equal(result.durationMinutes, 50);
});

test('arbitrary one-minute windows use exact departure bounds', async t => {
    const result = await fixture(t, [train('inside', [['AAA', null, 5], ['DDD', 25, null]]),
        train('outside', [['AAA', null, 6], ['DDD', 10, null]])]).disruptionProfile(window({ startMinutes: 545, endMinutes: 546 }));
    assert.equal(result.complete, true);
    assert.equal(result.directTrains, 1);
    assert.equal(result.durationMinutes, 20);
});

test('clock-change ambiguity, truncated frontiers and budget failures remain unknown', async t => {
    const engine = fixture(t, []);
    const autumn = await engine.disruptionProfile(window({ date: '2026-10-25', startMinutes: 60, endMinutes: 120 }));
    assert.equal(autumn.reason, 'CLOCK_CHANGE');
    assert.equal(autumn.datasetVersion, VERSION);
    assert.equal((await engine.disruptionProfile(window({ date: '2026-03-29', startMinutes: 60, endMinutes: 120 }))).complete, false);
    engine.routeBoardProfileChunk = async () => ({ profile: { candidates: [], profile: { complete: false }, searchTruncated: true } });
    assert.equal((await engine.disruptionProfile(window())).complete, false);
    engine.routeBoardProfileChunk = async () => { throw Object.assign(new Error('budget'), { code: 'SEARCH_TIMEOUT' }); };
    assert.equal((await engine.disruptionProfile(window())).reason, 'SEARCH_TIMEOUT');
    await assert.rejects(engine.disruptionProfile(window(), { aborted: true }), { code: 'SEARCH_CANCELLED' });
    await assert.rejects(engine.disruptionProfile(window({ endMinutes: 601 })), { code: 'INVALID_REQUEST' });
});

test('missing service data is never a complete negative profile', async t => {
    const result = await fixture(t, [], { INVALID_SERVICE_TIME: 1 }).disruptionProfile(window());
    assert.equal(result.complete, false);
    assert.equal(result.reason, 'INCOMPLETE_TIMETABLE');
});

test('known unsupported timetable categories disclose limitations without claiming malformed data', async t => {
    const result = await fixture(t, [train('normal', [['AAA', null, 5], ['DDD', 25, null]])],
        { UNSUPPORTED_ACTIVITY: 1, CANCELLED: 1 }).disruptionProfile(window());
    assert.equal(result.complete, true);
    assert.deepEqual(result.diagnosticCodes, ['UNSUPPORTED_ACTIVITY']);
    assert.ok(Array.isArray(result.limitations));
});

test('the full profile candidate cap cannot hide incomplete monitoring coverage', async t => {
    const result = await fixture(t, Array.from({ length: 514 }, (_, n) => train(`T${n}`,
        [['AAA', null, n / 10], ['DDD', n / 10 + 10, null]]))).disruptionProfile(window({ maxChanges: 0 }));
    assert.equal(result.directTrains, 514);
    assert.equal(result.complete, false);
    assert.equal(result.reason, 'INCOMPLETE_TIMETABLE');
});

test('national excluded variants and fixed-link warnings remain coverage limitations', async t => {
    const engine = fixture(t, [train('normal', [['AAA', null, 5], ['DDD', 25, null]])], { CONFLICTING_VARIANTS: 1 });
    const build = engine.routeBoardProfileChunk.bind(engine);
    engine.routeBoardProfileChunk = async (...args) => {
        const result = await build(...args);
        result.profile.warnings.push('Overlapping fixed links with conflicting equal priorities were excluded.');
        return result;
    };
    const result = await engine.disruptionProfile(window());
    assert.equal(result.complete, true);
    assert.deepEqual(result.diagnosticCodes, ['CONFLICTING_VARIANTS']);
    assert.ok(result.limitations.some(value => value.includes('conflicting equal priorities')));
    assert.equal(result.durationMinutes, 20);
});

test('an unclassified fixed transfer is not labelled all-rail or proof a bus is required', async t => {
    const engine = fixture(t, [train('bus', [['AAA', null, 0], ['DDD', 10, null]], 'replacementBus')], {},
        [{ id: 'generic', origin: 'AAA', destination: 'DDD', mode: 'genericTransfer', minutes: 20 }]);
    const result = await engine.disruptionProfile(window());
    assert.equal(result.complete, true);
    assert.equal(result.servicesAvailable, true);
    assert.equal(result.railOnlyAvailable, false);
    assert.equal(result.replacementBus, false);
});
