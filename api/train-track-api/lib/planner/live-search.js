import { createHash, randomUUID } from 'node:crypto';
import { LIVE_WINDOW_HOURS, PlannerError } from './contract.js';
import { applyLiveSnapshot, discoverLiveMatches, matchLiveObservations, annotateLiveJourney, expectedDepartureTime } from './live-network.js';
import { presentLivePage } from './live-coverage.js';
import { matchStaffObservations } from './live-staff-matching.js';

const HOUR = 3600000;
const FRONTIER_LIMIT = 1001;
const MAX_STATIONS = 8;
const MAX_ROUNDS = 3;
const MAX_REQUESTS = 64;
const MAX_STAFF_QUERIES = 8;
const SCHEDULED_CONTEXT_TTL_MS = 90000;

const instant = value => typeof value === 'number' ? value : Date.parse(value);
const rawKey = (request, version) => `${version}:${JSON.stringify(request)}`;
const identity = leg => leg.scheduledServiceId ?? leg.serviceId;

function eligible(request, journeys, now) {
    const end = now + LIVE_WINDOW_HOURS * HOUR;
    if (request.timeType === 'departAfter') {
        return Date.parse(request.time) <= end && Date.parse(request.time) + request.windowMinutes * 60000 >= now;
    }
    // A delayed train may be absent from the scheduled frontier. For an arrival
    // within the live window, inspect origin boards even if no scheduled option
    // still starts in the future.
    return (Date.parse(request.time) >= now && Date.parse(request.time) <= end)
        || journeys.some(journey => instant(journey.departure) >= now && instant(journey.departure) <= end);
}

function boardingStations(request, journeys, now) {
    const stations = new Set([request.origin]);
    for (const journey of journeys) for (const leg of journey.legs) {
        const departure = instant(leg.scheduledDeparture ?? leg.departure);
        if (leg.kind === 'vehicle' && departure >= now - 2 * HOUR && departure <= now + LIVE_WINDOW_HOURS * HOUR) {
            stations.add(leg.from.crs);
        }
    }
    return [...stations];
}

function detailCandidates(matches, request, journeys, now, detailed) {
    const priorities = new Map();
    for (const [position, journey] of journeys.entries()) for (const leg of journey.legs) {
        const departure = instant(leg.live?.departure ?? leg.scheduledDeparture ?? leg.departure);
        if (leg.kind !== 'vehicle' || departure < now - 2 * HOUR || departure > now + LIVE_WINDOW_HOURS * HOUR) continue;
        const key = `${identity(leg)}:${leg.from.crs}`;
        if (!priorities.has(key)) priorities.set(key, position);
    }
    return matches.flatMap(match => {
        if (detailed.has(`${match.station}:${match.serviceID}`)) return [];
        const priority = Math.min(...match.candidates.map(candidate =>
            priorities.get(`${candidate.scheduledServiceId}:${match.station}`) ?? Infinity));
        // Unfiltered origin boards can expose a delayed train that the scheduled
        // frontier could not catch. Other unrelated station services do not
        // need details; a newly useful alternative is checked on the next pass.
        const estimate = String(match.service.etd ?? '').trim().toLowerCase();
        const delayedAtOrigin = match.station === request.origin && !match.service.atd
            && !match.service.isCancelled && (estimate === 'delayed' || (!['', 'on time', 'cancelled'].includes(estimate)
                && match.candidates.some(candidate => expectedDepartureTime(match.service, candidate.scheduledDeparture) >= now)));
        return Number.isFinite(priority) || delayedAtOrigin ? [{ ...match, priority: delayedAtOrigin ? -1 : priority }] : [];
    }).sort((left, right) => left.priority - right.priority);
}


function staffQueryKey(station, departure) {
    return `${station}:${Math.floor(departure / 60000)}`;
}

function mergeStaffSnapshot(primary, recovered) {
    const publicIds = new Set(primary.services.map(service => service.serviceId));
    const added = recovered.services.filter(service => !publicIds.has(service.serviceId));
    if (!added.length) return primary;
    const services = [...primary.services, ...added].sort((left, right) => left.serviceId.localeCompare(right.serviceId));
    return { ...primary, services, matchedCount: services.length,
        id: createHash('sha256').update(JSON.stringify(services)).digest('hex'),
        observedAt: Math.min(primary.services.length ? primary.observedAt : Infinity, recovered.observedAt),
        expiresAt: Math.min(primary.services.length ? primary.expiresAt : Infinity, recovered.expiresAt),
        warnings: [...new Set([...(primary.warnings ?? []), ...(recovered.warnings ?? [])])],
        diagnostics: [...(primary.diagnostics ?? []), ...(recovered.diagnostics ?? [])] };
}

function disruption(journey, request) {
    const warnings = [];
    let previous;
    let allowance = 0;
    for (const leg of journey.legs) {
        if (leg.kind !== 'vehicle') {
            const parts = leg.transfer ?? leg.breakdown ?? {};
            allowance += ['exitMinutes', 'travelMinutes', 'entryMinutes', 'extraMinutes', 'interchangeMinutes']
                .reduce((sum, field) => sum + (parts[field] ?? 0), 0);
            continue;
        }
        if (leg.live?.cancelled) warnings.push(`The service from ${leg.from.name} to ${leg.to.name} is cancelled on this part of the journey.`);
        if (leg.live?.status === 'unknown') warnings.push(`Live times for the service from ${leg.from.name} cannot be confirmed.`);
        const departure = instant(leg.live ? leg.live.departure : leg.departure);
        if (Number.isFinite(previous) && Number.isFinite(departure) && previous + allowance * 60000 > departure) {
            warnings.push(`The live times do not allow enough time to connect at ${leg.from.name}.`);
        }
        previous = instant(leg.live ? leg.live.arrival : leg.arrival);
        allowance = 0;
    }
    const last = journey.legs.at(-1);
    const arrival = last?.kind === 'vehicle' ? previous
        : Number.isFinite(previous) ? previous + allowance * 60000 : instant(last?.arrival);
    if (request.timeType === 'arriveBy' && Number.isFinite(arrival) && arrival > Date.parse(request.time)) {
        warnings.push('The expected arrival is later than your requested arrival time.');
    }
    return warnings;
}

/** A bounded set of station observations augments the whole routing network.
 * Discovery uses the complete scheduled frontier and unfiltered origin boards,
 * then repeats after rerouting. It is deliberately reported as partial live
 * coverage: public departure boards are not a national real-time timetable feed.
 */
export class LivePlanner {
    constructor({ now = Date.now, provider, createBudget } = {}) {
        this.now = now;
        this.provider = provider;
        this.createBudget = createBudget;
        this.snapshots = new Map();
    }

    async source() {
        if (!this.provider) {
            const { PlannerLiveProvider, createLiveRequestBudget } = await import('./live-provider.js');
            this.provider = new PlannerLiveProvider();
            this.createBudget = createLiveRequestBudget;
        }
        return this.provider;
    }

    async search({ request, network, version, offset = 0, liveSnapshotId, route, check, abortSignal }) {
        const startedAt = this.now();
        const key = rawKey(request, version);
        for (const [id, value] of this.snapshots) if (value.expiresAt <= startedAt) this.snapshots.delete(id);
        let retained;
        if (liveSnapshotId) {
            retained = this.snapshots.get(liveSnapshotId);
            if (!retained || retained.key !== key) {
                throw new PlannerError('CURSOR_EXPIRED', 'The live times for this search have expired. Please search again.', 410);
            }
        }
        const completeRoute = async current => {
            check();
            return route({ ...request, limit: FRONTIER_LIMIT }, current, { offset: 0 });
        };
        let scheduled;
        let snapshot = retained?.snapshot;
        let all;
        if (retained) {
            scheduled = retained.scheduled;
            all = retained.result;
        } else {
            scheduled = await completeRoute(network);
            check();
            if (!eligible(request, scheduled.journeys, startedAt)) {
                // More must keep the original frontier even if this request
                // enters the live window before the next page is opened. This
                // expiry belongs to the retained search, not a live observation.
                const snapshot = { id: randomUUID(), expiresAt: this.now() + SCHEDULED_CONTEXT_TTL_MS };
                const live = { mode: request.realtime, status: 'outsideWindow',
                    windowHours: LIVE_WINDOW_HOURS, warnings: ['Live updates apply to journeys starting within the next four hours.'] };
                this.snapshots.set(snapshot.id, { key, snapshot, scheduled, result: scheduled, live, expiresAt: snapshot.expiresAt });
                while (this.snapshots.size > 8) this.snapshots.delete(this.snapshots.keys().next().value);
                return this.page(scheduled, request, offset, live, snapshot.id);
            }
            const provider = await this.source();
            const budget = this.createBudget ? this.createBudget(MAX_REQUESTS) : { limit: MAX_REQUESTS, used: 0 };
            const observations = { boards: [], details: [] };
            const visited = new Set();
            const detailed = new Set();
            const staffBoards = [];
            const staffTargets = new Map();
            const staffQueried = new Set();
            const staffPending = new Set();
            const errors = [];
            let matches = [];
            all = scheduled;
            let limited = false;
            for (let round = 0; round < MAX_ROUNDS; round++) {
                check();
                const wanted = boardingStations(request, [...scheduled.journeys, ...all.journeys], startedAt)
                    .filter(station => !visited.has(station));
                const stations = wanted.slice(0, MAX_STATIONS - visited.size);
                if (wanted.length > stations.length) limited = true;
                stations.forEach(station => visited.add(station));
                if (stations.length) {
                    const boards = await provider.fetchBoards(stations, { signal: abortSignal, budget });
                    check();
                    observations.boards.push(...boards.boards);
                    errors.push(...(boards.errors ?? []));
                    limited ||= Boolean(boards.limited);
                }
                matches = discoverLiveMatches(network, observations.boards, { now: this.now(), check });
                const candidates = detailCandidates(matches, request, [...all.journeys, ...scheduled.journeys], this.now(), detailed);
                // Reserve room for discovering alternatives after cancellation.
                const maximum = round === 0 ? 24 : MAX_REQUESTS;
                const requested = candidates.slice(0, maximum).map(({ serviceID, station }) => ({ serviceID, station }));
                if (!stations.length && !requested.length) break;
                requested.forEach(value => detailed.add(`${value.station}:${value.serviceID}`));
                const details = await provider.fetchDetails(requested, { signal: abortSignal, budget });
                check();
                observations.details.push(...details.details);
                errors.push(...(details.errors ?? []));
                limited ||= Boolean(details.limited || candidates.length > requested.length);
                const previousSnapshot = snapshot?.id;
                snapshot = matchLiveObservations(network, observations, { now: this.now(), check });
                if (provider.supportsStaffRecovery?.() && typeof provider.fetchStaffBoards === 'function') {
                    const publicIds = new Set(snapshot.services.map(service => service.serviceId));
                    const failed = new Set((details.errors ?? [])
                        .filter(error => ['upstream', 'unavailable'].includes(error.reason))
                        .map(error => `${error.station}:${error.serviceID}`));
                    for (const match of candidates.slice(0, maximum)) {
                        if (!failed.has(`${match.station}:${match.serviceID}`)) continue;
                        for (const candidate of match.candidates) {
                            if (publicIds.has(candidate.scheduledServiceId) || !Number.isFinite(candidate.scheduledDeparture)) continue;
                            const key = staffQueryKey(match.station, candidate.scheduledDeparture);
                            const target = staffTargets.get(key) ?? { station: match.station,
                                departure: candidate.scheduledDeparture, serviceIds: new Set() };
                            target.serviceIds.add(candidate.scheduledServiceId);
                            staffTargets.set(key, target);
                        }
                    }
                    const wanted = [...staffTargets.entries()].filter(([key, target]) => !staffQueried.has(key)
                        && [...target.serviceIds].some(id => !publicIds.has(id)));
                    const selected = wanted.slice(0, MAX_STAFF_QUERIES - staffQueried.size);
                    if (wanted.length > selected.length) {
                        limited = true;
                        wanted.slice(selected.length).forEach(([, target]) => target.serviceIds.forEach(id => staffPending.add(id)));
                    }
                    if (selected.length) {
                        selected.forEach(([key]) => staffQueried.add(key));
                        const staff = await provider.fetchStaffBoards(selected.map(([, { station, departure }]) => ({ station, departure })),
                            { signal: abortSignal, budget });
                        check();
                        staffBoards.push(...staff.boards);
                        errors.push(...(staff.errors ?? []));
                        if (staff.limited) {
                            limited = true;
                            selected.forEach(([, target]) => target.serviceIds.forEach(id => staffPending.add(id)));
                        }
                    }
                    const serviceIds = [...new Set([...staffTargets.values()].flatMap(target => [...target.serviceIds]))]
                        .filter(id => !publicIds.has(id));
                    snapshot = mergeStaffSnapshot(snapshot, matchStaffObservations(network, staffBoards,
                        { serviceIds, now: this.now(), check }));
                }
                if (snapshot.services.length && snapshot.id !== previousSnapshot) {
                    const changed = applyLiveSnapshot(network, snapshot, { mode: request.realtime, check });
                    all = await completeRoute(changed);
                } else if (!snapshot.services.length) all = scheduled;
                check();
            }
            snapshot ??= { observedAt: startedAt, expiresAt: this.now() + 30000, services: [], warnings: [], matchedCount: 0 };
            const unavailable = !snapshot.services.length;
            const warnings = request.realtime === 'ignore'
                ? ['Delays and cancellations are shown, but these routes use scheduled times.'] : [];
            const deferred = new Set(errors.filter(error => error.reason === 'requestLimit')
                .map(error => `${error.station}:${error.serviceID}`));
            const pending = [...detailCandidates(matches, request, [...all.journeys, ...scheduled.journeys], this.now(), detailed),
                ...matches.filter(match => deferred.has(`${match.station}:${match.serviceID}`))];
            limited ||= pending.length > 0;
            const coverageContext = { now: startedAt, diagnostics: snapshot.diagnostics ?? [], errors,
                visited: [...visited], limited, pendingServiceIds: [...new Set([...pending
                    .flatMap(match => match.candidates.map(candidate => candidate.scheduledServiceId)), ...staffPending])]
                    .filter(id => !snapshot.services.some(service => service.serviceId === id)) };
            snapshot = { ...snapshot, id: randomUUID() };
            const annotated = applyLiveSnapshot(network, snapshot, { mode: 'ignore', check });
            const disrupted = scheduled.journeys.map(journey => annotateLiveJourney(journey, annotated))
                .map(journey => ({ journey, warnings: disruption(journey, request) }))
                .filter(value => value.warnings.length)
                .slice(0, 5).map(({ journey, warnings: reasons }) => ({ ...journey,
                    warnings: [...new Set([...(journey.warnings ?? []), ...reasons])] }));
            all = { ...all, disruptedJourneys: request.realtime === 'apply' ? disrupted : [],
                journeys: all.journeys.filter(journey => request.realtime !== 'apply' || instant(journey.departure) >= this.now()).map(journey => {
                    const reasons = disruption(journey, request);
                    return reasons.length ? { ...journey, warnings: [...new Set([...(journey.warnings ?? []), ...reasons])] } : journey;
                }) };
            const live = { mode: request.realtime, status: unavailable ? 'unavailable' : 'partial',
                updatedAt: new Date(snapshot.observedAt).toISOString(), expiresAt: new Date(snapshot.expiresAt).toISOString(),
                windowHours: LIVE_WINDOW_HOURS, warnings: [...new Set(warnings)] };
            if (snapshot.expiresAt <= this.now()) live.warnings.push('The live observations aged while this search was running. Search again to refresh them.');
            retained = { key, snapshot, scheduled, result: all, live, coverageContext, expiresAt: snapshot.expiresAt };
            this.snapshots.set(snapshot.id, retained);
            while (this.snapshots.size > 8) this.snapshots.delete(this.snapshots.keys().next().value);
        }
        return this.page(all, request, offset, retained.live, snapshot.id, retained.coverageContext);
    }

    page(result, request, offset, live, liveSnapshotId, coverageContext) {
        const count = result.journeys.length;
        const selected = result.journeys.slice(offset, offset + request.limit);
        const expired = liveSnapshotId && Date.parse(live.expiresAt) <= this.now();
        let journeys = selected.filter(journey => request.realtime !== 'apply' || instant(journey.departure) >= this.now());
        if (coverageContext) ({ journeys, live } = presentLivePage(journeys, live, coverageContext));
        return { ...result, journeys, live, liveSnapshotId,
            warnings: [...(result.warnings ?? []), ...(journeys.length < selected.length
                ? ['Some departures have passed while you were viewing these results. Search again for current options.'] : [])],
            searchTruncated: result.searchTruncated || count >= FRONTIER_LIMIT,
            pagination: { ...result.pagination, nextOffset: !expired && offset + request.limit < count ? offset + request.limit : null,
                previousOffset: offset > 0 ? Math.max(0, offset - request.limit) : null } };
    }
}
