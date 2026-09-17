const MINUTE = 60000;
const finite = Number.isFinite;
const iso = value => finite(value) ? new Date(value).toISOString() : undefined;
const unique = values => [...new Set(values.filter(Boolean))];
const annotationIndexes = new WeakMap();
export { discoverLiveMatches, matchLiveObservations, expectedDepartureTime } from './live-matching.js';

function callAnnotation(call, observedAt) {
    const value = call.plannerLive;
    if (!value) return {};
    const live = {
        status: value.cancelled ? 'cancelled' : value.unknownDelay || value.arrivalUnknown || value.departureUnknown ? 'unknown'
            : (value.departureDelayMinutes > 0 || value.arrivalDelayMinutes > 0) ? 'delayed'
                : value.confirmed ? 'onTime' : 'unknown',
        updatedAt: iso(observedAt), cancelled: Boolean(value.cancelled), partCancelled: false,
        warnings: value.warnings || [],
        ...(finite(value.arrival) ? { arrival: iso(value.arrival), arrivalDelayMinutes: value.arrivalDelayMinutes } : {}),
        ...(finite(value.departure) ? { departure: iso(value.departure), departureDelayMinutes: value.departureDelayMinutes } : {})
    };
    return {
        ...(finite(call.scheduledArrival) ? { scheduledArrival: iso(call.scheduledArrival) } : {}),
        ...(finite(call.scheduledDeparture) ? { scheduledDeparture: iso(call.scheduledDeparture) } : {}), live
    };
}

export function liveCall(service, call) {
    return callAnnotation(call, service.plannerLive?.observedAt);
}

export function annotateLiveJourney(journey, network) {
    if (!annotationIndexes.has(network)) annotationIndexes.set(network, new Map(network.services.map(service => [service.id, service])));
    const services = annotationIndexes.get(network);
    return { ...journey, legs: journey.legs.map(leg => {
        const service = services.get(leg.serviceId);
        if (leg.kind !== 'vehicle' || !service?.plannerLive) return leg;
        const calls = new Map(service.calls.map(call => [call.sequence, call]));
        return { ...leg, ...liveLeg(service, leg.boardIndex, leg.alightIndex),
            platform: service.calls[leg.boardIndex]?.platform ?? leg.platform,
            callingPoints: leg.callingPoints.map(call => {
                const updated = calls.get(call.sequence);
                return updated ? { ...call, platform: updated.platform ?? call.platform, ...liveCall(service, updated) } : call;
            }) };
    }) };
}

/** Annotation is scoped to the ridden portion. A cancelled stop elsewhere on
 * this train is a warning, not cancellation of the passenger's selected leg.
 */
export function liveLeg(service, boardIndex, alightIndex) {
    const value = service.plannerLive;
    if (!value) return {};
    const board = service.calls[boardIndex];
    const alight = service.calls[alightIndex];
    const first = board.plannerLiveIndex;
    const last = alight.plannerLiveIndex;
    const affectedSection = value.cancelledSegments.some(segment => first < segment.toIndex && last > segment.fromIndex);
    const cancelled = value.cancelled || Boolean(board.plannerLive?.cancelled || alight.plannerLive?.cancelled || affectedSection);
    const partCancelled = !value.cancelled && (value.cancelledIndices.length > 0 || value.cancelledSegments.length > 0
        || Number.isInteger(value.unknownCancellationFromIndex));
    const departure = board.plannerLive?.departure;
    const arrival = alight.plannerLive?.arrival;
    const departureDelayMinutes = finite(departure) ? (departure - board.scheduledDeparture) / MINUTE : undefined;
    const arrivalDelayMinutes = finite(arrival) ? (arrival - alight.scheduledArrival) / MINUTE : undefined;
    const unknown = value.unknownDelay || board.plannerLive?.unknownDelay || alight.plannerLive?.unknownDelay
        || board.plannerLive?.departureUnknown || alight.plannerLive?.arrivalUnknown
        || last > (value.unknownCancellationFromIndex ?? Infinity) || last > (value.unknownDelayFromIndex ?? Infinity)
        || !finite(departure) || !finite(arrival);
    const warnings = unique([...value.warnings,
        ...service.calls.slice(boardIndex, alightIndex + 1).flatMap(call => call.plannerLive?.warnings || []),
        ...(cancelled ? ['This part of the train journey is cancelled.'] : []),
        ...(partCancelled && !cancelled && !Number.isInteger(value.unknownCancellationFromIndex)
            ? ['This train has cancellations at other stops; the selected boarding and arrival stops are unaffected.'] : []),
        ...(unknown && !cancelled ? ['Live times are not confirmed for every part of this train journey.'] : [])]);
    return {
        ...(service.scheduledServiceId ? { scheduledServiceId: service.scheduledServiceId } : {}),
        scheduledDeparture: iso(board.scheduledDeparture), scheduledArrival: iso(alight.scheduledArrival),
        live: {
            status: cancelled ? 'cancelled' : unknown ? 'unknown' : partCancelled ? 'partCancelled'
                : departureDelayMinutes > 0 || arrivalDelayMinutes > 0 ? 'delayed' : 'onTime',
            updatedAt: iso(value.observedAt), cancelled, partCancelled, warnings,
            ...(board.plannerLive?.platform ? { platform: board.plannerLive.platform } : {}),
            ...(board.plannerLive?.length ? { length: board.plannerLive.length } : {}),
            ...(finite(departure) ? { departure: iso(departure), departureDelayMinutes } : {}),
            ...(finite(arrival) ? { arrival: iso(arrival), arrivalDelayMinutes } : {})
        },
        ...(warnings.length ? { warnings } : {})
    };
}

function operationalSections(count, cancelledSegments) {
    let from = 0;
    const sections = [];
    for (const segment of [...cancelledSegments].sort((a, b) => a.fromIndex - b.fromIndex)) {
        if (segment.fromIndex >= from) sections.push([from, segment.fromIndex]);
        from = Math.max(from, segment.toIndex);
    }
    if (from < count) sections.push([from, count - 1]);
    return sections.filter(([first, last]) => last > first);
}

function validSegments(segments, count) {
    return Array.isArray(segments) && segments.every(segment => Number.isInteger(segment.fromIndex)
        && Number.isInteger(segment.toIndex) && segment.fromIndex >= 0
        && segment.fromIndex < segment.toIndex && segment.toIndex < count);
}

/** Create a new identity for routing indexes. The scheduled national network,
 * date cache and all original calls remain untouched. Arrival/departure are
 * effective times only in apply mode; annotations retain both sets of times.
 *
 * Snapshot updates use exact service IDs and original call array indices.
 * cancelledSegments denotes non-operating travel between the two indices;
 * call.cancelled alone denotes a skipped stop and does not break through travel.
 */
export function applyLiveSnapshot(network, snapshot, { mode = 'apply', check = () => {} } = {}) {
    if (!['apply', 'ignore'].includes(mode)) throw new Error('Invalid live timetable mode');
    const updates = new Map((snapshot.services || []).map(service => [service.serviceId, service]));
    const services = [];
    const changedServiceIds = new Set();
    const routingChangedServiceIds = new Set();
    const warnings = [...(snapshot.warnings || [])];
    for (const original of network.services) {
        check();
        const update = updates.get(original.id);
        if (!update) { services.push(original); continue; }
        changedServiceIds.add(original.id);
        const callUpdates = new Map((update.calls || []).map(call => [call.index, call]));
        const cancelledSegments = update.cancelledSegments || [];
        const invalidSegments = !validSegments(cancelledSegments, original.calls.length);
        const fullCancelled = update.cancelled === true || update.status === 'cancelled';
        const service = { ...original, calls: original.calls.map((call, index) => {
            if (index % 128 === 0) check();
            const unknownFuture = index > Math.min(update.unknownCancellationFromIndex ?? Infinity, update.unknownDelayFromIndex ?? Infinity);
            const observed = unknownFuture ? { ...callUpdates.get(index), arrivalUnknown: true, departureUnknown: true } : callUpdates.get(index);
            const next = { ...call, scheduledArrival: call.arrival, scheduledDeparture: call.departure, plannerLiveIndex: index };
            if (!observed && !fullCancelled) return next;
            const arrival = finite(observed?.arrival) ? observed.arrival : undefined;
            const departure = finite(observed?.departure) ? observed.departure : undefined;
            next.plannerLive = {
                cancelled: fullCancelled || observed?.cancelled === true,
                unknownDelay: update.unknownDelay === true || observed?.unknownDelay === true,
                arrivalUnknown: observed?.arrivalUnknown === true, departureUnknown: observed?.departureUnknown === true,
                confirmed: observed?.confirmed === true || finite(arrival) || finite(departure),
                warnings: [...(observed?.warnings || [])],
                ...(typeof observed?.platform === 'string' && observed.platform.trim() ? { platform: observed.platform.trim() } : {}),
                ...(Number.isInteger(observed?.length) && observed.length > 0 ? { length: observed.length } : {}),
                ...(finite(arrival) ? { arrival, arrivalDelayMinutes: (arrival - call.arrival) / MINUTE } : {}),
                ...(finite(departure) ? { departure, departureDelayMinutes: (departure - call.departure) / MINUTE } : {})
            };
            if (observed?.platform != null) next.platform = observed.platform;
            if (mode === 'apply') {
                if (finite(arrival)) next.arrival = arrival;
                if (finite(departure)) next.departure = departure;
                if (next.plannerLive.cancelled || next.plannerLive.unknownDelay) next.canBoard = next.canAlight = false;
                if (next.plannerLive.unknownDelay || observed?.arrivalUnknown) {
                    next.canAlight = false;
                    next.arrival = null;
                }
                if (next.plannerLive.unknownDelay || observed?.departureUnknown) {
                    next.canBoard = false;
                    next.departure = null;
                }
                // An arrival-only forecast cannot establish when a passenger
                // may board. Never invent a later departure after the old one.
                if (next.canBoard && finite(next.arrival) && next.arrival > next.departure) {
                    next.canBoard = false;
                    next.departure = null;
                    next.plannerLive.departureUnknown = true;
                }
            }
            return next;
        }) };
        service.plannerLive = {
            observedAt: snapshot.observedAt, cancelled: fullCancelled,
            unknownCancellationFromIndex: update.unknownCancellationFromIndex,
            unknownDelayFromIndex: update.unknownDelayFromIndex,
            unknownDelay: update.unknownDelay === true, cancelledSegments: invalidSegments ? [] : cancelledSegments,
            cancelledIndices: service.calls.flatMap((call, index) => call.plannerLive?.cancelled ? [index] : []),
            warnings: unique([...(update.warnings || []), ...(invalidSegments ? ['The cancelled part of this train could not be determined.'] : [])])
        };
        if (mode === 'ignore') { services.push(service); continue; }
        if (fullCancelled || update.unknownDelay || invalidSegments) {
            routingChangedServiceIds.add(original.id);
            continue;
        }
        if (cancelledSegments.length || service.calls.some((call, index) => {
            const before = original.calls[index];
            return ['arrival', 'departure', 'canBoard', 'canAlight'].some(key => call[key] !== before[key]);
        })) routingChangedServiceIds.add(original.id);
        const sections = cancelledSegments.length ? operationalSections(service.calls.length, cancelledSegments)
            : [[0, service.calls.length - 1]];
        for (const [first, last] of sections) {
            const calls = service.calls.slice(first, last + 1);
            let latest = -Infinity;
            let consistent = true;
            for (const call of calls) {
                for (const [allowed, time] of [[call.canAlight, call.arrival], [call.canBoard, call.departure]]) {
                    if (!allowed || !finite(time)) continue;
                    if (time < latest) consistent = false;
                    latest = Math.max(latest, time);
                }
            }
            if (!consistent) {
                routingChangedServiceIds.add(original.id);
                warnings.push('Some live train times were inconsistent and could not be used safely.');
                continue;
            }
            services.push(cancelledSegments.length ? { ...service,
                id: `${original.id}:live:${first}-${last}`, scheduledServiceId: original.id, calls
            } : service);
        }
    }
    return { ...network, services, baseNetwork: network, changedServiceIds, routingChangedServiceIds, live: { id: snapshot.id, observedAt: snapshot.observedAt,
        expiresAt: snapshot.expiresAt, mode, warnings: unique(warnings) } };
}
