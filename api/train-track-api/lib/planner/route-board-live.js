import { createHash } from 'node:crypto';
import { PlannerError } from './contract.js';
import { createConnectionIndex, resolveConnection } from './connections.js';
import { validateJourney } from './router.js';
import { discoverLiveMatches, matchLiveObservations, expectedDepartureTime, applyLiveSnapshot, annotateLiveJourney, liveCall, liveLeg } from './live-network.js';
import { matchStaffObservations } from './live-staff-matching.js';
import { presentLivePage } from './live-coverage.js';
import { tubeBoardings } from './tube-routing.js';

const MINUTE = 60000;
const HOUR = 60 * MINUTE;
const RAIL = new Set(['rail', 'replacementBus']);
const MAX_TRAINS = 20;
const MAX_STATIONS = 8;
const MAX_STAFF = 8;
const timeOf = value => typeof value === 'number' ? value : Date.parse(value);
const iso = value => new Date(value).toISOString();
const identity = leg => leg.scheduledServiceId ?? leg.serviceId;
const unique = values => [...new Set(values)];
const boardings = leg => leg.kind === 'vehicle' ? 1 : leg.mode === 'tubeTransfer' && leg.localJourney?.status === 'available'
    ? tubeBoardings(leg.localJourney.steps) : ['interchange', 'walk'].includes(leg.mode) ? 0 : 1;
const disruptionRank = journey => Math.max(0, ...(journey.legs ?? []).map(leg => leg.disruptionRank
    ?? (leg.localJourney?.disruption?.status === 'majorIssues' ? 2 : leg.localJourney?.disruption?.status === 'unknown' ? 1 : 0)));
let defaultProvider;

function mergeSnapshots(primary, recovered) {
    const known = new Set(primary.services.map(update => update.serviceId));
    const added = recovered.services.filter(update => !known.has(update.serviceId));
    if (!added.length) return primary;
    return { ...primary, services: [...primary.services, ...added],
        observedAt: Math.min(primary.services.length ? primary.observedAt : Infinity, recovered.observedAt),
        expiresAt: Math.min(primary.services.length ? primary.expiresAt : Infinity, recovered.expiresAt),
        diagnostics: [...(primary.diagnostics ?? []), ...(recovered.diagnostics ?? [])] };
}

function relevantLegs(candidates, now) {
    const wanted = new Map();
    const ranked = selectRouteBoardJourneys(candidates.filter(journey => timeOf(journey.departure) >= now), candidates.length);
    const add = leg => {
        if (!leg || leg.kind !== 'vehicle' || !RAIL.has(leg.mode)) return;
        const departure = timeOf(leg.scheduledDeparture ?? leg.departure);
        if (departure < now - 2 * HOUR || departure > now + 4 * HOUR) return;
        const key = `${identity(leg)}:${leg.from.crs}`;
        if (!wanted.has(key)) wanted.set(key, { serviceId: identity(leg), station: leg.from.crs, departure });
    };
    // Give every visible option a boarding observation before spending the
    // bounded detail budget on its connections or later candidates.
    for (const journey of ranked.slice(0, 5)) add(journey.legs.find(leg => leg.kind === 'vehicle' && RAIL.has(leg.mode)));
    for (const journey of ranked) for (const leg of journey.legs) add(leg);
    return [...wanted.values()];
}

async function transfers(leg, index, before, after, request, now, resolveTubeConnection) {
    const query = { from: leg.from.crs, to: leg.to.crs,
        originIsEndpoint: !before, destinationIsEndpoint: !after,
        arrival: before ? timeOf(before.arrival) : now,
        departure: after ? timeOf(after.departure) : undefined,
        arrivingOperator: before?.operator, departingOperator: after?.operator,
        direction: before || !after ? 'earliest' : 'latest', extraConnectionMinutes: request.extraConnectionMinutes ?? 0,
        allowedModes: [leg.mode] };
    const values = leg.mode === 'tubeTransfer' && resolveTubeConnection
        ? await resolveTubeConnection(index, query) : [resolveConnection(index, query)];
    return values.filter(value => value?.mode === leg.mode).map(value => ({ ...leg,
        localJourney: value.localJourney, disruptionRank: value.disruptionRank,
        genericTransfer: !value.localJourney && !['walk', 'interchange'].includes(leg.mode),
        warnings: value.localJourney ? value.localJourney.warnings ?? [] : leg.warnings,
        departure: iso(value.start), arrival: iso(value.end), durationMinutes: value.minutes,
        minutes: value.minutes, ruleId: value.ruleId, sourceRef: value.sourceRef, policy: value.policy,
        breakdown: value.breakdown, movementDeparture: Number.isFinite(value.movementStart) ? iso(value.movementStart) : null,
        movementArrival: Number.isFinite(value.movementEnd) ? iso(value.movementEnd) : null }));
}

async function warningsFor(journey, connections, request, now, resolveTubeConnection) {
    const warnings = [...(journey.warnings ?? [])];
    for (const [index, leg] of journey.legs.entries()) {
        if (leg.kind === 'vehicle') {
            if (leg.live?.cancelled) warnings.push('This journey includes a cancelled train.');
            else if (leg.live?.status === 'unknown') warnings.push('Live times are not confirmed for every part of this journey.');
            continue;
        }
        const before = journey.legs[index - 1], after = journey.legs[index + 1];
        if (!before || !after) continue;
        const arrival = timeOf(before.live ? before.live.arrival : before.arrival);
        const departure = timeOf(after.live ? after.live.departure : after.departure);
        if (Number.isFinite(arrival) && Number.isFinite(departure)
            && !(await transfers(leg, connections, { ...before, arrival: iso(arrival) },
                { ...after, departure: iso(departure) }, request, now, resolveTubeConnection)).length) {
            warnings.push('Live times no longer allow this connection.');
        }
    }
    return unique(warnings);
}

async function refreshCandidate(original, annotated, network, services, connections, request, now, check, tracking, resolveTubeConnection) {
    const legs = [];
    for (const leg of annotated.legs) {
        check();
        if (leg.kind !== 'vehicle') { legs.push(leg); continue; }
        const variants = services.get(identity(leg)) ?? [];
        const service = variants.find(value => value.calls.some((call, index) => (call.plannerLiveIndex ?? index) === leg.boardIndex)
            && value.calls.some((call, index) => (call.plannerLiveIndex ?? index) === leg.alightIndex));
        if (!service) return { reason: leg.live?.cancelled ? 'cancelled' : 'unknown' };
        const boardIndex = service.calls.findIndex((call, index) => (call.plannerLiveIndex ?? index) === leg.boardIndex);
        const alightIndex = service.calls.findIndex((call, index) => (call.plannerLiveIndex ?? index) === leg.alightIndex);
        const board = service.calls[boardIndex], alight = service.calls[alightIndex];
        if (!board?.canBoard || !alight?.canAlight || !Number.isFinite(board.departure) || !Number.isFinite(alight.arrival)) {
            return { reason: leg.live?.cancelled ? 'cancelled' : 'unknown' };
        }
        legs.push({ ...leg, serviceId: service.id, boardIndex, alightIndex,
            departure: iso(board.departure), arrival: iso(alight.arrival),
            durationMinutes: (alight.arrival - board.departure) / MINUTE, platform: board.platform ?? null,
            ...liveLeg(service, boardIndex, alightIndex),
            tracking: RAIL.has(leg.mode) && board.departure >= now && board.departure <= now + 4 * HOUR
                ? tracking.get(`${identity(leg)}:${leg.from.crs}`) : undefined,
            callingPoints: service.calls.slice(boardIndex, alightIndex + 1).map(call => ({
                station: { crs: call.station, name: network.stations.get(call.station)?.name ?? call.station }, sequence: call.sequence,
                arrival: Number.isFinite(call.arrival) ? iso(call.arrival) : null,
                departure: Number.isFinite(call.departure) ? iso(call.departure) : null,
                canBoard: call.canBoard, canAlight: call.canAlight, platform: call.platform ?? null, ...liveCall(service, call)
            })) });
    }
    const refresh = async (index, count) => {
        check();
        const remaining = legs.slice(index).reduce((sum, leg) => sum + (leg.mode === 'tubeTransfer' ? 0 : boardings(leg)), 0);
        if (count + remaining > (request.maxChanges ?? 5) + 1) return null;
        if (index === legs.length) {
            const journey = { ...original, legs: [...legs], departure: legs[0]?.departure, arrival: legs.at(-1)?.arrival,
                changes: Math.max(0, count - 1),
                durationMinutes: (timeOf(legs.at(-1)?.arrival) - timeOf(legs[0]?.departure)) / MINUTE };
            return validateJourney(journey, network, request) ? journey : null;
        }
        if (legs[index].kind === 'vehicle') return refresh(index + 1, count + 1);
        const template = legs[index];
        const choices = await transfers(template, connections, legs[index - 1], legs[index + 1], request, now, resolveTubeConnection);
        for (const choice of choices) {
            legs[index] = choice;
            const journey = await refresh(index + 1, count + boardings(choice));
            if (journey) return journey;
        }
        legs[index] = template;
        return null;
    };
    if (legs[0]?.kind === 'vehicle' && timeOf(legs[0].departure) < now) return { reason: 'departed' };
    const journey = await refresh(0, 0);
    if (journey && timeOf(journey.departure) < now) return { reason: 'departed' };
    return journey ? { journey } : { reason: 'connection' };
}

export function selectRouteBoardJourneys(journeys, limit = 5) {
    // Separate scheduled windows can retime the same fixed-link journey to
    // "now". Deduplicate after retiming, before those copies consume the page.
    const uniqueJourneys = new Map();
    for (const journey of journeys) {
        const key = journey.legs ? JSON.stringify([journey.departure, journey.arrival, journey.changes,
            journey.legs.map(leg => [leg.kind, leg.mode, leg.serviceId, leg.boardIndex, leg.alightIndex,
                leg.from.crs, leg.to.crs, leg.departure, leg.arrival, leg.ruleId, leg.movementDeparture, leg.movementArrival])]) : journey;
        const existing = uniqueJourneys.get(key);
        if (!existing || disruptionRank(journey) < disruptionRank(existing)) uniqueJourneys.set(key, journey);
    }
    // A direct train wins a small arrival difference. Connecting alternatives
    // saving at least ten minutes remain ahead of that direct train.
    const score = journey => timeOf(journey.arrival) + (journey.changes > 0 ? 10 * MINUTE : 0);
    return [...uniqueJourneys.values()].sort((a, b) => {
        return disruptionRank(a) - disruptionRank(b) || score(a) - score(b) || timeOf(a.arrival) - timeOf(b.arrival)
            || a.changes - b.changes || timeOf(a.departure) - timeOf(b.departure);
    }).slice(0, limit);
}

/** Refresh an immutable scheduled profile without running the national router.
 * Identity matching uses the full cached network, including competing services;
 * only cached candidate services are copied for retiming and validation. The
 * caller owns profile lifetime, response caching and deduplicated full replans.
 */
export async function refreshRouteBoard({ profile, network, time, limit = 5, realtime = 'apply',
    check: callerCheck = () => {}, abortSignal, budget, awaitIO = work => work(), resolveTubeConnection }, { provider, now = Date.now, createBudget } = {}) {
    const check = () => {
        callerCheck();
        if (abortSignal?.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499);
    };
    check();
    if (!['apply', 'ignore'].includes(realtime)) throw new PlannerError('INVALID_REQUEST', 'Invalid live mode.');
    const current = time ? timeOf(time) : now();
    if (!Number.isFinite(current)) throw new PlannerError('INVALID_REQUEST', 'Invalid board time.');
    const request = { ...profile.request, time: iso(current), timeType: 'departAfter', realtime };
    const candidates = profile.candidates ?? [];
    const candidateIds = new Set(candidates.flatMap(journey => journey.legs.filter(leg => leg.kind === 'vehicle').map(identity)));
    const compact = { ...network, services: network.services.filter(service => candidateIds.has(service.id)) };
    // Do not inherit an overlay/index pointing at a different service list.
    delete compact.baseNetwork;
    const targets = relevantLegs(candidates, current);
    const selected = targets.slice(0, MAX_TRAINS);
    const stations = unique([request.origin, ...selected.map(target => target.station)]).slice(0, MAX_STATIONS);
    let snapshot = { services: [], diagnostics: [], observedAt: now(), expiresAt: now() + 90000 };
    const errors = [], visited = [], pending = new Set(targets.slice(MAX_TRAINS).map(target => target.serviceId));
    let limited = targets.length > MAX_TRAINS;
    let matches = [];
    const tracking = new Map();
    const recentRail = candidates.some(journey => timeOf(journey.departure) >= current - 2 * HOUR
        && timeOf(journey.departure) <= current && journey.legs.some(leg => leg.kind === 'vehicle' && RAIL.has(leg.mode)));
    if (targets.length || recentRail) {
        if (!provider) {
            const tools = await import('./live-provider.js');
            defaultProvider ??= new tools.PlannerLiveProvider();
            provider = defaultProvider;
            createBudget ??= tools.createLiveRequestBudget;
        }
        budget ??= createBudget ? createBudget(64) : { limit: 64, used: 0 };
        const boards = await awaitIO(() => provider.fetchBoards(stations, { signal: abortSignal, budget }));
        check();
        visited.push(...stations);
        errors.push(...(boards.errors ?? []));
        limited ||= Boolean(boards.limited);
        matches = discoverLiveMatches(network, boards.boards, { now: now(), check });
        const wanted = new Map(selected.filter(target => stations.includes(target.station))
            .map((target, index) => [`${target.serviceId}:${target.station}`, index]));
        for (const target of selected) if (!stations.includes(target.station)) { pending.add(target.serviceId); limited = true; }
        const corridor = new Set([request.destination, ...(request.via ?? []), ...candidates.flatMap(journey =>
            journey.legs.filter(leg => leg.kind === 'vehicle' && leg.from.crs === request.origin).map(leg => leg.to.crs))]);
        const byId = new Map(network.services.map(service => [service.id, service]));
        const possibleNew = match => match.station === request.origin && !match.service.atd && !match.service.isCancelled
            && match.candidates.some(candidate => (!candidateIds.has(candidate.scheduledServiceId) || candidate.scheduledDeparture < current)
                && expectedDepartureTime(match.service, candidate.scheduledDeparture) >= current
                && byId.get(candidate.scheduledServiceId)?.calls.slice(candidate.index + 1).some(call => corridor.has(call.station)));
        const priority = match => Math.min(...match.candidates.map(candidate => wanted.get(`${candidate.scheduledServiceId}:${match.station}`) ?? Infinity));
        const wantedMatches = matches.filter(match => Number.isFinite(priority(match))).sort((a, b) => priority(a) - priority(b));
        const extraMatches = matches.filter(match => !wantedMatches.includes(match) && possibleNew(match));
        const selectedMatches = [...wantedMatches, ...extraMatches].slice(0, MAX_TRAINS);
        for (const match of wantedMatches.slice(MAX_TRAINS)) match.candidates.forEach(candidate => pending.add(candidate.scheduledServiceId));
        limited ||= wantedMatches.length + extraMatches.length > MAX_TRAINS;
        const references = selectedMatches.map(({ station, serviceID }) => ({ station, serviceID }));
        const details = await awaitIO(() => provider.fetchDetails(references, { signal: abortSignal, budget }));
        check();
        errors.push(...(details.errors ?? []));
        limited ||= Boolean(details.limited);
        for (const error of details.errors ?? []) if (error.reason === 'requestLimit') {
            selectedMatches.filter(match => match.station === error.station && match.serviceID === error.serviceID)
                .forEach(match => match.candidates.forEach(candidate => pending.add(candidate.scheduledServiceId)));
        }
        snapshot = matchLiveObservations(network, { boards: boards.boards, details: details.details }, { now: now(), check });
        // Verify each reference independently against ALL its original anchor
        // candidates. Merely finding an updated service in an ambiguous board
        // anchor is not proof that this particular provider ID matched it.
        for (const match of selectedMatches) {
            check();
            const detail = details.details.find(value => value.serviceID === match.serviceID && value.station === match.station);
            if (!detail) continue;
            const candidateServices = unique(match.candidates.map(candidate => candidate.scheduledServiceId)).map(id => byId.get(id));
            const verified = matchLiveObservations({ services: candidateServices, stations: new Map(), rules: { tsi: [], links: [] } },
                { boards: [{ ...match.board, services: [match.service] }], details: [detail] }, { now: now(), check });
            if (verified.services.length !== 1) continue;
            const service = byId.get(verified.services[0].serviceId);
            tracking.set(`${service.id}:${match.station}`, { providerServiceId: match.serviceID, station: match.station,
                uid: service.uid, originDate: service.originDate, verifiedAt: iso(verified.observedAt) });
        }
        if (provider.supportsStaffRecovery?.() && provider.fetchStaffBoards) {
            const failed = new Set((details.errors ?? []).filter(error => ['upstream', 'unavailable'].includes(error.reason))
                .map(error => `${error.station}:${error.serviceID}`));
            const publicIds = new Set(snapshot.services.map(update => update.serviceId));
            const staffTargets = new Map();
            for (const match of selectedMatches) if (failed.has(`${match.station}:${match.serviceID}`)) {
                for (const candidate of match.candidates) if (!publicIds.has(candidate.scheduledServiceId)) {
                    const key = `${match.station}:${candidate.scheduledDeparture}`;
                    const value = staffTargets.get(key) ?? { station: match.station, departure: candidate.scheduledDeparture, ids: [] };
                    value.ids.push(candidate.scheduledServiceId); staffTargets.set(key, value);
                }
            }
            const chosen = [...staffTargets.values()].slice(0, MAX_STAFF);
            for (const target of [...staffTargets.values()].slice(MAX_STAFF)) target.ids.forEach(id => pending.add(id));
            limited ||= staffTargets.size > MAX_STAFF;
            if (chosen.length) {
                const staff = await awaitIO(() => provider.fetchStaffBoards(chosen.map(({ station, departure }) => ({ station, departure })), { signal: abortSignal, budget }));
                check(); errors.push(...(staff.errors ?? [])); limited ||= Boolean(staff.limited);
                if (staff.limited) chosen.forEach(target => target.ids.forEach(id => pending.add(id)));
                snapshot = mergeSnapshots(snapshot, matchStaffObservations(network, staff.boards,
                    { now: now(), check, serviceIds: unique(chosen.flatMap(target => target.ids)) }));
            }
        }
    }
    check();
    const stale = snapshot.services.length && snapshot.expiresAt <= now();
    if (stale) { snapshot = { ...snapshot, services: [] }; tracking.clear(); }
    const annotated = applyLiveSnapshot(compact, snapshot, { mode: 'ignore', check });
    const applied = realtime === 'ignore' ? annotated : applyLiveSnapshot(compact, snapshot, { mode: 'apply', check });
    const serviceIndex = new Map();
    for (const service of applied.services) {
        const key = service.scheduledServiceId ?? service.id;
        if (!serviceIndex.has(key)) serviceIndex.set(key, []);
        serviceIndex.get(key).push(service);
    }
    const connections = createConnectionIndex(applied);
    const journeys = [], disruptedJourneys = [], changes = [], invalidCandidates = [];
    for (const candidate of candidates) {
        check();
        const shown = annotateLiveJourney(candidate, annotated);
        const value = await refreshCandidate(candidate, shown, applied, serviceIndex, connections, request, current, check, tracking, resolveTubeConnection);
        check();
        if (value.journey) {
            const warnings = await warningsFor(value.journey, connections, request, current, resolveTubeConnection);
            journeys.push(warnings.length ? { ...value.journey, warnings } : value.journey);
        }
        else if (value.reason !== 'departed') {
            const warning = value.reason === 'cancelled' ? 'This journey includes a cancelled train.'
                : value.reason === 'unknown' ? 'Live times cannot confirm this journey.' : 'Live times no longer allow this connection.';
            disruptedJourneys.push({ ...shown, warnings: unique([...(shown.warnings ?? []), warning]) });
            invalidCandidates.push({ reason: value.reason, legs: candidate.legs.map(leg => [identity(leg), leg.from.crs, leg.to.crs, leg.boardIndex, leg.alightIndex]) });
        }
    }
    const originalServices = new Map(network.services.map(service => [service.id, service]));
    const ridden = new Map();
    for (const journey of candidates) for (const leg of journey.legs) if (leg.kind === 'vehicle') {
        const id = identity(leg);
        if (!ridden.has(id)) ridden.set(id, []);
        ridden.get(id).push([leg.boardIndex, leg.alightIndex]);
    }
    for (const update of snapshot.services) {
        check();
        const source = originalServices.get(update.serviceId);
        const ranges = ridden.get(update.serviceId);
        const relevant = (index, direction) => !ranges || ranges.some(([first, last]) => direction === 'arrival'
            ? index > first && index <= last : direction === 'departure' ? index >= first && index < last : index >= first && index <= last);
        const calls = update.calls.filter(call => (call.cancelled && relevant(call.index))
            || (call.arrivalUnknown && relevant(call.index, 'arrival')) || (call.departureUnknown && relevant(call.index, 'departure'))
            || (relevant(call.index, 'arrival') && Number.isFinite(call.arrival) && call.arrival !== source?.calls[call.index]?.arrival)
            || (relevant(call.index, 'departure') && Number.isFinite(call.departure) && call.departure !== source?.calls[call.index]?.departure))
            .map(({ index, arrival, departure, cancelled, arrivalUnknown, departureUnknown }) =>
                ({ index, arrival, departure, cancelled, arrivalUnknown, departureUnknown }));
        const newOrigin = !candidateIds.has(update.serviceId) && matches.some(match => match.station === request.origin
            && match.candidates.some(candidate => candidate.scheduledServiceId === update.serviceId));
        const unknownCancellationFromIndex = update.unknownCancellationFromIndex != null
            && (!ranges || ranges.some(([, last]) => last > update.unknownCancellationFromIndex)) ? update.unknownCancellationFromIndex : undefined;
        const unknownDelayFromIndex = update.unknownDelayFromIndex != null
            && (!ranges || ranges.some(([, last]) => last > update.unknownDelayFromIndex)) ? update.unknownDelayFromIndex : undefined;
        if (calls.length || update.cancelled || unknownCancellationFromIndex != null || unknownDelayFromIndex != null || newOrigin) {
            changes.push({ serviceId: update.serviceId, calls, cancelled: update.cancelled,
                unknownCancellationFromIndex, unknownDelayFromIndex, newOrigin });
        }
    }
    changes.sort((a, b) => a.serviceId.localeCompare(b.serviceId));
    const live = { mode: realtime, status: snapshot.services.length ? 'partial' : 'unavailable', windowHours: 4,
        ...(snapshot.services.length ? { updatedAt: iso(snapshot.observedAt), expiresAt: iso(snapshot.expiresAt) } : {}),
        warnings: realtime === 'ignore' ? ['Delays and cancellations are shown, but these routes use scheduled times.'] : [] };
    if (stale) live.warnings.push('Live observations expired during this refresh; scheduled times are shown.');
    const page = presentLivePage(selectRouteBoardJourneys(journeys, limit), live, { now: current, visited, errors,
        diagnostics: snapshot.diagnostics ?? [], limited: limited || resolveTubeConnection?.state?.limited, pendingServiceIds: [...pending] });
    const tubeExpiry = Math.min(...page.journeys.flatMap(journey => journey.legs)
        .filter(leg => leg.localJourney?.status === 'available').map(leg => timeOf(leg.localJourney.expiresAt)).filter(Number.isFinite));
    if (Number.isFinite(tubeExpiry)) page.live.expiresAt = iso(Math.min(tubeExpiry, timeOf(page.live.expiresAt) || Infinity));
    const needsReplan = realtime === 'apply' && (changes.length > 0 || invalidCandidates.length > 0);
    return { ...page, disruptedJourneys: selectRouteBoardJourneys(disruptedJourneys, limit),
        warnings: [...(resolveTubeConnection?.state?.notes ?? [])],
        needsReplan, disruptionFingerprint: needsReplan
            ? createHash('sha256').update(JSON.stringify({ changes, invalidCandidates })).digest('hex') : null };
}
