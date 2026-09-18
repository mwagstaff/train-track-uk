#!/usr/bin/env node
// Read-only, offline benchmark: no activation, HTTP, live data or TfL lookups.
// Run with --expose-gc for retained-heap measurements after each major phase.
import { parseArgs } from 'node:util';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { dirname, resolve, join } from 'node:path';
import { createHash } from 'node:crypto';
import { openDataset } from '../lib/planner/repository.js';
import { PlannerEngine } from '../lib/planner/engine.js';
import { plannerConfig } from '../lib/planner/service.js';
import { normalizeRequest } from '../lib/planner/contract.js';
import { createCooperativeSignal } from '../lib/planner/execution.js';
import { prepareNetwork, findJourneys } from '../lib/planner/router.js';

const { values } = parseArgs({ options: {
    dataset: { type: 'string' }, cases: { type: 'string' }, output: { type: 'string' },
    time: { type: 'string', default: '2026-09-18T09:00:00+01:00' },
    repetitions: { type: 'string', default: '2' },
    'max-changes': { type: 'string', default: '5' }
} });
if (!values.dataset) throw new Error('--dataset is required');
const repetitions = Number(values.repetitions);
if (!Number.isSafeInteger(repetitions) || repetitions < 1 || repetitions > 20) {
    throw new Error('--repetitions must be between 1 and 20');
}
const memory = () => process.memoryUsage();
const cpuMs = cpu => (cpu.user + cpu.system) / 1000;
const timings = [];
function measured(name, work, details = {}) {
    const started = performance.now(), cpu = process.cpuUsage();
    const finish = result => {
        timings.push({ name, ...details, elapsedMs: performance.now() - started,
            cpuMs: cpuMs(process.cpuUsage(cpu)), memoryBytes: memory() });
        return result;
    };
    const result = work();
    return result?.then ? result.then(finish) : finish(result);
}
function retainedMemory() {
    global.gc?.();
    return { garbageCollected: Boolean(global.gc), memoryBytes: memory() };
}
let engine, repo;
try {
    const dataset = resolve(values.dataset);
    repo = await measured('openDataset', () => openDataset(dataset));
    const opened = retainedMemory();
    for (const name of ['dateCandidates', 'readVariantCalls', 'resolveServices']) {
        const original = repo[name];
        if (!original) continue;
        repo[name] = (...args) => measured(name, () => original(...args), {
            ...(name === 'readVariantCalls' ? { variants: args[0].length } : { date: args[0] })
        });
    }
    engine = new PlannerEngine({ ...plannerConfig(), datasetPath: dataset, prewarm: false });
    const cases = values.cases ? JSON.parse(await readFile(values.cases, 'utf8'))
        : [{ origin: 'VIC', destination: 'KTH' }, { origin: 'GLC', destination: 'PLY' },
            { origin: 'BRI', destination: 'EDB' }];
    if (!Array.isArray(cases) || !cases.length) throw new Error('--cases must contain a non-empty array');
    const requests = cases.map(request => normalizeRequest({
        time: values.time, timeType: 'departAfter', ...request,
        maxChanges: Number(values['max-changes']), realtime: 'off', allowedModes: ['rail', 'walk']
    }));
    const searches = [];
    const ranges = [];
    let lastNetwork;
    for (const request of requests) {
        const network = await measured('network', () => engine.network(repo, request), {
            origin: request.origin, destination: request.destination
        });
        if (network !== lastNetwork) {
            lastNetwork = network;
            const beforeIndex = retainedMemory();
            measured('prepareNetwork', () => prepareNetwork(network));
            ranges.push({ serviceCount: network.services.length,
                callCount: network.services.reduce((total, service) => total + service.calls.length, 0),
                originDates: [...new Set(network.services.map(service => service.originDate))].sort(),
                beforeIndex, afterIndex: retainedMemory() });
        }
        for (let repetition = 0; repetition < repetitions; repetition++) {
            const started = performance.now(), cpu = process.cpuUsage();
            try {
                const result = findJourneys(request, network, {
                    timeoutMs: 60000, maxOperations: 1000000000,
                    signal: createCooperativeSignal(new SharedArrayBuffer(4), { timeoutMs: 60000 })
                });
                // Snapshot versions differ across storage formats, not train identity.
                const comparable = JSON.stringify(result.journeys, (key, value) =>
                    key === 'serviceId' && typeof value === 'string' ? value.slice(value.indexOf(':') + 1) : value);
                searches.push({ request, repetition, elapsedMs: performance.now() - started,
                    cpuMs: cpuMs(process.cpuUsage(cpu)), metrics: result.metrics,
                    outputHash: createHash('sha256').update(comparable).digest('hex'),
                    totalJourneys: result.pagination.total,
                    journeys: result.journeys.map(journey => ({ departure: journey.departure,
                        arrival: journey.arrival, changes: journey.changes })), memoryBytes: memory() });
            } catch (error) {
                searches.push({ request, repetition, elapsedMs: performance.now() - started,
                    error: error.code || error.name, message: error.message, memoryBytes: memory() });
            }
        }
    }
    const report = { node: process.version, dataset, version: repo.version,
        databaseBytes: (await stat(join(dataset, 'timetable.sqlite'))).size,
        offlineModes: ['rail', 'walk'], cooperativeSignal: true, opened, ranges, timings, searches,
        retainedAfterSearch: retainedMemory(), peakRSSBytes: process.resourceUsage().maxRSS * 1024 };
    if (values.output) {
        const output = resolve(values.output);
        await mkdir(dirname(output), { recursive: true });
        await writeFile(output, `${JSON.stringify(report, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    }
    console.log(JSON.stringify(report, null, 2));
    if (searches.some(search => search.error)) process.exitCode = 1;
} finally {
    engine?.close();
    repo?.close();
}
