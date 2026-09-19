import { createConnectionIndex, resolveConnection, CONNECTION_POLICY } from './connections.js';
import { MAX_CHANGES, DEFAULT_WINDOW_MINUTES, MODES } from './contract.js';
import { liveCall, liveLeg } from './live-network.js';
import { validateJourney } from './router.js';

const MINUTE = 60_000;

function failure(code, message) {
    return Object.assign(new Error(message), { code });
}

function firstTime(service) {
    for (const call of service.calls) {
        if (Number.isFinite(call.departure)) return call.departure;
        if (Number.isFinite(call.arrival)) return call.arrival;
    }
    return Infinity;
}

// Stations alone are not a route: permissions, operator-sensitive interchange
// rules, mode and missing endpoint times must agree too. Repeated stops retain
// their occurrence position instead of being collapsed into a station set.
function patternKey(service) {
    return JSON.stringify([service.mode, service.operator, service.calls.map(call => [
        call.station ?? null, Boolean(call.canBoard), Boolean(call.canAlight),
        Number.isFinite(call.arrival), Number.isFinite(call.departure)
    ])]);
}

function follows(earlier, later, check) {
    for (let position = 0; position < earlier.calls.length; position++) {
        check();
        for (const field of ['arrival', 'departure']) {
            const before = earlier.calls[position][field], after = later.calls[position][field];
            if (Number.isFinite(before) && before > after) return false;
        }
    }
    return true;
}

function strictlyProgresses(service, check) {
    let previousTime = -Infinity, previousBoarding = -Infinity;
    for (const call of service.calls) {
        check();
        // Check before adding this occurrence's departure: a legal ride must
        // alight at a strictly later call, not merely dwell at the same call.
        if (call.canAlight && Number.isFinite(call.arrival) && call.arrival <= previousBoarding) return false;
        for (const field of ['arrival', 'departure']) {
            if (!Number.isFinite(call[field])) continue;
            if (call[field] < previousTime) return false;
            previousTime = call[field];
        }
        if (call.canBoard && Number.isFinite(call.departure)) previousBoarding = Math.max(previousBoarding, call.departure);
    }
    return true;
}

/** Experimental index, used only by an explicit RAPTOR request, never by default.
 * A FIFO chain is a RAPTOR route. Overtaking trains are put in separate chains,
 * allowing binary earliest-trip searches without assuming UK trains are FIFO.
 * Compile a new index after applying a live overlay; no cross-network caches.
 */
export function compileRaptorNetwork(network, { check = () => {} } = {}) {
    const begun = performance.now();
    const groups = new Map(), services = new Map(), unsafeServices = new Set();
    let calls = 0;
    for (const service of network.services) {
        check();
        services.set(service.id, service);
        if (!strictlyProgresses(service, check)) unsafeServices.add(service.id);
        calls += service.calls.length;
        const key = patternKey(service);
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(service);
    }
    const patterns = [], stationRoutes = new Map(), topologyPatterns = [], stationAlights = new Map();
    let overtakingSplits = 0;
    for (const trips of groups.values()) {
        check();
        const topology = { id: topologyPatterns.length, calls: trips[0].calls, mode: trips[0].mode };
        topologyPatterns.push(topology);
        topology.calls.forEach((call, position) => {
            check();
            if (!call.station || !call.canAlight || !Number.isFinite(call.arrival)) return;
            if (!stationAlights.has(call.station)) stationAlights.set(call.station, []);
            stationAlights.get(call.station).push({ pattern: topology, position });
        });
        trips.sort((a, b) => firstTime(a) - firstTime(b) || String(a.id).localeCompare(String(b.id)));
        const chains = [];
        for (const trip of trips) {
            check();
            let chain = chains.find(values => follows(values.at(-1), trip, check));
            if (!chain) { chain = []; chains.push(chain); }
            chain.push(trip);
        }
        overtakingSplits += Math.max(0, chains.length - 1);
        for (const chain of chains) {
            const id = patterns.length, prototype = chain[0];
            const pattern = { id, trips: chain, calls: prototype.calls, operator: prototype.operator, mode: prototype.mode, topology };
            patterns.push(pattern);
            prototype.calls.forEach((call, position) => {
                check();
                if (!call.station || !call.canBoard || !Number.isFinite(call.departure)) return;
                if (!stationRoutes.has(call.station)) stationRoutes.set(call.station, []);
                stationRoutes.get(call.station).push({ pattern, position });
            });
        }
    }
    check();
    const connections = createConnectionIndex(network);
    check();
    return { network, services, connections, patterns, stationRoutes, topologyPatterns, stationAlights, unsafeServices,
        stats: { services: services.size, calls, stoppingPatterns: groups.size,
            routes: patterns.length, overtakingSplits, stations: connections.stations.size,
            nonStrictServices: unsafeServices.size,
            indexBuildMs: performance.now() - begun } };
}

// Optimistic 0/1 shortest paths on reversed route-position nodes. A train costs
// one boarding regardless of the number of calls traversed; walking costs zero.
// Ignore times, windows, allowances, used trips and even the one-link restriction:
// this only underestimates remaining boardings, so it cannot prune a feasible
// journey. Position nodes avoid quadratic station-pair edges on long services.
function boardingBounds(index, target, modes, maximum, check) {
    const stations = new Map([[target, 0]]), routes = new Map();
    const buckets = Array.from({ length: maximum + 1 }, () => []);
    buckets[0].push({ station: target });
    const addStation = (station, cost) => {
        if (cost > maximum || cost >= (stations.get(station) ?? Infinity)) return;
        stations.set(station, cost);
        buckets[cost].push({ station });
    };
    const addPosition = (pattern, position, cost) => {
        let distances = routes.get(pattern.id);
        if (!distances) { distances = new Uint8Array(pattern.calls.length).fill(255); routes.set(pattern.id, distances); }
        if (cost >= distances[position]) return;
        distances[position] = cost;
        buckets[cost].push({ pattern, position });
    };
    for (let cost = 0; cost <= maximum; cost++) while (buckets[cost].length) {
        check();
        const node = buckets[cost].pop();
        if (node.station) {
            if (stations.get(node.station) !== cost) continue;
            for (const { pattern, position } of index.stationAlights.get(node.station) ?? []) {
                check();
                if (modes.has(pattern.mode)) addPosition(pattern, position, cost);
            }
            for (const from of index.connections.incoming.get(node.station) ?? []) {
                check();
                for (const rule of index.connections.pairs.get(`${from}|${node.station}`) ?? []) {
                    if (modes.has(rule.mode)) addStation(from, cost + (rule.mode === 'walk' ? 0 : 1));
                }
            }
        } else {
            if (routes.get(node.pattern.id)[node.position] !== cost) continue;
            const call = node.pattern.calls[node.position];
            if (call.station && call.canBoard && Number.isFinite(call.departure)) addStation(call.station, cost + 1);
            if (node.position > 0) addPosition(node.pattern, node.position - 1, cost);
        }
    }
    return stations;
}

function station(index, crs) {
    return { crs, name: index.connections.stations.get(crs)?.name ?? crs };
}

function vehicleLeg(index, raw) {
    const service = index.services.get(raw.serviceId);
    const from = service.calls[raw.boardIndex], to = service.calls[raw.alightIndex];
    return {
        kind: 'vehicle', mode: service.mode, serviceId: service.id,
        variantId: service.variantId, uid: service.uid, source: service.source,
        originDate: service.originDate, operator: service.operator,
        from: station(index, from.station), to: station(index, to.station),
        departure: new Date(from.departure).toISOString(), arrival: new Date(to.arrival).toISOString(),
        durationMinutes: (to.arrival - from.departure) / MINUTE, platform: from.platform ?? null,
        boardIndex: raw.boardIndex, alightIndex: raw.alightIndex, sourceRef: service.sourceRef,
        ...liveLeg(service, raw.boardIndex, raw.alightIndex),
        callingPoints: service.calls.slice(raw.boardIndex, raw.alightIndex + 1)
            .filter(call => call.station && (call.canBoard || call.canAlight || call.plannerLive))
            .map(call => ({ station: station(index, call.station), sequence: call.sequence,
                arrival: Number.isFinite(call.arrival) ? new Date(call.arrival).toISOString() : null,
                departure: Number.isFinite(call.departure) ? new Date(call.departure).toISOString() : null,
                canBoard: call.canBoard, canAlight: call.canAlight, platform: call.platform ?? null,
                ...liveCall(service, call) }))
    };
}

function transferLeg(index, raw) {
    return { kind: 'transfer', mode: raw.mode, from: station(index, raw.from), to: station(index, raw.to),
        departure: new Date(raw.start).toISOString(), arrival: new Date(raw.end).toISOString(),
        durationMinutes: raw.minutes, minutes: raw.minutes, breakdown: raw.breakdown,
        ruleId: raw.ruleId, sourceRef: raw.sourceRef, policy: raw.policy,
        genericTransfer: !['walk', 'interchange'].includes(raw.mode),
        warnings: ['walk', 'interchange'].includes(raw.mode) ? []
            : ['This is a supplied generic transfer; detailed local departures and stops are not available.'],
        movementDeparture: raw.movementStart == null ? null : new Date(raw.movementStart).toISOString(),
        movementArrival: raw.movementEnd == null ? null : new Date(raw.movementEnd).toISOString() };
}

function legs(path) {
    const result = [];
    for (let node = path; node; node = node.previous) result.push(node.leg);
    return result.reverse();
}

function subset(left, right) {
    for (const id of left) if (!right.has(id)) return false;
    return true;
}

function signature(path) {
    return legs(path).map(leg => leg.kind === 'vehicle'
        ? `${leg.serviceId}:${leg.boardIndex}:${leg.alightIndex}`
        : `${leg.ruleId}:${leg.start}:${leg.end}`).join('|');
}

function lowerBound(trips, position, ready) {
    let low = 0, high = trips.length;
    while (low < high) {
        const middle = (low + high) >>> 1;
        if (trips[middle].calls[position].departure < ready) low = middle + 1;
        else high = middle;
    }
    return low;
}

/** A departure-profile McRAPTOR POC: marked stops select affected route chains,
 * each chain is scanned once per boarding round, and route bags retain source
 * departure boundaries. It returns one representative for equal Pareto criteria,
 * not every tied itinerary. No upstream TfL/live lookups or default activation.
 */
export function findRaptorJourneys(request, index, options = {}) {
    const begun = performance.now();
    const metrics = { routesScanned: 0, stopsScanned: 0, tripSearches: 0, labels: 0, operations: 0, rounds: 0,
        topologyBoundsMs: 0, topologyPruned: 0 };
    const report = () => ({ ...metrics, elapsedMs: performance.now() - begun });
    const deadline = Date.now() + (options.timeoutMs ?? 10_000);
    const maxOperations = options.maxOperations ?? 2_000_000;
    const maxLabels = options.maxLabels ?? 200_000;
    const checkpoint = () => {
        if (options.signal?.aborted || options.abortSignal?.aborted) throw failure('SEARCH_CANCELLED', 'RAPTOR POC search was cancelled.');
        if (Date.now() > deadline) throw failure('SEARCH_TIMEOUT', 'RAPTOR POC exceeded its time budget.');
    };
    const check = () => {
        if ((++metrics.operations & 255) === 1) checkpoint();
        if (metrics.operations > maxOperations) throw failure('SEARCH_TIMEOUT', 'RAPTOR POC exceeded its operation budget.');
    };
    try {
        check();
        if (!Number.isFinite(options.timeoutMs ?? 10_000) || (options.timeoutMs ?? 10_000) < 0
            || !Number.isSafeInteger(maxOperations) || maxOperations < 0
            || !Number.isSafeInteger(maxLabels) || maxLabels < 0) {
            throw failure('INVALID_REQUEST', 'Invalid RAPTOR POC work budgets.');
        }
        if (request.timeType && request.timeType !== 'departAfter' || request.via?.length
            || options.resolveTubeConnection || options.excludeDirect) {
            throw failure('UNSUPPORTED_REQUEST', 'This scheduled RAPTOR POC supports departAfter without via stations, dynamic TfL resolution or direct-route exclusions.');
        }
        const query = Date.parse(request.time), window = (request.windowMinutes ?? DEFAULT_WINDOW_MINUTES) * MINUTE;
        const maxDuration = (options.maxDurationMinutes ?? 1440) * MINUTE;
        const maxChanges = request.maxChanges ?? MAX_CHANGES, maxBoardings = maxChanges + 1;
        const limit = request.limit ?? 5, offset = options.offset ?? 0;
        const extra = request.extraConnectionMinutes ?? 0;
        if (!Number.isFinite(query) || !Number.isFinite(window) || window <= 0
            || !Number.isFinite(maxDuration) || maxDuration <= 0
            || !Number.isInteger(maxChanges) || maxChanges < 0 || maxChanges > MAX_CHANGES
            || !Number.isInteger(limit) || limit < 1 || !Number.isInteger(offset) || offset < 0
            || !Number.isFinite(extra) || extra < 0) {
            throw failure('INVALID_REQUEST', 'Invalid RAPTOR POC search bounds.');
        }
        if (!index.connections.stations.has(request.origin) || !index.connections.stations.has(request.destination)) {
            throw failure('INVALID_STATION', 'Unknown planner station.');
        }
        const modes = new Set(request.allowedModes ?? MODES), profile = options.departureProfile === true;
        const boundsStarted = performance.now();
        const remainingBoardings = boardingBounds(index, request.destination, modes, maxBoardings, check);
        metrics.topologyBoundsMs = performance.now() - boundsStarted;
        const routeTailBounds = new Map();
        const tailBounds = pattern => {
            if (routeTailBounds.has(pattern.topology.id)) return routeTailBounds.get(pattern.topology.id);
            const bounds = new Uint8Array(pattern.calls.length + 1).fill(255);
            for (let position = pattern.calls.length - 1; position >= 0; position--) {
                check();
                const call = pattern.calls[position];
                bounds[position] = Math.min(bounds[position + 1], call.canAlight && Number.isFinite(call.arrival)
                    ? remainingBoardings.get(call.station) ?? 255 : 255);
            }
            routeTailBounds.set(pattern.topology.id, bounds);
            return bounds;
        };
        const rounds = Array.from({ length: maxBoardings + 1 }, () => new Map());
        const bags = new Map(), completed = [];
        const dominates = (a, b) => (!profile || a.boundary === b.boundary)
            && a.time <= b.time && a.boundary >= b.boundary && a.boardings <= b.boardings;
        // Preserve operator/kind bags and exceptional service histories while
        // keeping only active labels in each bag. Round lists retain their refs.
        const dominatesContinuation = (a, b) => dominates(a, b) && subset(a.unsafeUsed, b.unsafeUsed);
        const dominatesBoard = (a, b) => a.position <= b.position && a.boardings <= b.boardings
            && a.boundary >= b.boundary && (!profile || a.boundary === b.boundary) && subset(a.unsafeUsed, b.unsafeUsed);
        const countLabel = () => {
            if (++metrics.labels > maxLabels) throw failure('SEARCH_TIMEOUT', 'RAPTOR POC exceeded its label budget.');
        };
        // Alight candidates share a scratch label; allocate their reconstruction
        // only after dominance accepts them, and never store the scratch itself.
        const materializeRide = (label, boarding, alightIndex) => boarding ? { ...label,
            path: { previous: boarding.path, leg: { kind: 'vehicle', serviceId: boarding.service.id,
                boardIndex: boarding.position, alightIndex } } } : label;
        const complete = (label, boarding, alightIndex) => {
            if (completed.some(previous => dominates(previous, label))) return;
            for (let position = completed.length - 1; position >= 0; position--) {
                if (dominates(label, completed[position])) completed.splice(position, 1);
            }
            countLabel();
            completed.push(materializeRide(label, boarding, alightIndex));
        };
        const retain = (label, boarding, alightIndex) => {
            check();
            if (label.boardings > maxBoardings || label.boundary != null
                && (label.boundary < query || label.boundary >= query + window
                    || label.time - label.boundary > maxDuration)) return;
            if (label.boardings + (remainingBoardings.get(label.station) ?? Infinity) > maxBoardings) {
                metrics.topologyPruned++;
                return;
            }
            if (label.station === request.destination && (label.path || boarding)) { complete(label, boarding, alightIndex); return; }
            if (label.boundary != null && completed.some(previous => dominates(previous, label))) return;
            const key = `${label.station}|${label.operator ?? ''}|${label.lastKind}`;
            const values = bags.get(key) ?? [];
            // For strictly chronological, positive-duration rides, a future
            // reboarding of a used occurrence is dominated by staying aboard
            // the original ride to that eventual alight call. Therefore only
            // zero-time/nonchronological occurrences need history-sensitive
            // dominance. Full histories still forbid every repeated service.
            if (values.some(previous => dominatesContinuation(previous, label))) return;
            let kept = 0;
            for (const previous of values) {
                if (dominatesContinuation(label, previous)) previous.active = false;
                else values[kept++] = previous;
            }
            values.length = kept;
            label = materializeRide(label, boarding, alightIndex);
            label.active = true;
            values.push(label);
            bags.set(key, values);
            const marked = rounds[label.boardings];
            if (!marked.has(label.station)) marked.set(label.station, []);
            marked.get(label.station).push(label);
            countLabel();
        };
        const source = { station: request.origin, time: query, boundary: null, operator: null,
            boardings: 0, path: null, lastKind: 'initial', active: true, used: new Set(), unsafeUsed: new Set() };
        const arrival = { station: null, time: 0, boundary: null, operator: null, boardings: 0,
            path: null, lastKind: 'vehicle', used: null, unsafeUsed: null };
        if (request.origin !== request.destination) retain(source);
        const transfer = (label, destination, mode, event, initial, endpoint = false) => resolveConnection(index.connections, {
            from: label.station, to: destination, arrival: label.time, departure: event?.calls?.departure,
            arrivingOperator: label.operator, departingOperator: event?.service?.operator,
            direction: initial && event ? 'latest' : 'earliest',
            originIsEndpoint: initial, destinationIsEndpoint: endpoint,
            extraConnectionMinutes: request.extraConnectionMinutes ?? 0, allowedModes: new Set([mode])
        });
        for (let round = 0; round <= maxBoardings; round++) {
            check();
            const marked = rounds[round];
            if (!marked.size) continue;
            metrics.rounds++;
            // Walking links stay in this boarding round. A supplied non-walking
            // link consumes its own boarding; neither can be chained to a link.
            for (const values of [...marked.values()]) for (const label of [...values]) {
                check();
                if (!label.active || label.lastKind === 'fixed') continue;
                for (const destination of index.connections.outgoing.get(label.station) ?? []) {
                    check();
                    const linkModes = new Set((index.connections.pairs.get(`${label.station}|${destination}`) ?? []).map(rule => rule.mode));
                    for (const mode of linkModes) {
                        if (!modes.has(mode)) continue;
                        // Initial prefixes are timed backwards from each actual
                        // onward train below, rather than departing at query time.
                        if (label === source && destination !== request.destination) continue;
                        const connection = transfer(label, destination, mode, null, label === source,
                            destination === request.destination);
                        if (!connection) continue;
                        const path = { previous: label.path, leg: { kind: 'transfer', ...connection } };
                        retain({ station: destination, time: connection.end, boundary: label.boundary ?? connection.start,
                            operator: null, boardings: round + connection.boardings, path, lastKind: 'fixed',
                            used: label.used, unsafeUsed: label.unsafeUsed });
                    }
                }
            }
            if (round === maxBoardings) continue;
            const queue = new Map();
            const markRoutes = station => {
                for (const { pattern, position } of index.stationRoutes.get(station) ?? []) {
                    check();
                    if (!modes.has(pattern.mode)) continue;
                    queue.set(pattern.id, Math.min(queue.get(pattern.id) ?? Infinity, position));
                }
            };
            for (const [station, values] of marked) if (values.some(label => label.active)) markRoutes(station);
            if (round === 0) for (const destination of index.connections.outgoing.get(request.origin) ?? []) markRoutes(destination);
            for (const [id, start] of queue) {
                check();
                const pattern = index.patterns[id], aboard = new Map();
                const onwardBounds = tailBounds(pattern);
                metrics.routesScanned++;
                const board = (label, service, position, connection = null) => {
                    check();
                    if (label.used.has(service.id)) return;
                    const departure = service.calls[position].departure;
                    const boundary = label.boundary ?? connection?.start ?? departure;
                    const boardings = round + 1 + (connection?.boardings ?? 0);
                    if (boundary < query || boundary >= query + window || boardings > maxBoardings
                        || departure - boundary > maxDuration) return;
                    if (boardings + onwardBounds[position + 1] > maxBoardings) { metrics.topologyPruned++; return; }
                    const values = aboard.get(service.id) ?? [];
                    const boarding = { service, position, boundary, boardings,
                        unsafeUsed: index.unsafeServices.has(service.id) ? new Set(label.unsafeUsed).add(service.id) : label.unsafeUsed };
                    if (values.some(previous => dominatesBoard(previous, boarding))) return;
                    let kept = 0;
                    for (const previous of values) if (!dominatesBoard(boarding, previous)) values[kept++] = previous;
                    values.length = kept;
                    boarding.used = new Set(label.used).add(service.id);
                    boarding.path = connection ? { previous: label.path, leg: { kind: 'transfer', ...connection } } : label.path;
                    values.push(boarding);
                    aboard.set(service.id, values);
                };
                for (let position = start; position < pattern.calls.length; position++) {
                    check();
                    metrics.stopsScanned++;
                    const prototype = pattern.calls[position];
                    if (prototype.station && prototype.canAlight && Number.isFinite(prototype.arrival)) {
                        for (const values of aboard.values()) for (const boarding of values) {
                            check();
                            const call = boarding.service.calls[position];
                            if (boarding.position >= position || call.arrival < boarding.service.calls[boarding.position].departure) continue;
                            arrival.station = call.station;
                            arrival.time = call.arrival;
                            arrival.boundary = boarding.boundary;
                            arrival.operator = pattern.operator;
                            arrival.boardings = boarding.boardings;
                            arrival.used = boarding.used;
                            arrival.unsafeUsed = boarding.unsafeUsed;
                            retain(arrival, boarding, position);
                        }
                    }
                    if (!prototype.station || !prototype.canBoard || !Number.isFinite(prototype.departure)) continue;
                    for (const label of marked.get(prototype.station) ?? []) {
                        check();
                        if (!label.active) continue;
                        metrics.tripSearches++;
                        if (label === source) {
                            for (let trip = lowerBound(pattern.trips, position, query); trip < pattern.trips.length; trip++) {
                                check();
                                const service = pattern.trips[trip];
                                if (service.calls[position].departure >= query + window) break;
                                board(label, service, position);
                            }
                        } else {
                            const connection = label.lastKind === 'fixed' ? null : resolveConnection(index.connections, {
                                from: prototype.station, to: prototype.station, arrival: label.time,
                                arrivingOperator: label.operator, departingOperator: pattern.operator,
                                extraConnectionMinutes: request.extraConnectionMinutes ?? 0
                            });
                            if (label.lastKind !== 'fixed' && !connection) continue;
                            const ready = connection?.end ?? label.time;
                            for (let trip = lowerBound(pattern.trips, position, ready); trip < pattern.trips.length; trip++) {
                                check();
                                const service = pattern.trips[trip];
                                if (label.used.has(service.id)) continue;
                                board(label, service, position, connection);
                                // A zero-time/nonchronological first trip can
                                // forbid a later backward-index reboarding which
                                // staying aboard cannot replace. Retain those
                                // alternatives until a strictly progressing FIFO
                                // trip supplies the ordinary earliest-trip bound.
                                if (!index.unsafeServices.has(service.id)) break;
                            }
                        }
                    }
                    if (round === 0 && prototype.station !== request.origin
                        && index.connections.pairs.has(`${request.origin}|${prototype.station}`)) {
                        const linkModes = new Set(index.connections.pairs.get(`${request.origin}|${prototype.station}`).map(rule => rule.mode));
                        for (const mode of linkModes) {
                            if (!modes.has(mode)) continue;
                            metrics.tripSearches++;
                            for (let trip = lowerBound(pattern.trips, position, query); trip < pattern.trips.length; trip++) {
                                check();
                                const service = pattern.trips[trip], calls = service.calls[position];
                                if (calls.departure >= query + window + maxDuration) break;
                                const connection = transfer(source, prototype.station, mode, { service, calls }, true);
                                if (connection) board(source, service, position, connection);
                            }
                        }
                    }
                }
            }
        }
        // complete() already maintains the full frontier, rejecting equal
        // criteria on arrival. Transitivity prevents a removed tie re-entering.
        const candidates = completed;
        candidates.sort((a, b) => a.time - b.time || a.boardings - b.boardings || b.boundary - a.boundary
            || signature(a.path).localeCompare(signature(b.path)));
        let ranked = candidates;
        if (profile && options.balanceDepartures) {
            const groups = new Map();
            for (const candidate of candidates) {
                if (!groups.has(candidate.boundary)) groups.set(candidate.boundary, []);
                groups.get(candidate.boundary).push(candidate);
            }
            const ordered = [...groups].sort(([a], [b]) => a - b).map(([, values]) => values);
            ranked = [];
            for (let rank = 0, more = true; more; rank++) {
                more = false;
                for (const values of ordered) if (values[rank]) { ranked.push(values[rank]); more = true; }
            }
        }
        const journeys = ranked.slice(offset, offset + limit).map(candidate => ({
            departure: new Date(candidate.boundary).toISOString(), arrival: new Date(candidate.time).toISOString(),
            durationMinutes: (candidate.time - candidate.boundary) / MINUTE,
            changes: Math.max(0, candidate.boardings - 1), status: 'scheduledOnly',
            legs: legs(candidate.path).map(raw => raw.kind === 'vehicle' ? vehicleLeg(index, raw) : transferLeg(index, raw))
        }));
        for (const journey of journeys) {
            check();
            if (!validateJourney(journey, index.network, request)) {
                throw failure('INVALID_ITINERARY', 'A RAPTOR POC itinerary failed independent feasibility validation.');
            }
        }
        checkpoint();
        return { journeys, metrics: report(), searchTruncated: false,
            ...(request.origin === request.destination ? { alreadyAtDestination: true } : {}),
            pagination: { offset, total: candidates.length, nextOffset: offset + limit < candidates.length ? offset + limit : null },
            policy: { experimental: true, version: 'mc-raptor-scheduled-poc-v1', connectionPolicy: CONNECTION_POLICY,
                timeType: 'departAfter', maxChanges, windowMinutes: window / MINUTE, maxDurationMinutes: maxDuration / MINUTE,
                maxConsecutiveFixedLinks: 1, equalCriteria: 'one representative', dynamicTubeResolution: false } };
    } catch (error) {
        error.metrics = report();
        throw error;
    }
}
