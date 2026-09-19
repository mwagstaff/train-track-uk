import { MODES } from './contract.js';

// RSPS5046 5.11 describes ALF links between endpoint pairs; its layout has no
// direction field. The supplied feed contains no separately reversed pairs.
// Interpret source-backed ALF rows in both directions, retaining their source
// identity. Section 5.12 explicitly keeps TOC overrides ordered.
// https://www.rspaccreditation.org/downloadPublic.php?did=c5VkXAQOgMj8q024cALYymTpxTFaroiwLL7mvDA0A3UB5FJKuO
// ALF policy: the complete traversal must fit an active window. Boundaries use the
// stated clock minute, inclusively. A fixed link from/to a journey endpoint does
// not require an allowance outside the journey; boarding/alighting elsewhere
// still uses the supplied station allowances.
export const CONNECTION_POLICY = 'alf-pairs-endpoint-allowances-v4';
const MINUTE = 60_000;
const DAY = 86_400_000;
// Europe/London since 1996: BST runs from 01:00 UTC on the last Sunday of March
// to 01:00 UTC on the last Sunday of October. Routing resolves this clock for
// every fixed-link check, so integer arithmetic replaces Intl formatting here.
const summerTime = new Map();
const dayNames = new Map();

function calendarDay(day) {
    let value = dayNames.get(day);
    if (!value) {
        const date = new Date(day * DAY);
        value = { date: date.toISOString().slice(0, 10), weekday: (date.getUTCDay() + 6) % 7 };
        if (dayNames.size >= 128) dayNames.clear();
        dayNames.set(day, value);
    }
    return value;
}

function summerTimeBounds(year) {
    let bounds = summerTime.get(year);
    if (!bounds) {
        const lastSunday = month => {
            const last = new Date(Date.UTC(year, month + 1, 0));
            return Date.UTC(year, month, last.getUTCDate() - last.getUTCDay(), 1);
        };
        bounds = [lastSunday(2), lastSunday(9)];
        summerTime.set(year, bounds);
    }
    return bounds;
}

function localParts(time) {
    const [start, end] = summerTimeBounds(new Date(time).getUTCFullYear());
    const local = time + (time >= start && time < end ? 3_600_000 : 0);
    const day = Math.floor(local / DAY);
    const date = calendarDay(day);
    const ofDay = local - day * DAY;
    return { date: date.date, weekday: date.weekday, day,
        minute: Math.floor(ofDay / MINUTE), second: Math.floor((ofDay % MINUTE) / 1000) };
}

function minutes(value) {
    if (typeof value === 'number') return value;
    const text = String(value ?? '').replace(':', '');
    return /^\d{4}$/.test(text) ? Number(text.slice(0, 2)) * 60 + Number(text.slice(2)) : NaN;
}

function localInstants(date, minute) {
    const midnight = Date.parse(`${date}T00:00:00Z`);
    // Modern GB timetable dates use GMT/BST. Testing both offsets also handles
    // the duplicated autumn hour, and rejects the nonexistent spring hour.
    return [midnight + minute * MINUTE, midnight + (minute - 60) * MINUTE].filter(time => {
        const parts = localParts(time);
        return parts.date === date && parts.minute === minute;
    });
}

function ruleClock(index, rule) {
    let clock = index.ruleClocks.get(rule);
    if (!clock || clock.startTime !== rule.startTime || clock.endTime !== rule.endTime) {
        clock = { startTime: rule.startTime, endTime: rule.endTime,
            start: minutes(rule.startTime ?? '0000'), end: minutes(rule.endTime ?? '2359') };
        index.ruleClocks.set(rule, clock);
    }
    return clock;
}

function applicable(index, rule, time) {
    const parts = localParts(time);
    const { start, end } = ruleClock(index, rule);
    let { date, weekday } = parts;
    const minute = parts.minute + parts.second / 60;
    if (end < start) {
        if (minute <= end) ({ date, weekday } = calendarDay(parts.day - 1));
        else if (minute < start) return false;
    } else if (minute < start || minute > end) return false;
    if (rule.startDate && date < rule.startDate) return false;
    if (rule.endDate && date > rule.endDate) return false;
    return !rule.days || rule.days[weekday] === '1';
}

function addTo(map, key, value) {
    if (!map.has(key)) map.set(key, []);
    map.get(key).push(value);
}

export function createConnectionIndex(network) {
    const stations = network.stations instanceof Map ? network.stations : new Map(network.stations.map(s => [s.crs, s]));
    const pairs = new Map();
    const outgoing = new Map();
    const incoming = new Map();
    const tsi = new Map();
    const tsiStations = new Set(), interchanges = new Map();
    for (const rule of network.rules?.tsi ?? []) {
        addTo(tsi, `${rule.station}|${rule.arrivingOperator}|${rule.departingOperator}`, rule);
        tsiStations.add(rule.station);
    }
    for (const [key, overrides] of tsi) {
        // These source rules belong to this immutable network. Resolve conflicts
        // once, rather than allocating a Set on every possible train transfer.
        const first = overrides[0];
        interchanges.set(key, new Set(overrides.map(rule => rule.minutes)).size === 1
            ? { minutes: first.minutes, ruleId: first.id, sourceRef: first.sourceRef } : null);
    }
    function indexLink(rule) {
        const pair = `${rule.origin}|${rule.destination}`;
        addTo(pairs, pair, rule);
        if (!outgoing.has(rule.origin)) outgoing.set(rule.origin, new Set());
        if (!incoming.has(rule.destination)) incoming.set(rule.destination, new Set());
        outgoing.get(rule.origin).add(rule.destination);
        incoming.get(rule.destination).add(rule.origin);
    }
    for (const rule of network.rules?.links ?? []) {
        if (!stations.has(rule.origin) || !stations.has(rule.destination) || rule.origin === rule.destination) continue;
        if (!Number.isFinite(rule.minutes) || !(rule.minutes > 0) || !Number.isFinite(minutes(rule.startTime ?? '0000')) || !Number.isFinite(minutes(rule.endTime ?? '2359'))) continue;
        indexLink(rule);
        // Arbitrary links from other providers may be directional. Only expand
        // the ALF source type emitted by the timetable importer.
        if (rule.sourceRef?.member === 'ALF') {
            indexLink({ ...rule, origin: rule.destination, destination: rule.origin });
        }
    }
    return { stations, pairs, outgoing, incoming, tsi, tsiStations, interchanges,
        stationRules: new Map(), ruleClocks: new WeakMap(), windows: new Map(), ambiguousLinks: new Set() };
}

export function stationAllowance(index, station) {
    const value = index.stations.get(station)?.minimumChangeMinutes;
    return Number.isFinite(value) && value >= 0 ? value : null;
}

const allowance = stationAllowance;

function linkAllowances(index, from, to, { originIsEndpoint = false, destinationIsEndpoint = false } = {}) {
    return {
        exitMinutes: originIsEndpoint ? 0 : allowance(index, from),
        entryMinutes: destinationIsEndpoint ? 0 : allowance(index, to)
    };
}

function sameStationRule(index, from, arrivingOperator, departingOperator) {
    if (index.tsiStations.has(from)) {
        const override = index.interchanges.get(`${from}|${arrivingOperator}|${departingOperator}`);
        if (override !== undefined) return override;
    }
    const station = index.stations.get(from);
    if (!station) return null;
    const value = station.minimumChangeMinutes, sourceRef = station.sourceRef;
    let cached = index.stationRules.get(from);
    // TfL fallback shares the rule index with a small replacement station map.
    // Cache by the current station value as well as identity so overlays cannot
    // reuse an allowance from the base network or mutate an earlier result.
    if (!cached || cached.station !== station || cached.value !== value || cached.sourceRef !== sourceRef) {
        cached = { station, value, sourceRef, rule: Number.isFinite(value) && value >= 0
            ? { minutes: value, ruleId: `MSN:${from}`, sourceRef } : null };
        index.stationRules.set(from, cached);
    }
    return cached.rule;
}

export function effectiveWindows(index, from, to, time) {
    const day = Math.floor(time / DAY) * DAY;
    const key = `${from}|${to}|${day}`;
    if (index.windows.has(key)) return index.windows.get(key);
    const rules = index.pairs.get(`${from}|${to}`) ?? [];
    const lower = day - DAY;
    const upper = day + 3 * DAY;
    const boundaries = new Set([lower, upper]);
    for (const rule of rules) {
        const clock = ruleClock(index, rule);
        for (let offset = -2; offset <= 4; offset++) {
            const date = new Date(day + offset * DAY).toISOString().slice(0, 10);
            for (const minute of [clock.start, clock.end]) {
                for (const instant of localInstants(date, minute)) if (instant > lower && instant < upper) boundaries.add(instant);
            }
            for (const instant of localInstants(date, 0)) if (instant > lower && instant < upper) boundaries.add(instant);
        }
    }
    // Split at offset changes so an autumn repeated window cannot become one
    // long, erroneously available interval across the clock rollback.
    for (let t = lower + 3_600_000; t < upper; t += 3_600_000) {
        const before = localParts(t - MINUTE);
        const after = localParts(t);
        if ((after.minute - before.minute + 1440) % 1440 !== 1) boundaries.add(t);
    }
    const times = [...boundaries].sort((a, b) => a - b);
    const windows = [];
    for (let i = 0; i < times.length - 1; i++) {
        const start = times[i];
        const end = times[i + 1];
        const active = rules.filter(rule => applicable(index, rule, (start + end) / 2));
        if (!active.length) continue;
        const priority = Math.max(...active.map(rule => rule.priority ?? 1));
        const winners = active.filter(rule => (rule.priority ?? 1) === priority);
        if (new Set(winners.map(rule => `${rule.mode}|${rule.minutes}`)).size !== 1) {
            for (const rule of winners) index.ambiguousLinks.add(rule.id);
            continue;
        }
        winners.sort((a, b) => String(a.id).localeCompare(String(b.id)));
        const rule = winners[0];
        const previous = windows.at(-1);
        if (previous && previous.end === start && previous.rule.id === rule.id) previous.end = end;
        else windows.push({ start, end, rule });
    }
    // Cache is scoped to the date network; bound it for a long-lived worker.
    if (index.windows.size > 10_000) index.windows.clear();
    index.windows.set(key, windows);
    return windows;
}

/** Resolve a connection in forward chronological order, even during reverse routing.
 * earliest: the earliest ready time after `arrival`; latest: latest allowable
 * arrival before `departure`. A rule may require waiting until it opens.
 */
export function resolveConnection(index, {
    from, to, arrival, departure, arrivingOperator, departingOperator,
    extraConnectionMinutes = 0, allowedModes, direction = 'earliest',
    originIsEndpoint = false, destinationIsEndpoint = false
}) {
    const extra = extraConnectionMinutes;
    if (!Number.isFinite(extra) || extra < 0) return null;
    if (from === to) {
        const rule = sameStationRule(index, from, arrivingOperator, departingOperator);
        if (!rule || !Number.isFinite(rule.minutes) || rule.minutes < 0) return null;
        const duration = (rule.minutes + extra) * MINUTE;
        const start = direction === 'latest' ? departure - duration : arrival;
        const end = start + duration;
        if ((arrival != null && start < arrival) || (departure != null && end > departure)) return null;
        return {
            from, to, mode: 'interchange', start, end, minutes: duration / MINUTE,
            ruleId: rule.ruleId, sourceRef: rule.sourceRef, boardings: 0,
            breakdown: { interchangeMinutes: rule.minutes, extraMinutes: extra, waitingMinutes: 0 }
        };
    }
    const reference = direction === 'latest' ? departure : arrival;
    if (!Number.isFinite(reference)) return null;
    const modeSet = allowedModes instanceof Set ? allowedModes : new Set(allowedModes ?? MODES);
    let best = null;
    for (const window of effectiveWindows(index, from, to, reference)) {
        const rule = window.rule;
        if (!modeSet.has(rule.mode)) continue;
        const { exitMinutes, entryMinutes } = linkAllowances(index, from, to, { originIsEndpoint, destinationIsEndpoint });
        if (exitMinutes === null || entryMinutes === null) continue;
        const travel = rule.minutes * MINUTE;
        const entry = (entryMinutes + extra) * MINUTE;
        const exit = exitMinutes * MINUTE;
        const movementStart = direction === 'latest'
            ? Math.min(window.end - travel, departure - entry - travel)
            : Math.max(window.start, arrival + exit);
        if (movementStart < window.start || movementStart + travel > window.end) continue;
        // At a priority boundary the interval starting there governs departure.
        if (!applicable(index, rule, movementStart)) continue;
        const start = direction === 'latest' ? movementStart - exit : arrival;
        const end = movementStart + travel + entry;
        if ((arrival != null && start < arrival) || (departure != null && end > departure)) continue;
        const candidate = {
            from, to, mode: rule.mode, start, end, movementStart, movementEnd: movementStart + travel,
            minutes: (end - start) / MINUTE, ruleId: rule.id, sourceRef: rule.sourceRef,
            boardings: rule.mode === 'walk' ? 0 : 1, policy: CONNECTION_POLICY,
            breakdown: { exitMinutes, travelMinutes: rule.minutes, entryMinutes, extraMinutes: extra, waitingMinutes: (movementStart - start - exit) / MINUTE }
        };
        if (!best || (direction === 'latest' ? candidate.start > best.start : candidate.end < best.end)) best = candidate;
    }
    return best;
}

/** Validate the selected window and rule directly, without replacing the
 * selected connection with an earlier (or later) valid alternative. */
export function validateFixedLink(index, connection, extraConnectionMinutes = 0, endpoints = {}) {
    const { from, to, start, end, movementStart, movementEnd, ruleId, mode, breakdown } = connection;
    if (![start, end, movementStart, movementEnd].every(Number.isFinite)) return false;
    const { exitMinutes, entryMinutes } = linkAllowances(index, from, to, endpoints);
    if (exitMinutes === null || entryMinutes === null) return false;
    const window = effectiveWindows(index, from, to, movementStart).find(window =>
        window.rule.id === ruleId && window.rule.mode === mode && movementStart >= window.start && movementEnd <= window.end);
    if (!window || !applicable(index, window.rule, movementStart)) return false;
    return movementEnd - movementStart === window.rule.minutes * MINUTE
        && movementStart >= start + exitMinutes * MINUTE
        && end === movementEnd + (entryMinutes + extraConnectionMinutes) * MINUTE
        && breakdown?.exitMinutes === exitMinutes && breakdown?.entryMinutes === entryMinutes
        && breakdown?.travelMinutes === window.rule.minutes && breakdown?.extraMinutes === extraConnectionMinutes
        && breakdown?.waitingMinutes === (movementStart - start) / MINUTE - exitMinutes;
}
