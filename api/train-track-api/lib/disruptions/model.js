import { createHash } from 'node:crypto';
import { addDays, dateOnly, londonDate, originOffsetMinutes } from '../planner/time.js';

export const HORIZON_DAYS = 7;
export const hash = value => createHash('sha256').update(JSON.stringify(value ?? null)).digest('hex');
const RAIL_DATA_INCIDENTS_URL = 'https://api1.raildata.org.uk/1010-knowlegebase-incidents-xml-feed1_0/incidents.xml';

export function disruptionConfig(env = process.env) {
    const number = (key, fallback, min, max) => {
        const value = Number(env[key] ?? fallback);
        return Number.isFinite(value) && value >= min && value <= max ? value : fallback;
    };
    let noticeHeaders = {};
    try {
        const parsed = JSON.parse(env.DISRUPTION_NOTICE_HEADERS_JSON ?? '{}');
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)
            && Object.values(parsed).every(value => typeof value === 'string')) noticeHeaders = parsed;
    } catch { /* Provider access stays unavailable if credentials are invalid. */ }
    const marketplaceKey = env.TRAIN_TRACK_UK_DISRUPTIONS_API_KEY?.trim();
    const noticeEndpoint = env.DISRUPTION_NOTICE_URL ?? (marketplaceKey ? RAIL_DATA_INCIDENTS_URL : undefined);
    try {
        // The implicit Marketplace credential belongs only to this subscribed
        // feed. Custom destinations must provide their own explicit headers.
        if (marketplaceKey && new URL(noticeEndpoint).href === RAIL_DATA_INCIDENTS_URL
            && !Object.keys(noticeHeaders).some(key => key.toLowerCase() === 'x-apikey')) {
            noticeHeaders['x-apikey'] = marketplaceKey;
        }
    } catch { /* The provider reports invalid endpoint configuration. */ }
    return {
        mode: ['off', 'shadow', 'active'].includes(env.DISRUPTION_MONITOR_MODE) ? env.DISRUPTION_MONITOR_MODE : 'off',
        intervalMs: number('DISRUPTION_CHECK_INTERVAL_SECONDS', 1, 1, 300) * 1000,
        refreshMs: number('DISRUPTION_DEMAND_REFRESH_SECONDS', 300, 30, 3600) * 1000,
        maxSourceAgeHours: number('DISRUPTION_MAX_SOURCE_AGE_HOURS', 48, 1, 168),
        quietStart: 22, quietEnd: 7,
        noticeEndpoint,
        noticeAuthorization: env.DISRUPTION_NOTICE_AUTHORIZATION,
        noticeUsername: env.DISRUPTION_NOTICE_USERNAME,
        noticePassword: env.DISRUPTION_NOTICE_PASSWORD,
        noticeHeaders
    };
}

export class MonitorError extends Error {
    constructor(message, status = 400, code = 'INVALID_REQUEST') { super(message); this.status = status; this.code = code; }
}

export function deviceIdentifier(value) {
    if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(value)) throw new MonitorError('A valid device_id is required.');
    return value;
}

function clock(value, allowEnd = false) {
    if (allowEnd && value === '24:00') return 1440;
    if (typeof value !== 'string' || !/^([01]\d|2[0-3]):[0-5]\d$/.test(value)) throw new MonitorError('Use HH:mm for monitoring hours.');
    const [h, m] = value.split(':').map(Number);
    return h * 60 + m;
}

function window(start, end) {
    const startMinutes = clock(start), endMinutes = clock(end, true);
    if (startMinutes === endMinutes) throw new MonitorError('Monitoring start and end must differ. Use 00:00–24:00 for all day.');
    return { start, end };
}

export function normalizeMonitors(body) {
    const deviceId = deviceIdentifier(body?.device_id);
    if (!Array.isArray(body.monitors) || body.monitors.length > 100) throw new MonitorError('Supply at most 100 saved journey monitors.');
    const ids = new Set(), routes = new Set();
    const monitors = body.monitors.map(raw => {
        if (typeof raw?.id !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(raw.id) || ids.has(raw.id)) throw new MonitorError('Each monitor must have a unique id.');
        ids.add(raw.id);
        if (!Array.isArray(raw.stations) || raw.stations.length < 2 || raw.stations.length > 6
            || raw.stations.some(crs => typeof crs !== 'string' || !/^[A-Z]{3}$/.test(crs))) throw new MonitorError('Supply two to six ordered station CRS codes.');
        if (new Set(raw.stations).size !== raw.stations.length) throw new MonitorError('Use distinct stations in travel order.');
        const route = raw.stations.join('-');
        if (routes.has(route)) throw new MonitorError('Each saved route should be monitored once.');
        routes.add(route);
        const days = raw.days ?? [1, 2, 3, 4, 5, 6, 7];
        if (!Array.isArray(days) || !days.length || days.some(day => !Number.isInteger(day) || day < 1 || day > 7)) throw new MonitorError('Select at least one valid travel day.');
        for (const key of ['enabled', 'push_enabled']) if (raw[key] !== undefined && typeof raw[key] !== 'boolean') throw new MonitorError(`${key} must be true or false.`);
        const times = window(raw.window_start ?? '00:00', raw.window_end ?? '24:00');
        const dayWindows = {};
        if (raw.day_windows !== undefined && (!raw.day_windows || typeof raw.day_windows !== 'object' || Array.isArray(raw.day_windows))) throw new MonitorError('day_windows must contain weekday hours.');
        for (const [key, times] of Object.entries(raw.day_windows ?? {})) {
            if (!/^[1-7]$/.test(key)) throw new MonitorError('Use weekday keys 1 to 7.');
            dayWindows[key] = window(times?.start, times?.end);
        }
        let travelDate = null;
        if (raw.travel_date != null) {
            try { travelDate = dateOnly(raw.travel_date); } catch { throw new MonitorError('Use YYYY-MM-DD for travel_date.'); }
        }
        if (raw.name !== undefined && (typeof raw.name !== 'string' || raw.name.length > 200)) throw new MonitorError('Journey names must be at most 200 characters.');
        return { id: raw.id, stations: raw.stations, name: raw.name || route, enabled: raw.enabled !== false,
            days: [...new Set(days)].sort(), window_start: times.start, window_end: times.end, day_windows: dayWindows,
            travel_date: travelDate, push_enabled: raw.push_enabled === true };
    });
    if (body.push_token != null && (typeof body.push_token !== 'string' || !/^[a-fA-F0-9]{32,256}$/.test(body.push_token))) throw new MonitorError('Invalid notification token.');
    if (body.use_sandbox !== undefined && typeof body.use_sandbox !== 'boolean') throw new MonitorError('use_sandbox must be true or false.');
    return { deviceId, monitors, ...(Object.hasOwn(body, 'push_token') ? { pushToken: body.push_token } : {}),
        ...(Object.hasOwn(body, 'use_sandbox') ? { useSandbox: body.use_sandbox } : {}) };
}

export function weekday(date) { return new Date(`${date}T12:00:00Z`).getUTCDay() || 7; }

export function monitoringWindow(monitor, date) {
    if (!monitor.enabled || (monitor.travel_date ? monitor.travel_date !== date : !monitor.days.includes(weekday(date)))) return null;
    const times = monitor.day_windows[String(weekday(date))] ?? { start: monitor.window_start, end: monitor.window_end };
    const startMinutes = clock(times.start), end = clock(times.end, true);
    return { startMinutes, endMinutes: end <= startMinutes ? end + 1440 : end };
}

export function windowChunks(monitor, date) {
    const selected = monitoringWindow(monitor, date);
    if (!selected) return [];
    const result = [];
    for (let start = selected.startMinutes; start < selected.endMinutes; start += 60) {
        // Normalize the post-midnight portion to its actual date; the monitor's
        // selected weekday still owns the whole overnight window.
        const offset = Math.floor(start / 1440), base = offset * 1440;
        result.push({ date: addDays(date, offset), startMinutes: start - base,
            endMinutes: Math.min(start + 60, selected.endMinutes, base + 1440) - base });
        if (start + 60 > base + 1440 && selected.endMinutes > base + 1440) {
            result.push({ date: addDays(date, offset + 1), startMinutes: 0,
                endMinutes: Math.min(start + 60, selected.endMinutes) - (base + 1440) });
        }
    }
    return result;
}

export function londonInstant(date, minutes) {
    const day = addDays(date, Math.floor(minutes / 1440)), localMinutes = minutes % 1440;
    return Date.parse(`${day}T00:00:00Z`) + (localMinutes - originOffsetMinutes(day, localMinutes * 60)) * 60000;
}

export function profileJob(stations, chunk, version, now, priority = 0) {
    const key = hash([stations, chunk.date, chunk.startMinutes, chunk.endMinutes, version]);
    return { _id: key, routeKey: hash(stations), stations, date: chunk.date, startMinutes: chunk.startMinutes,
        endMinutes: chunk.endMinutes, datasetVersion: version, priority, status: 'pending',
        retryAt: new Date(now), createdAt: new Date(now), demandedUntil: new Date(now + 3600000),
        expiresAt: new Date(`${addDays(chunk.date, 45)}T00:00:00Z`) };
}

export function horizonDates(now) { return Array.from({ length: HORIZON_DAYS }, (_, i) => addDays(londonDate(now), i)); }

export function isQuietTime(now, { quietStart = 22, quietEnd = 7 } = {}) {
    const hour = Number(new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London', hour: '2-digit', hourCycle: 'h23' }).format(new Date(now)));
    return quietStart > quietEnd ? hour >= quietStart || hour < quietEnd : hour >= quietStart && hour < quietEnd;
}

export function timetableSeason(date) {
    const year = Number(date.slice(0, 4));
    const boundary = month => {
        const first = new Date(Date.UTC(year, month, 1));
        const secondSunday = 1 + (7 - first.getUTCDay()) % 7 + 7;
        return new Date(Date.UTC(year, month, secondSunday)).toISOString().slice(0, 10);
    };
    return date >= boundary(11) ? `${year}-winter` : date >= boundary(4) ? `${year}-summer` : `${year - 1}-winter`;
}
