import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { PassThrough, Readable } from 'node:stream';
import { HeadObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { TimetableS3Source, objectIdentity, timetableIngestionConfig } from '../lib/planner/ingestion-source.js';

const credentials = {
  TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_ACCESS_KEY: 'test-only-access-key',
  TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_SECRET_ACCESS_KEY: 'test-only-secret-key'
};
const config = { ...timetableIngestionConfig(credentials), maximumArchiveBytes: 1024 };
const object = { kind: 'full', key: 'timetable_full.zip', etag: '"test-etag"', size: 8,
  lastModified: '2026-09-18T14:09:14.000Z', versionId: null };
const headResponse = { ContentLength: object.size, ETag: object.etag, LastModified: new Date(object.lastModified) };
const awsError = (status, name = 'ServiceError') => Object.assign(new Error('upstream diagnostic must not escape'), {
  name, $metadata: { httpStatusCode: status }
});

function source(send) {
  return new TimetableS3Source(config, { client: { send } });
}

async function temporary(t) {
  const directory = await mkdtemp(join(tmpdir(), 'traintrack-ingestion-source-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

test('ingestion auto-enables only with both credentials and an enabled planner, with explicit overrides', () => {
  assert.equal(timetableIngestionConfig({}).enabled, false);
  assert.equal(timetableIngestionConfig({ ...credentials }).enabled, true);
  assert.equal(timetableIngestionConfig({ TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_ACCESS_KEY: 'test-only' }).configured, false);
  assert.equal(timetableIngestionConfig({ TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_SECRET_ACCESS_KEY: 'test-only' }).configured, false);
  assert.equal(timetableIngestionConfig({ ...credentials, PLANNER_ENABLED: 'false' }).enabled, false);
  assert.equal(timetableIngestionConfig({ ...credentials, PLANNER_INGESTION_ENABLED: 'false' }).enabled, false);
  assert.equal(timetableIngestionConfig({ PLANNER_INGESTION_ENABLED: 'true' }).enabled, true);
  assert.equal(timetableIngestionConfig({ PLANNER_ENABLED: 'false', PLANNER_INGESTION_ENABLED: 'true' }).enabled, true);
  assert.throws(() => new TimetableS3Source(timetableIngestionConfig({})), { code: 'CONFIG_INVALID' });
});

test('ingestion has hourly polling and bounded defaults while respecting bucket, region and delivery keys', () => {
  const defaults = timetableIngestionConfig({});
  assert.equal(defaults.intervalSeconds, 3600);
  assert.equal(defaults.maximumArchiveBytes, 512 * 1024 * 1024);
  assert.equal(defaults.timeoutMs, 15 * 60 * 1000);
  assert.equal(defaults.bucket, 'traintrack-uk-daily-full-timetable');
  assert.equal(defaults.region, 'eu-west-2');
  assert.deepEqual(defaults.keys, { full: 'timetable_full.zip', update: 'timetable_update.zip' });
  const custom = timetableIngestionConfig({ TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET: 'test-bucket',
    TRAIN_TRACK_UK_TIMETABLE_S3_REGION: 'eu-west-1', TRAIN_TRACK_UK_TIMETABLE_S3_FULL_KEY: 'monthly/full.zip',
    TRAIN_TRACK_UK_TIMETABLE_S3_UPDATE_KEY: 'daily/update.zip' });
  assert.equal(custom.bucket, 'test-bucket');
  assert.equal(custom.region, 'eu-west-1');
  assert.deepEqual(custom.keys, { full: 'monthly/full.zip', update: 'daily/update.zip' });
});

test('HEAD uses the configured key, bounded cancellation signal and exposes only safe delivery metadata', async () => {
  let request;
  const client = source(async (command, options) => {
    request = { command, options };
    return { ...headResponse, VersionId: 'test-version' };
  });
  const result = await client.head('update');
  assert.ok(request.command instanceof HeadObjectCommand);
  assert.deepEqual(request.command.input, { Bucket: config.bucket, Key: config.keys.update });
  assert.ok(request.options.abortSignal instanceof AbortSignal);
  assert.deepEqual(result, { ...object, kind: 'update', key: config.keys.update, versionId: 'test-version' });
});

test('HEAD distinguishes a genuinely absent delivery from denied access and sanitises upstream errors', async () => {
  for (const kind of ['full', 'update']) {
    assert.equal(await source(async () => { throw awsError(404); }).head(kind), null);
    for (const status of [401, 403]) {
      await assert.rejects(source(async () => { throw awsError(status); }).head(kind), error => {
        assert.equal(error.code, 'S3_ACCESS_DENIED');
        assert.doesNotMatch(error.message, /upstream diagnostic/);
        return true;
      });
    }
    await assert.rejects(source(async () => { throw awsError(503); }).head(kind), { code: 'S3_UNAVAILABLE' });
  }
});

test('HEAD rejects absent metadata and invalid, empty or oversized archive lengths', async () => {
  for (const invalid of [
    { ContentLength: undefined }, { ContentLength: 0 }, { ContentLength: -1 },
    { ContentLength: 1.5 }, { ContentLength: Number.NaN }, { ContentLength: config.maximumArchiveBytes + 1 },
    { ContentLength: Number.MAX_SAFE_INTEGER + 1 }, { ETag: undefined }, { ETag: '' }, { LastModified: undefined }
  ]) {
    await assert.rejects(source(async () => ({ ...headResponse, ...invalid })).head('full'), { code: 'DOWNLOAD_INVALID' });
  }
  const largest = await source(async () => ({ ...headResponse, ContentLength: config.maximumArchiveBytes })).head('full');
  assert.equal(largest.size, config.maximumArchiveBytes);
});

test('conditional GET pins the checked ETag without requiring version permissions and atomically saves exact bytes and hash', async t => {
  const directory = await temporary(t), target = join(directory, 'delivery.zip');
  const bytes = Buffer.from('zipbytes');
  await writeFile(target, 'old delivery');
  let request;
  const result = await source(async (command, options) => {
    request = { command, options };
    return { ETag: object.etag, ContentLength: bytes.length, Body: Readable.from([bytes.subarray(0, 3), bytes.subarray(3)]) };
  }).download({ ...object, versionId: 'test-version' }, target);
  assert.ok(request.command instanceof GetObjectCommand);
  assert.deepEqual(request.command.input, { Bucket: config.bucket, Key: object.key, IfMatch: object.etag });
  assert.ok(request.options.abortSignal instanceof AbortSignal);
  assert.deepEqual(result, { path: target, bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') });
  assert.deepEqual(await readFile(target), bytes);
  assert.equal((await stat(target)).mode & 0o777, 0o600);
  assert.deepEqual(await readdir(directory), ['delivery.zip']);
});

test('GET rejects changed ETag, changed content length or a missing body before touching the target', async t => {
  const directory = await temporary(t), target = join(directory, 'delivery.zip');
  await writeFile(target, 'old delivery');
  for (const invalid of [{ ETag: '"changed"' }, { ContentLength: object.size + 1 }, { Body: null }]) {
    const body = Readable.from([Buffer.from('zipbytes')]);
    await assert.rejects(source(async () => ({ ETag: object.etag, ContentLength: object.size, Body: body, ...invalid }))
      .download(object, target), { code: 'S3_OBJECT_CHANGED' });
    if (invalid.Body !== null) assert.equal(body.destroyed, true);
    assert.equal(await readFile(target, 'utf8'), 'old delivery');
    assert.deepEqual(await readdir(directory), ['delivery.zip']);
  }
});

test('GET converts changed-object preconditions and read failures into safe error codes', async t => {
  const directory = await temporary(t), target = join(directory, 'delivery.zip');
  for (const [status, code] of [[412, 'S3_OBJECT_CHANGED'], [403, 'S3_ACCESS_DENIED'], [404, 'S3_UNAVAILABLE'], [503, 'S3_UNAVAILABLE']]) {
    await assert.rejects(source(async () => { throw awsError(status); }).download(object, target), error => {
      assert.equal(error.code, code);
      assert.doesNotMatch(error.message, /upstream diagnostic/);
      return true;
    });
  }
  assert.deepEqual(await readdir(directory), []);
});

test('truncated and oversized streams are rejected, leave no partial archive and preserve an existing delivery', async t => {
  const directory = await temporary(t), target = join(directory, 'delivery.zip');
  await writeFile(target, 'old delivery');
  for (const chunks of [[Buffer.from('short')], [Buffer.from('zipbytes'), Buffer.from('extra')]]) {
    await assert.rejects(source(async () => ({ ETag: object.etag, ContentLength: object.size, Body: Readable.from(chunks) }))
      .download(object, target), { code: 'DOWNLOAD_INVALID' });
    assert.equal(await readFile(target, 'utf8'), 'old delivery');
    assert.deepEqual(await readdir(directory), ['delivery.zip']);
  }
});

test('stream failures are sanitised and remove the incomplete archive', async t => {
  const directory = await temporary(t), target = join(directory, 'delivery.zip');
  const body = Readable.from((async function* () {
    yield Buffer.from('zip');
    throw new Error('upstream diagnostic must not escape');
  })());
  await assert.rejects(source(async () => ({ ETag: object.etag, ContentLength: object.size, Body: body }))
    .download(object, target), error => {
    assert.equal(error.code, 'DOWNLOAD_INVALID');
    assert.doesNotMatch(error.message, /upstream diagnostic/);
    return true;
  });
  assert.deepEqual(await readdir(directory), []);
});

test('SDK cancellation and timeouts are reported consistently for HEAD and GET', async t => {
  const directory = await temporary(t), target = join(directory, 'delivery.zip');
  for (const name of ['AbortError', 'TimeoutError']) {
    const client = source(async () => { throw Object.assign(new Error('upstream diagnostic must not escape'), { name }); });
    await assert.rejects(client.head('full'), { code: 'CANCELLED' });
    await assert.rejects(client.download(object, target), { code: 'CANCELLED' });
  }
  const controller = new AbortController();
  controller.abort();
  const client = source(async (_command, { abortSignal }) => {
    assert.equal(abortSignal.aborted, true);
    throw Object.assign(new Error('cancelled'), { name: 'AbortError' });
  });
  await assert.rejects(client.head('full', { signal: controller.signal }), { code: 'CANCELLED' });
  await assert.rejects(client.download(object, target, { signal: controller.signal }), { code: 'CANCELLED' });
  assert.deepEqual(await readdir(directory), []);
});

test('cancelling an in-flight stream destroys its body and removes partial bytes without replacing the delivery', async t => {
  const directory = await temporary(t), target = join(directory, 'delivery.zip');
  await writeFile(target, 'old delivery');
  const controller = new AbortController(), body = new PassThrough();
  body.write(Buffer.from('zip'));
  const client = source(async () => {
    setImmediate(() => controller.abort());
    return { ETag: object.etag, ContentLength: object.size, Body: body };
  });
  await assert.rejects(client.download(object, target, { signal: controller.signal }), { code: 'CANCELLED' });
  assert.equal(body.destroyed, true);
  assert.equal(await readFile(target, 'utf8'), 'old delivery');
  assert.deepEqual(await readdir(directory), ['delivery.zip']);
});

test('delivery identity tracks ETag, size and modification time, and closing releases the SDK client', () => {
  assert.match(objectIdentity(object), /^[a-f0-9]{64}$/);
  assert.equal(objectIdentity({ ...object }), objectIdentity(object));
  assert.equal(objectIdentity(null), null);
  for (const change of [{ etag: '"changed"' }, { size: object.size + 1 }, { lastModified: '2026-09-19T14:09:14.000Z' }]) {
    assert.notEqual(objectIdentity({ ...object, ...change }), objectIdentity(object));
  }
  let destroyed = false;
  new TimetableS3Source(config, { client: { destroy() { destroyed = true; } } }).close();
  assert.equal(destroyed, true);
});
