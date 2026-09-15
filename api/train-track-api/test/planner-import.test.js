import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { inspectSource, memberIdentity } from '../lib/planner/source.js';
import { parseTimetable, parseFixedLink, parseInterchange } from '../lib/planner/parser.js';
import { runsOn, selectVariant } from '../lib/planner/calendar.js';
import { addDays, cifDate, normaliseCallTimes, originOffsetMinutes, parseClock, resolveCallTimes } from '../lib/planner/time.js';
import { importFullSnapshot, openDataset, validateDataset, activateDataset, getActiveDataset, rollbackDataset } from '../lib/planner/repository.js';

const run = promisify(execFile);
function fixed(type, fields = {}, length = 80) {
  const row = Array(length).fill(' ');
  for (const [start, value] of Object.entries({ 1: type, ...fields })) {
    for (let i = 0; i < value.length; i++) row[Number(start) - 1 + i] = value[i];
  }
  return row.join('');
}

function working({ uid = 'A00001', start = '260901', end = '261231', days = '1111100', stp = 'P', departure = '0700', arrival = '0730', intermediate = [], extra = {} } = {}) {
  const basic = fixed('BS', { 3: 'N', 4: uid, 10: start, 16: end, 22: days, 30: stp === 'C' ? ' ' : 'P', 31: stp === 'C' ? '  ' : 'OO', 80: stp, ...extra });
  if (stp === 'C') return [basic];
  return [basic, fixed('BX', { 12: 'SE', 14: 'Y' }),
    fixed('LO', { 3: 'ORIGIN ', 11: `${departure} `, 16: departure, 30: 'TB' }), ...intermediate,
    fixed('LT', { 3: 'DEST   ', 11: `${arrival} `, 16: arrival, 26: 'TF' })];
}

async function fixture(directory, schedules = working(), sequence = '001') {
  await mkdir(directory, { recursive: true });
  const prefix = `RJTTF${sequence}`;
  const names = ['MCA', 'MSN', 'TSI', 'ALF', 'FLF', 'ZTR', 'REJ', 'SET'];
  const body = {
    MCA: [fixed('HD'), ...schedules, fixed('ZZ')].join('\r\n') + '\r\n',
    MSN: [fixed('A', { 31: 'FILE-SPEC=05' }, 82),
      fixed('A', { 6: 'ORIGIN STATION', 36: '2', 37: 'ORIGIN ', 44: 'ORG', 50: 'ORG', 64: ' 4' }, 82),
      fixed('A', { 6: 'DESTINATION', 36: '2', 37: 'DEST   ', 44: 'DST', 50: 'DST', 64: '10' }, 82),
      fixed('A', { 6: 'MIDDLE STATION', 36: '2', 37: 'MIDDLE ', 44: 'MID', 50: 'MID', 64: ' 5' }, 82),
      fixed('L', { 6: 'ORIGIN STATION', 37: 'START HERE' }, 82),
      'End of File', '/!! End of file (6 records) (01/09/2026)'].join('\n'),
    TSI: 'DST,SE,SN,6,\n', ALF: 'M=WALK,O=ORG,D=DST,T=7,S=0001,E=2359,P=4,R=1111111\n',
    FLF: 'ADDITIONAL LINK: WALK BETWEEN ORG AND DST IN 7 MINUTES\nEND\n/!! End of file (2 records) (01/09/2026)\n',
    ZTR: `${fixed('HD')}\n${fixed('ZZ')}\n`, REJ: 'Start of rejected trains file\nEnd of rejected trains file\n',
    SET: 'UCFCATE\n/!! End of file (1 records) (01/09/2026)',
    DAT: `/!! Sequence: ${sequence}\r\n/!! Generated: 01/09/2026\r\n${names.map(type => `${prefix}${type}.txt`).join('\n')}\n/!! End of file (8 records) (01/09/2026)`,
  };
  for (const [type, value] of Object.entries(body)) await writeFile(join(directory, `${prefix}${type}.txt`), value);
  return directory;
}

async function temporary(t) {
  const path = await mkdtemp(join(tmpdir(), 'traintrack-import-test-'));
  t.after(() => rm(path, { recursive: true, force: true }));
  return path;
}

test('directory inspector recognises both member conventions, validates manifest and counts FLF END separately', async t => {
  const path = await temporary(t), source = await fixture(join(path, 'source'));
  const report = await inspectSource(source);
  assert.equal(report.members.length, 9);
  assert.equal(report.generationDate, '2026-09-01');
  assert.equal(report.members.find(m => m.type === 'MSN').counts.A, 3);
  assert.equal(report.members.find(m => m.type === 'FLF').counts.links, 1);
  assert.equal(report.members.find(m => m.type === 'FLF').counts.END, 1);
  assert.equal(report.archiveSha256, undefined);
  assert.deepEqual(memberIdentity('RJTTF999.MCA'), { packageId: 'RJTTF999', type: 'MCA' });
  assert.equal((await inspectSource(source)).contentHash, report.contentHash);
  await writeFile(join(source, 'RJTTF001DAT.txt'), (await readFile(join(source, 'RJTTF001DAT.txt'), 'utf8')).replace('RJTTF001TSI', 'RJTTF002TSI'));
  await assert.rejects(inspectSource(source), /Manifest membership mismatch/);
});

test('rejects source symlinks, truncated timetable, wrong widths and duplicate logical members', async t => {
  const path = await temporary(t), source = await fixture(join(path, 'source'));
  await symlink(source, join(path, 'link'));
  await assert.rejects(inspectSource(join(path, 'link')), /symbolic link/);
  const main = join(source, 'RJTTF001MCA.txt'), original = await readFile(main, 'utf8');
  await writeFile(main, original.replace(`${fixed('ZZ')}\r\n`, ''));
  await assert.rejects(inspectSource(source), /missing final ZZ/);
  await writeFile(main, original.replace('LOORIGIN ', 'LOORIGIN'));
  await assert.rejects(inspectSource(source), /expected 80/);
  await writeFile(main, original);
  await rm(join(source, 'RJTTF001TSI.txt'));
  await writeFile(join(source, 'RJTTF001.MCA'), original);
  await assert.rejects(inspectSource(source), /Conflicting logical member/);
});

test('ZIP and directory imports share member hashes and validate ZIP contents', async t => {
  const path = await temporary(t), source = await fixture(join(path, 'source'));
  const names = ['DAT','MCA','MSN','TSI','ALF','FLF','ZTR','REJ','SET'].map(type => `RJTTF001${type}.txt`);
  const archive = join(path, 'source.zip');
  await run('zip', ['-q', archive, ...names], { cwd: source });
  const zipped = await inspectSource(archive), directory = await inspectSource(source);
  assert.equal(zipped.contentHash, directory.contentHash);
  assert.match(zipped.archiveSha256, /^[a-f0-9]{64}$/);
  // A symlink has no right to become a regular timetable member on extraction.
  await symlink('../source/RJTTF001MCA.txt', join(path, 'RJTTF001MCA.txt'));
  await run('zip', ['-yq', join(path, 'unsafe.zip'), 'RJTTF001MCA.txt'], { cwd: path });
  await assert.rejects(inspectSource(join(path, 'unsafe.zip')), /Unsafe/);
  await run('zip', ['-q', join(path, 'traversal.zip'), '../source/RJTTF001MCA.txt'], { cwd: join(path, 'source') });
  await assert.rejects(inspectSource(join(path, 'traversal.zip')), /Unsafe/);
  await assert.rejects(inspectSource(archive, { maxExpandedBytes: 100 }), /expanded-size/);
});

test('parser separates passenger stops, passing, restrictions, occurrences and public/work half minutes', async t => {
  const path = await temporary(t);
  const intermediate = [
    fixed('LI', { 3: 'MIDDLE ', 21: '0705H', 26: '0000', 30: '0000' }),
    fixed('LI', { 3: 'MIDDLE 2', 11: '0709H', 16: '0710 ', 26: '0710', 30: '0710', 43: 'U' }),
    fixed('LI', { 3: 'MIDDLE 3', 11: '0715 ', 16: '0716 ', 26: '0715', 30: '0716', 43: 'D' }),
    fixed('LI', { 3: 'MIDDLE 4', 11: '0720 ', 16: '0721 ', 26: '0720', 30: '0721', 43: 'R -U-D' }),
    fixed('LI', { 3: 'MIDDLE 5', 11: '0725 ', 16: '0726 ', 26: '0725', 30: '0726', 43: 'T N' }),
  ];
  const source = await fixture(join(path, 'source'), working({ intermediate }));
  const parsed = [];
  for await (const item of parseTimetable(join(source, 'RJTTF001MCA.txt'), 'MCA')) if (item.type === 'schedule') parsed.push(item.value);
  const calls = parsed[0].calls;
  assert.equal(calls[1].canBoard, false); assert.equal(calls[1].canAlight, false);
  assert.equal(calls[2].canBoard, true); assert.equal(calls[2].canAlight, false);
  assert.equal(calls[3].canBoard, false); assert.equal(calls[3].canAlight, true);
  assert.equal(calls[4].requestStop, true); assert.equal(calls[4].canBoard, true);
  assert.equal(calls[4].canAlight, true);
  assert.equal(calls[5].canBoard, false); assert.equal(calls[5].canAlight, false);
  assert.equal(calls[2].suffix, '2'); assert.equal(calls[2].workArrival, 25770); assert.equal(calls[2].departureSeconds, 25800);
});

test('calendar chooses overlays on applicable days, honours dated cancellation, rejects ambiguous insertions', () => {
  const base = { uid: 'X', variantId: 'P', startDate: '2026-09-01', endDate: '2026-09-30', days: '1111100', stp: 'P' };
  const overlay = { ...base, variantId: 'O', startDate: '2026-09-08', endDate: '2026-09-08', stp: 'O' };
  const cancellation = { ...overlay, variantId: 'C', stp: 'C' };
  assert.equal(runsOn(base, '2026-09-01'), true); assert.equal(runsOn(base, '2026-09-30'), true);
  assert.equal(runsOn(base, '2026-09-05'), false);
  assert.equal(selectVariant([base, overlay], '2026-09-08').selected.variantId, 'O');
  assert.equal(selectVariant([base, overlay], '2026-09-09').selected.variantId, 'P');
  assert.equal(selectVariant([base, cancellation], '2026-09-08').reason, 'CANCELLED');
  assert.equal(selectVariant([base, cancellation], '2026-09-09').selected.variantId, 'P');
  assert.equal(selectVariant([{ ...base, stp: 'N' }], '2026-09-08').reason, 'NEW_STP');
  assert.equal(selectVariant([base, { ...base, stp: 'N' }], '2026-09-08').reason, 'CONFLICTING_VARIANTS');
  assert.equal(selectVariant([base, { ...base, variantId: 'other' }], '2026-09-08').reason, 'CONFLICTING_VARIANTS');
  // Never revive the permanent train because a replacing overlay is excluded
  // for unsupported semantics. Selection and routability are separate steps.
  assert.equal(selectVariant([base, { ...overlay, excludedReason: 'UNSUPPORTED_MODE' }], '2026-09-08').selected.variantId, 'O');
  assert.equal(selectVariant([base, overlay, cancellation], '2026-09-08').reason, 'CANCELLED');
});

test('operational attachment and reversal activities do not remove advertised origin/terminus calls', async t => {
  const path = await temporary(t);
  const trains = working().map(line => line.startsWith('LO')
    ? fixed('LO', { 3: 'ORIGIN ', 11: '0700 ', 16: '0700', 30: 'TBRM-U' })
    : line.startsWith('LT') ? fixed('LT', { 3: 'DEST   ', 11: '0730 ', 16: '0730', 26: 'TF-D' }) : line);
  const source = await fixture(join(path, 'source'), trains);
  const candidate = await importFullSnapshot(source, join(path, 'snapshot'));
  const repo = await openDataset(candidate.path);
  try {
    const calls = repo.resolveServices('2026-09-08').services[0].calls;
    assert.equal(calls[0].station, 'ORG'); assert.equal(calls[0].canBoard, true);
    assert.equal(calls.at(-1).station, 'DST'); assert.equal(calls.at(-1).canAlight, true);
  } finally { repo.close(); }
});

test('time resolver retains origin clock convention across both clock changes and rejects ambiguous origin', () => {
  assert.equal(cifDate('991231'), '2099-12-31');
  assert.equal(addDays('2026-12-31', 1), '2027-01-01');
  assert.equal(parseClock('2359H'), 86370);
  assert.throws(() => cifDate('260231'), /Invalid calendar/);
  assert.throws(() => parseClock('2460'), /Invalid timetable/);
  const calls = normaliseCallTimes([
    { workingDeparture: '2350 ', publicDeparture: '2350', canBoard: true },
    { workingArrival: '0200 ', publicArrival: '0200', canAlight: true },
  ]);
  assert.equal(calls[1].arrivalSeconds, 93600);
  const spring = resolveCallTimes(calls, '2026-03-28');
  assert.equal(new Date(spring[1].arrival).toISOString(), '2026-03-29T02:00:00.000Z');
  const autumn = resolveCallTimes(calls, '2026-10-24');
  assert.equal(new Date(autumn[1].arrival).toISOString(), '2026-10-25T01:00:00.000Z');
  assert.throws(() => originOffsetMinutes('2026-10-25', 5400), /clock-change/);
  assert.throws(() => originOffsetMinutes('2026-03-29', 5400), /clock-change/);
  assert.equal(originOffsetMinutes('2026-03-29', 7200), 60);
  assert.equal(originOffsetMinutes('2026-10-25', 7200), 0);
});

test('0000 requires midnight working context; small backwards working times fail', () => {
  const calls = normaliseCallTimes([
    { workingDeparture: '2359H', publicDeparture: '2359', canBoard: true },
    { workingArrival: '0000 ', publicArrival: '0000', canAlight: true },
  ]);
  assert.equal(calls[1].arrivalSeconds, 86400);
  const missing = normaliseCallTimes([
    { workingDeparture: '1200 ', publicDeparture: '0000', canBoard: true },
    { workingArrival: '1300 ', publicArrival: '1300', canAlight: true },
  ]);
  assert.equal(missing[0].canBoard, false);
  const halfMinute = normaliseCallTimes([
    { workingDeparture: '2359 ', publicDeparture: '2359', canBoard: true },
    { workingArrival: '0000H', publicArrival: '0000', canAlight: true },
  ]);
  assert.equal(halfMinute[1].arrivalSeconds, null);
  assert.equal(halfMinute[1].ambiguousMidnight, true);
  assert.throws(() => normaliseCallTimes([{ workingDeparture: '1200 ' }, { workingArrival: '1159 ' }]), /backwards/);
});

test('ALF and TSI retain direction, priority, applicability and source identities', () => {
  const source = { member: 'ALF', line: 7 };
  assert.deepEqual(parseFixedLink('M=TUBE,O=ORG,D=DST,T=13,S=0530,E=2359,P=6,F=01/09/2026,U=30/09/2026,R=1111100', source), {
    id: 'ALF:7', origin: 'ORG', destination: 'DST', mode: 'tubeTransfer', minutes: 13, startTime: '0530', endTime: '2359',
    priority: 6, startDate: '2026-09-01', endDate: '2026-09-30', days: '1111100', sourceRef: source,
  });
  assert.throws(() => parseFixedLink('M=WALK,O=ORG,D=DST,T=0,S=0001,E=2359,P=4', source), /Malformed/);
  assert.throws(() => parseFixedLink('M=WALK,O=ORG,D=DST,T=7,S=0001,E=2359,P=4,P=5', source), /duplicate/);
  assert.equal(parseInterchange('DST,SE,SN,6,', source).arrivingOperator, 'SE');
});

test('full import, idempotence, dated resolution, atomic activation and rollback', async t => {
  const path = await temporary(t), source = await fixture(join(path, 'source'), [
    ...working(), ...working({ stp: 'C', start: '260908', end: '260908' }),
    ...working({ uid: 'H00001', extra: { 29: 'X' } }),
  ]);
  const target = join(path, 'snapshot'), data = join(path, 'active');
  const result = await importFullSnapshot(source, target);
  assert.equal(result.validation.valid, true); assert.equal(result.metadata.counts.schedules, 3);
  assert.ok(result.validation.representativeDates.some(sample => sample.operatorCounts.SE === 1));
  assert.equal(result.metadata.diagnostics.counts.HOLIDAY_CALENDAR_NOT_CONFIGURED, 1);
  assert.equal((await importFullSnapshot(source, target)).unchanged, true);
  const repo = await openDataset(target);
  assert.equal(repo.stations.find(s => s.crs === 'ORG').aliases.includes('START HERE'), true);
  assert.equal(repo.resolveServices('2026-09-08').services.length, 0);
  const selected = repo.resolveServices('2026-09-09').services[0];
  assert.equal(repo.resolveServiceExplanation('A00001', '2026-09-08').reason, 'CANCELLED');
  assert.equal(selected.uid, 'A00001');
  assert.equal(new Date(selected.calls[0].departure).toISOString(), '2026-09-09T06:00:00.000Z');
  repo.close();
  const first = await activateDataset(target, data);
  assert.equal((await getActiveDataset(data)).version, first.version);
  const nextSource = await fixture(join(path, 'source-next'), working({ departure: '0800', arrival: '0830' }), '002');
  const next = await importFullSnapshot(nextSource, join(path, 'next-snapshot'));
  await activateDataset(next.path, data);
  assert.equal((await getActiveDataset(data)).version, next.version);
  await rollbackDataset(first.version, data);
  assert.equal((await getActiveDataset(data)).version, first.version);
  const malformed = JSON.parse(await readFile(join(next.path, 'metadata.json'), 'utf8'));
  malformed.counts.schedules++;
  await writeFile(join(next.path, 'metadata.json'), JSON.stringify(malformed));
  assert.equal((await validateDataset(next.path)).valid, false);
  await assert.rejects(activateDataset(next.path, data), /invalid dataset/);
  assert.equal((await getActiveDataset(data)).version, first.version);
});

test('partial operating records and update transactions cannot become a successful snapshot', async t => {
  const path = await temporary(t), schedules = working();
  const source = await fixture(join(path, 'source'), schedules.slice(0, -1));
  await assert.rejects(importFullSnapshot(source, join(path, 'partial')), /Incomplete schedule/);
  await fixture(source, working({ extra: { 3: 'D' } }));
  await assert.rejects(importFullSnapshot(source, join(path, 'delta')), /full importer rejects D/);
  const controller = new AbortController(); controller.abort();
  await assert.rejects(importFullSnapshot(source, join(path, 'cancelled'), { signal: controller.signal }), /abort/i);
});

test('source changes during inspection/import cannot acquire an earlier content identity', async t => {
  const path = await temporary(t), source = await fixture(join(path, 'source'));
  const main = join(source, 'RJTTF001MCA.txt'), original = await readFile(main, 'utf8');
  await assert.rejects(importFullSnapshot(source, join(path, 'candidate'), { onProgress(progress) {
    if (progress.phase === 'inspect' && progress.completed === progress.total) writeFileSync(main, original.replaceAll('0700', '0701'));
  } }), /Source changed during import/);
});

test('per-operator validation blocks a lost operator even if aggregate schedule count is unchanged', async t => {
  const path = await temporary(t), data = join(path, 'data');
  const trains = Array.from({ length: 20 }, (_, i) => working({ uid: `A${String(i).padStart(5, '0')}` })).flat();
  const source = await fixture(join(path, 'source'), trains);
  const first = await importFullSnapshot(source, join(path, 'first'));
  await activateDataset(first.path, data);
  const nextSource = await fixture(join(path, 'source-next'), trains.map(line => line.startsWith('BX') ? line.slice(0, 11) + 'SN' + line.slice(13) : line), '002');
  const next = await importFullSnapshot(nextSource, join(path, 'next'));
  assert.equal(next.metadata.counts.supportedSchedules, first.metadata.counts.supportedSchedules);
  await assert.rejects(activateDataset(next.path, data), /SE resolved passenger services fell/);
  assert.equal((await getActiveDataset(data)).version, first.version);
});

test('optional supplied-data fixture pins hashes and Kent House public times to resolver output', { skip: !process.env.PLANNER_FULL_DATASET }, async () => {
  const repo = await openDataset(process.env.PLANNER_FULL_DATASET);
  try {
    assert.equal(repo.metadata.source.contentHash, '75dacf80a357fe5878cead08e8b043671006ea96de29f315c6dad9d5ca440784');
    const service = repo.resolveServices('2026-09-08').services.find(value => value.uid === 'P86964');
    assert.ok(service);
    const board = service.calls.find(call => call.station === 'KTH'), alight = service.calls.find(call => call.station === 'VIC');
    assert.equal(new Date(board.departure).toISOString(), '2026-09-08T06:12:00.000Z');
    assert.equal(new Date(alight.arrival).toISOString(), '2026-09-08T06:33:00.000Z');
    assert.equal(alight.arrival - board.departure, 21 * 60000);
    assert.equal(repo.resolveServices('2026-08-31').services.some(value => value.uid === 'P86964'), false);
  } finally { repo.close(); }
});
