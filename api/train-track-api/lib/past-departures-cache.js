import moment from 'moment';

class PastDeparturesCache {
    constructor() {
        this.cache = new Map();
        this.startCleanupJob();
    }

    addOrUpdateDeparture(fromStation, toStation, departure) {
        const key = this.generateKey(fromStation, toStation, departure.serviceID);
        const cacheEntry = {
            fromStation,
            toStation,
            scheduledDepartureTime: departure.departure_time?.scheduled,
            estimatedDepartureTime: departure.departure_time?.estimated,
            isCancelled: departure.isCancelled,
            platform: departure.platform,
            length: departure.length,
            serviceID: departure.serviceID,
            operator: departure.operator,
            destination: departure.destination,
            origin: departure.origin,
            timestamp: moment().toISOString()
        };
        
        this.cache.set(key, cacheEntry);
    }

    getPastDepartures(fromStation, toStation) {
        const results = [];
        for (const [key, entry] of this.cache.entries()) {
            if (entry.fromStation === fromStation && entry.toStation === toStation) {
                // Prefer a valid HH:mm estimated time, otherwise fall back to scheduled
                const departureTime = this.getComparableTime(entry);
                if (this.isDepartureInPast(departureTime) && !this.isExpired(entry.timestamp)) {
                    results.push(entry);
                }
            }
        }
        
        return results.sort((a, b) => {
            const timeA = moment(this.getComparableTime(a), 'HH:mm');
            const timeB = moment(this.getComparableTime(b), 'HH:mm');
            return timeB.diff(timeA);
        });
    }

    getAllPastDepartures() {
        const results = [];
        for (const [key, entry] of this.cache.entries()) {
            if (this.isDepartureInPast(entry.scheduledDepartureTime) && !this.isExpired(entry.timestamp)) {
                results.push(entry);
            }
        }
        
        return results.sort((a, b) => {
            const timeA = moment(a.scheduledDepartureTime, 'HH:mm');
            const timeB = moment(b.scheduledDepartureTime, 'HH:mm');
            return timeB.diff(timeA);
        });
    }

    // Returns a time string in HH:mm for comparison: prefer estimated if it's a valid time, else scheduled
    getComparableTime(entry) {
        const est = entry.estimatedDepartureTime;
        if (est && moment(est, 'HH:mm', true).isValid()) {
            return est;
        }
        return entry.scheduledDepartureTime;
    }

    isDepartureInPast(scheduledTime) {
        if (!scheduledTime) return false;
        
        const now = moment();
        let departureTime = moment(scheduledTime, 'HH:mm');
        
        // Set the departure time to today
        departureTime.year(now.year()).month(now.month()).date(now.date());
        
        // If the departure time appears to be in the future but is actually from yesterday
        // (e.g., it's 02:00 now and departure was at 23:00 yesterday)
        if (departureTime.isAfter(now)) {
            const yesterdayDeparture = departureTime.clone().subtract(1, 'day');
            // If yesterday's time is within the last 2 hours, use that instead
            if (now.diff(yesterdayDeparture, 'hours') <= 2) {
                departureTime = yesterdayDeparture;
            }
        }
        
        // Only consider it "past" if it's actually before now and within the last 2 hours
        return departureTime.isBefore(now) && now.diff(departureTime, 'hours') <= 2;
    }

    isExpired(timestamp) {
        const entryTime = moment(timestamp);
        const now = moment();
        return now.diff(entryTime, 'hours') >= 2;
    }

    generateKey(fromStation, toStation, serviceID) {
        return `${fromStation}-${toStation}-${serviceID}`;
    }

    cleanup() {
        const expiredKeys = [];
        for (const [key, entry] of this.cache.entries()) {
            if (this.isExpired(entry.timestamp)) {
                expiredKeys.push(key);
            }
        }
        
        expiredKeys.forEach(key => this.cache.delete(key));
        console.log(`Cache cleanup: removed ${expiredKeys.length} expired entries`);
    }

    startCleanupJob() {
        setInterval(() => {
            this.cleanup();
        }, 60 * 60 * 1000);
    }

    getAllCacheContents() {
        const results = [];
        for (const [key, entry] of this.cache.entries()) {
            results.push(entry);
        }
        
        return results.sort((a, b) => {
            const timeA = moment(a.scheduledDepartureTime, 'HH:mm');
            const timeB = moment(b.scheduledDepartureTime, 'HH:mm');
            return timeB.diff(timeA);
        });
    }

    getCacheSize() {
        return this.cache.size;
    }
}

export const pastDeparturesCache = new PastDeparturesCache();
