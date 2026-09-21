#!/usr/bin/env node
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import { MongoClient } from 'mongodb';
import { chooseSearchTime, durationSummary } from './planner-service-smoke.js';

const exec = promisify(execFile);
const ROUTES = [['KTH', 'VIC'], ['KTH', 'INV'], ['ABD', 'PNZ'], ['CLK', 'CDB'], ['HHD', 'NRW']];
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));

export function parseLevels(value) {
    const levels = String(value).split(',').map(item => Number(item));
    if (!levels.length || levels.some((level, index) => !Number.isInteger(level) || level < 1 || level > 50
        || index > 0 && level <= levels[index - 1])) {
        throw new Error('Load levels must be ascending integers from 1 to 50.');
    }
    return levels;
}

export function parseAdmissionCap(value) {
    const cap = Number(value);
    if (!Number.isInteger(cap) || cap < 1 || cap > 100) {
        throw new Error('Admission cap must be an integer from 1 to 100.');
    }
    return cap;
}

export function parseCpuTime(value) {
    const match = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+(?:\.\d+)?)$/.exec(value.trim());
    if (!match) throw new Error(`Unexpected process CPU time: ${value}`);
    return Number(match[1] || 0) * 86400 + Number(match[2] || 0) * 3600
        + Number(match[3]) * 60 + Number(match[4]);
}

export async function readPlannerProcess(pid) {
    const { stdout } = await exec('/bin/ps', ['-p', String(pid), '-o', 'rss=', '-o', 'time=', '-o', 'command='],
        { env: { ...process.env, LC_ALL: 'C' } });
    const match = /^\s*(\d+)\s+(\S+)\s+(.+)$/m.exec(stdout);
    if (!match || !match[3].includes('/train-track-planner-mvp/planner-server.js')) {
        throw new Error('PID does not identify the Mini MVP planner process.');
    }
    return { rssBytes: Number(match[1]) * 1024, cpuSeconds: parseCpuTime(match[2]) };
}

function usageSummary(samples, durationMs) {
    const first = samples[0], last = samples.at(-1);
    const intervals = samples.slice(1).map((sample, index) => {
        const previous = samples[index];
        return Math.max(0, (sample.cpuSeconds - previous.cpuSeconds) / ((sample.at - previous.at) / 1000) * 100);
    }).filter(Number.isFinite);
    return { sampleCount: samples.length, sampleIntervalMs: 250,
        peakCpuPercentOneCore: Math.round(Math.max(0, ...intervals) * 10) / 10,
        averageCpuPercentOneCore: Math.round(Math.max(0, last.cpuSeconds - first.cpuSeconds) / (durationMs / 1000) * 1000) / 10,
        initialRssBytes: first.rssBytes, peakRssBytes: Math.max(...samples.map(sample => sample.rssBytes)),
        finalRssBytes: last.rssBytes };
}

export async function runPlannerServiceLoad({ baseUrl = 'http://127.0.0.1:3014', token, pid,
    levels = [5, 10, 20, 50], time, fetchImpl = fetch, readUsage = readPlannerProcess,
    intervalMs = 250, now = Date.now, admissionCap } = {}) {
    if (typeof token !== 'string' || token.length < 16) throw new Error('PLANNER_SERVICE_TOKEN is required.');
    if (!Number.isSafeInteger(pid) || pid < 1) throw new Error('A planner process PID is required.');
    parseLevels(levels.join(','));
    const root = baseUrl.replace(/\/+$/, '');
    const headers = { Authorization: `Bearer ${token}`, Accept: 'application/json' };
    const statusResponse = await fetchImpl(`${root}/api/v3/journey-planner/status`, { headers, signal: AbortSignal.timeout(10000) });
    const status = await statusResponse.json();
    if (!statusResponse.ok || status.available !== true || !status.dataset?.version) throw new Error('The planner has no active dataset.');
    const searchTime = time || chooseSearchTime(status.dataset, now());
    let admissionOverride = null;
    if (admissionCap !== undefined) {
        const maxQueue = parseAdmissionCap(admissionCap);
        const response = await fetchImpl(`${root}/internal/planner/v1/load/admission`, { method: 'POST',
            headers: { ...headers, 'Content-Type': 'application/json' }, body: JSON.stringify({ maxQueue }),
            signal: AbortSignal.timeout(10000) });
        if (!response.ok) throw new Error(`Could not override admission cap (HTTP ${response.status}); deploy the updated planner service first.`);
        admissionOverride = await response.json();
        if (typeof admissionOverride.leaseId !== 'string' || admissionOverride.maxQueue !== maxQueue) {
            throw new Error('Planner returned an invalid admission override lease.');
        }
    }
    let report;
    try {
        const stages = [];
        for (const level of levels) {
            const cleared = await fetchImpl(`${root}/internal/planner/v1/cache/clear`, { method: 'POST',
                headers: { ...headers, 'Content-Type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(15000) });
            if (!cleared.ok) throw new Error(`Could not clear search-result caches before the ${level}-user stage (${cleared.status}).`);
            const requests = Array.from({ length: level }, (_, index) => {
                const [origin, destination] = ROUTES[index % ROUTES.length];
                return { origin, destination, time: new Date(Date.parse(searchTime) + index * 60000).toISOString(),
                    timeType: 'departAfter', realtime: 'off', algorithm: 'raptor', limit: 5, windowMinutes: 360 };
            });
            const samples = [];
            const sample = async () => samples.push({ at: performance.now(), ...await readUsage(pid) });
            await sample();
            let sampling = Promise.resolve(), samplingError = null;
            const timer = setInterval(() => { sampling = sampling.then(sample).catch(error => { samplingError = error; }); }, intervalMs);
            const startedAt = new Date(now());
            const started = performance.now();
            let results;
            try {
                results = await Promise.all(requests.map(async (body, index) => {
                    const requestStarted = performance.now();
                    try {
                        const response = await fetchImpl(`${root}/api/v3/journey-planner/search`, { method: 'POST',
                            headers: { ...headers, 'Content-Type': 'application/json',
                                'X-Planner-Client': `load-user-${randomUUID()}` },
                            body: JSON.stringify(body), signal: AbortSignal.timeout(120000) });
                        const payload = await response.json();
                        return { index, route: `${body.origin}-${body.destination}`, requestedTime: body.time,
                            status: response.status, durationMs: Math.round((performance.now() - requestStarted) * 10) / 10,
                            journeyCount: payload?.journeys?.length ?? 0, errorCode: payload?.error?.code ?? null };
                    } catch (error) {
                        return { index, route: `${body.origin}-${body.destination}`, requestedTime: body.time, status: null,
                            durationMs: Math.round((performance.now() - requestStarted) * 10) / 10,
                            journeyCount: 0, errorCode: error?.name === 'TimeoutError' ? 'CLIENT_TIMEOUT' : 'NETWORK_ERROR' };
                    }
                }));
            } finally { clearInterval(timer); await sampling; await sample(); }
            const durationMs = Math.round((performance.now() - started) * 10) / 10;
            const endedAt = new Date(now());
            if (samplingError) throw samplingError;
            const successful = results.filter(result => result.status === 200);
            const codes = results.reduce((counts, result) => {
                const key = result.errorCode ?? String(result.status);
                counts[key] = (counts[key] ?? 0) + 1;
                return counts;
            }, {});
            stages.push({ users: level, startedAt: startedAt.toISOString(), endedAt: endedAt.toISOString(),
                durationMs, successful: successful.length, responses: codes,
                successfulLatency: durationSummary(successful.map(result => result.durationMs)),
                allLatency: durationSummary(results.map(result => result.durationMs)),
                usage: usageSummary(samples, durationMs), results });
            // Let the bounded search logger flush before the next stage's window.
            await sleep(1000);
        }
        const finalHealth = await fetchImpl(`${root}/healthcheck`, { signal: AbortSignal.timeout(5000) });
        report = { generatedAt: new Date(now()).toISOString(), baseUrl: root, hostId: process.env.PLANNER_HOST_ID ?? null,
            datasetVersion: status.dataset.version, searchTime, algorithm: 'raptor',
            cachePolicy: 'clear-between-stages-with-distinct-times', processId: pid,
            admission: admissionOverride ? { configuredMaxQueue: admissionOverride.configuredMaxQueue,
                testMaxQueue: admissionOverride.maxQueue } : null,
            routes: ROUTES.map(([origin, destination]) => `${origin}-${destination}`),
            healthAfterLoad: finalHealth.status, stages };
    } finally {
        if (admissionOverride) {
            const response = await fetchImpl(`${root}/internal/planner/v1/load/admission`, { method: 'DELETE',
                headers: { ...headers, 'Content-Type': 'application/json' },
                body: JSON.stringify({ leaseId: admissionOverride.leaseId }), signal: AbortSignal.timeout(10000) });
            if (!response.ok || (await response.json()).restored !== true) {
                throw new Error('Could not restore the configured admission cap; check Mini (the override expires automatically after five minutes).');
            }
        }
    }
    return report;
}

export async function verifyLoadCache(report, uri = process.env.MONGODB_URI_TRAIN_TRACK_UK,
    createClient = value => new MongoClient(value)) {
    if (!uri) throw new Error('MONGODB_URI_TRAIN_TRACK_UK is required to verify cache misses.');
    const client = createClient(uri);
    try {
        await client.connect();
        const collection = client.db().collection('planner_searches');
        for (const stage of report.stages) {
            const expected = new Set(stage.results.map(result => `${result.route}:${result.requestedTime}`));
            let rows = [];
            for (let attempt = 0; attempt < 20; attempt++) {
                rows = await collection.find({ source: report.source ?? 'search', algorithm: 'raptor',
                    requestedTime: { $in: stage.results.map(result => new Date(result.requestedTime)) },
                    startedAt: { $gte: new Date(stage.startedAt), $lte: new Date(stage.endedAt) } },
                { projection: { origin: 1, destination: 1, requestedTime: 1,
                    cacheStatus: 1, status: 1, errorCode: 1, metrics: 1 } }).toArray();
                rows = rows.filter(row => expected.has(`${row.origin}-${row.destination}:${row.requestedTime?.toISOString()}`));
                if (rows.length >= (stage.attempted ?? stage.users)) break;
                await sleep(500);
            }
            stage.cache = { logged: rows.length, misses: rows.filter(row => row.cacheStatus === 'miss').length,
                successfulMisses: rows.filter(row => row.status === 'success' && row.cacheStatus === 'miss').length,
                hits: rows.filter(row => row.cacheStatus === 'hit').length,
                unknown: rows.filter(row => row.cacheStatus === 'unknown').length };
            const byRequest = new Map(rows.map(row => [`${row.origin}-${row.destination}:${row.requestedTime?.toISOString()}`, row]));
            for (const result of stage.results) {
                const metrics = byRequest.get(`${result.route}:${result.requestedTime}`)?.metrics;
                result.serverQueueMs = metrics ? (metrics.admissionQueueMs ?? 0) + (metrics.queueWaitMs ?? 0) : null;
            }
        }
        return report.stages.every(stage => stage.cache.logged === (stage.attempted ?? stage.users) && stage.cache.hits === 0
            && stage.cache.successfulMisses === stage.successful);
    } finally { await client.close(); }
}

const responseName = code => ({ SEARCH_BUSY: 'busy', SEARCH_TIMEOUT: 'timeout',
    CLIENT_TIMEOUT: 'client timeout', NETWORK_ERROR: 'network error' })[code] ?? code.toLowerCase().replaceAll('_', ' ');

export function loadWarnings(report, missesVerified) {
    const warnings = [];
    for (const stage of report.stages) {
        for (const result of stage.results) {
            if (result.status !== 200) warnings.push(`${stage.users} users: ${result.route} ${responseName(result.errorCode ?? String(result.status))}`
                + ` (HTTP ${result.status ?? 'none'}, ${result.durationMs} ms)`);
            else if (result.journeyCount === 0) warnings.push(`${stage.users} users: ${result.route} returned no journeys`);
        }
    }
    if (!missesVerified) warnings.push('Zero-cache-hit verification failed; check the JSON report and Mini search log.');
    if (report.healthAfterLoad !== 200) warnings.push(`Planner health check returned HTTP ${report.healthAfterLoad}.`);
    return warnings;
}

export function formatLoadSummary(report) {
    const columns = [
        ['Simultaneous users', stage => String(stage.users)],
        ['Completed', stage => `${stage.successful}/${stage.users}`],
        ['Other responses', stage => Object.entries(stage.responses).filter(([code]) => code !== '200')
            .map(([code, count]) => `${count} ${responseName(code)}`).join(', ') || '—'],
        ['Successful p50 / p95', stage => stage.successfulLatency.count
            ? `${Math.round(stage.successfulLatency.medianMs).toLocaleString('en-GB')} / ${Math.round(stage.successfulLatency.p95Ms).toLocaleString('en-GB')} ms` : '—'],
        ['Peak CPU', stage => `${Math.round(stage.usage.peakCpuPercentOneCore)}%`],
        ['Peak RSS', stage => `${Math.round(stage.usage.peakRssBytes / 1048576).toLocaleString('en-GB')} MiB`]
    ];
    const widths = columns.map(([heading, value]) => Math.max(heading.length,
        ...report.stages.map(stage => value(stage).length)));
    const row = values => values.map((value, index) => value.padEnd(widths[index])).join('  ');
    return [row(columns.map(([heading]) => heading)), row(widths.map(width => '-'.repeat(width))),
        ...report.stages.map(stage => row(columns.map(([, value]) => value(stage))))].join('\n');
}

function argsFrom(argv) {
    const options = {};
    for (let index = 0; index < argv.length; index++) {
        const name = argv[index], value = argv[++index];
        if (value === undefined) throw new Error(`Missing value for ${name}.`);
        if (name === '--base-url') options.baseUrl = value;
        else if (name === '--pid') options.pid = Number(value);
        else if (name === '--levels') options.levels = parseLevels(value);
        else if (name === '--time') options.time = value;
        else if (name === '--output') options.output = value;
        else if (name === '--admission-cap') options.admissionCap = parseAdmissionCap(value);
        else throw new Error(`Unknown option: ${name}`);
    }
    return options;
}

async function main() {
    const options = argsFrom(process.argv.slice(2));
    await readPlannerProcess(options.pid);
    const report = await runPlannerServiceLoad({ ...options, token: process.env.PLANNER_SERVICE_TOKEN });
    let missesVerified = false, cacheError = null;
    try { missesVerified = await verifyLoadCache(report); }
    catch (error) { cacheError = error; }
    if (options.output) await writeFile(options.output, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
    console.log(formatLoadSummary(report));
    console.log(`\nCache verification: ${missesVerified ? 'passed (zero hits)' : 'FAILED'}; planner health: HTTP ${report.healthAfterLoad}`);
    if (report.admission) console.log(`Admission cap: ${report.admission.testMaxQueue} for this run; configured cap ${report.admission.configuredMaxQueue} restored`);
    if (options.output) console.log(`Report: ${options.output}`);
    const warnings = loadWarnings(report, missesVerified);
    for (const warning of warnings) console.warn(`WARNING: ${warning}`);
    if (cacheError) console.warn(`WARNING: Cache verification could not run: ${cacheError.message}`);
    if (warnings.length) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main().catch(error => { console.error(`Planner load test failed: ${error?.message || error}`); process.exitCode = 1; });
}
