import { PlannerError, normalizeRequest } from './contract.js';
import { dateOnly, londonDate } from './time.js';
import { prepareNetwork } from './router.js';

const MINUTE = 60000;
const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });

// Check both UK offsets instead of silently picking one occurrence of a repeated
// clock hour. Such windows cannot support a confident disruption comparison.
function localInstant(date, minutes) {
    const civil = Date.parse(`${date}T00:00:00Z`) + minutes * MINUTE;
    const expected = new Date(civil);
    const day = expected.toISOString().slice(0, 10);
    const time = expected.toISOString().slice(11, 16);
    const matches = [civil, civil - 60 * MINUTE].filter(value => londonDate(value) === day && clock.format(value) === time);
    return matches.length === 1 ? matches[0] : null;
}

export function normalizeDisruptionWindow(body) {
    if (!body || typeof body !== 'object') throw new PlannerError('INVALID_REQUEST', 'Supply a disruption monitoring window.');
    try { dateOnly(body.date); } catch { throw new PlannerError('INVALID_REQUEST', 'Use a valid monitoring date.'); }
    const { startMinutes, endMinutes } = body;
    if (!Number.isInteger(startMinutes) || !Number.isInteger(endMinutes) || startMinutes < 0 || startMinutes >= 1440
        || endMinutes - startMinutes < 1 || endMinutes - startMinutes > 60) {
        throw new PlannerError('INVALID_REQUEST', 'Use a monitoring interval between 1 and 60 minutes.');
    }
    const from = localInstant(body.date, startMinutes), to = localInstant(body.date, endMinutes);
    const request = normalizeRequest({ origin: body.from, destination: body.to, via: body.via,
        time: new Date(from ?? Date.parse(`${body.date}T12:00:00Z`)).toISOString(), timeType: 'departAfter',
        windowMinutes: Math.max(15, endMinutes - startMinutes), limit: 10, realtime: 'off',
        maxChanges: body.maxChanges, allowedModes: body.allowedModes, extraConnectionMinutes: body.extraConnectionMinutes });
    if (new Set([request.origin, ...(request.via ?? []), request.destination]).size !== (request.via?.length ?? 0) + 2) {
        throw new PlannerError('INVALID_REQUEST', 'Use distinct stations in travel order.');
    }
    return { request, from, to, clockChange: from === null || to === null || to - from !== (endMinutes - startMinutes) * MINUTE };
}

function directServices(index, request, from, to, check) {
    const services = new Set(), stationCRS = new Set();
    if (!request.allowedModes.includes('rail')) return { services, stationCRS };
    // Full routing already needs this immutable date index. Inspect only the
    // origin's departures in the exact window instead of rescanning UK calls.
    const departures = index.departures.get(request.origin) ?? [];
    let low = 0, high = departures.length;
    while (low < high) {
        const middle = (low + high) >>> 1;
        if (departures[middle].time < from) low = middle + 1;
        else high = middle;
    }
    for (let position = low; position < departures.length && departures[position].time < to; position++) {
        check();
        const { service, index: board, time: departure } = departures[position];
        if (service.mode !== 'rail') continue;
        let viaProgress = 0;
        for (let alight = board + 1; alight < service.calls.length; alight++) {
            check();
            const last = service.calls[alight];
            if ((last.canBoard || last.canAlight) && last.station === request.via?.[viaProgress]) viaProgress++;
            if (last.station !== request.destination || !last.canAlight || !Number.isFinite(last.arrival)
                || last.arrival < departure || last.arrival - departure > 1440 * MINUTE
                || viaProgress !== (request.via?.length ?? 0)) continue;
            services.add(service.id);
            for (const call of service.calls.slice(board, alight + 1)) stationCRS.add(call.station);
            break;
        }
    }
    return { services, stationCRS };
}

export async function disruptionProfile(engine, body, signal, execution = {}) {
    const { request: normalized, from, to, clockChange } = normalizeDisruptionWindow(body);
    const result = { complete: false, datasetVersion: null, sourceGenerationDate: null,
        date: body.date, startMinutes: body.startMinutes, endMinutes: body.endMinutes,
        directTrains: 0, replacementBus: false, railOnlyAvailable: false, servicesAvailable: false,
        minChanges: null, durationMinutes: null, stationCRS: [] };
    const started = performance.now(), timeoutMs = execution.timeoutMs ?? engine.config.timeoutMs;
    let remainingOperations = execution.maxOperations ?? engine.config.maxOperations;
    const check = () => {
        if (signal?.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Monitoring cancelled.', 499);
        if (performance.now() - started >= timeoutMs) throw new PlannerError('SEARCH_TIMEOUT', 'Monitoring exceeded its work budget.', 504);
    };
    check();
    try {
        const repo = await engine.dataset();
        result.datasetVersion = repo.version;
        result.sourceGenerationDate = repo.metadata.source.generationDate;
        if (clockChange) return { ...result, reason: 'CLOCK_CHANGE' };
        const request = engine.checkQuery(repo, normalized);
        // The planner normally checks only the starting date. Monitoring must
        // also refuse a window extending beyond the published timetable.
        if (londonDate(to - 1) > repo.metadata.coverage.endDate) return { ...result, reason: 'UNSUPPORTED_DATE' };
        const network = await engine.network(repo, request, signal);
        check();
        const index = prepareNetwork(network, check);
        const direct = directServices(index, request, from, to, check);
        result.directTrains = direct.services.size;
        const route = async allowedModes => {
            check();
            const response = await engine.routeBoardProfileChunk({ request: { ...request, allowedModes }, version: repo.version,
                chunk: { from: new Date(from).toISOString(), to: new Date(to).toISOString() } }, signal, {
                ...execution, measure: execution.measure ?? ((name, work) => work()),
                timeoutMs: Math.max(1, timeoutMs - (performance.now() - started)),
                maxOperations: remainingOperations,
                onTelemetry: event => {
                    remainingOperations -= event.metricsDelta?.operations ?? 0;
                    execution.onTelemetry?.(event);
                } });
            check();
            return response.profile;
        };
        const profile = await route(request.allowedModes);
        const bus = journey => journey.legs.some(leg => leg.mode === 'replacementBus');
        const ordinaryRail = journey => journey.legs.some(leg => ['rail', 'tubeTransfer'].includes(leg.mode))
            && journey.legs.every(leg => ['rail', 'tubeTransfer', 'walk', 'interchange'].includes(leg.mode));
        let candidates = profile.candidates;
        let rail = candidates.filter(journey => !bus(journey));
        let complete = profile.profile.complete && !profile.searchTruncated;
        // A quicker bus can dominate an ordinary train in the combined
        // frontier. Explicitly search without buses before claiming one is needed.
        if (!rail.length && candidates.some(bus)) {
            const modes = request.allowedModes.filter(mode => mode !== 'replacementBus');
            if (modes.length) {
                const alternative = await route(modes);
                rail = alternative.candidates;
                candidates = [...candidates, ...rail];
                complete &&= alternative.profile.complete && !alternative.searchTruncated;
            }
        }
        const stations = direct.stationCRS;
        for (const journey of candidates) for (const leg of journey.legs) {
            check();
            stations.add(leg.from.crs); stations.add(leg.to.crs);
            const service = index.services.get(leg.serviceId);
            if (service) for (const call of service.calls.slice(leg.boardIndex, leg.alightIndex + 1)) stations.add(call.station);
        }
        const diagnosticCodes = Object.entries(network.diagnostics?.counts ?? {})
            .filter(([code, count]) => code !== 'CANCELLED' && count > 0).map(([code]) => code).sort();
        // Global excluded variants/fixed links are supported-coverage limits:
        // unrelated conflicting records must not invalidate every UK route.
        // Malformed times and ambiguous dated services still cannot establish
        // an absence. The local repeated/missing clock hour is checked above.
        const partialTimetable = diagnosticCodes.some(code => /INVALID|AMBIGUOUS/.test(code));
        return { ...result, complete: Boolean(complete && !partialTimetable),
            servicesAvailable: candidates.length > 0, railOnlyAvailable: rail.some(ordinaryRail) || direct.services.size > 0,
            replacementBus: candidates.some(bus) && !rail.length && !direct.services.size,
            minChanges: candidates.length ? Math.min(...candidates.map(journey => journey.changes)) : null,
            durationMinutes: candidates.length ? Math.min(...candidates.map(journey => journey.durationMinutes)) : null,
            stationCRS: [...stations].filter(Boolean).sort(), diagnosticCodes,
            limitations: [...(repo.metadata.limitations ?? []), ...(profile.warnings ?? [])],
            ...(!complete || partialTimetable ? { reason: 'INCOMPLETE_TIMETABLE' } : {}) };
    } catch (error) {
        if (error.code === 'SEARCH_CANCELLED') throw error;
        if (['SEARCH_TIMEOUT', 'DATASET_UNAVAILABLE', 'DATASET_STALE', 'UNSUPPORTED_DATE', 'CURSOR_EXPIRED'].includes(error.code)) {
            return { ...result, reason: error.code };
        }
        throw error;
    }
}
