import { mkdir, mkdtemp, open, readFile, writeFile, copyFile, rename, rm, stat, lstat } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { createHash } from 'node:crypto';
import { prepareSource, inspectPreparedSource } from './source.js';
import { readLines } from './parser.js';
import { cifDate, dateOnly } from './time.js';
import { acquireOwnedLock } from './ingestion-lock.js';

const SCHEMA_VERSION = 1;
const DATABASE_FILE = 'canonical.sqlite';
const AUXILIARIES = ['MSN', 'TSI', 'ALF', 'FLF', 'ZTR', 'REJ', 'SET'];

function failure(code, message, details = {}) { return Object.assign(new Error(message), { code, ...details }); }

async function database(path, readOnly = false) {
  let sqlite;
  try { sqlite = await import('node:sqlite'); }
  catch { throw new Error('Timetable delivery imports require Node.js 22.16 or later with node:sqlite'); }
  return new sqlite.DatabaseSync(path, { readOnly });
}

export function nextDeliverySequence(sequence) {
  if (!/^(?!000)\d{3}$/.test(sequence)) throw new Error(`Invalid timetable sequence: ${sequence}`);
  return String(Number(sequence) % 999 + 1).padStart(3, '0');
}

export async function readDeliveryMetadata(directory) {
  const path = resolve(directory);
  const metadata = JSON.parse(await readFile(join(path, 'metadata.json'), 'utf8'));
  if (metadata.schemaVersion !== SCHEMA_VERSION || !metadata.canonicalHash) throw new Error('Unsupported canonical timetable delivery format');
  nextDeliverySequence(metadata.sequence);
  if (!(await lstat(join(path, DATABASE_FILE))).isFile()) throw new Error('Missing canonical timetable database');
  return metadata;
}

function headerDetails(raw, generationDate, feedMode) {
  if (raw[46] !== (feedMode === 'full' ? 'F' : 'U')) throw new Error(`Unexpected ${feedMode} timetable HD update indicator`);
  const value = raw.slice(22, 28);
  const extractDate = /^\d{6}$/.test(value) ? dateOnly(`20${value.slice(4, 6)}-${value.slice(2, 4)}-${value.slice(0, 2)}`) : null;
  if (feedMode === 'update' && extractDate !== generationDate) throw new Error('Daily HD extract date does not match manifest generation date');
  return { raw, extractDate, currentReference: raw.slice(32, 39).trim(), previousReference: raw.slice(39, 46).trim(),
    // Full refresh HD dates/references may be historical constants (RSPS5046 §5.5.1.2).
    referenceUsable: extractDate === generationDate && Boolean(raw.slice(32, 39).trim()) };
}

function scheduleIdentity(raw) {
  const uid = raw.slice(3, 9).trim(), startDate = cifDate(raw.slice(9, 15)), stp = raw[79];
  if (!/^[A-Z0-9]{6}$/.test(uid) || !'PCON'.includes(stp)) throw new Error('Malformed schedule identity');
  if (raw[2] !== 'D' && (startDate > cifDate(raw.slice(15, 21)) || !/^[01]{7}$/.test(raw.slice(21, 28)))) throw new Error('Malformed schedule calendar');
  return { identity: [uid, startDate, stp].join('|'), uid, startDate, stp };
}

function associationIdentity(raw) {
  const baseUid = raw.slice(3, 9).trim(), associatedUid = raw.slice(9, 15).trim(), startDate = cifDate(raw.slice(15, 21)), stp = raw[79];
  const location = raw.slice(37, 44).trim(), diagram = raw[46];
  if (!/^[A-Z0-9]{6}$/.test(baseUid) || !/^[A-Z0-9]{6}$/.test(associatedUid) || !location || diagram !== 'T' || !'PCON'.includes(stp)) throw new Error('Malformed association identity');
  if (raw[2] !== 'D' && (startDate > cifDate(raw.slice(21, 27)) || !/^[01]{7}$/.test(raw.slice(27, 34)))) throw new Error('Malformed association calendar');
  // §5.3.4.6: diagram type, not passenger/operating association type, is part of
  // the identity. STP additionally separates the permanent/overlay/cancellation
  // definitions; otherwise genuine full-file cancellation rows collide.
  return { identity: [baseUid, associatedUid, startDate, diagram, location, raw[44], raw[45], stp].join('|'), baseUid, associatedUid, startDate, stp };
}

function counts(db) {
  return { schedules: db.prepare('SELECT COUNT(*) count FROM schedules').get().count,
    associations: db.prepare('SELECT COUNT(*) count FROM associations').get().count,
    timingLocations: db.prepare('SELECT COUNT(*) count FROM timing_locations').get().count };
}

function checkDatabase(db, expected) {
  if (db.prepare('PRAGMA quick_check').get().quick_check !== 'ok') throw new Error('Canonical timetable database integrity check failed');
  const actual = counts(db);
  if (expected && Object.keys(actual).some(key => actual[key] !== expected[key])) throw new Error('Canonical timetable inventory mismatch');
  return actual;
}

async function applyMain(db, path, source, baseline, options) {
  const statements = {};
  for (const table of ['schedules', 'associations', 'timing_locations']) {
    const key = table === 'timing_locations' ? 'tiploc' : 'identity';
    statements[table] = { exists: db.prepare(`SELECT 1 FROM ${table} WHERE ${key}=?`),
      remove: db.prepare(`DELETE FROM ${table} WHERE ${key}=?`),
      insert: db.prepare(table === 'schedules' ? 'INSERT INTO schedules VALUES (?, ?, ?, ?, ?)'
        : table === 'associations' ? 'INSERT INTO associations VALUES (?, ?, ?, ?, ?, ?, ?)'
          : 'INSERT INTO timing_locations VALUES (?, ?)') };
  }
  const operations = { schedules: { N: 0, R: 0, D: 0 }, associations: { N: 0, R: 0, D: 0 }, timingLocations: { N: 0, R: 0, D: 0 } };
  let header, schedule, order = 0, processed = 0;
  function transaction(table, key, type, values) {
    if (!'NRD'.includes(type) || (source.feedMode === 'full' && type !== 'N')) throw new Error(`Invalid ${source.feedMode} ${table} transaction: ${type}`);
    const statement = statements[table], exists = Boolean(statement.exists.get(key));
    if (type === 'N' && exists) throw failure('UPDATE_TARGET_DUPLICATE', `New ${table} target already exists: ${key}`, { table, identity: key });
    if (type !== 'N' && !exists) throw failure('UPDATE_TARGET_MISSING', `${type === 'R' ? 'Revision' : 'Deletion'} ${table} target is absent: ${key}`, { table, identity: key });
    if (type !== 'N') statement.remove.run(key);
    if (type !== 'D') statement.insert.run(...values);
    operations[table === 'timing_locations' ? 'timingLocations' : table][type]++;
    if (++processed % 2000 === 0) { db.exec('COMMIT; BEGIN;'); options.onProgress?.({ phase: 'canonical', processed, operations }); }
  }
  function finishSchedule() {
    if (!schedule) return;
    const { raw, fields, records } = schedule;
    if (raw[2] === 'D' || fields.stp === 'C') {
      if (records.length !== 1) throw new Error('Cancellation/deletion unexpectedly has detail records');
    } else if (records[1]?.slice(0, 2) !== 'BX' || records[2]?.slice(0, 2) !== 'LO' || records.at(-1)?.slice(0, 2) !== 'LT') throw new Error(`Incomplete schedule ${fields.identity}`);
    const block = [`${raw.slice(0, 2)}N${raw.slice(3)}`, ...records.slice(1)].join('\r\n') + '\r\n';
    transaction('schedules', fields.identity, raw[2], [fields.identity, fields.startDate, fields.uid, fields.stp, block]);
    schedule = null;
  }
  db.exec('BEGIN;');
  try {
    for await (const { text, line } of readLines(path, options)) {
      const type = text.slice(0, 2);
      if (['BS', 'ZZ'].includes(type)) finishSchedule();
      if (type === 'HD') {
        header = headerDetails(text, source.generationDate, source.feedMode);
        if (baseline?.header.referenceUsable && header.previousReference && header.previousReference !== baseline.header.currentReference) {
          throw failure('UPDATE_REFERENCE_MISMATCH', `Daily previous-file reference ${header.previousReference} does not match baseline ${baseline.header.currentReference}`);
        }
      } else if (['TI', 'TA', 'TD'].includes(type)) {
        const rank = { TI: 1, TA: 2, TD: 3 }[type];
        if (rank < order || (source.feedMode === 'full' && type !== 'TI')) throw new Error(`Misordered/unsupported ${type} record at ${line}`);
        order = rank;
        const tiploc = text.slice(2, 9).trim(), replacement = type === 'TA' ? text.slice(72, 79).trim() || tiploc : tiploc;
        if (!/^[A-Z0-9]{4,7}$/.test(tiploc) || !/^[A-Z0-9]{4,7}$/.test(replacement)) throw new Error('Malformed TIPLOC identity');
        if (replacement !== tiploc && statements.timing_locations.exists.get(replacement)) throw failure('UPDATE_TARGET_DUPLICATE', `Amended TIPLOC already exists: ${replacement}`);
        const raw = `TI${replacement.padEnd(7)}${text.slice(9, 72)}${' '.repeat(8)}`;
        transaction('timing_locations', tiploc, { TI: 'N', TA: 'R', TD: 'D' }[type], [replacement, raw]);
      } else if (type === 'AA') {
        if (order > 4) throw new Error(`Association after schedules at ${line}`);
        order = 4;
        const fields = associationIdentity(text), raw = `${text.slice(0, 2)}N${text.slice(3)}`;
        transaction('associations', fields.identity, text[2], [fields.identity, fields.startDate, fields.baseUid, fields.associatedUid, fields.stp, text[46], raw]);
      } else if (type === 'BS') {
        order = 5;
        schedule = { raw: text, fields: scheduleIdentity(text), records: [text] };
      } else if (['BX', 'LO', 'LI', 'LT', 'CR'].includes(type)) {
        if (!schedule) throw new Error(`Orphan ${type} record at ${line}`);
        const previous = schedule.records.at(-1).slice(0, 2);
        if (previous === 'LT' || (type === 'BX' && previous !== 'BS') || (type === 'LO' && previous !== 'BX')
          || (['LI', 'LT', 'CR'].includes(type) && !['LO', 'LI', 'CR'].includes(previous))) throw new Error(`Misordered ${type} record at ${line}`);
        schedule.records.push(text);
      } else if (type !== 'ZZ') throw new Error(`Unsupported main timetable record ${type}`);
    }
    db.exec('COMMIT;');
    return { header, operations };
  } catch (error) { db.exec('ROLLBACK;'); throw error; }
}

async function exportFull(db, prepared, header, directory, options) {
  await mkdir(directory);
  const prefix = `RJTTF${prepared.sequence}`;
  for (const type of AUXILIARIES) {
    options.signal?.throwIfAborted();
    await copyFile(prepared.members.find(member => member.type === type).path, join(directory, `${prefix}.${type}`));
  }
  const handle = await open(join(directory, `${prefix}.MCA`), 'wx', 0o600);
  try {
    let buffer = `${header.raw.slice(0, 46)}F${header.raw.slice(47)}\r\n`;
    async function flush() { options.signal?.throwIfAborted(); await handle.writeFile(buffer, 'latin1'); buffer = ''; }
    for (const [table, ordering] of [['timing_locations', 'tiploc'], ['associations', 'start_date,base_uid,associated_uid,identity'], ['schedules', 'start_date,uid,stp,identity']]) {
      for (const row of db.prepare(`SELECT raw FROM ${table} ORDER BY ${ordering}`).iterate()) {
        buffer += row.raw + (table === 'schedules' ? '' : '\r\n');
        if (buffer.length >= 1024 * 1024) await flush();
      }
    }
    buffer += 'ZZ'.padEnd(80) + '\r\n';
    await flush();
  } finally { await handle.close(); }
  const date = prepared.generationDate.split('-').reverse().join('/');
  const types = ['MCA', ...AUXILIARIES];
  await writeFile(join(directory, `${prefix}.DAT`), `/!! Content type: DAT\r\n/!! Sequence: ${prepared.sequence}\r\n/!! Generated: ${date}\r\n${types.map(type => `${prefix}.${type}`).join('\r\n')}\r\n/!! End of file (8 records) (${date})\r\n`, { mode: 0o600 });
}

async function buildDelivery(baselineDirectory, sourcePath, targetDirectory, options) {
  const target = resolve(targetDirectory);
  await mkdir(dirname(target), { recursive: true });
  const lockPath = `${target}.import.lock`, lock = await acquireOwnedLock(lockPath, { stagingTarget: target });
  let prepared, db, building;
  try {
    try { await lstat(target); throw failure('DELIVERY_TARGET_EXISTS', 'Canonical delivery target already exists; use a new immutable directory'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    options.signal?.throwIfAborted();
    prepared = await prepareSource(sourcePath, options);
    if (prepared.feedMode !== (baselineDirectory ? 'update' : 'full')) throw new Error(baselineDirectory ? 'Expected a daily CFA update package' : 'A complete monthly MCA package is required to bootstrap');
    const source = await inspectPreparedSource(prepared, options), baseline = baselineDirectory ? await readDeliveryMetadata(baselineDirectory) : null;
    nextDeliverySequence(prepared.sequence);
    if (baseline) {
      const expectedSequence = nextDeliverySequence(baseline.sequence);
      if (prepared.sequence !== expectedSequence) throw failure('UPDATE_GAP', `Missing timetable update chain: expected ${expectedSequence}, received ${prepared.sequence}`, {
        expectedSequence, actualSequence: prepared.sequence, missingCount: (Number(prepared.sequence) - Number(expectedSequence) + 999) % 999 });
      if (prepared.generationDate <= baseline.generationDate) throw failure('UPDATE_STALE', 'Daily timetable generation date must be later than its baseline');
    }
    building = await mkdtemp(`${target}.building-`);
    if (baseline) await copyFile(join(resolve(baselineDirectory), DATABASE_FILE), join(building, DATABASE_FILE));
    db = await database(join(building, DATABASE_FILE));
    db.exec('PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF; PRAGMA temp_store=MEMORY;');
    if (baseline) checkDatabase(db, baseline.counts);
    else db.exec(`CREATE TABLE timing_locations (tiploc TEXT PRIMARY KEY, raw TEXT NOT NULL);
      CREATE TABLE associations (identity TEXT PRIMARY KEY, start_date TEXT NOT NULL, base_uid TEXT NOT NULL, associated_uid TEXT NOT NULL, stp TEXT NOT NULL, diagram TEXT NOT NULL, raw TEXT NOT NULL);
      CREATE TABLE schedules (identity TEXT PRIMARY KEY, start_date TEXT NOT NULL, uid TEXT NOT NULL, stp TEXT NOT NULL, raw TEXT NOT NULL);`);
    const { header, operations } = await applyMain(db, prepared.members.find(member => ['MCA', 'CFA'].includes(member.type)).path, source, baseline, options);
    const inventory = checkDatabase(db);
    if (baseline) await exportFull(db, prepared, header, join(building, 'full'), options);
    else {
      // Keep an initial full package byte-identical: stable source references,
      // hashes and itinerary identities, with no unnecessary SQL reordering.
      await mkdir(join(building, 'full'));
      for (const member of prepared.members) {
        options.signal?.throwIfAborted();
        await copyFile(member.path, join(building, 'full', member.name));
      }
    }
    for (const member of prepared.members) {
      const current = await stat(member.path);
      if (current.size !== member.size || current.mtimeMs !== member.mtimeMs || current.ctimeMs !== member.ctimeMs) throw new Error(`Source changed during canonical import: ${member.name}`);
    }
    const canonicalHash = createHash('sha256').update(`${SCHEMA_VERSION}\0${baseline?.canonicalHash ?? ''}\0${source.contentHash}`).digest('hex');
    const metadata = { schemaVersion: SCHEMA_VERSION, sequence: source.sequence, generationDate: source.generationDate,
      contentHash: source.contentHash, canonicalHash, source, header, counts: inventory, operations,
      importedAt: new Date().toISOString(), baseline: baseline ? { sequence: baseline.sequence, generationDate: baseline.generationDate,
        contentHash: baseline.contentHash, canonicalHash: baseline.canonicalHash } : null };
    await writeFile(join(building, 'metadata.json'), `${JSON.stringify(metadata, null, 2)}\n`, { mode: 0o600 });
    db.close(); db = null;
    options.signal?.throwIfAborted();
    await rename(building, target);
    building = null;
    return { path: target, fullSourcePath: join(target, 'full'), metadata };
  } finally {
    db?.close();
    await prepared?.cleanup();
    if (building) await rm(building, { recursive: true, force: true });
    await lock.release();
  }
}

export function bootstrapDelivery(sourcePath, targetDirectory, options = {}) {
  return buildDelivery(null, sourcePath, targetDirectory, options);
}

export function applyDeliveryUpdate(baselineDirectory, sourcePath, targetDirectory, options = {}) {
  return buildDelivery(baselineDirectory, sourcePath, targetDirectory, options);
}
