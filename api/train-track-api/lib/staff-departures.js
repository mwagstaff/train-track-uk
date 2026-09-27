import { getWithRetry } from './upstream-api-client.js';

const BOARD_URL = 'https://api1.raildata.org.uk/1010-live-departure-board---staff-version1_0/LDBSVWS/api/20220120/GetDepBoardWithDetails/';
const FRESH_MS = 30_000;
const MAX_CACHE_ENTRIES = 2000;
const london = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London',
    year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' });
const list = value => Array.isArray(value) ? value : [];
const specified = (value, field) => value[`${field}Specified`] !== false && value[field] != null;
const publicCall = value => value.isPass !== true && value.isOperational !== true
    && value.isOperationalCall !== true && value.serviceIsSupressed !== true && value.serviceIsSuppressed !== true;

export function staffServiceReference(service, station, type = 'P') {
    const scheduled = service.std?.slice(0, 19).replaceAll('-', '').replaceAll(':', '');
    const id = `staff_${service.rid}_${station}_${scheduled}_${type}`;
    return parseStaffServiceReference(id) ? id : null;
}

export function parseStaffServiceReference(id) {
    const match = /^staff_(\d{15})_([A-Z]{3})_(\d{8}T\d{6})_([PB])$/.exec(String(id));
    if (!match) return null;
    return { rid: match[1], station: match[2], scheduled: match[3], type: match[4] };
}

function boardTime(date) {
    const p = Object.fromEntries(london.formatToParts(date).map(part => [part.type, part.value]));
    return `${p.year}${p.month}${p.day}T${p.hour}${p.minute}${p.second}`;
}

function clock(value) {
    if (typeof value !== 'string') return undefined;
    // Staff datetimes are London wall times; never interpret them in the host's timezone.
    return /^\d{4}-\d{2}-\d{2}T([0-2]\d:[0-5]\d):/.exec(value)?.[1];
}

function movement(location, direction) {
    const arrival = direction === 'arrival';
    const type = arrival ? 'arrivalType' : 'departureType';
    const actual = arrival ? 'ata' : 'atd';
    const estimate = arrival ? 'eta' : 'etd';
    if (location.isCancelled === true) return { estimated: 'Cancelled' };
    const kind = specified(location, type) ? location[type] : null;
    if (kind === 'Actual' && specified(location, actual) && clock(location[actual])) {
        return { actual: clock(location[actual]), estimated: clock(location[actual]) };
    }
    if (kind === 'Forecast' && specified(location, estimate) && clock(location[estimate])) {
        return { estimated: clock(location[estimate]) };
    }
    return { estimated: 'Delayed' };
}

function reason(value) {
    // Reason codes are not passenger-facing descriptions. Preserve textual reasons
    // when supplied, but never invent a description from a numeric staff code.
    return typeof value === 'string' ? value : undefined;
}

function places(values) {
    return list(values).filter(place => !place.isOperationalEndPoint).map(place => ({
        crs: place.crs, locationName: place.locationName, via: place.via
    }));
}

function callingPoints(locations, service, previous = false) {
    return list(locations).filter(location => publicCall(location) && location.crs).map(location => {
        const direction = previous && specified(location, 'std') ? 'departure'
            : specified(location, 'sta') ? 'arrival' : 'departure';
        const times = movement(location, direction);
        return {
            locationName: location.locationName, crs: location.crs,
            st: clock(location[direction === 'arrival' ? 'sta' : 'std']) || 'Unknown',
            et: times.actual ? undefined : times.estimated, at: times.actual,
            isCancelled: location.isCancelled === true,
            cancelReason: reason(location.cancelReason),
            platform: location.platformIsHidden ? undefined : location.platform,
            length: location.length ?? service.length, detachFront: location.detachFront,
            affectedByDiversion: location.affectedByDiversion
        };
    });
}

export function normalizeStaffDepartureBoard(raw, { station, destination, type = 'P', serviceID }) {
    if (!raw || raw.crs !== station || !Number.isFinite(Date.parse(raw.generatedAt))
        || raw.servicesAreUnavailable === true || raw.isTruncated === true) {
        throw new Error('Staff departure board unavailable or truncated');
    }
    if (destination && String(raw.filtercrs || raw.filterCrs || '').toUpperCase() !== destination) {
        throw new Error('Staff departure board filter mismatch');
    }
    const field = type === 'B' ? 'busServices' : 'trainServices';
    if (raw[field] != null && !Array.isArray(raw[field])) throw new Error('Malformed staff departure board');
    const details = new Map();
    const services = list(raw[field]).filter(service => (!serviceID || staffServiceReference(service, station, type) === serviceID)
        && publicCall(service)
        && service.isPassengerService !== false && service.isDeleted !== true
        && service.filterLocationOperational !== true).map(service => {
        const destinations = places(service.destination);
        // The public adapter already handles portions. Do not silently turn a
        // dividing train into a single branch during this migration.
        const associations = [...list(service.previousLocations), service, ...list(service.subsequentLocations)]
            .flatMap(location => list(location.associations));
        if (destinations.length > 1 || associations.some(a => /^(divide|join)$/i.test(a.category))) {
            throw new Error('Staff service requires associated public branches');
        }
        const serviceID = staffServiceReference(service, station, type);
        if (!serviceID || !specified(service, 'std') || !clock(service.std)) throw new Error('Invalid staff service identity');
        const arrival = movement(service, 'arrival');
        const departure = movement(service, 'departure');
        const platformIsHidden = raw.platformsAreHidden === true || service.platformIsHidden === true;
        const platform = platformIsHidden ? undefined : service.platform;
        const shared = {
            serviceType: type === 'B' ? 'bus' : 'train', operator: service.operator,
            operatorCode: service.operatorCode, isCancelled: service.isCancelled === true,
            platform, length: service.length, delayReason: reason(service.delayReason), cancelReason: reason(service.cancelReason)
        };
        details.set(serviceID, {
            ...shared, generatedAt: raw.generatedAt, locationName: raw.locationName, crs: station,
            sta: specified(service, 'sta') ? clock(service.sta) : undefined,
            std: clock(service.std), eta: arrival.actual ? undefined : arrival.estimated, ata: arrival.actual,
            etd: departure.actual ? undefined : departure.estimated, atd: departure.actual,
            previousCallingPoints: [{ callingPoint: callingPoints(service.previousLocations, service, true) }],
            subsequentCallingPoints: [{ callingPoint: callingPoints(service.subsequentLocations, service) }],
            detachFront: service.detachFront, isReverseFormation: service.isReverseFormation
        });
        return {
            ...shared, serviceID, std: clock(service.std), etd: departure.estimated, atd: departure.actual,
            origin: places(service.origin), destination: destinations,
            platformIsHidden,
            filterLocationCancelled: service.filterLocationCancelled === true,
            futureCancellation: service.futureCancellation === true,
            // Scope this flag to the requested journey, not the train as a whole.
            filtercrs: destination, filterLocationName: raw.filterLocationName
        };
    });
    return { board: { generatedAt: raw.generatedAt, filtercrs: destination,
        filterLocationName: raw.filterLocationName, [field]: services }, details };
}

export class StaffDepartures {
    constructor({ request = getWithRetry, now = Date.now,
        credentials = () => process.env.LIVE_DEPARTURE_BOARD_STAFF_VERSION_API_KEY || process.env.STAFF_DEPARTURES_API_KEY } = {}) {
        this.request = request;
        this.now = now;
        this.credentials = credentials;
        this.details = new Map();
        this.inflight = new Map();
    }

    get enabled() { return Boolean(this.credentials()); }

    async requestBoard(station, time, { destination, type = 'P', serviceID, signal, timeoutMs = 3000 } = {}) {
        const query = new URLSearchParams({ numRows: '149', timeWindow: serviceID ? '2' : '120', services: type });
        if (destination) { query.set('filterCRS', destination); query.set('filterType', 'to'); }
        const response = await this.request({ api: 'rail_staff_departure_board', operation: 'get_departure_board_with_details',
            url: `${BOARD_URL}${station}/${time}?${query}`, headers: { 'x-apikey': this.credentials() },
            maxRetries: 0, timeoutMs, signal });
        return normalizeStaffDepartureBoard(response.data, { station, destination, type, serviceID });
    }

    remember(entries) {
        for (const [id, details] of entries) {
            const existing = this.details.get(id);
            if (existing && Date.parse(existing.value.generatedAt) > Date.parse(details.generatedAt)) continue;
            this.details.delete(id);
            this.details.set(id, { value: details, fetchedAt: this.now() });
        }
        while (this.details.size > MAX_CACHE_ENTRIES) this.details.delete(this.details.keys().next().value);
    }

    async getBoard(station, destination, offset, options = {}) {
        const time = boardTime(new Date(this.now() + offset * 60_000));
        // Replacement buses are a separate staff query; never lose them by
        // accepting a successful train-only board when the bus query fails.
        const results = await Promise.all(['P', 'B'].map(type => this.requestBoard(station, time,
            { ...options, destination, type })));
        for (const result of results) this.remember(result.details);
        return { ...results[0].board, busServices: results[1].board.busServices,
            generatedAt: results.map(result => result.board.generatedAt).sort()[0] };
    }

    async getDetails(id) {
        const reference = parseStaffServiceReference(id);
        if (!reference) return { error: 'Invalid staff service reference', unavailable: true };
        const cached = this.details.get(id);
        if (cached && Date.parse(cached.value.generatedAt) <= this.now() + 5000 && this.now() - cached.fetchedAt < FRESH_MS
            && this.now() - Date.parse(cached.value.generatedAt) < FRESH_MS) return structuredClone(cached.value);
        if (this.inflight.has(id)) return this.inflight.get(id);
        const promise = (async () => {
            if (!this.enabled) return { error: 'Staff service data unavailable' };
            try {
                const result = await this.requestBoard(reference.station, reference.scheduled, { type: reference.type, serviceID: id });
                this.remember(result.details);
                // Exact RID, station, dated departure and transport type: never
                // substitute a nearby departure, or yesterday's train after midnight.
                const detail = result.details.has(id) ? this.details.get(id)?.value : null;
                return detail ? structuredClone(detail) : { error: 'Service no longer available', unavailable: true };
            } catch {
                return { error: 'Staff service lookup failed' };
            }
        })().finally(() => this.inflight.delete(id));
        this.inflight.set(id, promise);
        return promise;
    }
}

export const staffDepartures = new StaffDepartures();
