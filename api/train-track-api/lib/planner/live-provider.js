import { getWithRetry } from '../upstream-api-client.js';

// Public LDBWS JSON supplies board-relative IDs and clock times, not Darwin
// UID/RID/origin dates. Preserve these observations for separate strict matching.
// https://realtime.nationalrail.co.uk/LDBWS/static/ldbws.json
// Strict legacy documented limits: fewer than 150 rows, offset/window < 120.
// https://lite.realtime.nationalrail.co.uk/OpenLDBWS/documentation.aspx
export const LIVE_BOARD_OFFSETS = Object.freeze([-119, 0, 118]);
export const LIVE_BOARD_WINDOW_MINUTES = 119;
export const LIVE_BOARD_ROWS = 149;
const MAX_REQUESTS = 64;
const TIMEOUT_MS = 3000;
const CACHE_TTL_MS = 30_000;
const CACHE_ENTRIES = 256;
const BOARD_URL = 'https://api1.raildata.org.uk/1010-live-departure-board-dep1_2/LDBWS/api/20220120/GetDepartureBoard/';
const DETAILS_URL = 'https://api1.raildata.org.uk/1010-service-details1_2/LDBWS/api/20220120/GetServiceDetails/';
const STAFF_BOARD_URL = 'https://api1.raildata.org.uk/1010-live-departure-board---staff-version1_0/LDBSVWS/api/20220120/GetDepBoardWithDetails/';
const staffClock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London',
  year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });

export function staffBoardKey({ station, departure }) {
  if (!/^[A-Z]{3}$/.test(station) || !Number.isFinite(departure)
    || !Number.isFinite(new Date(departure).getTime())) throw new TypeError('Invalid staff board reference');
  const parts = Object.fromEntries(staffClock.formatToParts(new Date(departure)).map(part => [part.type, part.value]));
  return `${station}:${parts.year}${parts.month}${parts.day}T${parts.hour}${parts.minute}00`;
}

export function createLiveRequestBudget(limit = MAX_REQUESTS) {
  if (!Number.isSafeInteger(limit) || limit < 0) throw new TypeError('Invalid live request budget');
  return { limit: Math.min(limit, MAX_REQUESTS), used: 0 };
}

/** A worker-scoped adapter. Pass one budget across every discovery round.
 * Signals must be real AbortSignals; the computing worker bridges shared cancel.
 * Clock strings remain provider strings. Neither absent services nor empty boards
 * establish cancellation or a complete live search interval.
 */
export class PlannerLiveProvider {
  constructor({ request = getWithRetry, now = Date.now, credentials = () => ({
    board: process.env.LIVE_DEPARTURE_BOARD_API_KEY,
    details: process.env.SERVICE_DETAILS_API_KEY,
    staff: process.env.STAFF_DEPARTURES_API_KEY
  }) } = {}) {
    this.request = request;
    this.now = now;
    this.credentials = credentials;
    this.cache = new Map();
    this.active = 0;
    this.queue = [];
    this.inflight = new Map();
  }

  async fetchBoards(stations, options = {}) {
    const codes = [...new Set(stations.map(station => String(station).trim().toUpperCase()))];
    if (codes.some(station => !/^[A-Z]{3}$/.test(station))) throw new TypeError('Invalid live board station');
    const offsets = options.offsets ?? LIVE_BOARD_OFFSETS;
    if (!Array.isArray(offsets) || offsets.length > 3 || offsets.some(value => !Number.isInteger(value) || value <= -120 || value >= 120)) {
      throw new TypeError('Invalid live board offsets');
    }
    const requests = codes.flatMap(station => [...new Set(offsets)].map(offset => ({
      kind: 'board', station, offset,
      key: `board:${station}:${offset}`,
      url: `${BOARD_URL}${station}?numRows=${LIVE_BOARD_ROWS}&timeOffset=${offset}&timeWindow=${LIVE_BOARD_WINDOW_MINUTES}`
    })));
    return this.fetchBatch(requests, 'boards', options);
  }

  async fetchDetails(services, options = {}) {
    const unique = new Map();
    for (const { serviceID, station } of services) {
      if (typeof serviceID !== 'string' || !serviceID.trim() || serviceID.length > 256 || !/^[A-Z]{3}$/.test(station)) {
        throw new TypeError('Invalid live service reference');
      }
      const key = `details:${station}:${serviceID}`;
      unique.set(key, { kind: 'details', station, serviceID, key, url: `${DETAILS_URL}${encodeURIComponent(serviceID)}` });
    }
    return this.fetchBatch([...unique.values()], 'details', options);
  }

  supportsStaffRecovery() { return Boolean(this.credentials().staff); }

  // Target only the departure minute that needs recovery. Staff boards include
  // dated forecasts and timetable UIDs, avoiding the public composite-ID error.
  // They share the public adapter's semaphore, cache and per-search budget.
  async fetchStaffBoards(targets, options = {}) {
    const unique = new Map();
    for (const target of targets) {
      const key = staffBoardKey(target);
      const [station, time] = key.split(':');
      unique.set(key, { kind: 'staff', station, departure: target.departure, key: `staff:${key}`,
        url: `${STAFF_BOARD_URL}${station}/${time}?numRows=9&timeWindow=2&services=P` });
    }
    return this.fetchBatch([...unique.values()], 'boards', options);
  }

  async fetchBatch(requests, resultKey, options) {
    const budget = options.budget ?? createLiveRequestBudget(options.requestLimit ?? MAX_REQUESTS);
    if (!Number.isSafeInteger(budget.limit) || budget.limit < 0 || budget.limit > MAX_REQUESTS
      || !Number.isSafeInteger(budget.used) || budget.used < 0 || budget.used > budget.limit) throw new TypeError('Invalid live request budget');
    const result = { [resultKey]: [], errors: [], requestCount: 0, limited: false };
    let cursor = 0;
    // At most two pending adapter calls per batch; the instance semaphore also
    // bounds parallel batches. Cached successes do not consume upstream budget.
    await Promise.all([0, 1].map(async () => {
      while (cursor < requests.length) {
        throwIfCancelled(options.signal);
        const request = requests[cursor++];
        const cached = this.cached(request.key, options.now ?? this.now());
        if (cached) { result[resultKey].push(cached); continue; }
        const key = this.credentials()[request.kind === 'staff' ? 'staff' : request.kind === 'board' ? 'board' : 'details'];
        if (!key) { result.errors.push(failure(request, 'credentialsUnavailable')); continue; }
        if (!this.inflight.has(request.key) && budget.used >= budget.limit) {
          result.limited = true;
          result.errors.push(failure(request, 'requestLimit'));
          continue;
        }
        if (!this.inflight.has(request.key)) { budget.used++; result.requestCount++; }
        try {
          const value = await this.sharedFetch(request, key, options.signal, options.now);
          result[resultKey].push(value);
        } catch (error) {
          throwIfCancelled(options.signal);
          result.errors.push(failure(request, errorReason(error)));
        }
      }
    }));
    return result;
  }

  sharedFetch(item, apiKey, signal, fixedNow) {
    throwIfCancelled(signal);
    let flight = this.inflight.get(item.key);
    if (!flight) {
      flight = { controller: new AbortController(), consumers: 0 };
      const current = flight;
      flight.promise = this.fetchOne(item, apiKey, flight.controller.signal, fixedNow).then(value => {
        this.remember(item.key, value, fixedNow ?? this.now());
        return value;
      }).finally(() => {
        if (this.inflight.get(item.key) === current) this.inflight.delete(item.key);
      });
      this.inflight.set(item.key, flight);
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
          if (this.inflight.get(item.key) === flight) this.inflight.delete(item.key);
        }
        error ? reject(error) : resolve(structuredClone(value));
      };
      const cancelled = () => finish(Object.assign(new Error('Live request cancelled'), { code: 'SEARCH_CANCELLED' }));
      signal?.addEventListener('abort', cancelled, { once: true });
      flight.promise.then(value => finish(null, value), error => finish(error));
    });
  }

  async fetchOne(item, apiKey, signal, fixedNow) {
    // Includes waiting for this adapter and shared-host request spacing. Axios's
    // own timeout alone would only cover the eventual HTTP request.
    const boundedSignal = AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(TIMEOUT_MS)]);
    await this.acquire(boundedSignal);
    try {
      boundedSignal.throwIfAborted();
      const response = await this.request({
        api: item.kind === 'staff' ? 'rail_staff_departure_board' : item.kind === 'board' ? 'rail_departure_board' : 'rail_service_details',
        operation: item.kind === 'staff' ? 'get_departure_board_with_details' : item.kind === 'board' ? 'get_departure_board' : 'get_service_details',
        url: item.url, headers: { 'x-apikey': apiKey },
        timeoutMs: TIMEOUT_MS, maxRetries: 0, signal: boundedSignal
      });
      boundedSignal.throwIfAborted();
      const fetchedAt = new Date(fixedNow ?? this.now()).toISOString();
      return item.kind === 'staff' ? normalizeStaffBoard(response.data, item, fetchedAt)
        : item.kind === 'board' ? normalizeBoard(response.data, item, fetchedAt)
        : normalizeDetails(response.data, item, fetchedAt);
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

  cached(key, now) {
    const value = this.cache.get(key);
    if (!value) return null;
    if (now < value.cachedAt || now - value.cachedAt >= CACHE_TTL_MS) { this.cache.delete(key); return null; }
    this.cache.delete(key);
    this.cache.set(key, value);
    return structuredClone(value.observation);
  }

  remember(key, observation, now) {
    this.cache.delete(key);
    this.cache.set(key, { cachedAt: now, observation: structuredClone(observation) });
    while (this.cache.size > CACHE_ENTRIES) this.cache.delete(this.cache.keys().next().value);
  }
}

function normalizeStaffBoard(raw, item, fetchedAt) {
  assertObject(raw);
  if (raw.crs !== item.station || (raw.trainServices != null && !Array.isArray(raw.trainServices))) throw malformed();
  const services = raw.servicesAreUnavailable === true ? [] : (raw.trainServices ?? []).slice(0, 9).map(service => {
    assertObject(service);
    for (const field of ['previousLocations', 'subsequentLocations']) {
      if (service[field] != null && (!Array.isArray(service[field]) || service[field].length > 512)) throw malformed();
      for (const location of service[field] ?? []) assertObject(location);
    }
    return { ...structuredClone(service), ...(raw.platformsAreHidden === true ? { platformIsHidden: true } : {}) };
  });
  return { station: item.station, generatedAt: timestamp(raw.generatedAt), fetchedAt, services,
    servicesAreUnavailable: raw.servicesAreUnavailable === true,
    possiblyTruncated: (raw.trainServices?.length ?? 0) >= 9 };
}

function normalizeBoard(raw, item, fetchedAt) {
  assertObject(raw);
  if (raw.crs !== item.station) throw malformed();
  const services = [];
  for (const [field, type] of [['trainServices', 'train'], ['busServices', 'bus'], ['ferryServices', 'ferry']]) {
    if (raw[field] != null && !Array.isArray(raw[field])) throw malformed();
    for (const service of (raw[field] ?? []).slice(0, LIVE_BOARD_ROWS)) {
      assertObject(service);
      services.push({ ...normalizeService(service), serviceType: service.serviceType ?? type });
    }
  }
  return {
    station: item.station, generatedAt: timestamp(raw.generatedAt), fetchedAt,
    window: { offsetMinutes: item.offset, windowMinutes: LIVE_BOARD_WINDOW_MINUTES, numRows: LIVE_BOARD_ROWS },
    ...pick(raw, ['areServicesAvailable', 'platformAvailable']),
    possiblyTruncated: services.length >= LIVE_BOARD_ROWS,
    services
  };
}

function normalizeDetails(raw, item, fetchedAt) {
  if (raw == null) throw Object.assign(new Error('Service unavailable'), { code: 'LIVE_SERVICE_UNAVAILABLE' });
  assertObject(raw);
  if (raw.crs !== item.station) throw malformed();
  const detail = normalizeService(raw);
  for (const field of ['previousCallingPoints', 'subsequentCallingPoints']) {
    if (raw[field] != null && !Array.isArray(raw[field])) throw malformed();
    if ((raw[field]?.length ?? 0) > 16) throw malformed();
    detail[field] = (raw[field] ?? []).map(group => {
      if (!Array.isArray(group?.callingPoint) || group.callingPoint.length > 256) throw malformed();
      return { ...pick(group, ['serviceType', 'serviceChangeRequired', 'assocIsCancelled']), callingPoint: group.callingPoint.map(point => {
        assertObject(point);
        return pick(point, ['crs', 'st', 'et', 'at', 'isCancelled', 'cancelReason', 'delayReason', 'uncertainty', 'affectedByDiversion', 'rerouteDelay']);
      }) };
    });
  }
  return { serviceID: item.serviceID, station: item.station, generatedAt: timestamp(raw.generatedAt), fetchedAt, detail };
}

function normalizeService(raw) {
  return pick(raw, ['serviceID', 'crs', 'rsid', 'operatorCode', 'serviceType', 'sta', 'eta', 'ata', 'std', 'etd', 'atd',
    'platform', 'length', 'isCancelled', 'cancelReason', 'delayReason', 'futureCancellation', 'futureDelay', 'filterLocationCancelled',
    'isCircularRoute', 'origin', 'destination', 'currentOrigins', 'currentDestinations', 'uncertainty', 'diversion',
    'divertedVia', 'diversionReason', 'overdueMessage']);
}

function pick(object, keys) {
  return Object.fromEntries(keys.filter(key => object[key] !== undefined).map(key => [key, structuredClone(object[key])]));
}
function timestamp(value) {
  if (typeof value !== 'string' || !/T.+(?:Z|[+-]\d{2}:\d{2})$/i.test(value) || !Number.isFinite(Date.parse(value))) return null;
  return new Date(value).toISOString();
}
function malformed() { return Object.assign(new Error('Malformed live response'), { code: 'LIVE_MALFORMED' }); }
function assertObject(value) { if (!value || typeof value !== 'object' || Array.isArray(value)) throw malformed(); }
function throwIfCancelled(signal) {
  if (signal?.aborted) throw Object.assign(new Error('Live request cancelled'), { code: 'SEARCH_CANCELLED' });
}
function failure(request, reason) {
  return { station: request.station, ...(request.serviceID ? { serviceID: request.serviceID }
    : request.kind === 'staff' ? { departure: request.departure, source: 'staff' } : { offsetMinutes: request.offset }), reason };
}
function errorReason(error) {
  if (error.code === 'LIVE_MALFORMED') return 'malformed';
  if (error.code === 'LIVE_SERVICE_UNAVAILABLE') return 'unavailable';
  if (['TimeoutError', 'AbortError'].includes(error.name) || ['ECONNABORTED', 'ETIMEDOUT', 'ERR_CANCELED'].includes(error.code)) return 'timeout';
  const status = error.response?.status;
  return status === 429 ? 'rateLimited' : [401, 403].includes(status) ? 'authentication' : status ? 'upstream' : 'connectivity';
}
