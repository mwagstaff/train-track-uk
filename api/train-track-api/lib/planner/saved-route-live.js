import { getTrainTimes } from '../realtime-trains-api.js';
import { qualifySiriResult } from '../siri-departure-policy.js';
import { PlannerLiveProvider, createLiveRequestBudget } from './live-provider.js';
import { createConnectionIndex, resolveConnection } from './connections.js';
import { journeyID, PlannerError } from './contract.js';
import { presentLivePage } from './live-coverage.js';
import { createTubeResolver, tubeBoardings } from './tube-routing.js';

const MINUTE = 60000, HOUR = 60 * MINUTE, DAY = 24 * HOUR;
const MAX_PAIRS = 12, MAX_DETAILS = 32, MAX_OPTIONS = 8, MAX_STATES = 32;
const clock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const date = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit' });
const instant = value => typeof value === 'number' ? value : Date.parse(value);
const iso = value => new Date(value).toISOString();
const unique = values => [...new Set(values.filter(Boolean))];
const text = value => typeof value === 'string' ? value.trim().toLowerCase() : '';
const isCancelled = value => value?.isCancelled === true || [value?.et, value?.etd, value?.eta].some(item => text(item) === 'cancelled');
const mode = row => row.serviceType === 'bus' ? 'replacementBus' : row.serviceType === 'train' || !row.serviceType ? 'rail' : null;
const rail = leg => leg.kind === 'vehicle' && ['rail', 'replacementBus'].includes(leg.mode);
const pair = (from, to) => `${from}:${to}`;
const boardings = leg => leg.kind === 'vehicle' ? 1 : leg.mode === 'tubeTransfer' && leg.localJourney?.status === 'available'
    ? tubeBoardings(leg.localJourney.steps) : ['interchange', 'walk'].includes(leg.mode) ? 0 : 1;
const disruptionRank = journey => Math.max(0, ...(journey.legs ?? []).map(leg => leg.disruptionRank
    ?? (leg.localJourney?.disruption?.status === 'majorIssues' ? 2 : leg.localJourney?.disruption?.status === 'unknown' ? 1 : 0)));
const scheduled = leg => ({ ...leg, departure: leg.scheduledDeparture ?? leg.departure, arrival: leg.scheduledArrival ?? leg.arrival,
    live: undefined, tracking: undefined, warnings: (leg.warnings ?? []).filter(value => !/live|cancel|delay/i.test(value)),
    callingPoints: leg.callingPoints?.map(call => ({ ...call, arrival: call.scheduledArrival ?? call.arrival,
        departure: call.scheduledDeparture ?? call.departure, live: undefined })) });

// An unqualified local clock in the repeated autumn hour cannot identify an
// occurrence. Reject it rather than attach a forecast to the other train.
function clockNear(value, reference) {
    if (typeof value !== 'string' || !/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value.trim()) || !Number.isFinite(reference)) return null;
    const parsed = value.trim(), [hour, minute] = parsed.split(':').map(Number);
    const day = Math.floor(reference / DAY) * DAY, candidates = [];
    for (const offset of [-1, 0, 1]) for (const zone of [0, 60]) {
        const time = day + offset * DAY + (hour * 60 + minute - zone) * MINUTE;
        if (clock.format(time) === parsed && Math.abs(time - reference) <= 12 * HOUR) candidates.push(time);
    }
    candidates.sort((a, b) => Math.abs(a - reference) - Math.abs(b - reference));
    if (!candidates.length || candidates.some(value => value !== candidates[0] && date.format(value) === date.format(candidates[0]))) return null;
    return candidates[0];
}

function forecast(scheduledTime, estimate, actual) {
    const value = actual || estimate;
    return text(value) === 'on time' ? scheduledTime : clockNear(value, scheduledTime);
}

function rowTime(row, now) {
    const observed = instant(row.siri?.providerObservedAt);
    const departure = clockNear(row.departure_time?.scheduled,
        (Number.isFinite(observed) ? observed : now) + (row.siri?.requestedOffsetMinutes ?? 0) * MINUTE);
    return { scheduled: departure, expected: forecast(departure, row.departure_time?.estimated, row.departure_time?.actual),
        departed: Boolean(row.departure_time?.actual) };
}

function currentRows(board, now, realtime = 'apply', allowedModes) {
    return (board.departures ?? []).filter(row => {
        if (!mode(row) || allowedModes && !allowedModes.includes(mode(row))) return false;
        const time = rowTime(row, now);
        const departure = realtime === 'ignore' ? time.scheduled : time.expected ?? time.scheduled;
        const delayedWithoutTime = realtime !== 'ignore' && text(row.departure_time?.estimated) === 'delayed'
            && departure >= now - 2 * HOUR;
        return !time.departed && Number.isFinite(departure) && (departure >= now || delayedWithoutTime) && departure <= now + 4 * HOUR;
    }).sort((a, b) => {
        const first = rowTime(a, now), second = rowTime(b, now);
        return realtime === 'ignore' ? first.scheduled - second.scheduled
            : (first.expected ?? first.scheduled) - (second.expected ?? second.scheduled);
    });
}

function fresh(board) {
    return !board.error && !board.siri?.failureReason && ['live', 'partial'].includes(board.dataStatus);
}

function publicSnapshot(board, departures = board.departures ?? []) {
    return { departures: departures.map(({ siri, ...row }) => row), dataStatus: board.dataStatus,
        lastSuccessfulUpdate: board.lastSuccessfulUpdate ?? null };
}

function ordered(points, via) {
    let next = 0, previous;
    for (const point of points) {
        if (point !== previous && point === via[next]) next++;
        previous = point;
    }
    return next === via.length;
}

function detailPaths(record, from, to, via = []) {
    const detail = record?.detail;
    if (!detail || detail.crs !== from) return [];
    // Groups describe separate portions, not consecutive sections. Never join
    // stops across branches or turn a required change into a direct service.
    return (detail.subsequentCallingPoints ?? []).filter(group => !group.serviceChangeRequired)
        .flatMap(group => {
            const end = group.callingPoint.findIndex(point => point.crs === to);
            if (end < 0) return [];
            const points = group.callingPoint.slice(0, end + 1);
            return ordered(points.map(point => point.crs), [...via, to]) ? [{ group, points }] : [];
        });
}

function completeCallingPoints(detail, path, template, departure) {
    // Match ServiceDetails.stationBranches in the app: the first previous
    // portion and current station are shared with each separate following
    // branch. Retain stops outside the ridden section for its final, unique
    // train check; never flatten joining/dividing portions into one service.
    const previous = detail.previousCallingPoints?.[0];
    if (previous?.serviceChangeRequired) return undefined;
    const station = crs => crs === template.from.crs ? template.from : crs === template.to.crs ? template.to
        : template.serviceCallingPoints?.find(call => call.station.crs === crs)?.station ?? { crs, name: crs };
    const before = [];
    let reference = departure;
    for (const point of [...(previous?.callingPoint ?? [])].reverse()) {
        let time = clockNear(point.st, reference);
        if (time !== null && time > reference) time = clockNear(point.st, reference - 12 * HOUR);
        if (time === null || time > reference || departure - time > DAY) return undefined;
        before.push({ station: station(point.crs), departure: iso(time), arrival: null });
        reference = time;
    }
    const after = [];
    reference = departure;
    for (const point of path.group.callingPoint) {
        let time = clockNear(point.st, reference);
        if (time !== null && time < reference) time = clockNear(point.st, reference + 12 * HOUR);
        if (time === null || time < reference || time - departure > DAY) return undefined;
        after.push({ station: station(point.crs), arrival: iso(time), departure: null });
        reference = time;
    }
    return [...before.reverse(), { station: template.from, departure: iso(departure), arrival: null }, ...after];
}

// Later trains on the same route are alternatives for making a connection, not
// separate departure options. Retain their templates in the plan cache, but
// show only the earliest arrival for each starting train and passenger route.
export function earliestRouteJourneys(journeys) {
    const best = new Map();
    for (const journey of journeys) {
        const first = journey.legs?.find(leg => leg.kind === 'vehicle');
        const firstService = first?.scheduledServiceId ?? first?.serviceId;
        const route = journey.legs?.map(leg => [leg.kind, leg.mode, leg.from.crs, leg.to.crs, leg.operator,
            leg.callingPoints?.map(call => call.station.crs)]);
        // Do not assume two trains are the same when their identity is absent.
        const key = firstService && Number.isFinite(instant(journey.departure)) && Number.isFinite(instant(journey.arrival))
            ? JSON.stringify([instant(journey.departure), firstService, first.originDate,
                instant(first.scheduledDeparture ?? first.departure), journey.changes, route]) : journey;
        const existing = best.get(key);
        if (!existing || disruptionRank(journey) < disruptionRank(existing)
            || disruptionRank(journey) === disruptionRank(existing) && instant(journey.arrival) < instant(existing.arrival)) best.set(key, journey);
    }
    return [...best.values()];
}

function rank(journeys, limit = 5) {
    const seen = new Map();
    for (const journey of earliestRouteJourneys(journeys)) {
        const key = JSON.stringify(journey.legs.map(leg => [leg.kind, leg.mode, leg.serviceId, leg.from.crs, leg.to.crs, leg.departure, leg.arrival]));
        const existing = seen.get(key);
        if (!existing || disruptionRank(journey) < disruptionRank(existing)) seen.set(key, journey);
    }
    return [...seen.values()].sort((a, b) => disruptionRank(a) - disruptionRank(b) || instant(a.arrival) + (a.changes ? 10 * MINUTE : 0)
        - instant(b.arrival) - (b.changes ? 10 * MINUTE : 0) || instant(a.departure) - instant(b.departure)).slice(0, limit);
}

/** Live saved boards only perform bounded pair/detail lookups. A cached plan
 * supplies route patterns and connection rules; this class never resolves a
 * national timetable or invokes its router. */
export class SavedRouteLive {
    constructor({ getDepartures = getTrainTimes, provider = new PlannerLiveProvider(), tubeProvider = null, now = Date.now } = {}) {
        Object.assign(this, { getDepartures, provider, tubeProvider, now });
    }

    context(signal) {
        const boards = new Map(), details = new Map(), budget = createLiveRequestBudget(MAX_DETAILS);
        const state = { oldest: Infinity, limited: false };
        const check = () => { if (signal?.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Saved journey refresh cancelled.', 499); };
        const board = async (from, to) => {
            check();
            const key = pair(from, to);
            if (!boards.has(key)) {
                if (boards.size >= MAX_PAIRS) { state.limited = true; return { departures: [], dataStatus: 'unavailable', error: 'Live lookup limit reached.' }; }
                boards.set(key, Promise.resolve().then(() => this.getDepartures(from, to, { requireFresh: true, signal }))
                    .then(value => qualifySiriResult(value, this.now()), () => ({ departures: [], dataStatus: 'unavailable', error: 'Live lookup failed.' })));
            }
            const value = await boards.get(key); check();
            if (fresh(value)) state.oldest = Math.min(state.oldest, instant(value.siri.providerObservedAt), instant(value.siri.fetchedAt));
            return value;
        };
        const detail = async (row, station) => {
            check();
            if (!row.serviceID) return null;
            const key = `${station}:${row.serviceID}`;
            if (!details.has(key)) {
                details.set(key, this.provider.fetchDetails([{ station, serviceID: row.serviceID }], { signal, budget })
                    .then(value => {
                        state.limited ||= Boolean(value.limited);
                        return value.details?.find(record => record.station === station && record.serviceID === row.serviceID);
                    }));
            }
            const value = await details.get(key); check();
            const observed = instant(value?.generatedAt);
            if (!Number.isFinite(observed) || observed > this.now() + 5000 || this.now() - observed > 60000) return null;
            state.oldest = Math.min(state.oldest, observed);
            return value;
        };
        const resolveTubeConnection = this.tubeProvider ? createTubeResolver(this.tubeProvider,
            { signal, check, now: this.now, budget: { limit: 32, used: 0 } }) : null;
        return Object.assign(state, { board, detail, check, resolveTubeConnection });
    }

    async direct(request, { signal } = {}) {
        const context = this.context(signal), now = this.now();
        const board = await context.board(request.origin, request.destination);
        if (!fresh(board)) return { status: 'unknown', snapshot: publicSnapshot(board),
            error: { code: 'LIVE_UNAVAILABLE', message: 'Live departures could not be refreshed.' } };
        let rows = currentRows(board, now, request.realtime, request.allowedModes);
        let uncertain = (board.departures ?? []).some(row => mode(row) && !Number.isFinite(rowTime(row, now).scheduled));
        if (request.via?.length) {
            uncertain ||= rows.length > MAX_OPTIONS;
            const checked = await Promise.all(rows.slice(0, MAX_OPTIONS).map(async row => {
                const record = await context.detail(row, request.origin);
                if (!record) { uncertain = true; return null; }
                if (record.detail.std !== row.departure_time?.scheduled) { uncertain = true; return null; }
                const paths = detailPaths(record, request.origin, request.destination, request.via);
                if (paths.length > 1) { uncertain = true; return null; }
                if (paths.length !== 1) return null;
                const cancelled = paths[0].group.assocIsCancelled || isCancelled(record.detail)
                    || paths[0].points.some(point => [...request.via, request.destination].includes(point.crs) && isCancelled(point));
                return cancelled ? { ...row, isCancelled: true } : row;
            }));
            rows = checked.filter(Boolean);
        }
        const availableRows = rows.filter(row => request.realtime === 'ignore'
            || !row.isCancelled && text(row.departure_time?.estimated) !== 'cancelled');
        const first = availableRows[0], firstTimes = first ? rowTime(first, now) : null;
        const departureAt = firstTimes && (request.realtime === 'ignore'
            ? firstTimes.scheduled : firstTimes.expected ?? firstTimes.scheduled);
        const available = availableRows.length > 0;
        return { status: available ? 'available' : board.dataStatus === 'live' && !uncertain ? 'empty' : 'unknown',
            snapshot: publicSnapshot(board, rows), expiresAt: iso(context.oldest + 60000),
            ...(Number.isFinite(departureAt) ? { departureAt: iso(departureAt) } : {}),
            compareWithConnections: available && availableRows.every(row => mode(row) === 'replacementBus') };
    }

    async refresh(plan, request, { signal } = {}) {
        const context = this.context(signal), now = this.now(), realtime = request.realtime ?? 'apply';
        const source = plan.result, connections = createConnectionIndex(plan.connections);
        const topologies = new Map(), examples = new Map();
        for (const journey of (source.journeys ?? []).slice(0, 5)) {
            const key = JSON.stringify(journey.legs.map(leg => [leg.kind, leg.mode, leg.from.crs, leg.to.crs]));
            if (!topologies.has(key)) topologies.set(key, journey);
            for (const leg of journey.legs.filter(rail)) {
                const key = pair(leg.from.crs, leg.to.crs);
                if (!examples.has(key)) examples.set(key, []);
                examples.get(key).push(leg);
            }
        }
        const options = new Map();
        for (const [key, legs] of examples) {
            context.check();
            options.set(key, await this.legOptions(legs, request, context, now));
        }
        const journeys = [], disrupted = [];
        let truncated = false;
        for (const original of topologies.values()) {
            context.check();
            let states = [{ legs: [], pending: [], blocked: false }];
            for (const [templateIndex, template] of original.legs.entries()) {
                if (template.kind === 'transfer') { states = states.map(state => ({ ...state, pending: [...state.pending, template] })); continue; }
                const choices = (options.get(pair(template.from.crs, template.to.crs)) ?? [scheduled(template)])
                    .filter(leg => !request.allowedModes || request.allowedModes.includes(leg.mode));
                const next = [];
                for (const state of states) for (const choice of choices) {
                    const alternatives = await this.transfers(state.pending, state.legs.at(-1), choice, connections, request, now, context);
                    if (!state.pending.length && state.legs.length) continue;
                    if (instant(choice.departure) < (instant(state.legs.at(-1)?.arrival) || now)) continue;
                    for (const transfers of alternatives) {
                        const legs = [...state.legs, ...transfers, choice];
                        const remaining = original.legs.slice(templateIndex + 1)
                            .reduce((sum, leg) => sum + (leg.mode === 'tubeTransfer' ? 0 : boardings(leg)), 0);
                        if (legs.reduce((sum, leg) => sum + boardings(leg), remaining) > (request.maxChanges ?? 5) + 1) continue;
                        next.push({ legs, pending: [],
                            blocked: state.blocked || realtime !== 'ignore' && Boolean(choice.live?.cancelled || choice.live?.status === 'unknown') });
                    }
                }
                next.sort((a, b) => disruptionRank(a) - disruptionRank(b) || instant(a.legs.at(-1).arrival) - instant(b.legs.at(-1).arrival));
                truncated ||= next.length > MAX_STATES;
                states = next.slice(0, MAX_STATES);
            }
            for (const state of states) {
                const tails = await this.transfers(state.pending, state.legs.at(-1), null, connections, request, now, context);
                for (const tail of tails) {
                    const legs = [...state.legs, ...tail];
                    if (!legs.length || legs[0].from.crs !== request.origin || legs.at(-1).to.crs !== request.destination) continue;
                    const visits = legs.flatMap(leg => leg.kind === 'vehicle' ? (leg.callingPoints ?? []).filter(call =>
                        realtime === 'ignore' || !call.live?.cancelled).map(call => call.station.crs) : [leg.from.crs, leg.to.crs]);
                    if (!ordered(visits, request.via ?? [])) continue;
                    const departure = legs[0].departure, arrival = legs.at(-1).arrival;
                    if (instant(departure) < now || instant(arrival) < instant(departure) || instant(arrival) - instant(departure) > DAY) continue;
                    const warnings = unique(legs.flatMap(leg => leg.warnings ?? []));
                    const journey = { departure, arrival, durationMinutes: (instant(arrival) - instant(departure)) / MINUTE,
                        changes: Math.max(0, legs.reduce((sum, leg) => sum + boardings(leg), 0) - 1),
                        legs, ...(warnings.length ? { warnings } : {}) };
                    if (journey.changes > (request.maxChanges ?? 5)) continue;
                    (state.blocked ? disrupted : journeys).push(journey);
                }
            }
        }
        const selected = rank(journeys), disruptedPage = rank(disrupted);
        const checked = [...selected, ...disruptedPage].flatMap(journey => journey.legs).filter(leg => leg.live);
        const observed = checked.length ? Math.min(...checked.map(leg => instant(leg.live.updatedAt))) : null;
        const live = { mode: realtime, status: checked.length ? 'partial' : 'unavailable', windowHours: 4,
            ...(observed !== null ? { updatedAt: iso(observed), expiresAt: iso(observed + 60000) } : {}),
            warnings: realtime === 'ignore' ? ['Delays and cancellations are shown, but these routes use scheduled times.'] : [] };
        const page = presentLivePage([...selected, ...disruptedPage], live, { now });
        const tubeExpiry = Math.min(...page.journeys.flatMap(journey => journey.legs)
            .filter(leg => leg.localJourney?.status === 'available').map(leg => instant(leg.localJourney.expiresAt)).filter(Number.isFinite));
        if (Number.isFinite(tubeExpiry)) page.live.expiresAt = iso(Math.min(tubeExpiry, instant(page.live.expiresAt) || Infinity));
        const identify = journey => ({ ...journey, id: journeyID(journey, source.dataset.version, page.live) });
        const includesLive = ['live', 'partial'].includes(page.live.status);
        truncated ||= context.limited || context.resolveTubeConnection?.state?.limited;
        const dataset = { ...source.dataset, scheduledOnly: !includesLive,
            warnings: (source.dataset.warnings ?? []).filter(value => !includesLive || (!value.startsWith('National Rail times are scheduled;')
                && value !== 'Scheduled timetable only. Live delays and changes are not included.')) };
        return { ...source, ...page, dataset, journeys: page.journeys.slice(0, selected.length).map(identify),
            disruptedJourneys: page.journeys.slice(selected.length).map(identify),
            search: { ...source.search, ...request, time: iso(now), realtime,
                window: { from: iso(now), to: iso(now + 4 * HOUR) }, searchTruncated: truncated || source.search?.searchTruncated || false },
            warnings: unique([...dataset.warnings, ...page.live.warnings,
                ...(context.resolveTubeConnection?.state?.notes ?? []),
                ...(truncated ? ['More journey options may exist.'] : [])]), pagination: {} };
    }

    async legOptions(examples, request, context, now) {
        const [first] = examples, realtime = request.realtime ?? 'apply';
        const later = examples.filter(leg => instant(leg.scheduledDeparture ?? leg.departure) > now + 4 * HOUR).map(scheduled);
        if (examples.every(leg => instant(leg.scheduledDeparture ?? leg.departure) > now + 4 * HOUR)) return later;
        const board = await context.board(first.from.crs, first.to.crs);
        const fallback = () => examples.map(scheduled).filter(leg => instant(leg.departure) >= now).map(leg => ({ ...leg,
            warnings: unique([...(leg.warnings ?? []), ...(instant(leg.departure) <= now + 4 * HOUR
                ? ['Live times could not be refreshed; scheduled times are shown.'] : [])]) }));
        if (!fresh(board)) return fallback();
        const available = currentRows(board, now, realtime, request.allowedModes);
        context.limited ||= available.length > MAX_OPTIONS;
        const rows = available.slice(0, MAX_OPTIONS);
        const represents = (row, leg) => mode(row) === leg.mode
            && rowTime(row, now).scheduled === instant(leg.scheduledDeparture ?? leg.departure);
        // A provider can report a fresh/live board while returning fewer rows
        // than the cached six-hour plan. Treat unmatched planned trains like a
        // partial response so they remain available as scheduled fallbacks.
        let missing = board.dataStatus === 'partial' || examples.some(leg => {
            const departure = instant(leg.scheduledDeparture ?? leg.departure);
            return departure >= now && departure <= now + 4 * HOUR && !rows.some(row => represents(row, leg));
        });
        const values = await Promise.all(rows.map(async row => {
            const record = await context.detail(row, first.from.crs);
            if (!record) { missing = true; return null; }
            const paths = detailPaths(record, first.from.crs, first.to.crs);
            if (paths.length !== 1) { missing = true; return null; }
            const value = this.vehicle(row, record, paths[0], first, request, now);
            if (!value) missing = true;
            return value;
        }));
        return [...values.filter(Boolean), ...later, ...(missing ? fallback().filter(leg => !values.some(value => value
            && value.mode === leg.mode && value.from.crs === leg.from.crs && value.to.crs === leg.to.crs
            && instant(value.scheduledDeparture ?? value.departure) === instant(leg.departure))) : [])];
    }

    vehicle(row, record, path, template, request, now) {
        const times = rowTime(row, now), detail = record.detail, realtime = request.realtime ?? 'apply';
        if (!Number.isFinite(times.scheduled) || detail.std !== row.departure_time?.scheduled) return null;
        const observed = Math.min(instant(record.generatedAt), instant(row.siri?.providerObservedAt));
        if (!Number.isFinite(observed)) return null;
        const stop = (station, scheduledTime, expected, cancelled, direction, warning = []) => ({ station,
            [direction]: iso(realtime === 'ignore' || !Number.isFinite(expected) ? scheduledTime : expected),
            [`scheduled${direction[0].toUpperCase()}${direction.slice(1)}`]: iso(scheduledTime),
            live: { status: cancelled ? 'cancelled' : !Number.isFinite(expected) ? 'unknown' : expected > scheduledTime ? 'delayed' : 'onTime',
                updatedAt: iso(observed), cancelled, partCancelled: false, warnings: warning,
                ...(Number.isFinite(expected) ? { [direction]: iso(expected), [`${direction}DelayMinutes`]: (expected - scheduledTime) / MINUTE } : {}) } });
        const boardCancelled = row.isCancelled === true || text(row.departure_time?.estimated) === 'cancelled' || isCancelled(detail);
        const calls = [stop(template.from, times.scheduled, times.expected, boardCancelled, 'departure')];
        let previous = times.scheduled;
        for (const point of path.points) {
            let scheduledTime = clockNear(point.st, previous);
            if (scheduledTime === null) return null;
            if (scheduledTime < previous) scheduledTime = clockNear(point.st, previous + 12 * HOUR);
            if (scheduledTime === null || scheduledTime < previous || scheduledTime - times.scheduled > 24 * HOUR) return null;
            previous = scheduledTime;
            calls.push(stop(point.crs === template.to.crs ? template.to : { crs: point.crs, name: point.locationName ?? point.crs },
                scheduledTime, forecast(scheduledTime, point.et, point.at), isCancelled(point) || path.group.assocIsCancelled === true,
                'arrival', [point.cancelReason, point.delayReason].filter(Boolean)));
        }
        const last = calls.at(-1), departure = calls[0].departure, arrival = last.arrival;
        if (instant(arrival) < instant(departure)) return null;
        const cancelled = boardCancelled || last.live.cancelled;
        const partCancelled = calls.some(call => call.live.cancelled) || Boolean(detail.futureCancellation);
        const uncertain = detail.futureCancellation && !calls.some(call => call.live.cancelled) || detail.futureDelay
            && !calls.some(call => call.live.status === 'delayed') || !Number.isFinite(times.expected) || !last.live.arrival;
        const warnings = unique([row.cancelReason, row.delayReason, detail.cancelReason, detail.delayReason,
            ...calls.flatMap(call => call.live.warnings), ...(cancelled ? ['This part of the train journey is cancelled.'] : []),
            ...(partCancelled && !cancelled ? ['This train has cancellations at other stops.'] : []),
            ...(uncertain ? ['Live times are not confirmed for every part of this train journey.'] : [])]);
        const live = { status: cancelled ? 'cancelled' : uncertain ? 'unknown' : calls.some(call => call.live.status === 'delayed') ? 'delayed'
            : partCancelled ? 'partCancelled' : 'onTime', updatedAt: iso(observed), cancelled, partCancelled, warnings,
            ...(Number.isFinite(times.expected) ? { departure: iso(times.expected), departureDelayMinutes: (times.expected - times.scheduled) / MINUTE } : {}),
            ...(last.live.arrival ? { arrival: last.live.arrival, arrivalDelayMinutes: last.live.arrivalDelayMinutes } : {}),
            ...(row.platform ? { platform: row.platform } : {}), ...(row.length ? { length: row.length } : {}) };
        return { kind: 'vehicle', mode: mode(row), from: template.from, to: template.to, departure, arrival,
            scheduledDeparture: iso(times.scheduled), scheduledArrival: last.scheduledArrival,
            operator: detail.operatorCode ?? row.operator, serviceId: `live:${template.from.crs}:${row.serviceID}`,
            callingPoints: calls, serviceCallingPoints: completeCallingPoints(detail, path, template, times.scheduled), live, warnings };
    }

    async transfers(templates, before, after, connections, request, now, context) {
        let states = [{ values: [], arrival: before ? instant(before.arrival) : now }];
        for (const [index, template] of templates.entries()) {
            context.check();
            if (template.mode !== 'interchange' && request.allowedModes && !request.allowedModes.includes(template.mode)) return [];
            const next = [];
            for (const state of states) {
                const query = { from: template.from.crs, to: template.to.crs, arrival: state.arrival,
                    originIsEndpoint: !before && index === 0,
                    destinationIsEndpoint: !after && index === templates.length - 1,
                    departure: index === templates.length - 1 && after ? instant(after.departure) : undefined,
                    arrivingOperator: before?.operator, departingOperator: after?.operator,
                    direction: (template.mode === 'walk' || template.mode === 'tubeTransfer' && context.resolveTubeConnection)
                        && !before && after && templates.length === 1 ? 'latest' : 'earliest',
                    extraConnectionMinutes: request.extraConnectionMinutes ?? 0, allowedModes: [template.mode] };
                const choices = template.mode === 'tubeTransfer' && context.resolveTubeConnection
                    ? await context.resolveTubeConnection(connections, query) : [resolveConnection(connections, query)];
                context.check();
                for (const value of choices) {
                    if (!value || value.mode !== template.mode) continue;
                    const leg = { ...template, departure: iso(value.start), arrival: iso(value.end),
                        durationMinutes: value.minutes, minutes: value.minutes, ruleId: value.ruleId,
                        sourceRef: value.sourceRef, policy: value.policy, transfer: value.breakdown, breakdown: value.breakdown,
                        movementDeparture: Number.isFinite(value.movementStart) ? iso(value.movementStart) : null,
                        movementArrival: Number.isFinite(value.movementEnd) ? iso(value.movementEnd) : null,
                        genericTransfer: !value.localJourney && !['walk', 'interchange'].includes(template.mode),
                        warnings: value.localJourney ? value.localJourney.warnings ?? [] : template.warnings,
                        localJourney: value.localJourney, disruptionRank: value.disruptionRank };
                    const values = [...state.values, leg];
                    if (values.reduce((sum, leg) => sum + boardings(leg), 0) > (request.maxChanges ?? 5) + 1) continue;
                    next.push({ values, arrival: value.end });
                }
            }
            context.limited ||= next.length > MAX_STATES;
            states = next.slice(0, MAX_STATES);
        }
        if (templates.length && states.length && request.realtime === 'ignore' && before?.live?.arrival && after?.live?.departure
            && !(await this.transfers(templates, { ...before, arrival: before.live.arrival }, { ...after, departure: after.live.departure },
                connections, { ...request, realtime: 'apply' }, now, context)).length) {
            for (const { values } of states) values.at(-1).warnings = unique([...(values.at(-1).warnings ?? []), 'Live times no longer allow this connection.']);
        }
        return states.map(state => state.values);
    }
}
