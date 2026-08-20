import assert from 'node:assert/strict';
import fs from 'fs/promises';
import os from 'os';
import path from 'path';
import test from 'node:test';

import {
    appendSubscriptionAuditLogEvent,
    deleteSubscriptionAuditEventsForDevice,
    maintainSubscriptionAuditLog,
    startSubscriptionAuditLogMaintenance
} from '../lib/subscription-audit-log.js';

const now = new Date('2026-08-20T12:00:00.000Z');

test('rotates the previous UTC day and removes archives at the 30-day boundary', async (t) => {
    const directory = await createTempDirectory(t);
    const logPath = path.join(directory, 'subscription-audit.log');
    const previousDay = new Date('2026-08-19T20:00:00.000Z');
    const recentArchivePath = `${logPath}.2026-08-10`;
    const expiredArchivePath = `${logPath}.2026-07-21`;

    await writeLog(logPath, [{ id: 'previous-day' }], previousDay);
    await writeLog(recentArchivePath, [{ id: 'recent' }], new Date('2026-08-10T12:00:00.000Z'));
    await writeLog(expiredArchivePath, [{ id: 'expired' }], new Date('2026-07-21T12:00:00.000Z'));

    await appendSubscriptionAuditLogEvent({ id: 'current' }, { logPath, now });

    assert.deepEqual(await readJsonLines(logPath), [{ id: 'current' }]);
    assert.deepEqual(await readJsonLines(`${logPath}.2026-08-19`), [{ id: 'previous-day' }]);
    assert.deepEqual(await readJsonLines(recentArchivePath), [{ id: 'recent' }]);
    await assert.rejects(fs.stat(expiredArchivePath), { code: 'ENOENT' });
});

test('maintenance rotates and prunes without appending a new event', async (t) => {
    const directory = await createTempDirectory(t);
    const logPath = path.join(directory, 'subscription-audit.log');
    const oldDate = new Date('2026-07-01T12:00:00.000Z');

    await writeLog(logPath, [{ id: 'too-old' }], oldDate);

    await maintainSubscriptionAuditLog({ logPath, now });

    await assert.rejects(fs.stat(logPath), { code: 'ENOENT' });
    await assert.rejects(fs.stat(`${logPath}.2026-07-01`), { code: 'ENOENT' });
});

test('startup maintenance prunes immediately and leaves an unrefed timer', async (t) => {
    const directory = await createTempDirectory(t);
    const logPath = path.join(directory, 'subscription-audit.log');
    const oldDate = new Date('2026-07-01T12:00:00.000Z');
    await writeLog(logPath, [{ id: 'too-old' }], oldDate);

    const timer = await startSubscriptionAuditLogMaintenance({
        logPath,
        now,
        intervalMs: 60_000
    });
    t.after(() => clearInterval(timer));

    assert.equal(timer.hasRef?.(), false);
    await assert.rejects(fs.stat(logPath), { code: 'ENOENT' });
});

test('device deletion scrubs active and rotated logs while retaining unrelated and malformed rows', async (t) => {
    const directory = await createTempDirectory(t);
    const logPath = path.join(directory, 'subscription-audit.log');
    const partialArchivePath = `${logPath}.2026-08-19`;
    const emptiedArchivePath = `${logPath}.2026-08-18`;
    const targetDeviceId = 'installation-target';

    await fs.writeFile(logPath, [
        JSON.stringify({ id: 'active-target', device_id: targetDeviceId }),
        JSON.stringify({ id: 'active-other', device_id: 'other' }),
        `{"device_id":"${targetDeviceId}"`,
        '{malformed',
        ''
    ].join('\n'));
    await fs.utimes(logPath, now, now);
    await writeLog(partialArchivePath, [
        { id: 'nested-target', before: { deviceId: targetDeviceId } },
        { id: 'archive-other', subscription: { deviceId: 'other' } }
    ], new Date('2026-08-19T12:00:00.000Z'));
    await writeLog(emptiedArchivePath, [
        { id: 'only-target', metadata: { device_id: targetDeviceId } }
    ], new Date('2026-08-18T12:00:00.000Z'));

    const result = await deleteSubscriptionAuditEventsForDevice(targetDeviceId, { logPath, now });

    assert.deepEqual(result, {
        deletedCount: 4,
        filesUpdated: 3,
        malformedLineCount: 2
    });
    assert.deepEqual(await readJsonLines(logPath), [
        { id: 'active-other', device_id: 'other' },
        '{malformed'
    ]);
    assert.deepEqual(await readJsonLines(partialArchivePath), [
        { id: 'archive-other', subscription: { deviceId: 'other' } }
    ]);
    await assert.rejects(fs.stat(emptiedArchivePath), { code: 'ENOENT' });
});

test('device deletion also matches known subscription and activity identifiers', async (t) => {
    const directory = await createTempDirectory(t);
    const logPath = path.join(directory, 'subscription-audit.log');

    await writeLog(logPath, [
        { id: 'audit-1', device_id: null, subscription_id: 'subscription-target' },
        { id: 'audit-2', device_id: null, before: { id: 'subscription-nested' } },
        { id: 'audit-3', device_id: null, metadata: { activityId: 'activity-target' } },
        { id: 'subscription-target', device_id: null },
        { id: 'audit-other', device_id: null, subscription_id: 'subscription-other' }
    ], now);
    await fs.appendFile(logPath, '{"subscription_id":"subscription-target"\n');

    const result = await deleteSubscriptionAuditEventsForDevice('installation-target', {
        logPath,
        now,
        subscriptionIds: new Set(['subscription-target', 'subscription-nested']),
        activityIds: ['activity-target']
    });

    assert.equal(result.deletedCount, 4);
    assert.equal(result.malformedLineCount, 1);
    assert.deepEqual(await readJsonLines(logPath), [
        { id: 'subscription-target', device_id: null },
        { id: 'audit-other', device_id: null, subscription_id: 'subscription-other' }
    ]);
});

test('append and device deletion operations execute in call order on the same log', async (t) => {
    const directory = await createTempDirectory(t);
    const logPath = path.join(directory, 'subscription-audit.log');

    const appendTarget = appendSubscriptionAuditLogEvent(
        { id: 'target', device_id: 'installation-target' },
        { logPath, now }
    );
    const deleteTarget = deleteSubscriptionAuditEventsForDevice(
        'installation-target',
        { logPath, now }
    );
    const appendOther = appendSubscriptionAuditLogEvent(
        { id: 'other', device_id: 'installation-other' },
        { logPath, now }
    );

    await Promise.all([appendTarget, deleteTarget, appendOther]);

    assert.deepEqual(await readJsonLines(logPath), [
        { id: 'other', device_id: 'installation-other' }
    ]);
});

test('append eligibility is rechecked inside the file operation queue', async (t) => {
    const directory = await createTempDirectory(t);
    const logPath = path.join(directory, 'subscription-audit.log');
    let shouldAppend = true;

    const append = appendSubscriptionAuditLogEvent(
        { id: 'late-device-event', device_id: 'installation-target' },
        { logPath, now, shouldAppend: () => shouldAppend }
    );
    shouldAppend = false;

    assert.equal(await append, false);
    await assert.rejects(fs.stat(logPath), { code: 'ENOENT' });
});

async function createTempDirectory(t) {
    const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'subscription-audit-log-'));
    t.after(() => fs.rm(directory, { recursive: true, force: true }));
    return directory;
}

async function writeLog(filePath, entries, modifiedAt) {
    await fs.writeFile(filePath, `${entries.map((entry) => JSON.stringify(entry)).join('\n')}\n`);
    await fs.utimes(filePath, modifiedAt, modifiedAt);
}

async function readJsonLines(filePath) {
    const contents = await fs.readFile(filePath, 'utf8');
    return contents
        .split('\n')
        .filter(Boolean)
        .map((line) => {
            try {
                return JSON.parse(line);
            } catch {
                return line;
            }
        });
}
