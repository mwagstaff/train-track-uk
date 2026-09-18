import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, readdir } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { bootstrapDelivery, applyDeliveryUpdate, readDeliveryMetadata, nextDeliverySequence } from '../lib/planner/delivery-store.js';
import { inspectSource } from '../lib/planner/source.js';
import { importFullSnapshot, openDataset } from '../lib/planner/repository.js';

function fixed(type, fields = {}, length = 80) {
  const row = Array(length).fill(' ');
  for (const [position, value] of Object.entries({ 1: type, ...fields })) for (let i = 0; i < value.length; i++) row[Number(position) - 1 + i] = value[i];
  return row.join('');
}

function schedule({ uid = 'A00001', transaction = 'N', start = '260901', stp = 'P', departure = '0700', intermediate = [] } = {}) {
  const raw = fixed('BS', { 3: transaction, 4: uid, 10: start, 16: '261231', 22: '1111111', 30: 'P', 31: 'OO', 80: stp });
  if (transaction === 'D' || stp === 'C') return [raw];
  return [raw, fixed('BX', { 12: 'SE', 14: 'Y' }), fixed('LO', { 3: 'ORIGIN', 11: `${departure} `, 16: departure, 30: 'TB' }),
    ...intermediate, fixed('LT', { 3: 'DEST', 11: '0800 ', 16: '0800', 26: 'TF' })];
}

function association(transaction = 'N', stp = 'P', changes = {}) {
  return fixed('AA', { 3: transaction, 4: 'A00001', 10: 'B00001', 16: '260901', 22: '261231', 28: '1111111', 35: 'JJ', 37: 'S', 38: 'ORIGIN', 47: 'T', 48: 'P', 80: stp, ...changes });
}

async function fixture(directory, { mode = 'full', sequence = '001', date = '2026-09-01', records = schedule(), currentReference = 'REF0001', previousReference = '', headerDate = date, auxiliaryMarker = '', middleStation = false, ztrRecords = [] } = {}) {
  await mkdir(directory, { recursive: true });
  const prefix = `RJTT${mode === 'full' ? 'F' : 'C'}${sequence}`, main = mode === 'full' ? 'MCA' : 'CFA';
  const names = [`${prefix}.${main}`, ...['MSN', 'TSI', 'ALF', 'FLF', 'ZTR', 'REJ', 'SET'].map(type => `RJTTF${sequence}.${type}`)];
  const displayDate = date.split('-').reverse().join('/'), hdDate = headerDate.split('-').reverse().join('').slice(0, 4) + headerDate.slice(2, 4);
  const body = {
    [main]: [fixed('HD', { 23: hdDate, 33: currentReference, 40: previousReference, 47: mode === 'full' ? 'F' : 'U' }), ...records, fixed('ZZ')].join('\r\n') + '\r\n',
    MSN: [fixed('A', { 31: 'FILE-SPEC=05' }, 82),
      fixed('A', { 6: 'ORIGIN STATION', 36: '2', 37: 'ORIGIN', 44: 'ORG', 50: 'ORG', 64: ' 4' }, 82),
      fixed('A', { 6: 'DESTINATION', 36: '2', 37: 'DEST', 44: 'DST', 50: 'DST', 64: ' 5' }, 82),
      ...(middleStation ? [fixed('A', { 6: 'MIDDLE', 36: '2', 37: 'MIDDLE', 44: 'MID', 50: 'MID', 64: ' 5' }, 82)] : []),
      'End of File', `/!! End of file (${middleStation ? 5 : 4} records)`].join('\n'),
    TSI: `DST,SE,SN,6,\n/${auxiliaryMarker}\n`, ALF: `M=WALK,O=ORG,D=DST,T=7,S=0001,E=2359,P=4,R=1111111\n/${auxiliaryMarker}\n`,
    FLF: `END\n/!! End of file (1 records)\n/${auxiliaryMarker}`, ZTR: [fixed('HD'), ...ztrRecords, fixed('ZZ')].join('\n') + '\n',
    REJ: 'Start of rejected trains file\nEnd of rejected trains file\n', SET: `UCFCATE\n/!! End of file (1 records)\n/${auxiliaryMarker}`,
    DAT: `/!! Sequence: ${sequence}\n/!! Generated: ${displayDate}\n${names.join('\n')}\n/!! End of file (8 records)`,
  };
  for (const [type, value] of Object.entries(body)) await writeFile(join(directory, `${['DAT', main].includes(type) ? prefix : `RJTTF${sequence}`}.${type}`), value);
  return directory;
}

async function temporary(t) {
  const root = await mkdtemp(join(tmpdir(), 'traintrack-canonical-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  return root;
}

function rawRows(directory, table) {
  const db = new DatabaseSync(join(directory, 'canonical.sqlite'), { readOnly: true });
  try { return db.prepare(`SELECT raw FROM ${table} ORDER BY raw`).all().map(row => row.raw); }
  finally { db.close(); }
}

test('canonical baseline preserves raw passing/unmapped calls and separate STP associations, exports optimized full projection', async t => {
  const root = await temporary(t);
  const intermediate = [fixed('LI', { 3: 'PASSING', 21: '0710 ', 26: '0000', 30: '0000' }),
    fixed('LI', { 3: 'MIDDLE', 11: '0730 ', 16: '0731 ', 26: '0730', 30: '0731', 43: 'T' })];
  const source = await fixture(join(root, 'source'), { records: [fixed('TI', { 3: 'ORIGIN' }), association(), association('N', 'C'), ...schedule({ intermediate })] });
  const before = await readFile(join(source, 'RJTTF001.MCA'));
  const result = await bootstrapDelivery(source, join(root, 'baseline'));
  assert.deepEqual(result.metadata.counts, { schedules: 1, associations: 2, timingLocations: 1 });
  assert.equal(result.metadata.header.referenceUsable, true);
  assert.equal(result.metadata.source.contentHash, (await inspectSource(source)).contentHash);
  assert.match(rawRows(result.path, 'schedules')[0], /LIPASSING/);
  assert.match(rawRows(result.path, 'schedules')[0], /LIMIDDLE/);
  assert.deepEqual(await readFile(join(source, 'RJTTF001.MCA')), before);
  assert.equal((await inspectSource(result.fullSourcePath)).feedMode, 'full');
  const imported = await importFullSnapshot(result.fullSourcePath, join(root, 'snapshot'));
  assert.equal(imported.metadata.schemaVersion, 2);
  assert.equal(imported.metadata.counts.routingCalls, 2);
  assert.equal(imported.validation.valid, true);
  assert.equal((await readDeliveryMetadata(result.path)).canonicalHash, result.metadata.canonicalHash);
});

test('daily N/R/D transactions preserve cancellations/overlays and replace every auxiliary including ZTR; new MSN mappings restore old raw calls', async t => {
  const root = await temporary(t);
  const intermediate = [fixed('LI', { 3: 'MIDDLE', 11: '0730 ', 16: '0731 ', 26: '0730', 30: '0731', 43: 'T' })];
  const full = await fixture(join(root, 'full'), { records: [association(), ...schedule({ intermediate }), ...schedule({ uid: 'B00001' })] });
  const baseline = await bootstrapDelivery(full, join(root, 'baseline'));
  const initialRaw = rawRows(baseline.path, 'schedules');
  const daily = await fixture(join(root, 'daily'), { mode: 'update', sequence: '002', date: '2026-09-02', currentReference: 'REF0002', previousReference: 'REF0001', middleStation: true, auxiliaryMarker: 'UPDATED',
    ztrRecords: schedule({ uid: 'Z00001' }), records: [association('R', 'P', { 35: 'VV' }), association('N', 'C'),
      ...schedule({ uid: 'B00001', transaction: 'D' }), ...schedule({ uid: 'C00001' }), ...schedule({ uid: 'C00001', transaction: 'D' }),
      ...schedule({ uid: 'D00001' }), ...schedule({ uid: 'D00001', transaction: 'R', departure: '0715' }),
      ...schedule({ uid: 'A00001', start: '260902', stp: 'O', departure: '0720' }), ...schedule({ uid: 'A00001', start: '260903', stp: 'C' })] });
  const result = await applyDeliveryUpdate(baseline.path, daily, join(root, 'updated'));
  assert.deepEqual(result.metadata.counts, { schedules: 4, associations: 2, timingLocations: 0 });
  assert.deepEqual(result.metadata.operations.schedules, { N: 4, R: 1, D: 2 });
  assert.deepEqual(rawRows(baseline.path, 'schedules'), initialRaw);
  const exported = await readFile(join(result.fullSourcePath, 'RJTTF002.MCA'), 'utf8');
  assert.equal(exported.includes('BSR'), false); assert.equal(exported.includes('BSD'), false);
  assert.match(exported, /BSNA00001260903.*C/);
  for (const type of ['MSN', 'TSI', 'ALF', 'FLF', 'ZTR', 'REJ', 'SET']) assert.deepEqual(await readFile(join(result.fullSourcePath, `RJTTF002.${type}`)), await readFile(join(daily, `RJTTF002.${type}`)));
  const snapshot = await importFullSnapshot(result.fullSourcePath, join(root, 'snapshot'));
  assert.equal(snapshot.validation.valid, true);
  const repository = await openDataset(snapshot.path);
  try { assert.equal(repository.resolveServices('2026-09-01').services.find(service => service.uid === 'A00001').calls.length, 3); }
  finally { repository.close(); }
});

test('TIPLOC insert/amend/rename/delete apply exact targets and export insert records without stale rename fields', async t => {
  const root = await temporary(t);
  const full = await fixture(join(root, 'full'), { records: [fixed('TI', { 3: 'ORIGIN', 54: 'ORG' }), fixed('TI', { 3: 'REMOVE', 54: 'REM' }), ...schedule()] });
  const baseline = await bootstrapDelivery(full, join(root, 'baseline'));
  const daily = await fixture(join(root, 'daily'), { mode: 'update', sequence: '002', date: '2026-09-02', previousReference: 'REF0001', records: [
    fixed('TI', { 3: 'NEWLOC', 54: 'NEW' }), fixed('TA', { 3: 'ORIGIN', 54: 'ORG', 73: 'RENAMED' }), fixed('TD', { 3: 'REMOVE' })] });
  const result = await applyDeliveryUpdate(baseline.path, daily, join(root, 'updated'));
  assert.deepEqual(result.metadata.operations.timingLocations, { N: 1, R: 1, D: 1 });
  assert.equal(result.metadata.counts.timingLocations, 2);
  const raw = rawRows(result.path, 'timing_locations');
  assert.deepEqual(raw.map(row => row.slice(2, 9).trim()), ['NEWLOC', 'RENAMED']);
  assert.equal(raw.every(row => row.slice(72) === '        '), true);
  assert.equal(rawRows(baseline.path, 'timing_locations').length, 2);
});

test('sequence gaps, stale dates and usable header-reference mismatch are rejected without changing baseline', async t => {
  const root = await temporary(t), full = await fixture(join(root, 'full'));
  const baseline = await bootstrapDelivery(full, join(root, 'baseline')), original = await readFile(join(baseline.path, 'canonical.sqlite'));
  const gap = await fixture(join(root, 'gap'), { mode: 'update', sequence: '004', date: '2026-09-04', records: [] });
  await assert.rejects(applyDeliveryUpdate(baseline.path, gap, join(root, 'gap-target')), { code: 'UPDATE_GAP', expectedSequence: '002', actualSequence: '004', missingCount: 2 });
  const stale = await fixture(join(root, 'stale'), { mode: 'update', sequence: '002', date: '2026-09-01', records: [] });
  await assert.rejects(applyDeliveryUpdate(baseline.path, stale, join(root, 'stale-target')), { code: 'UPDATE_STALE' });
  const mismatched = await fixture(join(root, 'mismatched'), { mode: 'update', sequence: '002', date: '2026-09-02', previousReference: 'WRONG', records: [] });
  await assert.rejects(applyDeliveryUpdate(baseline.path, mismatched, join(root, 'mismatch-target')), { code: 'UPDATE_REFERENCE_MISMATCH' });
  assert.deepEqual(await readFile(join(baseline.path, 'canonical.sqlite')), original);
  assert.equal((await readdir(root)).some(name => /\.building-|\.import\.lock/.test(name)), false);
});

test('duplicate additions, absent revisions/deletions and broken schedule shape fail safely', async t => {
  const root = await temporary(t), full = await fixture(join(root, 'full'));
  const baseline = await bootstrapDelivery(full, join(root, 'baseline'));
  for (const [name, records, code] of [
    ['duplicate', schedule(), 'UPDATE_TARGET_DUPLICATE'], ['missing-revise', schedule({ uid: 'B00001', transaction: 'R' }), 'UPDATE_TARGET_MISSING'],
    ['missing-delete', schedule({ uid: 'B00001', transaction: 'D' }), 'UPDATE_TARGET_MISSING'],
    ['association-missing', [association('D')], 'UPDATE_TARGET_MISSING'],
  ]) {
    const daily = await fixture(join(root, name), { mode: 'update', sequence: '002', date: '2026-09-02', records });
    await assert.rejects(applyDeliveryUpdate(baseline.path, daily, join(root, `${name}-target`)), { code });
    await assert.rejects(readFile(join(root, `${name}-target`, 'metadata.json')), { code: 'ENOENT' });
  }
  const incomplete = await fixture(join(root, 'incomplete'), { mode: 'update', sequence: '002', date: '2026-09-02', records: schedule({ uid: 'B00001' }).slice(0, 3) });
  await assert.rejects(applyDeliveryUpdate(baseline.path, incomplete, join(root, 'incomplete-target')), /Incomplete schedule/);
  assert.equal((await readDeliveryMetadata(baseline.path)).counts.schedules, 1);
});

test('999→001 rollover works and historical full HD references do not incorrectly reject the first daily update', async t => {
  const root = await temporary(t), full = await fixture(join(root, 'full'), { sequence: '999', headerDate: '2019-07-11', currentReference: 'OLDREF' });
  const baseline = await bootstrapDelivery(full, join(root, 'baseline'));
  assert.equal(baseline.metadata.header.referenceUsable, false);
  const daily = await fixture(join(root, 'daily'), { mode: 'update', sequence: '001', date: '2026-09-02', currentReference: 'REF0001', previousReference: 'REF0999', records: [] });
  const result = await applyDeliveryUpdate(baseline.path, daily, join(root, 'updated'));
  assert.equal(result.metadata.sequence, '001');
  assert.equal(result.metadata.baseline.sequence, '999');
  assert.equal(result.metadata.header.referenceUsable, true);
  assert.equal(nextDeliverySequence('999'), '001');
  assert.throws(() => nextDeliverySequence('000'), /Invalid/);
});

test('immutable targets, bootstrap/update roles and cancellation are enforced', async t => {
  const root = await temporary(t), full = await fixture(join(root, 'full'));
  const baseline = await bootstrapDelivery(full, join(root, 'baseline'));
  await assert.rejects(bootstrapDelivery(full, baseline.path), { code: 'DELIVERY_TARGET_EXISTS' });
  const daily = await fixture(join(root, 'daily'), { mode: 'update', sequence: '002', date: '2026-09-02', records: [] });
  await assert.rejects(bootstrapDelivery(daily, join(root, 'bad-bootstrap')), /monthly MCA/);
  await assert.rejects(applyDeliveryUpdate(baseline.path, full, join(root, 'bad-update')), /daily CFA/);
  const controller = new AbortController(); controller.abort();
  await assert.rejects(bootstrapDelivery(full, join(root, 'cancelled'), { signal: controller.signal }), { name: 'AbortError' });
  assert.equal((await readdir(root)).some(name => /\.building-|\.import\.lock/.test(name)), false);
});
