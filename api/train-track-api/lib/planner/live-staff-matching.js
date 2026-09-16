import { createHash } from 'node:crypto';

const london = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/London', year: 'numeric', month: '2-digit',
    day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
const list = value => Array.isArray(value) ? value : [];
const specified = (value, field) => value[`${field}Specified`] !== false && value[field] != null;
const identity = (uid, date, operator) => `${uid}|${date}|${operator}`;
const publicCall = location => !location.isPass && !location.isOperational && !location.isOperationalCall;

// Staff timestamps without an offset are London wall times, not the Node
// process's local zone. Keep dates and seconds; reject repeated autumn hours.
function timestamp(value) {
    if (typeof value !== 'string') return undefined;
    const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})?$/.exec(value);
    if (!match) return undefined;
    const [, year, month, day, hour, minute, second, fraction = '', offset] = match;
    const wall = Date.UTC(+year, +month - 1, +day, +hour, +minute, +second, +(fraction + '000').slice(0, 3));
    const date = `${year}-${month}-${day}`;
    const clock = `${hour}:${minute}:${second}`;
    if (!Number.isFinite(wall) || new Date(wall).toISOString().slice(0, 19) !== `${date}T${clock}`) return undefined;
    if (offset) {
        if (offset === 'Z') return wall;
        const hours = +offset.slice(1, 3), minutes = +offset.slice(4, 6);
        if (hours > 23 || minutes > 59) return undefined;
        return wall - (offset[0] === '+' ? 1 : -1) * (hours * 60 + minutes) * 60000;
    }
    const candidates = [wall, wall - 3600000].filter(time => {
        const parts = Object.fromEntries(london.formatToParts(time).map(part => [part.type, part.value]));
        return `${parts.year}-${parts.month}-${parts.day}` === date && `${parts.hour}:${parts.minute}:${parts.second}` === clock;
    });
    return candidates.length === 1 ? candidates[0] : undefined;
}

function originDate(value) {
    if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}(?:T00:00:00(?:\.0+)?(?:Z|[+-]\d{2}:\d{2})?)?$/.test(value)) return undefined;
    const date = value.slice(0, 10);
    return Number.isFinite(timestamp(`${date}T12:00:00Z`)) ? date : undefined;
}

function publicLocations(item, station) {
    if (item.isPassengerService === false || item.isDeleted === true || item.isOperationalCall === true) return null;
    const locations = [...list(item.previousLocations), { ...item, crs: station }, ...list(item.subsequentLocations)]
        .filter(publicCall);
    if (locations.some(location => location.serviceIsSupressed === true || location.serviceIsSuppressed === true)) return null;
    return locations;
}

function matchesSchedule(service, locations, check) {
    if (service.calls.length !== locations.length || locations.length < 2) return false;
    return locations.every((location, index) => {
        check();
        const call = service.calls[index];
        if (location.crs !== call.station || (location.tiploc && location.tiploc !== call.tiploc)) return false;
        for (const [field, scheduled] of [['sta', call.arrival], ['std', call.departure]]) {
            const time = specified(location, field) ? timestamp(location[field]) : undefined;
            if (Number.isFinite(scheduled) ? time !== scheduled : specified(location, field)) return false;
        }
        return true;
    });
}

function callUpdate(location, call, index, observedAt) {
    const update = { index, observedAt, warnings: [], cancelled: location.isCancelled === true };
    if (Number.isInteger(location.length) && location.length > 0) update.length = location.length;
    if (location.platformIsHidden === true) update.platform = '';
    else if (typeof location.platform === 'string' && location.platform) update.platform = location.platform;
    if (location.uncertainty) update.warnings.push('This train may be affected by disruption; no confirmed change is available yet.');
    for (const [direction, scheduled, estimate, actual, type] of [
        ['arrival', call.arrival, 'eta', 'ata', 'arrivalType'],
        ['departure', call.departure, 'etd', 'atd', 'departureType']
    ]) {
        if (!Number.isFinite(scheduled) || update.cancelled) continue;
        const kind = specified(location, type) ? location[type] : undefined;
        const field = kind === 'Actual' ? actual : kind === 'Forecast' ? estimate : undefined;
        const time = field && specified(location, field) ? timestamp(location[field]) : undefined;
        if (Number.isFinite(time)) update[direction] = time;
        else update[`${direction}Unknown`] = true;
    }
    return update;
}

/** Optional recovery for explicitly requested, publicly unresolved occurrences.
 * UID/date/operator identify candidates; the complete ordered public schedule
 * verifies the selected variant. Associations never extend or join its calls.
 * https://realtime.nationalrail.co.uk/LDBSVWS/static/ldbsvws.json
 */
export function matchStaffObservations(network, records, { now = Date.now(), check = () => {}, ttlMs = 90000, serviceIds = [] } = {}) {
    const allowed = new Set(serviceIds);
    const wanted = new Set();
    for (const service of network.services) {
        check();
        if (allowed.has(service.id)) wanted.add(identity(service.uid, service.originDate, service.operator));
    }
    const candidates = new Map();
    for (const service of network.services) {
        check();
        const key = identity(service.uid, service.originDate, service.operator);
        if (!wanted.has(key)) continue;
        if (!candidates.has(key)) candidates.set(key, []);
        candidates.get(key).push(service);
    }
    const updates = new Map();
    const diagnostics = [];
    const diagnostic = (reason, record, matches) => {
        if (diagnostics.length < 512) diagnostics.push({ reason, station: record.station,
            candidateServiceIds: matches.filter(service => allowed.has(service.id)).map(service => service.id) });
    };
    for (const record of list(records)) {
        check();
        const observedAt = typeof record.generatedAt === 'string' && /(?:Z|[+-]\d{2}:\d{2})$/.test(record.generatedAt)
            ? timestamp(record.generatedAt) : undefined;
        for (const item of list(record.services)) {
            check();
            if (typeof item.uid !== 'string' || !item.uid || typeof item.rid !== 'string' || !item.rid
                || typeof item.operatorCode !== 'string' || !item.operatorCode || !originDate(item.sdd)) continue;
            const matches = candidates.get(identity(item.uid, originDate(item.sdd), item.operatorCode)) || [];
            if (!matches.length) continue;
            if (!Number.isFinite(observedAt) || observedAt > now + 5000 || now - observedAt > ttlMs) {
                diagnostic('stale', record, matches); continue;
            }
            const locations = publicLocations(item, record.station);
            if (!locations) { diagnostic('suppressed', record, matches); continue; }
            const verified = matches.filter(service => matchesSchedule(service, locations, check));
            if (verified.length !== 1) { diagnostic(verified.length ? 'ambiguous' : 'mismatch', record, matches); continue; }
            const service = verified[0];
            if (!allowed.has(service.id)) continue;
            const previous = updates.get(service.id);
            if (previous && previous.observedAt > observedAt) continue;
            const update = { serviceId: service.id, observedAt, warnings: [],
                calls: locations.map((location, index) => callUpdate(location, service.calls[index], index, observedAt)) };
            const anchor = list(item.previousLocations).filter(publicCall).length;
            const later = update.calls.filter(call => call.index > anchor);
            if (item.futureCancellation && !later.some(call => call.cancelled)) {
                update.unknownCancellationFromIndex = anchor;
                update.warnings.push('A cancellation is reported later on this train, but the affected stops are not confirmed.');
            }
            if (item.futureDelay && !later.some(call => call.arrivalUnknown || call.departureUnknown
                || call.arrival > service.calls[call.index].arrival || call.departure > service.calls[call.index].departure)) {
                update.unknownDelayFromIndex = anchor;
                update.warnings.push('A delay is reported later on this train, but the affected times are not confirmed.');
            }
            if (previous?.observedAt === observedAt) {
                // Equal-age conflicting responses must not let completion order
                // clear a cancellation or manufacture a confirmed forecast.
                for (const call of update.calls) {
                    const old = previous.calls[call.index];
                    call.cancelled ||= old.cancelled;
                    if (old.platform === '') call.platform = '';
                    for (const direction of ['arrival', 'departure']) {
                        if (call[direction] !== old[direction] || old[`${direction}Unknown`]) {
                            delete call[direction];
                            call[`${direction}Unknown`] = true;
                        }
                    }
                    call.warnings = [...new Set([...old.warnings, ...call.warnings])];
                }
                for (const field of ['unknownCancellationFromIndex', 'unknownDelayFromIndex']) {
                    if (Number.isInteger(previous[field])) update[field] = Math.min(previous[field], update[field] ?? Infinity);
                }
                update.warnings = [...new Set([...previous.warnings, ...update.warnings])];
            }
            updates.set(service.id, update);
        }
    }
    const services = [...updates.values()];
    const observedAt = Math.min(now, ...services.map(service => service.observedAt));
    const id = createHash('sha256').update(JSON.stringify(services)).digest('hex');
    return { id, observedAt, expiresAt: observedAt + ttlMs, services, diagnostics, matchedCount: services.length, warnings: [] };
}
