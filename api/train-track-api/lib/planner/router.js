import { createConnectionIndex, resolveConnection, validateFixedLink, CONNECTION_POLICY } from './connections.js';
import { MAX_CHANGES, DEFAULT_WINDOW_MINUTES } from './contract.js';

const MINUTE = 60_000;
const indexes = new WeakMap();
export const ROUTING_POLICY_VERSION = 'scheduled-round-profile-v1';
export const DEFAULT_MODES = ['rail', 'replacementBus', 'walk', 'tubeTransfer'];

function add(map, key, item) {
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(item);
}

/** Index all service occurrences, not just the first train per stopping pattern:
 * trains sharing a pattern may overtake each other. Reused for a pinned network.
 */
export function prepareNetwork(network, check = () => {}) {
    if (indexes.has(network)) return indexes.get(network);
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
        callingPoints: service.calls.slice(raw.boardIndex, raw.alightIndex + 1)
            .filter(call => call.station && (call.canBoard || call.canAlight))
            .map(call => ({
                station: station(index, call.station), sequence: call.sequence,
                arrival: Number.isFinite(call.arrival) ? new Date(call.arrival).toISOString() : null,
                departure: Number.isFinite(call.departure) ? new Date(call.departure).toISOString() : null,
                canBoard: call.canBoard, canAlight: call.canAlight, platform: call.platform ?? null
            }))
    };
}

function transferLeg(index, raw) {
    return {
        kind: 'transfer', mode: raw.mode, from: station(index, raw.from), to: station(index, raw.to),
        departure: new Date(raw.start).toISOString(), arrival: new Date(raw.end).toISOString(),
        durationMinutes: raw.minutes, minutes: raw.minutes, breakdown: raw.breakdown,
        ruleId: raw.ruleId, sourceRef: raw.sourceRef, policy: raw.policy,
        genericTransfer: !['walk', 'interchange'].includes(raw.mode),
        warnings: ['walk', 'interchange'].includes(raw.mode) ? [] : ['This is a supplied generic transfer; detailed local departures and stops are not available.'],
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
                const valid = validateFixedLink(index.connections, {
                    from: leg.from.crs, to: leg.to.crs, start, end,
                    movementStart: Date.parse(leg.movementDeparture), movementEnd: Date.parse(leg.movementArrival),
                    ruleId: leg.ruleId, mode: leg.mode, breakdown: leg.breakdown
                }, request.extraConnectionMinutes ?? 0);
                if (!modes.has(leg.mode) || !valid || leg.minutes !== (end - start) / MINUTE) return false;
                boardings += leg.mode === 'walk' ? 0 : 1;
            } else if (!previousVehicle || i === journey.legs.length - 1 || leg.minutes !== (end - start) / MINUTE) return false;
            pendingTransfer = leg;
        } else return false;
        previousEnd = end;
        at = leg.to.crs;
    }
    if (at !== request.destination || !journey.legs.length) return false;
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
        : `${leg.ruleId}:${leg.start}:${leg.end}`).join('|');
}

// Optimistic boarding lower bounds ignore times and interchange allowances. They
// can only underestimate remaining work, so they safely rule out stations which
// cannot reach the destination within the requested number of changes.
function boardingBounds(index, target, reverse, allowedModes, maxBoardings, check) {
    const key = `${target}|${reverse}|${[...allowedModes].sort()}|${maxBoardings}`;
    if (index.potentials.has(key)) return index.potentials.get(key);
    const distances = new Map([[target, 0]]);
    const relaxLinks = () => {
        let changed = true;
        while (changed) {
            changed = false;
            for (const rules of index.connections.pairs.values()) for (const rule of rules) {
                if (!allowedModes.has(rule.mode)) continue;
                const from = reverse ? rule.destination : rule.origin;
                const to = reverse ? rule.origin : rule.destination;
                const cost = (distances.get(to) ?? Infinity) + (rule.mode === 'walk' ? 0 : 1);
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
function temporalBounds(index, target, reverse, allowedModes, maxBoardings, horizon, check) {
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
                if (link.mode === 'walk') continue;
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
                if (link.mode !== 'walk') continue;
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
export function findJourneys(request, network, options = {}) {
    const begun = Date.now();
    const reverse = request.timeType === 'arriveBy';
    const query = Date.parse(request.time);
    const window = (request.windowMinutes ?? DEFAULT_WINDOW_MINUTES) * MINUTE;
    const maxDuration = (options.maxDurationMinutes ?? 1440) * MINUTE;
    const maxChanges = request.maxChanges ?? MAX_CHANGES;
    const maxBoardings = maxChanges + 1;
    const limit = request.limit ?? 5;
    const allowedModes = new Set(request.allowedModes ?? DEFAULT_MODES);
    const from = reverse ? query - window : query;
    const to = reverse ? query : query + window;
    let operations = 0;
    const check = () => {
        if (options.signal?.aborted) throw failure('SEARCH_CANCELLED', 'Journey search was cancelled.');
        if (++operations > (options.maxOperations ?? 2_000_000) || Date.now() - begun > (options.timeoutMs ?? 10_000)) {
            throw failure('SEARCH_TIMEOUT', 'Journey search exceeded its work budget.');
        }
    };
    check();
    if (!Number.isFinite(query) || !Number.isFinite(window) || window <= 0 || !Number.isInteger(maxChanges) || maxChanges < 0 || maxChanges > MAX_CHANGES) throw failure('INVALID_REQUEST', 'Invalid journey search bounds.');
    const index = prepareNetwork(network, check);
    check();
    if (!index.connections.stations.has(request.origin) || !index.connections.stations.has(request.destination)) throw failure('INVALID_STATION', 'Unknown planner station.');
    const metadata = {
        searchTruncated: false, warnings: [], searchWindow: { from: new Date(from).toISOString(), to: new Date(to).toISOString(), fromInclusive: !reverse, toInclusive: reverse },
        pagination: { earlierTime: new Date(reverse ? from : from - window).toISOString(), laterTime: new Date(reverse ? to + window : to).toISOString() },
        policy: { version: ROUTING_POLICY_VERSION, connectionPolicy: CONNECTION_POLICY, maxChanges, maxDurationMinutes: maxDuration / MINUTE, windowMinutes: window / MINUTE, maxConsecutiveFixedLinks: 1 }
    };
    if (request.origin === request.destination) return { ...metadata, journeys: [], alreadyAtDestination: true, metrics: { operations, elapsedMs: Date.now() - begun } };
    const rounds = Array.from({ length: maxBoardings + 1 }, () => new Map());
    const target = reverse ? request.origin : request.destination;
    const remainingBoardings = boardingBounds(index, target, reverse, allowedModes, maxBoardings, check);
    const needsProfileBounds = (remainingBoardings.get(reverse ? request.destination : request.origin) ?? Infinity) > 2;
    const globalHorizon = reverse ? from - maxDuration : to + maxDuration;
    const timeBoundCache = new Map();
    const reachableTimes = horizon => {
        // Frequent local arrivals already give tight cheap finish bounds. Rebuilding
        // a national timetable envelope for each one costs more than it can prune.
        const boundary = needsProfileBounds && Number.isFinite(horizon) ? horizon : globalHorizon;
        if (timeBoundCache.has(boundary)) return timeBoundCache.get(boundary);
        if (timeBoundCache.size >= 8) {
            // Keep the initial global envelope and reuse an optimistic cached
            // horizon instead of repeatedly evicting and rebuilding national
            // indexes. A later deadline (earlier start in reverse) admits every
            // path admitted by the requested horizon, so pruning remains safe.
            let closest = globalHorizon;
            for (const cached of timeBoundCache.keys()) {
                if (reverse ? cached <= boundary && cached > closest : cached >= boundary && cached < closest) closest = cached;
            }
            return timeBoundCache.get(closest);
        }
        timeBoundCache.set(boundary, temporalBounds(index, target, reverse, allowedModes, maxBoardings, boundary, check));
        return timeBoundCache.get(boundary);
    };
    const results = [];
    const completed = [];
    const boarded = new Map();
    const finishBound = (boundary, boardings, at) => {
        if (boundary == null) return reverse ? -Infinity : Infinity;
        const minimumBoardings = boardings + (remainingBoardings.get(at) ?? Infinity);
        let bound = reverse ? -Infinity : Infinity;
        for (const known of completed) {
            if (known.boardings > minimumBoardings) continue;
            if (reverse ? known.boundary <= boundary : known.boundary >= boundary) {
                bound = reverse ? Math.max(bound, known.time) : Math.min(bound, known.time);
            }
        }
        return bound;
    };
    let labelCount = 0;
    const retain = label => {
        if (label.boardings > maxBoardings) return;
        if (label.boardings + (remainingBoardings.get(label.station) ?? Infinity) > maxBoardings) return;
        if (label.boundary != null && Math.abs(label.time - label.boundary) > maxDuration) return;
        const bound = finishBound(label.boundary, label.boardings, label.station);
        const reachableTime = reachableTimes(bound)[maxBoardings - label.boardings].get(label.station) ?? (reverse ? Infinity : -Infinity);
        if (reverse ? label.time < reachableTime : label.time > reachableTime) return;
        if (label.station !== target && label.boundary != null) {
            if (reverse ? label.time <= bound : label.time >= bound) return;
        }
        const bucket = `${label.station}|${label.operator ?? ''}`;
        const labels = rounds[label.boardings].get(bucket) ?? [];
        const dominates = (a, b) => reverse
            ? a.time >= b.time && a.boundary <= b.boundary
            : a.time <= b.time && a.boundary >= b.boundary;
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
        if (label.station === target) completed.push(label);
        if (++labelCount > (options.maxLabels ?? 200_000)) throw failure('SEARCH_TIMEOUT', 'Journey search exceeded its label budget.');
    };
    retain({ station: reverse ? request.destination : request.origin, time: query, boundary: null, operator: null, boardings: 0, path: [] });
    const connectionFor = (label, stop, mode, event, initial) => {
        const common = {
            from: reverse ? stop : label.station, to: reverse ? label.station : stop,
            extraConnectionMinutes: request.extraConnectionMinutes ?? 0,
            allowedModes: mode ? new Set([mode]) : allowedModes
        };
        if (reverse) {
            return resolveConnection(index.connections, {
                ...common, arrival: event?.time, departure: label.time,
                arrivingOperator: event?.service.operator, departingOperator: label.operator,
                direction: initial ? 'earliest' : 'latest'
            });
        }
        return resolveConnection(index.connections, {
            ...common, arrival: label.time, departure: event?.time,
            arrivingOperator: label.operator, departingOperator: event?.service.operator,
            direction: initial ? 'latest' : 'earliest'
        });
    };
    for (let round = 0; round <= maxBoardings; round++) {
        for (const labels of rounds[round].values()) for (const label of [...labels].sort((a, b) => reverse ? a.boundary - b.boundary : b.boundary - a.boundary)) {
            check();
            if (label.station === target && label.path.length) { results.push(label); continue; }
            const completionBound = finishBound(label.boundary, label.boardings, label.station);
            if (label.boundary != null && (reverse ? label.time <= completionBound : label.time >= completionBound)) continue;
            const timeBounds = reachableTimes(completionBound);
            const labelBound = timeBounds[maxBoardings - round].get(label.station) ?? (reverse ? Infinity : -Infinity);
            if (reverse ? label.time < labelBound : label.time > labelBound) continue;
            // Complete with one supplied endpoint link, including transfer-only searches.
            if (label.station !== target) {
                const endpointModes = new Set((index.connections.pairs.get(reverse ? `${target}|${label.station}` : `${label.station}|${target}`) ?? []).map(rule => rule.mode));
                for (const mode of endpointModes) {
                    if (!allowedModes.has(mode)) continue;
                    const transfer = connectionFor(label, target, mode, null, false);
                    if (!transfer || round + transfer.boardings > maxBoardings) continue;
                    const time = reverse ? transfer.start : transfer.end;
                    const boundary = label.boundary ?? (reverse ? transfer.end : transfer.start);
                    if (Math.abs(time - boundary) > maxDuration || boundary < from || boundary > to || (reverse ? boundary === from : boundary === to)) continue;
                    const leg = { kind: 'transfer', ...transfer };
                    const complete = { ...label, station: target, time, boundary, boardings: round + transfer.boardings, path: reverse ? [leg, ...label.path] : [...label.path, leg] };
                    results.push(complete);
                    completed.push(complete);
                }
            }
            if (round === maxBoardings) continue;
            const neighbours = reverse ? index.connections.incoming : index.connections.outgoing;
            const stops = [label.station, ...(neighbours.get(label.station) ?? [])];
            for (const stop of stops) {
                const cross = stop !== label.station;
                const linkModes = cross
                    ? [...new Set((index.connections.pairs.get(reverse ? `${stop}|${label.station}` : `${label.station}|${stop}`) ?? []).map(rule => rule.mode))].filter(mode => allowedModes.has(mode))
                    : [null];
                for (const mode of linkModes) {
                    const initial = label.path.length === 0;
                    const base = cross && !initial ? connectionFor(label, stop, mode, null, false) : null;
                    if (cross && !initial && !base) continue;
                    const ready = base ? (reverse ? base.start : base.end) : label.time;
                    const eventBoardings = maxBoardings - round - (cross && mode !== 'walk' ? 1 : 0);
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
                        if (!allowedModes.has(service.mode) || label.path.some(leg => leg.serviceId === service.id)) continue;
                        let transfer = null;
                        if (cross || !initial) {
                            transfer = base ?? connectionFor(label, stop, mode, event, initial);
                            if (!transfer || (reverse ? event.time > transfer.start : event.time < transfer.end)) continue;
                        }
                        const boardings = round + 1 + (transfer?.boardings ?? 0);
                        if (boardings > maxBoardings) continue;
                        const boundary = label.boundary ?? (transfer ? (reverse ? transfer.end : transfer.start) : event.time);
                        if (boundary < from || boundary > to || (reverse ? boundary === from : boundary === to)) continue;
                        // Once aboard the same occurrence, the incoming operator
                        // no longer matters. A better profile boarding no later
                        // on this train can already reach every onward call.
                        const boarding = { index: event.index, time: event.time, boundary, boardings };
                        const dominatesBoarding = (a, b) => a.boardings <= b.boardings && (reverse
                            ? a.index >= b.index && a.time >= b.time && a.boundary <= b.boundary
                            : a.index <= b.index && a.time <= b.time && a.boundary >= b.boundary);
                        const previous = boarded.get(service.id) ?? [];
                        if (previous.some(existing => dominatesBoarding(existing, boarding))) continue;
                        boarded.set(service.id, [...previous.filter(existing => !dominatesBoarding(boarding, existing)), boarding]);
                        for (const callIndex of reachableCalls(timeBounds, service, maxBoardings - boardings, reverse, check)) {
                            if (reverse ? callIndex >= event.index : callIndex <= event.index) continue;
                            check();
                            const call = service.calls[callIndex];
                            const time = reverse ? call.departure : call.arrival;
                            if (!call.station || !(reverse ? call.canBoard : call.canAlight) || !Number.isFinite(time)) continue;
                            if ((reverse ? time > event.time : time < event.time) || Math.abs(time - boundary) > maxDuration) continue;
                            const ride = { kind: 'vehicle', serviceId: service.id, boardIndex: reverse ? callIndex : event.index, alightIndex: reverse ? event.index : callIndex };
                            const legs = transfer ? [{ kind: 'transfer', ...transfer }] : [];
                            const path = reverse ? [ride, ...legs, ...label.path] : [...label.path, ...legs, ride];
                            retain({ station: call.station, time, boundary, operator: service.operator, boardings, path });
                        }
                    }
                }
            }
        }
    }
    const unique = new Map();
    for (const label of results) {
        const departure = reverse ? label.time : label.boundary;
        const arrival = reverse ? label.boundary : label.time;
        if (arrival - departure > maxDuration) continue;
        const key = signature(label.path);
        if (unique.has(key)) continue;
        unique.set(key, { departure, arrival, changes: Math.max(0, label.boardings - 1), path: label.path });
    }
    const candidates = [...unique.values()];
    const useful = candidates.filter(candidate => !candidates.some(other => {
        check();
        return other !== candidate && other.departure >= candidate.departure && other.arrival <= candidate.arrival && other.changes <= candidate.changes
            && (other.departure > candidate.departure || other.arrival < candidate.arrival || other.changes < candidate.changes);
    }));
    useful.sort((a, b) => reverse
        ? b.departure - a.departure || a.changes - b.changes || a.arrival - b.arrival || signature(a.path).localeCompare(signature(b.path))
        : a.arrival - b.arrival || a.changes - b.changes || b.departure - a.departure || signature(a.path).localeCompare(signature(b.path)));
    const offset = options.offset ?? 0;
    if (!Number.isInteger(offset) || offset < 0) throw failure('INVALID_REQUEST', 'Invalid journey page offset.');
    const journeys = [];
    for (const candidate of useful.slice(offset, offset + limit)) {
        check();
        const journey = {
            departure: new Date(candidate.departure).toISOString(), arrival: new Date(candidate.arrival).toISOString(),
            durationMinutes: (candidate.arrival - candidate.departure) / MINUTE, changes: candidate.changes,
            status: 'scheduledOnly', legs: candidate.path.map(raw => raw.kind === 'vehicle' ? vehicleLeg(index, raw) : transferLeg(index, raw))
        };
        if (!validateJourney(journey, network, request)) throw failure('INVALID_ITINERARY', 'An itinerary failed independent feasibility validation.');
        journeys.push(journey);
    }
    // Within a window page by rank, not by the final train's clock time: a
    // faster connection can rank before an earlier, slower direct alternative.
    metadata.pagination.offset = offset;
    metadata.pagination.nextOffset = offset + limit < useful.length ? offset + limit : null;
    metadata.pagination.previousOffset = offset > 0 ? Math.max(0, offset - limit) : null;
    metadata.pagination.total = useful.length;
    if (journeys.some(journey => journey.legs.some(leg => leg.kind === 'transfer' && leg.mode !== 'interchange'))) {
        metadata.warnings.push('Fixed links use supplied generic durations and require the entire transfer to fit the active window.');
    }
    if (index.connections.ambiguousLinks.size) metadata.warnings.push('Overlapping fixed links with conflicting equal priorities were excluded.');
    return { ...metadata, journeys, metrics: { operations, labels: labelCount, elapsedMs: Date.now() - begun } };
}
