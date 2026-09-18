import { createHash } from 'node:crypto';

export const API_VERSION = 3;
export const POLICY_VERSION = 'scheduled-v5-endpoint-walk';
export const LIVE_POLICY_VERSION = 'live-v3-endpoint-walk';
export const LIVE_WINDOW_HOURS = 4;
export const MAX_CHANGES = 5;
export const DEFAULT_WINDOW_MINUTES = 360;
export const MODES = ['rail', 'replacementBus', 'walk', 'tubeTransfer'];
export const CAPABILITIES = Object.freeze({
    timeTypes: ['departAfter', 'arriveBy'], maxChanges: MAX_CHANGES,
    allowedModes: MODES, scheduledOnly: false, throughServices: false,
    liveUpdates: true, liveWindowHours: LIVE_WINDOW_HOURS, realtimeModes: ['apply', 'ignore', 'off']
});

export class PlannerError extends Error {
    constructor(code, message, status = 400) {
        super(message);
        this.name = 'PlannerError';
        this.code = code;
        this.status = status;
    }
}

function integer(value, fallback, minimum, maximum, name) {
    const result = value === undefined ? fallback : value;
    if (!Number.isInteger(result) || result < minimum || result > maximum) {
        throw new PlannerError('INVALID_REQUEST', `${name} must be between ${minimum} and ${maximum}.`);
    }
    return result;
}

export function normalizeRequest(body) {
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
        throw new PlannerError('INVALID_REQUEST', 'Supply a journey search.');
    }
    const origin = typeof body.origin === 'string' ? body.origin.trim().toUpperCase() : '';
    const destination = typeof body.destination === 'string' ? body.destination.trim().toUpperCase() : '';
    if (!/^[A-Z0-9]{3}$/.test(origin) || !/^[A-Z0-9]{3}$/.test(destination)) {
        throw new PlannerError('INVALID_STATION', 'Select an origin and destination station.');
    }
    // Date.parse accepts impossible dates such as February 30; validate the date separately.
    const match = typeof body.time === 'string' && body.time.match(
        /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,3})?(Z|[+-]\d{2}:\d{2})$/
    );
    const date = match ? Date.parse(`${match[1]}T00:00:00Z`) : NaN;
    if (!match || !Number.isFinite(date) || new Date(date).toISOString().slice(0, 10) !== match[1]
        || Number(match[2]) > 23 || Number(match[3]) > 59 || Number(match[4]) > 59
        || !Number.isFinite(Date.parse(body.time))) {
        throw new PlannerError('INVALID_REQUEST', 'Use an ISO date and time with an explicit timezone offset.');
    }
    if (!CAPABILITIES.timeTypes.includes(body.timeType)) {
        throw new PlannerError('INVALID_REQUEST', 'Choose departAfter or arriveBy.');
    }
    if (body.realtime !== undefined && !['apply', 'ignore', 'off'].includes(body.realtime)) {
        throw new PlannerError('INVALID_REQUEST', 'Choose apply, ignore or off for realtime.');
    }
    const allowedModes = body.allowedModes === undefined ? MODES : body.allowedModes;
    if (!Array.isArray(allowedModes) || !allowedModes.length || allowedModes.length > MODES.length
        || allowedModes.some(mode => !MODES.includes(mode))) {
        throw new PlannerError('INVALID_REQUEST', `Supported modes: ${MODES.join(', ')}.`);
    }
    return {
        origin, destination, time: new Date(body.time).toISOString(), timeType: body.timeType,
        maxChanges: integer(body.maxChanges, MAX_CHANGES, 0, MAX_CHANGES, 'maxChanges'),
        extraConnectionMinutes: integer(body.extraConnectionMinutes, 0, 0, 60, 'extraConnectionMinutes'),
        allowedModes: [...new Set(allowedModes)].sort(),
        limit: integer(body.limit, 5, 1, 10, 'limit'),
        windowMinutes: integer(body.windowMinutes, DEFAULT_WINDOW_MINUTES, 15, 360, 'windowMinutes'),
        ...(body.realtime && body.realtime !== 'off' ? { realtime: body.realtime } : {})
    };
}

export function encodeCursor(request, version, offset = 0, liveSnapshotId, tubeSnapshotId) {
    return Buffer.from(JSON.stringify({ policy: request.realtime ? LIVE_POLICY_VERSION : POLICY_VERSION,
        version, request, offset, ...(liveSnapshotId ? { liveSnapshotId } : {}),
        ...(tubeSnapshotId ? { tubeSnapshotId } : {}) })).toString('base64url');
}

export function decodeCursor(cursor) {
    try {
        if (typeof cursor !== 'string' || cursor.length > 4096 || !/^[\w-]+$/.test(cursor)) throw new Error();
        const value = JSON.parse(Buffer.from(cursor, 'base64url').toString());
        if (![POLICY_VERSION, LIVE_POLICY_VERSION].includes(value.policy) || !/^[a-f0-9]{64}$/.test(value.version)) {
            throw new PlannerError('CURSOR_EXPIRED', 'This search has expired. Please search again.', 410);
        }
        const offset = integer(value.offset, 0, 0, 1000, 'offset');
        const request = normalizeRequest(value.request);
        if (Boolean(request.realtime) !== (value.policy === LIVE_POLICY_VERSION)
            || (value.liveSnapshotId !== undefined && (!request.realtime || !/^[a-f0-9-]{36}$/.test(value.liveSnapshotId)))
            || (value.tubeSnapshotId !== undefined && (request.realtime || !/^[a-f0-9-]{36}$/.test(value.tubeSnapshotId)))) {
            throw new Error();
        }
        return { version: value.version, request, offset,
            ...(value.liveSnapshotId ? { liveSnapshotId: value.liveSnapshotId } : {}),
            ...(value.tubeSnapshotId ? { tubeSnapshotId: value.tubeSnapshotId } : {}) };
    } catch (error) {
        if (error instanceof PlannerError && error.code === 'CURSOR_EXPIRED') throw error;
        throw new PlannerError('INVALID_REQUEST', 'The search cursor is invalid.');
    }
}

export function journeyID(journey, version, liveContext) {
    // Scheduled IDs retain their established identity. Live results additionally
    // pin their observation/mode so another search cannot overwrite their detail.
    const identity = liveContext ? { journey, liveContext } : journey;
    return `${version}.${createHash('sha256').update(JSON.stringify(identity)).digest('hex').slice(0, 32)}`;
}

export function londonDate(instant) {
    return new Intl.DateTimeFormat('en-CA', {
        timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit'
    }).format(new Date(instant));
}

export function addDays(date, days) {
    return new Date(Date.parse(`${date}T12:00:00Z`) + days * 86400000).toISOString().slice(0, 10);
}
