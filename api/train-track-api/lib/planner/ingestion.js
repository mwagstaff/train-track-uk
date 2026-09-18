import { createReadStream } from 'node:fs';
import { mkdir, readFile, writeFile, rename, rm, readdir, stat, statfs } from 'node:fs/promises';
import { join, resolve, dirname } from 'node:path';
import { hostname, tmpdir } from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { TimetableS3Source, timetableIngestionConfig, objectIdentity, ingestionError } from './ingestion-source.js';
import { inspectSource } from './source.js';
import { bootstrapDelivery, applyDeliveryUpdate, readDeliveryMetadata, nextDeliverySequence } from './delivery-store.js';
import { importFullSnapshot, activateDataset, getActiveDataset } from './repository.js';
import { acquireOwnedLock } from './ingestion-lock.js';

async function optionalJson(path) {
    try { return JSON.parse(await readFile(path, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
}
async function atomicJson(path, value) {
    const temporary = `${path}.${randomUUID()}`;
    try {
        await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
        await rename(temporary, path);
    } finally { await rm(temporary, { force: true }); }
}
async function fileHash(path, signal) {
    const hash = createHash('sha256');
    for await (const chunk of createReadStream(path)) { signal?.throwIfAborted(); hash.update(chunk); }
    return hash.digest('hex');
}
function digest(value) { return createHash('sha256').update(value).digest('hex'); }

// A live process is never evicted based on elapsed time. A crashed local worker
// can be recovered; unrecognised/remote owners require an operator to inspect.
export async function acquireIngestionLock(dataDirectory) {
    const lock = await acquireOwnedLock(join(dataDirectory, '.ingestion.lock'), { message: 'Another timetable ingestion owns the data directory.' });
    return lock.release;
}

async function activeSummary(dataDirectory) {
    const pointer = await getActiveDataset(dataDirectory);
    if (!pointer) return null;
    const metadata = await optionalJson(join(pointer.path, 'metadata.json'));
    return { ...pointer, metadata, validation: await optionalJson(join(pointer.path, 'validation.json')),
        baselineSequence: metadata?.delivery?.baselineSequence ?? metadata?.source?.sequence,
        currentSequence: metadata?.delivery?.sequence ?? metadata?.source?.sequence };
}

async function cachedArchive(source, object, root, options) {
    const path = join(root, 'archives', `${object.kind}-${objectIdentity(object)}.zip`);
    const receiptPath = `${path}.json`;
    const receipt = await optionalJson(receiptPath);
    if (receipt && receipt.identity === objectIdentity(object)) {
        try {
            if ((await stat(path)).size === object.size && await fileHash(path, options.signal) === receipt.sha256) {
                return { path, sha256: receipt.sha256, bytes: 0 };
            }
        } catch (error) { if (options.signal?.aborted) throw error; }
    }
    await ensureStagingSpace(root);
    const downloaded = await source.download(object, path, options);
    await atomicJson(receiptPath, { identity: objectIdentity(object), sha256: downloaded.sha256 });
    return downloaded;
}

async function ensureStagingSpace(root) {
    // ZIP extraction uses the OS temporary filesystem, which may differ from
    // persistent storage. Check before downloading/extracting, not afterwards.
    for (const path of [root, tmpdir()]) {
        const free = await statfs(path);
        if (Number(free.bavail) * Number(free.bsize) < 8 * 1024 ** 3) {
            throw ingestionError('INGESTION_FAILED', 'Timetable staging needs at least 8 GiB free on its data and temporary filesystems.');
        }
    }
}

async function recoverStaging(root, onProgress) {
    let removed = 0;
    for (const kind of ['canonical', 'snapshots']) {
        const directory = join(root, kind);
        for (const name of await readdir(directory)) {
            if (!/^[a-f0-9]{64}\.import\.lock$/.test(name)) continue;
            const lockPath = join(directory, name);
            const owner = await optionalJson(lockPath).catch(() => null);
            if (owner?.hostname !== hostname() || !Number.isSafeInteger(owner.pid) || owner.pid <= 0) continue;
            try { process.kill(owner.pid, 0); continue; }
            catch (error) { if (error.code !== 'ESRCH') continue; }
            const lock = await acquireOwnedLock(lockPath, { stagingTarget: lockPath.slice(0, -'.import.lock'.length) });
            await lock.release();
            removed++;
        }
    }
    const directory = join(root, 'archives');
    for (const name of await readdir(directory)) {
        if (/^(full|update)-[a-f0-9]{64}\.zip\.partial-[a-f0-9-]{36}$/.test(name)) {
            await rm(join(directory, name)); removed++;
        }
    }
    if (removed) onProgress?.({ phase: 'recovery', removedGeneratedPartialStores: removed, recoverable: false });
}

async function canonicalCandidate(sourcePath, target, baseline, options) {
    try {
        const metadata = await readDeliveryMetadata(target);
        return { path: target, fullSourcePath: join(target, 'full'), metadata };
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
    const free = await statfs(dirname(target));
    if (Number(free.bavail) * Number(free.bsize) < 3 * 1024 ** 3) {
        throw ingestionError('INGESTION_FAILED', 'Timetable staging needs at least 3 GiB of free disk space.');
    }
    return baseline ? applyDeliveryUpdate(baseline.path, sourcePath, target, options) : bootstrapDelivery(sourcePath, target, options);
}

function boundedCode(error) {
    if (error.name === 'AbortError' || error.name === 'TimeoutError') return 'CANCELLED';
    const known = new Set(['S3_ACCESS_DENIED', 'S3_UNAVAILABLE', 'S3_OBJECT_CHANGED', 'DOWNLOAD_INVALID',
        'UPDATE_GAP', 'UPDATE_TARGET_MISSING', 'VALIDATION_FAILED', 'ACTIVATION_BLOCKED',
        'CONFIG_INVALID', 'INGESTION_FAILED', 'CANCELLED', 'LOCKED']);
    return known.has(error.code) ? error.code : 'INVALID_DELIVERY';
}

// Prune only this worker's private, generated stores. Manual snapshots/raw
// inputs are never touched. Keep three managed snapshots plus the active and
// immediate rollback pointers, and every canonical store they depend upon.
async function pruneManagedStores(dataDirectory, remote, options) {
    const root = join(dataDirectory, 'deliveries');
    const activationLockPath = join(dataDirectory, '.activation.lock');
    let lock;
    try { lock = await acquireOwnedLock(activationLockPath); }
    catch (error) { if (error.code === 'LOCKED') return; throw error; }
    let removed = 0;
    try {
        const pointer = await getActiveDataset(dataDirectory);
        const snapshots = [];
        for (const entry of await readdir(join(root, 'snapshots'), { withFileTypes: true })) {
            if (!entry.isDirectory() || !/^[a-f0-9]{64}$/.test(entry.name)) continue;
            const path = join(root, 'snapshots', entry.name), metadata = await optionalJson(join(path, 'metadata.json'));
            if (metadata?.delivery?.managed === true) snapshots.push({ path, metadata });
        }
        snapshots.sort((a, b) => b.metadata.importedAt.localeCompare(a.metadata.importedAt));
        const keep = new Set(snapshots.slice(0, 3).map(item => item.path));
        for (const path of [pointer?.path, pointer?.previousPath]) if (path) keep.add(resolve(path));
        const canonicalKeep = new Set();
        for (const path of keep) {
            const metadata = await optionalJson(join(path, 'metadata.json'));
            if (metadata?.delivery?.canonicalPath) canonicalKeep.add(resolve(metadata.delivery.canonicalPath));
        }
        const removedPaths = new Set();
        for (const snapshot of snapshots) {
            options.signal?.throwIfAborted();
            if (!keep.has(snapshot.path)) { await rm(snapshot.path, { recursive: true }); removedPaths.add(snapshot.path); removed++; }
        }
        if (removedPaths.size) {
            const historyPath = join(dataDirectory, 'activation-history.json');
            const history = await optionalJson(historyPath);
            if (history) await atomicJson(historyPath, history.filter(item => !removedPaths.has(resolve(item.path))));
        }
        const canonicals = [];
        for (const entry of await readdir(join(root, 'canonical'), { withFileTypes: true })) {
            if (!entry.isDirectory() || !/^[a-f0-9]{64}$/.test(entry.name)) continue;
            const path = join(root, 'canonical', entry.name), metadata = await optionalJson(join(path, 'metadata.json'));
            if (metadata?.schemaVersion === 1 && metadata.canonicalHash) canonicals.push({ path, metadata });
        }
        canonicals.sort((a, b) => b.metadata.importedAt.localeCompare(a.metadata.importedAt));
        for (const item of canonicals.slice(0, 2)) canonicalKeep.add(item.path); // Failed/dry-run candidates remain retryable.
        for (const item of canonicals) {
            if (!canonicalKeep.has(item.path)) { await rm(item.path, { recursive: true }); removed++; }
        }
        const archiveDirectory = join(root, 'archives');
        const archives = [];
        for (const name of await readdir(archiveDirectory)) {
            if (!/^(full|update)-[a-f0-9]{64}\.zip$/.test(name)) continue;
            const path = join(archiveDirectory, name), receipt = await optionalJson(`${path}.json`);
            if (receipt?.sha256) archives.push({ path, mtime: (await stat(path)).mtimeMs });
        }
        archives.sort((a, b) => b.mtime - a.mtime);
        const archiveKeep = new Set(archives.slice(0, 4).map(item => item.path));
        for (const object of Object.values(remote)) if (object) archiveKeep.add(join(archiveDirectory, `${object.kind}-${objectIdentity(object)}.zip`));
        for (const item of archives) {
            if (!archiveKeep.has(item.path)) { await rm(item.path); await rm(`${item.path}.json`, { force: true }); removed++; }
        }
    } finally { await lock.release(); }
    if (removed) options.onProgress?.({ phase: 'retention', removedGeneratedStores: removed, recoverable: false });
}

export async function syncTimetable({ config = timetableIngestionConfig(), source, dryRun = false, signal, onProgress } = {}) {
    const directory = resolve(config.dataDirectory), root = join(directory, 'deliveries');
    const release = await acquireIngestionLock(directory);
    const started = Date.now(), options = { signal, onProgress };
    let state, ownedSource;
    try {
        const previous = await optionalJson(join(directory, 'ingestion-state.json')).catch(() => null);
        state = { ...(previous?.schemaVersion === 1 ? previous : {}), schemaVersion: 1,
            enabled: config.enabled, inProgress: true, intervalSeconds: config.intervalSeconds,
            lastCheckAt: new Date().toISOString(), lastErrorCode: null, lastDownloadBytes: 0, worker: { pid: process.pid, hostname: hostname() },
            active: await activeSummary(directory) };
        if (!dryRun) await atomicJson(join(directory, 'ingestion-state.json'), state);
        if (config.datasetPath) throw ingestionError('CONFIG_INVALID', 'Unset PLANNER_DATASET_PATH before enabling managed ingestion; it pins searches to a fixed snapshot.');
        if (!source) { ownedSource = source = new TimetableS3Source(config); }
        signal?.throwIfAborted();
        const [full, update] = await Promise.all([source.head('full', options), source.head('update', options)]);
        state.remote = { full, update };
        if (!full) throw ingestionError('INVALID_DELIVERY', 'The required full timetable object is missing.');
        state.lastSuccessfulCheckAt = new Date().toISOString();
        for (const name of ['canonical', 'snapshots', 'archives']) await mkdir(join(root, name), { recursive: true });
        await recoverStaging(root, onProgress);
        if (!dryRun) await pruneManagedStores(directory, state.remote, options);

        const initialActive = state.active;
        let candidate = null, fullArchiveSha256 = initialActive?.metadata?.delivery?.fullArchiveSha256;
        const committed = initialActive?.metadata?.delivery;
        if (committed?.canonicalPath) {
            const metadata = await readDeliveryMetadata(committed.canonicalPath);
            if (metadata.sequence !== committed.sequence || metadata.canonicalHash !== committed.canonicalHash) {
                throw ingestionError('INVALID_DELIVERY', 'Active snapshot and its canonical timetable commit disagree.');
            }
            candidate = { path: committed.canonicalPath, fullSourcePath: join(committed.canonicalPath, 'full'), metadata };
        }
        let baselineSequence = committed?.baselineSequence;
        let appliedRemote = committed?.remote ?? {};
        if (!candidate || objectIdentity(full) !== objectIdentity(appliedRemote.full)) {
            const archive = await cachedArchive(source, full, root, options);
            state.lastDownloadBytes += archive.bytes;
            if (!candidate || archive.sha256 !== fullArchiveSha256) {
                await ensureStagingSpace(root);
                const inspected = await inspectSource(archive.path, options);
                if (inspected.feedMode !== 'full') throw ingestionError('INVALID_DELIVERY', 'The full object must contain a complete MCA package.');
                const currentDate = candidate?.metadata.generationDate ?? initialActive?.metadata?.source?.generationDate;
                if (!currentDate || inspected.generationDate >= currentDate) {
                    // Do not replace an effective daily snapshot by an older
                    // monthly baseline just because its S3 object was uploaded.
                    if (candidate && inspected.generationDate === currentDate && inspected.sequence !== candidate.metadata.sequence) {
                        throw ingestionError('INVALID_DELIVERY', 'Monthly and active delivery sequences conflict on the same publication date.');
                    }
                    const target = join(root, 'canonical', digest(`full\0${inspected.contentHash}`));
                    candidate = await canonicalCandidate(archive.path, target, null, options);
                    baselineSequence = candidate.metadata.sequence;
                    fullArchiveSha256 = archive.sha256;
                    appliedRemote = { full, update: null };
                }
            }
        }
        if (!candidate) throw ingestionError('INVALID_DELIVERY', 'Monthly delivery is older than the active snapshot; a current full baseline is required to initialise safe daily imports.');
        state.pendingGap = null;
        if (update && objectIdentity(update) !== objectIdentity(appliedRemote.update)) {
            const archive = await cachedArchive(source, update, root, options);
            state.lastDownloadBytes += archive.bytes;
            await ensureStagingSpace(root);
            const inspected = await inspectSource(archive.path, options);
            if (inspected.feedMode !== 'update') throw ingestionError('INVALID_DELIVERY', 'The daily object must contain a CFA update package.');
            if (inspected.generationDate === candidate.metadata.generationDate && inspected.sequence !== candidate.metadata.sequence) {
                throw ingestionError('INVALID_DELIVERY', 'Daily and active delivery sequences conflict on the same publication date.');
            }
            if (inspected.generationDate > candidate.metadata.generationDate) {
                if (inspected.sequence !== nextDeliverySequence(candidate.metadata.sequence)) {
                    state.pendingGap = { expectedSequence: nextDeliverySequence(candidate.metadata.sequence), actualSequence: inspected.sequence,
                        missingCount: (Number(inspected.sequence) - Number(nextDeliverySequence(candidate.metadata.sequence)) + 999) % 999 };
                } else {
                    const target = join(root, 'canonical', digest(`update\0${candidate.metadata.canonicalHash}\0${inspected.contentHash}`));
                    candidate = await canonicalCandidate(archive.path, target, candidate, options);
                    appliedRemote = { ...appliedRemote, update };
                }
            } else if (inspected.generationDate === candidate.metadata.generationDate && candidate.metadata.source.feedMode === 'update'
                && inspected.contentHash !== candidate.metadata.contentHash) {
                throw ingestionError('INVALID_DELIVERY', 'Daily payload changed without a new sequence/publication date.');
            }
        }
        let activated = false, snapshot;
        if (candidate.metadata.canonicalHash !== committed?.canonicalHash) {
            const delivery = { managed: true, canonicalPath: candidate.path, canonicalHash: candidate.metadata.canonicalHash,
                sequence: candidate.metadata.sequence, baselineSequence, fullArchiveSha256, remote: appliedRemote };
            try { snapshot = await importFullSnapshot(candidate.fullSourcePath, join(root, 'snapshots', candidate.metadata.canonicalHash), { ...options, delivery }); }
            catch (error) {
                if (signal?.aborted || boundedCode(error) === 'CANCELLED') throw ingestionError('CANCELLED', 'Timetable import was cancelled or timed out.');
                throw ingestionError('VALIDATION_FAILED', `Compact timetable import/validation failed: ${error.message}`);
            }
            signal?.throwIfAborted();
            if (!dryRun) {
                try { await activateDataset(snapshot.path, directory, { expectedPreviousVersion: initialActive?.version ?? null, relocateSameVersion: true }); }
                catch (error) { throw ingestionError('ACTIVATION_BLOCKED', error.message); }
                activated = true;
                state.lastSuccessAt = state.lastActivatedAt = new Date().toISOString();
                state.active = await activeSummary(directory);
            }
        }
        state.lastResult = state.pendingGap ? 'gap' : activated ? 'activated' : 'unchanged';
        state.lastErrorCode = state.pendingGap ? 'UPDATE_GAP' : null;
        state.inProgress = false;
        state.lastDurationMs = Date.now() - started;
        if (!dryRun) {
            await atomicJson(join(directory, 'ingestion-state.json'), state);
            try { await pruneManagedStores(directory, state.remote, options); }
            catch { onProgress?.({ phase: 'retention', warning: 'Generated-store cleanup deferred; inspect free disk space.' }); }
        }
        return { result: state.lastResult, dryRun, activated, pendingGap: state.pendingGap,
            activeVersion: state.active?.version ?? null, candidateVersion: snapshot?.version ?? null,
            sequence: candidate.metadata.sequence, baselineSequence, durationMs: state.lastDurationMs,
            downloadBytes: state.lastDownloadBytes };
    } catch (error) {
        if (state && !dryRun) {
            state.inProgress = false;
            state.lastResult = 'error';
            state.lastErrorCode = boundedCode(error);
            state.lastDurationMs = Date.now() - started;
            // Activation is the commit: recover its summary even if the process
            // failed between active.json rename and the observational state save.
            state.active = await activeSummary(directory).catch(() => state.active);
            await atomicJson(join(directory, 'ingestion-state.json'), state);
            if (state.remote) {
                try { await pruneManagedStores(directory, state.remote, { onProgress }); }
                catch { onProgress?.({ phase: 'retention', warning: 'Generated-store cleanup deferred; inspect free disk space.' }); }
            }
        }
        throw Object.assign(error, { code: boundedCode(error) });
    } finally { ownedSource?.close(); await release(); }
}
