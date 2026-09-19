import { createConnectionIndex, resolveConnection, validateFixedLink, CONNECTION_POLICY } from './connections.js';
import { MAX_CHANGES, DEFAULT_WINDOW_MINUTES, MODES } from './contract.js';
import { liveCall, liveLeg } from './live-network.js';
import { validateTubeConnection, tubeBoardings } from './tube-routing.js';
import { ROUTING_PROFILE_FIELDS } from './telemetry.js';

const MINUTE = 60_000;
const indexes = new WeakMap();
export const ROUTING_POLICY_VERSION = 'scheduled-round-profile-tfl-priority-v3';
export const DEFAULT_MODES = MODES;

function routePhaseMetrics() {
    return Object.fromEntries(ROUTING_PROFILE_FIELDS.map(name => [name, 0]));
}

function addRoutePhaseMetrics(total, metrics) {
    for (const name of ROUTING_PROFILE_FIELDS) total[name] += metrics?.[name] ?? 0;
}

function add(map, key, item) {
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(item);
}

function unchangedTopology(service, baseline, check) {
    const original = baseline.services.get(service.id);
    if (!original || original.mode !== service.mode || original.calls.length !== service.calls.length) return false;
    // Timing/platform observations can reuse an unchanged passenger topology.
    // Removed, split or newly enabled stops/services get fresh bounds instead:
    // weaker baseline bounds could expand extra states or disable profile bounds.
    for (let position = 0; position < service.calls.length; position++) {
        if (position % 128 === 0) check();
        const call = service.calls[position], before = original.calls[position];
        if (call.station !== before.station || Boolean(call.canBoard) !== Boolean(before.canBoard)
            || Boolean(call.canAlight) !== Boolean(before.canAlight)) return false;
    }
    return true;
}

/** Index all service occurrences, not just the first train per stopping pattern:
 * trains sharing a pattern may overtake each other. Reused for a pinned network.
 */
export function prepareNetwork(network, check = () => {}) {
    if (indexes.has(network)) return indexes.get(network);
    if (network.baseNetwork && network.changedServiceIds instanceof Set) {
        const base = prepareNetwork(network.baseNetwork, check);
        const topologyIndex = base.topologyIndex ?? base;
        let baselineTopology = true;
        const changed = network.changedServiceIds;
        const services = new Map(base.services);
        const affected = new Set();
        for (const id of changed) {
            check();
            for (const call of services.get(id)?.calls || []) if (call.station) affected.add(call.station);
            services.delete(id);
        }
        const addedDepartures = new Map();
        const addedArrivals = new Map();
        for (const service of network.services) {
            check();
            if (!changed.has(service.id) && !changed.has(service.scheduledServiceId)) continue;
            if (baselineTopology && !unchangedTopology(service, topologyIndex, check)) baselineTopology = false;
            services.set(service.id, service);
            service.calls.forEach((call, index) => {
                if (index % 128 === 0) check();
                if (!call.station) return;
                affected.add(call.station);
                if (call.canBoard && Number.isFinite(call.departure)) add(addedDepartures, call.station, { service, index, time: call.departure });
                if (call.canAlight && Number.isFinite(call.arrival)) add(addedArrivals, call.station, { service, index, time: call.arrival });
            });
        }
        const copyEvents = (original, additions) => {
            const copied = new Map(original);
            for (const station of affected) {
                check();
                const values = (original.get(station) || []).filter(event => !changed.has(event.service.id));
                values.push(...(additions.get(station) || []));
                values.sort((a, b) => a.time - b.time || String(a.service.id).localeCompare(String(b.service.id)) || a.index - b.index);
                copied.set(station, values);
            }
            return copied;
        };
        if (services.size !== topologyIndex.services.size) baselineTopology = false;
        if (baselineTopology) for (const id of changed) {
            if (!services.has(id)) { baselineTopology = false; break; }
        }
        // Every miss also calculates against the unchanged immutable topology.
        const prepared = { connections: base.connections, services, potentials: new Map(),
            ...(baselineTopology ? { topologyIndex } : {}),
            departures: copyEvents(base.departures, addedDepartures), arrivals: copyEvents(base.arrivals, addedArrivals) };
        indexes.set(network, prepared);
        return prepared;
    }
    const connections = createConnectionIndex(network);
    const departures = new Map();
    const arrivals = new Map();
    const services = new Map();
    for (const service of network.services) {
        check();
        services.set(service.id, service);
        for (let index = 0; index < service.calls.length; index++) {
            if (index % 256 === 0) check();
            const call = service.calls[index];
            if (!call.station) continue;
            if (call.canBoard && Number.isFinite(call.departure)) add(departures, call.station, { service, index, time: call.departure });
            if (call.canAlight && Number.isFinite(call.arrival)) add(arrivals, call.station, { service, index, time: call.arrival });
        }
    }
    for (const map of [departures, arrivals]) {
        for (const values of map.values()) {
            check();
            values.sort((a, b) => a.time - b.time || String(a.service.id).localeCompare(String(b.service.id)) || a.index - b.index);
        }
    }
    const prepared = { connections, departures, arrivals, services, potentials: new Map() };
    indexes.set(network, prepared);
    return prepared;
}

/** Drop the derived per-index caches (boarding potentials, temporal bounds)
 * under memory pressure. The index itself and its results are unaffected. */
export function releaseIndexCaches(network) {
    const index = indexes.get(network);
    if (!index) return;
    index.potentials.clear();
    index.topologyIndex?.potentials.clear();
    index.temporal?.clear();
}

function lowerBound(items, time) {
    let low = 0;
    let high = items.length;
    while (low < high) {
        const middle = (low + high) >>> 1;
        if (items[middle].time < time) low = middle + 1;
        else high = middle;
    }
    return low;
}

function failure(code, message) {
    const error = new Error(message);
    error.code = code;
    return error;
}

function station(index, crs) {
    return { crs, name: index.connections.stations.get(crs)?.name ?? crs };
}

function vehicleLeg(index, raw) {
    const service = index.services.get(raw.serviceId);
    const from = service.calls[raw.boardIndex];
    const to = service.calls[raw.alightIndex];
    return {
        kind: 'vehicle', mode: service.mode, serviceId: service.id,
        variantId: service.variantId, uid: service.uid, source: service.source,
        originDate: service.originDate, operator: service.operator,
        from: station(index, from.station), to: station(index, to.station),
        departure: new Date(from.departure).toISOString(), arrival: new Date(to.arrival).toISOString(),
        durationMinutes: (to.arrival - from.departure) / MINUTE,
        platform: from.platform ?? null,
        boardIndex: raw.boardIndex, alightIndex: raw.alightIndex,
        sourceRef: service.sourceRef,
        ...liveLeg(service, raw.boardIndex, raw.alightIndex),
        callingPoints: service.calls.slice(raw.boardIndex, raw.alightIndex + 1)
            .filter(call => call.station && (call.canBoard || call.canAlight || call.plannerLive))
            .map(call => ({
                station: station(index, call.station), sequence: call.sequence,
                arrival: Number.isFinite(call.arrival) ? new Date(call.arrival).toISOString() : null,
                departure: Number.isFinite(call.departure) ? new Date(call.departure).toISOString() : null,
                canBoard: call.canBoard, canAlight: call.canAlight, platform: call.platform ?? null,
                ...liveCall(service, call)
            }))
    };
}

function transferLeg(index, raw) {
    return {
        kind: 'transfer', mode: raw.mode, from: station(index, raw.from), to: station(index, raw.to),
        departure: new Date(raw.start).toISOString(), arrival: new Date(raw.end).toISOString(),
        durationMinutes: raw.minutes, minutes: raw.minutes, breakdown: raw.breakdown,
        ruleId: raw.ruleId, sourceRef: raw.sourceRef, policy: raw.policy,
        genericTransfer: !raw.localJourney && !['walk', 'interchange'].includes(raw.mode),
        ...(raw.localJourney ? { localJourney: raw.localJourney } : {}),
        warnings: raw.localJourney ? raw.localJourney.warnings ?? []
            : ['walk', 'interchange'].includes(raw.mode) ? [] : ['This is a supplied generic transfer; detailed local departures and stops are not available.'],
        movementDeparture: raw.movementStart == null ? null : new Date(raw.movementStart).toISOString(),
        movementArrival: raw.movementEnd == null ? null : new Date(raw.movementEnd).toISOString()
    };
}

/** Recheck the reconstructed legs against source occurrences and connection
 * rules. This deliberately does not trust search labels or their parent times.
 */
export function validateJourney(journey, network, request) {
    const index = prepareNetwork(network);
    let at = request.origin;
    let previousEnd = -Infinity;
    let previousVehicle = null;
    let pendingTransfer = null;
    let boardings = 0;
    const used = new Set();
    const modes = new Set(request.allowedModes ?? DEFAULT_MODES);
    const via = request.via ?? [];
    let viaProgress = 0, previousStation;
    const visit = station => {
        if (station !== previousStation && station === via[viaProgress]) viaProgress++;
        previousStation = station;
    };
    visit(request.origin);
    for (let i = 0; i < journey.legs.length; i++) {
        const leg = journey.legs[i];
        const start = Date.parse(leg.departure);
        const end = Date.parse(leg.arrival);
        if (leg.from.crs !== at || !(end >= start) || start < previousEnd) return false;
        if (leg.durationMinutes !== (end - start) / MINUTE) return false;
        if (leg.kind === 'vehicle') {
            const service = index.services.get(leg.serviceId);
            const board = service?.calls[leg.boardIndex];
            const alight = service?.calls[leg.alightIndex];
            if (!service || !modes.has(service.mode) || used.has(service.id) || !(leg.boardIndex < leg.alightIndex)) return false;
            if (leg.mode !== service.mode || leg.operator !== service.operator) return false;
            if (!board?.canBoard || !alight?.canAlight || board.station !== leg.from.crs || alight.station !== leg.to.crs) return false;
            if (board.departure !== start || alight.arrival !== end) return false;
            if (via.length) for (const call of service.calls.slice(leg.boardIndex, leg.alightIndex + 1)) {
                if (call.canBoard || call.canAlight) visit(call.station);
            }
            if (previousVehicle && !pendingTransfer) return false;
            if (pendingTransfer?.mode === 'interchange') {
                const connection = resolveConnection(index.connections, {
                    from: leg.from.crs, to: leg.from.crs, arrival: Date.parse(previousVehicle.arrival), departure: start,
                    arrivingOperator: previousVehicle.operator, departingOperator: service.operator,
                    extraConnectionMinutes: request.extraConnectionMinutes ?? 0
                });
                if (!connection || connection.ruleId !== pendingTransfer.ruleId || connection.minutes !== pendingTransfer.minutes) return false;
            }
            boardings++;
            used.add(service.id);
            previousVehicle = leg;
            pendingTransfer = null;
        } else if (leg.kind === 'transfer') {
            if (pendingTransfer) return false; // The prototype permits one supplied link between rides.
            if (leg.mode !== 'interchange') {
                const valid = (leg.localJourney ? validateTubeConnection : validateFixedLink)(index.connections, {
                    from: leg.from.crs, to: leg.to.crs, start, end,
                    movementStart: Date.parse(leg.movementDeparture), movementEnd: Date.parse(leg.movementArrival),
                    ruleId: leg.ruleId, mode: leg.mode, breakdown: leg.breakdown, localJourney: leg.localJourney
                }, request.extraConnectionMinutes ?? 0, {
                    originIsEndpoint: i === 0, destinationIsEndpoint: i === journey.legs.length - 1
                });
                if (!modes.has(leg.mode) || !valid || leg.minutes !== (end - start) / MINUTE) return false;
                boardings += leg.localJourney?.status === 'available' ? tubeBoardings(leg.localJourney.steps) : leg.mode === 'walk' ? 0 : 1;
            } else if (!previousVehicle || i === journey.legs.length - 1 || leg.minutes !== (end - start) / MINUTE) return false;
            pendingTransfer = leg;
            visit(leg.to.crs);
        } else return false;
        previousEnd = end;
        at = leg.to.crs;
    }
    if (at !== request.destination || !journey.legs.length || viaProgress !== via.length) return false;
    const start = Date.parse(journey.departure);
    const end = Date.parse(journey.arrival);
    if (start !== Date.parse(journey.legs[0].departure) || end !== previousEnd) return false;
    if (journey.durationMinutes !== (end - start) / MINUTE) return false;
    if (journey.changes !== Math.max(0, boardings - 1) || journey.changes > (request.maxChanges ?? MAX_CHANGES)) return false;
    const time = Date.parse(request.time);
    return request.timeType === 'arriveBy' ? end <= time : start >= time;
}

function signature(path) {
    return path.map(leg => leg.kind === 'vehicle'
        ? `${leg.serviceId}:${leg.boardIndex}:${leg.alightIndex}`
        : `${leg.ruleId}:${leg.start}:${leg.end}:${leg.localJourney?.id ?? ''}:${leg.boardings ?? ''}`).join('|');
}

// Search labels share their preceding legs instead of copying an entire path
// at every onward stop. Only completed candidates need an ordered leg array.
function containsService(path, serviceId) {
    for (let node = path; node; node = node.previous) if (node.leg.serviceId === serviceId) return true;
    return false;
}

function pathLegs(path, reverse) {
    const legs = [];
    for (let node = path; node; node = node.previous) legs.push(node.leg);
    return reverse ? legs : legs.reverse();
}

// Input is already ranked. A bounded saved board must not fill its entire
// allowance with alternatives for early departures and lose later trains.
export function departureProfileOrder(candidates) {
    const groups = new Map();
    for (const candidate of candidates) {
        const values = groups.get(candidate.departure) ?? [];
        values.push(candidate);
        groups.set(candidate.departure, values);
    }
    const ordered = [...groups].sort(([a], [b]) => (typeof a === 'number' ? a : Date.parse(a))
        - (typeof b === 'number' ? b : Date.parse(b))).map(([, values]) => values);
    const result = [];
    for (let round = 0, more = true; more; round++) {
        more = false;
        for (const values of ordered) if (values[round]) { result.push(values[round]); more = true; }
    }
    return result;
}

// A live replan can discover a path absent from the scheduled frontier. Retain
// its source references for the next refresh, never its expiring predictions.
// Its scheduled connections may be infeasible: callers must retime and validate
// this structural candidate before presenting it as an available journey.
export function scheduledCandidate(journey, network) {
    const index = prepareNetwork(network);
    const legs = journey.legs.map(leg => {
        if (leg.kind !== 'vehicle') return { ...leg };
        const serviceId = leg.scheduledServiceId ?? leg.serviceId;
        const service = index.services.get(serviceId);
        if (!service) return null;
        const first = leg.callingPoints?.[0]?.sequence, last = leg.callingPoints?.at(-1)?.sequence;
        const boardIndex = first === undefined ? leg.boardIndex : service.calls.findIndex(call => call.sequence === first);
        const alightIndex = last === undefined ? leg.alightIndex : service.calls.findIndex(call => call.sequence === last);
        if (boardIndex < 0 || alightIndex <= boardIndex) return null;
        return vehicleLeg(index, { serviceId, boardIndex, alightIndex });
    });
    if (legs.some(leg => !leg)) return null;
    for (let position = 0; position < legs.length; position++) {
        const leg = legs[position];
        if (leg.kind !== 'transfer') continue;
        if (leg.localJourney) {
            const previous = legs[position - 1], next = legs[position + 1];
            const connection = resolveConnection(index.connections, {
                from: leg.from.crs, to: leg.to.crs, allowedModes: new Set([leg.mode]),
                extraConnectionMinutes: (leg.transfer ?? leg.breakdown)?.extraMinutes ?? 0,
                ...(previous || !next ? { arrival: Date.parse(previous?.arrival ?? leg.departure), direction: 'earliest' }
                    : { departure: Date.parse(next.departure), direction: 'latest' })
            });
            if (!connection) return null;
            // Stored templates retain the supplied link, not an expiring TfL
            // route or its contingency. Refresh resolves the connection again.
            legs[position] = transferLeg(index, connection);
            continue;
        }
        if (legs.length === 1) continue;
        const duration = leg.minutes * MINUTE;
        const start = legs[position - 1] ? Date.parse(legs[position - 1].arrival)
            : Date.parse(legs[position + 1]?.departure) - duration;
        if (!Number.isFinite(start) || !Number.isFinite(duration)) return null;
        leg.departure = new Date(start).toISOString();
        leg.arrival = new Date(start + duration).toISOString();
        delete leg.movementDeparture;
        delete leg.movementArrival;
    }
    return { departure: legs[0].departure, arrival: legs.at(-1).arrival,
        durationMinutes: (Date.parse(legs.at(-1).arrival) - Date.parse(legs[0].departure)) / MINUTE,
        changes: journey.changes, status: 'scheduledOnly', legs };
}

// Optimistic boarding lower bounds ignore times and interchange allowances. They
// can only underestimate remaining work, so they safely rule out stations which
// cannot reach the destination within the requested number of changes.
function boardingBounds(index, target, reverse, allowedModes, maxBoardings, check, tubeAware, metrics) {
    // Both cache hits and misses use baseline services. Computing a live-only
    // miss into the shared cache could wrongly prune a later scheduled search.
    index = index.topologyIndex ?? index;
    const key = `${target}|${reverse}|${[...allowedModes].sort()}|${maxBoardings}|${Boolean(tubeAware)}`;
    if (index.potentials.has(key)) {
        metrics.topologyBoundsCacheHits++;
        return index.potentials.get(key);
    }
    metrics.topologyBoundsBuilds++;
    const distances = new Map([[target, 0]]);
    const relaxLinks = () => {
        let changed = true;
        while (changed) {
            changed = false;
            for (const rules of index.connections.pairs.values()) for (const rule of rules) {
                if (!allowedModes.has(rule.mode)) continue;
                const from = reverse ? rule.destination : rule.origin;
                const to = reverse ? rule.origin : rule.destination;
                const cost = (distances.get(to) ?? Infinity) + (rule.mode === 'walk' || (tubeAware && rule.mode === 'tubeTransfer') ? 0 : 1);
                if (cost <= maxBoardings && cost < (distances.get(from) ?? Infinity)) {
                    distances.set(from, cost);
                    changed = true;
                }
            }
        }
    };
    for (let round = 0; round < maxBoardings; round++) {
        check();
        relaxLinks();
        let scanned = 0;
        for (const service of index.services.values()) {
            if (++scanned % 128 === 0) check();
            if (!allowedModes.has(service.mode)) continue;
            let best = Infinity;
            for (let i = reverse ? 0 : service.calls.length - 1; i >= 0 && i < service.calls.length; i += reverse ? 1 : -1) {
                const call = service.calls[i];
                if (!call.station) continue;
                if (reverse ? call.canAlight : call.canBoard) {
                    if (best + 1 <= maxBoardings && best + 1 < (distances.get(call.station) ?? Infinity)) distances.set(call.station, best + 1);
                }
                if (reverse ? call.canBoard : call.canAlight) best = Math.min(best, distances.get(call.station) ?? Infinity);
            }
        }
    }
    relaxLinks();
    index.potentials.set(key, distances);
    if (index.potentials.size > 32) index.potentials.delete(index.potentials.keys().next().value);
    return distances;
}

// Optimistic timetable reachability: for each remaining boarding budget, find
// the latest possible departure toward the destination (earliest arrival from
// the origin in reverse searches). Ignoring interchange allowances and treating
// fixed links as instantaneous can admit extra paths, but cannot exclude a
// feasible one. This avoids expanding trains after their final onward service.
function temporalBounds(index, target, reverse, allowedModes, maxBoardings, horizon, check, tubeAware) {
    const absent = reverse ? Infinity : -Infinity;
    const improves = (a, b) => reverse ? a < b : a > b;
    const bounds = [];
    const links = [...index.connections.pairs.values()].flat().filter(link => allowedModes.has(link.mode));
    for (let round = 0; round <= maxBoardings; round++) {
        check();
        const previous = bounds[round - 1];
        const current = previous ? new Map(previous) : new Map([[target, horizon]]);
        const retain = (station, time) => {
            if (!improves(time, current.get(station) ?? absent)) return false;
            current.set(station, time);
            return true;
        };
        if (round) {
            let scanned = 0;
            for (const service of index.services.values()) {
                if (++scanned % 128 === 0) check();
                if (!allowedModes.has(service.mode)) continue;
                let reachable = false;
                for (let i = reverse ? 0 : service.calls.length - 1; i >= 0 && i < service.calls.length; i += reverse ? 1 : -1) {
                    const call = service.calls[i];
                    if (!call.station) continue;
                    const event = reverse ? call.arrival : call.departure;
                    if (reachable && (reverse ? call.canAlight : call.canBoard) && Number.isFinite(event)) retain(call.station, event);
                    const connection = reverse ? call.departure : call.arrival;
                    const boundary = previous.get(call.station) ?? absent;
                    if ((reverse ? call.canBoard : call.canAlight) && Number.isFinite(connection)
                        && (reverse ? connection >= boundary : connection <= boundary)) reachable = true;
                }
            }
            for (const link of links) {
                if (link.mode === 'walk' || (tubeAware && link.mode === 'tubeTransfer')) continue;
                const from = reverse ? link.destination : link.origin;
                const to = reverse ? link.origin : link.destination;
                retain(from, previous.get(to) ?? absent);
            }
        }
        let changed = true;
        while (changed) {
            check();
            changed = false;
            for (const link of links) {
                if (link.mode !== 'walk' && !(tubeAware && link.mode === 'tubeTransfer')) continue;
                const from = reverse ? link.destination : link.origin;
                const to = reverse ? link.origin : link.destination;
                changed = retain(from, current.get(to) ?? absent) || changed;
            }
        }
        bounds.push(current);
    }
    return bounds;
}

function reachableCalls(bounds, service, remainingBoardings, reverse, check) {
    bounds.calls ??= Array.from({ length: bounds.length }, () => new WeakMap());
    const cache = bounds.calls[remainingBoardings];
    if (cache.has(service)) return cache.get(service);
    const times = bounds[remainingBoardings];
    const calls = [];
    for (let i = reverse ? service.calls.length - 1 : 0; i >= 0 && i < service.calls.length; i += reverse ? -1 : 1) {
        check();
        const call = service.calls[i];
        const time = reverse ? call.departure : call.arrival;
        const bound = times.get(call.station) ?? (reverse ? Infinity : -Infinity);
        if (call.station && (reverse ? call.canBoard : call.canAlight) && Number.isFinite(time)
            && (reverse ? time >= bound : time <= bound)) calls.push(i);
    }
    cache.set(service, calls);
    return calls;
}

// Several departure profiles revisit the same station and remaining boarding
// budget. Index the events which have at least one usable onward call once, so
// each profile does not repeatedly scan trains already proven unable to finish.
function reachableEvents(index, bounds, station, remainingBoardings, reverse, queryBoundary, check) {
    bounds.events ??= Array.from({ length: bounds.length }, () => new Map());
    const cache = bounds.events[remainingBoardings];
    if (cache.has(station)) return cache.get(station);
    const events = [];
    const source = (reverse ? index.arrivals : index.departures).get(station) ?? [];
    const timeBound = bounds[remainingBoardings + 1].get(station) ?? (reverse ? Infinity : -Infinity);
    const fromIndex = lowerBound(source, reverse ? timeBound : queryBoundary);
    const toIndex = lowerBound(source, (reverse ? queryBoundary : timeBound) + 1);
    for (let i = fromIndex; i < toIndex; i++) {
        check();
        const event = source[i];
        const calls = reachableCalls(bounds, event.service, remainingBoardings, reverse, check);
        const last = calls.at(-1);
        if (last !== undefined && (reverse ? last < event.index : last > event.index)) events.push(event);
    }
    cache.set(station, events);
    return events;
}

/** Round-based profile search. Each round adds a passenger vehicle boarding;
 * labels retain inbound (or outbound in reverse) operator and departure/arrival
 * profile, so an earlier train cannot erase useful later departure choices.
 */
function* journeySearch(request, network, options = {}) {
    const begun = Date.now();
    const reverse = request.timeType === 'arriveBy';
    const departureProfile = options.departureProfile === true;
    const via = reverse ? [...(request.via ?? [])].reverse() : request.via ?? [];
    const visit = (progress, station) => station === via[progress] ? progress + 1 : progress;
    const query = Date.parse(request.time);
    const window = (request.windowMinutes ?? DEFAULT_WINDOW_MINUTES) * MINUTE;
    const maxDuration = (options.maxDurationMinutes ?? 1440) * MINUTE;
    const maxChanges = request.maxChanges ?? MAX_CHANGES;
    const maxBoardings = maxChanges + 1;
    const limit = request.limit ?? 5;
    const allowedModes = new Set(request.allowedModes ?? DEFAULT_MODES);
    const from = reverse ? query - window : query;
    const to = reverse ? query : query + window;
    let operations = 0, labelCount = 0;
    const phases = routePhaseMetrics();
    phases.internalRoutePasses = 1;
    let expansionStarted = null, expansionSuspendedMs = 0, expansionTemporalMs = 0;
    const expansionElapsed = () => expansionStarted === null ? phases.labelExpansionMs
        : Math.max(0, performance.now() - expansionStarted - expansionSuspendedMs - (phases.temporalBoundsMs - expansionTemporalMs));
    const metrics = () => ({ ...phases, labelExpansionMs: expansionElapsed(), operations, labels: labelCount,
        elapsedMs: Date.now() - begun });
    const measurePhase = (name, work) => {
        const started = performance.now();
        try { return work(); }
        finally { phases[name] += performance.now() - started; }
    };
    const maxOperations = options.maxOperations ?? 2_000_000;
    const deadline = begun + (options.timeoutMs ?? 10_000);
    const checkpoint = () => {
        if (options.signal?.aborted) throw failure('SEARCH_CANCELLED', 'Journey search was cancelled.');
        if (Date.now() > deadline) throw failure('SEARCH_TIMEOUT', 'Journey search exceeded its work budget.');
    };
    const check = () => {
        // Count every operation, but avoid millions of clock/shared-flag reads.
        // Poll at entry/every 256 checkpoints and after native work or I/O;
        // the final poll prevents publishing cancelled or overdue results.
        if ((++operations & 255) === 1) checkpoint();
        if (operations > maxOperations) throw failure('SEARCH_TIMEOUT', 'Journey search exceeded its work budget.');
    };
    try {
    check();
    if (!Number.isFinite(query) || !Number.isFinite(window) || window <= 0 || !Number.isInteger(maxChanges) || maxChanges < 0 || maxChanges > MAX_CHANGES) throw failure('INVALID_REQUEST', 'Invalid journey search bounds.');
    const index = indexes.has(network) ? prepareNetwork(network, check)
        : measurePhase('indexBuildMs', () => prepareNetwork(network, check));
    checkpoint();
    check();
    if (!index.connections.stations.has(request.origin) || !index.connections.stations.has(request.destination)
        || via.some(station => !index.connections.stations.has(station))) throw failure('INVALID_STATION', 'Unknown planner station.');
    const metadata = {
        searchTruncated: false, warnings: [], searchWindow: { from: new Date(from).toISOString(), to: new Date(to).toISOString(), fromInclusive: !reverse, toInclusive: reverse },
        pagination: { earlierTime: new Date(reverse ? from : from - window).toISOString(), laterTime: new Date(reverse ? to + window : to).toISOString() },
        policy: { version: ROUTING_POLICY_VERSION, connectionPolicy: CONNECTION_POLICY, maxChanges, maxDurationMinutes: maxDuration / MINUTE, windowMinutes: window / MINUTE, maxConsecutiveFixedLinks: 1 }
    };
    if (request.origin === request.destination) return { ...metadata, journeys: [], alreadyAtDestination: true, metrics: metrics() };
    const rounds = Array.from({ length: maxBoardings + 1 }, () => new Map());
    const target = reverse ? request.origin : request.destination;
    const remainingBoardings = measurePhase('topologyBoundsMs', () =>
        boardingBounds(index, target, reverse, allowedModes, maxBoardings, check, options.resolveTubeConnection, phases));
    const needsProfileBounds = (remainingBoardings.get(reverse ? request.destination : request.origin) ?? Infinity) > 2;
    const globalHorizon = reverse ? from - maxDuration : to + maxDuration;
    // Temporal bounds depend only on the index, target, direction, modes and
    // boarding budget, so repeated searches (live re-routing, paging, nearby
    // times) share them across calls instead of rescanning the national index.
    index.temporal ??= new Map();
    const temporalKey = `${target}|${reverse}|${[...allowedModes].sort()}|${maxBoardings}|${Boolean(options.resolveTubeConnection)}`;
    const timeBoundCache = index.temporal.get(temporalKey) ?? new Map();
    const seenEnvelopes = new Set();
    const cachedEnvelope = bounds => {
        // Count distinct reused envelopes, not every label's cheap lookup.
        if (!seenEnvelopes.has(bounds)) {
            seenEnvelopes.add(bounds);
            phases.temporalBoundsCacheHits++;
        }
        return bounds;
    };
    const buildEnvelope = horizon => {
        phases.temporalBoundsBuilds++;
        const bounds = measurePhase('temporalBoundsMs', () =>
            temporalBounds(index, target, reverse, allowedModes, maxBoardings, horizon, check, options.resolveTubeConnection));
        seenEnvelopes.add(bounds);
        return bounds;
    };
    index.temporal.delete(temporalKey);
    index.temporal.set(temporalKey, timeBoundCache);
    if (index.temporal.size > 4) index.temporal.delete(index.temporal.keys().next().value);
    if (!timeBoundCache.has(globalHorizon)) {
        // The shared cache may already hold other searches' horizons; this
        // search's global envelope must exist before any fallback below.
        if (timeBoundCache.size >= 8) timeBoundCache.delete(timeBoundCache.keys().next().value);
        timeBoundCache.set(globalHorizon, buildEnvelope(globalHorizon));
    } else cachedEnvelope(timeBoundCache.get(globalHorizon));
    // Only the bounds themselves are shared. The eligible-event and call
    // caches hang off a per-search view so they are released with the search.
    const views = new Map();
    const view = bounds => {
        if (!views.has(bounds)) views.set(bounds, [...cachedEnvelope(bounds)]);
        return views.get(bounds);
    };
    const reachableTimes = horizon => {
        // Frequent local arrivals already give tight cheap finish bounds. Rebuilding
        // a national timetable envelope for each one costs more than it can prune.
        const boundary = needsProfileBounds && Number.isFinite(horizon) ? horizon : globalHorizon;
        if (timeBoundCache.has(boundary)) return view(timeBoundCache.get(boundary));
        if (timeBoundCache.size >= 8) {
            // Keep the initial global envelope and reuse an optimistic cached
            // horizon instead of repeatedly evicting and rebuilding national
            // indexes. A later deadline (earlier start in reverse) admits every
            // path admitted by the requested horizon, so pruning remains safe.
            let closest = globalHorizon;
            for (const cached of timeBoundCache.keys()) {
                if (reverse ? cached <= boundary && cached > closest : cached >= boundary && cached < closest) closest = cached;
            }
            return view(timeBoundCache.get(closest));
        }
        timeBoundCache.set(boundary, buildEnvelope(boundary));
        return view(timeBoundCache.get(boundary));
    };
    const results = [];
    const completed = [];
    const completedProfiles = new Map();
    const absentFinish = reverse ? -Infinity : Infinity;
    const rememberCompleted = ({ boundary, boardings, time, disruptionRank = 0 }) => {
        if (!departureProfile) { completed.push({ boundary, boardings, time, disruptionRank }); return; }
        const key = `${boundary}:${disruptionRank}`;
        let bounds = completedProfiles.get(key);
        if (!bounds) completedProfiles.set(key, bounds = Array(maxBoardings + 1).fill(absentFinish));
        // Each slot represents an allowance, not an exact boarding count. A
        // faster connecting train must never prune a slower direct option.
        for (let allowance = boardings; allowance <= maxBoardings; allowance++) {
            bounds[allowance] = reverse ? Math.max(bounds[allowance], time) : Math.min(bounds[allowance], time);
        }
    };
    const boarded = new Map();
    const finishBound = (boundary, boardings, at, disruptionRank = 0) => {
        if (boundary == null) return absentFinish;
        const minimumBoardings = boardings + (remainingBoardings.get(at) ?? Infinity);
        if (departureProfile) {
            let best = absentFinish;
            for (let rank = 0; rank <= disruptionRank; rank++) {
                const value = completedProfiles.get(`${boundary}:${rank}`)?.[Math.min(maxBoardings, minimumBoardings)] ?? absentFinish;
                best = reverse ? Math.max(best, value) : Math.min(best, value);
            }
            return best;
        }
        let bound = absentFinish;
        for (const known of completed) {
            if (known.boardings > minimumBoardings || known.disruptionRank > disruptionRank) continue;
            if (reverse ? known.boundary <= boundary : known.boundary >= boundary) {
                bound = reverse ? Math.max(bound, known.time) : Math.min(bound, known.time);
            }
        }
        return bound;
    };
    const retain = label => {
        // A saved-board fallback already checked direct departures. Do not let
        // a scheduled direct train dominate all connecting replacement routes.
        if (options.excludeDirect && label.station === target && label.path?.leg.kind === 'vehicle'
            && !label.path.previous) return;
        if (label.boardings > maxBoardings) return;
        if (label.boardings + (remainingBoardings.get(label.station) ?? Infinity) > maxBoardings) return;
        if (label.boundary != null && Math.abs(label.time - label.boundary) > maxDuration) return;
        const bound = finishBound(label.boundary, label.boardings, label.station, label.disruptionRank);
        const reachableTime = reachableTimes(bound)[maxBoardings - label.boardings].get(label.station) ?? (reverse ? Infinity : -Infinity);
        if (reverse ? label.time < reachableTime : label.time > reachableTime) return;
        if (label.station !== target && label.boundary != null) {
            if (reverse ? label.time <= bound : label.time >= bound) return;
        }
        const bucket = `${label.station}|${label.operator ?? ''}|${label.viaProgress}${departureProfile ? `|${label.boundary}` : ''}`;
        const labels = rounds[label.boardings].get(bucket) ?? [];
        const dominates = (a, b) => (a.disruptionRank ?? 0) <= (b.disruptionRank ?? 0) && (reverse
            ? a.time >= b.time && a.boundary <= b.boundary
            : a.time <= b.time && a.boundary >= b.boundary);
        // A path using fewer boardings with the same operator context and a
        // better time profile also dominates this label. Keeping it in every
        // later round creates large numbers of redundant national detours.
        for (let earlierRound = 0; earlierRound < label.boardings; earlierRound++) {
            if ((rounds[earlierRound].get(bucket) ?? []).some(existing => dominates(existing, label))) return;
        }
        if (labels.some(existing => dominates(existing, label))) return;
        rounds[label.boardings].set(bucket, [...labels.filter(existing => !dominates(label, existing)), label]);
        for (let laterRound = label.boardings + 1; laterRound <= maxBoardings; laterRound++) {
            const later = rounds[laterRound].get(bucket);
            if (later) rounds[laterRound].set(bucket, later.filter(existing => !dominates(label, existing)));
        }
        if (label.station === target && label.viaProgress === via.length) rememberCompleted(label);
        if (++labelCount > (options.maxLabels ?? 200_000)) throw Object.assign(
            failure('SEARCH_TIMEOUT', 'Journey search exceeded its label budget.'),
            { reason: 'labelLimit', metrics: { operations, labels: labelCount } });
    };
    expansionStarted = performance.now();
    expansionTemporalMs = phases.temporalBoundsMs;
    retain({ station: reverse ? request.destination : request.origin, time: query, boundary: null, operator: null, boardings: 0,
        viaProgress: visit(0, reverse ? request.destination : request.origin), path: null, disruptionRank: 0 });
    const connectionFor = function* (label, stop, mode, event, initial) {
        const common = {
            from: reverse ? stop : label.station, to: reverse ? label.station : stop,
            originIsEndpoint: reverse ? stop === target && !event : label.path === null,
            destinationIsEndpoint: reverse ? label.path === null : stop === target && !event,
            extraConnectionMinutes: request.extraConnectionMinutes ?? 0,
            allowedModes: mode ? new Set([mode]) : allowedModes
        };
        const query = reverse ? {
            ...common, arrival: event?.time, departure: label.time,
            arrivingOperator: event?.service.operator, departingOperator: label.operator,
            direction: initial ? 'earliest' : 'latest'
        } : {
            ...common, arrival: label.time, departure: event?.time,
            arrivingOperator: label.operator, departingOperator: event?.service.operator,
            direction: initial ? 'latest' : 'earliest'
        };
        if (mode === 'tubeTransfer' && options.resolveTubeConnection) {
            checkpoint();
            const suspended = performance.now();
            try {
                const connections = yield { index: index.connections, query };
                checkpoint();
                return connections;
            } finally {
                const elapsed = performance.now() - suspended;
                expansionSuspendedMs += elapsed;
                phases.transferResolutionMs += elapsed;
            }
        }
        const connection = resolveConnection(index.connections, query);
        return connection ? [connection] : [];
    };
    for (let round = 0; round <= maxBoardings; round++) {
        for (const labels of rounds[round].values()) for (const label of [...labels].sort((a, b) => reverse ? a.boundary - b.boundary : b.boundary - a.boundary)) {
            check();
            if (label.station === target && label.path && label.viaProgress === via.length) { results.push(label); continue; }
            const completionBound = finishBound(label.boundary, label.boardings, label.station, label.disruptionRank);
            if (label.boundary != null && (reverse ? label.time <= completionBound : label.time >= completionBound)) continue;
            const timeBounds = reachableTimes(completionBound);
            const labelBound = timeBounds[maxBoardings - round].get(label.station) ?? (reverse ? Infinity : -Infinity);
            if (reverse ? label.time < labelBound : label.time > labelBound) continue;
            // Complete with one supplied endpoint link, including transfer-only searches.
            if (label.station !== target) {
                const endpointModes = new Set((index.connections.pairs.get(reverse ? `${target}|${label.station}` : `${label.station}|${target}`) ?? []).map(rule => rule.mode));
                for (const mode of endpointModes) {
                    if (!allowedModes.has(mode)) continue;
                    for (const transfer of yield* connectionFor(label, target, mode, null, false)) {
                        if (!transfer || round + transfer.boardings > maxBoardings) continue;
                        const time = reverse ? transfer.start : transfer.end;
                        const boundary = label.boundary ?? (reverse ? transfer.end : transfer.start);
                        if (Math.abs(time - boundary) > maxDuration || boundary < from || boundary > to || (reverse ? boundary === from : boundary === to)) continue;
                        const leg = { kind: 'transfer', ...transfer };
                        const viaProgress = visit(label.viaProgress, target);
                        if (viaProgress !== via.length) continue;
                        const complete = { ...label, station: target, time, boundary, viaProgress, boardings: round + transfer.boardings, disruptionRank: Math.max(label.disruptionRank ?? 0, transfer.disruptionRank ?? 0), path: { previous: label.path, leg } };
                        results.push(complete);
                        rememberCompleted(complete);
                    }
                }
            }
            if (round === maxBoardings) continue;
            const neighbours = reverse ? index.connections.incoming : index.connections.outgoing;
            const stops = [label.station, ...(neighbours.get(label.station) ?? [])];
            const candidates = [];
            for (const stop of stops) {
                const cross = stop !== label.station;
                const linkModes = cross
                    ? [...new Set((index.connections.pairs.get(reverse ? `${stop}|${label.station}` : `${label.station}|${stop}`) ?? []).map(rule => rule.mode))].filter(mode => allowedModes.has(mode))
                    : [null];
                for (const mode of linkModes) {
                    const candidate = { stop, mode };
                    if (cross && mode === 'tubeTransfer' && options.resolveTubeConnection) {
                        // Check that a useful onward train exists before spending
                        // a TubeTrack lookup. A zero-minute, zero-boarding link is
                        // deliberately optimistic: TfL can be faster than the ALF
                        // allowance and can return a walking-only connection.
                        const allowance = maxBoardings - round;
                        const eventBound = timeBounds[allowance].get(stop) ?? (reverse ? Infinity : -Infinity);
                        const events = reachableEvents(index, timeBounds, stop, allowance - 1,
                            reverse, reverse ? to : from, check);
                        const first = reverse ? lowerBound(events, label.time + 1) - 1 : lowerBound(events, label.time);
                        for (let position = first; position >= 0 && position < events.length; position += reverse ? -1 : 1) {
                            check();
                            const event = events[position];
                            if (reverse ? event.time < eventBound : event.time > eventBound) break;
                            if (reverse ? event.time <= completionBound : event.time >= completionBound) break;
                            const outerBound = label.boundary ?? (reverse ? from : to);
                            if (Math.abs(event.time - outerBound) > maxDuration) break;
                            if (!allowedModes.has(event.service.mode) || containsService(label.path, event.service.id)) continue;
                            candidate.eventTime = event.time;
                            // Neighbouring London stations often share the same
                            // optimistic bound through zero-cost fixed links.
                            // Rank the actual onward train's reachable calls so
                            // those links cannot make every interchange tie.
                            candidate.remainingBoardings = Infinity;
                            for (const callIndex of reachableCalls(timeBounds, event.service, allowance - 1, reverse, check)) {
                                if (reverse ? callIndex >= event.index : callIndex <= event.index) continue;
                                candidate.remainingBoardings = Math.min(candidate.remainingBoardings,
                                    1 + (remainingBoardings.get(event.service.calls[callIndex].station) ?? Infinity));
                            }
                            break;
                        }
                        if (candidate.eventTime === undefined) continue;
                    }
                    candidates.push(candidate);
                }
            }
            // Reorder only the Tube candidates. Rail interchanges and supplied
            // walking links keep their existing traversal order and behaviour.
            const tubeCandidates = candidates.filter(candidate => candidate.eventTime !== undefined)
                .sort((a, b) => a.remainingBoardings - b.remainingBoardings
                    || (reverse ? b.eventTime - a.eventTime : a.eventTime - b.eventTime));
            let tubePosition = 0;
            for (const entry of candidates) {
                const { stop, mode } = entry.eventTime === undefined ? entry : tubeCandidates[tubePosition++];
                const cross = stop !== label.station;
                const initial = label.path === null;
                const bases = cross && !initial ? yield* connectionFor(label, stop, mode, null, false) : [null];
                for (const base of bases) {
                    const ready = base ? (reverse ? base.start : base.end) : label.time;
                    const eventBoardings = maxBoardings - round - (base?.boardings ?? (cross && mode !== 'walk' && !(mode === 'tubeTransfer' && options.resolveTubeConnection) ? 1 : 0));
                    if (eventBoardings < 1) continue;
                    const eventBound = timeBounds[eventBoardings].get(stop) ?? (reverse ? Infinity : -Infinity);
                    const events = reachableEvents(index, timeBounds, stop, eventBoardings - 1,
                        reverse, reverse ? to : from, check);
                    const startIndex = reverse ? lowerBound(events, ready + 1) - 1 : lowerBound(events, ready);
                    for (let eventIndex = startIndex; eventIndex >= 0 && eventIndex < events.length; eventIndex += reverse ? -1 : 1) {
                        check();
                        const event = events[eventIndex];
                        if (reverse ? event.time < eventBound : event.time > eventBound) break;
                        if (reverse ? event.time <= completionBound : event.time >= completionBound) break;
                        const outerBound = label.boundary ?? (reverse ? (cross ? from : to) : (cross ? to : from));
                        if (Math.abs(event.time - outerBound) > maxDuration) break;
                        if (initial && !cross && (reverse ? event.time <= from : event.time >= to)) break;
                        const service = event.service;
                        if (!allowedModes.has(service.mode) || containsService(label.path, service.id)) continue;
                        const transfers = cross || !initial
                            ? base ? [base] : yield* connectionFor(label, stop, mode, event, initial) : [null];
                        for (const transfer of transfers) {
                            if (transfer && (reverse ? event.time > transfer.start : event.time < transfer.end)) continue;
                            const boardings = round + 1 + (transfer?.boardings ?? 0);
                            if (boardings > maxBoardings) continue;
                            const boundary = label.boundary ?? (transfer ? (reverse ? transfer.end : transfer.start) : event.time);
                            if (boundary < from || boundary > to || (reverse ? boundary === from : boundary === to)) continue;
                            // Once aboard the same occurrence, the incoming operator
                            // no longer matters. A better profile boarding no later
                            // on this train can already reach every onward call.
                            const viaProgress = cross ? visit(label.viaProgress, stop) : label.viaProgress;
                            const disruptionRank = Math.max(label.disruptionRank ?? 0, transfer?.disruptionRank ?? 0);
                            const boarding = { index: event.index, time: event.time, boundary, boardings, disruptionRank };
                            const dominatesBoarding = (a, b) => a.disruptionRank <= b.disruptionRank && a.boardings <= b.boardings && (reverse
                                ? a.index >= b.index && a.time >= b.time && a.boundary <= b.boundary
                                : a.index <= b.index && a.time <= b.time && a.boundary >= b.boundary);
                            const boardingKey = `${service.id}|${viaProgress}${departureProfile ? `|${boundary}` : ''}`;
                            const previous = boarded.get(boardingKey) ?? [];
                            if (previous.some(existing => dominatesBoarding(existing, boarding))) continue;
                            boarded.set(boardingKey, [...previous.filter(existing => !dominatesBoarding(boarding, existing)), boarding]);
                            const progressAtCall = via.length ? new Map() : null;
                            if (via.length) {
                                let progress = viaProgress;
                                for (let position = event.index + (reverse ? -1 : 1); position >= 0 && position < service.calls.length; position += reverse ? -1 : 1) {
                                    check();
                                    const call = service.calls[position];
                                    if (call.canBoard || call.canAlight) progress = visit(progress, call.station);
                                    progressAtCall.set(position, progress);
                                }
                            }
                            const precedingPath = transfer ? { previous: label.path, leg: { kind: 'transfer', ...transfer } } : label.path;
                            for (const callIndex of reachableCalls(timeBounds, service, maxBoardings - boardings, reverse, check)) {
                                if (reverse ? callIndex >= event.index : callIndex <= event.index) continue;
                                check();
                                const call = service.calls[callIndex];
                                const time = reverse ? call.departure : call.arrival;
                                if (!call.station || !(reverse ? call.canBoard : call.canAlight) || !Number.isFinite(time)) continue;
                                if ((reverse ? time > event.time : time < event.time) || Math.abs(time - boundary) > maxDuration) continue;
                                const ride = { kind: 'vehicle', serviceId: service.id, boardIndex: reverse ? callIndex : event.index, alightIndex: reverse ? event.index : callIndex };
                                const path = { previous: precedingPath, leg: ride };
                                retain({ station: call.station, time, boundary, operator: service.operator, boardings, disruptionRank,
                                    viaProgress: progressAtCall?.get(callIndex) ?? viaProgress, path });
                            }
                        }
                    }
                }
            }
        }
    }
    phases.labelExpansionMs = expansionElapsed();
    expansionStarted = null;
    const journeys = [];
    const assemblyStarted = performance.now();
    try {
    const unique = new Map();
    for (const label of results) {
        const departure = reverse ? label.time : label.boundary;
        const arrival = reverse ? label.boundary : label.time;
        if (arrival - departure > maxDuration) continue;
        const path = pathLegs(label.path, reverse);
        const key = signature(path);
        if (unique.has(key)) continue;
        unique.set(key, { departure, arrival, changes: Math.max(0, label.boardings - 1), path, disruptionRank: label.disruptionRank ?? 0 });
    }
    const candidates = [...unique.values()];
    const useful = candidates.filter(candidate => !candidates.some(other => {
        check();
        if (departureProfile && (reverse ? other.arrival !== candidate.arrival : other.departure !== candidate.departure)) return false;
        return other !== candidate && other.disruptionRank <= candidate.disruptionRank && other.departure >= candidate.departure && other.arrival <= candidate.arrival && other.changes <= candidate.changes
            && (other.departure > candidate.departure || other.arrival < candidate.arrival || other.changes < candidate.changes || other.disruptionRank < candidate.disruptionRank);
    }));
    useful.sort((a, b) => a.disruptionRank - b.disruptionRank || (reverse
        ? b.departure - a.departure || a.changes - b.changes || a.arrival - b.arrival || signature(a.path).localeCompare(signature(b.path))
        : a.arrival - b.arrival || a.changes - b.changes || b.departure - a.departure || signature(a.path).localeCompare(signature(b.path))));
    const offset = options.offset ?? 0;
    if (!Number.isInteger(offset) || offset < 0) throw failure('INVALID_REQUEST', 'Invalid journey page offset.');
    const ranked = departureProfile && options.balanceDepartures ? departureProfileOrder(useful) : useful;
    for (const candidate of ranked.slice(offset, offset + limit)) {
        check();
        const journey = {
            departure: new Date(candidate.departure).toISOString(), arrival: new Date(candidate.arrival).toISOString(),
            durationMinutes: (candidate.arrival - candidate.departure) / MINUTE, changes: candidate.changes,
            status: 'scheduledOnly', legs: candidate.path.map(raw => raw.kind === 'vehicle' ? vehicleLeg(index, raw) : transferLeg(index, raw))
        };
        const disruptedEarlier = candidates.find(other => other.disruptionRank === 2 && candidate.disruptionRank < 2
            && (reverse ? other.departure > candidate.departure : other.arrival < candidate.arrival));
        if (disruptedEarlier && !journey.legs.some(leg => leg.localJourney?.notes?.some(note => note.includes('avoid reported disruption')))) {
            journey.warnings = ['This route avoids an earlier option with major TfL disruption. The journey times and connections reflect this alternative.'];
        }
        if (!validateJourney(journey, network, request)) throw failure('INVALID_ITINERARY', 'An itinerary failed independent feasibility validation.');
        journeys.push(journey);
    }
    // Within a window page by rank, not by the final train's clock time: a
    // faster connection can rank before an earlier, slower direct alternative.
    metadata.pagination.offset = offset;
    metadata.pagination.nextOffset = offset + limit < useful.length ? offset + limit : null;
    metadata.pagination.previousOffset = offset > 0 ? Math.max(0, offset - limit) : null;
    metadata.pagination.total = useful.length;
    if (departureProfile) metadata.pagination.departureTimes = new Set(useful.map(candidate => candidate.departure)).size;
    if (journeys.some(journey => journey.legs.some(leg => leg.kind === 'transfer' && leg.mode !== 'interchange' && !leg.localJourney))) {
        metadata.warnings.push('Fixed links use supplied generic durations and require the entire transfer to fit the active window.');
    }
    if (index.connections.ambiguousLinks.size) metadata.warnings.push('Overlapping fixed links with conflicting equal priorities were excluded.');
    checkpoint();
    } finally { phases.resultAssemblyMs += performance.now() - assemblyStarted; }
    return { ...metadata, journeys, metrics: metrics() };
    } catch (error) {
        error.metrics = metrics();
        throw error;
    }
}

// The synchronous API remains available to timetable-only callers. Only eligible
// TfL connections suspend graph work; ordinary rail/walk routing stays synchronous.
export function findJourneys(request, network, options = {}) {
    const search = journeySearch(request, network, options);
    const result = search.next();
    if (!result.done) search.throw(failure('INVALID_REQUEST', 'Use asynchronous routing for TfL connections.'));
    return result.value;
}

export async function findJourneysAsync(request, network, options = {}) {
    const begun = Date.now();
    const maxOperations = options.maxOperations ?? 2_000_000;
    const timeoutMs = options.timeoutMs ?? 10_000;
    let operations = 0, labels = 0;
    const phases = routePhaseMetrics();
    const checkpoint = () => {
        if (options.signal?.aborted || options.abortSignal?.aborted) throw failure('SEARCH_CANCELLED', 'Journey search was cancelled.');
        if (operations > maxOperations || Date.now() - begun > timeoutMs) throw failure('SEARCH_TIMEOUT', 'Journey search exceeded its work budget.');
    };
    options.resolveTubeConnection?.reserveForResults?.();
    // Verification spends reserved I/O capacity on complete candidate journeys.
    // Reroute against those observations so new durations, disruptions and
    // vehicle changes are validated throughout the route, not patched into a
    // journey that may no longer catch its onward train.
    // One further refinement can verify a newly preferred fallback after the
    // first observations change the frontier. All passes share the same limits.
    for (let pass = 0; pass < 3; pass++) {
        const remainingMs = timeoutMs - (Date.now() - begun);
        if (operations >= maxOperations || remainingMs <= 0) throw Object.assign(
            failure('SEARCH_TIMEOUT', 'Journey search exceeded its work budget.'),
            { metrics: { ...phases, operations, labels, elapsedMs: Date.now() - begun } });
        const search = journeySearch(request, network, { ...options,
            maxOperations: maxOperations - operations, timeoutMs: remainingMs });
        let result;
        try {
            let step = search.next();
            while (!step.done) {
                const { index, query } = step.value;
                let connections;
                try { connections = await options.resolveTubeConnection(index, query); }
                catch (error) { search.throw(error); }
                step = search.next(connections);
            }
            result = step.value;
        } catch (error) {
            addRoutePhaseMetrics(phases, error.metrics);
            error.metrics = { ...phases, operations: operations + (error.metrics?.operations ?? 0),
                labels: labels + (error.metrics?.labels ?? 0), elapsedMs: Date.now() - begun };
            throw error;
        }
        operations += result.metrics?.operations ?? 0;
        labels += result.metrics?.labels ?? 0;
        addRoutePhaseMetrics(phases, result.metrics);
        const selected = result.journeys.slice(0, Math.min(options.tubeVerificationLimit ?? request.limit ?? 5, 10));
        try {
            let changed = false;
            if (pass < 2 && options.resolveTubeConnection?.verifySelected) {
                const verificationStarted = performance.now();
                try { changed = await options.resolveTubeConnection.verifySelected(selected); }
                finally { phases.transferResolutionMs += performance.now() - verificationStarted; }
            }
            // Verification can exhaust a shared deadline or cancel even when
            // it returns false. Never publish or start another pass afterward.
            checkpoint();
            if (changed) continue;
        } catch (error) {
            error.metrics = { ...phases, operations, labels, elapsedMs: Date.now() - begun };
            throw error;
        }
        return { ...result, metrics: { ...result.metrics, ...phases, operations, labels, elapsedMs: Date.now() - begun } };
    }
}
