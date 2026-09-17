import { dateOnly, resolveCallTimes } from './time.js';

const weekdays = new Map();

/** Monday is 0. Every candidate row of a date consults this, so cache it. */
export function weekdayIndex(date) {
  let weekday = weekdays.get(date);
  if (weekday === undefined) {
    dateOnly(date);
    weekday = (new Date(`${date}T12:00:00Z`).getUTCDay() + 6) % 7;
    if (weekdays.size >= 64) weekdays.clear();
    weekdays.set(date, weekday);
  }
  return weekday;
}

export function runsOn(variant, date) {
  const weekday = weekdayIndex(date);
  return variant.startDate <= date && variant.endDate >= date && variant.days[weekday] === '1';
}

// Transactions are applied by the full importer (which rejects delta files).
// C suppresses the permanent working; O replaces it. N is an independent STP
// insertion and cannot be silently merged with a permanent working of that UID.
export function selectVariant(variants, date) {
  const candidates = variants.filter(variant => runsOn(variant, date));
  const permanent = candidates.filter(variant => variant.stp === 'P');
  const overlays = candidates.filter(variant => variant.stp === 'O');
  const inserted = candidates.filter(variant => variant.stp === 'N');
  const cancelled = candidates.filter(variant => variant.stp === 'C');
  if (inserted.length) {
    if (inserted.length !== 1 || permanent.length || overlays.length || cancelled.length) {
      return { selected: null, reason: 'CONFLICTING_VARIANTS', candidates: candidates.map(v => v.variantId) };
    }
    return { selected: inserted[0], reason: 'NEW_STP', candidates: candidates.map(v => v.variantId) };
  }
  if (cancelled.length) return { selected: null, reason: 'CANCELLED', candidates: candidates.map(v => v.variantId) };
  if (overlays.length > 1 || (!overlays.length && permanent.length > 1)) {
    return { selected: null, reason: 'CONFLICTING_VARIANTS', candidates: candidates.map(v => v.variantId) };
  }
  return { selected: overlays[0] ?? permanent[0] ?? null,
    reason: overlays.length ? 'OVERLAY' : permanent.length ? 'PERMANENT' : 'NOT_RUNNING', candidates: candidates.map(v => v.variantId) };
}

export function makeDiagnostics() { return { counts: {}, examples: [] }; }

export function recordDiagnostic(diagnostics, code, detail = {}) {
  diagnostics.counts[code] = (diagnostics.counts[code] ?? 0) + 1;
  if (diagnostics.examples.length < 100 && diagnostics.examples.filter(example => example.code === code).length < 5) diagnostics.examples.push({ code, ...detail });
}

export function decodeCalls(rows, stationByTiploc) {
  return rows.map((row, sequence) => ({
    tiploc: row[0], suffix: row[1], sequence, station: stationByTiploc.get(row[0])?.crs ?? null,
    arrivalSeconds: row[2], departureSeconds: row[3], workArrival: row[4], workDeparture: row[5], workPass: row[6],
    publicArrival: row[7], publicDeparture: row[8], activity: row[9], platform: row[10] || undefined,
    canAlight: row[2] !== null, canBoard: row[3] !== null, sourceLine: row[11], requestStop: hasRequestStop(row[9]),
  }));
}

// Activity codes are two-character fields; a lone R marks a request stop.
function hasRequestStop(activity) {
  for (let index = 0; index + 1 < activity.length; index += 2) {
    if (activity.slice(index, index + 2).trim() === 'R') return true;
  }
  return false;
}

export function resolveServices(repository, originDate, { summaryOnly = false, signal } = {}) {
  function check() {
    if (signal?.aborted) throw Object.assign(new Error('Timetable preparation cancelled'), { code: 'SEARCH_CANCELLED' });
  }
  dateOnly(originDate);
  check();
  // SQLite returns this date's metadata in one synchronous call. Cancellation
  // and CPU throttling resume at the following row/group checkpoints.
  const rows = repository.dateCandidates(originDate);
  const groups = new Map();
  let rowIndex = 0;
  for (const row of rows) {
    if (rowIndex++ % 256 === 0) check();
    const key = `${row.source}:${row.uid}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }
  const services = [], diagnostics = makeDiagnostics();
  const summary = { serviceCount: 0, operatorCounts: {}, stationCount: 0 }, stations = new Set();
  const selected = [];
  for (const group of groups.values()) {
    // Outside the per-service catch: cancellation/deadline errors must not be
    // misreported as an unsupported timetable record or cached as partial data.
    check();
    const decision = selectVariant(group, originDate);
    const variant = decision.selected;
    if (!variant) {
      if (decision.reason !== 'NOT_RUNNING') recordDiagnostic(diagnostics, decision.reason, { uid: group[0].uid, candidates: decision.candidates });
      continue;
    }
    if (variant.excludedReason) {
      recordDiagnostic(diagnostics, variant.excludedReason, { uid: variant.uid, variantId: variant.variantId });
      continue;
    }
    selected.push({ variant, decision });
  }
  check();
  // One batched read per date instead of a point lookup per selected service.
  const storedCalls = repository.readVariantCalls
    ? repository.readVariantCalls(selected.map(({ variant }) => variant.variantId))
    : new Map(selected.map(({ variant }) => [variant.variantId, repository.readVariant(variant.variantId).calls]));
  for (const { variant, decision } of selected) {
    check();
    try {
      const calls = resolveCallTimes(decodeCalls(JSON.parse(storedCalls.get(variant.variantId)), repository.stationByTiploc), originDate)
        .filter(call => call.station && (call.canBoard || call.canAlight));
      if (calls.length < 2) { recordDiagnostic(diagnostics, 'INSUFFICIENT_PASSENGER_CALLS', { uid: variant.uid }); continue; }
      if (summaryOnly) {
        summary.serviceCount++;
        summary.operatorCounts[variant.operator] = (summary.operatorCounts[variant.operator] ?? 0) + 1;
        for (const call of calls) stations.add(call.station);
        continue;
      }
      services.push({ id: `${repository.version}:${variant.variantId}:${originDate}`, variantId: variant.variantId,
        uid: variant.uid, source: variant.source, originDate, operator: variant.operator, mode: variant.mode, calls,
        sourceRef: { member: variant.source, line: variant.line }, resolution: decision.reason });
    } catch (error) {
      recordDiagnostic(diagnostics, error.code ?? 'INVALID_SERVICE_TIME', { uid: variant.uid, detail: error.message });
    }
  }
  check();
  summary.stationCount = stations.size;
  return summaryOnly ? { ...summary, diagnostics } : { services, diagnostics };
}
