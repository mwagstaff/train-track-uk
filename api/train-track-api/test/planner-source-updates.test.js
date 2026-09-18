import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { promisify } from 'node:util';
import { execFile } from 'node:child_process';
import { inspectSource } from '../lib/planner/source.js';
import { importFullSnapshot } from '../lib/planner/repository.js';

const run = promisify(execFile);
const fixed = text => text.padEnd(80, ' ');

async function updateFixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'traintrack-update-inspect-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const source = join(root, 'source');
  await mkdir(source);
  const schedule = (transaction, stp) => fixed(`BS${transaction}A000012609172609181111111`).slice(0, 79) + stp;
  const association = fixed('AAD').slice(0, 79) + 'P';
  const names = ['RJTTC962CFA.txt', ...['MSN', 'TSI', 'ALF', 'FLF', 'ZTR', 'REJ', 'SET'].map(type => `RJTTF962${type}.txt`)];
  const body = {
    'RJTTC962DAT.txt': `/!! Sequence: 962\n/!! Generated: 17/09/2026\n${names.join('\n')}\n/!! End of file (8 records)`,
    'RJTTC962CFA.txt': [fixed('HD'), association, schedule('D', 'P'), schedule('R', 'O'), schedule('N', 'N'), fixed('TA'), fixed('TD'), fixed('ZZ')].join('\r\n') + '\r\n',
    'RJTTF962MSN.txt': 'A'.padEnd(30) + 'FILE-SPEC=05'.padEnd(52) + '\nEnd of File\n/!! End of file (2 records)',
    'RJTTF962TSI.txt': 'DST,SE,SN,6,\n',
    'RJTTF962ALF.txt': 'M=WALK,O=ORG,D=DST,T=7,S=0001,E=2359,P=4,R=1111111\n',
    'RJTTF962FLF.txt': 'END\n/!! End of file (1 records)',
    'RJTTF962ZTR.txt': `${fixed('HD')}\n${fixed('ZZ')}\n`,
    'RJTTF962REJ.txt': 'Start of rejected trains file\nEnd of rejected trains file\n',
    'RJTTF962SET.txt': 'UCFCATE\n/!! End of file (1 records)',
  };
  for (const [name, value] of Object.entries(body)) await writeFile(join(source, name), value);
  return { root, source, names: Object.keys(body) };
}

test('daily update inspection recognises mixed C/F members without claiming complete timetable coverage', async t => {
  const { root, source } = await updateFixture(t);
  const report = await inspectSource(source);
  assert.equal(report.packageId, 'RJTTC962');
  assert.equal(report.sequence, '962');
  assert.equal(report.feedMode, 'update');
  assert.equal(report.requiresBaseline, true);
  assert.equal(report.generationDate, '2026-09-17');
  const cfa = report.members.find(member => member.type === 'CFA');
  assert.deepEqual(cfa.transactions, { AA: { D: 1 }, BS: { D: 1, R: 1, N: 1 } });
  assert.deepEqual(cfa.stp.BS, { P: 1, O: 1, N: 1 });
  assert.equal(cfa.counts.TA, 1);
  assert.equal(cfa.counts.TD, 1);
  await assert.rejects(importFullSnapshot(source, join(root, 'snapshot')), /baseline.*unbroken update sequence/i);
  await assert.rejects(readFile(join(root, 'snapshot', 'metadata.json')), { code: 'ENOENT' });
});

test('daily directory and ZIP inspection share content identity', async t => {
  const { root, source, names } = await updateFixture(t);
  const zip = join(root, 'daily.zip');
  await run('zip', ['-q', zip, ...names], { cwd: source });
  const zipped = await inspectSource(zip);
  const directory = await inspectSource(source);
  assert.equal(zipped.contentHash, directory.contentHash);
  assert.equal(zipped.feedMode, 'update');
  assert.equal(zipped.requiresBaseline, true);
  assert.match(zipped.archiveSha256, /^[a-f0-9]{64}$/);
});

test('daily inspection rejects a missing trailer and mixed delivery sequences', async t => {
  const { source } = await updateFixture(t);
  const cfaPath = join(source, 'RJTTC962CFA.txt');
  const cfa = await readFile(cfaPath, 'utf8');
  await writeFile(cfaPath, cfa.replace(`${fixed('ZZ')}\r\n`, ''));
  await assert.rejects(inspectSource(source), /missing final ZZ/);
  await writeFile(cfaPath, cfa);
  const tsi = await readFile(join(source, 'RJTTF962TSI.txt'));
  await rm(join(source, 'RJTTF962TSI.txt'));
  await writeFile(join(source, 'RJTTF961TSI.txt'), tsi);
  await assert.rejects(inspectSource(source), /Mixed timetable packages/);
});
