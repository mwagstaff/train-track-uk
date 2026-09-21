import { mkdir, open, readFile, rm, readdir, stat } from 'node:fs/promises';
import { dirname, basename, join } from 'node:path';
import { hostname } from 'node:os';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const run = promisify(execFile);
const EMPTY_LOCK_GRACE_MS = 10 * 60 * 1000;

async function owner(path) {
    try { return JSON.parse(await readFile(path, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT' || error instanceof SyntaxError) return null; throw error; }
}
function isDead(value) {
    if (value?.hostname !== hostname() || !Number.isSafeInteger(value.pid) || value.pid <= 0) return false;
    try { process.kill(value.pid, 0); return false; }
    catch (error) { return error.code === 'ESRCH'; }
}

async function recoverable(path) {
    const value = await owner(path);
    if (isDead(value)) return true;
    if (value !== null) return false;
    // A crash between O_EXCL creation and writing the owner leaves an empty
    // lock. Reclaim it only after a grace period, and only when lsof can prove
    // no process still holds the file open. Other unknown locks fail closed.
    let details;
    try { details = await stat(path); }
    catch (error) { if (error.code === 'ENOENT') return false; throw error; }
    if (!details.isFile() || details.size !== 0 || Date.now() - details.mtimeMs < EMPTY_LOCK_GRACE_MS) return false;
    try { await run('lsof', ['-n', '-F', 'p', '--', path], { timeout: 5000 }); return false; }
    catch (error) { return error.code === 1 && !error.stdout; }
}

// Recovery is serialised separately, then re-checks the owner. Two callers
// cannot both unlink a stale lock and accidentally evict the new live owner.
// Unknown/remote locks (including an interrupted recovery) fail closed.
export async function acquireOwnedLock(path, { message = 'Another timetable process owns this lock.', stagingTarget } = {}) {
    await mkdir(dirname(path), { recursive: true });
    const locked = () => Object.assign(new Error(message), { code: 'LOCKED' });
    let handle, recovered = false;
    try { handle = await open(path, 'wx', 0o600); }
    catch (error) {
        if (error.code !== 'EEXIST') throw error;
        if (!await recoverable(path)) throw locked();
        const recoveryPath = `${path}.recovery`, recovery = await open(recoveryPath, 'wx', 0o600).catch(error => {
            if (error.code === 'EEXIST') throw locked();
            throw error;
        });
        try {
            await recovery.writeFile(JSON.stringify({ pid: process.pid, hostname: hostname() }));
            if (!await recoverable(path)) throw locked();
            await rm(path);
            try { handle = await open(path, 'wx', 0o600); }
            catch (error) { if (error.code === 'EEXIST') throw locked(); throw error; }
            recovered = true;
        } finally { await recovery.close(); await rm(recoveryPath); }
    }
    const token = randomUUID();
    const release = async () => {
        await handle.close();
        if ((await owner(path))?.token === token) await rm(path);
    };
    try {
        await handle.writeFile(JSON.stringify({ pid: process.pid, hostname: hostname(), token, startedAt: new Date().toISOString() }));
        if (recovered && stagingTarget) {
            const prefix = `${basename(stagingTarget)}.building-`;
            for (const entry of await readdir(dirname(stagingTarget), { withFileTypes: true })) {
                if (entry.isDirectory() && entry.name.startsWith(prefix) && /^[A-Za-z0-9-]{6,36}$/.test(entry.name.slice(prefix.length))) {
                    await rm(join(dirname(stagingTarget), entry.name), { recursive: true });
                }
            }
        }
        return { release, recovered };
    } catch (error) { await release(); throw error; }
}
