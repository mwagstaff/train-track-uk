import { normalizeRequest, journeyID, PlannerError } from './contract.js';
import { scheduledCandidate, departureProfileOrder } from './router.js';
import { presentLivePage } from './live-coverage.js';

export const ROUTE_PROFILE_POLICY = 'route-profile-v1';
export const ROUTE_PROFILE_LIMIT = 512;
export const ROUTE_PROFILE_BYTES = 4 * 1024 * 1024 - 4096;

const compare = (a, b) => Date.parse(a.arrival) - Date.parse(b.arrival) || a.changes - b.changes
    || Date.parse(b.departure) - Date.parse(a.departure);
const candidateKey = candidate => candidate.legs.map(leg => leg.kind === 'vehicle'
    ? `${leg.serviceId}:${leg.boardIndex}:${leg.alightIndex}` : `${leg.from.crs}:${leg.to.crs}:${leg.mode}`).join('|');

function boundProfile(profile, candidates, check, preferredKeys = new Set()) {
    const retained = [];
    // Reserve room for the bounded completeness/departure summary below.
    let bytes = Buffer.byteLength(JSON.stringify({ ...profile, candidates: [] })) + 1024;
    if (bytes > ROUTE_PROFILE_BYTES) throw new PlannerError('INVALID_REQUEST', 'The saved route profile is too large.');
    let truncated = Boolean(profile.searchTruncated);
    const preferred = candidates.filter(candidate => preferredKeys.has(candidateKey(candidate)));
    const remaining = candidates.filter(candidate => !preferredKeys.has(candidateKey(candidate))).sort(compare);
    for (const candidate of [...preferred, ...departureProfileOrder(remaining)]) {
        check();
        const size = Buffer.byteLength(JSON.stringify(candidate)) + Number(retained.length > 0);
        if (retained.length >= ROUTE_PROFILE_LIMIT || bytes + size > ROUTE_PROFILE_BYTES) { truncated = true; continue; }
        retained.push(candidate); bytes += size;
    }
    retained.sort(compare);
    const departures = [...new Set(retained.map(candidate => candidate.departure))].sort();
    return { ...profile, candidates: retained, searchTruncated: truncated,
        profile: { ...profile.profile, complete: !truncated,
            departureTimesRetained: departures.length, firstRetainedDeparture: departures[0] ?? null,
            lastRetainedDeparture: departures.at(-1) ?? null } };
}

function normalizeProfileRequest(input) {
    if (!input || typeof input !== 'object') throw new PlannerError('INVALID_REQUEST', 'A saved route request is required.');
    const request = normalizeRequest({ ...input, windowMinutes: 360, limit: 10, realtime: 'off' });
    const windowMinutes = input.windowMinutes ?? 480;
    const via = input.via ?? [];
    if (request.timeType !== 'departAfter' || !Number.isInteger(windowMinutes) || windowMinutes < 15 || windowMinutes > 480
        || !Array.isArray(via) || via.length > 8 || via.some(code => typeof code !== 'string' || !/^[A-Z0-9]{3}$/.test(code))
        || new Set([request.origin, ...via, request.destination]).size !== via.length + 2) {
        throw new PlannerError('INVALID_REQUEST', 'Use a departure profile with distinct intermediate stations in travel order.');
    }
    return { ...request, via: [...via], windowMinutes, limit: ROUTE_PROFILE_LIMIT + 1 };
}

async function context(engine, payload, signal, execution) {
    const started = performance.now();
    const timeoutMs = execution.timeoutMs ?? engine.config.timeoutMs;
    let remainingOperations = execution.maxOperations ?? engine.config.maxOperations;
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || !Number.isSafeInteger(remainingOperations) || remainingOperations <= 0) {
        throw new PlannerError('INVALID_REQUEST', 'Invalid planner execution budget.');
    }
    const check = () => {
        if (signal?.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499);
        if (performance.now() - started >= timeoutMs) throw new PlannerError('SEARCH_TIMEOUT', 'The route search exceeded its execution time budget.', 504);
    };
    check();
    const repo = await engine.dataset(payload.version ?? payload.profile?.dataset?.version);
    const request = engine.checkQuery(repo, normalizeProfileRequest(payload.request ?? payload.profile?.request));
    for (const code of request.via) {
        const canonical = engine.checkQuery(repo, { ...request, origin: code }).origin;
        if (canonical !== code) throw new PlannerError('INVALID_STATION', 'Use canonical intermediate station codes.');
    }
    execution.onProgress?.('preparing');
    const network = await engine.network(repo, request, signal);
    check();
    const routeCurrent = async (query, current, options = {}) => {
        check();
        if (remainingOperations <= 0) throw new PlannerError('SEARCH_TIMEOUT', 'The route search exceeded its work budget.', 504);
        const result = await engine.route({ ...query, via: request.via }, current, {
            ...options, signal, maxDurationMinutes: 1440, maxOperations: remainingOperations,
            timeoutMs: Math.max(1, timeoutMs - (performance.now() - started))
        });
        remainingOperations -= result.metrics?.operations ?? 0;
        check();
        return result;
    };
    const route = async (query, current, options = {}) => {
        const begin = Date.parse(query.time), end = begin + query.windowMinutes * 60000;
        const results = [], warnings = new Set();
        let first, total = 0, departureTimes = 0, truncated = false, operations = 0, labels = 0;
        const totalWindows = Math.ceil(query.windowMinutes / 60);
        let completedWindows = 0;
        execution.onProgress?.({ phase: 'searching', completedWindows, totalWindows });
        // A saved board keeps the frontier independently for each departure.
        // Disjoint departure windows therefore combine exactly, while releasing
        // each national search's intermediate labels before the next window.
        for (let from = begin; from < end; from += 60 * 60000) {
            check();
            if (remainingOperations <= 0) throw new PlannerError('SEARCH_TIMEOUT', 'The route search exceeded its work budget.', 504);
            const part = await engine.route({ ...query, time: new Date(from).toISOString(),
                windowMinutes: Math.min(60, (end - from) / 60000), via: request.via, limit: ROUTE_PROFILE_LIMIT + 1 }, current, {
                ...options, signal, departureProfile: true, balanceDepartures: true, offset: 0, maxDurationMinutes: 1440,
                maxOperations: remainingOperations, timeoutMs: Math.max(1, timeoutMs - (performance.now() - started))
            });
            if (!first) first = { ...part, journeys: [] };
            remainingOperations -= part.metrics?.operations ?? 0;
            operations += part.metrics?.operations ?? 0;
            labels += part.metrics?.labels ?? 0;
            total += part.pagination?.total ?? part.journeys.length;
            departureTimes += part.pagination?.departureTimes ?? new Set(part.journeys.map(journey => journey.departure)).size;
            truncated ||= Boolean(part.searchTruncated || total > ROUTE_PROFILE_LIMIT);
            for (const warning of part.warnings ?? []) warnings.add(warning);
            results.push(...part.journeys);
            const balanced = departureProfileOrder(results.sort(compare)).slice(0, ROUTE_PROFILE_LIMIT + 1);
            results.splice(0, results.length, ...balanced);
            execution.onProgress?.({ phase: 'searching', completedWindows: ++completedWindows, totalWindows });
        }
        check();
        return { ...first, journeys: results, warnings: [...warnings], searchTruncated: truncated,
            searchWindow: { from: query.time, to: new Date(end).toISOString(), fromInclusive: true, toInclusive: false },
            pagination: { total, departureTimes }, metrics: { operations, labels, elapsedMs: performance.now() - started } };
    };
    return { repo, request, network, check, route, routeCurrent };
}

function envelope(engine, repo, request, raw, profile, time = request.time, network) {
    const dataset = engine.publicMetadata(repo, raw.live);
    const searchTruncated = Boolean(profile.searchTruncated || raw.searchTruncated);
    const wanted = new Set([...raw.journeys, ...(raw.disruptedJourneys ?? [])].flatMap(journey => journey.legs)
        .filter(leg => leg.kind === 'vehicle').map(leg => leg.scheduledServiceId ?? leg.serviceId));
    const services = new Map((network?.services ?? []).filter(service => wanted.has(service.id)).map(service => [service.id, service]));
    const present = journey => {
        const result = engine.publicJourney(journey);
        result.legs.forEach((leg, index) => {
            const original = journey.legs[index];
            if (original.uid) leg.uid = original.uid;
            if (original.tracking) leg.tracking = original.tracking;
            const service = services.get(original.scheduledServiceId ?? original.serviceId);
            if (service) leg.serviceCallingPoints = service.calls.filter(call => call.canBoard || call.canAlight).map(call => ({
                station: engine.publicStation(network.stations.get(call.station) ?? call.station),
                arrival: Number.isFinite(call.arrival) ? new Date(call.arrival).toISOString() : null,
                departure: Number.isFinite(call.departure) ? new Date(call.departure).toISOString() : null
            }));
        });
        const first = result.legs.find(leg => leg.kind === 'vehicle');
        if (first) result.firstTrain = { serviceId: first.scheduledServiceId ?? first.serviceId, originDate: first.originDate,
            from: first.from, to: first.to, departure: first.departure, scheduledDeparture: first.scheduledDeparture ?? first.departure };
        result.id = journeyID(result, repo.version, raw.live ? { profile: profile.profile.createdAt, time, ...raw.live } : undefined);
        engine.retainJourney(result, repo.version, raw.live);
        return result;
    };
    return { journeys: raw.journeys.map(present), dataset,
        ...(raw.live ? { live: raw.live, disruptedJourneys: (raw.disruptedJourneys ?? []).map(present) } : {}),
        search: { ...request, time, realtime: raw.live?.mode ?? request.realtime, limit: raw.journeys.length, window: profile.searchWindow,
            searchTruncated },
        warnings: [...new Set([...dataset.warnings, ...(profile.warnings ?? []), ...(raw.warnings ?? []), ...(raw.live?.warnings ?? []),
            ...(searchTruncated ? ['More alternatives may exist; this route list is limited.'] : [])])],
        pagination: {}, ...(raw.needsReplan !== undefined ? { needsReplan: raw.needsReplan } : {}),
        ...(raw.disruptionFingerprint ? { disruptionFingerprint: raw.disruptionFingerprint } : {}) };
}

export async function routeBoardProfile(engine, payload, signal, execution = {}) {
    const { repo, request, network, check, route } = await context(engine, payload, signal, execution);
    execution.onProgress?.('searching');
    const routed = await route(request, network);
    const candidates = routed.journeys;
    const searchTruncated = Boolean(routed.searchTruncated || routed.journeys.length > ROUTE_PROFILE_LIMIT
        || routed.pagination?.total > ROUTE_PROFILE_LIMIT);
    const profile = boundProfile({ version: repo.version, request, dataset: engine.publicMetadata(repo), searchWindow: routed.searchWindow,
        searchTruncated, warnings: routed.warnings ?? [], profile: { policy: ROUTE_PROFILE_POLICY,
            createdAt: new Date(engine.now()).toISOString(), candidateLimit: ROUTE_PROFILE_LIMIT,
            departureTimesAvailable: routed.pagination.departureTimes } }, candidates, check);
    check();
    const result = envelope(engine, repo, request, { ...routed, journeys: profile.candidates.slice(0, 5) }, profile, request.time, network);
    return { result, profile };
}

export async function routeBoardRefresh(engine, payload, signal, execution = {}) {
    if (payload.profile?.profile?.policy !== ROUTE_PROFILE_POLICY || !Array.isArray(payload.profile?.candidates)
        || payload.profile.candidates.length > ROUTE_PROFILE_LIMIT) throw new PlannerError('CURSOR_EXPIRED', 'The saved route profile needs to be refreshed.', 410);
    const { repo, request, network, check } = await context(engine, payload, signal, execution);
    // Validate the actual current instant without imposing the public six-hour
    // window limit on this private eight-hour scheduled profile.
    const current = normalizeRequest({ ...request, time: payload.time, windowMinutes: 360,
        limit: payload.limit ?? 5, realtime: payload.realtime ?? 'apply' });
    if (!engine.livePlanner) {
        const { LivePlanner } = await import('./live-search.js');
        engine.livePlanner = new LivePlanner({ now: engine.now, provider: engine.liveProvider, createBudget: engine.createLiveBudget });
    }
    const provider = await engine.livePlanner.source();
    const { refreshRouteBoard } = await import('./route-board-live.js');
    execution.onProgress?.('live');
    const raw = await refreshRouteBoard({ profile: payload.profile, network, time: current.time, limit: current.limit,
        realtime: payload.realtime ?? 'apply', check, abortSignal: execution.abortSignal },
    { provider, now: engine.now, createBudget: engine.livePlanner.createBudget });
    check();
    return envelope(engine, repo, request, raw, payload.profile, current.time, network);
}

export async function routeBoardReplan(engine, payload, signal, execution = {}) {
    if (payload.profile?.profile?.policy !== ROUTE_PROFILE_POLICY || !Array.isArray(payload.profile?.candidates)
        || payload.profile.candidates.length > ROUTE_PROFILE_LIMIT) throw new PlannerError('CURSOR_EXPIRED', 'The saved route profile needs to be refreshed.', 410);
    const { repo, request, network, check, routeCurrent } = await context(engine, payload, signal, execution);
    const current = normalizeRequest({ ...request, time: payload.time, windowMinutes: 360,
        limit: payload.limit ?? 5, realtime: payload.realtime ?? 'apply' });
    if (!engine.livePlanner) {
        const { LivePlanner } = await import('./live-search.js');
        engine.livePlanner = new LivePlanner({ now: engine.now, provider: engine.liveProvider, createBudget: engine.createLiveBudget });
    }
    execution.onProgress?.('live');
    const remainingMinutes = (Date.parse(payload.profile.searchWindow.to) - Date.parse(current.time)) / 60000;
    if (!(remainingMinutes > 0)) throw new PlannerError('CURSOR_EXPIRED', 'The saved route profile needs to be refreshed.', 410);
    const raw = await engine.livePlanner.search({ request: { ...request, time: current.time,
        windowMinutes: Math.min(360, remainingMinutes), realtime: payload.realtime ?? 'apply' }, network,
        version: repo.version, route: routeCurrent, check, abortSignal: execution.abortSignal });
    // The refresh helper owns the same direct/connecting ranking policy. Its
    // input candidates may be freshly routed; it rechecks them before display.
    const { selectRouteBoardJourneys } = await import('./route-board-live.js');
    const selected = selectRouteBoardJourneys(raw.journeys, current.limit);
    const page = presentLivePage(selected, raw.live, { now: Date.parse(current.time) });
    const candidates = new Map();
    const preferredKeys = new Set(selected.map(journey => scheduledCandidate(journey, network)).filter(Boolean).map(candidateKey));
    for (const journey of [...raw.journeys, ...payload.profile.candidates]) {
        check();
        const candidate = scheduledCandidate(journey, network);
        if (!candidate) continue;
        const key = candidateKey(candidate);
        if (!candidates.has(key)) candidates.set(key, candidate);
    }
    const truncated = Boolean(payload.profile.searchTruncated || raw.searchTruncated || candidates.size > ROUTE_PROFILE_LIMIT);
    const refreshProfile = boundProfile({ ...payload.profile, searchTruncated: truncated,
        profile: { ...payload.profile.profile, ephemeral: true } }, [...candidates.values()], check, preferredKeys);
    check();
    return { ...envelope(engine, repo, request, { ...raw, ...page, needsReplan: false,
        disruptionFingerprint: payload.disruptionFingerprint }, payload.profile, current.time, network), refreshProfile };
}
