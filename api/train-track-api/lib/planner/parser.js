import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';
import { cifDate, dateOnly, normaliseCallTimes, parseClock } from './time.js';

export const PARSER_VERSION = 'rsps5046-p04-02/v3';

export async function* readLines(path, { signal } = {}) {
  const input = createReadStream(path, { encoding: 'latin1', signal });
  const reader = createInterface({ input, crlfDelay: Infinity });
  let line = 0;
  try {
    for await (const text of reader) {
      signal?.throwIfAborted();
      yield { text, line: ++line };
    }
  } finally { reader.close(); input.destroy(); }
}

export function parseDisplayDate(value) {
  const match = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(value);
  if (!match) throw new Error(`Invalid display date: ${value}`);
  return dateOnly(`${match[3]}-${match[2]}-${match[1]}`);
}

export function parseStation(line, sourceRef) {
  if (line.startsWith('A') && !line.includes('FILE-SPEC=')) {
    if (line.length !== 82) throw new Error(`MSN station width ${line.length}, expected 82`);
    const minimum = line.slice(63, 65).trim();
    const result = { name: line.slice(5, 31).trim(), interchangeStatus: line[35],
      tiploc: line.slice(36, 43).trim(), minorCrs: line.slice(43, 46).trim(),
      crs: line.slice(49, 52).trim(), minimumChangeMinutes: minimum === '' ? null : Number(minimum), sourceRef };
    if (!/^[A-Z0-9]{3}$/.test(result.crs) || !result.tiploc || !/^[01239]$/.test(result.interchangeStatus)
      || (minimum !== '' && !/^\d{1,2}$/.test(minimum))) throw new Error('Malformed MSN station');
    return { type: 'station', value: result };
  }
  if (line.startsWith('L')) {
    if (line.length !== 82) throw new Error('Malformed MSN alias width');
    return { type: 'alias', value: { name: line.slice(5, 31).trim(), alias: line.slice(36, 62).trim(), sourceRef } };
  }
  return null;
}

export function parseInterchange(line, sourceRef) {
  const [station, arrivingOperator, departingOperator, minutes] = line.split(',');
  if (!/^[A-Z0-9]{3}$/.test(station) || !/^[A-Z0-9]{2}$/.test(arrivingOperator)
    || !/^[A-Z0-9]{2}$/.test(departingOperator) || !/^\d{1,2}$/.test(minutes) || Number(minutes) < 1) {
    throw new Error('Malformed TSI record');
  }
  return { station, arrivingOperator, departingOperator, minutes: Number(minutes), id: `TSI:${sourceRef.line}`, sourceRef };
}

const LINK_MODES = { WALK: 'walk', TUBE: 'tubeTransfer', METRO: 'metroTransfer', TRAM: 'tramTransfer',
  BUS: 'busTransfer', FERRY: 'ferryTransfer', TRANSFER: 'genericTransfer' };
const ACTIVITIES = new Set(['A','AE','AX','BL','C','D','-D','E','G','H','HH','K','KC','KE','KF','KS','L','N','OP','OR','PR',
  'R','RM','RR','S','T','-T','TB','TF','TS','TW','U','-U','W','X']);

export function parseFixedLink(line, sourceRef) {
  const fields = {};
  for (const field of line.trim().split(',')) {
    const match = /^([MODTSEPFUR])=(.+)$/.exec(field);
    if (!match || fields[match[1]] !== undefined) throw new Error('Malformed or duplicate ALF field');
    fields[match[1]] = match[2];
  }
  if (!LINK_MODES[fields.M] || !/^[A-Z0-9]{3}$/.test(fields.O) || !/^[A-Z0-9]{3}$/.test(fields.D)
    || !/^\d{1,2}$/.test(fields.T) || Number(fields.T) < 1 || !/^[1-7]$/.test(fields.P)
    || !/^\d{4}$/.test(fields.S) || !/^\d{4}$/.test(fields.E) || !/^[01]{7}$/.test(fields.R ?? '1111111')) {
    throw new Error('Malformed ALF record');
  }
  parseClock(fields.S); parseClock(fields.E);
  const startDate = fields.F ? parseDisplayDate(fields.F) : undefined;
  const endDate = fields.U ? parseDisplayDate(fields.U) : undefined;
  if (startDate && endDate && startDate > endDate) throw new Error('Inverted ALF calendar');
  return { id: `ALF:${sourceRef.line}`, origin: fields.O, destination: fields.D, mode: LINK_MODES[fields.M],
    minutes: Number(fields.T), startTime: fields.S, endTime: fields.E, priority: Number(fields.P),
    startDate, endDate, days: fields.R ?? '1111111', sourceRef };
}

export function scheduleMode(status, category) {
  if (['P', '1'].includes(status) && ['OL', 'OO', 'OW', 'XC', 'XD', 'XI', 'XR', 'XX', 'XZ'].includes(category)) return 'rail';
  if (['B', '5'].includes(status) && category === 'BR') return 'replacementBus';
  return null;
}

function parseCall(text, sequence, sourceRef) {
  const type = text.slice(0, 2);
  const activity = type === 'LO' ? text.slice(29, 41) : type === 'LT' ? text.slice(25, 37) : text.slice(42, 54);
  const codes = activity.match(/.{2}/g).map(value => value.trim()).filter(Boolean);
  // Network Rail CIF End User Specification, Appendix A. In particular -U,
  // -D and -T are vehicle attachment activities, not passenger restrictions.
  const advertised = !codes.some(c => ['N', 'S'].includes(c));
  const pickup = codes.some(c => ['T', 'U', 'R'].includes(c));
  const setdown = codes.some(c => ['T', 'D', 'R'].includes(c));
  const board = advertised && (type === 'LO' ? codes.includes('TB') && (!codes.includes('D') || pickup) : type === 'LI' && pickup);
  const alight = advertised && (type === 'LT' ? codes.includes('TF') && (!codes.includes('U') || setdown) : type === 'LI' && setdown);
  return { type, tiploc: text.slice(2, 9).trim(), suffix: text[9].trim(), sequence,
    workingArrival: type === 'LO' ? '' : text.slice(10, 15),
    workingDeparture: type === 'LT' ? '' : type === 'LO' ? text.slice(10, 15) : text.slice(15, 20),
    workingPass: type === 'LI' ? text.slice(20, 25) : '',
    publicArrival: type === 'LO' ? '' : type === 'LT' ? text.slice(15, 19) : text.slice(25, 29),
    publicDeparture: type === 'LT' ? '' : type === 'LO' ? text.slice(15, 19) : text.slice(29, 33),
    platform: (type === 'LI' ? text.slice(33, 36) : text.slice(19, 22)).trim() || undefined,
    activity, canBoard: Boolean(board), canAlight: Boolean(alight), requestStop: codes.includes('R'),
    unsupportedActivity: codes.some(code => !ACTIVITIES.has(code)), sourceRef };
}

export async function* parseTimetable(path, source, options = {}) {
  let schedule = null;
  let header = false;
  let trailer = false;
  function finish() {
    if (!schedule) return null;
    const value = schedule;
    schedule = null;
    if (value.stp !== 'C' && value.transaction !== 'D') {
      if (!value.hasExtra || value.calls[0]?.type !== 'LO' || value.calls.at(-1)?.type !== 'LT') {
        throw new Error(`Incomplete schedule ${value.uid} at ${source}:${value.sourceRef.line}`);
      }
      try { value.calls = normaliseCallTimes(value.calls); }
      catch (error) { value.excludedReason ??= 'INVALID_CHRONOLOGY'; value.exclusionDetail = error.message; }
      if (value.calls.some(call => call.unsupportedActivity)) value.excludedReason ??= 'UNSUPPORTED_ACTIVITY';
      if (value.changes.some(change => scheduleMode(value.status, change.category) !== value.mode)) value.excludedReason ??= 'MODE_CHANGE_EN_ROUTE';
    } else if (value.calls.length) throw new Error('Cancellation/deletion unexpectedly has calling points');
    delete value.hasExtra;
    return { type: 'schedule', value };
  }
  for await (const { text, line } of readLines(path, options)) {
    if (text.length !== 80) throw new Error(`${source}:${line}: record width ${text.length}, expected 80`);
    const type = text.slice(0, 2);
    const sourceRef = { member: source, line };
    if (trailer) throw new Error(`${source}:${line}: data after timetable trailer`);
    if (!header && type !== 'HD') throw new Error(`${source}: missing timetable header`);
    if (type === 'HD') {
      if (header) throw new Error(`${source}: duplicate header`);
      header = true;
      yield { type: 'header', value: { raw: text, sourceRef } };
    } else if (type === 'BS') {
      const previous = finish(); if (previous) yield previous;
      const transaction = text[2], stp = text[79];
      if (transaction !== 'N') throw new Error(`${source}:${line}: full importer rejects ${transaction} transactions; updates need a baseline`);
      if (!'PCON'.includes(stp)) throw new Error(`${source}:${line}: unknown STP indicator`);
      const startDate = cifDate(text.slice(9, 15)), endDate = cifDate(text.slice(15, 21)), days = text.slice(21, 28);
      if (startDate > endDate || !/^[01]{7}$/.test(days)) throw new Error(`${source}:${line}: malformed calendar`);
      const uid = text.slice(3, 9).trim(), status = text[29], category = text.slice(30, 32);
      const mode = scheduleMode(status, category);
      schedule = { variantId: `${source}:${line}`, source, sourceRef, uid, startDate, endDate, days, transaction, stp,
        status, category, bankHoliday: text[28].trim(), operator: null, mode, calls: [], changes: [],
        excludedReason: stp === 'C' ? null : source === 'ZTR' ? 'SUPPLEMENTARY_DIALECT_NOT_ENABLED'
          : text[28].trim() ? 'HOLIDAY_CALENDAR_NOT_CONFIGURED' : !mode ? 'UNSUPPORTED_MODE' : null };
    } else if (['BX', 'LO', 'LI', 'LT', 'CR'].includes(type)) {
      if (!schedule) throw new Error(`${source}:${line}: orphan ${type} record`);
      if (type === 'BX') {
        if (schedule.hasExtra || schedule.calls.length) throw new Error('Misordered BX record');
        schedule.hasExtra = true;
        schedule.operator = text.slice(11, 13).trim() || null;
        schedule.retailServiceId = source === 'ZTR' ? null : text.slice(14, 22).trim();
      } else if (type === 'CR') {
        schedule.changes.push({ tiploc: text.slice(2, 9).trim(), suffix: text[9].trim(), category: text.slice(10, 12), raw: text, sourceRef });
      } else {
        if (!schedule.hasExtra || (type === 'LO' && schedule.calls.length) || (type !== 'LO' && !schedule.calls.length)
          || schedule.calls.at(-1)?.type === 'LT') throw new Error(`${source}:${line}: misordered ${type}`);
        schedule.calls.push(parseCall(text, schedule.calls.length, sourceRef));
      }
    } else if (type === 'AA') {
      if (schedule) throw new Error('Association appears inside schedule section');
      if (text[2] !== 'N' || !/^[01]{7}$/.test(text.slice(27, 34)) || !'PCON'.includes(text[79])) {
        throw new Error(`${source}:${line}: invalid full-feed association`);
      }
      yield { type: 'association', value: { source, sourceRef, raw: text, transaction: text[2],
        baseUid: text.slice(3, 9).trim(), associatedUid: text.slice(9, 15).trim(), startDate: cifDate(text.slice(15, 21)),
        endDate: cifDate(text.slice(21, 27)), days: text.slice(27, 34), category: text.slice(34, 36),
        dateIndicator: text[36], tiploc: text.slice(37, 44).trim(), baseSuffix: text[44].trim(), associatedSuffix: text[45].trim(),
        associationType: text[47], stp: text[79] } };
    } else if (type === 'TI') {
      yield { type: 'location', value: { source, sourceRef, tiploc: text.slice(2, 9).trim(), crs: text.slice(53, 56).trim(), raw: text } };
    } else if (type === 'ZZ') {
      const previous = finish(); if (previous) yield previous;
      trailer = true;
    } else throw new Error(`${source}:${line}: unsupported critical record ${type}`);
  }
  if (!header || !trailer) throw new Error(`${source}: truncated timetable (missing HD/ZZ)`);
}
