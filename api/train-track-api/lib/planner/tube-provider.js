import { readFileSync } from 'node:fs';

const stationConfig = JSON.parse(readFileSync(new URL('../../resources/london-tfl-stations.json', import.meta.url), 'utf8'));
const bundledPalette = JSON.parse(readFileSync(new URL('../../resources/tfl-line-colours.json', import.meta.url), 'utf8')).lines;
const MODES = new Set(['tube', 'elizabeth-line', 'overground', 'dlr', 'walking', 'walk']);
const CACHE_TTL = 30_000;
const PALETTE_TTL = 86_400_000;
const MAX_REQUESTS = 32;
const MAX_CACHE_ENTRIES = 256;
const NEUTRAL = { colour: '#59636E', textColour: '#FFFFFF' };

/** Shared worker-scoped TubeTrack adapter. Caller cancellation never cancels a
 * request another search is still using. Journey requests consume the supplied
 * search budget; the daily palette refresh is shared across every search.
 */
export class TubeTrackProvider {
    constructor({ baseURL = 'https://api.skynolimit.dev/tube-track/api/v1', fetch: request = globalThis.fetch,
        now = Date.now, timeoutMs = 4_000, mappings = stationConfig.stations, lineColours = bundledPalette } = {}) {
        this.baseURL = baseURL.replace(/\/$/, '');
        this.fetch = request;
        this.now = now;
        this.timeoutMs = timeoutMs;
        this.mappings = mappings;
        this.palette = paletteMap(lineColours);
        this.paletteExpiresAt = 0;
        this.paletteFlight = null;
        this.cache = new Map();
        this.observations = new Map();
        this.inflight = new Map();
        this.active = 0;
        this.queue = [];
    }

    mapping(crs) { return this.mappings[String(crs).trim().toUpperCase()] ?? null; }

    async lookup({ from, to, time, timeMode = 'departAt', signal, budget = { limit: MAX_REQUESTS, used: 0 }, awaitIO = work => work() }) {
        throwIfCancelled(signal);
        if (!['departAt', 'arriveBy'].includes(timeMode)) throw new TypeError('Invalid TubeTrack time mode');
        const instant = typeof time === 'number' ? time : validTimestamp(time) ? Date.parse(time) : NaN;
        if (!Number.isFinite(instant) || !Number.isFinite(new Date(instant).getTime())) throw new TypeError('Invalid TubeTrack time');
        if (!Number.isSafeInteger(budget.limit) || budget.limit < 0 || !Number.isSafeInteger(budget.used)
            || budget.used < 0 || budget.used > budget.limit) throw new TypeError('Invalid TubeTrack request budget');
        const origin = this.mapping(from);
        const destination = this.mapping(to);
        if (!origin || !destination) return unavailable('unmapped', 'unmapped');
        const params = new URLSearchParams({ from: origin.routingId, to: destination.routingId,
            timeMode, time: new Date(instant).toISOString(), accessibility: 'none' });
        const key = params.toString();
        const pair = `${origin.routingId}|${destination.routingId}`;
        const cached = this.cache.get(key);
        const now = this.now();
        if (cached && now >= cached.cachedAt && now < cached.validUntil) {
            this.cache.delete(key);
            this.cache.set(key, cached);
            return structuredClone(cached.value);
        }
        if (!this.inflight.has(key) && budget.used >= Math.min(MAX_REQUESTS, budget.limit)) {
            return unavailable('requestLimit', 'unavailable', this.disruptionEvidence(pair, instant));
        }
        if (!this.inflight.has(key)) budget.used++;
        try {
            return await awaitIO(() => this.sharedFetch(key, params, signal, pair, instant));
        } catch (error) {
            throwIfCancelled(signal);
            return unavailable(errorReason(error), 'unavailable', this.disruptionEvidence(pair, instant));
        }
    }

    sharedFetch(key, params, signal, pair, instant) {
        throwIfCancelled(signal);
        let flight = this.inflight.get(key);
        if (!flight) {
            flight = { controller: new AbortController(), consumers: 0 };
            const current = flight;
            flight.promise = this.fetchJourney(params, flight.controller.signal).then(value => {
                // Retain the last observation after expiry so an outage cannot
                // erase an already known closure. Expired values are never fresh
                // directions; callers receive unavailable + stale with warnings.
                if (value.status === 'available') {
                    const cachedAt = this.now();
                    this.cache.delete(key);
                    this.cache.set(key, { cachedAt, validUntil: Math.min(cachedAt + CACHE_TTL, Date.parse(value.expiresAt)), value });
                    while (this.cache.size > MAX_CACHE_ENTRIES) this.cache.delete(this.cache.keys().next().value);
                    const recent = (this.observations.get(pair) ?? []).filter(item => item.instant !== instant).slice(-3);
                    this.observations.delete(pair);
                    this.observations.set(pair, [...recent, { instant, observedAt: cachedAt, value }]);
                    while (this.observations.size > MAX_CACHE_ENTRIES) this.observations.delete(this.observations.keys().next().value);
                }
                return value;
            }).finally(() => {
                if (this.inflight.get(key) === current) this.inflight.delete(key);
            });
            this.inflight.set(key, flight);
        }
        flight.consumers++;
        return new Promise((resolve, reject) => {
            let done = false;
            const finish = (error, value) => {
                if (done) return;
                done = true;
                signal?.removeEventListener('abort', cancelled);
                if (--flight.consumers === 0) {
                    flight.controller.abort();
                    if (this.inflight.get(key) === flight) this.inflight.delete(key);
                }
                error ? reject(error) : resolve(structuredClone(value));
            };
            const cancelled = () => finish(cancelledError());
            signal?.addEventListener('abort', cancelled, { once: true });
            flight.promise.then(value => finish(null, value), error => finish(error));
        });
    }

    disruptionEvidence(pair, instant) {
        const now = this.now();
        const observation = (this.observations.get(pair) ?? []).findLast(item =>
            now >= item.observedAt && now - item.observedAt <= PALETTE_TTL && Math.abs(item.instant - instant) <= 2 * 3_600_000);
        if (!observation) return null;
        const prior = observation.value;
        const active = issue => issue.validityPeriods?.some(period => {
            const from = period.from ? Date.parse(period.from) : -Infinity;
            const to = period.to ? Date.parse(period.to) : Infinity;
            return (period.from || period.to) && from <= instant && to >= instant;
        });
        const evidence = disruption => {
            const issues = (disruption?.issues ?? []).filter(active);
            return { ...disruption, issues, hasDisruption: issues.length > 0,
                status: issues.some(issue => ['major', 'severe'].includes(issue.severity)) ? 'majorIssues'
                    : issues.length ? 'minorIssues' : 'unknown', coverage: 'unknown' };
        };
        const journeys = prior.journeys.map(journey => ({ id: journey.id, disruption: evidence(journey.disruption),
            warnings: [], legs: journey.legs.map(leg => ({ id: leg.id, mode: leg.mode, lines: leg.lines,
                from: leg.from, to: leg.to, warnings: [], disruption: evidence(leg.disruption) })) }));
        if (!journeys.some(journey => journey.disruption.issues.length
            || journey.legs.some(leg => leg.disruption.issues.length))) return null;
        return { journeys, expiresAt: prior.expiresAt, attribution: prior.attribution, messages: [],
            meta: { ...prior.meta, stale: true, disruptionEvidenceForTime: new Date(instant).toISOString() } };
    }

    async fetchJourney(params, signal) {
        const [raw] = await Promise.all([
            this.getJSON(`/journeys?${params}`, signal), this.refreshPalette()
        ]);
        signal.throwIfAborted();
        if (!isObject(raw?.data) || !Array.isArray(raw.data.journeys) || raw.data.journeys.length > 64) throw malformed();
        optional(raw, 'meta', meta => {
            if (!isObject(meta)) return false;
            optional(meta, 'updatedAt', validTimestamp);
            optional(meta, 'stale', isBoolean);
            return true;
        });
        optional(raw.data, 'expiresAt', validTimestamp);
        optional(raw.data, 'stale', isBoolean);
        const journeys = [];
        let unsupportedJourneyCount = 0;
        for (const journey of raw.data.journeys) {
            if (!journey || typeof journey.id !== 'string' || !Array.isArray(journey.legs) || !journey.legs.length || journey.legs.length > 64
                || !validTimestamp(journey.departureTime) || !validTimestamp(journey.arrivalTime)
                || Date.parse(journey.arrivalTime) < Date.parse(journey.departureTime)) throw malformed();
            if (journey.legs.some(leg => !leg || typeof leg.mode !== 'string')) throw malformed();
            // A replacement bus/tram cannot be made a rail route by deleting its
            // leg. Reject the entire itinerary and keep any supported options.
            if (journey.legs.some(leg => !MODES.has(leg.mode))) { unsupportedJourneyCount++; continue; }
            validateOptionalJourneyFields(journey);
            journeys.push({ ...journey, legs: journey.legs.map(leg => {
                if (typeof leg.id !== 'string' || typeof leg.instruction !== 'string'
                    || !validStop(leg.from) || !validStop(leg.to)
                    || !validTimestamp(leg.departureTime) || !validTimestamp(leg.arrivalTime)
                    || Date.parse(leg.arrivalTime) < Date.parse(leg.departureTime)
                    || !Array.isArray(leg.lines) || leg.lines.length > 32) throw malformed();
                validateOptionalLegFields(leg);
                return { ...leg, lines: leg.lines.map(line => {
                    if (!line || typeof line.id !== 'string' || typeof line.name !== 'string') throw malformed();
                    optional(line, 'direction', isString);
                    const colour = this.palette.get(line.id) ?? NEUTRAL;
                    return { ...line, colour: colour.colour, textColour: colour.textColour };
                }) };
            }) });
        }
        const now = this.now();
        const expiresAt = validTimestamp(raw.data.expiresAt) ? raw.data.expiresAt : new Date(now + CACHE_TTL).toISOString();
        const stale = raw.meta?.stale === true || raw.data.stale === true || Date.parse(expiresAt) <= now;
        const result = { status: stale ? 'unavailable' : 'available', journeys,
            meta: { ...raw.meta, ...(stale ? { stale: true, reason: 'stale' } : {}),
                ...(unsupportedJourneyCount ? { unsupportedJourneyCount } : {}) },
            expiresAt, attribution: typeof raw.data.attribution === 'string' ? raw.data.attribution : null,
            messages: Array.isArray(raw.data.messages) ? raw.data.messages.filter(value => typeof value === 'string') : [] };
        if (unsupportedJourneyCount) result.messages.push('Some TfL options use transport outside Underground, Elizabeth line, DLR and Overground and were excluded.');
        return result;
    }

    refreshPalette() {
        if (this.now() < this.paletteExpiresAt) return Promise.resolve();
        if (!this.paletteFlight) {
            this.paletteFlight = this.getJSON('/line-colours').then(raw => {
                if (!Array.isArray(raw?.data) || raw.meta?.stale === true) throw malformed();
                const palette = paletteMap(raw.data);
                if (!palette.size) throw malformed();
                // A partial response must not erase previously known branding.
                for (const [id, colour] of palette) this.palette.set(id, colour);
                this.paletteExpiresAt = this.now() + PALETTE_TTL;
            }).catch(() => {
                // Bundled/last-good colours remain usable during an outage.
                this.paletteExpiresAt = this.now() + 60_000;
            }).finally(() => { this.paletteFlight = null; });
        }
        return this.paletteFlight;
    }

    async getJSON(path, signal) {
        const bounded = AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(this.timeoutMs)]);
        await this.acquire(bounded);
        try {
            bounded.throwIfAborted();
            const response = await this.fetch(`${this.baseURL}${path}`, { signal: bounded, headers: { accept: 'application/json' } });
            if (!response.ok) throw Object.assign(new Error(`TubeTrack HTTP ${response.status}`), { status: response.status });
            const result = await response.json();
            bounded.throwIfAborted();
            return result;
        } finally { this.release(); }
    }

    acquire(signal) {
        signal.throwIfAborted();
        if (this.active < 2) { this.active++; return Promise.resolve(); }
        return new Promise((resolve, reject) => {
            const waiting = { resolve: () => { signal.removeEventListener('abort', cancelled); resolve(); } };
            const cancelled = () => {
                this.queue = this.queue.filter(value => value !== waiting);
                reject(signal.reason);
            };
            signal.addEventListener('abort', cancelled, { once: true });
            this.queue.push(waiting);
        });
    }

    release() {
        const next = this.queue.shift();
        if (next) next.resolve();
        else this.active--;
    }
}

function validTimestamp(value) {
    return typeof value === 'string' && /T.+(?:Z|[+-]\d{2}:\d{2})$/i.test(value) && Number.isFinite(Date.parse(value));
}
function validStop(value) {
    if (!isObject(value) || !isString(value.id) || !isString(value.name)) return false;
    optional(value, 'platform', isString);
    return true;
}
const isString = value => typeof value === 'string';
const isBoolean = value => typeof value === 'boolean';
const nonnegativeNumber = value => Number.isFinite(value) && value >= 0;
const nonnegativeInteger = value => Number.isSafeInteger(value) && value >= 0;
const arrayOf = (validate, limit = 128) => value => Array.isArray(value) && value.length <= limit && value.every(validate);
function isObject(value) { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function optional(object, key, validate) {
    if (object[key] != null && !validate(object[key])) throw malformed();
}
function validWarning(value) {
    if (isString(value)) return true;
    if (!isObject(value) || !isString(value.message)) return false;
    for (const key of ['id', 'kind', 'severity']) optional(value, key, isString);
    return true;
}
function validValidityPeriod(value) {
    if (!isObject(value)) return false;
    optional(value, 'from', validTimestamp);
    optional(value, 'to', validTimestamp);
    return !value.from || !value.to || Date.parse(value.from) <= Date.parse(value.to);
}
function validIssue(value) {
    if (!isObject(value)) return false;
    for (const key of ['id', 'severity', 'kind', 'lineId', 'description', 'statusDescription', 'scope']) {
        optional(value, key, isString);
    }
    optional(value, 'statusCode', Number.isSafeInteger);
    optional(value, 'sources', arrayOf(isString));
    optional(value, 'validityPeriods', arrayOf(validValidityPeriod));
    optional(value, 'stale', isBoolean);
    optional(value, 'affectsLeg', isBoolean);
    return true;
}
function validDisruptionSource(value) {
    if (!isObject(value)) return false;
    optional(value, 'source', isString);
    optional(value, 'status', isString);
    optional(value, 'checkedAt', validTimestamp);
    return true;
}
function validDisruption(value) {
    if (!isObject(value)) return false;
    for (const key of ['status', 'summary', 'coverage']) optional(value, key, isString);
    optional(value, 'hasDisruption', isBoolean);
    optional(value, 'issues', arrayOf(validIssue));
    optional(value, 'sources', arrayOf(validDisruptionSource));
    return true;
}
function validateOptionalJourneyFields(journey) {
    optional(journey, 'warnings', arrayOf(validWarning));
    optional(journey, 'disruption', validDisruption);
    optional(journey, 'labels', arrayOf(isString));
    for (const key of ['durationMinutes', 'walkingMinutes', 'waitingMinutes']) optional(journey, key, nonnegativeNumber);
    optional(journey, 'changes', nonnegativeInteger);
    optional(journey, 'disruptionScore', Number.isFinite);
}
function validateOptionalLegFields(leg) {
    optional(leg, 'timing', isString);
    optional(leg, 'durationMinutes', nonnegativeNumber);
    optional(leg, 'scheduledDepartureTime', validTimestamp);
    optional(leg, 'scheduledArrivalTime', validTimestamp);
    optional(leg, 'stops', arrayOf(validStop, 512));
    optional(leg, 'warnings', arrayOf(validWarning));
    optional(leg, 'disruption', validDisruption);
}
function paletteMap(lines) {
    return new Map(lines.filter(line => typeof line?.id === 'string'
        && /^#[0-9a-f]{6}$/i.test(line.colour) && /^#[0-9a-f]{6}$/i.test(line.textColour)).map(line => [line.id, line]));
}
function unavailable(reason, status = 'unavailable', previous) {
    return { status, journeys: previous ? structuredClone(previous.journeys) : [],
        meta: { ...previous?.meta, reason, ...(previous ? { stale: true } : {}) },
        expiresAt: previous?.expiresAt ?? null, attribution: previous?.attribution ?? null,
        messages: [...(previous?.messages ?? []), status === 'unmapped'
            ? 'TfL directions are unavailable for this station mapping.'
            : 'TfL directions are unavailable; the National Rail transfer estimate is retained.'] };
}
function malformed() { return Object.assign(new Error('Malformed TubeTrack response'), { code: 'TUBE_MALFORMED' }); }
function cancelledError() { return Object.assign(new Error('TubeTrack search cancelled'), { code: 'SEARCH_CANCELLED' }); }
function throwIfCancelled(signal) { if (signal?.aborted) throw cancelledError(); }
function errorReason(error) {
    if (error.code === 'TUBE_MALFORMED' || error instanceof SyntaxError) return 'malformed';
    if (['TimeoutError', 'AbortError'].includes(error.name)) return 'timeout';
    if (error.status === 429) return 'rateLimited';
    return error.status ? 'upstream' : 'connectivity';
}
