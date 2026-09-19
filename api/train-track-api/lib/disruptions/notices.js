import { XMLParser, XMLValidator } from 'fast-xml-parser';
import { addDays, dateOnly, originOffsetMinutes } from '../planner/time.js';
import { noticeAffectsJourney } from './relevance.js';

// National Rail Incidents v5: Planned=true identifies engineering work.
// Affects.RoutesAffected is prose, not structured CRS data; Progress=closed
// means a cleared incident, never a line closure.
// https://assets.nationalrail.co.uk/e8xgegruud3g/58gBgQCvfLYDdRWfgOuMmS/f00023eb3c5ace68db9693a0761038a6/Incidents_XML_Feed.pdf
const parser = new XMLParser({ ignoreAttributes: false, removeNSPrefix: true,
    parseTagValue: false, parseAttributeValue: false, trimValues: true });
const array = value => value == null ? [] : Array.isArray(value) ? value : [value];
const string = value => typeof value === 'string' ? value : typeof value?.['#text'] === 'string' ? value['#text'] : '';
const flag = value => ['true', '1'].includes(string(value).toLowerCase());
const text = value => string(value).replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, ' ').replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;|&#160;/gi, ' ').replace(/&amp;/gi, '&').replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'").replace(/&lt;/gi, '<').replace(/&gt;/gi, '>').replace(/\s+/g, ' ').trim();
const normal = value => value.normalize('NFKC').replace(/[‘’]/g, "'").replace(/\s+/g, ' ').trim().toLowerCase();
const invalid = () => Object.assign(new Error('The planned engineering feed could not be interpreted.'), { code: 'invalid_feed' });

function timestamp(value, required = true) {
    const raw = string(value);
    if (!raw && !required) return null;
    if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(raw)) throw invalid();
    if (Number(raw.slice(11, 13)) > 23 || Number(raw.slice(14, 16)) > 59 || Number(raw.slice(17, 19)) > 59) throw invalid();
    try { dateOnly(raw.slice(0, 10)); } catch { throw invalid(); }
    if (!Number.isFinite(Date.parse(raw))) throw invalid();
    return new Date(raw).toISOString();
}

function stationMatcher(definitions) {
    const names = new Map();
    for (const station of array(definitions)) {
        if (!/^[A-Z0-9]{3}$/.test(station?.crs)) continue;
        for (const name of [station.name, ...(Array.isArray(station.aliases) ? station.aliases : [])]) {
            if (typeof name !== 'string' || !name.trim()) continue;
            const key = normal(name), codes = names.get(key) ?? new Set();
            codes.add(station.crs); names.set(key, codes);
        }
    }
    const ordered = [...names].sort((a, b) => b[0].length - a[0].length);
    const match = routes => {
        const value = normal(routes), occupied = [], codes = new Set();
        for (const [name, matches] of ordered) {
            let offset = value.indexOf(name);
            while (offset >= 0) {
                const end = offset + name.length;
                const boundary = !/[\p{L}\p{N}]/u.test(value[offset - 1] ?? '') && !/[\p{L}\p{N}]/u.test(value[end] ?? '');
                if (boundary && !occupied.some(([from, to]) => offset < to && end > from)) {
                    if (matches.size === 1) codes.add([...matches][0]);
                    // An ambiguous longer station name cannot become a false
                    // match for an unambiguous shorter name inside it.
                    occupied.push([offset, end]);
                }
                offset = value.indexOf(name, offset + 1);
            }
        }
        return [...codes].sort();
    };
    match.exact = name => {
        const codes = names.get(normal(name));
        return codes?.size === 1 ? [...codes] : [];
    };
    return match;
}

function proseBlocks(value) {
    return string(value).replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, ' ')
        .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, ' ')
        .replace(/<\/?(?:p|div|li|ul|ol|h[1-6]|blockquote|tr)\b[^>]*>|<br\b[^>]*>/gi, '\n')
        .split(/[\r\n]+/).map(text).filter(Boolean);
}

function affectedStationClauses(routes, matchStations) {
    return proseBlocks(routes).flatMap(block => block.split(/;|[.!?](?:\s+|$)/)).flatMap(clause => {
        // Multiple services in a single ambiguous prose clause cannot safely
        // combine endpoints from different branches. Separate paragraphs and
        // semicolon/sentence clauses remain independently usable.
        if (['between', 'from', 'to', 'services?'].some(word =>
            (clause.match(new RegExp(`\\b${word}\\b`, 'gi'))?.length ?? 0) > 1)
            || (clause.match(/\s[-–—]\s|[–—]/g)?.length ?? 0) > 1) return [];
        const stations = matchStations(clause);
        return stations.length ? [stations] : [];
    });
}

function wholeStationClosureTail(value) {
    // Accept only unconditional whole-station formulations. A prefix such as
    // "closed to Southern services only" or "closed if work overruns" cannot
    // establish a closure for every service using this station.
    const tail = value.trim().replace(/[.:]$/, '').trim()
        .replace(/,?\s*and (?:will )?(?:only be served|only served) by (?:(?:accessible|replacement) )*buses$/i, '').trim();
    const weekday = '(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday)';
    return tail === '' || new RegExp(`^(?:all (?:day|weekend)(?: on ${weekday})?|throughout (?:the )?(?:day|weekend)|on ${weekday}(?: and ${weekday})?)$`, 'i').test(tail);
}

function explicitlyClosedStations(description, matchStations) {
    const closed = new Set();
    const facilityOnly = /\b(?:platforms?|entrances?|ticket offices?|booking offices?|car parks?|footbridges?|lifts?|escalators?)\b/i;
    const markup = string(description);
    // Only the list immediately following an explicit whole-station closure
    // heading counts. General body mentions, bus stops and ticket acceptance
    // never supply route evidence.
    const lists = /<(p|div|h[1-6])\b[^>]*>((?:(?!<\/?(?:p|div|h[1-6])\b)[\s\S])*?)<\/\1>\s*<(ul|ol)\b[^>]*>([\s\S]*?)<\/\3>/gi;
    for (const match of markup.matchAll(lists)) {
        const heading = text(match[2]);
        const closure = heading.match(/^the following stations (?:will be|are) closed\b(.*)$/i);
        if (!closure || !wholeStationClosureTail(closure[1]) || facilityOnly.test(heading)) continue;
        for (const item of match[4].matchAll(/<li\b[^>]*>([\s\S]*?)<\/li>/gi)) {
            for (const station of matchStations.exact(text(item[1]))) closed.add(station);
        }
    }
    for (const block of proseBlocks(description)) {
        const statement = block.match(/^(.+?)(?:\s+station)?\s+(?:will be|is|remains?)\s+closed\b(.*)$/i);
        if (statement && wholeStationClosureTail(statement[2]) && !facilityOnly.test(block)) {
            for (const station of matchStations.exact(statement[1])) closed.add(station);
        }
    }
    return [...closed].sort();
}

function nationalRailURL(links) {
    for (const link of array(links?.InfoLink)) {
        try {
            const url = new URL(string(link.Uri));
            if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password
                || !(url.hostname === 'nationalrail.co.uk' || url.hostname.endsWith('.nationalrail.co.uk'))) continue;
            url.protocol = 'https:';
            return url.href;
        } catch { /* Only validated official source links are displayed. */ }
    }
    return 'https://www.nationalrail.co.uk/status-and-disruptions/';
}

export function parseEngineeringNotices(xml, { stationDefinitions = [], onInvalidIncident } = {}) {
    // Reject DTD/entity declarations before parsing; the feed has no need for
    // them. The transport separately bounds decompressed response bytes.
    if (typeof xml !== 'string' || /<!DOCTYPE|<!ENTITY/i.test(xml) || XMLValidator.validate(xml) !== true) throw invalid();
    let parsed;
    try { parsed = parser.parse(xml); } catch { throw invalid(); }
    const root = parsed.Incidents ?? parsed.Xtis?.Incidents;
    if (root === undefined || root === null || typeof root !== 'object' && root !== '') throw invalid();
    if (Object.keys(root).some(key => !key.startsWith('@_') && !['PtIncident', '#text'].includes(key))) throw invalid();
    const matchStations = stationMatcher(stationDefinitions), notices = [], unverifiedIDs = new Set();
    for (const incident of array(root.PtIncident)) {
        try {
            if (!incident || typeof incident !== 'object' || !['true', 'false', '1', '0'].includes(string(incident.Planned).toLowerCase())) throw invalid();
            if (!flag(incident.Planned) || flag(incident.ClearedIncident) || string(incident.Progress).toLowerCase() === 'closed') continue;
            const incidentID = string(incident.IncidentNumber);
            if (!incidentID || incidentID.length > 256 || !array(incident.ValidityPeriod).length) throw invalid();
            const title = text(incident.Summary).slice(0, 500) || 'Planned engineering work';
            const routesMarkup = incident.Affects?.RoutesAffected, routes = text(routesMarkup);
            const body = text(incident.Description).slice(0, 10000) || routes || 'See National Rail for details of this planned engineering work.';
            const clauses = affectedStationClauses(routesMarkup, matchStations);
            const closedStationCRS = explicitlyClosedStations(incident.Description, matchStations);
            const stationCRS = [...new Set([...clauses.flat(), ...closedStationCRS])].sort();
            const sourceURL = nationalRailURL(incident.InfoLinks);
            const updatedAt = timestamp(incident.ChangeHistory?.LastChangedDate, false);
            const incidentNotices = [];
            for (const period of array(incident.ValidityPeriod)) {
                const startAt = timestamp(period?.StartTime), endAt = timestamp(period?.EndTime, false);
                if (endAt && Date.parse(endAt) <= Date.parse(startAt)) throw invalid();
                incidentNotices.push({ id: `${incidentID}:${startAt}`, incidentId: incidentID, title, body, startAt, endAt,
                    stationCRS, affectedStationClauses: clauses, closedStationCRS,
                    sourceURL, planned: true, kind: 'engineering', ...(updatedAt ? { updatedAt } : {}) });
            }
            notices.push(...incidentNotices);
        } catch (error) {
            if (error.code !== 'invalid_feed' || typeof onInvalidIncident !== 'function') throw error;
            const rawID = string(incident?.IncidentNumber);
            const incidentId = rawID && rawID.length <= 256 ? rawID : null;
            unverifiedIDs.add(incidentId);
            // Never return part of an invalid incident, or upstream content in
            // diagnostics. A missing ID means prior incidents cannot be ruled out.
            onInvalidIncident({ incidentId, reason: 'invalid_incident' });
        }
    }
    const verified = notices.filter(notice => !unverifiedIDs.has(notice.incidentId));
    if (unverifiedIDs.size && !verified.length) throw invalid();
    return [...new Map(verified.map(notice => [notice.id, notice])).values()];
}

function windowInstant(date, minutes) {
    const day = addDays(date, Math.floor(minutes / 1440)), clockMinutes = minutes % 1440;
    return Date.parse(`${day}T00:00:00Z`) + (clockMinutes - originOffsetMinutes(day, clockMinutes * 60)) * 60000;
}

/** Match the requested journey itself, never a union of possible itinerary
 * stations. Exact affected-service clauses and explicit station closures are
 * useful evidence, but do not prove that every departure is affected. */
export function matchEngineeringNotices(notices, { stations = [], date, startMinutes = 0, endMinutes = 1440 } = {}) {
    if (!Number.isInteger(startMinutes) || !Number.isInteger(endMinutes) || startMinutes < 0
        || startMinutes >= 1440 || endMinutes <= startMinutes || endMinutes > startMinutes + 1440) return [];
    let from, to;
    try { dateOnly(date); from = windowInstant(date, startMinutes); to = windowInstant(date, endMinutes); }
    catch { return []; }
    return array(notices).filter(notice => noticeAffectsJourney(notice, stations)
        && Number.isFinite(Date.parse(notice.startAt)) && Date.parse(notice.startAt) < to
        && (!notice.endAt || Number.isFinite(Date.parse(notice.endAt)) && Date.parse(notice.endAt) > from));
}

export function createPlannedEngineeringProvider({ endpoint, authorization, username, password, headers = {}, stationDefinitions = [],
    fetchImpl = globalThis.fetch, now = Date.now, timeoutMs = 10000, maximumBytes = 5 * 1024 * 1024, cacheMs = 300000 } = {}) {
    let cached, flight;
    const unavailable = reason => ({ available: false, checkedAt: new Date(now()).toISOString(), notices: [], reason });
    async function refresh() {
        if (!endpoint) return unavailable('not_configured');
        let url;
        try {
            url = new URL(endpoint);
            if (url.protocol !== 'https:' || url.username || url.password) return unavailable('invalid_configuration');
            if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || !Number.isSafeInteger(maximumBytes) || maximumBytes <= 0) return unavailable('invalid_configuration');
        } catch { return unavailable('invalid_configuration'); }
        const controller = new AbortController();
        const timer = setTimeout(() => controller.abort(), timeoutMs);
        timer.unref?.();
        try {
            const requestHeaders = { accept: 'application/xml, text/xml', ...headers };
            if (authorization) requestHeaders.authorization = authorization;
            else if (username !== undefined && password !== undefined) requestHeaders.authorization = `Basic ${Buffer.from(`${username}:${password}`).toString('base64')}`;
            const response = await fetchImpl(url.href, { headers: requestHeaders, signal: controller.signal, redirect: 'error' });
            if (!response.ok) return unavailable([401, 403].includes(response.status) ? 'access_denied' : 'upstream_unavailable');
            if (Number(response.headers?.get('content-length')) > maximumBytes) {
                controller.abort(); return unavailable('feed_too_large');
            }
            if (!response.body) return unavailable('invalid_feed');
            let size = 0;
            const chunks = [];
            for await (const chunk of response.body) {
                const bytes = Buffer.from(chunk);
                size += bytes.length;
                if (size > maximumBytes) { controller.abort(); return unavailable('feed_too_large'); }
                chunks.push(bytes);
            }
            const unverifiedIDs = new Set();
            const notices = parseEngineeringNotices(Buffer.concat(chunks).toString('utf8'), { stationDefinitions,
                onInvalidIncident: ({ incidentId }) => unverifiedIDs.add(incidentId) });
            const complete = unverifiedIDs.size === 0;
            return { available: true, complete, checkedAt: new Date(now()).toISOString(), notices,
                unverifiedIncidentIds: [...unverifiedIDs], reason: complete ? null : 'partial_feed' };
        } catch (error) {
            return unavailable(controller.signal.aborted ? 'timeout' : error.code === 'invalid_feed' ? 'invalid_feed' : 'upstream_unavailable');
        } finally { clearTimeout(timer); }
    }
    return {
        async getSnapshot({ signal, force = false } = {}) {
            if (signal?.aborted) return unavailable('cancelled');
            if (!flight && (force || !cached || now() - Date.parse(cached.checkedAt) >= cacheMs)) {
                flight = refresh().then(value => { cached = value; return value; }).finally(() => { flight = null; });
            }
            if (!flight) return structuredClone(cached);
            if (!signal) return structuredClone(await flight);
            // One caller cancelling must not poison the shared authoritative snapshot.
            let cancelled;
            const cancellation = new Promise(resolve => {
                cancelled = () => resolve(unavailable('cancelled'));
                signal.addEventListener('abort', cancelled, { once: true });
            });
            try { return structuredClone(await Promise.race([flight, cancellation])); }
            finally { signal.removeEventListener('abort', cancelled); }
        }
    };
}
