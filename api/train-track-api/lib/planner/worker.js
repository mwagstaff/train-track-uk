import { parentPort, threadId, workerData } from 'node:worker_threads';
import { getHeapStatistics } from 'node:v8';
import { PlannerEngine } from './engine.js';
import { PlannerError, normalizeRequest } from './contract.js';
import { createCooperativeSignal } from './execution.js';
import { PlannerLiveProvider, createLiveRequestBudget } from './live-provider.js';
import { createPlannerTelemetry } from './telemetry.js';
import { londonDate } from './time.js';
import { compileRaptorNetwork } from './raptor-poc.js';

const PREWARM_MIN_HEAP_HEADROOM = 300 * 1024 * 1024;

const upstreamRequests = new Map();
const resumes = new Map();
let requestSequence = 0;

// HTTP shares the parent's host spacing and metrics with existing departures.
function requestUpstream({ signal, ...options }) {
    signal?.throwIfAborted();
    const requestId = `${threadId}:${++requestSequence}`;
    return new Promise((resolve, reject) => {
        const finish = (error, value) => {
            if (!upstreamRequests.delete(requestId)) return;
            signal?.removeEventListener('abort', abort);
            error ? reject(error) : resolve(value);
        };
        const abort = () => {
            parentPort.postMessage({ requestId, cancelUpstream: true });
            finish(signal.reason ?? Object.assign(new Error('Live request cancelled'), { name: 'AbortError' }));
        };
        upstreamRequests.set(requestId, finish);
        signal?.addEventListener('abort', abort, { once: true });
        try { parentPort.postMessage({ requestId, upstream: options }); }
        catch (error) { finish(error); }
    });
}

const engine = new PlannerEngine(workerData, {
    liveProvider: new PlannerLiveProvider({ request: requestUpstream }),
    createLiveBudget: createLiveRequestBudget
});

parentPort.on('message', message => {
    if (message.upstreamResult || message.upstreamError) {
        const error = message.upstreamError && Object.assign(new Error('Live request failed'), {
            code: message.upstreamError.code, name: message.upstreamError.name ?? 'Error',
            ...(message.upstreamError.status ? { response: { status: message.upstreamError.status } } : {})
        });
        upstreamRequests.get(message.requestId)?.(error, message.upstreamResult);
        return;
    }
    if (message.resume) {
        const resume = resumes.get(message.id);
        resumes.delete(message.id);
        resume?.();
        return;
    }
    void run(message);
});

async function run({ id, method, payload, cancelBuffer, execution }) {
    // Network requests must also stop while the worker is awaiting live data.
    // Graph work continues to use the existing synchronous cooperative signal.
    const networkController = new AbortController();
    const cancellation = new Int32Array(cancelBuffer);
    const cancellationTimer = setInterval(() => {
        if (Atomics.load(cancellation, 0)) networkController.abort();
    }, 50);
    cancellationTimer.unref();
    const onTelemetry = telemetry => parentPort.postMessage({ id, telemetry });
    const telemetry = createPlannerTelemetry(onTelemetry);
    let signal;
    const awaitIO = async work => {
        const heap = getHeapStatistics();
        parentPort.postMessage({ id, waitingForIO: true, heapRatio: heap.used_heap_size / heap.heap_size_limit });
        try { return await telemetry.measure('liveLookupMs', work); }
        finally {
            // Rejoin the CPU queue even after cancellation: another operation
            // may own the worker's mutable caches while this one awaits I/O.
            await new Promise(resolve => {
                resumes.set(id, resolve);
                parentPort.postMessage({ id, readyToResume: true });
            });
            signal.resetAccounting();
        }
    };
    try {
        signal = createCooperativeSignal(cancelBuffer, {
            timeoutMs: execution?.timeoutMs ?? workerData.timeoutMs,
            cpuDutyCycle: execution?.cpuDutyCycle ?? 1
        });
        const context = { ...execution, abortSignal: networkController.signal,
            onTelemetry, measure: telemetry.measure, awaitIO,
            onProgress: progress => parentPort.postMessage({ id,
                progress: typeof progress === 'string' ? { phase: progress } : progress }) };
        let result;
        if (method === 'status') result = await engine.status();
        else if (method === 'metadata') result = engine.publicMetadata(await engine.dataset(payload.version), payload.live);
        else if (method === 'stations') result = await engine.stationList(payload.query);
        else if (method === 'search') result = await engine.search(payload, signal, context);
        else if (method === 'clearSearchCache') result = engine.clearSearchCache();
        else if (method === 'savedRoutePlan') result = await engine.savedRoutePlan(payload, signal, context);
        else if (['routeBoardProfile', 'routeBoardProfileChunk', 'routeBoardPreview', 'routeBoardRefresh', 'routeBoardReplan'].includes(method)) {
            result = await engine[method](payload, signal, context);
        }
        else if (method === 'prewarm') result = await telemetry.measure('preparationMs', () => prewarm(signal));
        else if (method === 'journey') result = await engine.journey(payload.id, signal);
        else if (method === 'explain') result = await engine.explain(payload.request, signal);
        else if (method === 'runtime') result = engine.runtime();
        else throw new PlannerError('INVALID_REQUEST', 'Unknown planner operation.');
        telemetry.sample();
        parentPort.postMessage({ id, result });
    } catch (error) {
        const known = error instanceof PlannerError;
        if (!known) console.error('[planner] worker operation failed', method, error.message);
        parentPort.postMessage({ id, error: {
            code: known ? error.code : 'DATASET_UNAVAILABLE',
            message: known ? error.message : 'Journey planning is temporarily unavailable.',
            status: known ? error.status : 503,
            ...(known && error.reason ? { reason: error.reason } : {})
        } });
    } finally { clearInterval(cancellationTimer); }
}

// The parent schedules warming through its queue only while completely idle.
// No worker timer can race a real search across an asynchronous preparation.
let warmed = null;
async function prewarm(signal) {
    if (!workerData.prewarm) return { warmed: false };
    const today = londonDate(engine.now());
    const repo = await engine.dataset();
    if (warmed?.date === today && warmed.version === repo.version) return { warmed: false };
    const stats = getHeapStatistics();
    if (stats.heap_size_limit - stats.used_heap_size < PREWARM_MIN_HEAP_HEADROOM) return { warmed: false };
    const [origin, destination] = repo.stations;
    if (!origin || !destination) return { warmed: false };
    const query = time => engine.checkQuery(repo, normalizeRequest({ origin: origin.crs, destination: destination.crs,
        time: new Date(time).toISOString(), timeType: 'departAfter' }));
    // A daytime search's range (yesterday to tomorrow) covers most searches;
    // later ranges resolve their extra date on demand to bound worker memory.
    const network = await engine.network(repo, query(Date.parse(`${today}T12:00:00Z`)), signal);
    const check = () => {
        if (signal.aborted) throw new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499);
    };
    (await import('./router.js')).prepareNetwork(network, check);
    if (engine.raptorIndex?.network !== network) {
        const index = compileRaptorNetwork(network, { check });
        check();
        engine.raptorIndex = { network, index };
    }
    warmed = { date: today, version: repo.version };
    return { warmed: true };
}
