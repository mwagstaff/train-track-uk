import { ukClockTime, ukDateParts } from "./time.js";

export function formatRailDataTimestamp(value, now = new Date()) {
  let date;
  if (typeof value === "string" && /^\d{2}:\d{2}$/.test(value)) {
    const current = ukDateParts(now);
    return `${current.year}${current.month}${current.day}T${value.replace(":", "")}00`;
  }
  date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error("scheduledDeparture must be an ISO date/time or HH:mm");
  const parts = ukDateParts(date);
  const minute = String(Math.floor(Number(parts.minute) / 30) * 30).padStart(2, "0");
  return `${parts.year}${parts.month}${parts.day}T${parts.hour}${minute}00`;
}

export class StaffDepartureBoardClient {
  constructor({ apiKey, baseUrl, timeoutMs, cacheTtlMs, fetchImpl = fetch, onRequest = () => {} }) {
    this.apiKey = apiKey;
    this.baseUrl = baseUrl.replace(/\/$/, "");
    this.timeoutMs = timeoutMs;
    this.cacheTtlMs = cacheTtlMs;
    this.fetchImpl = fetchImpl;
    this.onRequest = onRequest;
    this.cache = new Map();
    this.inFlight = new Map();
  }

  async getBoard(crs, scheduledDeparture) {
    const station = crs.trim().toUpperCase();
    const timestamp = formatRailDataTimestamp(scheduledDeparture);
    const key = `${station}:${timestamp}`;
    const cached = this.cache.get(key);
    if (cached && Date.now() - cached.storedAt < this.cacheTtlMs) return cached.data;

    if (this.inFlight.has(key)) return this.inFlight.get(key);

    const request = this.fetchBoard(station, timestamp, key);
    this.inFlight.set(key, request);
    try {
      return await request;
    } finally {
      this.inFlight.delete(key);
    }
  }

  async fetchBoard(station, timestamp, cacheKey) {
    return this.fetchJson(
      `${this.baseUrl}/GetDepBoardWithDetails/${encodeURIComponent(station)}/${timestamp}`,
      cacheKey,
      "Staff departure board",
    );
  }

  async getServiceDetailsByRid(rid) {
    const normalizedRid = String(rid ?? "").trim();
    if (!normalizedRid) throw new Error("rid is required");
    const key = `details:${normalizedRid}`;
    const cached = this.cache.get(key);
    if (cached && Date.now() - cached.storedAt < this.cacheTtlMs) return cached.data;
    if (this.inFlight.has(key)) return this.inFlight.get(key);

    const request = this.fetchJson(
      `${this.baseUrl}/GetServiceDetailsByRID/${encodeURIComponent(normalizedRid)}`,
      key,
      "Staff service details",
    );
    this.inFlight.set(key, request);
    try {
      return await request;
    } finally {
      this.inFlight.delete(key);
    }
  }

  async fetchJson(url, cacheKey, description) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
    const startedAt = Date.now();
    let outcome = "error";
    try {
      const response = await this.fetchImpl(url, {
        headers: { "x-apikey": this.apiKey, accept: "application/json" },
        signal: controller.signal,
      });
      outcome = String(response.status);
      if (!response.ok) throw new Error(`${description} returned HTTP ${response.status}`);
      const data = await response.json();
      this.cache.set(cacheKey, { storedAt: Date.now(), data });
      return data;
    } finally {
      clearTimeout(timeout);
      this.onRequest({ outcome, durationSeconds: (Date.now() - startedAt) / 1_000 });
    }
  }
}

const normalizedCrs = (value) => value?.trim().toUpperCase();

function serviceCallsAt(service, crs) {
  const target = normalizedCrs(crs);
  const locations = [...(service.subsequentLocations ?? []), ...(service.destination ?? [])];
  return locations.some((location) => normalizedCrs(location.crs) === target)
    || locations.some((location) => (location.associations ?? []).some((association) => (
      String(association.category ?? "").toLowerCase() === "divide"
        && association.isCancelled !== true
        && (normalizedCrs(association.destCRS) === target
          || normalizedCrs(association.destination?.crs) === target)
    )));
}

function finalDestination(service) {
  return normalizedCrs(service.destination?.[0]?.crs);
}

function scheduledTime(service) {
  const value = service.std ?? service.sta;
  const match = String(value ?? "").match(/(?:T|^)(\d{2}:\d{2})/);
  return match?.[1];
}

export function matchStaffService(board, request) {
  const requestedTime = ukClockTime(request.scheduledDeparture);
  if (!requestedTime) return { status: "unresolved", reason: "invalid_scheduled_time" };
  const timed = (board.trainServices ?? []).filter((service) => service.rid && scheduledTime(service) === requestedTime);
  const routed = timed.filter((service) => serviceCallsAt(service, request.to));
  if (routed.length === 0) return { status: "unresolved", reason: "no_staff_service_match" };

  const scored = routed.map((service) => {
    let score = 0;
    if (request.destinationCRS && finalDestination(service) === normalizedCrs(request.destinationCRS)) score += 4;
    if (request.length && service.length && Number(request.length) === Number(service.length)) score += 2;
    return { service, score };
  }).sort((left, right) => right.score - left.score);
  const bestScore = scored[0]?.score;
  const best = scored.filter((candidate) => candidate.score === bestScore);
  if (best.length !== 1) return { status: "unresolved", reason: "ambiguous_staff_service_match", candidateCount: best.length };
  return { status: "resolved", service: best[0].service };
}
