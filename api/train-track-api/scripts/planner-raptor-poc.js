#!/usr/bin/env node
// Offline proof of concept only: no API switching, providers, imports,
// active-pointer updates or search-history writes.
import { parseArgs } from 'node:util';
import { resolve } from 'node:path';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { openDataset } from '../lib/planner/repository.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { plannerConfig } from '../lib/planner/service.js';
import { normalizeRequest } from '../lib/planner/contract.js';
import { prepareNetwork, findJourneys, releaseIndexCaches, validateJourney } from '../lib/planner/router.js';
import { applyLiveSnapshot } from '../lib/planner/live-network.js';
import { compileRaptorNetwork, findRaptorJourneys } from '../lib/planner/raptor-poc.js';

const { values } = parseArgs({ options: {
    dataset: { type: 'string' }, cases: { type: 'string' },
    origin: { type: 'string' }, destination: { type: 'string' }, time: { type: 'string' },
    repetitions: { type: 'string', default: '3' },
    'timeout-ms': { type: 'string', default: '30000' },
    disruptions: { type: 'boolean', default: false }
} });
if (!values.dataset) throw new Error('--dataset is required');
const repetitions = Number(values.repetitions), timeoutMs = Number(values['timeout-ms']);
if (!Number.isSafeInteger(repetitions) || repetitions < 1 || repetitions > 10) throw new Error('--repetitions must be 1–10');
if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 120000) throw new Error('--timeout-ms must be 1–120000');
const single = [values.origin, values.destination, values.time];
if (single.some(Boolean) && (!single.every(Boolean) || values.cases)) {
    throw new Error('Provide --origin, --destination and --time together, or use --cases');
}
const defaultCases = [
    { name: 'Kent House → Inverness, evening', origin: 'KTH', destination: 'INV', time: '2026-09-18T16:59:52+01:00' },
    { name: 'Kent House → Inverness, overnight', origin: 'KTH', destination: 'INV', time: '2026-09-15T15:10:00+01:00' },
    { name: 'Victoria → Kent House', origin: 'VIC', destination: 'KTH', time: '2026-09-18T17:00:00+01:00' },
    { name: 'Glasgow Central → Plymouth', origin: 'GLC', destination: 'PLY', time: '2026-09-18T07:00:00+01:00' },
    { name: 'Bristol Temple Meads → Edinburgh', origin: 'BRI', destination: 'EDB', time: '2026-09-18T07:00:00+01:00' }
];
const cases = values.cases ? JSON.parse(await readFile(resolve(values.cases), 'utf8'))
    : single.every(Boolean) ? [{ origin: values.origin, destination: values.destination, time: values.time }] : defaultCases;
if (!Array.isArray(cases) || !cases.length || cases.length > 100) throw new Error('Cases must be an array of 1–100 requests');
// The public normalizer does not retain internal via constraints.
if (cases.some(item => item?.via?.length)) throw new Error('This POC does not support via stations');
const requests = cases.map(item => ({ name: item.name ?? `${item.origin} → ${item.destination}`, request:
    { ...normalizeRequest({ ...item, timeType: item.timeType ?? 'departAfter', realtime: 'off', limit: 5 }), limit: 10000 } }));
if (requests.some(item => item.request.timeType !== 'departAfter' || item.request.via?.length)) {
    throw new Error('This POC supports departAfter without via stations only');
}
const median = values => {
    const sorted = [...values].sort((a, b) => a - b), middle = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};
const tuple = journey => [Date.parse(journey.departure), Date.parse(journey.arrival), journey.changes];
const frontier = journeys => {
    const distinct = [...new Map(journeys.map(journey => { const value = tuple(journey); return [value.join('|'), value]; })).values()];
    return distinct.filter(value => !distinct.some(other => other !== value
        && other[0] >= value[0] && other[1] <= value[1] && other[2] <= value[2]
        && (other[0] > value[0] || other[1] < value[1] || other[2] < value[2]))).map(value => value.join('|')).sort();
};
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const options = { timeoutMs, maxOperations: 1000000000, maxLabels: 200000, maxDurationMinutes: 1440 };
const reports = [];
let repo, engine, matched = true;
const dataset = resolve(values.dataset);
try {
    repo = await openDataset(dataset);
    engine = new PlannerEngine({ ...plannerConfig({}), datasetPath: dataset, prewarm: false, tubeTrackEnabled: false });
    for (const { name, request } of requests) {
        console.error(`Preparing ${name}`);
        const preparationStarted = performance.now();
        const network = await engine.network(repo, request);
        const preparationMs = performance.now() - preparationStarted;
        const runPhase = (phase, current) => {
            console.error(`Comparing ${name}/${phase}`);
            let started = performance.now();
            prepareNetwork(current);
            const legacyIndexMs = performance.now() - started;
            started = performance.now();
            const index = compileRaptorNetwork(current);
            const raptorCompileMs = performance.now() - started;
            const runs = [];
            let firstJourneys;
            const run = algorithm => {
                const cpu = process.cpuUsage(), begun = performance.now();
                const result = algorithm === 'current' ? findJourneys(request, current, options)
                    : findRaptorJourneys(request, index, options);
                const elapsedMs = performance.now() - begun, used = process.cpuUsage(cpu);
                if (algorithm === 'current' && !firstJourneys) firstJourneys = result.journeys;
                if (result.searchTruncated || result.pagination?.total > result.journeys.length) {
                    throw new Error(`${algorithm} did not return its complete frontier`);
                }
                const queryTime = Date.parse(request.time), upper = queryTime + request.windowMinutes * 60000;
                for (const journey of result.journeys) {
                    const departure = Date.parse(journey.departure), arrival = Date.parse(journey.arrival);
                    if (!validateJourney(journey, current, request) || departure < queryTime || departure >= upper
                        || arrival - departure > options.maxDurationMinutes * 60000 || journey.changes > request.maxChanges) {
                        throw new Error(`${algorithm} returned an independently invalid journey`);
                    }
                }
                const criteria = frontier(result.journeys);
                return { algorithm, elapsedMs, cpuMs: (used.user + used.system) / 1000,
                    metrics: result.metrics, journeys: result.journeys.length, frontier: criteria,
                    frontierHash: hash(criteria), heapUsedBytes: process.memoryUsage().heapUsed };
            };
            // First query includes query-derived bounds; prepared indexes are separate.
            const firstCurrent = run('current'), firstRaptor = run('raptor');
            runs.push({ temperature: 'first', current: firstCurrent, raptor: firstRaptor });
            for (let repetition = 0; repetition < repetitions; repetition++) {
                const pair = {};
                for (const algorithm of repetition % 2 ? ['raptor', 'current'] : ['current', 'raptor']) pair[algorithm] = run(algorithm);
                runs.push({ temperature: 'warm', repetition, ...pair });
            }
            const comparisons = runs.map(row => {
                const equal = row.current.frontierHash === row.raptor.frontierHash;
                if (!equal) matched = false;
                return { temperature: row.temperature, repetition: row.repetition, matched: equal,
                    missing: row.current.frontier.filter(value => !row.raptor.frontier.includes(value)),
                    additional: row.raptor.frontier.filter(value => !row.current.frontier.includes(value)) };
            });
            const warmCurrentMs = median(runs.slice(1).map(row => row.current.elapsedMs));
            const warmRaptorMs = median(runs.slice(1).map(row => row.raptor.elapsedMs));
            return { phase, indexStats: index.stats, legacyIndexMs, raptorCompileMs,
                firstCurrentMs: firstCurrent.elapsedMs, firstRaptorMs: firstRaptor.elapsedMs,
                firstCurrentIncludingIndexMs: legacyIndexMs + firstCurrent.elapsedMs,
                firstRaptorIncludingCompileMs: raptorCompileMs + firstRaptor.elapsedMs,
                // The prototype validates using the existing router's index.
                // A standalone cold POC query must pay for that index as well.
                firstRaptorIncludingRequiredIndexesMs: legacyIndexMs + raptorCompileMs + firstRaptor.elapsedMs,
                warmCurrentMs, warmRaptorMs, warmSpeedup: warmCurrentMs / warmRaptorMs,
                comparisons, runs, firstJourneys };
        };
        const scheduled = runPhase('scheduled', network), phases = [scheduled];
        if (values.disruptions) {
            const legs = scheduled.firstJourneys[0]?.legs.filter(leg => leg.kind === 'vehicle') ?? [];
            if (!legs.length) throw new Error('Synthetic disruption cases require a vehicle journey');
            const service = network.services.find(value => value.id === legs[0].serviceId);
            if (!service) throw new Error('Selected service is missing from the immutable timetable');
            const observedAt = Date.parse(request.time);
            const snapshot = services => ({ id: 'raptor-poc-synthetic', observedAt, expiresAt: observedAt + 30000, services });
            const delayed = applyLiveSnapshot(network, snapshot([{ serviceId: service.id,
                calls: service.calls.map((call, index) => ({ index,
                    ...(Number.isFinite(call.arrival) ? { arrival: call.arrival + 5 * 60000 } : {}),
                    ...(Number.isFinite(call.departure) ? { departure: call.departure + 5 * 60000 } : {}) })) }]));
            phases.push(runPhase('delayed', delayed));
            const cancelled = applyLiveSnapshot(network, snapshot([{ serviceId: legs.at(-1).serviceId, cancelled: true }]));
            phases.push(runPhase('cancelled', cancelled));
        }
        for (const phase of phases) delete phase.firstJourneys;
        reports.push({ name, request, preparationMs, services: network.services.length,
            calls: network.services.reduce((sum, service) => sum + service.calls.length, 0), phases });
        releaseIndexCaches(network);
        global.gc?.();
    }
    console.log(JSON.stringify({ experimental: true, productionEnabled: false, node: process.version,
        dataset, version: repo.version, noUpstreamRequests: true, syntheticDisruptions: values.disruptions,
        raptorSourceHash: createHash('sha256').update(await readFile(new URL('../lib/planner/raptor-poc.js', import.meta.url))).digest('hex'),
        currentSourceHash: createHash('sha256').update(await readFile(new URL('../lib/planner/router.js', import.meta.url))).digest('hex'),
        validationUsesSharedLegacyIndex: true,
        comparison: 'Full unique departure/arrival/changes Pareto frontier; independently feasible tie representatives',
        allFrontiersMatched: matched, budgets: options, repetitions, reports,
        peakCombinedRSSBytes: process.resourceUsage().maxRSS * 1024 }, null, 2));
    if (!matched) process.exitCode = 1;
} finally {
    engine?.close();
    repo?.close();
}
