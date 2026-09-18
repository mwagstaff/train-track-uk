import assert from 'node:assert/strict';
import test from 'node:test';
import { PlannerEngine } from '../lib/planner/engine.js';
import { ROUTING_PROFILE_FIELDS } from '../lib/planner/telemetry.js';

const profile = {
    indexBuildMs: 1.25, topologyBoundsMs: 2.5, temporalBoundsMs: 3.75,
    labelExpansionMs: 4.5, transferResolutionMs: 5.25, resultAssemblyMs: 6.5,
    topologyBoundsBuilds: 1, topologyBoundsCacheHits: 2,
    temporalBoundsBuilds: 3, temporalBoundsCacheHits: 4, internalRoutePasses: 2
};

function fixture(findJourneys) {
    const events = [];
    const engine = new PlannerEngine({ tubeTrackEnabled: false }, { findJourneys });
    const options = { timetableOnly: true,
        measure: async (name, work) => work(), onTelemetry: event => events.push(event) };
    return { engine, options, events };
}

test('engine forwards the bounded route profile alongside existing counters', async () => {
    assert.deepEqual([...ROUTING_PROFILE_FIELDS].sort(), Object.keys(profile).sort());
    const result = { journeys: [{}, {}], metrics: { operations: 12, labels: 7, ...profile, privateValue: 99 } };
    const { engine, options, events } = fixture(() => result);
    assert.equal(await engine.route({}, {}, options), result);
    assert.deepEqual(events, [
        { metricsDelta: { routeCalls: 1 } },
        { metricsDelta: { operations: 12, labels: 7, candidates: 2, ...profile } }
    ]);
});

test('legacy or invalid routing profiles do not fabricate new measurements', async () => {
    for (const metrics of [undefined, null, { indexBuildMs: NaN, topologyBoundsMs: -1,
        temporalBoundsMs: Infinity, labelExpansionMs: '10', transferResolutionMs: Infinity,
        resultAssemblyMs: -1, privateValue: 99 }]) {
        const { engine, options, events } = fixture(() => ({ journeys: [], metrics }));
        await engine.route({}, {}, options);
        assert.deepEqual(events.at(-1), { metricsDelta: { operations: 0, labels: 0, candidates: 0 } });
    }
});

test('failed and cancelled routes retain measured profile deltas before error translation', async () => {
    for (const code of ['SEARCH_TIMEOUT', 'SEARCH_CANCELLED']) {
        const error = Object.assign(new Error('Bounded routing stopped'), {
            code, metrics: { operations: 12, labels: 7, ...profile, privateValue: 99 }
        });
        const { engine, options, events } = fixture(() => { throw error; });
        await assert.rejects(engine.route({}, {}, options), { code });
        assert.deepEqual(events.at(-1), { metricsDelta: { operations: 12, labels: 7, ...profile } });
    }
});
