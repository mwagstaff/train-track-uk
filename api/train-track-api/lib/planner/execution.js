import { isMainThread } from 'node:worker_threads';
import { PlannerError } from './contract.js';

const ACCOUNTING_INTERVAL_MS = 10;
const MAX_WAIT_MS = 25;

function threadCpuMilliseconds() {
    // Node >=23.9 exposes current-worker CPU time, independently of Express.
    // https://nodejs.org/docs/latest-v24.x/api/process.html#processthreadcpuusagepreviousvalue
    // Earlier planner runtimes conservatively account elapsed active wall time.
    if (typeof process.threadCpuUsage !== 'function') return null;
    const usage = process.threadCpuUsage();
    return (usage.user + usage.system) / 1000;
}

function workerWait(cancelled, duration) {
    if (isMainThread) throw new Error('Planner CPU throttling must run in a worker thread');
    Atomics.wait(cancelled, 0, 0, duration);
}

/** Cooperatively limit this worker's CPU duty cycle without pausing Express.
 * Native synchronous work (notably one SQLite statement) cannot pause until the
 * next checkpoint. Account for that work afterwards; this is not an OS CPU cap.
 * Injectable clocks/waiting make cancellation and duty bounds deterministic in tests.
 */
export function createCooperativeSignal(cancelBuffer, { timeoutMs, cpuDutyCycle = 1 } = {}, {
    now = () => performance.now(), cpuTime = threadCpuMilliseconds, wait = workerWait
} = {}) {
    if (!Number.isFinite(cpuDutyCycle) || cpuDutyCycle <= 0 || cpuDutyCycle > 1) throw new RangeError('cpuDutyCycle must be greater than zero and at most one');
    if (timeoutMs !== undefined && (!Number.isFinite(timeoutMs) || timeoutMs <= 0)) throw new RangeError('timeoutMs must be a positive finite number');
    if (cpuDutyCycle < 1 && wait === workerWait && isMainThread) throw new Error('Planner CPU throttling must run in a worker thread');
    const cancelled = new Int32Array(cancelBuffer);
    const started = now();
    const deadline = timeoutMs === undefined ? Infinity : started + timeoutMs;
    let lastWall = started;
    let lastCpu = cpuDutyCycle < 1 ? cpuTime() : null;
    function checkDeadline(time) {
        if (time >= deadline) throw new PlannerError('SEARCH_TIMEOUT', 'The search exceeded its execution time budget.', 504);
    }
    return {
        // A parked operation shares this thread with other searches. Their CPU
        // time must not be charged to it when it regains the execution slot.
        // The original deadline and shared cancellation flag remain unchanged.
        resetAccounting() {
            lastWall = now();
            lastCpu = cpuDutyCycle < 1 ? cpuTime() : null;
        },
        get aborted() {
            if (Atomics.load(cancelled, 0) !== 0) return true;
            let time = now();
            checkDeadline(time);
            if (cpuDutyCycle === 1 || time - lastWall < ACCOUNTING_INTERVAL_MS) return false;
            const currentCpu = cpuTime();
            const elapsed = time - lastWall;
            const active = lastCpu === null || currentCpu === null ? elapsed : Math.max(0, currentCpu - lastCpu);
            // Idle time already spent awaiting I/O counts toward this interval,
            // but is never banked to permit a later unthrottled CPU burst.
            const restUntil = time + Math.max(0, active / cpuDutyCycle - elapsed);
            while (time < restUntil) {
                if (Atomics.load(cancelled, 0) !== 0) return true;
                checkDeadline(time);
                wait(cancelled, Math.min(MAX_WAIT_MS, restUntil - time, deadline - time));
                time = now();
            }
            if (Atomics.load(cancelled, 0) !== 0) return true;
            checkDeadline(time);
            lastWall = time;
            lastCpu = cpuTime();
            return false;
        }
    };
}
