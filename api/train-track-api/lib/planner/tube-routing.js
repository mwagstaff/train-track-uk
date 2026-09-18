import { effectiveWindows, resolveConnection, stationAllowance, validateFixedLink, CONNECTION_POLICY } from './connections.js';
import { PlannerError } from './contract.js';

const MINUTE = 60000;
const CLOSURE_NOTE = 'Connections using a confirmed TfL closure were excluded; alternative routes and onward trains use the available services.';
export const TUBE_POLICY = 'tubetrack-v1-minor-contingency-5';
const walking = mode => ['walk', 'walking'].includes(mode);
export const tubeBoardings = steps => (steps ?? []).filter(step => !walking(step.mode)).length;
const iso = time => new Date(time).toISOString();
const distinct = values => [...new Set(values.filter(Boolean))];

function issues(journey) {
    const found = new Map();
    for (const segment of [journey, ...(journey.legs ?? [])]) {
        for (const issue of segment.disruption?.issues ?? []) {
            if (issue.affectsLeg === false || !applicable(issue, segment)) continue;
            const key = issue.id ?? `${issue.lineId}:${issue.description}`;
            const previous = found.get(key);
            if (!previous || issue.affectsLeg === true || previous.affectsLeg !== true) found.set(key, issue);
        }
    }
    return [...found.values()];
}

function applicable(issue, journey) {
    const start = Date.parse(journey.departureTime), end = Date.parse(journey.arrivalTime);
    return !issue.validityPeriods?.length || issue.validityPeriods.some(period =>
        (!period.from || Date.parse(period.from) <= end) && (!period.to || Date.parse(period.to) >= start));
}

function assessment(journey) {
    const active = issues(journey);
    const disrupted = [journey.disruption, ...(journey.legs ?? []).filter(leg => !walking(leg.mode)).map(leg => leg.disruption)];
    // When details explicitly place every issue outside this ride, an aggregate
    // status must not reintroduce those same delays or closures. Status-only
    // observations still carry useful information when no issue list is supplied.
    const statusOnly = disrupted.filter(value => !value?.issues?.length);
    // A line-wide part closure, even with scope=station, does not identify the
    // affected section. Only a full closure or explicit leg applicability can
    // establish that this returned connection cannot be used.
    const closed = active.some(issue => issue.affectsLeg !== false && (
        ['closed', 'closure', 'suspended', 'service closed'].includes(String(issue.statusDescription).toLowerCase())
        || (issue.affectsLeg === true && /closure|suspend/i.test(issue.statusDescription ?? ''))));
    const major = active.some(issue => ['major', 'severe'].includes(issue.severity))
        || statusOnly.some(value => value?.status === 'majorIssues');
    const minor = active.some(issue => issue.severity === 'minor')
        || statusOnly.some(value => value?.status === 'minorIssues');
    const unknown = disrupted.some(value => !value || !['noIssues', 'minorIssues', 'majorIssues'].includes(value.status)
        || !['complete', 'notApplicable'].includes(value.coverage)
        || value.sources?.some(source => !['available', 'notApplicable'].includes(source.status)))
        || active.some(issue => issue.stale);
    return { active, closed, minor, major, unknown, rank: closed ? 4 : major ? 3 : unknown ? 2 : minor ? 1 : 0 };
}

function warningText(journey) {
    return distinct([...issues(journey).map(issue => issue.description),
        ...(journey.warnings ?? []).map(warning => typeof warning === 'string' ? warning : warning.message),
        ...(journey.legs ?? []).flatMap(leg => (leg.warnings ?? []).map(warning => typeof warning === 'string' ? warning : warning.message))]);
}

function lineNames(journey) {
    return distinct((journey.legs ?? []).flatMap(leg => (leg.lines ?? []).map(line => line.name))).join(' and ');
}

function allowances(index, query, provider) {
    const origin = provider.mapping?.(query.from), destination = provider.mapping?.(query.to);
    const valid = value => Number.isFinite(value) && value >= 0;
    const exit = origin?.exitMinutes ?? stationAllowance(index, query.from);
    const entry = destination?.entryMinutes ?? stationAllowance(index, query.to);
    return { exitMinutes: (valid(exit) ? exit : 10) + (valid(origin?.accessWalkingMinutes) ? origin.accessWalkingMinutes : 0),
        entryMinutes: (valid(entry) ? entry : 10) + (valid(destination?.accessWalkingMinutes) ? destination.accessWalkingMinutes : 0),
        extraMinutes: query.extraConnectionMinutes ?? 0 };
}

function fallback(index, query, parts, response, notes) {
    const known = (response?.journeys ?? []).map(journey => response?.meta?.disruptionEvidenceForTime
        ? { ...journey, departureTime: response.meta.disruptionEvidenceForTime, arrivalTime: response.meta.disruptionEvidenceForTime,
            legs: journey.legs?.map(leg => ({ ...leg, departureTime: response.meta.disruptionEvidenceForTime,
                arrivalTime: response.meta.disruptionEvidenceForTime })) } : journey);
    if (known.length && known.every(journey => assessment(journey).closed)) {
        notes.add(CLOSURE_NOTE);
        return [];
    }
    const stations = new Map(index.stations);
    for (const [crs, minutes] of [[query.from, parts.exitMinutes], [query.to, parts.entryMinutes]]) {
        stations.set(crs, { ...stations.get(crs), minimumChangeMinutes: minutes });
    }
    const connection = resolveConnection({ ...index, stations }, query);
    if (!connection) return [];
    const warnings = distinct(known.flatMap(warningText));
    const note = response?.meta?.reason === 'requestLimit'
        ? 'This TfL connection could not be checked within the search allowance; the National Rail transfer allowance is shown. Check TfL before travelling.'
        : response?.status === 'unmapped'
        ? 'Detailed TfL directions are not available for this station connection; the National Rail transfer allowance is shown.'
        : 'TubeTrack directions are unavailable; the National Rail transfer allowance is shown. Check TfL before travelling.';
    return [{ ...connection, disruptionRank: 1, localJourney: { provider: 'tubetrack', status: 'unavailable',
        contingencyMinutes: 0, notes: [note, ...(warnings.length ? ['Previously reported disruption may still affect this transfer.'] : [])],
        warnings, steps: [], ...(response?.expiresAt ? { expiresAt: response.expiresAt } : {}) } }];
}

/** One resolver per routing operation. Network I/O happens only for eligible
 * National Rail Tube links. Alternatives retain their boarding-count/time
 * trade-offs, so a faster two-line route cannot erase a usable direct route. */
export function createTubeResolver(provider, { signal, check = () => {}, awaitIO = work => work(),
    budget = { limit: 12, used: 0 }, now = Date.now, lookupBudgetMs = 8000 } = {}) {
    const memo = new Map();
    let lookupMs = 0;
    const state = { limited: false, expiresAt: Infinity, used: false, notes: new Set() };
    const checkpoint = () => {
        check();
        if (signal?.aborted) throw new PlannerError('SEARCH_CANCELLED', 'TubeTrack search cancelled.', 499);
    };
    const resolve = async (index, query) => {
        checkpoint();
        state.used = true;
        const parts = allowances(index, query, provider);
        const reverse = query.direction === 'latest';
        const reference = reverse ? query.departure : query.arrival;
        if (!Number.isFinite(reference)) return [];
        const windows = effectiveWindows(index, query.from, query.to, reference).filter(window =>
            window.rule.mode === 'tubeTransfer' && (reverse
                ? window.start <= reference - (parts.entryMinutes + parts.extraMinutes) * MINUTE
                : window.end >= reference + parts.exitMinutes * MINUTE));
        const candidates = [];
        for (const window of reverse ? [...windows].reverse() : windows) {
            checkpoint();
            const time = reverse ? Math.min(window.end, reference - (parts.entryMinutes + parts.extraMinutes) * MINUTE)
                : Math.max(window.start, reference + parts.exitMinutes * MINUTE);
            if (query.arrival != null && time < query.arrival + parts.exitMinutes * MINUTE) continue;
            if (query.departure != null && time > query.departure - (parts.entryMinutes + parts.extraMinutes) * MINUTE) continue;
            const get = async instant => {
                const key = `${query.from}:${query.to}:${reverse}:${instant}`;
                if (!memo.has(key)) {
                    const began = performance.now();
                    memo.set(key, await provider.lookup({ from: query.from, to: query.to,
                        time: iso(instant), timeMode: reverse ? 'arriveBy' : 'departAt', signal,
                        awaitIO, budget: lookupMs >= lookupBudgetMs ? { limit: 0, used: 0 } : budget }));
                    lookupMs += performance.now() - began;
                }
                checkpoint();
                const response = memo.get(key);
                const expires = Date.parse(response.expiresAt);
                if (Number.isFinite(expires)) state.expiresAt = Math.min(state.expiresAt, expires);
                if ((response.reason ?? response.meta?.reason) === 'requestLimit' || budget.used >= budget.limit) state.limited = true;
                return response;
            };
            let response = await get(time);
            if (response.status !== 'available' || response.meta?.stale || Date.parse(response.expiresAt) <= now()) {
                return fallback(index, query, parts, response, state.notes);
            }
            let options = response.journeys ?? [];
            // Reserve the contingency in an arrive-by query too. A second query
            // exposes an earlier train instead of only rejecting the latest one.
            if (reverse && options.some(option => assessment(option).minor)) {
                const earlier = await get(time - 5 * MINUTE);
                if (earlier.status === 'available' && !earlier.meta?.stale && Date.parse(earlier.expiresAt) > now()) {
                    options = [...options, ...(earlier.journeys ?? [])];
                    response = { ...response, expiresAt: iso(Math.min(Date.parse(response.expiresAt), Date.parse(earlier.expiresAt))),
                        meta: { ...response.meta, updatedAt: [response.meta?.updatedAt, earlier.meta?.updatedAt].filter(Boolean).sort()[0] } };
                }
            }
            // The first response can expire while the earlier-departure request
            // is in flight; never publish its directions with a newer response.
            if (Date.parse(response.expiresAt) <= now()) return fallback(index, query, parts, response, state.notes);
            const all = options.map(option => ({ option, assessment: assessment(option) }));
            const usable = all.filter(value => !value.assessment.closed);
            if (usable.length < all.length) state.notes.add(CLOSURE_NOTE);
            const fastest = all.reduce((best, value) => !best || (reverse
                ? Date.parse(value.option.departureTime) > Date.parse(best.option.departureTime)
                : Date.parse(value.option.arrivalTime) < Date.parse(best.option.arrivalTime)) ? value : best, null);
            for (const { option, assessment: risk } of usable) {
                const movementStart = Date.parse(option.departureTime), movementEnd = Date.parse(option.arrivalTime);
                const contingencyMinutes = risk.minor ? 5 : 0;
                const start = reverse ? movementStart - parts.exitMinutes * MINUTE : query.arrival;
                const end = movementEnd + (parts.entryMinutes + parts.extraMinutes + contingencyMinutes) * MINUTE;
                if (![start, end, movementStart, movementEnd].every(Number.isFinite) || movementEnd < movementStart
                    || movementStart < start + parts.exitMinutes * MINUTE
                    || movementStart < window.start || movementEnd + contingencyMinutes * MINUTE > window.end
                    || (query.arrival != null && start < query.arrival) || (query.departure != null && end > query.departure)) continue;
                const actualWindow = effectiveWindows(index, query.from, query.to, movementStart)
                    .find(candidate => movementStart >= candidate.start && movementStart < candidate.end);
                if (actualWindow?.rule.id !== window.rule.id) continue;
                const notes = distinct([provider.mapping?.(query.from)?.accessNote, provider.mapping?.(query.to)?.accessNote]);
                if (contingencyMinutes) notes.push(`An extra 5 minutes is allowed for minor delays${lineNames(option) ? ` on ${lineNames(option)}` : ''}. Connection times include this contingency.`);
                if (fastest && fastest.assessment.rank > risk.rank && fastest.option.id !== option.id) {
                    notes.push(`Using ${lineNames(option) || 'this route'} to avoid reported disruption${lineNames(fastest.option) ? ` on ${lineNames(fastest.option)}` : ''}. Onward connections use this alternative's timings.`);
                }
                if (risk.major) notes.push('Major disruption is reported on this route. Allow extra time and check TfL before travelling.');
                if (risk.unknown) notes.push('Disruption information is incomplete or out of date; an unaffected service cannot be confirmed.');
                if (!risk.unknown && !risk.major && !risk.minor
                    && option.disruption?.sources?.some(source => source.source === 'plannedWorks' && source.status === 'available')
                    && option.disruption?.sources?.some(source => source.source === 'realtime' && source.status === 'notApplicable')) {
                    notes.push('No planned disruption is reported for this route. Check again nearer departure for live conditions.');
                }
                const steps = option.legs ?? [];
                const boardings = tubeBoardings(steps);
                candidates.push({ from: query.from, to: query.to, mode: 'tubeTransfer', start, end,
                    movementStart, movementEnd, minutes: (end - start) / MINUTE, boardings,
                    ruleId: window.rule.id, sourceRef: window.rule.sourceRef, policy: CONNECTION_POLICY,
                    breakdown: { ...parts, travelMinutes: (movementEnd - movementStart) / MINUTE,
                        contingencyMinutes, waitingMinutes: (movementStart - start) / MINUTE - parts.exitMinutes },
                    localJourney: { provider: 'tubetrack', policy: TUBE_POLICY, status: 'available', id: option.id,
                        departureTime: option.departureTime, arrivalTime: option.arrivalTime,
                        durationMinutes: (movementEnd - movementStart) / MINUTE, changes: Math.max(0, boardings - 1),
                        contingencyMinutes, notes, warnings: warningText(option), steps,
                        disruption: option.disruption, updatedAt: response.meta?.updatedAt, expiresAt: response.expiresAt,
                        attribution: response.attribution ?? 'Powered by the Transport for London Journey Planner API' },
                    disruptionRank: risk.major ? 2 : risk.unknown ? 1 : 0 });
            }
            // The API searches beyond the requested instant. Later ALF windows
            // are useful only if this one produced no feasible option.
            if (candidates.length) break;
        }
        // Keep alternatives with fewer boardings, even if slower. Prefer less
        // disruption only among options that fit the same downstream context.
        return candidates.filter(candidate => !candidates.some(other => other !== candidate
            && other.boardings <= candidate.boardings && other.disruptionRank <= candidate.disruptionRank
            && (reverse ? other.start >= candidate.start : other.end <= candidate.end)
            && (other.boardings < candidate.boardings || other.disruptionRank < candidate.disruptionRank
                || (reverse ? other.start > candidate.start : other.end < candidate.end))))
            .sort((a, b) => a.disruptionRank - b.disruptionRank || (reverse ? b.start - a.start : a.end - b.end) || a.boardings - b.boardings);
    };
    resolve.state = state;
    return resolve;
}

export function validateTubeConnection(index, connection, extraConnectionMinutes = 0) {
    const { from, to, start, end, movementStart, movementEnd, ruleId, mode, breakdown: parts, localJourney: local } = connection;
    if (local?.status === 'unavailable' && parts && mode === 'tubeTransfer') {
        const stations = new Map(index.stations);
        for (const [crs, minutes] of [[from, parts.exitMinutes], [to, parts.entryMinutes]]) {
            if (!Number.isFinite(minutes) || minutes < 0) return false;
            stations.set(crs, { ...stations.get(crs), minimumChangeMinutes: minutes });
        }
        return validateFixedLink({ ...index, stations }, connection, extraConnectionMinutes);
    }
    if (mode !== 'tubeTransfer' || local?.status !== 'available' || local.policy !== TUBE_POLICY
        || !Array.isArray(local.steps) || !local.steps.length || !parts) return false;
    const window = effectiveWindows(index, from, to, movementStart).find(window =>
        window.rule.id === ruleId && window.rule.mode === mode && movementStart >= window.start
        && movementEnd + (parts.contingencyMinutes ?? 0) * MINUTE <= window.end);
    if (!window || ![start, end, movementStart, movementEnd].every(Number.isFinite)
        || parts.exitMinutes < 0 || parts.entryMinutes < 0 || parts.extraMinutes !== extraConnectionMinutes
        || ![0, 5].includes(parts.contingencyMinutes) || local.contingencyMinutes !== parts.contingencyMinutes
        || movementStart !== Date.parse(local.departureTime) || movementEnd !== Date.parse(local.arrivalTime)
        || parts.travelMinutes !== (movementEnd - movementStart) / MINUTE
        || movementStart < start + parts.exitMinutes * MINUTE
        || end !== movementEnd + (parts.entryMinutes + parts.extraMinutes + parts.contingencyMinutes) * MINUTE
        || parts.waitingMinutes !== (movementStart - start) / MINUTE - parts.exitMinutes) return false;
    let previous = movementStart;
    for (const step of local.steps) {
        const departure = Date.parse(step.departureTime), arrival = Date.parse(step.arrivalTime);
        if (!Number.isFinite(departure) || !Number.isFinite(arrival) || departure < previous || arrival < departure || arrival > movementEnd) return false;
        previous = arrival;
    }
    return previous === movementEnd;
}
