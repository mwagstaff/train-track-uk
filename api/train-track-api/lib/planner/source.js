import { createReadStream, createWriteStream } from 'node:fs';
import { lstat, readdir, open, mkdtemp, rm, readFile } from 'node:fs/promises';
import { basename, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import { parseDisplayDate } from './parser.js';

const TYPES = ['DAT', 'MCA', 'MSN', 'TSI', 'ALF', 'FLF', 'ZTR', 'REJ', 'SET'];
const DEFAULT_MAX_BYTES = 2 * 1024 ** 3;

// Daily deliveries replace MCA with CFA and use C for DAT/CFA, but F for
// refreshed supporting files. They can be inspected, never used as a baseline.
function packageDetails(identities) {
  const manifest = identities.find(member => member.type === 'DAT');
  if (!manifest) throw new Error('Missing timetable manifest');
  const feedMode = manifest.packageId.startsWith('RJTTF') ? 'full' : 'update';
  const sequence = manifest.packageId.slice(-3);
  const expected = TYPES.map(type => feedMode === 'update' && type === 'MCA' ? 'CFA' : type);
  if (identities.length !== expected.length || expected.some(type => !identities.some(member => member.type === type))) {
    throw new Error(`Expected nine complete ${feedMode === 'full' ? 'full-feed' : 'daily-update'} members`);
  }
  for (const member of identities) {
    const prefix = feedMode === 'update' && ['DAT', 'CFA'].includes(member.type) ? 'RJTTC' : 'RJTTF';
    if (member.packageId !== `${prefix}${sequence}`) throw new Error('Mixed timetable packages');
  }
  return { packageId: manifest.packageId, sequence, feedMode };
}

export function memberIdentity(name) {
  const match = /^(RJTT[FC]\d{3})(?:\.(DAT|MCA|CFA|MSN|TSI|ALF|FLF|ZTR|REJ|SET)|(DAT|MCA|CFA|MSN|TSI|ALF|FLF|ZTR|REJ|SET)\.txt)$/i.exec(name);
  if (!match) throw new Error(`Unrecognised timetable member: ${name}`);
  return { packageId: match[1].toUpperCase(), type: (match[2] ?? match[3]).toUpperCase() };
}

async function zipEntries(path, maxBytes) {
  const handle = await open(path, 'r');
  try {
    const { size } = await handle.stat();
    const tailSize = Math.min(size, 65557);
    const tail = Buffer.alloc(tailSize);
    await handle.read(tail, 0, tailSize, size - tailSize);
    let end = -1;
    for (let i = tailSize - 22; i >= 0; i--) {
      if (tail.readUInt32LE(i) === 0x06054b50 && i + 22 + tail.readUInt16LE(i + 20) === tailSize) { end = i; break; }
    }
    if (end < 0) throw new Error('Missing ZIP directory terminator');
    const count = tail.readUInt16LE(end + 10), directorySize = tail.readUInt32LE(end + 12), offset = tail.readUInt32LE(end + 16);
    if (tail.readUInt16LE(end + 4) || tail.readUInt16LE(end + 6) || count !== tail.readUInt16LE(end + 8)
      || count < 1 || count > 20 || directorySize > 32768 || offset + directorySize > size - tailSize + end) {
      throw new Error('Unsupported or malformed ZIP directory (split/ZIP64 archives are not supported)');
    }
    const directory = Buffer.alloc(directorySize);
    await handle.read(directory, 0, directorySize, offset);
    const entries = [], names = new Set(), logicalTypes = new Set();
    const identities = [];
    let position = 0, expanded = 0;
    for (let i = 0; i < count; i++) {
      if (position + 46 > directory.length || directory.readUInt32LE(position) !== 0x02014b50) throw new Error('Malformed ZIP central record');
      const nameLength = directory.readUInt16LE(position + 28), extraLength = directory.readUInt16LE(position + 30), commentLength = directory.readUInt16LE(position + 32);
      const name = directory.subarray(position + 46, position + 46 + nameLength).toString('utf8');
      const size = directory.readUInt32LE(position + 24), flags = directory.readUInt16LE(position + 8);
      const mode = directory.readUInt32LE(position + 38) >>> 16;
      if (/[\/\\\x00-\x1f*?\[\]]/.test(name) || basename(name) !== name || names.has(name.toUpperCase())
        || ![0, 0x8000].includes(mode & 0xf000) || flags & 1 || ![0, 8].includes(directory.readUInt16LE(position + 10))) {
        throw new Error(`Unsafe, duplicate, encrypted or unsupported ZIP member: ${name}`);
      }
      const identity = memberIdentity(name);
      if (logicalTypes.has(identity.type)) throw new Error('Conflicting logical ZIP members');
      logicalTypes.add(identity.type);
      identities.push(identity);
      expanded += size;
      if (expanded > maxBytes) throw new Error('ZIP exceeds expanded-size limit');
      names.add(name.toUpperCase());
      entries.push({ name, size });
      position += 46 + nameLength + extraLength + commentLength;
    }
    if (position !== directorySize) throw new Error('ZIP directory size mismatch');
    packageDetails(identities);
    return entries;
  } finally { await handle.close(); }
}

export async function prepareSource(sourcePath, { signal, maxExpandedBytes = DEFAULT_MAX_BYTES } = {}) {
  const path = resolve(sourcePath);
  const stat = await lstat(path);
  if (stat.isSymbolicLink()) throw new Error('Timetable source must not be a symbolic link');
  let directory = path, temporary = false;
  try {
    if (!stat.isDirectory()) {
      if (!stat.isFile() || !/\.zip$/i.test(path)) throw new Error('Timetable source must be a directory or ZIP');
      const entries = await zipEntries(path, maxExpandedBytes);
      directory = await mkdtemp(join(tmpdir(), 'traintrack-timetable-'));
      temporary = true;
      for (const entry of entries) {
        signal?.throwIfAborted();
        const child = spawn('unzip', ['-p', path, entry.name], { stdio: ['ignore', 'pipe', 'pipe'], signal });
        let emitted = 0, stderr = '';
        child.stderr.on('data', chunk => { if (stderr.length < 4096) stderr += chunk; });
        const completion = new Promise((resolveExit, reject) => {
          child.once('error', reject);
          child.once('close', code => code === 0 ? resolveExit() : reject(new Error(`ZIP integrity failure: ${stderr.trim() || code}`)));
        });
        const limiter = new Transform({ transform(chunk, _encoding, callback) {
          emitted += chunk.length;
          if (emitted > entry.size || emitted > maxExpandedBytes) callback(new Error('ZIP emitted bytes exceed validated size'));
          else callback(null, chunk);
        } });
        try {
          await Promise.all([pipeline(child.stdout, limiter, createWriteStream(join(directory, entry.name), { flags: 'wx' }), { signal }), completion]);
          if (emitted !== entry.size) throw new Error('ZIP member size mismatch');
        } catch (error) { child.kill(); throw error; }
      }
    }
    const names = (await readdir(directory)).sort();
    if (names.length !== 9) throw new Error(`Expected nine timetable members, found ${names.length}`);
    const members = [], seen = new Set();
    let total = 0;
    for (const name of names) {
      const identity = memberIdentity(name);
      const memberPath = join(directory, name), memberStat = await lstat(memberPath);
      if (!memberStat.isFile() || memberStat.isSymbolicLink()) throw new Error(`Member is not a regular file: ${name}`);
      if (seen.has(identity.type)) throw new Error(`Conflicting logical member: ${identity.type}`);
      seen.add(identity.type);
      total += memberStat.size;
      members.push({ ...identity, name, path: memberPath, size: memberStat.size, mtimeMs: memberStat.mtimeMs, ctimeMs: memberStat.ctimeMs });
    }
    const { packageId, sequence: packageSequence, feedMode } = packageDetails(members);
    if (total > maxExpandedBytes) throw new Error('Source exceeds expanded-size limit');
    const manifest = await readFile(members.find(m => m.type === 'DAT').path, 'latin1');
    const listed = manifest.split(/\r?\n/).filter(line => line.trim() && !line.startsWith('/')).map(line => line.trim());
    if (listed.length !== 8 || new Set(listed.map(name => name.toUpperCase())).size !== 8
      || listed.some(name => !names.some(actual => actual.toUpperCase() === name.toUpperCase()) || memberIdentity(name).type === 'DAT')) {
      throw new Error('Manifest membership mismatch');
    }
    const generated = /\/!! Generated:\s*(\d{2}\/\d{2}\/\d{4})/.exec(manifest);
    const sequence = /\/!! Sequence:\s*(\d{3})/.exec(manifest);
    if (!generated || !sequence || sequence[1] !== packageId.slice(-3) || !/\/!! End of file \(8 records\)/.test(manifest)) throw new Error('Malformed/truncated manifest metadata');
    return { path, directory, kind: temporary ? 'zip' : 'directory', packageId, sequence: packageSequence, feedMode,
      generationDate: parseDisplayDate(generated[1]), members, totalBytes: total,
      cleanup: async () => { if (temporary) await rm(directory, { recursive: true, force: true }); } };
  } catch (error) { if (temporary) await rm(directory, { recursive: true, force: true }); throw error; }
}

async function inspectMember(member, options) {
  const counts = {}, widths = {}, hash = createHash('sha256');
  const transactions = {}, stp = {};
  let remaining = '', lines = 0, last = '', seenEnd = false, header = false, footerCount = null, records = 0, msnEnd = false;
  let generationDate = null, sequence = null;
  function line(text) {
    if (text.endsWith('\r')) text = text.slice(0, -1);
    lines++;
    widths[text.length] = (widths[text.length] ?? 0) + 1;
    if (text.trim()) last = text.trim();
    if (text.startsWith('/')) {
      const generated = /\/!! Generated:\s*(\d{2}\/\d{2}\/\d{4})/.exec(text);
      if (generated) generationDate = parseDisplayDate(generated[1]);
      const sequenceField = /\/!! Sequence:\s*(\d{3})/.exec(text);
      if (sequenceField) sequence = sequenceField[1];
      const footer = /\/!! End of file \((\d+) records\)/.exec(text);
      if (footer) { footerCount = Number(footer[1]); seenEnd = true; }
      return;
    }
    if (!text.trim()) return;
    records++;
    let type;
    if (['MCA', 'CFA', 'ZTR'].includes(member.type)) {
      if (text.length !== 80) throw new Error(`${member.name}:${lines}: expected 80 characters, found ${text.length}`);
      type = text.slice(0, 2);
      if (seenEnd) throw new Error(`${member.name}: data after ZZ`);
      if (!header && type !== 'HD') throw new Error(`${member.name}: missing HD`);
      if (type === 'HD') { if (header) throw new Error('Duplicate HD'); header = true; }
      if (type === 'ZZ') seenEnd = true;
      const allowed = ['HD','TI','AA','BS','BX','LO','LI','CR','LT','ZZ', ...(member.type === 'CFA' ? ['TA', 'TD'] : [])];
      if (!allowed.includes(type)) throw new Error(`${member.name}:${lines}: unsupported record ${type}`);
      if (['BS', 'AA'].includes(type)) {
        transactions[type] ??= {};
        transactions[type][text[2]] = (transactions[type][text[2]] ?? 0) + 1;
        stp[type] ??= {};
        stp[type][text[79]] = (stp[type][text[79]] ?? 0) + 1;
      }
    } else if (member.type === 'MSN') {
      type = text.startsWith('A') ? text.includes('FILE-SPEC=') ? 'header' : 'A'
        : text.startsWith('L') ? 'L' : /^(-1| 0| 1)/.test(text) ? 'CRS-usage' : 'legacy';
      if (['A', 'L', 'header'].includes(type) && text.length !== 82) throw new Error(`${member.name}:${lines}: expected 82 characters`);
      if (text.startsWith('End of File')) { seenEnd = true; msnEnd = true; }
    } else if (member.type === 'FLF') { type = text.trim() === 'END' ? 'END' : 'links'; if (type === 'END') seenEnd = true; }
    else type = 'rows';
    counts[type] = (counts[type] ?? 0) + 1;
  }
  for await (const chunk of createReadStream(member.path, { signal: options.signal })) {
    hash.update(chunk);
    const parts = (remaining + chunk.toString('latin1')).split('\n');
    remaining = parts.pop();
    for (const text of parts) line(text);
  }
  if (remaining.length) line(remaining);
  if (['MCA','CFA','ZTR'].includes(member.type) && (!header || !seenEnd || last !== 'ZZ')) throw new Error(`${member.name}: missing final ZZ`);
  if (['DAT','FLF','MSN','SET'].includes(member.type) && !seenEnd) throw new Error(`${member.name}: missing end marker`);
  if (member.type === 'FLF' && counts.END !== 1) throw new Error(`${member.name}: missing/duplicate END`);
  if (member.type === 'MSN' && (!msnEnd || counts.header !== 1)) throw new Error(`${member.name}: missing MSN header or End of File`);
  if (member.type === 'REJ' && last !== 'End of rejected trains file') throw new Error(`${member.name}: missing rejection trailer`);
  if (footerCount !== null && footerCount !== records) throw new Error(`${member.name}: footer count ${footerCount} does not match ${records}`);
  return { type: member.type, name: member.name, size: member.size, sha256: hash.digest('hex'), counts, widths, lines, generationDate, sequence,
    ...(Object.keys(transactions).length ? { transactions, stp } : {}) };
}

export async function inspectPreparedSource(prepared, options = {}) {
  const members = [];
  for (const member of prepared.members) {
    options.signal?.throwIfAborted();
    const inspected = await inspectMember(member, options);
    if (inspected.generationDate && inspected.generationDate !== prepared.generationDate) throw new Error(`${member.name}: generation date does not match package manifest`);
    if (inspected.sequence && inspected.sequence !== prepared.sequence) throw new Error(`${member.name}: sequence does not match package manifest`);
    members.push(inspected);
    options.onProgress?.({ phase: 'inspect', member: member.type, completed: members.length, total: prepared.members.length });
  }
  const contentHash = createHash('sha256').update(members.map(member => `${member.type}\0${member.size}\0${member.sha256}\n`).sort().join('')).digest('hex');
  const result = { kind: prepared.kind, path: prepared.path, packageId: prepared.packageId, sequence: prepared.sequence,
    feedMode: prepared.feedMode, requiresBaseline: prepared.feedMode === 'update',
    generationDate: prepared.generationDate, totalBytes: prepared.totalBytes, contentHash, members };
  if (prepared.kind === 'zip') {
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(prepared.path, { signal: options.signal })) hash.update(chunk);
    result.archiveSha256 = hash.digest('hex');
  }
  return result;
}

export async function inspectSource(sourcePath, options = {}) {
  const source = await prepareSource(sourcePath, options);
  try { return await inspectPreparedSource(source, options); }
  finally { await source.cleanup(); }
}
