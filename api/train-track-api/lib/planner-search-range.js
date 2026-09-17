const DAY = 86400000;
const units = { m: 60000, h: 3600000, d: DAY };
const legacyRanges = ['1h', '24h', '7d'];

export class PlannerSearchRangeError extends Error {
    constructor(message) { super(message); this.code = 'INVALID_SEARCH_RANGE'; }
}

// Bookmarks use explicit offsets; the native date/time form submits UTC fields
// with timezone=UTC. Never interpret a date in the server's local timezone.
function instant(value, timezone) {
    if (typeof value !== 'string' || value.length > 40) throw new PlannerSearchRangeError('Enter both a start and an end date and time.');
    const match = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})(?::(\d{2})(\.\d{1,3})?)?(Z|[+-]\d{2}:\d{2})?$/.exec(value);
    if (!match || (!match[5] && timezone !== 'UTC')) {
        throw new PlannerSearchRangeError('Dates in the URL need a timezone, such as Z or +01:00. The date fields use UTC.');
    }
    const wall = `${match[1]}T${match[2]}:${match[3] ?? '00'}${match[4] ?? ''}`;
    const check = new Date(`${wall}Z`);
    if (!Number.isFinite(check.getTime()) || check.toISOString().slice(0, 19) !== wall.slice(0, 19)) {
        throw new PlannerSearchRangeError('Enter a valid calendar date and time.');
    }
    const suffix = match[5] ?? 'Z';
    if (suffix !== 'Z' && (Number(suffix.slice(1, 3)) > 14 || Number(suffix.slice(4, 6)) > 59
        || (Number(suffix.slice(1, 3)) === 14 && suffix.slice(4, 6) !== '00'))) {
        throw new PlannerSearchRangeError('Use a valid UTC offset between -14:00 and +14:00.');
    }
    const parsed = new Date(`${wall}${suffix}`);
    if (!Number.isFinite(parsed.getTime())) throw new PlannerSearchRangeError('Enter a valid date and time.');
    return parsed.toISOString();
}

export function normalizePlannerSearchRange(query = {}) {
    const hasDates = query.from !== undefined || query.to !== undefined;
    const q = query.q ?? (query.range === 'custom' || hasDates ? 'custom' : undefined);
    if (q === undefined || q === '') return { range: legacyRanges.includes(query.range) ? query.range : '24h' };
    if (q === 'custom') {
        const from = instant(query.from, query.timezone), to = instant(query.to, query.timezone);
        if (from >= to) throw new PlannerSearchRangeError('The end must be later than the start.');
        if (Date.parse(to) - Date.parse(from) > 7 * DAY) throw new PlannerSearchRangeError('Choose a period of seven days or less.');
        return { range: 'custom', q: 'custom', from, to };
    }
    const match = typeof q === 'string' && q.length <= 10 && /^-([1-9]\d*)([mhd])$/.exec(q);
    if (!match || Number(match[1]) * units[match[2]] > 7 * DAY) {
        throw new PlannerSearchRangeError('Use a relative period such as -5m, -2h or -7d, up to seven days.');
    }
    return { range: 'relative', q };
}

export function plannerSearchWindow(options, now) {
    const query = options.q ?? `-${options.range}`;
    const milliseconds = options.range === 'custom' ? null : Number(query.slice(1, -1)) * units[query.at(-1)];
    const from = options.range === 'custom' ? Date.parse(options.from) : now - milliseconds;
    const to = options.range === 'custom' ? Date.parse(options.to) : now;
    // Historical bookmarks can outlive retention. Keep the chosen period, but
    // never include expired records while Mongo's TTL deletion catches up.
    return { from: new Date(Math.max(from, now - 7 * DAY)), to: new Date(Math.min(to, now)) };
}
