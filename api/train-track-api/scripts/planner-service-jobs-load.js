#!/usr/bin/env node
import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import os from 'node:os';
import { promisify } from 'node:util';
import { pathToFileURL } from 'node:url';
import { chooseSearchTime, durationSummary } from './planner-service-smoke.js';
import { parseLevels, readPlannerProcess, verifyLoadCache } from './planner-service-load.js';

const exec = promisify(execFile);
const ROUTES = [['KTH', 'VIC'], ['KTH', 'INV'], ['ABD', 'PNZ'], ['CLK', 'CDB'], ['HHD', 'NRW']];
const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
const round = value => Math.round(value * 10) / 10;

export function parseDuration(value) {
    const seconds = Number(value);
    if (!Number.isInteger(seconds) || seconds < 0 || seconds > 600) {
        throw new Error('Sustained duration must be an integer from 0 to 600 seconds.');
    }
    return seconds;
}

export function parseUsers(value) {
    const users = Number(value);
    if (!Number.isInteger(users) || users < 1 || users > 32) {
        throw new Error('Sustained users must be an integer from 1 to 32.');
    }
    return users;
}

export async function readMiniHeadroom() {
    const cpu = os.cpus().reduce((sum, core) => {
        for (const [name, ticks] of Object.entries(core.times)) {
            sum.total += ticks;
            if (name === 'idle') sum.idle += ticks;
        }
        return sum;
    }, { total: 0, idle: 0 });
    const [pressure, swap] = await Promise.all([
        exec('/usr/bin/memory_pressure', ['-Q']), exec('/usr/sbin/sysctl', ['-n', 'vm.swapusage'])
    ]);
    const free = /System-wide memory free percentage:\s*(\d+)%/.exec(pressure.stdout);
    const used = /used = ([\d.]+)M/.exec(swap.stdout);
    if (!free || !used) throw new Error('Could not read Mini memory pressure or swap usage.');
    return { cpuTotalTicks: cpu.total, cpuIdleTicks: cpu.idle,
        freeMemoryPercent: Number(free[1]), swapUsedMiB: Number(used[1]) };
}

export function summarizeResourceSamples(samples) {
    const plannerCpu = [], hostCpu = [];
    for (let index = 1; index < samples.length; index++) {
        const first = samples[index - 1], last = samples[index];
        const seconds = (last.at - first.at) / 1000;
        if (seconds > 0) plannerCpu.push(Math.max(0, (last.planner.cpuSeconds - first.planner.cpuSeconds) / seconds * 100));
        const total = last.host.cpuTotalTicks - first.host.cpuTotalTicks;
        if (total > 0) hostCpu.push(Math.max(0, Math.min(100,
            (total - (last.host.cpuIdleTicks - first.host.cpuIdleTicks)) / total * 100)));
    }
    return { sampleCount: samples.length, peakPlannerCpuPercentOneCore: round(Math.max(0, ...plannerCpu)),
        peakHostCpuPercent: round(Math.max(0, ...hostCpu)),
        peakPlannerRssBytes: Math.max(...samples.map(sample => sample.planner.rssBytes)),
        minHostFreeMemoryPercent: Math.min(...samples.map(sample => sample.host.freeMemoryPercent)),
        peakSwapUsedMiB: Math.max(...samples.map(sample => sample.host.swapUsedMiB)) };
}

export async function runPlannerJobsLoad({ baseUrl = 'http://127.0.0.1:3014', token, pid,
    levels = [5, 10, 20], durationSeconds = 60, sustainedUsers = 20, maxWaitSeconds = 120,
    fetchImpl = fetch, readPlanner = readPlannerProcess, readHost = readMiniHeadroom,
    sampleIntervalMs = 500, minPollMs = 250, now = Date.now } = {}) {
    if (typeof token !== 'string' || token.length < 16) throw new Error('PLANNER_SERVICE_TOKEN is required.');
    if (!Number.isSafeInteger(pid) || pid < 1) throw new Error('A planner process PID is required.');
    parseLevels(levels.join(','));
    parseDuration(durationSeconds);
    parseUsers(sustainedUsers);
    if (!Number.isInteger(maxWaitSeconds) || maxWaitSeconds < 1 || maxWaitSeconds > 900) {
        throw new Error('Maximum job wait must be an integer from 1 to 900 seconds.');
    }
    const base = new URL(baseUrl);
    if (!['127.0.0.1', 'localhost', '[::1]'].includes(base.hostname) || base.protocol !== 'http:') {
        throw new Error('Job load testing must target the authenticated Mini loopback service.');
    }
    const root = baseUrl.replace(/\/+$/, '');
    const headers = { Authorization: `Bearer ${token}`, Accept: 'application/json' };
    const statusResponse = await fetchImpl(`${root}/api/v3/journey-planner/status`, {
        headers, signal: AbortSignal.timeout(10000) });
    const status = await statusResponse.json();
    if (!statusResponse.ok || status.available !== true || !status.dataset?.version) {
        throw new Error('The planner has no active dataset.');
    }
    const searchTime = chooseSearchTime(status.dataset, now());
    const runId = randomUUID().replaceAll('-', '').slice(0, 12);
    let sequence = 0;
    const search = async (userIndex, stageLabel) => {
        const index = sequence++;
        const [origin, destination] = ROUTES[index % ROUTES.length];
        const body = { origin, destination, time: new Date(Date.parse(searchTime) + index * 60000).toISOString(),
            timeType: 'departAfter', realtime: 'off', algorithm: 'raptor', limit: 5, windowMinutes: 360 };
        const client = `load-${runId}-${stageLabel}-${userIndex + 1}`;
        const network = `198.18.0.${userIndex + 1}`;
        const jobHeaders = { ...headers, 'Content-Type': 'application/json',
            'X-Planner-Client': client, 'X-Planner-Forwarded': 'gateway-v1',
            'X-Planner-Caller-Network': network, 'Idempotency-Key': randomUUID() };
        const started = performance.now();
        let jobId = null, terminal = false, result;
        const finish = fields => ({ index, user: userIndex + 1, route: `${origin}-${destination}`,
            requestedTime: body.time, durationMs: round(performance.now() - started), ...fields });
        try {
            const submitted = await fetchImpl(`${root}/api/v3/journey-planner/search-jobs`, { method: 'POST',
                headers: jobHeaders, body: JSON.stringify(body), signal: AbortSignal.timeout(15000) });
            let state = await submitted.json();
            if (submitted.status !== 202 || !state?.id) {
                result = finish({ status: 'rejected', httpStatus: submitted.status,
                    errorCode: state?.error?.code ?? 'INVALID_JOB_RESPONSE', journeyCount: 0 });
            } else {
                jobId = state.id;
                const acceptedMs = round(performance.now() - started);
                let maxQueuePosition = state.queuePosition ?? null;
                while (!result) {
                    if (state.status === 'completed') {
                        terminal = true;
                        result = finish({ status: 'completed', httpStatus: 200, acceptedMs,
                            journeyCount: state.result?.journeys?.length ?? 0, maxQueuePosition, errorCode: null });
                    } else if (state.status === 'failed' || state.status === 'cancelled') {
                        terminal = true;
                        result = finish({ status: state.status, httpStatus: 200, acceptedMs,
                            journeyCount: 0, maxQueuePosition, errorCode: state.error?.code ?? state.status.toUpperCase() });
                    } else if (performance.now() - started >= maxWaitSeconds * 1000) {
                        result = finish({ status: 'timeout', httpStatus: null, acceptedMs,
                            journeyCount: 0, maxQueuePosition, errorCode: 'CLIENT_TIMEOUT' });
                    } else {
                        await sleep(Math.max(minPollMs, Math.min(1000, state.pollAfterMs ?? 1000)));
                        const polled = await fetchImpl(`${root}/api/v3/journey-planner/search-jobs/${jobId}`, {
                            headers, signal: AbortSignal.timeout(15000) });
                        state = await polled.json();
                        if (!polled.ok) result = finish({ status: 'poll-failed', httpStatus: polled.status,
                            acceptedMs, journeyCount: 0, maxQueuePosition,
                            errorCode: state?.error?.code ?? 'JOB_POLL_FAILED' });
                        else if (Number.isInteger(state.queuePosition)) {
                            maxQueuePosition = Math.max(maxQueuePosition ?? 0, state.queuePosition);
                        }
                    }
                }
            }
        } catch (error) {
            result = finish({ status: 'network-failed', httpStatus: null, journeyCount: 0,
                errorCode: error?.name === 'TimeoutError' ? 'CLIENT_TIMEOUT' : 'NETWORK_ERROR' });
        } finally {
            if (jobId && !terminal) {
                try {
                    const cancelled = await fetchImpl(`${root}/api/v3/journey-planner/search-jobs/${jobId}`, {
                        method: 'DELETE', headers, signal: AbortSignal.timeout(10000) });
                    if (!cancelled.ok) result.cancelWarning = `HTTP ${cancelled.status}`;
                } catch (error) { result.cancelWarning = error?.message ?? String(error); }
            }
        }
        return result;
    };
    const measure = async (kind, users, work) => {
        const cleared = await fetchImpl(`${root}/internal/planner/v1/cache/clear`, { method: 'POST',
            headers: { ...headers, 'Content-Type': 'application/json' }, body: '{}', signal: AbortSignal.timeout(15000) });
        if (!cleared.ok) throw new Error(`Could not clear search caches before ${kind} ${users} (${cleared.status}).`);
        const samples = [];
        const sample = async () => samples.push({ at: performance.now(),
            planner: await readPlanner(pid), host: await readHost() });
        await sample();
        let sampling = Promise.resolve(), samplingError = null;
        const timer = setInterval(() => { sampling = sampling.then(sample).catch(error => { samplingError = error; }); }, sampleIntervalMs);
        const startedAt = new Date(now()), started = performance.now();
        let results;
        try { results = await work(); }
        finally { clearInterval(timer); await sampling; await sample(); }
        const endedAt = new Date(now());
        if (samplingError) throw samplingError;
        const successful = results.filter(result => result.status === 'completed' && result.journeyCount > 0);
        const stage = { kind, users, attempted: results.length, successful: successful.length,
            startedAt: startedAt.toISOString(), endedAt: endedAt.toISOString(),
            durationMs: round(performance.now() - started),
            successfulLatency: durationSummary(successful.map(result => result.durationMs)),
            usage: summarizeResourceSamples(samples), results };
        await sleep(1000);
        return stage;
    };
    const stages = [];
    for (const users of levels) stages.push(await measure('burst', users,
        () => Promise.all(Array.from({ length: users }, (_, index) => search(index, `burst${users}`)))));
    if (durationSeconds > 0) stages.push(await measure('sustained', sustainedUsers, async () => {
        const stopAt = performance.now() + durationSeconds * 1000;
        const results = [];
        await Promise.all(Array.from({ length: sustainedUsers }, async (_, index) => {
            do { results.push(await search(index, 'sustained')); }
            while (performance.now() < stopAt);
        }));
        return results;
    }));
    const health = await fetchImpl(`${root}/healthcheck`, { signal: AbortSignal.timeout(5000) });
    return { generatedAt: new Date(now()).toISOString(), baseUrl: root, hostId: process.env.PLANNER_HOST_ID ?? null,
        source: 'search-job', datasetVersion: status.dataset.version, searchTime, processId: pid,
        algorithm: 'raptor', clientModel: 'one outstanding job per virtual user; distinct simulated networks',
        cachePolicy: 'clear-between-stages-with-distinct-times', durationSeconds, sustainedUsers,
        healthAfterLoad: health.status, stages };
}

export function formatJobsSummary(report) {
    const columns = [
        ['Stage', stage => `${stage.kind} ${stage.users}${stage.kind === 'sustained' ? `/${report.durationSeconds}s` : ''}`],
        ['Completed', stage => `${stage.successful}/${stage.attempted}`],
        ['p50 / p95', stage => stage.successful ? `${Math.round(stage.successfulLatency.medianMs)} / ${Math.round(stage.successfulLatency.p95Ms)} ms` : '—'],
        ['Queue p95', stage => {
            const values = stage.results.map(result => result.serverQueueMs).filter(Number.isFinite);
            return values.length ? `${Math.round(durationSummary(values).p95Ms)} ms` : '—';
        }],
        ['Planner CPU', stage => `${Math.round(stage.usage.peakPlannerCpuPercentOneCore)}%`],
        ['Host CPU', stage => `${Math.round(stage.usage.peakHostCpuPercent)}%`],
        ['Planner RSS', stage => `${Math.round(stage.usage.peakPlannerRssBytes / 1048576)} MiB`],
        ['Host free min', stage => `${stage.usage.minHostFreeMemoryPercent}%`],
        ['Swap peak', stage => `${stage.usage.peakSwapUsedMiB} MiB`]
    ];
    const widths = columns.map(([heading, value]) => Math.max(heading.length,
        ...report.stages.map(stage => value(stage).length)));
    const row = values => values.map((value, index) => value.padEnd(widths[index])).join('  ');
    return [row(columns.map(([heading]) => heading)), row(widths.map(width => '-'.repeat(width))),
        ...report.stages.map(stage => row(columns.map(([, value]) => value(stage))))].join('\n');
}

export function jobsLoadWarnings(report, missesVerified) {
    const failures = report.stages.flatMap(stage => stage.results.filter(result =>
        result.status !== 'completed' || result.journeyCount === 0 || result.cancelWarning)
        .map(result => `${stage.kind} ${stage.users}: ${result.route} ${result.errorCode ?? 'no journeys'}`
            + ` (${result.durationMs} ms)${result.cancelWarning ? `; cancellation ${result.cancelWarning}` : ''}`));
    const warnings = failures.slice(0, 10);
    if (failures.length > 10) warnings.push(`...and ${failures.length - 10} more search failures in the JSON report.`);
    if (!missesVerified) warnings.push('Zero-cache-hit verification failed; check the JSON report and Mini search log.');
    if (report.healthAfterLoad !== 200) warnings.push(`Planner health check returned HTTP ${report.healthAfterLoad}.`);
    return warnings;
}

function argsFrom(argv) {
    const options = {};
    for (let index = 0; index < argv.length; index++) {
        const name = argv[index], value = argv[++index];
        if (value === undefined) throw new Error(`Missing value for ${name}.`);
        if (name === '--base-url') options.baseUrl = value;
        else if (name === '--pid') options.pid = Number(value);
        else if (name === '--levels') options.levels = parseLevels(value);
        else if (name === '--duration-seconds') options.durationSeconds = parseDuration(value);
        else if (name === '--users') options.sustainedUsers = parseUsers(value);
        else if (name === '--output') options.output = value;
        else throw new Error(`Unknown option: ${name}`);
    }
    return options;
}

async function main() {
    const options = argsFrom(process.argv.slice(2));
    await readPlannerProcess(options.pid);
    const report = await runPlannerJobsLoad({ ...options, token: process.env.PLANNER_SERVICE_TOKEN });
    let missesVerified = false, cacheError = null;
    try { missesVerified = await verifyLoadCache(report); }
    catch (error) { cacheError = error; }
    if (options.output) await writeFile(options.output, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
    console.log(formatJobsSummary(report));
    console.log(`\nCache verification: ${missesVerified ? 'passed (zero hits)' : 'FAILED'}; planner health: HTTP ${report.healthAfterLoad}`);
    if (options.output) console.log(`Report: ${options.output}`);
    const warnings = jobsLoadWarnings(report, missesVerified);
    for (const warning of warnings) console.warn(`WARNING: ${warning}`);
    if (cacheError) console.warn(`WARNING: Cache verification could not run: ${cacheError.message}`);
    if (warnings.length) process.exitCode = 1;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main().catch(error => { console.error(`Planner jobs load test failed: ${error?.message || error}`); process.exitCode = 1; });
}
