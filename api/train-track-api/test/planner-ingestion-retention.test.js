import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { mkdtemp, mkdir, readFile, writeFile, copyFile, readdir, rm, stat, utimes } from 'node:fs/promises';
import { tmpdir, hostname } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { syncTimetable } from '../lib/planner/ingestion.js';
import { objectIdentity } from '../lib/planner/ingestion-source.js';
import { getActiveDataset } from '../lib/planner/repository.js';

const run = promisify(execFile);
const hash = value => createHash('sha256').update(Buffer.isBuffer(value) ? value : String(value)).digest('hex');
const timestamp = value => `2026-09-${String(value).padStart(2, '0')}T00:00:00.000Z`;
const remote = { kind: 'full', key: 'timetable_full.zip', etag: '"new-delivery"', size: 8,
  lastModified: timestamp(18), versionId: null };
const failure = () => Object.assign(new Error('controlled download failure'), { code: 'S3_UNAVAILABLE' });

async function json(path, value) { await writeFile(path, JSON.stringify(value)); }
async function missing(path) { await assert.rejects(stat(path), { code: 'ENOENT' }); }
async function present(path) { assert.ok(await stat(path)); }
async function setup(t) {
  const directory = await mkdtemp(join(tmpdir(), 'traintrack-retention-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const root = join(directory, 'data', 'deliveries');
  for (const name of ['snapshots', 'canonical', 'archives']) await mkdir(join(root, name), { recursive: true });
  const config = { enabled: true, configured: true, dataDirectory: join(directory, 'data'), datasetPath: null, intervalSeconds: 3600 };
  return { directory, root, config, source: { async head(kind) { return kind === 'full' ? remote : null; }, async download() { throw failure(); } } };
}

async function canonical(fixture, number, importedAt = timestamp(number)) {
  const canonicalHash = hash(`canonical-${number}`), path = join(fixture.root, 'canonical', hash(number));
  await mkdir(path);
  await json(join(path, 'metadata.json'), { schemaVersion: 1, canonicalHash, sequence: '001', generationDate: '2026-09-01', importedAt });
  await writeFile(join(path, 'canonical.sqlite'), 'lightweight retention fixture');
  return { path, canonicalHash };
}
async function snapshot(fixture, number, store, importedAt = timestamp(number), managed = true) {
  const path = join(fixture.root, 'snapshots', hash(number));
  await mkdir(path);
  await json(join(path, 'metadata.json'), { importedAt, source: { generationDate: '2026-09-01', sequence: '001' },
    delivery: { managed, canonicalPath: store.path, canonicalHash: store.canonicalHash, sequence: '001', baselineSequence: '001' } });
  return path;
}
async function archive(fixture, number, modifiedAt = timestamp(number)) {
  const name = number === 1 ? `full-${objectIdentity(remote)}.zip` : `update-${hash(number)}.zip`;
  const path = join(fixture.root, 'archives', name);
  await writeFile(path, 'zipbytes');
  await json(`${path}.json`, { sha256: hash(number) });
  await utimes(path, new Date(modifiedAt), new Date(modifiedAt));
  return path;
}

test('retention protects active/rollback linkage and manual data, keeps bounded newest stores, and cleans failed-run additions', async t => {
  const fixture = await setup(t), stores = [], snapshots = [], archives = [];
  for (let number = 1; number <= 9; number++) stores.push(await canonical(fixture, number));
  for (let number = 1; number <= 7; number++) {
    snapshots.push(await snapshot(fixture, number, stores[number - 1]));
    archives.push(await archive(fixture, number));
  }
  const outside = join(fixture.directory, 'manual-outside'); await mkdir(outside); await writeFile(join(outside, 'keep.txt'), 'manual data');
  const unmanaged = await snapshot(fixture, 20, { path: outside, canonicalHash: hash('outside') }, timestamp(1), false);
  const manualCanonical = join(fixture.root, 'canonical', 'manual-baseline'); await mkdir(manualCanonical);
  await json(join(manualCanonical, 'metadata.json'), { schemaVersion: 1, canonicalHash: hash('manual'), importedAt: timestamp(1) });
  const unownedCanonical = join(fixture.root, 'canonical', hash('unowned')); await mkdir(unownedCanonical);
  await json(join(unownedCanonical, 'metadata.json'), { schemaVersion: 7, importedAt: timestamp(1) });
  const notes = join(fixture.root, 'snapshots', 'manual-notes'); await mkdir(notes);
  const unreceipted = join(fixture.root, 'archives', `full-${hash('manual-archive')}.zip`); await writeFile(unreceipted, 'manual archive');
  const pointer = { version: 'active-version', path: snapshots[0], previousVersion: 'previous-version', previousPath: snapshots[1], activatedAt: timestamp(18) };
  await json(join(fixture.config.dataDirectory, 'active.json'), pointer);
  await json(join(fixture.config.dataDirectory, 'activation-history.json'), [...snapshots, unmanaged, outside].map((path, number) => ({ version: `version-${number}`, path })));
  let failedSnapshot, failedCanonical, failedArchive;
  fixture.source.download = async () => {
    // These appear after the initial cleanup, so only catch-path retention can remove them.
    failedCanonical = await canonical(fixture, 30, timestamp(1));
    failedSnapshot = await snapshot(fixture, 30, failedCanonical, timestamp(1));
    failedArchive = await archive(fixture, 30, timestamp(1));
    throw failure();
  };
  await assert.rejects(syncTimetable(fixture), { code: 'S3_UNAVAILABLE' });
  assert.deepEqual(await getActiveDataset(fixture.config.dataDirectory), pointer);
  for (const index of [0, 1, 4, 5, 6]) { await present(snapshots[index]); await present(stores[index].path); }
  for (const index of [2, 3]) { await missing(snapshots[index]); await missing(stores[index].path); }
  for (const index of [7, 8]) await present(stores[index].path); // Newest two canonical candidates, without snapshots.
  for (const index of [0, 3, 4, 5, 6]) await present(archives[index]); // Current remote plus four newest archives.
  for (const index of [1, 2]) { await missing(archives[index]); await missing(`${archives[index]}.json`); }
  for (const path of [failedSnapshot, failedCanonical.path, failedArchive, `${failedArchive}.json`]) await missing(path);
  for (const path of [outside, join(outside, 'keep.txt'), unmanaged, manualCanonical, unownedCanonical, notes, unreceipted]) await present(path);
  const history = JSON.parse(await readFile(join(fixture.config.dataDirectory, 'activation-history.json'), 'utf8'));
  assert.deepEqual(history.map(item => item.path), [...snapshots.filter((_path, index) => ![2, 3].includes(index)), unmanaged, outside]);
  const state = JSON.parse(await readFile(join(fixture.config.dataDirectory, 'ingestion-state.json'), 'utf8'));
  assert.equal(state.lastErrorCode, 'S3_UNAVAILABLE'); assert.equal(state.inProgress, false);
  await missing(join(fixture.config.dataDirectory, '.ingestion.lock')); await missing(join(fixture.config.dataDirectory, '.activation.lock'));
});

test('staging recovery removes only dead owned generated builds and private download partials', async t => {
  const fixture = await setup(t), deadPid = 2147483647, removed = [], preserved = [];
  for (const [kind, suffix] of [['canonical', 'Az19Qx'], ['snapshots', randomUUID()]]) {
    const target = join(fixture.root, kind, hash(kind));
    const lock = `${target}.import.lock`, building = `${target}.building-${suffix}`, manual = `${target}.building-manual_notes`;
    await json(lock, { pid: deadPid, hostname: hostname(), token: 'dead-owner' });
    await mkdir(building); await writeFile(join(building, 'incomplete.sqlite'), 'incomplete'); await mkdir(manual);
    removed.push(lock, building); preserved.push(manual);
  }
  for (const [number, owner] of [[1, { pid: process.pid, hostname: hostname() }], [2, { pid: deadPid, hostname: 'other-host' }]]) {
    const target = join(fixture.root, 'canonical', hash(`protected-${number}`));
    await json(`${target}.import.lock`, owner); await mkdir(`${target}.building-Az19Qx`);
    preserved.push(`${target}.import.lock`, `${target}.building-Az19Qx`);
  }
  const emptyLock = join(fixture.root, 'snapshots', `${hash('unknown')}.import.lock`); await writeFile(emptyLock, ''); preserved.push(emptyLock);
  const partial = join(fixture.root, 'archives', `full-${hash('partial')}.zip.partial-${randomUUID()}`); await writeFile(partial, 'incomplete'); removed.push(partial);
  for (const name of [`manual.zip.partial-${randomUUID()}`, `full-${hash('notes')}.zip.partial-manual_notes`, 'operator-notes.txt']) {
    const path = join(fixture.root, 'archives', name); await writeFile(path, 'manual'); preserved.push(path);
  }
  const progress = [];
  await assert.rejects(syncTimetable({ ...fixture, onProgress: item => progress.push(item) }), { code: 'S3_UNAVAILABLE' });
  for (const path of removed) await missing(path);
  for (const path of preserved) await present(path);
  assert.ok(progress.some(item => item.phase === 'recovery' && item.removedGeneratedPartialStores === 3));
});

test('retention does not evict a live activation owner or delete stores while activation is locked', async t => {
  const fixture = await setup(t), snapshots = [];
  for (let number = 1; number <= 6; number++) snapshots.push(await snapshot(fixture, number, await canonical(fixture, number)));
  const path = join(fixture.config.dataDirectory, '.activation.lock');
  await json(path, { pid: process.pid, hostname: hostname(), token: 'live-activation-owner' });
  const bytes = await readFile(path);
  await assert.rejects(syncTimetable(fixture), { code: 'S3_UNAVAILABLE' });
  assert.deepEqual(await readFile(path), bytes);
  for (const snapshotPath of snapshots) await present(snapshotPath);
});

function fixed(type, fields = {}, width = 80) {
  const row = Array(width).fill(' ');
  for (const [position, value] of Object.entries({ 1: type, ...fields })) for (let index = 0; index < value.length; index++) row[Number(position) - 1 + index] = value[index];
  return row.join('');
}
async function fullArchive(fixture) {
  const directory = join(fixture.directory, 'source'); await mkdir(directory);
  const records = [fixed('HD', { 23: '010926', 33: 'REF0001', 47: 'F' })];
  for (let number = 0; number < 2000; number++) records.push(
    fixed('BS', { 3: 'N', 4: `A${String(number).padStart(5, '0')}`, 10: '260901', 16: '261231', 22: '1111111', 30: 'P', 31: 'OO', 80: 'P' }),
    fixed('BX', { 12: 'SE', 14: 'Y' }), fixed('LO', { 3: 'ORIGIN', 11: '0700 ', 16: '0700', 30: 'TB' }), fixed('LT', { 3: 'DEST', 11: '0800 ', 16: '0800', 26: 'TF' }));
  records.push(fixed('ZZ'));
  const types = ['MCA', 'MSN', 'TSI', 'ALF', 'FLF', 'ZTR', 'REJ', 'SET'];
  const bodies = {
    MCA: records.join('\r\n') + '\r\n',
    MSN: [fixed('A', { 31: 'FILE-SPEC=05' }, 82), fixed('A', { 6: 'ORIGIN', 36: '2', 37: 'ORIGIN', 44: 'ORG', 50: 'ORG', 64: ' 4' }, 82),
      fixed('A', { 6: 'DESTINATION', 36: '2', 37: 'DEST', 44: 'DST', 50: 'DST', 64: ' 5' }, 82), 'End of File', '/!! End of file (4 records)'].join('\n'),
    TSI: '', ALF: '', FLF: 'END\n/!! End of file (1 records)', ZTR: `${fixed('HD')}\n${fixed('ZZ')}\n`,
    REJ: 'Start of rejected trains file\nEnd of rejected trains file', SET: 'UCFCATE\n/!! End of file (1 records)',
    DAT: `/!! Sequence: 001\n/!! Generated: 01/09/2026\n${types.map(type => `RJTTF001.${type}`).join('\n')}\n/!! End of file (8 records)`
  };
  for (const [type, body] of Object.entries(bodies)) await writeFile(join(directory, `RJTTF001.${type}`), body);
  const path = join(fixture.directory, 'full.zip'); await run('zip', ['-q', path, ...await readdir(directory)], { cwd: directory });
  return path;
}

test('cancelling during compact import reports CANCELLED and cleans staging without activating a partial snapshot', async t => {
  const fixture = await setup(t), path = await fullArchive(fixture), bytes = await readFile(path);
  const object = { ...remote, size: bytes.length, etag: `"${hash(bytes)}"` }, controller = new AbortController();
  const source = { async head(kind) { return kind === 'full' ? object : null; }, async download(_object, target) {
    await copyFile(path, target); return { path: target, bytes: bytes.length, sha256: hash(bytes) };
  } };
  let cancelled = false;
  await assert.rejects(syncTimetable({ ...fixture, source, signal: controller.signal, onProgress(progress) {
    if (progress.phase === 'import') { cancelled = true; controller.abort(); }
  } }), { code: 'CANCELLED' });
  assert.equal(cancelled, true); assert.equal(await getActiveDataset(fixture.config.dataDirectory), null);
  assert.deepEqual(await readdir(join(fixture.root, 'snapshots')), []);
  const state = JSON.parse(await readFile(join(fixture.config.dataDirectory, 'ingestion-state.json'), 'utf8'));
  assert.equal(state.lastErrorCode, 'CANCELLED'); assert.equal(state.inProgress, false); assert.equal(state.lastResult, 'error');
  await missing(join(fixture.config.dataDirectory, '.ingestion.lock')); await missing(join(fixture.config.dataDirectory, '.activation.lock'));
});
