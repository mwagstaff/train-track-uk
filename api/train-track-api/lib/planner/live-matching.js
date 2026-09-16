import { createHash } from 'node:crypto';
import { prepareNetwork } from './router.js';

const MINUTE = 60000;
const DAY = 86400000;
const MAX_DIAGNOSTICS = 512;
const clockFormatter = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const dateFormatter = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit' });
const clock = value => Number.isFinite(value) ? clockFormatter.format(new Date(value)) : null;
const hhmm = value => typeof value === 'string' && /^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value.trim()) ? value.trim() : null;
const textIs = (value, expected) => typeof value === 'string' && value.trim().toLowerCase() === expected;
const list = value => Array.isArray(value) ? value : [];
const cancelledAtStop = item => item.isCancelled === true
    || [item.eta, item.etd, item.et].some(value => textIs(value, 'cancelled'));

function observationTime(record, now, maxAgeMs) {
    if (typeof record.generatedAt !== 'string' || !/(?:Z|[+-]\d\d:\d\d)$/.test(record.generatedAt)) return NaN;
    const time = Date.parse(record.generatedAt);
    return Number.isFinite(time) && time <= now + 5000 && now - time <= maxAgeMs ? time : NaN;
}

// Resolve clock-only estimates around the exact scheduled occurrence, including
// midnight. A repeated autumn clock time is ambiguous without an upstream date.
function instantForClock(value, reference) {
    const parsed = hhmm(value);
    if (!parsed || !Number.isFinite(reference)) return undefined;
    const [hour, minute] = parsed.split(':').map(Number);
    const day = Math.floor(reference / DAY) * DAY;
    const candidates = [];
    for (let offset = -1; offset <= 1; offset++) for (const zone of [0, 60]) {
        const time = day + offset * DAY + (hour * 60 + minute - zone) * MINUTE;
        if (clock(time) === parsed && Math.abs(time - reference) <= 12 * 60 * MINUTE) candidates.push(time);
    }
    const unique = [...new Set(candidates)].sort((a, b) => Math.abs(a - reference) - Math.abs(b - reference));
    if (!unique.length) return undefined;
    if (unique.some(time => time !== unique[0] && dateFormatter.format(time) === dateFormatter.format(unique[0]))) return undefined;
    return unique[0];
}

function forecast(scheduled, estimated, actual) {
    if (hhmm(actual)) return { time: instantForClock(actual, scheduled) };
    if (textIs(actual, 'on time')) return { time: scheduled };
    if (hhmm(estimated)) return { time: instantForClock(estimated, scheduled) };
    if (textIs(estimated, 'on time')) return { time: scheduled };
    return { unknown: textIs(estimated, 'delayed') || textIs(actual, 'delayed') };
}

export function expectedDepartureTime(item, scheduledDeparture) {
    if (!Number.isFinite(scheduledDeparture)) return undefined;
    return forecast(scheduledDeparture, item.etd, item.atd).time;
}

function anchorCandidates(index, station, item, reference, check) {
    const operator = item.operatorCode;
    if (typeof operator !== 'string' || !operator || !Number.isFinite(reference)) return [];
    const departure = hhmm(item.std);
    const arrival = hhmm(item.sta);
    if (!departure && !arrival) return [];
    const events = (departure ? index.departures : index.arrivals).get(station) || [];
    const candidates = [];
    for (const event of events) {
        check();
        if (event.service.operator !== operator || Math.abs(event.time - reference) > 12 * 60 * MINUTE) continue;
        const call = event.service.calls[event.index];
        if (departure && clock(call.departure) !== departure) continue;
        if (arrival && clock(call.arrival) !== arrival) continue;
        candidates.push({ scheduledServiceId: event.service.id, index: event.index, scheduledDeparture: call.departure });
    }
    return candidates;
}

/** Cheap board anchors deliberately retain ambiguity until ordered through-call
 * verification. LDBWS service IDs are station-relative opaque identifiers, not
 * timetable UIDs, and a cancellation on a board applies only at that station.
 */
export function discoverLiveMatches(network, boards, { now = Date.now(), check = () => {}, maxAgeMs = 90000 } = {}) {
    const index = prepareNetwork(network, check);
    const matches = [];
    const newest = new Map();
    for (const board of boards) {
        check();
        const generated = observationTime(board, now, maxAgeMs);
        if (!Number.isFinite(generated)) continue;
        for (const item of list(board.services)) {
            check();
            if (!item.serviceID) continue;
            const key = `${board.station}|${item.serviceID}`;
            const previous = newest.get(key);
            if (!previous || generated > previous.generated || (generated === previous.generated && cancelledAtStop(item))) {
                newest.set(key, { board, item, generated });
            }
        }
    }
    for (const { board, item, generated } of newest.values()) {
        const reference = generated + (board.window?.offsetMinutes || 0) * MINUTE;
        const candidates = anchorCandidates(index, board.station, item, reference, check);
        if (candidates.length) matches.push({ serviceID: item.serviceID, station: board.station, candidates, board, service: item });
    }
    return matches;
}

function throughPoints(groups) {
    const group = list(groups)[0];
    // Additional groups describe joining/dividing portions; do not attach them
    // to the selected occurrence or manufacture a through service.
    return group?.serviceChangeRequired ? [] : list(group?.callingPoint);
}

function mapPoints(calls, points, direction, first, last) {
    let states = [{ last: first - 1, count: 1, indices: [] }];
    for (const point of points) {
        if (!point.crs || !hhmm(point.st)) return { reason: 'mismatch' };
        const next = [];
        for (let index = first; index <= last; index++) {
            if (calls[index].station !== point.crs || clock(calls[index][direction]) !== hhmm(point.st)) continue;
            const previous = states.filter(state => state.last < index);
            const count = Math.min(2, previous.reduce((sum, state) => sum + state.count, 0));
            if (count) next.push({ last: index, count, indices: [...previous[0].indices, index] });
        }
        states = next;
        if (!states.length) return { reason: 'mismatch' };
    }
    return states.reduce((sum, state) => sum + state.count, 0) === 1
        ? { indices: states[0].indices } : { reason: 'ambiguous' };
}

function matchDetails(service, anchor, record) {
    const detail = record.detail;
    if (!detail || detail.crs !== record.station || detail.operatorCode !== service.operator) return { reason: 'mismatch' };
    const call = service.calls[anchor];
    if (hhmm(detail.std) && clock(call.departure) !== hhmm(detail.std)) return { reason: 'mismatch' };
    if (hhmm(detail.sta) && clock(call.arrival) !== hhmm(detail.sta)) return { reason: 'mismatch' };
    const previous = throughPoints(detail.previousCallingPoints);
    const subsequent = throughPoints(detail.subsequentCallingPoints);
    if (!previous.length && !subsequent.length) return { reason: 'mismatch' };
    const before = mapPoints(service.calls, previous, 'departure', 0, anchor - 1);
    const after = mapPoints(service.calls, subsequent, 'arrival', anchor + 1, service.calls.length - 1);
    if (before.reason === 'mismatch' || after.reason === 'mismatch') return { reason: 'mismatch' };
    if (before.reason || after.reason) return { reason: 'ambiguous' };
    return { previous, subsequent, before: before.indices, after: after.indices };
}

function eventUpdate(update, direction, scheduled, estimate, actual) {
    if (!Number.isFinite(scheduled)) return;
    const result = forecast(scheduled, estimate, actual);
    if (Number.isFinite(result.time)) {
        update[direction] = result.time;
        update[`${direction}Unknown`] = false;
    }
    if (result.unknown || ((hhmm(estimate) || hhmm(actual)) && !Number.isFinite(result.time))) update[`${direction}Unknown`] = true;
}

/** Match observations to one exact scheduled occurrence. Unmatched/ambiguous
 * observations remain explicit coverage gaps instead of changing another train.
 */
export function matchLiveObservations(network, { boards = [], details = [] }, { now = Date.now(), check = () => {}, ttlMs = 90000 } = {}) {
    const services = new Map(network.services.map(service => [service.id, service]));
    const detailByID = new Map(details.map(record => [`${record.station}|${record.serviceID}`, record]));
    const updates = new Map();
    const matches = discoverLiveMatches(network, boards, { now, check, maxAgeMs: ttlMs });
    let unmatchedCount = 0;
    const diagnosticCounts = { missingDetail: 0, staleDetail: 0, ambiguous: 0, mismatch: 0 };
    const missingDetails = [];
    const failedDetails = [];
    const recordDiagnostic = (reason, match) => {
        unmatchedCount++;
        diagnosticCounts[reason]++;
        const records = reason === 'missingDetail' ? missingDetails : failedDetails;
        if (records.length < MAX_DIAGNOSTICS) records.push({ reason, station: match.station, serviceID: match.serviceID,
            candidateServiceIds: [...new Set(match.candidates.map(candidate => candidate.scheduledServiceId))] });
    };
    for (const match of matches) {
        check();
        const record = detailByID.get(`${match.station}|${match.serviceID}`);
        const at = record ? observationTime(record, now, ttlMs) : NaN;
        if (!record) { recordDiagnostic('missingDetail', match); continue; }
        if (!Number.isFinite(at)) { recordDiagnostic('staleDetail', match); continue; }
        const evaluated = match.candidates.map(candidate => {
            const service = services.get(candidate.scheduledServiceId);
            const points = matchDetails(service, candidate.index, record);
            return { service, index: candidate.index, points };
        });
        const verified = evaluated.filter(candidate => !candidate.points.reason);
        const ambiguousMapping = evaluated.some(candidate => candidate.points.reason === 'ambiguous');
        if (verified.length !== 1 || ambiguousMapping) {
            recordDiagnostic(verified.length > 1 || ambiguousMapping
                ? 'ambiguous' : 'mismatch', match);
            continue;
        }
        const { service, index, points } = verified[0];
        const detail = record.detail;
        const update = updates.get(service.id) || { serviceId: service.id, calls: new Map(), warnings: [] };
        const put = (position, fields, observedAt = at) => {
            const previous = update.calls.get(position) || { index: position, observationTimes: {} };
            // Later station observations replace only the fields they actually
            // report, preserving verified forecasts from another board.
            for (const [field, value] of Object.entries(fields)) {
                if (value === undefined || observedAt < (previous.observationTimes[field] ?? -Infinity)) continue;
                if (field === 'cancelled' && observedAt === previous.observationTimes[field] && previous.cancelled) continue;
                previous[field] = value;
                previous.observationTimes[field] = observedAt;
            }
            previous.observedAt = Math.min(...Object.values(previous.observationTimes));
            update.calls.set(position, previous);
        };
        const current = { cancelled: cancelledAtStop(detail) ? true : detail.isCancelled, platform: detail.platform,
            warnings: [detail.cancelReason, detail.delayReason].filter(Boolean) };
        eventUpdate(current, 'arrival', service.calls[index].arrival, detail.eta, detail.ata);
        eventUpdate(current, 'departure', service.calls[index].departure, detail.etd, detail.atd);
        put(index, current);
        const boardCurrent = { cancelled: cancelledAtStop(match.service) ? true : match.service.isCancelled, platform: match.service.platform,
            warnings: [match.service.cancelReason, match.service.delayReason].filter(Boolean) };
        eventUpdate(boardCurrent, 'arrival', service.calls[index].arrival, match.service.eta, match.service.ata);
        eventUpdate(boardCurrent, 'departure', service.calls[index].departure, match.service.etd, match.service.atd);
        put(index, boardCurrent, observationTime(match.board, now, ttlMs));
        for (const [rows, indices, direction] of [[points.previous, points.before, 'departure'], [points.subsequent, points.after, 'arrival']]) {
            rows.forEach((point, position) => {
                const callIndex = indices[position];
                const fields = { cancelled: cancelledAtStop(point) ? true : point.isCancelled, warnings: [point.cancelReason, point.delayReason].filter(Boolean) };
                eventUpdate(fields, direction, service.calls[callIndex][direction], point.et, point.at);
                put(callIndex, fields);
            });
        }
        const latestFlags = observationTime(match.board, now, ttlMs) >= at ? { ...detail, ...match.service } : detail;
        if (latestFlags.uncertainty) update.warnings.push('This train may be affected by disruption; no confirmed change is available yet.');
        const later = [...update.calls.values()].filter(call => call.index > index);
        if (latestFlags.futureCancellation && !later.some(call => call.cancelled)) {
            update.unknownCancellationFromIndex = Math.min(update.unknownCancellationFromIndex ?? Infinity, index);
            update.warnings.push('A cancellation is reported later on this train, but the affected stops are not confirmed.');
        }
        if (latestFlags.futureDelay && !later.some(call => call.arrivalUnknown || call.departureUnknown
            || (Number.isFinite(call.arrival) && call.arrival > service.calls[call.index].arrival)
            || (Number.isFinite(call.departure) && call.departure > service.calls[call.index].departure))) {
            update.unknownDelayFromIndex = Math.min(update.unknownDelayFromIndex ?? Infinity, index);
            update.warnings.push('A delay is reported later on this train, but the affected times are not confirmed.');
        }
        updates.set(service.id, update);
    }
    const values = [...updates.values()].map(update => ({ ...update, calls: [...update.calls.values()].sort((a, b) => a.index - b.index)
        .map(({ observationTimes, ...call }) => call) }));
    // Missing details normally mean discovery did not request that unrelated
    // board service. Keep private, reason-specific evidence so the caller can
    // scope warnings to journeys actually being presented.
    const diagnostics = [...failedDetails, ...missingDetails].slice(0, MAX_DIAGNOSTICS);
    const id = createHash('sha256').update(JSON.stringify(values)).digest('hex');
    const observedAt = Math.min(now, ...values.flatMap(update => update.calls.map(call => call.observedAt)));
    return { id, observedAt, expiresAt: observedAt + ttlMs, services: values, warnings: [],
        matchedCount: values.length, unmatchedCount,
        unsafeMatchCount: diagnosticCounts.ambiguous + diagnosticCounts.mismatch,
        diagnostics, diagnosticCounts, diagnosticsTruncated: unmatchedCount > diagnostics.length };
}
