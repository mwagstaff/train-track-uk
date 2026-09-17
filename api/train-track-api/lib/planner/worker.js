import { parentPort, workerData } from 'node:worker_threads';
import { PlannerEngine } from './engine.js';
import { PlannerError } from './contract.js';
import { createCooperativeSignal } from './execution.js';

const engine = new PlannerEngine(workerData);
parentPort.on('message', async ({ id, method, payload, cancelBuffer, execution }) => {
    // Network requests must also stop while the worker is awaiting live data.
    // Graph work continues to use the existing synchronous cooperative signal.
    const networkController = new AbortController();
    const cancellation = new Int32Array(cancelBuffer);
    const cancellationTimer = setInterval(() => {
        if (Atomics.load(cancellation, 0)) networkController.abort();
    }, 50);
    cancellationTimer.unref();
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
            ...(execution ? { onProgress: phase => parentPort.postMessage({ id, progress: { phase } }) } : {})
        });
        else if (['routeBoardProfile', 'routeBoardRefresh', 'routeBoardReplan'].includes(method)) result = await engine[method](payload, signal, {
            ...execution, abortSignal: networkController.signal,
            ...(execution ? { onProgress: phase => parentPort.postMessage({ id, progress: { phase } }) } : {})
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
    } finally { clearInterval(cancellationTimer); }
});
