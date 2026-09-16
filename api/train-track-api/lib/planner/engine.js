import fs from 'node:fs/promises';
import path from 'node:path';
import { API_VERSION, POLICY_VERSION, CAPABILITIES, PlannerError, addDays,
    londonDate, encodeCursor, journeyID, normalizeRequest } from './contract.js';

const DAY = 86400000;
const HOUR = 3600000;
const scheduledWarning = 'Scheduled timetable only. Live delays and changes are not included.';
const coverageWarnings = [
    'Some services are omitted, including ferry connections and trains with special holiday rules.',
    'Staying aboard a train that divides or joins another service is not supported.',
    'Some overnight services and transfers may be omitted where the timetable is ambiguous.',
    'Transfer times are timetable allowances; detailed walking or Tube directions are not included.'
];

function remember(map, key, value, maximum) {
    map.delete(key);
    map.set(key, value);
    while (map.size > maximum) map.delete(map.keys().next().value);
    return value;
}

export class PlannerEngine {
    constructor(config, { openDataset, findJourneys, now = Date.now, liveProvider, createLiveBudget } = {}) {
        this.config = config;
        this.openDataset = openDataset;
        this.findJourneys = findJourneys;
        this.now = now;
        this.datasets = new Map();
        this.dates = new Map();
        this.networks = new Map();
        this.searches = new Map();
        this.journeys = new Map();
        this.stats = { searches: 0, cacheHits: 0, datePreparations: 0 };
        this.stationPresentation = new Map();
        this.liveProvider = liveProvider;
        this.createLiveBudget = createLiveBudget;
    }

    async loadStationPresentation() {
        if (!this.stationPresentationLoaded) {
            this.stationPresentationLoaded = true;
            // Existing names and coordinates are presentation hints; timetable CRS remains authoritative.
            try {
                const rows = JSON.parse(await fs.readFile(new URL('../../resources/stations.json', import.meta.url), 'utf8'));
                this.stationPresentation = new Map(rows.map(row => [row.crs, row]));
            } catch { /* The validated timetable also supplies station names. */ }
        }
    }

    publicStation(value) {
        const station = typeof value === 'string' ? { crs: value, name: value } : value;
        const presentation = this.stationPresentation.get(station.crs);
        return { crs: station.crs, name: presentation?.name || station.name };
    }

    async paths() {
        if (this.config.datasetPath) return [{ path: this.config.datasetPath }];
        try {
            const pointer = JSON.parse(await fs.readFile(path.join(this.config.dataDirectory, 'active.json'), 'utf8'));
            return [{ path: pointer.path, version: pointer.version },
                ...(pointer.previousPath ? [{ path: pointer.previousPath, version: pointer.previousVersion }] : [])];
        } catch {
            throw new PlannerError('DATASET_UNAVAILABLE', 'No validated timetable is available yet.', 503);
        }
    }

    async dataset(version) {
        if (!this.config.enabled) throw new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is not enabled yet.', 503);
        await this.loadStationPresentation();
        const paths = await this.paths();
        const chosen = version ? paths.find(item => item.version === version || (!item.version && this.config.datasetPath)) : paths[0];
        if (!chosen?.path) throw new PlannerError('CURSOR_EXPIRED', 'The timetable for this search is no longer retained. Please search again.', 410);
        let repo = this.datasets.get(chosen.path);
        if (!repo) {
            if (!this.openDataset) this.openDataset = (await import('./repository.js')).openDataset;
            try { repo = await this.openDataset(chosen.path); } catch {
                throw new PlannerError('DATASET_UNAVAILABLE', 'The timetable could not be opened. Please try again later.', 503);
            }
            this.datasets.set(chosen.path, repo);
        }
        if (version && repo.version !== version) {
            throw new PlannerError('CURSOR_EXPIRED', 'This search uses a different timetable. Please search again.', 410);
        }
        const retained = new Set(paths.map(item => item.path));
        for (const [key, old] of this.datasets) {
            if (!retained.has(key)) {
                old.close();
                this.datasets.delete(key);
                for (const cache of [this.dates, this.networks, this.searches]) {
                    for (const cacheKey of cache.keys()) if (cacheKey.startsWith(`${old.version}:`)) cache.delete(cacheKey);
                }
            }
        }
        return repo;
    }

    publicMetadata(repo, live) {
        const metadata = repo.metadata;
        const sourceGenerationDate = metadata.source.generationDate;
        const ageDays = Math.max(0, Math.floor((this.now() - Date.parse(`${sourceGenerationDate}T00:00:00Z`)) / DAY));
        const includesLive = live && ['live', 'partial'].includes(live.status);
        return {
            version: repo.version, sourceGenerationDate, importedAt: metadata.importedAt,
            coverage: { from: metadata.coverage.startDate, to: metadata.coverage.endDate, basis: metadata.coverage.basis },
            ageDays, freshness: ageDays > this.config.warnAgeDays ? 'stale' : 'fresh', scheduledOnly: !includesLive,
            warnings: [...(includesLive ? [] : [scheduledWarning]), ...(metadata.limitations?.length ? coverageWarnings : []),
                ...(ageDays > this.config.warnAgeDays ? ['The timetable is older than expected; recent changes may be missing.'] : [])],
            freshnessPolicy: { warnAgeDays: this.config.warnAgeDays, maxStaleDays: this.config.maxStaleDays }
        };
    }

    async status() {
        try {
            const repo = await this.dataset();
            const dataset = this.publicMetadata(repo);
            const available = dataset.ageDays <= this.config.maxStaleDays;
            return { apiVersion: API_VERSION, available, capabilities: CAPABILITIES, dataset,
                ...(available ? {} : { reason: 'The timetable needs to be refreshed before new searches are available.' }) };
        } catch (error) {
            return { apiVersion: API_VERSION, available: false, capabilities: CAPABILITIES,
                reason: error instanceof PlannerError ? error.message : 'Journey planning is unavailable.' };
        }
    }

    async stationList(query) {
        const repo = await this.dataset();
        const term = query.trim().normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase();
        const rows = repo.stations.filter(station => station.selectable !== false);
        const matching = rows.filter(station => !term || [station.crs, station.name,
            this.publicStation(station).name, ...(station.aliases || [])]
            .some(text => text.normalize('NFKD').replace(/\p{M}/gu, '').toLowerCase().includes(term)));
        matching.sort((a, b) => Number(b.crs.toLowerCase() === term) - Number(a.crs.toLowerCase() === term)
            || a.name.localeCompare(b.name));
        return { stations: (term ? matching.slice(0, 30) : matching).map(station => {
            const presentation = this.stationPresentation.get(station.crs);
            const latitude = Number(station.latitude ?? presentation?.latitude);
            const longitude = Number(station.longitude ?? presentation?.longitude);
            return { ...this.publicStation(station), aliases: station.aliases || [],
                ...(Number.isFinite(latitude) && Number.isFinite(longitude) ? { latitude, longitude } : {}) };
        }), datasetVersion: repo.version };
    }

    checkQuery(repo, request) {
        const metadata = this.publicMetadata(repo);
        if (metadata.ageDays > this.config.maxStaleDays) {
            throw new PlannerError('DATASET_STALE', 'The timetable needs to be refreshed. Please try again later.', 503);
        }
        const stations = repo.stations.filter(station => station.selectable !== false);
        const canonical = code => {
            const exact = stations.find(station => station.crs === code);
            if (exact) return exact;
            const matches = stations.filter(station => (station.aliases || []).some(alias => alias.toUpperCase() === code));
            return matches.length === 1 ? matches[0] : undefined;
        };
        const origin = canonical(request.origin);
        const destination = canonical(request.destination);
        if (!origin || !destination) throw new PlannerError('INVALID_STATION', 'A selected station is not available in this timetable. Please select it again.');
        const date = londonDate(request.time);
        if (date < metadata.coverage.from || date > metadata.coverage.to) {
            throw new PlannerError('UNSUPPORTED_DATE', `Choose a date between ${metadata.coverage.from} and ${metadata.coverage.to}.`, 422);
        }
        return { ...request, origin: origin.crs, destination: destination.crs };
    }

    async network(repo, request, signal) {
        const time = Date.parse(request.time);
        const windowMs = request.windowMinutes * 60000;
        const lower = request.timeType === 'arriveBy' ? time - windowMs - DAY : time;
        const upper = request.timeType === 'arriveBy' ? time : time + windowMs + DAY;
        const lookback = repo.metadata.maxEventDayOffset ?? 0;
        const firstDate = addDays(londonDate(lower), -lookback);
        const lastDate = londonDate(upper);
        const key = `${repo.version}:${firstDate}:${lastDate}`;
        if (this.networks.has(key)) return this.networks.get(key);
        // One hot national index. Release the previous index before preparing another
        // date range, otherwise alternating dates can temporarily retain three indexes.
        this.networks.clear();
        for (const dateKey of this.dates.keys()) {
            const date = dateKey.slice(-10);
            if (!dateKey.startsWith(`${repo.version}:`) || date < firstDate || date > lastDate) this.dates.delete(dateKey);
        }
        const services = [];
        const diagnostics = { counts: {}, examples: [] };
        for (let date = firstDate; date <= lastDate; date = addDays(date, 1)) {
            if (signal?.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499);
            const dateKey = `${repo.version}:${date}`;
            let resolved = this.dates.get(dateKey);
            if (!resolved) {
                try { resolved = await repo.resolveServices(date, { signal }); }
                catch (error) {
                    if (error.code === 'SEARCH_CANCELLED') throw new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499);
                    throw error;
                }
                this.stats.datePreparations++;
                remember(this.dates, dateKey, resolved, this.config.dateCacheSize);
            }
            for (let index = 0; index < resolved.services.length; index++) {
                if (index % 256 === 0 && signal?.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499);
                services.push(resolved.services[index]);
            }
            for (const [code, count] of Object.entries(resolved.diagnostics?.counts || {})) {
                diagnostics.counts[code] = (diagnostics.counts[code] || 0) + count;
            }
            diagnostics.examples.push(...(resolved.diagnostics?.examples || []).slice(0, 30 - diagnostics.examples.length));
        }
        return remember(this.networks, key, {
            stations: new Map((repo.allStations || repo.stations).map(station => [station.crs, station])),
            services, rules: repo.rules, diagnostics
        }, 1);
    }

    async search({ request, version, offset = 0, liveSnapshotId }, signal, execution = {}) {
        const started = performance.now();
        const timeoutMs = execution.timeoutMs ?? this.config.timeoutMs;
        const maxOperations = execution.maxOperations ?? this.config.maxOperations;
        if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || !Number.isSafeInteger(maxOperations) || maxOperations <= 0) {
            throw new PlannerError('INVALID_REQUEST', 'Invalid planner execution budget.');
        }
        const check = () => {
            if (signal?.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499);
            if (performance.now() - started >= timeoutMs) throw new PlannerError('SEARCH_TIMEOUT', 'The search exceeded its execution time budget.', 504);
        };
        check();
        execution.onProgress?.('preparing');
        const repo = await this.dataset(version);
        check();
        request = this.checkQuery(repo, request);
        this.stats.searches++;
        const key = `${repo.version}:${POLICY_VERSION}:${JSON.stringify(request)}:${offset}`;
        const cached = this.searches.get(key);
        if (!request.realtime && cached && this.now() - cached.createdAt < 5 * 60000) {
            this.stats.cacheHits++;
            for (const journey of cached.result.journeys) this.retainJourney(journey, repo.version);
            const dataset = this.publicMetadata(repo);
            return { ...cached.result, dataset, warnings: [...new Set([...dataset.warnings,
                ...cached.result.warnings.filter(warning => !cached.result.dataset.warnings.includes(warning))])] };
        }
        let result;
        const resolutionWarnings = [];
        if (request.origin === request.destination) {
            result = { journeys: [], warnings: ['You are already at the destination.'],
                searchTruncated: false, searchWindow: { from: request.time, to: request.time }, pagination: {} };
        } else {
            const network = await this.network(repo, request, signal);
            check();
            if (Object.entries(network.diagnostics.counts).some(([code, count]) => code !== 'CANCELLED' && count > 0)) {
                resolutionWarnings.push('Some timetable records could not be resolved safely; results may be incomplete.');
            }
            execution.onProgress?.('searching');
            let remainingOperations = maxOperations;
            const route = async (query, current, options = {}) => {
                if (remainingOperations <= 0) throw new PlannerError('SEARCH_TIMEOUT', 'The search exceeded its work budget.', 504);
                const routed = await this.route(query, current, {
                    signal, maxDurationMinutes: 1440, maxOperations: remainingOperations,
                    timeoutMs: Math.max(1, timeoutMs - (performance.now() - started)), offset, ...options
                });
                remainingOperations -= routed.metrics?.operations ?? 0;
                return routed;
            };
            if (request.realtime) {
                if (!this.livePlanner) {
                    const { LivePlanner } = await import('./live-search.js');
                    this.livePlanner = new LivePlanner({ now: this.now, provider: this.liveProvider, createBudget: this.createLiveBudget });
                }
                execution.onProgress?.('live');
                try {
                    result = await this.livePlanner.search({ request, network, version: repo.version, offset, liveSnapshotId,
                        route, check, abortSignal: execution.abortSignal });
                } catch (error) {
                    check();
                    if (error.code === 'SEARCH_CANCELLED') throw new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499);
                    throw error;
                }
            } else result = await route(request, network);
        }
        check();
        const dataset = this.publicMetadata(repo, result.live);
        const present = journey => {
            const publicJourney = this.publicJourney(journey);
            publicJourney.id = journeyID(publicJourney, repo.version, result.live
                ? { snapshot: result.liveSnapshotId, ...result.live } : undefined);
            this.retainJourney(publicJourney, repo.version, result.live);
            return publicJourney;
        };
        const journeys = result.journeys.map(present);
        const cursor = time => time && londonDate(time) >= dataset.coverage.from && londonDate(time) <= dataset.coverage.to
            ? encodeCursor({ ...request, time }, repo.version) : undefined;
        const pageLimitReached = result.pagination?.nextOffset > 1000;
        const window = result.searchWindow;
        const coverageEdge = window && (londonDate(window.from) < dataset.coverage.from
            || londonDate(Date.parse(window.to) - (window.toInclusive === false ? 1 : 0)) > dataset.coverage.to);
        const response = {
            journeys, dataset,
            ...(result.live ? { live: result.live, disruptedJourneys: (result.disruptedJourneys ?? []).map(present) } : {}),
            search: { ...request, window, searchTruncated: Boolean(result.searchTruncated || pageLimitReached || coverageEdge) },
            warnings: [...new Set([...dataset.warnings, ...resolutionWarnings, ...(result.warnings || []), ...(result.live?.warnings ?? []),
                ...(coverageEdge ? ['Part of this search window falls outside the available timetable; results may be incomplete.'] : []),
                ...(pageLimitReached ? ['The result limit was reached. Narrow the time window to see more journeys.'] : [])])],
            pagination: { earlier: cursor(result.pagination?.earlierTime), later: cursor(result.pagination?.laterTime),
                more: Number.isInteger(result.pagination?.nextOffset) && result.pagination.nextOffset <= 1000
                    ? encodeCursor(request, repo.version, result.pagination.nextOffset, result.liveSnapshotId) : undefined }
        };
        if (!request.realtime && !response.search.searchTruncated) remember(this.searches, key, { result: response, createdAt: this.now() }, 64);
        return response;
    }

    publicJourney(journey) {
        const station = value => this.publicStation(value);
        return {
            departure: journey.departure, arrival: journey.arrival, durationMinutes: journey.durationMinutes,
            changes: journey.changes,
            ...(journey.warnings?.length ? { warnings: journey.warnings } : {}),
            legs: journey.legs.map(leg => ({
                kind: leg.kind, mode: leg.mode, from: station(leg.from), to: station(leg.to),
                departure: leg.departure, arrival: leg.arrival,
                ...(leg.scheduledDeparture ? { scheduledDeparture: leg.scheduledDeparture } : {}),
                ...(leg.scheduledArrival ? { scheduledArrival: leg.scheduledArrival } : {}),
                ...(leg.scheduledServiceId ? { scheduledServiceId: leg.scheduledServiceId } : {}),
                ...(leg.live ? { live: leg.live } : {}),
                ...(leg.operator ? { operator: leg.operator } : {}),
                ...(leg.serviceId ? { serviceId: leg.serviceId } : {}),
                ...(leg.originDate ? { originDate: leg.originDate } : {}),
                ...(leg.platform ? { platform: leg.platform } : {}),
                ...(leg.callingPoints ? { callingPoints: leg.callingPoints.map(call => ({
                    station: station(call.station), arrival: call.arrival ?? null, departure: call.departure ?? null,
                    ...(call.scheduledArrival ? { scheduledArrival: call.scheduledArrival } : {}),
                    ...(call.scheduledDeparture ? { scheduledDeparture: call.scheduledDeparture } : {}),
                    ...(call.live ? { live: call.live } : {})
                })) } : {}),
                ...(leg.transfer || leg.breakdown ? { transfer: leg.transfer || leg.breakdown } : {}),
                ...(leg.warnings?.length ? { warnings: leg.warnings } : {})
            }))
        };
    }

    retainJourney(journey, version, live) {
        remember(this.journeys, journey.id, { journey, version, at: this.now(), live }, 500);
    }

    async journey(id, signal) {
        const cached = this.journeys.get(id);
        if (!cached || this.now() - cached.at > HOUR) {
            throw new PlannerError('JOURNEY_EXPIRED', 'This journey has expired. Please search again.', 410);
        }
        const repo = await this.dataset(cached.version);
        const stations = new Map((repo.allStations ?? repo.stations).map(station => [station.crs, station]));
        const legs = [];
        for (const leg of cached.journey.legs) {
            if (signal?.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Request cancelled.', 499);
            if (leg.kind !== 'vehicle' || !leg.originDate || !leg.serviceId) { legs.push(leg); continue; }
            const dateKey = `${repo.version}:${leg.originDate}`;
            let resolved = this.dates.get(dateKey);
            if (!resolved) {
                resolved = await repo.resolveServices(leg.originDate, { signal });
                remember(this.dates, dateKey, resolved, this.config.dateCacheSize);
            }
            const service = resolved.services.find(value => value.id === (leg.scheduledServiceId ?? leg.serviceId));
            legs.push(service ? { ...leg, serviceCallingPoints: service.calls.map(call => ({
                station: this.publicStation(stations.get(call.station) ?? call.station),
                arrival: Number.isFinite(call.arrival) ? new Date(call.arrival).toISOString() : null,
                departure: Number.isFinite(call.departure) ? new Date(call.departure).toISOString() : null
            })) } : leg);
        }
        const dataset = this.publicMetadata(repo, cached.live);
        return { journey: { ...cached.journey, legs }, dataset, ...(cached.live ? { live: cached.live } : {}) };
    }

    async route(request, network, options) {
        if (!this.findJourneys) this.findJourneys = (await import('./router.js')).findJourneys;
        try { return await this.findJourneys(request, network, options); }
        catch (error) {
            if (error.code === 'SEARCH_TIMEOUT') throw new PlannerError('SEARCH_TIMEOUT', 'The search exceeded its work budget. Try a narrower time window.', 504);
            if (error.code === 'SEARCH_CANCELLED') throw new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499);
            throw error;
        }
    }

    async explain(request, signal) {
        const repo = await this.dataset();
        request = this.checkQuery(repo, normalizeRequest(request));
        const network = await this.network(repo, request, signal);
        const result = await this.route(request, network, { signal, maxOperations: this.config.maxOperations });
        const resolutions = [];
        const seen = new Set();
        for (const journey of result.journeys) for (const leg of journey.legs) {
            if (leg.kind !== 'vehicle' || seen.has(leg.serviceId)) continue;
            seen.add(leg.serviceId);
            if (repo.resolveServiceExplanation) resolutions.push(repo.resolveServiceExplanation(leg.uid, leg.originDate, leg.source));
        }
        return { datasetVersion: repo.version, request, policy: result.policy,
            diagnostics: network.diagnostics, resolutions, journeys: result.journeys, metrics: result.metrics };
    }

    close() { for (const repo of this.datasets.values()) repo.close(); }

    runtime() {
        return { ...this.stats, caches: { datasets: this.datasets.size, dates: this.dates.size,
            networks: this.networks.size, searches: this.searches.size, journeys: this.journeys.size },
            memoryBytes: process.memoryUsage() };
    }
}
