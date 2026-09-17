import { mkdir, open, readFile, writeFile, rename, rm, stat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { prepareSource, inspectPreparedSource } from './source.js';
import { readLines, parseStation, parseInterchange, parseFixedLink, parseTimetable, PARSER_VERSION } from './parser.js';
import { makeDiagnostics, recordDiagnostic, resolveServices, selectVariant, runsOn, weekdayIndex } from './calendar.js';
import { addDays } from './time.js';

export { inspectSource } from './source.js';
const DATABASE_FILE = 'timetable.sqlite';
const SCHEMA_VERSION = 1;

async function database(path, readOnly = false) {
  // Loaded only for planner work. Existing API startup remains compatible when
  // the optional planner is disabled. Supported planner runtime: Node >=22.16.
  let sqlite;
  try { sqlite = await import('node:sqlite'); }
  catch { throw new Error('Journey planner requires Node.js 22.16 or later with node:sqlite'); }
  return new sqlite.DatabaseSync(path, { readOnly });
}

async function json(path) { return JSON.parse(await readFile(path, 'utf8')); }
async function optionalJson(path) {
  try { return await json(path); } catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
async function writeJson(path, value) { await writeFile(path, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 }); }

function compactCalls(calls) {
  return calls.map(call => [call.tiploc, call.suffix, call.arrivalSeconds ?? null, call.departureSeconds ?? null,
    call.workArrival ?? null, call.workDeparture ?? null, call.workPass ?? null, call.publicArrival,
    call.publicDeparture, call.activity, call.platform ?? '', call.sourceRef.line]);
}

async function loadStations(member, options) {
  const records = [], aliases = [], stationByTiploc = new Map(), stationByCrs = new Map();
  for await (const { text, line } of readLines(member.path, options)) {
    const record = parseStation(text, { member: 'MSN', line });
    if (record?.type === 'station') records.push(record.value);
    if (record?.type === 'alias') aliases.push(record.value);
  }
  // Prefer the canonical physical definition to its subsidiary/minor entry.
  records.sort((a, b) => Number(b.crs === b.minorCrs) - Number(a.crs === a.minorCrs));
  for (const record of records) {
    const existing = stationByTiploc.get(record.tiploc);
    if (existing && existing.crs !== record.crs) throw new Error(`Conflicting MSN mapping for ${record.tiploc}`);
    stationByTiploc.set(record.tiploc, record);
    if (!stationByCrs.has(record.crs)) stationByCrs.set(record.crs, { crs: record.crs, name: record.name,
      minimumChangeMinutes: record.minimumChangeMinutes, aliases: [], tiplocs: [], selectable: false, sourceRef: record.sourceRef });
    const station = stationByCrs.get(record.crs);
    if (station.minimumChangeMinutes !== record.minimumChangeMinutes) throw new Error(`Conflicting MSN interchange allowance for ${record.crs}`);
    station.tiplocs.push(record.tiploc);
    for (const alias of [record.name, record.minorCrs]) {
      if (alias && alias !== station.name && alias !== station.crs && !station.aliases.includes(alias)) station.aliases.push(alias);
    }
  }
  for (const alias of aliases) {
    for (const record of records.filter(record => record.name === alias.name)) {
      const station = stationByCrs.get(record.crs);
      if (!station.aliases.includes(alias.alias)) station.aliases.push(alias.alias);
    }
  }
  return { records, stationByTiploc, stationByCrs };
}

export async function importFullSnapshot(sourcePath, targetDirectory, options = {}) {
  if (options.mode && options.mode !== 'full') throw new Error('Only full timetable refreshes are implemented');
  const target = resolve(targetDirectory);
  await mkdir(dirname(target), { recursive: true });
  const lockPath = `${target}.import.lock`;
  const lock = await open(lockPath, 'wx').catch(error => {
    if (error.code === 'EEXIST') throw new Error(`Another import owns ${lockPath}`);
    throw error;
  });
  const building = `${target}.building-${randomUUID()}`;
  let prepared, db;
  try {
    await lock.writeFile(`${JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() })}\n`);
    prepared = await prepareSource(sourcePath, options);
    const source = await inspectPreparedSource(prepared, options);
    const version = createHash('sha256').update(`${SCHEMA_VERSION}\0${PARSER_VERSION}\0${source.contentHash}`).digest('hex');
    const existing = await optionalJson(join(target, 'metadata.json'));
    if (existing) {
      if (existing.version !== version) throw new Error('Target already contains a different dataset; choose a new snapshot directory');
      const validation = await validateDataset(target);
      if (!validation.valid) throw new Error('Existing snapshot failed validation');
      return { version, path: target, metadata: existing, validation, unchanged: true };
    }
    await mkdir(building);
    db = await database(join(building, DATABASE_FILE));
    db.exec(`PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY;
      CREATE TABLE stations (crs TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE timing_locations (tiploc TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE source_records (source TEXT, kind TEXT, line INTEGER, data TEXT NOT NULL);
      CREATE TABLE rules (kind TEXT, data TEXT NOT NULL);
      CREATE TABLE associations (source TEXT, base_uid TEXT, associated_uid TEXT, start_date TEXT, end_date TEXT, data TEXT NOT NULL);
      CREATE TABLE variants (variant_id TEXT PRIMARY KEY, source TEXT NOT NULL, uid TEXT NOT NULL,
        start_date TEXT NOT NULL, end_date TEXT NOT NULL, days TEXT NOT NULL, stp TEXT NOT NULL,
        operator TEXT, mode TEXT, excluded_reason TEXT, line INTEGER, calls TEXT NOT NULL, data TEXT NOT NULL);
      BEGIN;`);
    const members = new Map(prepared.members.map(member => [member.type, member]));
    const { records, stationByTiploc, stationByCrs } = await loadStations(members.get('MSN'), options);
    const diagnostics = makeDiagnostics();
    const insertLocation = db.prepare('INSERT INTO timing_locations VALUES (?, ?)');
    for (const record of stationByTiploc.values()) insertLocation.run(record.tiploc, JSON.stringify(record));
    const ruleInsert = db.prepare('INSERT INTO rules VALUES (?, ?)');
    const counts = { stations: 0, stationDefinitions: records.length, schedules: 0, supportedSchedules: 0,
      associations: 0, fixedLinks: 0, interchanges: 0, calls: 0, passengerCalls: 0, changesEnRoute: 0 };
    for (const [type, parse] of [['TSI', parseInterchange], ['ALF', parseFixedLink]]) {
      for await (const { text, line } of readLines(members.get(type).path, options)) {
        if (!text.trim() || text.startsWith('/')) continue;
        let rule;
        try { rule = parse(text, { member: type, line }); }
        catch (error) { throw new Error(`${type}:${line}: ${error.message}`); }
        if (type === 'TSI') counts.interchanges++; else counts.fixedLinks++;
        ruleInsert.run(type, JSON.stringify(rule));
      }
    }
    const variantInsert = db.prepare('INSERT INTO variants VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
    const associationInsert = db.prepare('INSERT INTO associations VALUES (?, ?, ?, ?, ?, ?)');
    const sourceInsert = db.prepare('INSERT INTO source_records VALUES (?, ?, ?, ?)');
    let startDate = null, endDate = null, maxEventDayOffset = 0, maximumServiceDurationSeconds = 0;
    for (const sourceType of ['MCA', 'ZTR']) {
      for await (const record of parseTimetable(members.get(sourceType).path, sourceType, options)) {
        const value = record.value;
        if (record.type === 'association') {
          associationInsert.run(sourceType, value.baseUid, value.associatedUid, value.startDate, value.endDate, JSON.stringify(value));
          counts.associations++;
        } else if (record.type === 'schedule') {
          counts.schedules++;
          counts.calls += value.calls.length;
          counts.changesEnRoute += value.changes.length;
          for (const call of value.calls.filter(call => call.ambiguousMidnight)) {
            recordDiagnostic(diagnostics, 'AMBIGUOUS_MIDNIGHT_PUBLIC_TIME', { uid: value.uid, tiploc: call.tiploc, line: call.sourceRef.line });
          }
          if (!value.excludedReason && value.stp !== 'C') {
            if (!value.operator || !/^[A-Z0-9]{2}$/.test(value.operator)) value.excludedReason = 'MISSING_OPERATOR';
            const publicCalls = value.calls.filter(call => call.canBoard || call.canAlight);
            const missing = publicCalls.filter(call => !stationByTiploc.has(call.tiploc));
            if (missing.length) {
              // Retain the working but never offer an unnormalised passenger stop.
              recordDiagnostic(diagnostics, 'UNMAPPED_PASSENGER_CALLS', { uid: value.uid, locations: missing.map(call => call.tiploc) });
            }
            if (publicCalls.filter(call => stationByTiploc.has(call.tiploc)).length < 2) value.excludedReason = 'INSUFFICIENT_PASSENGER_CALLS';
          }
          if (value.excludedReason) recordDiagnostic(diagnostics, value.excludedReason, { uid: value.uid, variantId: value.variantId, detail: value.exclusionDetail });
          else if (value.stp !== 'C') {
            counts.supportedSchedules++;
            if (sourceType === 'MCA') { startDate = !startDate || value.startDate < startDate ? value.startDate : startDate; endDate = !endDate || value.endDate > endDate ? value.endDate : endDate; }
            let first = value.calls[0].workDeparture, last = first;
            for (const call of value.calls) {
              for (const seconds of [call.workArrival, call.workDeparture, call.workPass, call.arrivalSeconds, call.departureSeconds]) {
                if (seconds !== null && seconds !== undefined) { maxEventDayOffset = Math.max(maxEventDayOffset, Math.floor(seconds / 86400)); last = Math.max(last, seconds); }
              }
              if ((call.canBoard || call.canAlight) && stationByTiploc.has(call.tiploc)) {
                counts.passengerCalls++;
                stationByCrs.get(stationByTiploc.get(call.tiploc).crs).selectable = true;
              }
            }
            maximumServiceDurationSeconds = Math.max(maximumServiceDurationSeconds, last - first);
          }
          const { calls, ...detail } = value;
          variantInsert.run(value.variantId, sourceType, value.uid, value.startDate, value.endDate, value.days, value.stp,
            value.operator, value.mode, value.excludedReason, value.sourceRef.line, JSON.stringify(compactCalls(calls)), JSON.stringify(detail));
          if (counts.schedules % 2000 === 0) {
            db.exec('COMMIT; BEGIN;');
            options.onProgress?.({ phase: 'import', source: sourceType, schedules: counts.schedules, calls: counts.calls });
            options.signal?.throwIfAborted();
          }
        } else sourceInsert.run(sourceType, record.type, value.sourceRef.line, JSON.stringify(value));
      }
    }
    const insertStation = db.prepare('INSERT INTO stations VALUES (?, ?)');
    for (const station of stationByCrs.values()) { insertStation.run(station.crs, JSON.stringify(station)); if (station.selectable) counts.stations++; }
    db.exec(`COMMIT;
      CREATE INDEX variant_calendar ON variants(start_date, end_date);
      CREATE INDEX variant_uid ON variants(source, uid);
      CREATE INDEX association_uid ON associations(source, base_uid, associated_uid);
      PRAGMA optimize;`);
    for (const member of prepared.members) {
      const current = await stat(member.path);
      if (current.size !== member.size || current.mtimeMs !== member.mtimeMs || current.ctimeMs !== member.ctimeMs) {
        throw new Error(`Source changed during import: ${member.name}; stage a complete immutable package and retry`);
      }
    }
    const metadata = { schemaVersion: SCHEMA_VERSION, parserVersion: PARSER_VERSION, version, source,
      importedAt: new Date().toISOString(), coverage: { startDate, endDate, basis: 'Supported MCA schedule date range; completeness not guaranteed' },
      counts, maxEventDayOffset, maximumServiceDurationSeconds, diagnostics,
      capabilities: { scheduledOnly: true, departAfter: true, arriveBy: true, maximumChanges: 2,
        throughServices: false, supplementaryServices: false, fixedLinks: true },
      limitations: ['Scheduled timetable only; later timetable changes and live running are not included.',
        'Supplementary ZTR services and unsupported modes are retained but excluded.',
        'Train split/join associations are retained; staying aboard across separate service records is not enabled.',
        'Schedules with holiday restrictions are excluded until an authoritative holiday calendar is configured.',
        'Services originating in the ambiguous clock-change hour are excluded on the affected date.',
        'A 0000 public field is treated as midnight only when the corresponding working event is exactly midnight; otherwise that public event is excluded.',
        'ALF station-pair links apply in both directions. Traversal must fit within the available window (conservative prototype policy).'],
    };
    await writeJson(join(building, 'metadata.json'), metadata);
    db.close(); db = null;
    const validation = await validateDataset(building);
    await writeJson(join(building, 'validation.json'), validation);
    if (!validation.valid) throw new Error(`Dataset failed validation: ${validation.errors.join('; ')}`);
    await rename(building, target);
    return { version, path: target, metadata, validation, unchanged: false };
  } finally {
    db?.close();
    await prepared?.cleanup();
    await rm(building, { recursive: true, force: true });
    await lock.close();
    await rm(lockPath, { force: true });
  }
}

export async function validateDataset(datasetPath) {
  const path = resolve(datasetPath), errors = [], warnings = [];
  const metadata = await json(join(path, 'metadata.json'));
  const db = await database(join(path, DATABASE_FILE), true);
  try {
    if (metadata.schemaVersion !== SCHEMA_VERSION || metadata.parserVersion !== PARSER_VERSION) errors.push('Unsupported snapshot schema/parser version');
    const check = db.prepare('PRAGMA integrity_check').get();
    if (Object.values(check)[0] !== 'ok') errors.push('SQLite integrity check failed');
    const counts = db.prepare(`SELECT COUNT(*) total, SUM(CASE WHEN excluded_reason IS NULL AND stp != 'C' THEN 1 ELSE 0 END) supported FROM variants`).get();
    if (counts.total !== metadata.counts.schedules) errors.push('Schedule inventory mismatch');
    if (!counts.supported || !metadata.counts.stations || !metadata.coverage.startDate || !metadata.coverage.endDate) errors.push('No supported passenger timetable');
    const conflicts = db.prepare(`SELECT COUNT(*) count FROM (SELECT source,uid,start_date,stp FROM variants GROUP BY source,uid,start_date,stp HAVING COUNT(*)>1)`).get().count;
    if (conflicts) errors.push(`${conflicts} duplicate schedule-definition identities`);
    if (metadata.diagnostics && Object.keys(metadata.diagnostics.counts).length) warnings.push('Some records are excluded or have missing passenger mappings; inspect diagnostics');
    const representativeDates = [];
    if (!errors.length) {
      const repo = await openDataset(path);
      try {
        const publicationDate = metadata.source.generationDate;
        const weekday = (new Date(`${publicationDate}T12:00:00Z`).getUTCDay() + 6) % 7;
        const dates = new Set([metadata.coverage.startDate, metadata.coverage.endDate, publicationDate,
          addDays(publicationDate, (5 - weekday + 7) % 7), addDays(publicationDate, (6 - weekday + 7) % 7)]);
        for (const date of [...dates].sort()) {
          if (date < metadata.coverage.startDate || date > metadata.coverage.endDate) continue;
          representativeDates.push({ date, ...repo.resolveServices(date, { summaryOnly: true }) });
        }
      } finally { repo.close(); }
      if (!representativeDates.some(sample => sample.serviceCount > 0)) errors.push('No passenger services resolve on representative dates');
      if (representativeDates.some(sample => sample.diagnostics.counts.CONFLICTING_VARIANTS)) warnings.push('Conflicting dated schedule variants are excluded; inspect representative-date diagnostics');
    }
    return { valid: errors.length === 0, version: metadata.version, checkedAt: new Date().toISOString(), errors, warnings,
      counts: metadata.counts, diagnostics: metadata.diagnostics, representativeDates, databaseBytes: (await stat(join(path, DATABASE_FILE))).size };
  } finally { db.close(); }
}

export async function openDataset(datasetPath) {
  const path = resolve(datasetPath), metadata = await json(join(path, 'metadata.json'));
  if (metadata.schemaVersion !== SCHEMA_VERSION || metadata.parserVersion !== PARSER_VERSION) throw new Error('Unsupported planner snapshot format');
  const db = await database(join(path, DATABASE_FILE), true);
  const allStations = db.prepare('SELECT data FROM stations').all().map(row => JSON.parse(row.data));
  const stationByTiploc = new Map(db.prepare('SELECT data FROM timing_locations').all().map(row => { const value = JSON.parse(row.data); return [value.tiploc, value]; }));
  const rules = { tsi: [], links: [] };
  for (const row of db.prepare('SELECT kind,data FROM rules').all()) rules[row.kind === 'TSI' ? 'tsi' : 'links'].push(JSON.parse(row.data));
  // The weekday filter lets SQLite drop non-running variants before any JS work;
  // runsOn still applies the complete calendar rule to every returned row.
  const candidates = db.prepare(`SELECT variant_id variantId, source, uid, start_date startDate, end_date endDate,
    days,stp,operator,mode,excluded_reason excludedReason,line FROM variants WHERE start_date<=? AND end_date>=? AND substr(days,?,1)='1'`);
  const dateCandidates = date => candidates.all(date, date, weekdayIndex(date) + 1);
  const variant = db.prepare('SELECT calls,data FROM variants WHERE variant_id=?');
  const VARIANT_BATCH = 500;
  const variantBatch = db.prepare(`SELECT variant_id variantId, calls FROM variants WHERE variant_id IN (${Array(VARIANT_BATCH).fill('?').join(',')})`);
  const readVariantCalls = ids => {
    const calls = new Map();
    for (let offset = 0; offset < ids.length; offset += VARIANT_BATCH) {
      const chunk = ids.slice(offset, offset + VARIANT_BATCH);
      while (chunk.length < VARIANT_BATCH) chunk.push(null);
      for (const row of variantBatch.all(...chunk)) calls.set(row.variantId, row.calls);
    }
    return calls;
  };
  const repository = { version: metadata.version, path, metadata, stations: allStations.filter(station => station.selectable), allStations, stationByTiploc, rules,
    dateCandidates, readVariant: id => variant.get(id), readVariantCalls,
    resolveServices: (date, options) => resolveServices(repository, date, options),
    resolveServiceExplanation: (uid, date, source = 'MCA') => {
      const rows = dateCandidates(date).filter(row => row.uid === uid && row.source === source);
      const decision = selectVariant(rows, date);
      return { version: metadata.version, source, uid, originDate: date, reason: decision.reason,
        selectedVariantId: decision.selected?.variantId ?? null,
        candidates: rows.map(row => ({ ...row, dateApplicable: runsOn(row, date) })) };
    }, close: () => db.close() };
  return repository;
}

export async function getActiveDataset(dataDirectory) { return optionalJson(join(resolve(dataDirectory), 'active.json')); }

export async function activateDataset(datasetPath, dataDirectory, options = {}) {
  const path = resolve(datasetPath), directory = resolve(dataDirectory);
  await mkdir(directory, { recursive: true });
  const lockPath = join(directory, '.activation.lock'), lock = await open(lockPath, 'wx');
  try {
    const validation = await validateDataset(path);
    if (!validation.valid) throw new Error(`Cannot activate invalid dataset: ${validation.errors.join('; ')}`);
    const previous = await getActiveDataset(directory);
    if (previous?.version === validation.version) return { ...previous, unchanged: true };
    if (previous && !options.allowLargeChange) {
      const priorMetadata = await json(join(previous.path, 'metadata.json'));
      for (const key of ['stations', 'supportedSchedules']) {
        if (validation.counts[key] < priorMetadata.counts[key] * 0.7) throw new Error(`Activation blocked: ${key} fell by over 30%; inspect the candidate before explicitly accepting a coverage change`);
      }
      const candidateMetadata = await json(join(path, 'metadata.json'));
      const date = candidateMetadata.source.generationDate;
      if (date >= priorMetadata.coverage.startDate && date <= priorMetadata.coverage.endDate
        && date >= candidateMetadata.coverage.startDate && date <= candidateMetadata.coverage.endDate) {
        const priorRepo = await openDataset(previous.path), nextRepo = await openDataset(path);
        try {
          const prior = priorRepo.resolveServices(date, { summaryOnly: true });
          const next = nextRepo.resolveServices(date, { summaryOnly: true });
          for (const [operator, count] of Object.entries(prior.operatorCounts)) {
            if (count >= 20 && (next.operatorCounts[operator] ?? 0) < count * 0.7) {
              throw new Error(`Activation blocked: ${operator} resolved passenger services fell by over 30% on ${date}; inspect the candidate before accepting a coverage change`);
            }
          }
        } finally { priorRepo.close(); nextRepo.close(); }
      }
    }
    const pointer = { version: validation.version, path, activatedAt: new Date().toISOString(),
      previousVersion: previous?.version ?? null, previousPath: previous?.path ?? null };
    const historyPath = join(directory, 'activation-history.json');
    const history = await optionalJson(historyPath) ?? [];
    const nextHistory = `${historyPath}.${randomUUID()}`;
    await writeJson(nextHistory, [...history, pointer]);
    await rename(nextHistory, historyPath);
    const nextPointer = join(directory, `.active-${randomUUID()}.json`);
    await writeJson(nextPointer, pointer);
    await rename(nextPointer, join(directory, 'active.json'));
    return pointer;
  } finally { await lock.close(); await rm(lockPath, { force: true }); }
}

export async function rollbackDataset(version, dataDirectory) {
  const active = await getActiveDataset(dataDirectory);
  const history = await optionalJson(join(resolve(dataDirectory), 'activation-history.json')) ?? [];
  const target = version ? history.findLast(item => item.version === version)
    : active?.previousPath ? { path: active.previousPath } : null;
  if (!target) throw new Error('Requested rollback version is not retained in activation history');
  return activateDataset(target.path, dataDirectory, { allowLargeChange: true });
}
