// RSPS5046 5.11 describes ALF links between endpoint pairs; its layout has no
// direction field. The supplied feed contains no separately reversed pairs.
// Interpret source-backed ALF rows in both directions, retaining their source
// identity. Section 5.12 explicitly keeps TOC overrides ordered.
// https://www.rspaccreditation.org/downloadPublic.php?did=c5VkXAQOgMj8q024cALYymTpxTFaroiwLL7mvDA0A3UB5FJKuO
// ALF policy: the complete traversal must fit an active window. Boundaries use the
// stated clock minute, inclusively; both endpoint allowances are added to transit.
export const CONNECTION_POLICY = 'alf-pairs-full-traversal-inclusive-boundaries-v2';
const MINUTE = 60_000;
const DAY = 86_400_000;
const clock = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23'
});

function localParts(time) {
    const parts = Object.fromEntries(clock.formatToParts(time).map(p => [p.type, p.value]));
    return { date: `${parts.year}-${parts.month}-${parts.day}`, minute: Number(parts.hour) * 60 + Number(parts.minute), second: Number(parts.second) };
}

function dateShift(date, days) {
    return new Date(Date.parse(`${date}T12:00:00Z`) + days * DAY).toISOString().slice(0, 10);
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

function applicable(rule, time) {
    const parts = localParts(time);
    const start = minutes(rule.startTime ?? '0000');
    const end = minutes(rule.endTime ?? '2359');
    let date = parts.date;
    const minute = parts.minute + parts.second / 60;
    if (end < start) {
        if (minute <= end) date = dateShift(date, -1);
        else if (minute < start) return false;
    } else if (minute < start || minute > end) return false;
    if (rule.startDate && date < rule.startDate) return false;
    if (rule.endDate && date > rule.endDate) return false;
    const weekday = (new Date(`${date}T12:00:00Z`).getUTCDay() + 6) % 7;
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
    for (const rule of network.rules?.tsi ?? []) {
        addTo(tsi, `${rule.station}|${rule.arrivingOperator}|${rule.departingOperator}`, rule);
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
        if (!(rule.minutes > 0) || !Number.isFinite(minutes(rule.startTime ?? '0000')) || !Number.isFinite(minutes(rule.endTime ?? '2359'))) continue;
        indexLink(rule);
        // Arbitrary links from other providers may be directional. Only expand
        // the ALF source type emitted by the timetable importer.
        if (rule.sourceRef?.member === 'ALF') {
            indexLink({ ...rule, origin: rule.destination, destination: rule.origin });
        }
    }
    return { stations, pairs, outgoing, incoming, tsi, windows: new Map(), ambiguousLinks: new Set() };
}

function allowance(index, station) {
    const value = index.stations.get(station)?.minimumChangeMinutes;
    return Number.isFinite(value) && value >= 0 ? value : null;
}

function sameStationRule(index, from, arrivingOperator, departingOperator) {
    const overrides = index.tsi.get(`${from}|${arrivingOperator}|${departingOperator}`) ?? [];
    if (overrides.length) {
        // Conflicting source rules cannot safely be resolved by their file order.
        if (new Set(overrides.map(rule => rule.minutes)).size !== 1) return null;
        return { minutes: overrides[0].minutes, ruleId: overrides[0].id, sourceRef: overrides[0].sourceRef };
    }
    const value = allowance(index, from);
    return value === null ? null : { minutes: value, ruleId: `MSN:${from}`, sourceRef: index.stations.get(from)?.sourceRef };
}

function effectiveWindows(index, from, to, time) {
    const day = Math.floor(time / DAY) * DAY;
    const key = `${from}|${to}|${day}`;
    if (index.windows.has(key)) return index.windows.get(key);
    const rules = index.pairs.get(`${from}|${to}`) ?? [];
    const lower = day - DAY;
    const upper = day + 3 * DAY;
    const boundaries = new Set([lower, upper]);
    for (const rule of rules) {
        for (let offset = -2; offset <= 4; offset++) {
            const date = new Date(day + offset * DAY).toISOString().slice(0, 10);
            for (const minute of [minutes(rule.startTime ?? '0000'), minutes(rule.endTime ?? '2359')]) {
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
        const active = rules.filter(rule => applicable(rule, (start + end) / 2));
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
    extraConnectionMinutes = 0, allowedModes, direction = 'earliest'
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
    const exitMinutes = allowance(index, from);
    const entryMinutes = allowance(index, to);
    if (exitMinutes === null || entryMinutes === null) return null;
    const reference = direction === 'latest' ? departure : arrival;
    if (!Number.isFinite(reference)) return null;
    const modeSet = allowedModes instanceof Set ? allowedModes : new Set(allowedModes ?? ['rail', 'replacementBus', 'walk', 'tubeTransfer']);
    let best = null;
    for (const window of effectiveWindows(index, from, to, reference)) {
        const rule = window.rule;
        if (!modeSet.has(rule.mode)) continue;
        const travel = rule.minutes * MINUTE;
        const entry = (entryMinutes + extra) * MINUTE;
        const exit = exitMinutes * MINUTE;
        const movementStart = direction === 'latest'
            ? Math.min(window.end - travel, departure - entry - travel)
            : Math.max(window.start, arrival + exit);
        if (movementStart < window.start || movementStart + travel > window.end) continue;
        // At a priority boundary the interval starting there governs departure.
        if (!applicable(rule, movementStart)) continue;
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
export function validateFixedLink(index, connection, extraConnectionMinutes = 0) {
    const { from, to, start, end, movementStart, movementEnd, ruleId, mode, breakdown } = connection;
    if (![start, end, movementStart, movementEnd].every(Number.isFinite)) return false;
    const exitMinutes = allowance(index, from);
    const entryMinutes = allowance(index, to);
    if (exitMinutes === null || entryMinutes === null) return false;
    const window = effectiveWindows(index, from, to, movementStart).find(window =>
        window.rule.id === ruleId && window.rule.mode === mode && movementStart >= window.start && movementEnd <= window.end);
    if (!window || !applicable(window.rule, movementStart)) return false;
    return movementEnd - movementStart === window.rule.minutes * MINUTE
        && movementStart >= start + exitMinutes * MINUTE
        && end === movementEnd + (entryMinutes + extraConnectionMinutes) * MINUTE
        && breakdown?.exitMinutes === exitMinutes && breakdown?.entryMinutes === entryMinutes
        && breakdown?.travelMinutes === window.rule.minutes && breakdown?.extraMinutes === extraConnectionMinutes
        && breakdown?.waitingMinutes === (movementStart - start) / MINUTE - exitMinutes;
}
