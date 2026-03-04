import moment from 'moment';
import { getWithRetry } from './upstream-api-client.js';

import { pastDeparturesCache } from './past-departures-cache.js';

// Cache the most recent known platform for a service so we can keep showing it
// when upstream drops platform data very close to departure.
const platformFallbackCache = new Map();
const PLATFORM_CACHE_CLEANUP_INTERVAL_MS = 60 * 60 * 1000;
const PLATFORM_CACHE_ENTRY_TTL_MS = 6 * 60 * 60 * 1000;
const PLATFORM_FALLBACK_WINDOW_BEFORE_DEPARTURE_MINUTES = 5;
const PLATFORM_FALLBACK_WINDOW_AFTER_DEPARTURE_MINUTES = 20;

const platformCacheCleanupTimer = setInterval(() => {
    cleanupPlatformFallbackCache();
}, PLATFORM_CACHE_CLEANUP_INTERVAL_MS);
if (typeof platformCacheCleanupTimer.unref === 'function') {
    platformCacheCleanupTimer.unref();
}

export async function getTrainTimes(from, to) {
    // Only fetch now and future; past cache refresh is handled separately
    const [departuresNow, departuresFuture] = await Promise.all([
        getLiveDepartureBoard(from, to, 0),
        getLiveDepartureBoard(from, to, 119)
    ]);

    // Gracefully handle partial failures: merge whichever arrays are available
    const nowList = Array.isArray(departuresNow.departures) ? departuresNow.departures : [];
    const futureList = Array.isArray(departuresFuture.departures) ? departuresFuture.departures : [];
    if (nowList.length === 0 && futureList.length === 0) {
        return { error: 'Failed to get data from API' };
    }
    const departures = nowList.concat(futureList);
    // Dedupe by serviceID and prefer entries that still have a platform.
    const uniqueByService = new Map();
    departures.forEach((departure) => {
        const existing = uniqueByService.get(departure.serviceID);
        if (!existing || shouldPreferDeparture(existing, departure)) {
            uniqueByService.set(departure.serviceID, departure);
        }
    });
    const uniqueDepartures = Array.from(uniqueByService.values());

    applyPlatformFallbackCache(uniqueDepartures, from, to);

    // Return both departures as one array
    return {
        departures: uniqueDepartures
    };
}

// Track in-flight past refreshes to avoid duplicate upstream calls per route
const inFlightPastRefreshes = new Map();
const lastPastRefresh = new Map();
const REFRESH_COOLDOWN_MS = 30_000; // throttle per route

// Lightweight refresher for the past departures cache that only calls the
// "past" offset and updates the cache. Safe, deduplicated, and can be fired
// in the background without blocking HTTP responses.
export function refreshPastDepartures(from, to) {
    const key = `${from || ''}-${to || ''}`;
    // Throttle refreshes per route to avoid hammering upstream
    const last = lastPastRefresh.get(key) || 0;
    if (Date.now() - last < REFRESH_COOLDOWN_MS) {
        return Promise.resolve();
    }
    if (inFlightPastRefreshes.has(key)) {
        return inFlightPastRefreshes.get(key);
    }

    const promise = (async () => {
        try {
            if (!from || !to) return;
            const result = await getLiveDepartureBoard(from, to, -60);
            if (result && result.departures) {
                result.departures.forEach(dep => pastDeparturesCache.addOrUpdateDeparture(from, to, dep));
            }
        } catch (error) {
            const status = error?.response?.status;
            const statusText = error?.response?.statusText;
            const code = error?.code;
            const message = error?.message;
            console.error(`Failed to refresh past departures for ${from} -> ${to} (code=${code || 'n/a'}, status=${status || 'n/a'} ${statusText || ''}): ${message || ''}`);
        } finally {
            lastPastRefresh.set(key, Date.now());
            inFlightPastRefreshes.delete(key);
        }
    })();

    inFlightPastRefreshes.set(key, promise);
    return promise;
}

// Fetches data from the live departure board API to provide upcoming departures
async function getLiveDepartureBoard(from, to, offset) {
    if (!from || !to) {
        return { error: `Missing from (${from}) or to (${to}) parameter` };
    }
    const url = to && to.length > 0 ? `https://api1.raildata.org.uk/1010-live-departure-board-dep1_2/LDBWS/api/20220120/GetDepartureBoard/${from}?filterCrs=${to}&filterType=to&timeOffset=${offset}` : `https://api1.raildata.org.uk/1010-live-departure-board-dep1_2/LDBWS/api/20220120/GetDepartureBoard/${from}?timeOffset=${offset}`;
    try {
        const start = Date.now();
        const response = await getWithRetry({
            api: 'rail_departure_board',
            operation: 'get_departure_board',
            url,
            headers: {
                'x-apikey': process.env.LIVE_DEPARTURE_BOARD_API_KEY
            }
        });
        const elapsed = Date.now() - start;
        if (elapsed > 5000) {
            console.warn(`Slow upstream: ${from}->${to} offset=${offset} took ${elapsed}ms`);
        }
        return parseResponseDataLiveDepartureBoard(response.data);
    } catch (error) {
        const status = error?.response?.status;
        const statusText = error?.response?.statusText;
        const code = error?.code;
        const message = error?.message;
        console.error(`Failed to get data from API for journey ${from} to ${to} with offset ${offset} (code=${code || 'n/a'}, status=${status || 'n/a'} ${statusText || ''}): ${message || ''}`);
        return { error: 'Failed to get data from API' };
    }
}

// Check if the estimated departure time is "On time" and if so, return the scheduled departure time
function getEstimatedDepartureTime(scheduled, estimated) {
    if (estimated === 'On time') {
        return scheduled;
    } else {
        return estimated;
    }
}

// Parse the response data to strip out unnecessary fields
async function parseResponseDataLiveDepartureBoard(data) {

    let departures = [];

    try {
        // In the data, iterate through each object in the trainServices array and extract the relevant fields
        if (data.trainServices) {
            departures = data.trainServices.map(trainService => {
                return {
                    departure_time: {
                        scheduled: trainService.std,
                        estimated: getEstimatedDepartureTime(trainService.std, trainService.etd)
                    },
                    operator: trainService.operator,
                    serviceType: trainService.serviceType,
                    delayReason: trainService.delayReason,
                    cancelReason: trainService.cancelReason,
                    platform: trainService.platform,
                    isCancelled: trainService.isCancelled,
                    length: trainService.length,
                    destination: {
                        crs: trainService.destination[0].crs,
                        locationName: trainService.destination[0].locationName,
                        via: trainService.destination[0].via
                    },
                    origin: {
                        crs: trainService.origin[0].crs,
                        locationName: trainService.origin[0].locationName
                    },
                    serviceID: trainService.serviceID
                }
            });
        }

        // Concat the same data for bus services
        if (data.busServices) {
            departures = departures.concat(data.busServices.map(busService => {
                return {
                    departure_time: {
                        scheduled: busService.std,
                        estimated: getEstimatedDepartureTime(busService.std, busService.etd)
                    },
                    serviceType: busService.serviceType,
                    delayReason: busService.delayReason,
                    cancelReason: busService.cancelReason,
                    platform: busService.platform,
                    isCancelled: busService.isCancelled,
                    length: busService.length,
                    destination: {
                        locationName: busService.destination[0].locationName
                    },
                    serviceID: busService.serviceID
                }
            }));
        }

        return { departures };
    } catch (error) {
        console.error(`Failed to parse response data: ${error}`);
        return { error: 'Failed to parse response data', error };
    }
}

function shouldPreferDeparture(current, candidate) {
    const currentPlatform = normalizePlatform(current?.platform);
    const candidatePlatform = normalizePlatform(candidate?.platform);

    if (!currentPlatform && candidatePlatform) {
        return true;
    }
    if (currentPlatform && !candidatePlatform) {
        return false;
    }
    return false;
}

function normalizePlatform(platform) {
    if (typeof platform !== 'string') {
        return null;
    }
    const trimmed = platform.trim();
    return trimmed.length > 0 ? trimmed : null;
}

function platformCacheKey(from, to, serviceID) {
    return `${(from || '').toUpperCase()}-${(to || '').toUpperCase()}-${serviceID || ''}`;
}

function parseServiceDepartureTime(timeString, reference = moment()) {
    if (!timeString || !moment(timeString, 'HH:mm', true).isValid()) {
        return null;
    }

    const parsed = moment(timeString, 'HH:mm');
    const candidate = reference.clone()
        .hour(parsed.hour())
        .minute(parsed.minute())
        .second(0)
        .millisecond(0);

    const deltaHours = candidate.diff(reference, 'hours', true);
    if (deltaHours > 12) {
        return candidate.subtract(1, 'day');
    }
    if (deltaHours < -12) {
        return candidate.add(1, 'day');
    }
    return candidate;
}

function isNearDepartureWindow(timeString, now = moment()) {
    const departureTime = parseServiceDepartureTime(timeString, now);
    if (!departureTime) {
        return false;
    }
    const minutesFromNow = departureTime.diff(now, 'minutes', true);
    return minutesFromNow <= PLATFORM_FALLBACK_WINDOW_BEFORE_DEPARTURE_MINUTES &&
        minutesFromNow >= -PLATFORM_FALLBACK_WINDOW_AFTER_DEPARTURE_MINUTES;
}

function cleanupPlatformFallbackCache() {
    const nowMs = Date.now();
    for (const [key, entry] of platformFallbackCache.entries()) {
        if (!entry || !entry.lastUpdatedAtMs || (nowMs - entry.lastUpdatedAtMs) > PLATFORM_CACHE_ENTRY_TTL_MS) {
            platformFallbackCache.delete(key);
        }
    }
}

function applyPlatformFallbackCache(departures, from, to) {
    if (!Array.isArray(departures) || departures.length === 0) {
        return;
    }

    const now = moment();
    const nowMs = now.valueOf();

    departures.forEach((departure) => {
        if (!departure?.serviceID) {
            return;
        }

        const key = platformCacheKey(from, to, departure.serviceID);
        const currentPlatform = normalizePlatform(departure.platform);
        const cached = platformFallbackCache.get(key);

        if (currentPlatform) {
            platformFallbackCache.set(key, {
                platform: currentPlatform,
                fallbackActive: false,
                lastUpdatedAtMs: nowMs
            });
            departure.platform = currentPlatform;
            return;
        }

        if (!cached?.platform) {
            return;
        }

        const shouldUseFallback = cached.fallbackActive ||
            isNearDepartureWindow(departure?.departure_time?.scheduled, now);
        if (!shouldUseFallback) {
            return;
        }

        departure.platform = cached.platform;
        platformFallbackCache.set(key, {
            ...cached,
            fallbackActive: true,
            lastUpdatedAtMs: nowMs
        });
    });
}
