import crypto from 'crypto';
import fs from 'fs/promises';
import path from 'path';

const MILLISECONDS_PER_DAY = 24 * 60 * 60 * 1000;
const ROTATED_LOG_SUFFIX = /^\d{4}-\d{2}-\d{2}(?:\.\d+)?$/;

export const DEFAULT_SUBSCRIPTION_AUDIT_LOG_RETENTION_DAYS = 30;

const operationQueues = new Map();
const maintenanceTimers = new Map();

export function appendSubscriptionAuditLogEvent(event, options = {}) {
    const logPath = resolveLogPath(options.logPath);
    return enqueue(logPath, async () => {
        const now = resolveNow(options.now);
        const retentionDays = resolveRetentionDays(options.retentionDays);
        await maintainSubscriptionAuditLogUnlocked(logPath, { now, retentionDays });
        if (typeof options.shouldAppend === 'function' && !options.shouldAppend()) {
            return false;
        }
        await fs.mkdir(path.dirname(logPath), { recursive: true });
        await fs.appendFile(logPath, `${JSON.stringify(event)}\n`, 'utf8');
        return true;
    });
}

export function maintainSubscriptionAuditLog(options = {}) {
    const logPath = resolveLogPath(options.logPath);
    return enqueue(logPath, () => maintainSubscriptionAuditLogUnlocked(logPath, {
        now: resolveNow(options.now),
        retentionDays: resolveRetentionDays(options.retentionDays)
    }));
}

export async function startSubscriptionAuditLogMaintenance(options = {}) {
    const logPath = resolveLogPath(options.logPath);
    const existingTimer = maintenanceTimers.get(logPath);
    if (existingTimer) return existingTimer;

    const retentionDays = resolveRetentionDays(options.retentionDays);
    const intervalMs = resolvePositiveNumber(options.intervalMs, MILLISECONDS_PER_DAY);
    const onError = typeof options.onError === 'function'
        ? options.onError
        : (error) => console.error('[admin] Failed to maintain subscription audit log:', error?.message || error);
    const runMaintenance = () => maintainSubscriptionAuditLog({ logPath, retentionDays }).catch(onError);

    await maintainSubscriptionAuditLog({ logPath, retentionDays, now: options.now }).catch(onError);
    const timer = setInterval(runMaintenance, intervalMs);
    timer.unref?.();
    maintenanceTimers.set(logPath, timer);
    return timer;
}

export function deleteSubscriptionAuditEventsForDevice(deviceId, options = {}) {
    const normalizedDeviceId = typeof deviceId === 'string' ? deviceId.trim() : '';
    if (!normalizedDeviceId) {
        throw new Error('deviceId is required');
    }

    const logPath = resolveLogPath(options.logPath);
    const identifiers = {
        deviceId: normalizedDeviceId,
        subscriptionIds: normalizeIdentifierSet(options.subscriptionIds),
        activityIds: normalizeIdentifierSet(options.activityIds)
    };
    return enqueue(logPath, async () => {
        const now = resolveNow(options.now);
        const retentionDays = resolveRetentionDays(options.retentionDays);
        await maintainSubscriptionAuditLogUnlocked(logPath, { now, retentionDays });

        const logFiles = await listSubscriptionAuditLogFiles(logPath);
        const result = {
            deletedCount: 0,
            filesUpdated: 0,
            malformedLineCount: 0
        };

        for (const filePath of logFiles) {
            const fileResult = await deleteDeviceEventsFromFile(filePath, logPath, identifiers);
            result.deletedCount += fileResult.deletedCount;
            result.filesUpdated += fileResult.updated ? 1 : 0;
            result.malformedLineCount += fileResult.malformedLineCount;
        }

        return result;
    });
}

async function maintainSubscriptionAuditLogUnlocked(logPath, { now, retentionDays }) {
    const activeLogStat = await statIfExists(logPath);
    const startOfToday = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());

    if (activeLogStat?.size > 0 && activeLogStat.mtimeMs < startOfToday) {
        const rotatedPath = await nextRotatedLogPath(logPath, activeLogStat.mtime);
        await fs.rename(logPath, rotatedPath);
    }

    const cutoff = now.getTime() - (retentionDays * MILLISECONDS_PER_DAY);
    const rotatedLogPaths = await listRotatedSubscriptionAuditLogFiles(logPath);
    await Promise.all(rotatedLogPaths.map(async (rotatedPath) => {
        const stat = await statIfExists(rotatedPath);
        if (stat && stat.mtimeMs <= cutoff) {
            await fs.unlink(rotatedPath);
        }
    }));
}

async function deleteDeviceEventsFromFile(filePath, activeLogPath, identifiers) {
    const stat = await statIfExists(filePath);
    if (!stat) {
        return { deletedCount: 0, updated: false, malformedLineCount: 0 };
    }

    const contents = await fs.readFile(filePath, 'utf8');
    const keptLines = [];
    let deletedCount = 0;
    let malformedLineCount = 0;

    for (const line of contents.split('\n')) {
        if (!line.trim()) continue;
        try {
            const event = JSON.parse(line);
            if (containsDeletionIdentifier(event, identifiers)) {
                deletedCount += 1;
            } else {
                keptLines.push(line);
            }
        } catch {
            malformedLineCount += 1;
            if (lineContainsDeletionIdentifier(line, identifiers)) {
                deletedCount += 1;
            } else {
                keptLines.push(line);
            }
        }
    }

    if (deletedCount === 0) {
        return { deletedCount, updated: false, malformedLineCount };
    }

    if (keptLines.length === 0 && filePath !== activeLogPath) {
        await fs.unlink(filePath);
    } else {
        const updatedContents = keptLines.length > 0 ? `${keptLines.join('\n')}\n` : '';
        await replaceFilePreservingTimestamps(filePath, updatedContents, stat);
    }

    return { deletedCount, updated: true, malformedLineCount };
}

function lineContainsDeletionIdentifier(line, identifiers) {
    return [
        identifiers.deviceId,
        ...identifiers.subscriptionIds,
        ...identifiers.activityIds
    ].some((identifier) => identifier && line.includes(identifier));
}

async function replaceFilePreservingTimestamps(filePath, contents, originalStat) {
    const tempPath = path.join(
        path.dirname(filePath),
        `.${path.basename(filePath)}.${process.pid}.${crypto.randomUUID()}.tmp`
    );

    try {
        await fs.writeFile(tempPath, contents, { encoding: 'utf8', mode: originalStat.mode });
        await fs.utimes(tempPath, originalStat.atime, originalStat.mtime);
        await fs.rename(tempPath, filePath);
    } catch (error) {
        await fs.rm(tempPath, { force: true }).catch(() => {});
        throw error;
    }
}

function containsDeletionIdentifier(value, identifiers, parentKey = null) {
    if (!value || typeof value !== 'object') return false;
    if (Array.isArray(value)) {
        return value.some((entry) => containsDeletionIdentifier(entry, identifiers, parentKey));
    }

    return Object.entries(value).some(([key, entry]) => {
        if ((key === 'device_id' || key === 'deviceId') && typeof entry === 'string') {
            return entry.trim() === identifiers.deviceId;
        }
        if ((key === 'subscription_id' || key === 'subscriptionId') && typeof entry === 'string') {
            return identifiers.subscriptionIds.has(entry.trim());
        }
        if ((key === 'activity_id' || key === 'activityId') && typeof entry === 'string') {
            return identifiers.activityIds.has(entry.trim());
        }
        if (key === 'id' && isSubscriptionSnapshotKey(parentKey) && typeof entry === 'string') {
            return identifiers.subscriptionIds.has(entry.trim());
        }
        return containsDeletionIdentifier(entry, identifiers, key);
    });
}

function isSubscriptionSnapshotKey(key) {
    return key === 'before' || key === 'after' || key === 'subscription';
}

function normalizeIdentifierSet(value) {
    const entries = value instanceof Set ? [...value] : Array.isArray(value) ? value : [];
    return new Set(entries
        .filter((entry) => typeof entry === 'string')
        .map((entry) => entry.trim())
        .filter(Boolean));
}

async function listSubscriptionAuditLogFiles(logPath) {
    const files = [];
    if (await statIfExists(logPath)) files.push(logPath);
    files.push(...await listRotatedSubscriptionAuditLogFiles(logPath));
    return files;
}

async function listRotatedSubscriptionAuditLogFiles(logPath) {
    const directory = path.dirname(logPath);
    const baseName = path.basename(logPath);
    let entries;
    try {
        entries = await fs.readdir(directory, { withFileTypes: true });
    } catch (error) {
        if (error?.code === 'ENOENT') return [];
        throw error;
    }

    return entries
        .filter((entry) => entry.isFile())
        .filter((entry) => {
            if (!entry.name.startsWith(`${baseName}.`)) return false;
            return ROTATED_LOG_SUFFIX.test(entry.name.slice(baseName.length + 1));
        })
        .map((entry) => path.join(directory, entry.name))
        .sort();
}

async function nextRotatedLogPath(logPath, modifiedAt) {
    const dateSuffix = modifiedAt.toISOString().slice(0, 10);
    const basePath = `${logPath}.${dateSuffix}`;
    let candidate = basePath;
    let sequence = 1;
    while (await statIfExists(candidate)) {
        candidate = `${basePath}.${sequence}`;
        sequence += 1;
    }
    return candidate;
}

function enqueue(logPath, operation) {
    const previous = operationQueues.get(logPath) || Promise.resolve();
    const result = previous.catch(() => {}).then(operation);
    operationQueues.set(logPath, result);
    result.then(
        () => clearQueue(logPath, result),
        () => clearQueue(logPath, result)
    );
    return result;
}

function clearQueue(logPath, operation) {
    if (operationQueues.get(logPath) === operation) {
        operationQueues.delete(logPath);
    }
}

async function statIfExists(filePath) {
    try {
        return await fs.stat(filePath);
    } catch (error) {
        if (error?.code === 'ENOENT') return null;
        throw error;
    }
}

function resolveLogPath(logPath) {
    const configuredPath = logPath || process.env.SUBSCRIPTION_AUDIT_LOG_PATH || 'subscription-audit.log';
    return path.resolve(configuredPath);
}

function resolveRetentionDays(value) {
    return resolvePositiveNumber(
        value ?? process.env.SUBSCRIPTION_AUDIT_LOG_RETENTION_DAYS,
        DEFAULT_SUBSCRIPTION_AUDIT_LOG_RETENTION_DAYS
    );
}

function resolvePositiveNumber(value, fallback) {
    const number = Number(value);
    return Number.isFinite(number) && number > 0 ? number : fallback;
}

function resolveNow(value) {
    const now = value instanceof Date ? value : new Date(value || Date.now());
    if (!Number.isFinite(now.getTime())) {
        throw new Error('now must be a valid date');
    }
    return now;
}
