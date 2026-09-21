import { S3Client, HeadObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { createWriteStream } from 'node:fs';
import { mkdir, rename, rm } from 'node:fs/promises';
import { dirname } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { plannerConfig } from './service.js';

export function ingestionError(code, message, details = {}) {
    return Object.assign(new Error(message), { code, ...details });
}

export function timetableIngestionConfig(env = process.env) {
    const planner = plannerConfig(env);
    const configured = Boolean(env.TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_ACCESS_KEY && env.TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_SECRET_ACCESS_KEY);
    return {
        // Service role must be deliberate: credentials alone never start the
        // importer on a gateway or warm-standby host.
        enabled: env.PLANNER_INGESTION_ENABLED === 'true',
        configured, dataDirectory: planner.dataDirectory, datasetPath: planner.datasetPath,
        bucket: env.TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET || 'traintrack-uk-daily-full-timetable',
        region: env.TRAIN_TRACK_UK_TIMETABLE_S3_REGION || 'eu-west-2',
        keys: {
            full: env.TRAIN_TRACK_UK_TIMETABLE_S3_FULL_KEY || 'timetable_full.zip',
            update: env.TRAIN_TRACK_UK_TIMETABLE_S3_UPDATE_KEY || 'timetable_update.zip'
        },
        intervalSeconds: 3600,
        maximumArchiveBytes: 512 * 1024 * 1024,
        timeoutMs: 15 * 60 * 1000
    };
}

export function objectIdentity(object) {
    return object && createHash('sha256').update(JSON.stringify([object.etag, object.size, object.lastModified])).digest('hex');
}

function safeS3Error(error) {
    if (error.name === 'AbortError' || error.name === 'TimeoutError') return ingestionError('CANCELLED', 'Timetable download was cancelled or timed out.');
    const status = error.$metadata?.httpStatusCode;
    if (status === 401 || status === 403) return ingestionError('S3_ACCESS_DENIED', 'S3 denied timetable access; check the bucket credentials and read permissions.');
    if (status === 412) return ingestionError('S3_OBJECT_CHANGED', 'S3 delivery changed during download; retry the next check.');
    return ingestionError('S3_UNAVAILABLE', 'The timetable bucket could not be read.');
}

export class TimetableS3Source {
    constructor(config = timetableIngestionConfig(), { client, env = process.env } = {}) {
        this.config = config;
        if (!client && !config.configured) throw ingestionError('CONFIG_INVALID', 'Both timetable S3 credential variables are required.');
        this.client = client || new S3Client({
            region: config.region, maxAttempts: 3,
            credentials: {
                accessKeyId: env.TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_ACCESS_KEY,
                secretAccessKey: env.TRAIN_TRACK_UK_TIMETABLE_S3_BUCKET_SECRET_ACCESS_KEY
            }
        });
    }

    async head(kind, { signal } = {}) {
        let result;
        try {
            result = await this.client.send(new HeadObjectCommand({ Bucket: this.config.bucket, Key: this.config.keys[kind] }), {
                abortSignal: signal ? AbortSignal.any([signal, AbortSignal.timeout(60_000)]) : AbortSignal.timeout(60_000)
            });
        } catch (error) {
            // S3 returns 403, not 404, for a missing object without ListBucket.
            // Never misclassify that as an absent optional update.
            if (error.$metadata?.httpStatusCode === 404) return null;
            throw safeS3Error(error);
        }
        const size = result.ContentLength, lastModified = result.LastModified?.toISOString();
        if (!result.ETag || !lastModified || !Number.isSafeInteger(size) || size <= 0 || size > this.config.maximumArchiveBytes) {
            throw ingestionError('DOWNLOAD_INVALID', 'Timetable object metadata is missing or exceeds the archive size limit.');
        }
        return { kind, key: this.config.keys[kind], etag: result.ETag, size, lastModified, versionId: result.VersionId || null };
    }

    async download(object, targetPath, { signal } = {}) {
        const abortSignal = signal ? AbortSignal.any([signal, AbortSignal.timeout(300_000)]) : AbortSignal.timeout(300_000);
        let response;
        try {
            // IfMatch pins the bytes without requiring GetObjectVersion rights.
            response = await this.client.send(new GetObjectCommand({ Bucket: this.config.bucket, Key: object.key, IfMatch: object.etag }), { abortSignal });
        } catch (error) { throw safeS3Error(error); }
        if (response.ETag !== object.etag || response.ContentLength !== object.size || !response.Body) {
            response.Body?.destroy?.();
            throw ingestionError('S3_OBJECT_CHANGED', 'Timetable object no longer matches its checked metadata.');
        }
        await mkdir(dirname(targetPath), { recursive: true });
        const temporary = `${targetPath}.partial-${randomUUID()}`;
        const hash = createHash('sha256');
        let bytes = 0;
        const limiter = new Transform({ transform(chunk, encoding, callback) {
            bytes += chunk.length;
            if (bytes > object.size) callback(ingestionError('DOWNLOAD_INVALID', 'Timetable download exceeded its expected size.'));
            else { hash.update(chunk); callback(null, chunk); }
        } });
        try {
            await pipeline(response.Body, limiter, createWriteStream(temporary, { flags: 'wx', mode: 0o600 }), { signal: abortSignal });
            if (bytes !== object.size) throw ingestionError('DOWNLOAD_INVALID', 'Timetable download was truncated.');
            await rename(temporary, targetPath);
            return { path: targetPath, bytes, sha256: hash.digest('hex') };
        } catch (error) {
            if (error.code === 'DOWNLOAD_INVALID') throw error;
            if (abortSignal.aborted) throw ingestionError('CANCELLED', 'Timetable download was cancelled or timed out.');
            throw ingestionError('DOWNLOAD_INVALID', 'Timetable archive could not be downloaded safely.');
        } finally { await rm(temporary, { force: true }); }
    }

    close() { this.client.destroy?.(); }
}
