import test from 'node:test';
import assert from 'node:assert/strict';
import { TubeTrackProvider } from '../lib/planner/tube-provider.js';

const NOW = Date.parse('2026-09-19T11:00:00Z');
const query = { from: 'WAT', to: 'KGX', time: NOW, timeMode: 'departAt' };
const iso = offset => new Date(NOW + offset).toISOString();
const response = value => ({ ok: true, json: async () => structuredClone(value) });
const colours = { data: [{ id: 'bakerloo', name: 'Bakerloo', mode: 'tube', colour: '#123456', textColour: '#FFFFFF' }] };
const issue = { id: 'closed', severity: 'major', kind: 'line', lineId: 'bakerloo', statusDescription: 'Closed',
    validityPeriods: [{ from: iso(-60_000), to: iso(3_600_000) }], stale: false };
function payload(changes = {}) {
    return { data: { journeys: [{ id: 'route', departureTime: iso(60_000), arrivalTime: iso(900_000),
        disruption: { status: 'majorIssues', issues: [issue], coverage: 'complete' },
        legs: [{ id: '0', mode: 'tube', instruction: 'Take the Bakerloo line', departureTime: iso(60_000), arrivalTime: iso(900_000),
            lines: [{ id: 'bakerloo', name: 'Bakerloo', direction: 'Elephant & Castle' }],
            from: { id: '940GZZLUWLO', name: 'Waterloo' }, to: { id: '940GZZLUKSX', name: 'Kings Cross' },
            disruption: { status: 'majorIssues', issues: [issue] }, stops: [] }] }],
        expiresAt: iso(20_000), messages: ['Current line warning'], ...changes },
    meta: { stale: false, updatedAt: iso(0), source: 'tfl' } };
}
function setup(options = {}) {
    const calls = [];
    const provider = new TubeTrackProvider({ now: () => NOW, fetch: async url => {
        calls.push(url);
        return response(url.includes('/line-colours') ? colours : payload());
    }, ...options });
    return { provider, calls };
}
const tick = () => new Promise(resolve => setImmediate(resolve));

test('reviewed mapping retains all hub stops, distinct rail identities and explicit missing mappings', () => {
    const { provider } = setup();
    assert.equal(provider.mapping('wat').routingId, '940GZZLUWLO');
    assert.equal(provider.mapping('PAD').routingId, 'HUBPAD');
    assert.equal(provider.mapping('PAD').stopIds.length, 4);
    assert.equal(provider.mapping('STP').routingId, provider.mapping('KGX').routingId);
    assert.equal(provider.mapping('BET').routingId, '910GBTHNLGR');
    assert.equal(provider.mapping('RDG'), null);
    assert.equal(provider.mapping('FST').routingId, '940GZZLUTWH');
    assert.equal(provider.mapping('FST').accessWalkingMinutes, 3);
    assert.equal(provider.mapping('CTK').routingId, '940GZZLUBKF');
    assert.equal(provider.mapping('CTK').accessWalkingMinutes, 5);
    assert.equal(provider.mapping('WAE').routingId, '940GZZLUSWK');
    assert.equal(provider.mapping('WHP'), null);
});

test('sends zoned instants and mapped IDs and preserves disruptions with API palette', async () => {
    const { provider, calls } = setup();
    const value = await provider.lookup({ ...query, time: '2026-09-19T12:00:00+01:00', timeMode: 'arriveBy' });
    const url = new URL(calls.find(url => url.includes('/journeys')));
    assert.equal(url.searchParams.get('time'), iso(0));
    assert.equal(url.searchParams.get('timeMode'), 'arriveBy');
    assert.equal(url.searchParams.get('from'), '940GZZLUWLO');
    assert.equal(url.searchParams.get('to'), '940GZZLUKSX');
    assert.equal(value.status, 'available');
    assert.equal(value.journeys[0].legs[0].lines[0].colour, '#123456');
    assert.equal(value.journeys[0].legs[0].lines[0].direction, 'Elephant & Castle');
    assert.deepEqual(value.journeys[0].disruption.issues, [issue]);
    assert.deepEqual(value.journeys[0].legs[0].disruption.issues, [issue]);
});

test('returns unmapped without an upstream request and preserves successful empty results', async () => {
    const { provider, calls } = setup();
    assert.equal((await provider.lookup({ ...query, from: 'WHP' })).status, 'unmapped');
    assert.equal(calls.length, 0);
    const empty = setup({ fetch: async url => response(url.includes('/line-colours') ? colours : payload({ journeys: [] })) });
    const result = await empty.provider.lookup(query);
    assert.equal(result.status, 'available');
    assert.deepEqual(result.journeys, []);
});

test('shares inflight journeys, counts actual journey requests and isolates caller mutations', async () => {
    let release;
    let journeyCalls = 0;
    const { provider } = setup({ fetch: async url => {
        if (url.includes('/line-colours')) return response(colours);
        journeyCalls++;
        await new Promise(resolve => { release = resolve; });
        return response(payload());
    } });
    const a = { limit: 1, used: 0 };
    const b = { limit: 0, used: 0 };
    const first = provider.lookup({ ...query, budget: a });
    const second = provider.lookup({ ...query, budget: b });
    await tick();
    release();
    const [one, two] = await Promise.all([first, second]);
    assert.equal(journeyCalls, 1);
    assert.equal(a.used, 1);
    assert.equal(b.used, 0);
    one.journeys[0].legs[0].lines[0].colour = '#000000';
    assert.equal(two.journeys[0].legs[0].lines[0].colour, '#123456');
    assert.equal((await provider.lookup({ ...query, budget: b })).journeys[0].legs[0].lines[0].colour, '#123456');
    assert.equal(journeyCalls, 1);
});

test('cancelling one consumer leaves the shared request available to another', async () => {
    let release;
    let upstreamSignal;
    const { provider } = setup({ fetch: async (url, options) => {
        if (url.includes('/line-colours')) return response(colours);
        upstreamSignal = options.signal;
        await new Promise(resolve => { release = resolve; });
        return response(payload());
    } });
    const controller = new AbortController();
    const cancelled = provider.lookup({ ...query, signal: controller.signal });
    const survives = provider.lookup(query);
    await tick();
    controller.abort();
    await assert.rejects(cancelled, { code: 'SEARCH_CANCELLED' });
    assert.equal(upstreamSignal.aborted, false);
    release();
    assert.equal((await survives).status, 'available');
});

test('upstream expiresAt limits caching; an outage retains known closure observations as stale', async () => {
    let now = NOW;
    let offline = false;
    const { provider } = setup({ now: () => now, fetch: async url => {
        if (url.includes('/line-colours')) return response(colours);
        if (offline) throw new Error('offline');
        return response(payload());
    } });
    assert.equal((await provider.lookup(query)).status, 'available');
    offline = true;
    now += 19_999;
    assert.equal((await provider.lookup(query)).status, 'available');
    now++;
    const failed = await provider.lookup(query);
    assert.equal(failed.status, 'unavailable');
    assert.equal(failed.meta.stale, true);
    assert.equal(failed.meta.reason, 'connectivity');
    assert.equal(failed.expiresAt, iso(20_000));
    assert.deepEqual(failed.journeys[0].disruption.issues, [issue]);
    assert.equal(failed.journeys[0].departureTime, undefined);
    assert.equal(failed.meta.disruptionEvidenceForTime, iso(0));
});

test('outage evidence follows a nearby refresh but preserves unaffected alternatives and expires with the issue', async () => {
    let offline = false;
    const { provider } = setup({ fetch: async url => {
        if (url.includes('/line-colours')) return response(colours);
        if (offline) throw new Error('offline');
        const raw = payload();
        const unaffected = structuredClone(raw.data.journeys[0]);
        unaffected.id = 'unaffected';
        unaffected.disruption.issues = [];
        unaffected.legs[0].disruption.issues = [];
        raw.data.journeys.push(unaffected);
        return response(raw);
    } });
    await provider.lookup(query);
    offline = true;
    const refresh = await provider.lookup({ ...query, time: NOW + 60_000 });
    assert.equal(refresh.status, 'unavailable');
    assert.equal(refresh.journeys.length, 2);
    assert.deepEqual(refresh.journeys[0].disruption.issues, [issue]);
    assert.deepEqual(refresh.journeys[1].disruption.issues, []);
    assert.equal(refresh.journeys[0].departureTime, undefined);
    assert.equal(refresh.journeys[0].legs[0].arrivalTime, undefined);
    assert.equal(refresh.meta.disruptionEvidenceForTime, iso(60_000));
    assert.deepEqual((await provider.lookup({ ...query, time: NOW + 3_600_001 })).journeys, []);
});

test('pair evidence excludes undated warnings and does not carry across distant searches', async () => {
    let offline = false;
    const raw = payload();
    for (const disruption of [raw.data.journeys[0].disruption, raw.data.journeys[0].legs[0].disruption]) {
        disruption.issues = [{ ...issue, validityPeriods: [] }];
    }
    const { provider } = setup({ fetch: async url => {
        if (url.includes('/line-colours')) return response(colours);
        if (offline) throw new Error('offline');
        return response(raw);
    } });
    await provider.lookup(query);
    offline = true;
    assert.deepEqual((await provider.lookup({ ...query, time: NOW + 60_000 })).journeys, []);
    assert.deepEqual((await provider.lookup({ ...query, time: NOW + 3 * 3_600_000 })).journeys, []);
});

test('explicit stale and expired responses never become fresh cached directions', async () => {
    for (const raw of [{ ...payload(), meta: { stale: true } }, payload({ expiresAt: iso(-1) })]) {
        let count = 0;
        const { provider } = setup({ fetch: async url => {
            if (url.includes('/line-colours')) return response(colours);
            count++;
            return response(raw);
        } });
        for (let i = 0; i < 2; i++) {
            const value = await provider.lookup(query);
            assert.equal(value.status, 'unavailable');
            assert.equal(value.meta.stale, true);
            assert.deepEqual(value.journeys[0].disruption.issues, [issue]);
        }
        assert.equal(count, 2);
    }
});

test('request limits prevent new fetches and preserve an expired known warning', async () => {
    let now = NOW;
    const { provider, calls } = setup({ now: () => now });
    const budget = { limit: 1, used: 0 };
    await provider.lookup({ ...query, budget });
    now += 20_000;
    const limited = await provider.lookup({ ...query, budget });
    assert.equal(limited.meta.reason, 'requestLimit');
    assert.equal(limited.meta.stale, true);
    assert.deepEqual(limited.journeys[0].disruption.issues, [issue]);
    assert.equal(calls.filter(url => url.includes('/journeys')).length, 1);
});

test('a complete itinerary with an unsupported mode is excluded, without losing valid rail options', async () => {
    const raw = payload();
    const unsupported = structuredClone(raw.data.journeys[0]);
    unsupported.id = 'bus-transfer';
    unsupported.legs.push({ ...unsupported.legs[0], mode: 'bus' });
    raw.data.journeys.unshift(unsupported);
    const { provider } = setup({ fetch: async url => response(url.includes('/line-colours') ? colours : raw) });
    const value = await provider.lookup(query);
    assert.equal(value.journeys.length, 1);
    assert.equal(value.journeys[0].id, 'route');
    assert.equal(value.meta.unsupportedJourneyCount, 1);
});

test('all four permitted modes and their walking links retain their ordered legs', async () => {
    const raw = payload();
    const leg = raw.data.journeys[0].legs[0];
    raw.data.journeys[0].legs = ['walking', 'tube', 'elizabeth-line', 'dlr', 'overground']
        .map(mode => ({ ...leg, mode, lines: mode === 'walking' ? [] : leg.lines }));
    const { provider } = setup({ fetch: async url => response(url.includes('/line-colours') ? colours : raw) });
    assert.deepEqual((await provider.lookup(query)).journeys[0].legs.map(leg => leg.mode),
        ['walking', 'tube', 'elizabeth-line', 'dlr', 'overground']);
});

test('palette failures retain bundled and last-good colours, with neutral unknown lines', async () => {
    let now = NOW;
    let failPalette = false;
    const { provider } = setup({ now: () => now, fetch: async url => {
        if (url.includes('/line-colours')) {
            if (failPalette) throw new Error('palette offline');
            return response(colours);
        }
        const raw = payload({ expiresAt: new Date(now + 20_000).toISOString() });
        raw.data.journeys[0].legs[0].lines.push({ id: 'new-line', name: 'New line' });
        return response(raw);
    } });
    await provider.lookup(query);
    now += 86_400_001;
    failPalette = true;
    const value = await provider.lookup(query);
    assert.equal(value.journeys[0].legs[0].lines[0].colour, '#123456');
    assert.equal(value.journeys[0].legs[0].lines[1].colour, '#59636E');
    const bundled = setup({ fetch: async url => {
        if (url.includes('/line-colours')) throw new Error('offline');
        return response(payload());
    } });
    assert.equal((await bundled.provider.lookup(query)).journeys[0].legs[0].lines[0].colour, '#8C4512');
});

test('malformed responses and HTTP failures produce explicit unavailable reasons', async () => {
    for (const [reply, reason] of [[response({ data: {} }), 'malformed'],
        [{ ok: false, status: 429 }, 'rateLimited'], [{ ok: false, status: 500 }, 'upstream']]) {
        const { provider } = setup({ fetch: async url => url.includes('/line-colours') ? response(colours) : reply });
        const value = await provider.lookup(query);
        assert.equal(value.status, 'unavailable');
        assert.equal(value.meta.reason, reason);
    }
});

test('missing required detail fields and unzoned request times cannot reach client decoding', async () => {
    for (const change of [leg => delete leg.instruction, leg => delete leg.id,
        leg => delete leg.from.name, leg => { leg.lines[0].name = null; }]) {
        const raw = payload();
        change(raw.data.journeys[0].legs[0]);
        const { provider } = setup({ fetch: async url => response(url.includes('/line-colours') ? colours : raw) });
        assert.equal((await provider.lookup(query)).meta.reason, 'malformed');
    }
    const { provider } = setup();
    await assert.rejects(provider.lookup({ ...query, time: '2026-09-19T12:00:00' }), TypeError);
});

test('malformed optional presentation and disruption fields fall back before routing or Swift decoding', async () => {
    const invalid = [
        ['platform', raw => { raw.data.journeys[0].legs[0].from.platform = 3; }],
        ['direction', raw => { raw.data.journeys[0].legs[0].lines[0].direction = {}; }],
        ['leg timing', raw => { raw.data.journeys[0].legs[0].timing = false; }],
        ['leg duration', raw => { raw.data.journeys[0].legs[0].durationMinutes = '12'; }],
        ['negative duration', raw => { raw.data.journeys[0].legs[0].durationMinutes = -1; }],
        ['stops container', raw => { raw.data.journeys[0].legs[0].stops = {}; }],
        ['null stop', raw => { raw.data.journeys[0].legs[0].stops = [null]; }],
        ['stop platform', raw => { raw.data.journeys[0].legs[0].stops = [{ id: 'x', name: 'X', platform: [] }]; }],
        ['warnings container', raw => { raw.data.journeys[0].warnings = {}; }],
        ['null warning', raw => { raw.data.journeys[0].legs[0].warnings = [null]; }],
        ['warning text', raw => { raw.data.journeys[0].warnings = [{ message: 4 }]; }],
        ['disruption container', raw => { raw.data.journeys[0].disruption = []; }],
        ['issues container', raw => { raw.data.journeys[0].disruption.issues = {}; }],
        ['null issue', raw => { raw.data.journeys[0].legs[0].disruption.issues = [null]; }],
        ['issue description', raw => { raw.data.journeys[0].disruption.issues[0].description = {}; }],
        ['issue sources', raw => { raw.data.journeys[0].disruption.issues[0].sources = [null]; }],
        ['issue validity container', raw => { raw.data.journeys[0].disruption.issues[0].validityPeriods = {}; }],
        ['null validity', raw => { raw.data.journeys[0].disruption.issues[0].validityPeriods = [null]; }],
        ['invalid validity date', raw => { raw.data.journeys[0].disruption.issues[0].validityPeriods = [{ from: 'tomorrow' }]; }],
        ['inverted validity', raw => { raw.data.journeys[0].disruption.issues[0].validityPeriods = [{ from: iso(1), to: iso(0) }]; }],
        ['invalid closure applicability', raw => { raw.data.journeys[0].disruption.issues[0].affectsLeg = 'false'; }],
        ['sources container', raw => { raw.data.journeys[0].disruption.sources = {}; }],
        ['null source', raw => { raw.data.journeys[0].legs[0].disruption.sources = [null]; }],
        ['source checkedAt', raw => { raw.data.journeys[0].disruption.sources = [{ source: 'realtime', checkedAt: 3 }]; }],
        ['updatedAt', raw => { raw.meta.updatedAt = 'invalid'; }],
        ['stale flag', raw => { raw.meta.stale = 'true'; }],
        ['expiresAt', raw => { raw.data.expiresAt = 'invalid'; }],
        ['fractional changes', raw => { raw.data.journeys[0].changes = 1.5; }]
    ];
    for (const [name, change] of invalid) {
        const raw = structuredClone(payload());
        change(raw);
        const { provider } = setup({ fetch: async url => response(url.includes('/line-colours') ? colours : raw) });
        const first = await provider.lookup(query);
        assert.equal(first.status, 'unavailable', name);
        assert.equal(first.meta.reason, 'malformed', name);
        assert.deepEqual(first.journeys, [], name);
        // A following budget fallback must not encounter poisoned evidence.
        assert.deepEqual((await provider.lookup({ ...query, time: NOW + 1, budget: { limit: 0, used: 0 } })).journeys, [], name);
    }
});

test('nullable optional fields and unknown extension data survive normalization and evidence reuse', async () => {
    const raw = structuredClone(payload());
    const journey = raw.data.journeys[0];
    const leg = journey.legs[0];
    Object.assign(leg, { durationMinutes: 14, timing: 'futureTimingValue', stops: [{ id: '', name: 'Walking entrance', platform: null,
        futureStopField: { entrance: 4 } }], futureLegField: { data: [1, 2] } });
    leg.from.platform = null;
    leg.lines[0].direction = null;
    leg.lines[0].futureLineField = { branch: 'x' };
    journey.warnings = ["Plain warning", { message: 'Structured warning', futureWarningField: { code: 4 } }];
    journey.disruption.sources = [{ source: 'futureSource', status: 'futureStatus', checkedAt: null, futureSourceField: true }];
    journey.disruption.futureDisruptionField = { affectedSegments: ['a', 'b'] };
    journey.disruption.issues[0].futureIssueField = { certainty: 0.5 };
    raw.meta.futureMetaField = { revision: 2 };
    let offline = false;
    const { provider } = setup({ fetch: async url => {
        if (url.includes('/line-colours')) return response(colours);
        if (offline) throw new Error('offline');
        return response(raw);
    } });
    const value = await provider.lookup(query);
    assert.equal(value.status, 'available');
    assert.deepEqual(value.journeys[0].legs[0].stops, leg.stops);
    assert.deepEqual(value.journeys[0].legs[0].futureLegField, { data: [1, 2] });
    assert.deepEqual(value.journeys[0].legs[0].lines[0].futureLineField, { branch: 'x' });
    assert.deepEqual(value.journeys[0].disruption, journey.disruption);
    assert.deepEqual(value.journeys[0].warnings, journey.warnings);
    assert.deepEqual(value.meta.futureMetaField, { revision: 2 });
    offline = true;
    const evidence = await provider.lookup({ ...query, time: NOW + 1 });
    assert.deepEqual(evidence.journeys[0].disruption.issues[0].futureIssueField, { certainty: 0.5 });
});

test('awaitIO runs for network work only, never for cached, unmapped or exhausted-budget responses', async () => {
    const { provider, calls } = setup();
    let awaits = 0;
    const awaitIO = async work => { awaits++; return work(); };
    assert.equal((await provider.lookup({ ...query, awaitIO })).status, 'available');
    assert.equal(awaits, 1);
    assert.equal((await provider.lookup({ ...query, awaitIO })).status, 'available');
    assert.equal((await provider.lookup({ ...query, from: 'WHP', awaitIO })).status, 'unmapped');
    assert.equal((await provider.lookup({ ...query, time: NOW + 1, budget: { limit: 0, used: 0 }, awaitIO })).meta.reason, 'requestLimit');
    assert.equal(awaits, 1);
    assert.equal(calls.filter(url => url.includes('/journeys')).length, 1);
});

test('timeout covers a hanging request and leaves the semaphore available', async () => {
    const { provider } = setup({ timeoutMs: 15, fetch: async (url, { signal }) => {
        if (url.includes('/line-colours')) return response(colours);
        return new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }));
    } });
    // AbortSignal.timeout is unref'ed; keep the test process alive for the wait.
    const hold = setTimeout(() => {}, 100);
    try {
        assert.equal((await provider.lookup(query)).meta.reason, 'timeout');
        assert.equal(provider.active, 0);
    } finally { clearTimeout(hold); }
});

test('concurrent searches and palette refresh share a two-request bound', async () => {
    let active = 0;
    let maximum = 0;
    const releases = [];
    const { provider } = setup({ fetch: async url => {
        active++;
        maximum = Math.max(maximum, active);
        await new Promise(resolve => releases.push(resolve));
        active--;
        return response(url.includes('/line-colours') ? colours : payload());
    } });
    const pending = Promise.all(Array.from({ length: 5 }, (_, i) => provider.lookup({ ...query, time: NOW + i })));
    for (let i = 0; i < 6; i++) {
        await tick();
        releases.shift()?.();
    }
    await pending;
    assert.equal(maximum, 2);
    assert.equal(provider.active, 0);
});
