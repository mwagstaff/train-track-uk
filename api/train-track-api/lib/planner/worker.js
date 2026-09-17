import { parentPort, workerData } from 'node:worker_threads';
import { getHeapStatistics } from 'node:v8';
import { PlannerEngine } from './engine.js';
import { PlannerError, normalizeRequest } from './contract.js';
import { createCooperativeSignal } from './execution.js';
import { londonDate } from './time.js';

const PREWARM_DELAY_MS = 2000;
const PREWARM_CHECK_MS = 60000;
const PREWARM_MIN_HEAP_HEADROOM = 300 * 1024 * 1024;

const engine = new PlannerEngine(workerData);
let busy = false;
parentPort.on('message', async ({ id, method, payload, cancelBuffer, execution }) => {
    // Network requests must also stop while the worker is awaiting live data.
    // Graph work continues to use the existing synchronous cooperative signal.
    const networkController = new AbortController();
    const cancellation = new Int32Array(cancelBuffer);
    const cancellationTimer = setInterval(() => {
        if (Atomics.load(cancellation, 0)) networkController.abort();
    }, 50);
    cancellationTimer.unref();
    busy = true;
    try {
        const signal = createCooperativeSignal(cancelBuffer, {
            timeoutMs: execution?.timeoutMs ?? workerData.timeoutMs,
            cpuDutyCycle: execution?.cpuDutyCycle ?? 1
        });
        let result;
        if (method === 'status') result = await engine.status();
        else if (method === 'metadata') result = engine.publicMetadata(await engine.dataset(payload.version), payload.live);
        else if (method === 'stations') result = await engine.stationList(payload.query);
        else if (method === 'search') result = await engine.search(payload, signal, {
            ...execution,
            abortSignal: networkController.signal,
            onTelemetry: telemetry => parentPort.postMessage({ id, telemetry }),
            ...(execution ? { onProgress: phase => parentPort.postMessage({ id, progress: { phase } }) } : {})
        });
        else if (['routeBoardProfile', 'routeBoardRefresh', 'routeBoardReplan'].includes(method)) result = await engine[method](payload, signal, {
            ...execution, abortSignal: networkController.signal,
            ...(execution ? { onProgress: progress => parentPort.postMessage({ id,
                progress: typeof progress === 'string' ? { phase: progress } : progress }) } : {})
        });
        else if (method === 'journey') result = await engine.journey(payload.id, signal);
        else if (method === 'explain') result = await engine.explain(payload.request, signal);
        else if (method === 'runtime') result = engine.runtime();
        else throw new PlannerError('INVALID_REQUEST', 'Unknown planner operation.');
        parentPort.postMessage({ id, result });
    } catch (error) {
        const known = error instanceof PlannerError;
        if (!known) console.error('[planner] worker operation failed', method, error.message);
        parentPort.postMessage({ id, error: {
            code: known ? error.code : 'DATASET_UNAVAILABLE',
            message: known ? error.message : 'Journey planning is temporarily unavailable.',
            status: known ? error.status : 503
        } });
    } finally { busy = false; clearInterval(cancellationTimer); }
});

// The first search of a day otherwise pays for resolving its dates and building
// the national index. Warm today's default range once the worker is idle, and
// again when the London date or the active timetable changes.
let warmed = null;
async function prewarm() {
    if (busy) return;
    const today = londonDate(engine.now());
    let repo;
    try { repo = await engine.dataset(); } catch { return; }
    if (warmed?.date === today && warmed.version === repo.version) return;
    const stats = getHeapStatistics();
    if (stats.heap_size_limit - stats.used_heap_size < PREWARM_MIN_HEAP_HEADROOM) return;
    const [origin, destination] = repo.stations;
    if (!origin || !destination) return;
    try {
        const query = time => engine.checkQuery(repo, normalizeRequest({ origin: origin.crs, destination: destination.crs,
            time: new Date(time).toISOString(), timeType: 'departAfter' }));
        // A daytime search's range (yesterday to tomorrow) covers most searches;
        // later ranges resolve their extra date on demand to bound worker memory.
        const network = await engine.network(repo, query(Date.parse(`${today}T12:00:00Z`)));
        (await import('./router.js')).prepareNetwork(network);
        warmed = { date: today, version: repo.version };
    } catch (error) {
        if (!(error instanceof PlannerError)) console.error('[planner] pre-warm failed', error.message);
    }
}
if (workerData.prewarm) {
    setTimeout(prewarm, PREWARM_DELAY_MS).unref();
    setInterval(prewarm, PREWARM_CHECK_MS).unref();
}
