#!/usr/bin/env node
// API-only benchmark. --dataset starts isolated local APIs; otherwise --base-url
// exercises a deployed v5 endpoint. Never clears production caches or changes data.
import { parseArgs } from 'node:util';
import { writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import express from 'express';
import { createPlannerServer } from '../planner-server.js';

const { values: args } = parseArgs({ options: {
    'base-url': { type: 'string' }, dataset: { type: 'string' }, 'tube-api-root': { type: 'string' },
    from: { type: 'string', default: 'nr:CLK' }, to: { type: 'string', default: '910GACTNCTL' },
    time: { type: 'string', default: new Date(Date.now() + 300000).toISOString() },
    'time-type': { type: 'string', default: 'departAfter' }, runs: { type: 'string', default: '2' },
    'expect-error': { type: 'string' }, 'expect-message': { type: 'string' }, 'require-hop': { type: 'string' }, output: { type: 'string' }, 'max-ms': { type: 'string', default: '60000' },
    'require-directions': { type: 'boolean', default: false }, fault: { type: 'string', default: 'none' }
} });
const report = { request: { origin: args.from, destination: args.to, time: args.time, timeType: args['time-type'] },
    local: Boolean(args.dataset), runs: [], upstream: [] };
if (!Number.isInteger(Number(args.runs)) || Number(args.runs) < 1 || Number(args.runs) > 20) throw new Error('--runs must be between 1 and 20');
if (!['none', 'unavailable'].includes(args.fault)) throw new Error('Unknown fault');
if (args.fault !== 'none' && !args.dataset) throw new Error('Fault injection requires isolated local APIs');
let planner, tubeServer, server;
const listen = app => new Promise(resolve => { const server = app.listen(0, '127.0.0.1', () => resolve(server)); });
const address = server => `http://127.0.0.1:${server.address().port}`;
const close = server => server && new Promise(resolve => server.close(resolve));
const token = randomUUID(), headers = { 'Content-Type': 'application/json', 'X-Planner-Client': 'combined-benchmark' };
async function json(url, options = {}) {
    const response = await fetch(url, { ...options, headers: { ...headers, ...options.headers }, signal: AbortSignal.timeout(12000) });
    if (response.status === 204) return null;
    const body = await response.json();
    if (!response.ok) throw new Error(`${response.status}: ${JSON.stringify(body)}`);
    return body;
}
try {
    let base = args['base-url'];
    if (args.dataset) {
        if (!args['tube-api-root']) throw new Error('--dataset requires --tube-api-root (TubeTrack API directory)');
        const { JourneyPlanner } = await import(pathToFileURL(resolve(args['tube-api-root'], 'lib/journey-planner.js')));
        const client = { async fetchJSON(path, options = {}) {
            const started = performance.now();
            const url = new URL(`https://api.tfl.gov.uk${path}`);
            for (const [key, value] of Object.entries(options.query ?? {})) url.searchParams.set(key, value);
            let status;
            try {
                const response = await fetch(url, { signal: options.signal }); status = response.status;
                if (!response.ok) throw Object.assign(new Error(`TfL HTTP ${status}`), { status });
                return await response.json();
            } finally { report.upstream.push({ path, query: options.query, status, ms: Math.round(performance.now() - started) }); }
        } };
        const tfl = new JourneyPlanner({ client });
        const app = express();
        app.get('/api/v2/journey-transfers', async (req, res) => {
            try {
                if (args.fault === 'unavailable') return res.status(503).json({ error: { code: 'UPSTREAM_UNAVAILABLE' } });
                res.json(await tfl.plan(req.query, { transfer: true }));
            } catch (error) { res.status(error.status ?? 503).json({ error: { code: error.code, message: error.message } }); }
        });
        app.get('/api/v1/line-colours', (_req, res) => res.json({ data: [] }));
        tubeServer = await listen(app);
        process.env.TUBETRACK_TRANSFER_URL = `${address(tubeServer)}/api/v2`;
        planner = await createPlannerServer({ env: { ...process.env, PLANNER_HOST_ID: 'combined-benchmark',
            PLANNER_SERVICE_TOKEN: token, PLANNER_PERSISTENCE_MODE: 'memory', PLANNER_INGESTION_ENABLED: 'false',
            PLANNER_DATASET_PATH: resolve(args.dataset), PLANNER_WORKERS: '1' } });
        server = await listen(planner.app);
        base = `${address(server)}/api/v5/journey-planner`;
        headers.Authorization = `Bearer ${token}`;
    }
    if (!base) throw new Error('Supply --base-url or --dataset and --tube-api-root');
    for (let run = 0; run < Number(args.runs); run++) {
        const started = performance.now(), before = report.upstream.length;
        let job = await json(`${base}/search-jobs`, { method: 'POST', body: JSON.stringify(report.request),
            headers: { 'Idempotency-Key': randomUUID() } });
        const id = job.id;
        try {
            while (['queued', 'running'].includes(job.status)) {
                if (performance.now() - started > 180000) throw new Error('Benchmark deadline exceeded');
                await new Promise(resolve => setTimeout(resolve, Math.max(100, Math.min(job.pollAfterMs ?? 500, 1000))));
                job = await json(`${base}/search-jobs/${id}`);
            }
            if (args['expect-error']) {
                if (job.status !== 'failed' || job.error?.code !== args['expect-error']
                    || (args['expect-message'] && !job.error?.message?.includes(args['expect-message']))) {
                    throw new Error(`Expected ${args['expect-error']} with the requested notice, got ${JSON.stringify(job.error ?? job.status)}`);
                }
                const row = { run: run + 1, ms: Math.round(performance.now() - started), expectedError: job.error };
                report.runs.push(row);
                console.log(JSON.stringify(row));
                continue;
            }
            if (job.status !== 'completed') throw new Error(JSON.stringify(job.error ?? job));
            const journeys = job.result.journeys;
            for (const journey of journeys) {
                let previous = Date.parse(journey.departure);
                for (const leg of journey.legs) {
                    if (Date.parse(leg.departure) < previous || Date.parse(leg.arrival) < Date.parse(leg.departure)) throw new Error('Impossible leg chronology');
                    if (leg.live?.cancelled) throw new Error('Cancelled train in result');
                    previous = Date.parse(leg.arrival);
                }
            }
            const row = { run: run + 1, temperature: run ? 'warm' : args.dataset ? 'cold' : 'unknown',
                ms: Math.round(performance.now() - started), upstreamCalls: args.dataset ? report.upstream.length - before : null,
                warnings: job.result.warnings, search: job.result.search,
                journeys: journeys.map(j => ({ departure: j.departure, arrival: j.arrival, changes: j.changes,
                    legs: j.legs, transfers: j.legs.filter(l => l.mode === 'tubeTransfer').map(l => ({ from: l.from, to: l.to,
                        status: l.localJourney?.status, notes: l.localJourney?.notes, steps: l.localJourney?.steps,
                        departure: l.departure, arrival: l.arrival })) })) };
            report.runs.push(row);
            console.log(JSON.stringify({ run: row.run, ms: row.ms, upstreamCalls: row.upstreamCalls,
                journeys: row.journeys.length, unresolved: row.journeys.flatMap(j => j.transfers).filter(t => t.status !== 'available').length }));
            if (!journeys.length) throw new Error('No journeys returned');
            if (args['require-hop']) {
                const [from, to] = args['require-hop'].split(':');
                const transfers = row.journeys.flatMap(j => j.transfers).filter(t => t.from.crs === from && t.to.crs === to);
                if (!transfers.length || transfers.some(t => t.status !== 'available')) throw new Error('Required hop missing or unresolved');
            }
            if (row.ms > Number(args['max-ms'])) throw new Error(`Latency target exceeded: ${row.ms}ms`);
            if (args.fault === 'unavailable') {
                const transfers = row.journeys.flatMap(j => j.transfers);
                if (!transfers.length || transfers.some(t => t.status !== 'unavailable' || !t.notes?.length)) {
                    throw new Error('Outage must produce explicitly warned timetable transfers');
                }
            }
            if (args['require-directions'] && row.journeys.some(j => j.transfers.some(t => t.status !== 'available'))) throw new Error('Unresolved transfer in returned choices');
        } finally { await json(`${base}/search-jobs/${id}`, { method: 'DELETE' }); }
    }
} catch (error) { report.error = error.message; console.error(error.message); process.exitCode = 1; }
finally {
    if (args.output) await writeFile(args.output, JSON.stringify(report, null, 2));
    await close(server); await planner?.close(); await close(tubeServer);
}
