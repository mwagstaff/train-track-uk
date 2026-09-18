// Read-only diagnostic: pipe this file to `ssh sky node --input-type=module`.
// Credentials stay inside the remote process; only object/package metadata is printed.
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createHash, createHmac } from 'node:crypto';
import { inflateRawSync, constants } from 'node:zlib';

const pid = execFileSync('systemctl', ['--user', 'show', 'com.train-track-api.api.service', '--property=MainPID', '--value'], { encoding: 'utf8' }).trim();
const environment = Object.fromEntries(readFileSync(`/proc/${pid}/environ`, 'utf8').split('\0').filter(Boolean).map(pair => {
  const separator = pair.indexOf('=');
  return [pair.slice(0, separator), pair.slice(separator + 1)];
}));
const accessKey = environment.TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_ACCESS_KEY;
const secretKey = environment.TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_SECRET_ACCESS_KEY;
if (!accessKey || !secretKey) throw new Error('S3 credentials are not present in the API process environment');
const region = 'eu-west-2';
const host = `traintrack-uk-daily-full-timetable.s3.${region}.amazonaws.com`;
const digest = value => createHash('sha256').update(value).digest('hex');
const hmac = (key, value) => createHmac('sha256', key).update(value).digest();

async function request(key, method, extraHeaders = {}, query = '') {
  const timestamp = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
  const day = timestamp.slice(0, 8);
  const path = `/${encodeURIComponent(key)}`;
  const headers = { host, 'x-amz-content-sha256': digest(''), 'x-amz-date': timestamp, ...extraHeaders };
  const names = Object.keys(headers).sort();
  const signedHeaders = names.join(';');
  const canonicalHeaders = names.map(name => `${name}:${headers[name].trim()}\n`).join('');
  const scope = `${day}/${region}/s3/aws4_request`;
  const canonical = [method, path, query, canonicalHeaders, signedHeaders, digest('')].join('\n');
  const signingKey = hmac(hmac(hmac(hmac(`AWS4${secretKey}`, day), region), 's3'), 'aws4_request');
  const signature = createHmac('sha256', signingKey).update(['AWS4-HMAC-SHA256', timestamp, scope, digest(canonical)].join('\n')).digest('hex');
  headers.authorization = `AWS4-HMAC-SHA256 Credential=${accessKey}/${scope}, SignedHeaders=${signedHeaders}, Signature=${signature}`;
  const response = await fetch(`https://${host}${path}${query ? `?${query}` : ''}`, { method, headers, signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw new Error(`${method} ${key}: HTTP ${response.status}`);
  return response;
}

for (const query of ['list-type=2', 'versions=', 'versioning=']) {
  try {
    const response = await request('', 'GET', {}, query);
    const body = await response.text();
    console.log(JSON.stringify({ bucketQuery: query, status: response.status,
      keys: [...body.matchAll(/<Key>([^<]+)<\/Key>/g)].map(match => match[1]),
      versionCount: [...body.matchAll(/<Version>/g)].length,
      truncated: /<IsTruncated>true<\/IsTruncated>/.test(body),
      versioningStatus: /<Status>([^<]+)<\/Status>/.exec(body)?.[1] ?? null }));
  } catch (error) { console.log(JSON.stringify({ bucketQuery: query, error: error.message })); }
}

function centralDirectory(tail, tailOffset) {
  let end = -1;
  for (let position = tail.length - 22; position >= 0; position--) {
    if (tail.readUInt32LE(position) === 0x06054b50 && position + 22 + tail.readUInt16LE(position + 20) === tail.length) { end = position; break; }
  }
  if (end < 0) throw new Error('ZIP central directory terminator not found');
  const count = tail.readUInt16LE(end + 10);
  const offset = tail.readUInt32LE(end + 16) - tailOffset;
  if (offset < 0) throw new Error('ZIP central directory exceeds diagnostic tail limit');
  const members = [];
  let position = offset;
  for (let index = 0; index < count; index++) {
    if (tail.readUInt32LE(position) !== 0x02014b50) throw new Error('Invalid ZIP central directory record');
    const nameLength = tail.readUInt16LE(position + 28), extraLength = tail.readUInt16LE(position + 30), commentLength = tail.readUInt16LE(position + 32);
    members.push({ name: tail.subarray(position + 46, position + 46 + nameLength).toString('utf8'),
      method: tail.readUInt16LE(position + 10), compressedBytes: tail.readUInt32LE(position + 20),
      bytes: tail.readUInt32LE(position + 24), offset: tail.readUInt32LE(position + 42) });
    position += 46 + nameLength + extraLength + commentLength;
  }
  return members;
}

for (const key of ['timetable_full.zip', 'timetable_update.zip']) {
  const response = await request(key, 'HEAD');
  const bytes = Number(response.headers.get('content-length'));
  const etag = response.headers.get('etag');
  const metadata = { key, bytes, etag, lastModified: response.headers.get('last-modified'), versionId: response.headers.get('x-amz-version-id') };
  const tailOffset = Math.max(0, bytes - 65557);
  const tailResponse = await request(key, 'GET', { range: `bytes=${tailOffset}-${bytes - 1}`, 'if-match': etag });
  const members = centralDirectory(Buffer.from(await tailResponse.arrayBuffer()), tailOffset);
  metadata.members = members;
  metadata.headers = [];
  for (const member of members.filter(value => /(?:\.(?:DAT|MCA|CFA|ZTR)|(?:DAT|MCA|CFA|ZTR)\.txt)$/.test(value.name))) {
    const length = Math.min(member.compressedBytes + 1024, 65536);
    const part = await request(key, 'GET', { range: `bytes=${member.offset}-${member.offset + length - 1}`, 'if-match': etag });
    const buffer = Buffer.from(await part.arrayBuffer());
    if (buffer.readUInt32LE(0) !== 0x04034b50) throw new Error('Invalid local ZIP header');
    const dataOffset = 30 + buffer.readUInt16LE(26) + buffer.readUInt16LE(28);
    const compressed = buffer.subarray(dataOffset, Math.min(dataOffset + member.compressedBytes, buffer.length));
    const data = member.method === 0 ? compressed : inflateRawSync(compressed, { finishFlush: constants.Z_SYNC_FLUSH });
    metadata.headers.push({ member: member.name, preview: /(?:\.DAT|DAT\.txt)$/.test(member.name) ? data.toString('latin1').trim() : data.toString('latin1').split(/\r?\n/, 1)[0] });
  }
  console.log(JSON.stringify(metadata));
}
