import { getOperatorBrandingConfig } from '../operator-branding-config.js';
import { readFileSync } from 'node:fs';
import { PlannerEngine } from './engine.js';
import { normalizeRequest, PlannerError } from './contract.js';
import { TubeTrackProvider } from './tube-provider.js';
import { createTubeResolver } from './tube-routing.js';

export const combinedStations = JSON.parse(readFileSync(new URL('../../resources/combined-stations.json', import.meta.url))).stations;
const byID = new Map(combinedStations.flatMap(s => [s.id, ...s.stopIds].map(id => [id.toUpperCase(), s])));
const nodeID = station => station.railCodes.length === 1 ? station.railCodes[0] : station.id;

export function normalizeCombinedRequest(body) {
    if (!body || typeof body !== 'object' || Array.isArray(body)
        || Object.keys(body).some(key => !['origin', 'destination', 'time', 'timeType', 'accessibility'].includes(key))) {
        throw new PlannerError('INVALID_REQUEST', 'Supply combined journey endpoints, time and accessibility.');
    }
    const from = byID.get(String(body.origin ?? '').toUpperCase());
    const to = byID.get(String(body.destination ?? '').toUpperCase());
    if (!from || !to) throw new PlannerError('INVALID_STATION', 'Choose stations shown on the TubeTrack map.', 422);
    if (nodeID(from) === nodeID(to)) throw new PlannerError('SAME_STATION', 'Choose a different destination.');
    const accessibility = body.accessibility ?? 'none';
    if (!['none', 'platform', 'train'].includes(accessibility)) throw new PlannerError('INVALID_REQUEST', 'Invalid accessibility preference.');
    const request = normalizeRequest({ origin: 'AAA', destination: 'BBB', time: body.time, timeType: body.timeType,
        realtime: 'apply', allowedModes: ['rail', 'replacementBus', 'walk', 'tubeTransfer'], limit: 10 });
    return { request: { ...request, origin: nodeID(from), destination: nodeID(to),
        fromID: from.id, toID: to.id, accessibility } };
}

/** V5 uses the existing independently validated, asynchronous router. The v3
 * RAPTOR switch and caches are untouched. Dataset/date preparation is shared
 * with the worker's existing engine; each augmented graph is request-local. */
export class CombinedPlannerEngine extends PlannerEngine {
    constructor(base, { stations = combinedStations, provider } = {}) {
        super(base.config, { now: base.now, liveProvider: base.liveProvider, createLiveBudget: base.createLiveBudget });
        this.base = base;
        this.catalogue = stations;
        this.nodes = new Map(stations.map(s => [nodeID(s), s]));
        this.provider = provider ?? new TubeTrackProvider({ minuteKeys: true, palettePath: '/../v1/line-colours', journeyPath: '/journey-transfers', baseURL: process.env.TUBETRACK_TRANSFER_URL ?? 'https://api.skynolimit.dev/tube-track/api/v2', allowedModes: ['tube', 'elizabeth-line', 'overground', 'dlr', 'tram', 'walking', 'walk'] });
        // TfL-only endpoints are real catalogue identifiers, never invented CRS.
        for (const s of stations) if (s.tflId) {
            this.provider.mappings[nodeID(s)] ??= { routingId: s.tflId };
        }
    }

    dataset(version) { return this.base.dataset(version); }

    checkQuery(repo, request) {
        const from = this.nodes.get(request.origin), to = this.nodes.get(request.destination);
        if (!from || !to) throw new PlannerError('INVALID_STATION', 'Unknown map station.', 422);
        // Reuse timetable freshness/date checks without pretending virtual nodes
        // are selectable National Rail CRS codes.
        const reference = repo.stations.find(s => s.selectable !== false)?.crs;
        super.checkQuery(repo, { ...request, origin: reference, destination: reference });
        return request;
    }

    publicJourney(journey) {
        const result = super.publicJourney(journey);
        let branding;
        try { branding = getOperatorBrandingConfig().operators; }
        catch { return result; } // Presentation metadata must not block routing.
        for (const leg of result.legs) {
            const brand = branding.find(value => value.operator_codes.includes(leg.operator));
            if (brand) leg.operatorBranding = { name: brand.name, colour: brand.color_hex };
        }
        return result;
    }

    publicStation(value) {
        const code = typeof value === 'string' ? value : value.crs;
        const station = this.nodes.get(code) ?? this.catalogue.find(s => s.railCodes.includes(code));
        return { crs: code, id: station?.id ?? `nr:${code}`, name: station?.name ?? this.base.publicStation(value).name };
    }

    async network(repo, request, signal) {
        const base = await this.base.network(repo, request, signal);
        const mapped = new Set(this.catalogue.flatMap(s => s.railCodes));
        // Route within the map's rail network. Keep full train identities and
        // calling patterns for live matching, including travel outside the map,
        // but do not expand national off-map interchange searches from this API.
        const reference = Date.parse(request.time);
        const lower = request.timeType === 'arriveBy' ? reference - 12 * 3600000 : reference - 2 * 3600000;
        const upper = request.timeType === 'arriveBy' ? reference + 2 * 3600000 : reference + 12 * 3600000;
        const services = base.services.filter(service => service.calls.filter(call => mapped.has(call.station)
            && (call.canBoard || call.canAlight)).length >= 2
            && service.calls.some(call => (call.departure ?? call.arrival) >= lower && (call.departure ?? call.arrival) <= upper))
            .map(service => ({ ...service, calls: service.calls.map(call => mapped.has(call.station)
                ? call : { ...call, canBoard: false, canAlight: false }) }));
        const stations = new Map(base.stations), links = [...(base.rules?.links ?? [])];
        const endpoints = [request.origin, request.destination];
        for (const id of endpoints) {
            const station = this.nodes.get(id);
            if (stations.has(id)) continue;
            if (!station?.tflId && !station?.railCodes.some(code => stations.has(code))) {
                throw new PlannerError('INVALID_STATION', 'This map station is unavailable in the current timetable.', 422);
            }
            stations.set(id, { crs: id, name: station.name, minimumChangeMinutes: 0 });
            for (const code of station.railCodes.filter(code => stations.has(code))) {
                // A hub may represent several rail stations. Use their published
                // platform-access allowance; never merge their train events.
                const minutes = Math.max(1, stations.get(code).minimumChangeMinutes ?? 10);
                for (const [origin, destination] of [[id, code], [code, id]]) links.push({
                    id: `hub:${origin}:${destination}`, origin, destination, mode: 'walk', minutes,
                    sourceRef: { member: 'MAP_HUB_ACCESS' }
                });
            }
            if (!station.tflId) continue;
            for (const [code] of base.stations) {
                if (!this.provider.mapping(code) || station.railCodes.includes(code)) continue;
                for (const [origin, destination] of [[id, code], [code, id]]) links.push(dynamicLink(origin, destination));
            }
        }
        // Direct TfL journeys compete in the same time/boarding frontier.
        if (endpoints.every(id => this.provider.mapping(id)) && !links.some(l =>
            l.origin === request.origin && l.destination === request.destination)) {
            links.push(dynamicLink(request.origin, request.destination));
        }
        return { ...base, stations, services, rules: { ...base.rules,
            links: links.filter(link => (mapped.has(link.origin) || endpoints.includes(link.origin))
                && (mapped.has(link.destination) || endpoints.includes(link.destination))) }, accessibility: request.accessibility };
    }

    async route(request, network, options = {}) {
        // Parent search constructs a resolver before calling route. Replace it
        // with one scoped to this request's accessibility and shared pass budget.
        let resolver = options.resolveTubeConnection;
        if (resolver) resolver.accessibility = request.accessibility;
        return super.route(request, network, { ...options, maxDurationMinutes: 360,
            prioritizeJourneyTime: true, resolveTubeConnection: resolver });
    }

    async tubeResolver(options = {}) {
        const provider = this.provider;
        let wrapped;
        const sourceFor = sameAccess => ({
            mapping: code => sameAccess ? { ...provider.mapping(code), exitMinutes: 0, entryMinutes: 0, accessWalkingMinutes: 0 }
                : provider.mapping(code),
            lookup: args => {
                if (!sameAccess) return provider.lookup({ ...args, accessibility: wrapped.accessibility ?? 'none' });
                const duration = sameAccess.minutes * 60000;
                const arrival = args.timeMode === 'arriveBy' ? Date.parse(args.time) : Date.parse(args.time) + duration;
                const departureTime = new Date(arrival - duration).toISOString(), arrivalTime = new Date(arrival).toISOString();
                const from = { id: args.from, name: this.nodes.get(args.from)?.name ?? args.from };
                const to = { id: args.to, name: this.nodes.get(args.to)?.name ?? args.to };
                const disruption = { status: 'unknown', coverage: 'partial', issues: [], sources: [] };
                return Promise.resolve({ status: 'available', expiresAt: new Date(this.now() + 20000).toISOString(),
                    meta: { updatedAt: null }, journeys: [{ id: `access:${args.from}:${args.to}`, departureTime, arrivalTime,
                        disruption, warnings: ['Walking access uses the railway station allowance; check station accessibility notices.'],
                        legs: [{ id: '0', mode: 'walking', from, to, departureTime, arrivalTime, durationMinutes: sameAccess.minutes,
                            instruction: `Walk between ${from.name} and ${to.name}`, timing: 'scheduled', source: 'timetable', lines: [], stops: [], warnings: [], disruption }] }] });
            }
        });
        const resolver = createTubeResolver(sourceFor(null), { ...options, now: this.now,
            budget: { limit: 24, used: 0 }, lookupBudgetMs: 12000, verificationConcurrency: 2 });
        wrapped = async (index, query) => {
            const a = provider.mapping(query.from), b = provider.mapping(query.to);
            const sameAccess = a && b && a.routingId === b.routingId ? { minutes: Math.max(1,
                index.stations.get(query.from)?.minimumChangeMinutes ?? 0,
                index.stations.get(query.to)?.minimumChangeMinutes ?? 0,
                a.accessWalkingMinutes ?? 0, b.accessWalkingMinutes ?? 0) } : null;
            const selected = sameAccess ? createTubeResolver(sourceFor(sameAccess), { ...options, now: this.now }) : resolver;
            // Endpoint-only TfL links cannot be left as timetable fallbacks:
            // they disappear from the frontier and can never be verified later.
            const dynamic = (index.pairs.get(`${query.from}|${query.to}`) ?? [])
                .some(rule => rule.id?.startsWith('dynamic:'));
            const bounded = { ...query };
            if (bounded.arrival == null && Number.isFinite(bounded.departure)) bounded.arrival = bounded.departure - 360 * 60000;
            if (bounded.departure == null && Number.isFinite(bounded.arrival)) bounded.departure = bounded.arrival + 360 * 60000;
            const result = await selected(index, bounded, dynamic);
            if (sameAccess) {
                resolver.state.used = true;
                resolver.state.expiresAt = Math.min(resolver.state.expiresAt, selected.state.expiresAt);
            }
            // The one-minute dynamic link is only an optimistic search bound.
            // There is no timetable fallback for a newly invented endpoint link.
            return result.filter(connection => !connection.ruleId?.startsWith('dynamic:')
                || connection.localJourney?.status === 'available');
        };
        wrapped.state = resolver.state;
        // Published rail transfer allowances do have fallback candidates. Protect
        // capacity for those in complete journeys; dynamic links remain filtered.
        wrapped.reserveForResults = resolver.reserveForResults;
        wrapped.metrics = resolver.metrics;
        wrapped.verifySelected = resolver.verifySelected;
        return wrapped;
    }

    async search(payload, signal, execution = {}) {
        const result = await super.search(payload, signal, execution);
        if (!result.journeys.length && result.search?.searchTruncated) {
            const notices = result.warnings.filter(message => message.startsWith('TfL: ')).slice(0, 2);
            throw new PlannerError('SEARCH_INCOMPLETE', [
                ...notices, 'Journey connections could not all be checked. Please try again later.'
            ].join(' '), 503);
        }
        const expiries = result.journeys.flatMap(j => j.legs.map(l => Date.parse(l.localJourney?.expiresAt))).filter(Number.isFinite);
        const expiresAt = Math.min(this.now() + 20000, Date.parse(result.live?.expiresAt) || Infinity, ...expiries);
        return { ...result, apiVersion: 5, expiresAt: new Date(expiresAt).toISOString(),
            // V3 cursors cannot encode these map endpoints. V5 refreshes a search
            // atomically; it never exposes a cursor to an incompatible API.
            pagination: {}, warnings: [...new Set([...result.warnings,
                'Routes use up to five changes at stations on the TubeTrack map and last up to six hours. Trains may travel beyond the map between these stations.',
                ...(payload.request.accessibility !== 'none' ? ['TfL legs use your step-free preference. National Rail and replacement-bus accessibility is unverified; check assistance and station notices.'] : []),
                ...(expiresAt <= this.now() ? ['Some journey information expired during the search. Refresh before travelling.'] : [])])] };
    }
}

function dynamicLink(origin, destination) {
    return { id: `dynamic:${origin}:${destination}`, origin, destination, mode: 'tubeTransfer', minutes: 1,
        sourceRef: { member: 'TFL_DYNAMIC_ONLY' } };
}
