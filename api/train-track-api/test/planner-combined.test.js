import test from 'node:test';
import assert from 'node:assert/strict';
import { CombinedPlannerEngine, normalizeCombinedRequest, combinedStations } from '../lib/planner/combined.js';
import { createConnectionIndex } from '../lib/planner/connections.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { plannerConfig } from '../lib/planner/service.js';

const at = time => Date.parse(`2026-10-09T${time}:00Z`), iso = value => new Date(value).toISOString();
const stations = [
    { id: 'tube:A', name: 'Tube A', stopIds: [], railCodes: [], tflId: 'tube:A' },
    { id: 'tube:B', name: 'Tube B', stopIds: [], railCodes: [], tflId: 'tube:B' },
    { id: 'nr:AAA', name: 'Rail A', stopIds: [], railCodes: ['AAA'], tflId: null },
    { id: 'nr:BBB', name: 'Rail B', stopIds: [], railCodes: ['BBB'], tflId: null }
];
function fixture({ unavailable = false, replacement = false, liveUpdate } = {}) {
    const clock = () => liveUpdate ? at('10:50') : at('06:00');
    const repo = { version: 'a'.repeat(64), metadata: { source: { generationDate: '2026-10-01' },
        importedAt: iso(at('06:00')), maxEventDayOffset: 0, coverage: { startDate: '2026-10-01', endDate: '2026-12-01' } },
    stations: ['AAA', 'BBB'].map(crs => ({ crs, name: crs, aliases: [], minimumChangeMinutes: 5 })),
    rules: { links: [], tsi: [] }, resolveServices: date => ({ diagnostics: { counts: {} }, services: date === '2026-10-09' ? [
        { id: 'train1', uid: 'T1', originDate: date, operator: 'SE', mode: replacement ? 'replacementBus' : 'rail', calls: [
            { station: 'AAA', departure: at('11:20'), canBoard: true, sequence: 0 },
            { station: 'BBB', arrival: at('11:40'), canAlight: true, sequence: 1 }
        ] }
    ] : [] }), close() {} };
    const base = new PlannerEngine({ ...plannerConfig({}), datasetPath: '/test', timeoutMs: 10000 }, {
        openDataset: async () => repo, now: clock,
        liveProvider: {
            async fetchBoards(codes) {
                assert.ok(codes.every(code => /^[A-Z]{3}$/.test(code)), 'virtual TfL IDs must not reach the live rail API');
                if (liveUpdate === 'unavailable') return { boards: [], errors: [{ reason: 'connectivity' }], requestCount: 0 };
                return { boards: codes.map(station => ({ station, generatedAt: iso(clock()), fetchedAt: iso(clock()), areServicesAvailable: true,
                    services: station === 'AAA' ? [{ serviceID: 'live:T1', serviceType: 'train', operatorCode: 'SE',
                        std: '12:20', etd: liveUpdate === 'delayed' ? '12:30' : 'On time', isCancelled: liveUpdate === 'cancelled',
                        origin: [{ crs: 'AAA' }], destination: [{ crs: 'BBB' }] }] : [] })), errors: [], requestCount: codes.length };
            },
            async fetchDetails(references) {
                return { details: references.map(reference => ({ ...reference, generatedAt: iso(clock()), fetchedAt: iso(clock()), detail: {
                    crs: 'AAA', operatorCode: 'SE', serviceType: 'train', std: '12:20',
                    etd: liveUpdate === 'delayed' ? '12:30' : 'On time', isCancelled: liveUpdate === 'cancelled',
                    previousCallingPoints: [], subsequentCallingPoints: [{ callingPoint: [{ crs: 'BBB', st: '12:40',
                        et: liveUpdate === 'delayed' ? '12:55' : 'On time' }] }]
                } })), errors: [], requestCount: references.length };
            }
        }
    });
    const provider = { mappings: { AAA: { routingId: 'AAA' }, BBB: { routingId: 'BBB' } },
        mapping(code) { return this.mappings[code]; },
        async lookup({ from, to, time, timeMode, accessibility }) {
            if (unavailable) return { status: 'unavailable', journeys: [], meta: {}, expiresAt: null };
            // Tube A accesses Rail A; Rail B accesses Tube B. Direct Tube A-B
            // takes an hour, so the rail shortcut must be found and preferred.
            const minutes = from === 'tube:A' && to === 'tube:B' ? 60
                : from === 'tube:A' && to === 'AAA' || from === 'BBB' && to === 'tube:B' ? 10 : 90;
            const end = timeMode === 'arriveBy' ? Date.parse(time) : Date.parse(time) + minutes * 60000;
            const start = end - minutes * 60000;
            const disruption = { status: 'noIssues', coverage: 'complete', issues: [], sources: [] };
            return { status: 'available', expiresAt: iso(clock() + 60000), meta: { updatedAt: iso(clock()) },
                journeys: [{ id: `${from}-${to}-${start}`, departureTime: iso(start), arrivalTime: iso(end), disruption,
                    warnings: [], legs: [{ id: '0', mode: 'tube', instruction: `Take Tube to ${to}`, from: { id: from, name: from },
                        to: { id: to, name: to }, departureTime: iso(start), arrivalTime: iso(end), lines: [{ id: 'victoria', name: 'Victoria' }],
                        timing: 'estimated', durationMinutes: minutes, warnings: [], stops: [], disruption }] }] };
        }
    };
    return { base, engine: new CombinedPlannerEngine(base, { stations, provider }) };
}
const request = (origin, destination, extra = {}) => ({ request: { origin, destination, fromID: origin, toID: destination,
    time: iso(at('11:00')), timeType: 'departAfter', maxChanges: 5, windowMinutes: 120, limit: 10,
    allowedModes: ['rail', 'replacementBus', 'walk', 'tubeTransfer'], accessibility: 'none', ...extra } });

test('combined contract accepts every map endpoint, limits modes, and keeps v3 IDs separate', () => {
    const tube = combinedStations.find(s => !s.railCodes.length && s.tflId);
    const rail = combinedStations.find(s => s.railCodes.length === 1 && !s.tflId);
    const normalized = normalizeCombinedRequest({ origin: tube.id, destination: rail.id, time: iso(at('11:00')), timeType: 'arriveBy' });
    assert.equal(normalized.request.origin, tube.id);
    assert.equal(normalized.request.destination, rail.railCodes[0]);
    assert.equal(normalized.request.realtime, 'apply');
    assert.deepEqual(normalized.request.allowedModes, ['rail', 'replacementBus', 'tubeTransfer', 'walk']);
    assert.throws(() => normalizeCombinedRequest({ origin: 'EUS', destination: rail.id }), { code: 'INVALID_STATION' });
    assert.throws(() => normalizeCombinedRequest({ origin: tube.id, destination: rail.id, algorithm: 'raptor' }), { code: 'INVALID_REQUEST' });
});

for (const [from, to] of [['tube:A', 'BBB'], ['AAA', 'tube:B'], ['tube:A', 'tube:B'], ['AAA', 'BBB']]) {
    test(`${from} to ${to} finds a complete connected rail journey`, async () => {
        const { engine, base } = fixture();
        const result = await engine.search(request(from, to));
        assert.ok(result.journeys.length, JSON.stringify(result));
        assert.ok(result.journeys.some(j => j.legs.some(l => l.serviceId === 'train1')));
        assert.equal(result.apiVersion, 5);
        assert.deepEqual(result.pagination, {});
        assert.equal((await base.dataset()).stations.length, 2);
        if (from === 'tube:A' && to === 'tube:B') {
            assert.equal(result.journeys[0].arrival, iso(at('11:55')));
            assert.equal(result.journeys[0].changes, 2);
        }
    });
}

test('arrive-by includes access and interchange time in both networks', async () => {
    const { engine } = fixture();
    const result = await engine.search(request('tube:A', 'tube:B', { time: iso(at('11:55')), timeType: 'arriveBy' }));
    const rail = result.journeys.find(j => j.legs.some(l => l.serviceId === 'train1'));
    assert.ok(rail);
    assert.equal(rail.departure, iso(at('11:05')));
    assert.equal(rail.arrival, iso(at('11:55')));
});

test('missing TfL directions never turn a dynamic search bound into a one-minute journey', async () => {
    const { engine } = fixture({ unavailable: true });
    const result = await engine.search(request('tube:A', 'BBB'));
    assert.deepEqual(result.journeys, []);
    const railOnly = await engine.search(request('AAA', 'BBB'));
    assert.equal(railOnly.journeys.length, 1);
});

test('official replacement buses remain selectable vehicle legs', async () => {
    const { engine } = fixture({ replacement: true });
    const result = await engine.search(request('tube:A', 'BBB'));
    assert.ok(result.journeys.some(j => j.legs.some(l => l.mode === 'replacementBus')));
});

test('live rail delay changes the onward Tube connection before ranking', async () => {
    const { engine } = fixture({ liveUpdate: 'delayed' });
    const result = await engine.search(request('AAA', 'tube:B', { realtime: 'apply' }));
    assert.ok(result.journeys.length);
    const train = result.journeys[0].legs.find(l => l.serviceId === 'train1');
    assert.equal(train.live.status, 'delayed');
    assert.equal(train.arrival, iso(at('11:55')));
    assert.equal(result.journeys[0].arrival, iso(at('12:10')));
});

test('cancelled rail is excluded while a feasible TfL alternative survives', async () => {
    const { engine } = fixture({ liveUpdate: 'cancelled' });
    const result = await engine.search(request('tube:A', 'tube:B', { realtime: 'apply' }));
    assert.ok(result.journeys.length);
    assert.ok(result.journeys.every(j => j.legs.every(l => l.serviceId !== 'train1')));
});

test('unavailable live rail keeps timetable routes with an explicit warning', async () => {
    const { engine } = fixture({ liveUpdate: 'unavailable' });
    const result = await engine.search(request('tube:A', 'BBB', { realtime: 'apply' }));
    assert.ok(result.journeys.length);
    assert.equal(result.live.status, 'unavailable');
    assert.match(result.warnings.join(' '), /scheduled|Live information is not available/);
});


test('map catalogue keeps distinct Tube and railway stations separate', () => {
    const codes = combinedStations.flatMap(station => station.railCodes);
    assert.equal(new Set(codes).size, codes.length);
    assert.deepEqual(combinedStations.find(s => s.id === '940GZZLUBLG').railCodes, []);
    assert.deepEqual(combinedStations.find(s => s.id === '940GZZLUSWK').railCodes, []);
});

test('dynamic endpoint lookups can use the reserved capacity and never scan the next day', async () => {
    const { engine } = fixture();
    const original = engine.provider.lookup.bind(engine.provider);
    let calls = 0;
    engine.provider.lookup = async args => {
        if (args.budget.used >= args.budget.limit) return { status: 'unavailable', meta: { reason: 'requestLimit' } };
        args.budget.used++;
        calls++;
        return original(args);
    };
    const index = createConnectionIndex({ stations: new Map([['AAA', { crs: 'AAA' }], ['tube:B', { crs: 'tube:B' }]]),
        rules: { links: [{ id: 'dynamic:AAA:tube:B', origin: 'AAA', destination: 'tube:B', mode: 'tubeTransfer', minutes: 1 }] } });
    const resolve = await engine.tubeResolver();
    resolve.reserveForResults();
    for (let i = 0; i < 13; i++) {
        const result = await resolve(index, { from: 'AAA', to: 'tube:B', arrival: at('11:00') + i * 60000,
            direction: 'earliest', destinationIsEndpoint: true, allowedModes: new Set(['tubeTransfer']) });
        assert.ok(result.length, 'Essential endpoint must not disappear at the speculative half-budget');
    }
    assert.equal(calls, 13);
    let emptyCalls = 0;
    engine.provider.lookup = async () => { emptyCalls++; return { status: 'available', journeys: [], expiresAt: iso(at('06:01')), meta: {} }; };
    const empty = await engine.tubeResolver();
    await empty(index, { from: 'AAA', to: 'tube:B', arrival: at('11:00'), direction: 'earliest', allowedModes: new Set(['tubeTransfer']) });
    assert.equal(emptyCalls, 1, 'Do not query tomorrow for a six-hour journey');
});

test('a lookup-limited empty result is an incomplete search, not proof of no journeys', async () => {
    const { engine } = fixture();
    engine.provider.lookup = async () => ({ status: 'unavailable', journeys: [], meta: { reason: 'requestLimit' } });
    await assert.rejects(engine.search(request('AAA', 'tube:B')), { code: 'SEARCH_INCOMPLETE' });
});

test('station closure notices survive when every TfL journey is beyond the search window', async () => {
    const { engine } = fixture();
    const original = engine.provider.lookup.bind(engine.provider);
    engine.provider.lookup = async args => {
        const result = await original({ ...args, time: iso(at('23:00')) });
        return { ...result, messages: ['Arsenal: Closed - This station is closed due to infrastructure damage within the station.'] };
    };
    const result = await engine.search(request('AAA', 'tube:B'));
    assert.equal(result.journeys.length, 0);
    assert.ok(result.warnings.some(message => message.includes('Arsenal: Closed')));
});

test('v5 rail legs expose the shared TrainTrack operator branding catalogue', async () => {
    const { engine } = fixture();
    const result = await engine.search(request('AAA', 'BBB'));
    const leg = result.journeys[0].legs.find(leg => leg.operator === 'SE');
    assert.deepEqual(leg.operatorBranding, { name: 'Southeastern', colour: '#1D2452' });
});
