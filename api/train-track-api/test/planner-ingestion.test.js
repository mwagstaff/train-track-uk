import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, readdir, copyFile, stat } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { tmpdir, hostname } from 'node:os';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { performance } from 'node:perf_hooks';
import { syncTimetable, acquireIngestionLock } from '../lib/planner/ingestion.js';
import { objectIdentity } from '../lib/planner/ingestion-source.js';
import { getActiveDataset, openDataset, importFullSnapshot, activateDataset } from '../lib/planner/repository.js';
import { findJourneys } from '../lib/planner/router.js';
import { inspectSource } from '../lib/planner/source.js';

const run = promisify(execFile);
function fixed(type, fields = {}, length = 80) {
  const row = Array(length).fill(' ');
  for (const [position, value] of Object.entries({ 1: type, ...fields })) for (let i = 0; i < value.length; i++) row[Number(position) - 1 + i] = value[i];
  return row.join('');
}

function schedule(uid = 'A00001', { transaction = 'N', departure = '0700', arrival = '0800', stp = 'P' } = {}) {
  const raw = fixed('BS', { 3: transaction, 4: uid, 10: '260901', 16: '261231', 22: '1111111', 30: 'P', 31: 'OO', 80: stp });
  return transaction === 'D' || stp === 'C' ? [raw] : [raw, fixed('BX', { 12: 'SE', 14: 'Y' }),
    fixed('LO', { 3: 'ORIGIN', 11: `${departure} `, 16: departure, 30: 'TB' }), fixed('LT', { 3: 'DEST', 11: `${arrival} `, 16: arrival, 26: 'TF' })];
}

async function archive(root, name, { mode = 'full', sequence = '001', date = '2026-09-01', records = [...schedule(), ...schedule('B00001')], previousReference = '', currentReference = 'REF0001', truncate = false } = {}) {
  const directory = join(root, name); await mkdir(directory);
  const prefix = `RJTT${mode === 'full' ? 'F' : 'C'}${sequence}`, main = mode === 'full' ? 'MCA' : 'CFA';
  const members = [`${prefix}.${main}`, ...['MSN', 'TSI', 'ALF', 'FLF', 'ZTR', 'REJ', 'SET'].map(type => `RJTTF${sequence}.${type}`)];
  const displayDate = date.split('-').reverse().join('/'), hdDate = displayDate.replaceAll('/', '').slice(0, 4) + date.slice(2, 4);
  const body = {
    [main]: [fixed('HD', { 23: hdDate, 33: currentReference, 40: previousReference, 47: mode === 'full' ? 'F' : 'U' }), ...records, ...(truncate ? [] : [fixed('ZZ')])].join('\r\n') + '\r\n',
    MSN: [fixed('A', { 31: 'FILE-SPEC=05' }, 82), fixed('A', { 6: 'ORIGIN', 36: '2', 37: 'ORIGIN', 44: 'ORG', 50: 'ORG', 64: ' 4' }, 82),
      fixed('A', { 6: 'DESTINATION', 36: '2', 37: 'DEST', 44: 'DST', 50: 'DST', 64: ' 5' }, 82), 'End of File', '/!! End of file (4 records)'].join('\n'),
    TSI: '', ALF: '', FLF: 'END\n/!! End of file (1 records)', ZTR: `${fixed('HD')}\n${fixed('ZZ')}\n`,
    REJ: 'Start of rejected trains file\nEnd of rejected trains file\n', SET: 'UCFCATE\n/!! End of file (1 records)',
    DAT: `/!! Sequence: ${sequence}\n/!! Generated: ${displayDate}\n${members.join('\n')}\n/!! End of file (8 records)`,
  };
  for (const [type, contents] of Object.entries(body)) await writeFile(join(directory, `${[main, 'DAT'].includes(type) ? prefix : `RJTTF${sequence}`}.${type}`), contents);
  const path = join(root, `${name}.zip`);
  await run('zip', ['-q', path, ...await readdir(directory)], { cwd: directory });
  return path;
}

class FakeSource {
  constructor() { this.objects = {}; this.heads = []; this.downloads = []; }
  async set(kind, path, { etag, lastModified = '2026-09-18T14:00:00.000Z' } = {}) {
    if (!path) { this.objects[kind] = null; return; }
    const sha256 = createHash('sha256').update(await readFile(path)).digest('hex');
    this.objects[kind] = { path, sha256, object: { kind, key: `timetable_${kind}.zip`, etag: etag ?? `"${sha256}"`,
      size: (await stat(path)).size, lastModified, versionId: null } };
  }
  async head(kind) { this.heads.push(kind); return this.objects[kind]?.object ?? null; }
  async download(object, targetPath) {
    const remote = this.objects[object.kind];
    assert.equal(objectIdentity(object), objectIdentity(remote.object));
    this.downloads.push(object.kind);
    await mkdir(dirname(targetPath), { recursive: true }); await copyFile(remote.path, targetPath);
    return { path: targetPath, bytes: object.size, sha256: remote.sha256 };
  }
}

async function setup(t, fullOptions) {
  const root = await mkdtemp(join(tmpdir(), 'traintrack-ingestion-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const dataDirectory = join(root, 'data'), source = new FakeSource();
  const full = await archive(root, 'full', fullOptions); await source.set('full', full);
  const config = { enabled: true, configured: true, dataDirectory, datasetPath: null, intervalSeconds: 3600, timeoutMs: 900000 };
  const sync = options => syncTimetable({ config, source, ...options });
  const state = async () => JSON.parse(await readFile(join(dataDirectory, 'ingestion-state.json'), 'utf8'));
  const active = () => getActiveDataset(dataDirectory);
  return { root, source, config, sync, state, active, full };
}

async function metadata(pointer) { return JSON.parse(await readFile(join(pointer.path, 'metadata.json'), 'utf8')); }
async function services(pointer, date = '2026-09-02') {
  const repository = await openDataset(pointer.path);
  try { return repository.resolveServices(date).services; } finally { repository.close(); }
}

test('full delivery activates compact schema2 with authoritative canonical linkage; unchanged checks are HEAD-only', async t => {
  const fixture = await setup(t), first = await fixture.sync(), pointer = await fixture.active(), imported = await metadata(pointer);
  assert.equal(first.result, 'activated'); assert.equal(first.activated, true); assert.equal(first.sequence, '001');
  assert.equal(imported.schemaVersion, 2); assert.equal(imported.delivery.sequence, '001');
  assert.equal(imported.delivery.baselineSequence, '001'); assert.equal(imported.delivery.managed, true);
  assert.equal(imported.delivery.remote.full.etag, fixture.source.objects.full.object.etag);
  assert.equal((await readFile(join(imported.delivery.canonicalPath, 'metadata.json'), 'utf8')).includes(imported.delivery.canonicalHash), true);
  const downloads = fixture.source.downloads.length, second = await fixture.sync();
  assert.equal(second.result, 'unchanged'); assert.equal(second.downloadBytes, 0);
  assert.equal(fixture.source.downloads.length, downloads);
  assert.deepEqual(fixture.source.heads, ['full', 'update', 'full', 'update']);
  assert.deepEqual(await fixture.active(), pointer);
});

test('contiguous daily N/R/D changes reach routing and preserve monthly baseline metadata', async t => {
  const fixture = await setup(t); await fixture.sync();
  const daily = await archive(fixture.root, 'daily', { mode: 'update', sequence: '002', date: '2026-09-02', currentReference: 'REF0002', previousReference: 'REF0001', records: [
    ...schedule('A00001', { transaction: 'R', departure: '0715' }), ...schedule('B00001', { transaction: 'D' }), ...schedule('C00001', { departure: '0730' })] });
  await fixture.source.set('update', daily);
  const result = await fixture.sync(), pointer = await fixture.active(), imported = await metadata(pointer), running = await services(pointer);
  assert.equal(result.result, 'activated'); assert.equal(result.sequence, '002'); assert.equal(result.baselineSequence, '001');
  assert.equal(imported.source.generationDate, '2026-09-02'); assert.equal(imported.delivery.sequence, '002');
  assert.equal(imported.source.sequence, '002'); assert.equal(imported.source.feedMode, 'full');
  const canonical = JSON.parse(await readFile(join(imported.delivery.canonicalPath, 'metadata.json'), 'utf8'));
  assert.equal(canonical.source.feedMode, 'update'); assert.equal(canonical.source.generationDate, '2026-09-02');
  assert.deepEqual(running.map(service => service.uid).sort(), ['A00001', 'C00001']);
  assert.equal(new Date(running.find(service => service.uid === 'A00001').calls[0].departure).toISOString(), '2026-09-02T06:15:00.000Z');
  const repository = await openDataset(pointer.path);
  try {
    const network = { services: running, stations: new Map(repository.allStations.map(station => [station.crs, station])), rules: repository.rules };
    const journeys = findJourneys({ origin: 'ORG', destination: 'DST', time: '2026-09-02T06:00:00.000Z', timeType: 'departAfter', maxChanges: 0, windowMinutes: 120, limit: 10 }, network).journeys;
    assert.ok(journeys.length > 0);
    assert.equal(journeys[0].legs[0].serviceId, running.find(service => service.uid === 'C00001').id);
  } finally { repository.close(); }
  const downloads = fixture.source.downloads.length;
  assert.equal((await fixture.sync()).result, 'unchanged'); assert.equal(fixture.source.downloads.length, downloads);
});

test('missing daily sequences preserve active publication date and record explicit pending gap', async t => {
  const fixture = await setup(t); await fixture.sync();
  const pointer = await fixture.active();
  const fourth = await archive(fixture.root, 'fourth', { mode: 'update', sequence: '004', date: '2026-09-04', records: [] });
  await fixture.source.set('update', fourth);
  assert.deepEqual((await fixture.sync()).pendingGap, { expectedSequence: '002', actualSequence: '004', missingCount: 2 });
  assert.deepEqual(await fixture.active(), pointer);
  const gap = await archive(fixture.root, 'gap', { mode: 'update', sequence: '024', date: '2026-09-24', records: [] });
  await fixture.source.set('update', gap);
  const result = await fixture.sync(), state = await fixture.state();
  assert.equal(result.result, 'gap'); assert.equal(result.activated, false);
  assert.deepEqual(result.pendingGap, { expectedSequence: '002', actualSequence: '024', missingCount: 22 });
  assert.equal(state.lastErrorCode, 'UPDATE_GAP'); assert.deepEqual(state.pendingGap, result.pendingGap);
  assert.deepEqual(await fixture.active(), pointer); assert.equal((await metadata(pointer)).source.generationDate, '2026-09-01');
  const downloads = fixture.source.downloads.length;
  assert.equal((await fixture.sync()).result, 'gap'); assert.equal(fixture.source.downloads.length, downloads);
});

test('corrupt or stale observational state recovers from active snapshot canonical metadata, not a stale sequence', async t => {
  const fixture = await setup(t); await fixture.sync();
  const daily = await archive(fixture.root, 'daily', { mode: 'update', sequence: '002', date: '2026-09-02', previousReference: 'REF0001', currentReference: 'REF0002', records: [] });
  await fixture.source.set('update', daily); await fixture.sync();
  const pointer = await fixture.active(), downloads = fixture.source.downloads.length;
  await writeFile(join(fixture.config.dataDirectory, 'ingestion-state.json'), '{interrupted-write');
  assert.equal((await fixture.sync()).result, 'unchanged');
  assert.equal((await fixture.state()).active.currentSequence, '002');
  await writeFile(join(fixture.config.dataDirectory, 'ingestion-state.json'), JSON.stringify({ schemaVersion: 1, active: { currentSequence: '999', metadata: { delivery: { canonicalPath: '/invalid' } } }, inProgress: true }));
  assert.equal((await fixture.sync()).result, 'unchanged');
  assert.deepEqual(await fixture.active(), pointer); assert.equal(fixture.source.downloads.length, downloads);
});

test('dry-run validates candidates without altering active pointer, history or ingestion state, including first boot', async t => {
  const fixture = await setup(t);
  const initial = await fixture.sync({ dryRun: true });
  assert.equal(initial.dryRun, true); assert.equal(initial.activated, false); assert.equal(await fixture.active(), null);
  await assert.rejects(readFile(join(fixture.config.dataDirectory, 'ingestion-state.json')), { code: 'ENOENT' });
  await fixture.sync();
  const pointer = await fixture.active(), previousState = await readFile(join(fixture.config.dataDirectory, 'ingestion-state.json')),
    history = await readFile(join(fixture.config.dataDirectory, 'activation-history.json'));
  const daily = await archive(fixture.root, 'daily', { mode: 'update', sequence: '002', date: '2026-09-02', previousReference: 'REF0001', records: [] });
  await fixture.source.set('update', daily);
  const result = await fixture.sync({ dryRun: true });
  assert.equal(result.activated, false); assert.equal(result.sequence, '002'); assert.ok(result.candidateVersion);
  assert.deepEqual(await fixture.active(), pointer);
  assert.deepEqual(await readFile(join(fixture.config.dataDirectory, 'ingestion-state.json')), previousState);
  assert.deepEqual(await readFile(join(fixture.config.dataDirectory, 'activation-history.json')), history);
});

test('live/unknown ingestion owners are protected; a dead local owner is recovered', async t => {
  const fixture = await setup(t), release = await acquireIngestionLock(fixture.config.dataDirectory);
  await assert.rejects(fixture.sync(), { code: 'LOCKED' });
  assert.equal(fixture.source.heads.length, 0);
  await release();
  const lock = join(fixture.config.dataDirectory, '.ingestion.lock');
  await writeFile(lock, JSON.stringify({ pid: 99999999, hostname: 'another-host', startedAt: '2000-01-01T00:00:00Z' }));
  await assert.rejects(fixture.sync(), { code: 'LOCKED' });
  await writeFile(lock, JSON.stringify({ pid: 99999999, hostname: hostname(), startedAt: '2000-01-01T00:00:00Z' }));
  assert.equal((await fixture.sync()).result, 'activated');
  await assert.rejects(readFile(lock), { code: 'ENOENT' });
});

test('pinned dataset configuration blocks managed activation before any remote calls', async t => {
  const fixture = await setup(t); await fixture.sync();
  const pointer = await fixture.active(), headCalls = fixture.source.heads.length;
  await assert.rejects(fixture.sync({ config: { ...fixture.config, datasetPath: pointer.path } }), { code: 'CONFIG_INVALID' });
  assert.equal(fixture.source.heads.length, headCalls); assert.deepEqual(await fixture.active(), pointer);
  assert.equal((await fixture.state()).lastErrorCode, 'CONFIG_INVALID');
});

test('malformed daily, missing update targets and failed compact validation cannot change the active pointer', async t => {
  const fixture = await setup(t); await fixture.sync();
  const pointer = await fixture.active();
  const malformed = await archive(fixture.root, 'malformed', { mode: 'update', sequence: '002', date: '2026-09-02', records: [], truncate: true });
  await fixture.source.set('update', malformed);
  await assert.rejects(fixture.sync(), { code: 'INVALID_DELIVERY' });
  assert.deepEqual(await fixture.active(), pointer);
  const missing = await archive(fixture.root, 'missing', { mode: 'update', sequence: '002', date: '2026-09-02', records: schedule('M00001', { transaction: 'R' }) });
  await fixture.source.set('update', missing);
  await assert.rejects(fixture.sync(), { code: 'UPDATE_TARGET_MISSING' });
  assert.deepEqual(await fixture.active(), pointer);
  const invalidFull = await archive(fixture.root, 'invalid-full', { sequence: '002', date: '2026-09-02', records: [] });
  await fixture.source.set('full', invalidFull); await fixture.source.set('update', null);
  await assert.rejects(fixture.sync(), { code: 'VALIDATION_FAILED' });
  assert.deepEqual(await fixture.active(), pointer);
  const state = await fixture.state();
  assert.equal(state.inProgress, false); assert.equal(state.lastErrorCode, 'VALIDATION_FAILED');
});

test('fresh S3 timestamps and changed ETags on older source bytes cannot regress an effective daily snapshot', async t => {
  const fixture = await setup(t); await fixture.sync();
  const daily = await archive(fixture.root, 'daily', { mode: 'update', sequence: '002', date: '2026-09-02', previousReference: 'REF0001', records: [] });
  await fixture.source.set('update', daily); await fixture.sync();
  const pointer = await fixture.active();
  const oldFull = await archive(fixture.root, 'old-full', { sequence: '999', date: '2026-08-31' });
  await fixture.source.set('full', oldFull, { etag: '"new-upload-old-full"', lastModified: '2026-09-19T14:00:00.000Z' });
  const oldDaily = await archive(fixture.root, 'old-daily', { mode: 'update', sequence: '001', date: '2026-09-01', records: [] });
  await fixture.source.set('update', oldDaily, { etag: '"new-upload-old-update"', lastModified: '2026-09-19T14:00:00.000Z' });
  const result = await fixture.sync();
  assert.equal(result.result, 'unchanged'); assert.equal(result.sequence, '002');
  assert.deepEqual(await fixture.active(), pointer); assert.equal((await metadata(pointer)).source.generationDate, '2026-09-02');
});

async function managedTargets(fixture) {
  const root = join(fixture.config.dataDirectory, 'deliveries');
  const canonicalName = (await readdir(join(root, 'canonical'))).find(name => /^[a-f0-9]{64}$/.test(name));
  const snapshotName = (await readdir(join(root, 'snapshots'))).find(name => /^[a-f0-9]{64}$/.test(name));
  return { canonical: join(root, 'canonical', canonicalName), snapshot: join(root, 'snapshots', snapshotName) };
}

async function staleLock(path, pid = 99999999) {
  await writeFile(path, JSON.stringify({ pid, hostname: hostname(), startedAt: '2000-01-01T00:00:00Z', token: 'old-lock-token' }));
}

test('dead snapshot import lock is recovered and only matching stale UUID staging is cleaned', async t => {
  const fixture = await setup(t); await fixture.sync({ dryRun: true });
  const target = (await managedTargets(fixture)).snapshot;
  await rm(target, { recursive: true });
  await staleLock(`${target}.import.lock`);
  const stale = `${target}.building-01234567-0123-0123-0123-0123456789ab`, unrelated = `${target}.building-manual_notes`;
  await mkdir(stale); await writeFile(join(stale, 'partial.sqlite'), 'incomplete'); await mkdir(unrelated);
  assert.equal((await fixture.sync()).result, 'activated');
  await assert.rejects(stat(stale), { code: 'ENOENT' }); await assert.rejects(stat(`${target}.import.lock`), { code: 'ENOENT' });
  assert.equal((await stat(unrelated)).isDirectory(), true);
});

test('dead canonical import lock cleans actual six-alphanumeric mkdtemp staging suffixes before rebuilding', async t => {
  const fixture = await setup(t); await fixture.sync({ dryRun: true });
  const targets = await managedTargets(fixture);
  await rm(targets.snapshot, { recursive: true }); await rm(targets.canonical, { recursive: true });
  await staleLock(`${targets.canonical}.import.lock`);
  const stale = `${targets.canonical}.building-Az19Qx`, unrelated = `${targets.canonical}.building-manual_notes`;
  await mkdir(stale); await writeFile(join(stale, 'canonical.sqlite'), 'incomplete'); await mkdir(unrelated);
  assert.equal((await fixture.sync()).result, 'activated');
  await assert.rejects(stat(stale), { code: 'ENOENT' }); await assert.rejects(stat(`${targets.canonical}.import.lock`), { code: 'ENOENT' });
  assert.equal((await stat(unrelated)).isDirectory(), true);
});

test('dead activation lock recovers, while old live activation/import owners are never evicted', async t => {
  const fixture = await setup(t); await fixture.sync();
  const daily = await archive(fixture.root, 'daily', { mode: 'update', sequence: '002', date: '2026-09-02', previousReference: 'REF0001', currentReference: 'REF0002', records: [] });
  await fixture.source.set('update', daily);
  const activation = join(fixture.config.dataDirectory, '.activation.lock');
  await staleLock(activation);
  assert.equal((await fixture.sync()).result, 'activated');
  assert.equal((await metadata(await fixture.active())).delivery.sequence, '002');
  await assert.rejects(stat(activation), { code: 'ENOENT' });
  const pointer = await fixture.active();
  const third = await archive(fixture.root, 'third', { mode: 'update', sequence: '003', date: '2026-09-03', previousReference: 'REF0002', currentReference: 'REF0003', records: [] });
  await fixture.source.set('update', third); await staleLock(activation, process.pid);
  const liveOwner = await readFile(activation);
  await assert.rejects(fixture.sync(), { code: 'ACTIVATION_BLOCKED' });
  assert.deepEqual(await fixture.active(), pointer); assert.deepEqual(await readFile(activation), liveOwner);
  await rm(activation);
  const other = await setup(t); await other.sync({ dryRun: true });
  const snapshot = (await managedTargets(other)).snapshot, importLock = `${snapshot}.import.lock`;
  await staleLock(importLock, process.pid); const liveImport = await readFile(importLock);
  await assert.rejects(other.sync(), { code: 'VALIDATION_FAILED' });
  assert.equal(await other.active(), null); assert.deepEqual(await readFile(importLock), liveImport);
});

test('concurrent stale ingestion-lock reclamation admits exactly one owner without evicting its live lock', async t => {
  const fixture = await setup(t); await mkdir(fixture.config.dataDirectory);
  const lock = join(fixture.config.dataDirectory, '.ingestion.lock'); await staleLock(lock);
  const attempts = await Promise.allSettled([acquireIngestionLock(fixture.config.dataDirectory), acquireIngestionLock(fixture.config.dataDirectory)]);
  const fulfilled = attempts.filter(result => result.status === 'fulfilled'), rejected = attempts.filter(result => result.status === 'rejected');
  assert.equal(fulfilled.length, 1); assert.equal(rejected.length, 1); assert.equal(rejected[0].reason.code, 'LOCKED');
  const winner = JSON.parse(await readFile(lock, 'utf8'));
  assert.equal(winner.pid, process.pid); assert.equal(winner.hostname, hostname()); assert.notEqual(winner.token, 'old-lock-token');
  await assert.rejects(acquireIngestionLock(fixture.config.dataDirectory), { code: 'LOCKED' });
  await fulfilled[0].value(); await assert.rejects(stat(lock), { code: 'ENOENT' });
});

test('an operator activation during download blocks stale candidate CAS and preserves the new pointer', async t => {
  const fixture = await setup(t); await fixture.sync();
  const initial = await fixture.active();
  const operatorArchive = await archive(fixture.root, 'operator-full', { sequence: '003', date: '2026-09-03', records: [...schedule('A00001', { departure: '0710' }), ...schedule('B00001', { departure: '0720' })] });
  const operatorSnapshot = await importFullSnapshot(operatorArchive, join(fixture.root, 'operator-snapshot'));
  const daily = await archive(fixture.root, 'daily', { mode: 'update', sequence: '002', date: '2026-09-02', previousReference: 'REF0001', records: [] });
  await fixture.source.set('update', daily);
  const originalDownload = fixture.source.download.bind(fixture.source);
  let switched;
  fixture.source.download = async (...args) => {
    const result = await originalDownload(...args);
    if (args[0].kind === 'update') switched = await activateDataset(operatorSnapshot.path, fixture.config.dataDirectory);
    return result;
  };
  await assert.rejects(fixture.sync(), { code: 'ACTIVATION_BLOCKED' });
  assert.ok(switched); assert.notEqual(switched.version, initial.version);
  assert.deepEqual(await fixture.active(), switched);
  assert.equal((await fixture.state()).active.version, switched.version);
  assert.equal((await fixture.state()).lastErrorCode, 'ACTIVATION_BLOCKED');
});

const REAL_FULL_SOURCE = process.env.PLANNER_INGESTION_FULL_SOURCE;
const REAL_UPDATE_SOURCE = process.env.PLANNER_INGESTION_UPDATE_SOURCE;

async function acceptanceArchive(sourcePath, root, kind) {
  if (!(await stat(sourcePath)).isDirectory()) return sourcePath;
  const path = join(root, `${kind}-acceptance.zip`), members = await readdir(sourcePath);
  await run('zip', ['-jq', path, ...members.map(name => join(sourcePath, name))]);
  return path;
}

test('opt-in real full939/daily962 ingestion acceptance remains isolated, compact and gap-safe', {
  skip: !REAL_FULL_SOURCE || !REAL_UPDATE_SOURCE ? 'Set PLANNER_INGESTION_FULL_SOURCE and PLANNER_INGESTION_UPDATE_SOURCE to run national-corpus acceptance' : false,
  timeout: 300000,
}, async t => {
  const started = performance.now(), root = await mkdtemp(join(tmpdir(), 'traintrack-real-ingestion-acceptance-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const inventory = await inspectSource(REAL_FULL_SOURCE), dailyInventory = await inspectSource(REAL_UPDATE_SOURCE);
  assert.equal(inventory.sequence, '939'); assert.equal(inventory.generationDate, '2026-08-25');
  assert.equal(dailyInventory.sequence, '962'); assert.equal(dailyInventory.generationDate, '2026-09-17');
  const source = new FakeSource();
  await source.set('full', await acceptanceArchive(REAL_FULL_SOURCE, root, 'full'));
  await source.set('update', await acceptanceArchive(REAL_UPDATE_SOURCE, root, 'update'));
  const config = { enabled: true, configured: true, dataDirectory: join(root, 'data'), datasetPath: null, intervalSeconds: 3600, timeoutMs: 900000 };
  const result = await syncTimetable({ config, source }), pointer = await getActiveDataset(config.dataDirectory), imported = await metadata(pointer);
  assert.equal(result.result, 'gap'); assert.equal(result.activated, true); assert.equal(result.sequence, '939');
  assert.deepEqual(result.pendingGap, { expectedSequence: '940', actualSequence: '962', missingCount: 22 });
  assert.equal(imported.schemaVersion, 2); assert.equal(imported.source.sequence, '939');
  assert.equal(imported.source.generationDate, '2026-08-25'); assert.equal(imported.delivery.sequence, '939');
  const mains = inventory.members.filter(member => ['MCA', 'ZTR'].includes(member.type));
  assert.equal(imported.counts.schedules, mains.reduce((sum, member) => sum + (member.counts.BS ?? 0), 0));
  assert.equal(imported.counts.associations, mains.reduce((sum, member) => sum + (member.counts.AA ?? 0), 0));
  assert.equal(imported.counts.calls, mains.reduce((sum, member) => sum + (member.counts.LO ?? 0) + (member.counts.LI ?? 0) + (member.counts.LT ?? 0), 0));
  assert.equal(imported.counts.stationDefinitions, inventory.members.find(member => member.type === 'MSN').counts.A);
  assert.ok(imported.counts.routingCalls < imported.counts.calls);
  const validation = JSON.parse(await readFile(join(pointer.path, 'validation.json'), 'utf8'));
  assert.equal(validation.valid, true); assert.deepEqual(validation.counts, imported.counts);
  const downloads = source.downloads.length, repeat = await syncTimetable({ config, source });
  assert.equal(repeat.result, 'gap'); assert.equal(repeat.activated, false); assert.equal(repeat.downloadBytes, 0);
  assert.equal(source.downloads.length, downloads); assert.deepEqual(await getActiveDataset(config.dataDirectory), pointer);
  t.diagnostic(JSON.stringify({ totalElapsedMs: Math.round(performance.now() - started), syncElapsedMs: result.durationMs,
    repeatElapsedMs: repeat.durationMs, peakRssMiB: Math.round(process.resourceUsage().maxRSS / 1024),
    heapUsedMiB: Math.round(process.memoryUsage().heapUsed / 1024 ** 2), compactDatabaseBytes: validation.databaseBytes,
    schedules: imported.counts.schedules, routingCalls: imported.counts.routingCalls, pendingGap: result.pendingGap }));
});
