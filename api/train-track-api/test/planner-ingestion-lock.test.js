import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, open, readFile, rm, stat, utimes, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { acquireOwnedLock } from '../lib/planner/ingestion-lock.js';

const run = promisify(execFile);

test('only an old, unopened empty lock is recovered', async t => {
    try { await run('lsof', ['-v']); }
    catch (error) { if (error.code === 'ENOENT') return t.skip('lsof is unavailable'); }
    const directory = await mkdtemp(join(tmpdir(), 'planner-empty-lock-'));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const path = join(directory, '.activation.lock');
    const held = await open(path, 'wx');
    t.after(() => held.close());
    const old = new Date(Date.now() - 20 * 60 * 1000);
    await utimes(path, old, old);
    await assert.rejects(acquireOwnedLock(path), { code: 'LOCKED' });
    await held.close();
    const lock = await acquireOwnedLock(path);
    assert.equal(lock.recovered, true);
    await lock.release();
    await assert.rejects(stat(path), { code: 'ENOENT' });
});

test('recent empty and old malformed locks remain protected', async t => {
    const directory = await mkdtemp(join(tmpdir(), 'planner-unknown-lock-'));
    t.after(() => rm(directory, { recursive: true, force: true }));
    const path = join(directory, '.activation.lock');
    await writeFile(path, '');
    await assert.rejects(acquireOwnedLock(path), { code: 'LOCKED' });
    await writeFile(path, 'malformed-owner');
    const old = new Date(Date.now() - 20 * 60 * 1000);
    await utimes(path, old, old);
    await assert.rejects(acquireOwnedLock(path), { code: 'LOCKED' });
    assert.equal(await readFile(path, 'utf8'), 'malformed-owner');
});
