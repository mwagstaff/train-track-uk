#!/usr/bin/env node
// Offline, read-only routing benchmark. Live changes are synthetic; no providers
// are contacted and no dataset, active pointer or search history is written.
import { parseArgs } from 'node:util';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
import { openDataset } from '../lib/planner/repository.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { plannerConfig } from '../lib/planner/service.js';
import { normalizeRequest } from '../lib/planner/contract.js';
import { applyLiveSnapshot } from '../lib/planner/live-network.js';
import { createTubeResolver } from '../lib/planner/tube-routing.js';

const { values } = parseArgs({ options: {
    dataset: { type: 'string' }, 'baseline-router': { type: 'string' },
    'baseline-tube-resolver': { type: 'string' },
    origin: { type: 'string', default: 'KTH' }, destination: { type: 'string', default: 'INV' },
    time: { type: 'string', default: '2026-09-18T16:59:52+01:00' },
    'time-type': { type: 'string', default: 'departAfter' },
    repetitions: { type: 'string', default: '3' }
} });
if (!values.dataset) throw new Error('--dataset is required');
if (values['baseline-tube-resolver'] && !values['baseline-router']) {
    throw new Error('--baseline-tube-resolver requires --baseline-router');
}
const repetitions = Number(values.repetitions);
if (!Number.isSafeInteger(repetitions) || repetitions < 1 || repetitions > 10) {
    throw new Error('--repetitions must be between 1 and 10');
}
const request = normalizeRequest({ origin: values.origin, destination: values.destination,
    time: values.time, timeType: values['time-type'], limit: 5, realtime: 'off' });
// Match the retained live frontier's internal capacity without changing the
// public request contract's ten-result upper bound.
request.limit = 1001;
const now = Date.parse(request.time);
const routers = [];
if (values['baseline-router']) routers.push(['before', await import(pathToFileURL(resolve(values['baseline-router'])))]);
routers.push(['after', await import('../lib/planner/router.js')]);
const baselineTubeResolver = values['baseline-tube-resolver']
    ? (await import(pathToFileURL(resolve(values['baseline-tube-resolver'])))).createTubeResolver : createTubeResolver;
const source = { async lookup() {
    return { status: 'unavailable', journeys: [], meta: { reason: 'offlineBenchmark' } };
} };
const resolver = name => (name === 'before' ? baselineTubeResolver : createTubeResolver)(source,
    { now: () => now, budget: { limit: 0, used: 0 } });
const outputHash = result => createHash('sha256').update(JSON.stringify(result, (key, value) =>
    key === 'metrics' ? undefined : value)).digest('hex');
const snapshot = services => ({ id: 'offline-routing-benchmark', observedAt: now,
    expiresAt: now + 30000, services });
const reports = [];
const median = values => {
    const sorted = [...values].sort((a, b) => a - b), middle = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};
let repo, engine;
try {
    const dataset = resolve(values.dataset);
    repo = await openDataset(dataset);
    engine = new PlannerEngine({ ...plannerConfig({}), datasetPath: dataset, prewarm: false,
        tubeTrackEnabled: false });
    const start = performance.now();
    const network = await engine.network(repo, request);
    const preparationMs = performance.now() - start;
    for (let repetition = 0; repetition < repetitions; repetition++) {
        const base = { ...network };
        const results = new Map();
        // Alternate the paired order to reduce systematic warm-up/GC bias.
        const orderedRouters = repetition % 2 ? [...routers].reverse() : routers;
        const run = async (name, router, phase, current) => {
            console.error(`Routing ${name}/${phase}, repetition ${repetition + 1}/${repetitions}`);
            const started = performance.now(), cpu = process.cpuUsage();
            const result = await router.findJourneysAsync(request, current, {
                timeoutMs: 120000, maxOperations: 1000000000, maxDurationMinutes: 1440,
                resolveTubeConnection: resolver(name), tubeVerificationLimit: 5
            });
            const used = process.cpuUsage(cpu);
            reports.push({ name, phase, repetition, elapsedMs: performance.now() - started,
                cpuMs: (used.user + used.system) / 1000, metrics: result.metrics,
                outputHash: outputHash(result), journeys: result.journeys.length,
                rssBytes: process.memoryUsage().rss });
            return result;
        };
        for (const [name, router] of orderedRouters) {
            router.prepareNetwork(base);
            results.set(name, await run(name, router, 'scheduled', base));
        }
        const scheduled = results.get(routers[0][0]);
        const legs = scheduled.journeys[0]?.legs.filter(leg => leg.kind === 'vehicle') ?? [];
        if (!legs.length) throw new Error('Benchmark request must find a vehicle journey');
        const service = network.services.find(value => value.id === legs[0].serviceId);
        if (!service) throw new Error('Selected service is absent from the immutable network');
        const delayed = applyLiveSnapshot(base, snapshot([{ serviceId: service.id,
            calls: service.calls.map((call, index) => ({ index,
                ...(Number.isFinite(call.arrival) ? { arrival: call.arrival + 5 * 60000 } : {}),
                ...(Number.isFinite(call.departure) ? { departure: call.departure + 5 * 60000 } : {}) }))
        }]));
        const cancelled = applyLiveSnapshot(base, snapshot([{ serviceId: (legs.at(-1) ?? legs[0]).serviceId,
            cancelled: true }]));
        for (const [phase, current] of [['delayed', delayed], ['cancelled', cancelled], ['scheduledAgain', base]]) {
            for (const [name, router] of orderedRouters) await run(name, router, phase, current);
        }
        if (routers.length === 2) {
            for (const phase of ['scheduled', 'delayed', 'cancelled', 'scheduledAgain']) {
                const rows = reports.filter(row => row.repetition === repetition && row.phase === phase);
                assert.equal(rows[0].outputHash, rows[1].outputHash,
                    `Itinerary/ranking/pagination mismatch in ${phase}, repetition ${repetition}`);
            }
        }
        routers.forEach(([, router]) => router.releaseIndexCaches(base));
        global.gc?.();
    }
    const summaries = routers.flatMap(([name]) => ['scheduled', 'delayed', 'cancelled', 'scheduledAgain'].map(phase => {
        const rows = reports.filter(row => row.name === name && row.phase === phase);
        const fields = Object.keys(rows[0].metrics);
        return { name, phase, medianElapsedMs: median(rows.map(row => row.elapsedMs)),
            medianCpuMs: median(rows.map(row => row.cpuMs)),
            medianMetrics: Object.fromEntries(fields.map(field => [field, median(rows.map(row => row.metrics[field]))])) };
    }));
    console.log(JSON.stringify({ node: process.version, dataset, version: repo.version,
        baselineRouter: values['baseline-router'] ? resolve(values['baseline-router']) : null,
        baselineTubeResolver: values['baseline-tube-resolver'] ? resolve(values['baseline-tube-resolver']) : null,
        request, preparationMs, offlineTubeFallback: true, syntheticLiveChanges: true,
        comparisonsMatched: routers.length === 2 ? true : null, summaries, reports,
        peakRSSBytes: process.resourceUsage().maxRSS * 1024 }, null, 2));
} finally {
    engine?.close();
    repo?.close();
}
