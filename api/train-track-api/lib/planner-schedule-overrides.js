// Dated exceptions belong to the replacement, so cancellation restores the original.
const DAY = 86400000;
const formatter = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
function parts(date) { return Object.fromEntries(formatter.formatToParts(date).map(p => [p.type, p.value])); }
function dateKey(date) { const p = parts(date); return `${p.year}-${p.month}-${p.day}`; }
function localTime(day, clock, end = false) {
    const target = Date.parse(`${day}T${clock}:00Z`);
    // At the autumn fold cover both occurrences of an ambiguous local clock time.
    const candidates = [target - 3600000, target].filter(instant => {
        const p = parts(new Date(instant));
        return `${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:00Z` === `${day}T${clock}:00Z`;
    });
    if (candidates.length) return end ? Math.max(...candidates) : Math.min(...candidates);
    let instant = target;
    for (let i = 0; i < 4; i++) {
        const p = parts(new Date(instant));
        const observed = Date.parse(`${p.year}-${p.month}-${p.day}T${p.hour}:${p.minute}:00Z`);
        if (observed === target) break;
        instant += target - observed;
    }
    return instant;
}
const key = leg => `${leg.from}-${leg.to}`;
export function plannerConflicts(subscriptions, deviceId, plan) {
    const start = Date.parse(plan.startsAt), end = Date.parse(plan.arrival);
    const dates = new Set();
    for (let day = start - DAY; day <= end + DAY; day += DAY) dates.add(dateKey(new Date(day)));
    const conflicts = [];
    for (const sub of subscriptions) {
        if (sub.deviceId !== deviceId || sub.source === 'live_session' || sub.plannerJourney || sub.scheduleKind === 'one_off') continue;
        for (const day of dates) {
            const weekday = new Intl.DateTimeFormat('en-GB', { timeZone: 'UTC', weekday: 'short' })
                .format(new Date(`${day}T12:00:00Z`)).toLowerCase();
            if (!sub.daysOfWeek.includes(weekday)) continue;
            sub.legs.forEach((leg, legIndex) => {
                if (!leg.enabled) return;
                const window = leg.dayWindows?.[weekday] || leg;
                if (!/^\d{2}:\d{2}$/.test(window.windowStart) || !/^\d{2}:\d{2}$/.test(window.windowEnd)) return;
                const from = localTime(day, window.windowStart);
                const endDay = window.windowEnd < window.windowStart
                    ? new Date(Date.parse(`${day}T12:00:00Z`) + DAY).toISOString().slice(0, 10) : day;
                const until = localTime(endDay, window.windowEnd, true);
                if (from >= end || until <= start) return;
                conflicts.push({ subscriptionId: sub.id, legIndex, legKey: key(leg),
                    start: new Date(from).toISOString(), end: new Date(until).toISOString(),
                    title: `${leg.fromName || leg.from} → ${leg.toName || leg.to}`,
                    revision: sub.updatedAt || null });
            });
        }
    }
    return conflicts;
}
export function preparePlannerOverrides(subscriptions, deviceId, plan, input) {
    if (!input.replacementMode) return;
    if (!['once', 'permanent'].includes(input.replacementMode)) throw new Error('Invalid schedule replacement option');
    const conflicts = plannerConflicts(subscriptions, deviceId, plan);
    const identity = rows => rows.map(row => `${row.subscriptionId}|${row.legIndex}|${Date.parse(row.start)}|${row.revision || ''}`).sort();
    if (JSON.stringify(identity(input.replacements || [])) !== JSON.stringify(identity(conflicts))) {
        throw new Error('Your regular schedules have changed. Reopen journey tracking to review the replacements.');
    }
    plan.replacementMode = input.replacementMode;
    plan.replacements = conflicts;
    // Keep the exception until the entire replaced occurrence ends, even after arrival.
    plan.expiresAt = new Date(Math.max(Date.parse(plan.expiresAt), ...conflicts.map(c => Date.parse(c.end)))).toISOString();
}
export function replacedOccurrences(subscriptions, subscription) {
    return subscriptions.filter(s => s.deviceId === subscription.deviceId).flatMap(s =>
        (s.plannerJourney?.replacements || []).filter(r => r.subscriptionId === subscription.id)
            .map(r => ({ ...r, replacementPlanId: s.id })));
}
export function occurrenceIsReplaced(occurrences, leg, now = new Date()) {
    return occurrences.some(r => (r.legKey === key(leg) || r.replacementLegKeys?.includes(key(leg)))
        && Date.parse(r.start) <= +now && +now < Date.parse(r.end));
}
export function permanentReplacement(sub, plan) {
    const indexes = new Set(plan.replacements.filter(r => r.subscriptionId === sub.id).map(r => r.legIndex));
    if (!indexes.size) return sub;
    const orderedIndexes = [...indexes].sort((a, b) => a - b);
    const first = orderedIndexes[0];
    const replacement = plan.legs.filter(l => l.kind === 'vehicle' && l.mode === 'rail').map((l, index) => ({
        ...sub.legs[orderedIndexes[index] ?? first], from: l.from.crs, to: l.to.crs, fromName: l.from.name, toName: l.to.name
    }));
    const legs = sub.legs.flatMap((leg, index) => index === first ? replacement : indexes.has(index) ? [] : [leg]);
    const sequence = rows => [rows[0].from, ...rows.map(l => l.to)];
    const oldSplit = sub.directionSplitIndex ?? sub.legs.findIndex((_, index) => index > 0
        && JSON.stringify(sequence(sub.legs.slice(index))) === JSON.stringify(sequence(sub.legs.slice(0, index)).reverse()));
    const directionSplitIndex = oldSplit > 0
        ? oldSplit - [...indexes].filter(i => i < oldSplit).length + (first < oldSplit ? replacement.length : 0) : null;
    const route = sequence(replacement);
    const routeKey = [route.join('-'), [...route].reverse().join('-')].sort()[0];
    return { ...sub, legs, routeKey, directionSplitIndex };
}

export function replacementMatchesScheduleKey(occurrence, scheduleKey) {
    const start = parts(new Date(occurrence.start)), end = parts(new Date(occurrence.end));
    return [occurrence.legKey, ...(occurrence.replacementLegKeys || [])].some(route =>
        `${route}|${start.hour}:${start.minute}|${end.hour}:${end.minute}|${dateKey(new Date(occurrence.start))}` === scheduleKey);
}
