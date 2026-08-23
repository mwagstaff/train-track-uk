import { COLLECTIONS, getMongoCollection } from './mongo-client.js';

export const RECENT_DEPARTURE_LOOKBACK_MS = 2 * 60 * 60 * 1000;
export const RECENT_DEPARTURE_UPCOMING_MS = 10 * 60 * 1000;

const RAIL_TIME_ZONE = 'Europe/London';
const railDateFormatter = new Intl.DateTimeFormat('en-GB', {
    timeZone: RAIL_TIME_ZONE,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23'
});

export class RecentDeparturesRepository {
    constructor({ getCollection = getMongoCollection, now = () => new Date() } = {}) {
        this.getCollection = getCollection;
        this.now = now;
    }

    async recordDepartures(fromStation, toStation, departures = []) {
        const fromCRS = normalizeCRS(fromStation);
        const toCRS = normalizeCRS(toStation);
        if (!fromCRS || !toCRS || !Array.isArray(departures) || departures.length === 0) return 0;

        const observedAt = this.now();
        const lowerBound = new Date(observedAt.getTime() - RECENT_DEPARTURE_LOOKBACK_MS);
        const upperBound = new Date(observedAt.getTime() + RECENT_DEPARTURE_UPCOMING_MS);
        const writes = departures.flatMap((departure) => {
            const serviceID = normalizeString(departure?.serviceID);
            const scheduledDisplay = normalizeString(departure?.departure_time?.scheduled);
            const scheduledDepartureAt = railDateNear(scheduledDisplay, observedAt);
            if (!serviceID || !scheduledDepartureAt
                || scheduledDepartureAt < lowerBound
                || scheduledDepartureAt > upperBound) {
                return [];
            }

            const estimatedDisplay = normalizeString(departure?.departure_time?.estimated);
            const reportedActual = normalizeString(
                departure?.departure_time?.actual
                || departure?.actualDepartureTime
                || departure?.atd
            );
            const actualDisplay = reportedActual.toLowerCase() === 'on time'
                ? scheduledDisplay
                : reportedActual;
            const estimatedDepartureAt = railDateNear(estimatedDisplay, scheduledDepartureAt);
            const actualDepartureAt = railDateNear(actualDisplay, scheduledDepartureAt);
            const expiryAnchor = actualDepartureAt || scheduledDepartureAt;
            const expiresAt = new Date(expiryAnchor.getTime() + RECENT_DEPARTURE_LOOKBACK_MS);
            const identity = `${fromCRS}:${toCRS}:${serviceID}:${scheduledDepartureAt.toISOString()}`;

            const set = {
                fromCRS,
                toCRS,
                serviceID,
                serviceType: normalizeString(departure?.serviceType) || 'train',
                scheduledDepartureAt,
                scheduledDeparture: scheduledDisplay,
                isCancelled: Boolean(departure?.isCancelled),
                lastObservedAt: observedAt
            };
            assignIfPresent(set, 'estimatedDepartureAt', estimatedDepartureAt);
            assignIfPresent(set, 'estimatedDeparture', estimatedDisplay);
            assignIfPresent(set, 'actualDepartureAt', actualDepartureAt);
            assignIfPresent(set, 'actualDeparture', actualDisplay);
            assignIfPresent(set, 'platform', normalizeString(departure?.platform));

            return [{
                updateOne: {
                    filter: { _id: identity },
                    update: {
                        $set: set,
                        $setOnInsert: { firstObservedAt: observedAt },
                        $max: { expiresAt }
                    },
                    upsert: true
                }
            }];
        });

        if (writes.length === 0) return 0;
        const collection = await this.getCollection(COLLECTIONS.recentDepartures);
        await collection.bulkWrite(writes, { ordered: false });
        return writes.length;
    }

    async recentDepartures(fromStation, toStation) {
        const fromCRS = normalizeCRS(fromStation);
        const toCRS = normalizeCRS(toStation);
        if (!fromCRS || !toCRS) return [];

        const now = this.now();
        const lowerBound = new Date(now.getTime() - RECENT_DEPARTURE_LOOKBACK_MS);
        const upperBound = new Date(now.getTime() + RECENT_DEPARTURE_UPCOMING_MS);
        const collection = await this.getCollection(COLLECTIONS.recentDepartures);
        const documents = await collection.find({
            fromCRS,
            toCRS,
            expiresAt: { $gt: now },
            $or: [
                { actualDepartureAt: { $gte: lowerBound, $lte: upperBound } },
                {
                    actualDepartureAt: { $exists: false },
                    scheduledDepartureAt: { $gte: lowerBound, $lte: upperBound }
                }
            ]
        }).sort({ scheduledDepartureAt: -1 }).limit(32).toArray();

        return documents.map(serializeRecentDeparture);
    }

    async debugDepartures({ pastOnly = false } = {}) {
        const now = this.now();
        const filter = { expiresAt: { $gt: now } };
        if (pastOnly) filter.scheduledDepartureAt = { $lt: now };
        const collection = await this.getCollection(COLLECTIONS.recentDepartures);
        const documents = await collection.find(filter)
            .sort({ scheduledDepartureAt: -1 })
            .limit(500)
            .toArray();
        return documents.map(serializeRecentDeparture);
    }
}

export const recentDeparturesRepository = new RecentDeparturesRepository();

export function railDateNear(value, reference = new Date()) {
    const match = /^(\d{1,2}):(\d{2})$/.exec(normalizeString(value));
    if (!match) return null;
    const hour = Number(match[1]);
    const minute = Number(match[2]);
    if (hour > 23 || minute > 59) return null;

    const referenceParts = railDateParts(reference);
    const baseDay = Date.UTC(referenceParts.year, referenceParts.month - 1, referenceParts.day);
    const candidates = [-1, 0, 1].map((offset) => {
        const day = new Date(baseDay + (offset * 24 * 60 * 60 * 1000));
        return dateInRailTimeZone(
            day.getUTCFullYear(),
            day.getUTCMonth() + 1,
            day.getUTCDate(),
            hour,
            minute
        );
    });
    return candidates.reduce((best, candidate) => (
        Math.abs(candidate.getTime() - reference.getTime()) < Math.abs(best.getTime() - reference.getTime())
            ? candidate
            : best
    ));
}

function dateInRailTimeZone(year, month, day, hour, minute) {
    const desiredUTC = Date.UTC(year, month - 1, day, hour, minute);
    let candidate = new Date(desiredUTC);
    for (let attempt = 0; attempt < 3; attempt += 1) {
        const represented = railDateParts(candidate);
        const representedUTC = Date.UTC(
            represented.year,
            represented.month - 1,
            represented.day,
            represented.hour,
            represented.minute
        );
        const correction = desiredUTC - representedUTC;
        if (correction === 0) break;
        candidate = new Date(candidate.getTime() + correction);
    }
    return candidate;
}

function railDateParts(date) {
    const parts = Object.fromEntries(
        railDateFormatter.formatToParts(date)
            .filter((part) => part.type !== 'literal')
            .map((part) => [part.type, Number(part.value)])
    );
    return parts;
}

function serializeRecentDeparture(document) {
    return {
        serviceID: document.serviceID,
        serviceType: document.serviceType,
        fromCRS: document.fromCRS,
        toCRS: document.toCRS,
        scheduledDeparture: document.scheduledDeparture,
        estimatedDeparture: document.estimatedDeparture || null,
        actualDeparture: document.actualDeparture || null,
        scheduledDepartureAt: document.scheduledDepartureAt?.toISOString?.() || document.scheduledDepartureAt,
        estimatedDepartureAt: document.estimatedDepartureAt?.toISOString?.() || document.estimatedDepartureAt || null,
        actualDepartureAt: document.actualDepartureAt?.toISOString?.() || document.actualDepartureAt || null,
        platform: document.platform || null,
        isCancelled: Boolean(document.isCancelled),
        lastObservedAt: document.lastObservedAt?.toISOString?.() || document.lastObservedAt
    };
}

function normalizeCRS(value) {
    return normalizeString(value).toUpperCase();
}

function normalizeString(value) {
    return typeof value === 'string' ? value.trim() : '';
}

function assignIfPresent(target, key, value) {
    if (value !== null && value !== undefined && value !== '') target[key] = value;
}
