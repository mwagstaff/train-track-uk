#!/usr/bin/env node
import { randomUUID } from 'node:crypto';
import { writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';

const DAY_MS = 24 * 60 * 60 * 1000;

export function parseComplexRoutes(value) {
    if (typeof value !== 'string' || !value.trim()) return [];
    return value.split(',').map((entry) => {
        const match = /^([A-Z0-9]{3})-([A-Z0-9]{3})$/i.exec(entry.trim());
        if (!match || match[1].toUpperCase() === match[2].toUpperCase()) {
            throw new Error(`Invalid complex route: ${entry}. Use ORG-DST station-code pairs.`);
        }
        return { origin: match[1].toUpperCase(), destination: match[2].toUpperCase() };
    });
}

export function chooseSearchTime(dataset, now = Date.now()) {
    const from = dataset?.coverage?.from;
    const to = dataset?.coverage?.to;
    if (!/^\d{4}-\d{2}-\d{2}$/.test(from ?? '') || !/^\d{4}-\d{2}-\d{2}$/.test(to ?? '')) {
        throw new Error('Planner status did not include a usable coverage range. Supply --time explicitly.');
    }
    const tomorrow = new Date(now + DAY_MS).toISOString().slice(0, 10);
    const date = tomorrow < from ? from : tomorrow > to ? to : tomorrow;
    return `${date}T09:00:00Z`;
}

export function durationSummary(values) {
    const sorted = [...values].sort((a, b) => a - b);
    const percentile = value => sorted[Math.max(0, Math.ceil(sorted.length * value) - 1)] ?? null;
    return { count: sorted.length, minMs: sorted[0] ?? null,
        medianMs: percentile(0.5), p95Ms: percentile(0.95), maxMs: sorted.at(-1) ?? null };
}

export async function runPlannerServiceSmoke({ baseUrl = 'http://127.0.0.1:3014', token,
    origin = 'KTH', destination = 'VIC', time, runs = 3, algorithms = ['original', 'raptor'],
    complexRoutes = [], clearCacheBeforeSearch = false, fetchImpl = fetch, now = Date.now } = {}) {
    if (typeof token !== 'string' || token.length < 16) throw new Error('PLANNER_SERVICE_TOKEN must contain at least 16 characters.');
    if (!/^[A-Z0-9]{3}$/.test(origin) || !/^[A-Z0-9]{3}$/.test(destination) || origin === destination) {
        throw new Error('Use distinct three-character --origin and --destination station codes.');
    }
    if (!Number.isSafeInteger(runs) || runs < 1 || runs > 20) throw new Error('--runs must be between 1 and 20.');
    if (!Array.isArray(algorithms) || algorithms.length === 0
        || algorithms.some(algorithm => !['original', 'raptor'].includes(algorithm))) {
        throw new Error('Algorithms must contain original and/or raptor.');
    }
    if (!Array.isArray(complexRoutes)) throw new Error('complexRoutes must be an array of station pairs.');
    const normalizedComplexRoutes = complexRoutes.map((route) => {
        const routeOrigin = String(route?.origin ?? '').toUpperCase();
        const routeDestination = String(route?.destination ?? '').toUpperCase();
        if (!/^[A-Z0-9]{3}$/.test(routeOrigin) || !/^[A-Z0-9]{3}$/.test(routeDestination)
            || routeOrigin === routeDestination) throw new Error('Complex routes must use distinct three-character station codes.');
        return { origin: routeOrigin, destination: routeDestination };
    });
    const root = baseUrl.replace(/\/+$/, '');
    const request = async (name, pathname, { method = 'GET', body, headers = {}, timeoutMs = 45000,
        accepted = [200], json = true } = {}) => {
        const started = performance.now();
        let response;
        try {
            response = await fetchImpl(`${root}${pathname}`, { method, redirect: 'manual', signal: AbortSignal.timeout(timeoutMs),
                headers: { Authorization: `Bearer ${token}`, Accept: 'application/json', ...headers,
                    ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
                ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
        } catch (error) {
            throw new Error(`${name} could not reach the planner: ${error?.message || error}`);
        }
        const durationMs = Math.round((performance.now() - started) * 10) / 10;
        const text = await response.text();
        let payload = text;
        if (json) {
            try { payload = text ? JSON.parse(text) : null; }
            catch { throw new Error(`${name} returned non-JSON data (${response.status}).`); }
        }
        if (!accepted.includes(response.status)) {
            throw new Error(`${name} failed (${response.status} ${payload?.error?.code ?? 'UNKNOWN'}): ${payload?.error?.message ?? 'No safe error message.'}`);
        }
        return { status: response.status, durationMs, payload, retryAfter: response.headers.get('retry-after') };
    };

    const health = await request('health', '/internal/planner/v1/health');
    const readiness = await request('readiness', '/internal/planner/v1/readiness');
    const status = await request('status', '/api/v3/journey-planner/status');
    if (status.payload?.available !== true || !status.payload?.dataset?.version) {
        throw new Error(`Planner status is unavailable: ${status.payload?.reason ?? 'no active dataset'}`);
    }
    const searchTime = time || chooseSearchTime(status.payload.dataset, now());
    let cacheClears = 0;
    const clearCache = async label => {
        if (!clearCacheBeforeSearch) return;
        await request(`${label} cache clear`, '/internal/planner/v1/cache/clear', { method: 'POST', body: {} });
        cacheClears++;
    };
    const stationChecks = [];
    const stationCodes = [...new Set([origin, destination,
        ...normalizedComplexRoutes.flatMap(route => [route.origin, route.destination])])];
    for (const code of stationCodes) {
        const result = await request(`station ${code}`, `/api/v3/journey-planner/stations?q=${encodeURIComponent(code)}`);
        const rows = Array.isArray(result.payload) ? result.payload : result.payload?.stations;
        if (!Array.isArray(rows) || !rows.some(row => row?.crs === code)) throw new Error(`Station ${code} was not returned by the planner.`);
        stationChecks.push({ code, durationMs: result.durationMs });
    }

    const searches = [];
    let detail = null;
    for (const algorithm of algorithms) {
        const samples = [];
        for (let run = 1; run <= runs; run++) {
            const body = { origin, destination, time: searchTime, timeType: 'departAfter', realtime: 'off',
                algorithm, limit: 5, windowMinutes: 360 };
            await clearCache(`${algorithm} search ${run}`);
            const result = await request(`${algorithm} search ${run}`, '/api/v3/journey-planner/search', { method: 'POST', body });
            const journeys = result.payload?.journeys;
            if (!Array.isArray(journeys)) throw new Error(`${algorithm} search returned no journeys array.`);
            samples.push({ run, durationMs: result.durationMs, journeyCount: journeys.length,
                truncated: result.payload?.search?.searchTruncated === true });
            if (!detail && journeys[0]?.id) {
                const value = await request('journey detail', `/api/v3/journey-planner/journeys/${encodeURIComponent(journeys[0].id)}`);
                detail = { durationMs: value.durationMs, journeyId: journeys[0].id,
                    legCount: value.payload?.journey?.legs?.length ?? null };
            }
        }
        searches.push({ algorithm, samples, summary: durationSummary(samples.map(sample => sample.durationMs)) });
    }

    const runQueuedSearch = async (body, label) => {
        await clearCache(label);
        const idempotencyKey = `mini-planner-${randomUUID()}`;
        const submitted = await request(`${label} submission`, '/api/v3/journey-planner/search-jobs', {
            method: 'POST', body, accepted: [202], headers: {
                'X-Planner-Client': 'mini-planner-smoke', 'Idempotency-Key': idempotencyKey
            }
        });
        const jobId = submitted.payload?.id;
        if (typeof jobId !== 'string') throw new Error(`${label} submission returned no job ID.`);
        const jobStarted = performance.now();
        let job = submitted.payload;
        let polls = 0;
        while (['queued', 'running'].includes(job.status) && performance.now() - jobStarted < 12 * 60 * 1000) {
            const delay = Math.max(100, Math.min(2000, Number(job.pollAfterMs) || 1000));
            await new Promise(resolve => setTimeout(resolve, delay));
            const polled = await request(`${label} poll`, `/api/v3/journey-planner/search-jobs/${encodeURIComponent(jobId)}`, {
                headers: { 'X-Planner-Client': 'mini-planner-smoke' }, timeoutMs: 15000
            });
            polls++;
            job = polled.payload;
        }
        if (job.status !== 'completed') {
            throw new Error(`${label} ended in ${job.status ?? 'an unknown state'} (${job.error?.code ?? 'no code'}).`);
        }
        return { submitMs: submitted.durationMs, polls, totalMs: Math.round((performance.now() - jobStarted) * 10) / 10,
            journeyCount: job.result?.journeys?.length ?? 0, truncated: job.result?.search?.searchTruncated === true };
    };

    const jobBody = { origin, destination, time: searchTime, timeType: 'departAfter', realtime: 'off',
        algorithm: algorithms[0], limit: 5, windowMinutes: 360 };
    const queuedSearch = await runQueuedSearch(jobBody, 'queued search');

    const complexRouteResults = [];
    for (const route of normalizedComplexRoutes) {
        const routeResult = { ...route, algorithms: [] };
        for (const algorithm of algorithms) {
            const routeTime = searchTime;
            const body = { ...route, time: routeTime, timeType: 'departAfter', realtime: 'off',
                algorithm, limit: 5, windowMinutes: 360 };
            await clearCache(`${route.origin}-${route.destination} ${algorithm} direct search`);
            const direct = await request(`${route.origin}-${route.destination} ${algorithm} direct search`,
                '/api/v3/journey-planner/search', { method: 'POST', body, accepted: [200, 504], timeoutMs: 135000 });
            const journeys = direct.status === 200 ? direct.payload?.journeys : null;
            if (direct.status === 200 && (!Array.isArray(journeys) || journeys.length === 0)) {
                throw new Error(`${route.origin}-${route.destination} ${algorithm} returned no journeys.`);
            }
            const result = { algorithm, time: routeTime, direct: { status: direct.status,
                durationMs: direct.durationMs, journeyCount: journeys?.length ?? 0,
                truncated: direct.payload?.search?.searchTruncated === true,
                errorCode: direct.status === 200 ? null : direct.payload?.error?.code ?? 'UNKNOWN' }, queuedFallback: null };
            if (direct.status === 504) {
                result.queuedFallback = await runQueuedSearch(body, `${route.origin}-${route.destination} ${algorithm} queued fallback`);
                if (result.queuedFallback.journeyCount === 0) {
                    throw new Error(`${route.origin}-${route.destination} ${algorithm} queued fallback returned no journeys.`);
                }
            }
            routeResult.algorithms.push(result);
        }
        complexRouteResults.push(routeResult);
    }

    let residentMemoryBytes = null;
    try {
        const metrics = await request('metrics', '/internal/planner/metrics', { json: false });
        const match = /^process_resident_memory_bytes(?:\{[^}]*\})?\s+([0-9.e+-]+)$/m.exec(String(metrics.payload));
        residentMemoryBytes = match ? Number(match[1]) : null;
    } catch { /* Metrics are supplementary to the functional smoke test. */ }

    return { generatedAt: new Date(now()).toISOString(), baseUrl: root, hostId: health.payload?.hostId ?? null,
        protocolVersion: health.payload?.protocolVersion ?? null, processReady: health.payload?.ready === true,
        readinessReason: readiness.payload?.readinessReason ?? null, persistence: readiness.payload?.ingestion?.enabled === true
            ? 'ingestion-enabled' : 'isolated-test', dataset: status.payload.dataset, query: { origin, destination, time: searchTime },
        endpointMs: { health: health.durationMs, readiness: readiness.durationMs, status: status.durationMs,
            stations: stationChecks, detail: detail?.durationMs ?? null, jobSubmit: queuedSearch.submitMs },
        cachePolicy: clearCacheBeforeSearch ? 'clear-before-each-search' : 'normal', cacheClears,
        searches, detail, queuedSearch, complexRoutes: complexRouteResults, residentMemoryBytes };
}

function argumentsFrom(argv) {
    const options = { algorithms: ['original', 'raptor'] };
    for (let index = 0; index < argv.length; index++) {
        const name = argv[index];
        if (name === '--json') { options.json = true; continue; }
        if (name === '--no-cache') { options.clearCacheBeforeSearch = true; continue; }
        const value = argv[++index];
        if (value === undefined) throw new Error(`Missing value for ${name}.`);
        if (name === '--base-url') options.baseUrl = value;
        else if (name === '--origin') options.origin = value.toUpperCase();
        else if (name === '--destination') options.destination = value.toUpperCase();
        else if (name === '--time') options.time = value;
        else if (name === '--runs') options.runs = Number(value);
        else if (name === '--algorithms') options.algorithms = value.split(',').filter(Boolean);
        else if (name === '--complex-routes') options.complexRoutes = parseComplexRoutes(value);
        else if (name === '--output') options.output = value;
        else throw new Error(`Unknown option: ${name}`);
    }
    return options;
}

function printReport(report) {
    console.log(`Planner service smoke test · ${report.hostId ?? 'unknown host'} · ${report.query.origin} → ${report.query.destination}`);
    console.log(`Dataset ${report.dataset.version.slice(0, 12)} · ${report.query.time}`);
    if (report.cachePolicy === 'clear-before-each-search') console.log(`Search-result cache cleared before each request (${report.cacheClears} clears).`);
    for (const search of report.searches) {
        const timings = search.samples.map(sample => `${sample.durationMs} ms`).join(', ');
        console.log(`${search.algorithm}: ${timings} (median ${search.summary.medianMs} ms, p95 ${search.summary.p95Ms} ms)`);
    }
    console.log(`Queued search: ${report.queuedSearch.totalMs} ms across ${report.queuedSearch.polls} poll(s)`);
    for (const route of report.complexRoutes) {
        for (const search of route.algorithms) {
            const direct = `${search.direct.durationMs} ms / HTTP ${search.direct.status}`;
            const fallback = search.queuedFallback
                ? `; queued fallback ${search.queuedFallback.totalMs} ms (${search.queuedFallback.journeyCount} journeys)` : '';
            console.log(`${route.origin} → ${route.destination} ${search.algorithm}: ${direct}${fallback}`);
        }
    }
    if (Number.isFinite(report.residentMemoryBytes)) console.log(`Process RSS after checks: ${(report.residentMemoryBytes / 1048576).toFixed(1)} MiB`);
    if (!report.processReady) console.log(`Readiness: not production-ready (${report.readinessReason ?? 'unspecified'}); searches still passed in isolated test mode.`);
}

async function main() {
    const options = argumentsFrom(process.argv.slice(2));
    const report = await runPlannerServiceSmoke({ ...options, token: process.env.PLANNER_SERVICE_TOKEN });
    if (options.output) await writeFile(options.output, `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
    if (options.json) console.log(JSON.stringify(report, null, 2));
    else printReport(report);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    main().catch(error => { console.error(`Planner smoke test failed: ${error?.message || error}`); process.exitCode = 1; });
}
