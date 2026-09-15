// RSPS5046 P-04-02 §5.3.6: a train keeps its origin's GMT/BST timing
// convention for its entire working. Do not convert every stop independently.
export const DAY_MS = 86400000;

export function dateOnly(value) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || new Date(`${value}T00:00:00Z`).toISOString().slice(0, 10) !== value) {
    throw new Error(`Invalid calendar date: ${value}`);
  }
  return value;
}

export function cifDate(value) {
  if (!/^\d{6}$/.test(value)) throw new Error(`Invalid CIF date: ${value}`);
  // Explicit format policy: this importer accepts the 2000–2099 timetable era.
  // The supplementary 991231 sentinel therefore remains 2099-12-31.
  return dateOnly(`20${value.slice(0, 2)}-${value.slice(2, 4)}-${value.slice(4, 6)}`);
}

export function addDays(date, days) {
  return new Date(Date.parse(`${dateOnly(date)}T00:00:00Z`) + days * DAY_MS).toISOString().slice(0, 10);
}

export function londonDate(epoch) {
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/London', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(epoch));
}

export function parseClock(value) {
  if (!value?.trim()) return null;
  const text = value.trim();
  if (!/^\d{4}H?$/.test(text)) throw new Error(`Invalid timetable time: ${value}`);
  const hours = Number(text.slice(0, 2));
  const minutes = Number(text.slice(2, 4));
  if (hours > 23 || minutes > 59) throw new Error(`Invalid timetable time: ${value}`);
  return hours * 3600 + minutes * 60 + (text.endsWith('H') ? 30 : 0);
}

function lastSunday(year, month) {
  const last = new Date(Date.UTC(year, month + 1, 0));
  last.setUTCDate(last.getUTCDate() - last.getUTCDay());
  return last.toISOString().slice(0, 10);
}

export function originOffsetMinutes(date, originSeconds) {
  dateOnly(date);
  const year = Number(date.slice(0, 4));
  const spring = lastSunday(year, 2);
  const autumn = lastSunday(year, 9);
  if ((date === spring || date === autumn) && originSeconds >= 3600 && originSeconds < 7200) {
    const error = new Error('Origin falls in an unresolved clock-change hour');
    error.code = 'AMBIGUOUS_CLOCK_CHANGE';
    throw error;
  }
  if (date < spring || date > autumn) return 0;
  if (date === spring) return originSeconds < 3600 ? 0 : 60;
  if (date === autumn) return originSeconds < 3600 ? 60 : 0;
  return 60;
}

function publicOffset(raw, work) {
  const seconds = parseClock(raw);
  if (seconds === null || work === null) return null;
  // 0000 is the missing-public-time sentinel. Only an actual working event at
  // midnight establishes a midnight public event; never invent one at noon.
  if (seconds === 0 && work % 86400 !== 0) return null;
  return seconds + Math.round((work - seconds) / 86400) * 86400;
}

export function normaliseCallTimes(calls) {
  let previous = null;
  let day = 0;
  const nextWork = raw => {
    const seconds = parseClock(raw);
    if (seconds === null) return null;
    let value = seconds + day * 86400;
    if (previous !== null && value < previous) {
      // Small backwards steps are malformed timings, not 24-hour journeys.
      if (previous - value < 43200) throw new Error('Working chronology moves backwards');
      day += 1;
      value += 86400;
    }
    previous = value;
    return value;
  };
  const result = calls.map(call => {
    const workArrival = nextWork(call.workingArrival);
    const workDeparture = nextWork(call.workingDeparture);
    const workPass = nextWork(call.workingPass);
    const arrivalSeconds = call.canAlight ? publicOffset(call.publicArrival, workArrival) : null;
    const departureSeconds = call.canBoard ? publicOffset(call.publicDeparture, workDeparture) : null;
    const ambiguousMidnight = [[call.publicArrival, workArrival, call.canAlight], [call.publicDeparture, workDeparture, call.canBoard]]
      .some(([raw, work, advertised]) => advertised && raw === '0000' && work !== null && work % 86400 !== 0
        && Math.min(work % 86400, 86400 - work % 86400) <= 60);
    return { ...call, workArrival, workDeparture, workPass, arrivalSeconds, departureSeconds,
      ambiguousMidnight,
      canBoard: call.canBoard && departureSeconds !== null, canAlight: call.canAlight && arrivalSeconds !== null };
  });
  const first = result[0]?.workDeparture;
  if (first === null || first === undefined) throw new Error('Missing working origin departure');
  let lastPublic = null;
  for (const call of result) {
    for (const value of [call.arrivalSeconds, call.departureSeconds]) {
      if (value === null) continue;
      if (value < 0 || (lastPublic !== null && value < lastPublic)) throw new Error('Public chronology moves backwards');
      lastPublic = value;
    }
  }
  if (previous - first > 48 * 3600) throw new Error('Service exceeds supported 48-hour duration');
  return result;
}

export function resolveCallTimes(calls, originDate) {
  const offset = originOffsetMinutes(originDate, calls[0].workDeparture % 86400);
  const base = Date.parse(`${dateOnly(originDate)}T00:00:00Z`) - offset * 60000;
  return calls.map(call => ({ ...call,
    arrival: call.arrivalSeconds === null ? null : base + call.arrivalSeconds * 1000,
    departure: call.departureSeconds === null ? null : base + call.departureSeconds * 1000,
  }));
}
