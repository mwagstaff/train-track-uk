const TEST_START_STATION = {
    crs: 'TTS',
    name: 'Test start station',
    longitude: '-0.1278',
    latitude: '51.5074'
};

const TEST_END_STATION = {
    crs: 'TTE',
    name: 'Test end station',
    longitude: '-0.1180',
    latitude: '51.5010'
};

const DEFAULT_INTERVAL_MINUTES = 10;
const DEFAULT_PLATFORM = '1';
const DEFAULT_LENGTH = 8;
const DEFAULT_DEPARTURE_COUNT = 18;
const SCHEDULE_TIME_ZONE = process.env.NOTIFICATION_SCHEDULE_TIME_ZONE || 'Europe/London';

const state = {
    active: false,
    intervalMinutes: DEFAULT_INTERVAL_MINUTES,
    defaultPlatform: DEFAULT_PLATFORM,
    defaultLength: DEFAULT_LENGTH,
    startedAt: null,
    updatedAt: new Date().toISOString(),
    overrides: {}
};

export const testServiceHarness = {
    start({ intervalMinutes, defaultPlatform, defaultLength } = {}) {
        state.active = true;
        state.intervalMinutes = normalizeInterval(intervalMinutes);
        state.defaultPlatform = normalizePlatform(defaultPlatform) || DEFAULT_PLATFORM;
        state.defaultLength = normalizeLength(defaultLength) || DEFAULT_LENGTH;
        state.startedAt = new Date().toISOString();
        state.updatedAt = state.startedAt;
        pruneOverridesForCurrentServices();
        return this.getState();
    },

    stop() {
        state.active = false;
        state.updatedAt = new Date().toISOString();
        return this.getState();
    },

    reset() {
        state.active = false;
        state.intervalMinutes = DEFAULT_INTERVAL_MINUTES;
        state.defaultPlatform = DEFAULT_PLATFORM;
        state.defaultLength = DEFAULT_LENGTH;
        state.startedAt = null;
        state.updatedAt = new Date().toISOString();
        state.overrides = {};
        return this.getState();
    },

    updateDeparture(serviceID, patch = {}) {
        const id = normalizeServiceID(serviceID);
        if (!id) {
            throw new Error('service_id is required');
        }

        const existing = state.overrides[id] || {};
        const next = { ...existing };

        if (Object.prototype.hasOwnProperty.call(patch, 'delayMinutes')) {
            next.delayMinutes = normalizeDelayMinutes(patch.delayMinutes);
        }
        if (Object.prototype.hasOwnProperty.call(patch, 'isCancelled')) {
            next.isCancelled = parseBoolean(patch.isCancelled);
        }
        if (Object.prototype.hasOwnProperty.call(patch, 'platform')) {
            next.platform = normalizePlatform(patch.platform) || '';
        }
        if (Object.prototype.hasOwnProperty.call(patch, 'length')) {
            next.length = normalizeLength(patch.length) || state.defaultLength;
        }

        state.overrides[id] = next;
        state.updatedAt = new Date().toISOString();
        return this.getState();
    },

    clearDeparture(serviceID) {
        const id = normalizeServiceID(serviceID);
        if (id) {
            delete state.overrides[id];
            state.updatedAt = new Date().toISOString();
        }
        return this.getState();
    },

    getState() {
        const departures = buildDepartures({
            fromStation: TEST_START_STATION,
            toStation: TEST_END_STATION
        });
        return {
            active: state.active,
            intervalMinutes: state.intervalMinutes,
            defaultPlatform: state.defaultPlatform,
            defaultLength: state.defaultLength,
            startedAt: state.startedAt,
            updatedAt: state.updatedAt,
            route: {
                from: TEST_START_STATION,
                to: TEST_END_STATION
            },
            departures,
            overrides: { ...state.overrides }
        };
    },

    getStations() {
        return [TEST_START_STATION, TEST_END_STATION];
    },

    isTestRoute(from, to) {
        return resolveTestRoute(from, to) !== null;
    },

    getTrainTimes(from, to) {
        const route = resolveTestRoute(from, to);
        if (!route) {
            return null;
        }
        return {
            departures: state.active ? buildDepartures(route) : []
        };
    },

    getServiceDetails(serviceID) {
        const routes = [
            { fromStation: TEST_START_STATION, toStation: TEST_END_STATION },
            { fromStation: TEST_END_STATION, toStation: TEST_START_STATION }
        ];
        let departure = null;
        for (const route of routes) {
            departure = buildDepartures({ ...route, includeWhenInactive: true })
                .find((dep) => dep.serviceID === serviceID);
            if (departure) break;
        }
        if (!departure) {
            return null;
        }

        const originStation = departure.origin?.crs === TEST_END_STATION.crs
            ? TEST_END_STATION
            : TEST_START_STATION;
        const destinationStation = departure.destination?.crs === TEST_START_STATION.crs
            ? TEST_START_STATION
            : TEST_END_STATION;
        const scheduled = departure.departure_time.scheduled;
        const estimated = departure.isCancelled
            ? 'Cancelled'
            : departure.departure_time.estimated;
        const arrival = departure.isCancelled
            ? 'Cancelled'
            : addMinutesToHHmm(estimated || scheduled, 12);

        return {
            generatedAt: new Date().toISOString(),
            serviceID: departure.serviceID,
            locationName: originStation.name,
            crs: originStation.crs,
            operator: departure.operator,
            serviceType: departure.serviceType,
            length: departure.length,
            platform: departure.platform,
            std: scheduled,
            etd: estimated,
            atd: null,
            destination: [{ ...destinationStation }],
            subsequentCallingPoints: [
                {
                    callingPoint: [
                        {
                            locationName: destinationStation.name,
                            crs: destinationStation.crs,
                            st: addMinutesToHHmm(scheduled, 12),
                            et: arrival,
                            at: null,
                            isCancelled: departure.isCancelled
                        }
                    ]
                }
            ],
            previousCallingPoints: [
                {
                    callingPoint: []
                }
            ]
        };
    }
};

function buildDepartures({
    fromStation = TEST_START_STATION,
    toStation = TEST_END_STATION,
    includeWhenInactive = false
} = {}) {
    if (!state.active && !includeWhenInactive) {
        return [];
    }

    const nowMinutes = currentScheduleMinutes();
    const interval = state.intervalMinutes;
    const firstMinutes = Math.ceil(nowMinutes / interval) * interval;
    const dateKey = currentScheduleDateKey();

    return Array.from({ length: DEFAULT_DEPARTURE_COUNT }, (_, index) => {
        const scheduledMinutes = firstMinutes + (index * interval);
        const scheduled = minutesToHHmm(scheduledMinutes);
        const serviceID = `TEST-${fromStation.crs}-${toStation.crs}-${dateKey}-${scheduled.replace(':', '')}`;
        const override = state.overrides[serviceID] || {};
        const delayMinutes = normalizeDelayMinutes(override.delayMinutes);
        const isCancelled = Boolean(override.isCancelled);
        const platform = normalizePlatform(override.platform) || state.defaultPlatform;
        const length = normalizeLength(override.length) || state.defaultLength;
        const estimated = isCancelled
            ? 'Cancelled'
            : (delayMinutes > 0 ? addMinutesToHHmm(scheduled, delayMinutes) : scheduled);

        return {
            departure_time: {
                scheduled,
                estimated
            },
            operator: 'Train Track Test Harness',
            serviceType: 'train',
            delayReason: delayMinutes > 0 ? 'Synthetic delay from Train Track admin test harness' : null,
            cancelReason: isCancelled ? 'Synthetic cancellation from Train Track admin test harness' : null,
            platform,
            isCancelled,
            length,
            destination: {
                crs: toStation.crs,
                locationName: toStation.name,
                via: null
            },
            origin: {
                crs: fromStation.crs,
                locationName: fromStation.name
            },
            serviceID
        };
    });
}

function pruneOverridesForCurrentServices() {
    const serviceIDs = new Set([
        ...buildDepartures({
            fromStation: TEST_START_STATION,
            toStation: TEST_END_STATION,
            includeWhenInactive: true
        }),
        ...buildDepartures({
            fromStation: TEST_END_STATION,
            toStation: TEST_START_STATION,
            includeWhenInactive: true
        })
    ].map((dep) => dep.serviceID));
    for (const key of Object.keys(state.overrides)) {
        if (!serviceIDs.has(key)) {
            delete state.overrides[key];
        }
    }
}

function resolveTestRoute(from, to) {
    const fromCode = normalizeStationCode(from);
    const toCode = normalizeStationCode(to);
    if (fromCode === TEST_START_STATION.crs && toCode === TEST_END_STATION.crs) {
        return { fromStation: TEST_START_STATION, toStation: TEST_END_STATION };
    }
    if (fromCode === TEST_END_STATION.crs && toCode === TEST_START_STATION.crs) {
        return { fromStation: TEST_END_STATION, toStation: TEST_START_STATION };
    }
    return null;
}

function normalizeStationCode(value) {
    return typeof value === 'string' ? value.trim().toUpperCase() : '';
}

function normalizeServiceID(value) {
    return typeof value === 'string' ? value.trim() : '';
}

function normalizeInterval(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) return DEFAULT_INTERVAL_MINUTES;
    return Math.min(60, Math.max(1, Math.round(number)));
}

function normalizeDelayMinutes(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) return 0;
    return Math.min(240, Math.max(0, Math.round(number)));
}

function normalizeLength(value) {
    const number = Number(value);
    if (!Number.isFinite(number)) return null;
    return Math.min(24, Math.max(1, Math.round(number)));
}

function normalizePlatform(value) {
    if (typeof value !== 'string' && typeof value !== 'number') return null;
    const text = String(value).trim();
    return text.length > 0 ? text : null;
}

function parseBoolean(value) {
    if (value === true) return true;
    if (value === false) return false;
    if (typeof value === 'string') {
        const normalized = value.trim().toLowerCase();
        return normalized === 'true' || normalized === 'on' || normalized === '1' || normalized === 'yes';
    }
    return Boolean(value);
}

function currentScheduleMinutes(date = new Date()) {
    const parts = getScheduleTimeParts(date);
    return parts.hour * 60 + parts.minute;
}

function currentScheduleDateKey(date = new Date()) {
    const parts = getScheduleTimeParts(date);
    return `${parts.year}${parts.month}${parts.day}`;
}

function getScheduleTimeParts(date = new Date()) {
    const formatter = new Intl.DateTimeFormat('en-GB', {
        timeZone: SCHEDULE_TIME_ZONE,
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        hourCycle: 'h23'
    });
    const parts = Object.fromEntries(
        formatter
            .formatToParts(date)
            .filter((part) => part.type !== 'literal')
            .map((part) => [part.type, part.value])
    );
    return {
        year: String(parts.year || ''),
        month: String(parts.month || '').padStart(2, '0'),
        day: String(parts.day || '').padStart(2, '0'),
        hour: Number(parts.hour || '0'),
        minute: Number(parts.minute || '0')
    };
}

function minutesToHHmm(totalMinutes) {
    const minutesInDay = 24 * 60;
    const wrapped = ((totalMinutes % minutesInDay) + minutesInDay) % minutesInDay;
    const hours = Math.floor(wrapped / 60);
    const minutes = wrapped % 60;
    return `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;
}

function addMinutesToHHmm(time, minutesToAdd) {
    const [hours, minutes] = String(time || '').split(':').map(Number);
    if (!Number.isFinite(hours) || !Number.isFinite(minutes)) {
        return null;
    }
    return minutesToHHmm((hours * 60) + minutes + Number(minutesToAdd || 0));
}
