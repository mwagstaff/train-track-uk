import { Worker } from 'node:worker_threads';
import os from 'node:os';
import path from 'node:path';
import { PlannerError, normalizeRequest, decodeCursor } from './contract.js';

const defaultWorkerURL = new URL('./worker.js', import.meta.url);

export function plannerConfig(env = process.env) {
    function number(name, fallback, min, max) {
        const value = Number(env[name] ?? fallback);
        return Number.isFinite(value) && value >= min && value <= max ? value : fallback;
    }
    return {
        dataDirectory: path.resolve(env.PLANNER_DATA_DIR || path.join(os.homedir(), '.local/share/train-track-api/planner')),
        datasetPath: env.PLANNER_DATASET_PATH ? path.resolve(env.PLANNER_DATASET_PATH) : null,
        enabled: env.PLANNER_ENABLED !== 'false',
        // Prototype defaults for the agreed monthly full-feed cadence; configure before production.
        warnAgeDays: number('PLANNER_WARN_AGE_DAYS', 35, 1, 365),
        maxStaleDays: number('PLANNER_MAX_STALE_DAYS', 45, 1, 365),
        timeoutMs: number('PLANNER_TIMEOUT_MS', 30000, 100, 120000),
        maxQueue: number('PLANNER_MAX_QUEUE', 8, 1, 100),
        maxOldGenerationSizeMb: number('PLANNER_HEAP_MB', 1024, 128, 8192),
        dateCacheSize: number('PLANNER_DATE_CACHE_SIZE', 6, 1, 14),
        // Broader long-distance searches need more graph work; elapsed time and
        // worker heap remain independently capped at 30 seconds and 1024 MB.
        maxOperations: number('PLANNER_MAX_OPERATIONS', 10000000, 1000, 100000000),
        jobTimeoutMs: number('PLANNER_JOB_TIMEOUT_MS', 600000, 1000, 900000),
        jobQueueTimeoutMs: number('PLANNER_JOB_QUEUE_TIMEOUT_MS', 480000, 1000, 900000),
        jobMaxOperations: number('PLANNER_JOB_MAX_OPERATIONS', 1000000000, 1000, 2000000000),
        jobCpuDutyCycle: number('PLANNER_JOB_CPU_DUTY_CYCLE', 0.5, 0.1, 1),
        maxSearchJobs: number('PLANNER_MAX_SEARCH_JOBS', 8, 1, 32)
    };
}

// One long-lived worker: bounded admission, no CPU work or SQLite dependency on Express's event loop.
export class PlannerService {
    constructor(config = plannerConfig(), { workerURL = defaultWorkerURL, metadataOnly = false } = {}) {
        this.config = config;
        this.workerURL = workerURL;
        this.worker = null;
        this.queue = [];
        this.active = null;
        this.sequence = 0;
        this.closed = false;
        this.metadataOnly = metadataOnly;
        this.standardWorker = workerURL.href === defaultWorkerURL.href;
        this.metadataService = null;
        this.journeys = new Map();
    }

    metadata() {
        if (!this.metadataService) this.metadataService = new PlannerService({ ...this.config,
            timeoutMs: 5000, maxQueue: 16, maxOldGenerationSizeMb: 256
        }, { metadataOnly: true });
        return this.metadataService;
    }

    status(options) {
        return this.standardWorker && !this.metadataOnly
            ? this.metadata().call('status', {}, options) : this.call('status', {}, options);
    }
    stations(query, options) {
        if (typeof query !== 'string' || query.length > 100) {
            return Promise.reject(new PlannerError('INVALID_REQUEST', 'Station search must be at most 100 characters.'));
        }
        return this.standardWorker && !this.metadataOnly
            ? this.metadata().call('stations', { query }, options) : this.call('stations', { query }, options);
    }
    search(body, options) {
        try {
            const payload = body?.cursor === undefined
                ? { request: normalizeRequest(body) } : decodeCursor(body.cursor);
            return this.call('search', payload, options);
        } catch (error) { return Promise.reject(error); }
    }
    async journey(id, options) {
        if (typeof id !== 'string' || !/^[a-f0-9]{64}\.[a-f0-9]{32}$/.test(id)) {
            return Promise.reject(new PlannerError('JOURNEY_EXPIRED', 'This journey has expired. Please search again.', 410));
        }
        if (!this.standardWorker) return this.call('journey', { id }, options);
        const cached = this.journeys.get(id);
        if (!cached || Date.now() - cached.at > 3600000) {
            this.journeys.delete(id);
            throw new PlannerError('JOURNEY_EXPIRED', 'This journey has expired. Please search again.', 410);
        }
        const dataset = await this.metadata().call('metadata', { version: cached.version }, options);
        return { journey: cached.journey, dataset };
    }

    call(method, payload, { signal, execution, onStart, onProgress, queueTimeoutMs } = {}) {
        if (this.closed) return Promise.reject(new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is unavailable.', 503));
        if (signal?.aborted) return Promise.reject(new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499));
        if (this.queue.length + Number(Boolean(this.active)) >= this.config.maxQueue) {
            return Promise.reject(new PlannerError('SEARCH_BUSY', 'Journey planning is busy. Please try again shortly.', 429));
        }
        return new Promise((resolve, reject) => {
            const job = { id: ++this.sequence, method, payload, resolve, reject, signal,
                cancelBuffer: new SharedArrayBuffer(4), settled: false, execution, onStart, onProgress };
            job.abort = () => this.cancel(job, new PlannerError('SEARCH_CANCELLED', 'Search cancelled.', 499));
            job.timer = setTimeout(() => this.cancel(job,
                new PlannerError('SEARCH_TIMEOUT', 'The search took too long. Please try again.', 504)),
            execution ? (queueTimeoutMs ?? this.config.jobQueueTimeoutMs) : this.config.timeoutMs);
            signal?.addEventListener('abort', job.abort, { once: true });
            this.queue.push(job);
            this.pump();
        });
    }

    settle(job, error, result) {
        if (job.settled) return;
        job.settled = true;
        clearTimeout(job.timer);
        job.signal?.removeEventListener('abort', job.abort);
        if (!error && job.method === 'search' && result?.dataset) {
            for (const journey of result.journeys ?? []) {
                this.journeys.delete(journey.id);
                this.journeys.set(journey.id, { journey, version: result.dataset.version, at: Date.now() });
            }
            while (this.journeys.size > 500) this.journeys.delete(this.journeys.keys().next().value);
        }
        error ? job.reject(error) : job.resolve(result);
    }

    cancel(job, error) {
        if (job.settled) return;
        Atomics.store(new Int32Array(job.cancelBuffer), 0, 1);
        this.settle(job, error);
        this.queue = this.queue.filter(item => item !== job);
        if (this.active === job) {
            // Also bound non-cooperative work, such as a blocked SQLite call.
            job.killTimer = setTimeout(() => {
                if (this.active === job) this.resetWorker(error);
            }, 1000);
        }
    }

    startWorker() {
        const worker = new Worker(this.workerURL, {
            workerData: this.config,
            resourceLimits: { maxOldGenerationSizeMb: this.config.maxOldGenerationSizeMb }
        });
        this.worker = worker;
        worker.on('message', message => {
            if (worker !== this.worker || message.id !== this.active?.id) return;
            const job = this.active;
            if (message.progress) { job.onProgress?.(message.progress); return; }
            clearTimeout(job.killTimer);
            this.active = null;
            this.settle(job, message.error
                ? new PlannerError(message.error.code, message.error.message, message.error.status) : null, message.result);
            this.pump();
        });
        worker.on('error', error => {
            console.error('Planner worker failed:', error.code || error.name);
            if (worker === this.worker) this.resetWorker(new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is temporarily unavailable.', 503));
        });
        worker.on('exit', () => {
            if (worker === this.worker) this.resetWorker(new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is temporarily unavailable.', 503));
        });
    }

    pump() {
        if (this.active || this.closed) return;
        const job = this.queue.shift();
        if (!job) { this.worker?.unref(); return; }
        try {
            if (!this.worker) this.startWorker();
            this.worker.ref();
            this.active = job;
            if (job.execution) {
                clearTimeout(job.timer);
                job.timer = setTimeout(() => this.cancel(job,
                    new PlannerError('SEARCH_TIMEOUT', 'This search could not finish within the available processing time. Please try a different time.', 504)), job.execution.timeoutMs);
            }
            job.onStart?.();
            this.worker.postMessage({ id: job.id, method: job.method, payload: job.payload,
                cancelBuffer: job.cancelBuffer, execution: job.execution });
        } catch {
            this.active = job;
            this.resetWorker(new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is unavailable on this server.', 503));
        }
    }

    resetWorker(error) {
        const worker = this.worker;
        this.worker = null;
        if (this.active) {
            clearTimeout(this.active.killTimer);
            this.settle(this.active, error);
            this.active = null;
        }
        // Fail admitted work explicitly; a later request may restart the worker.
        for (const job of this.queue.splice(0)) this.settle(job, error);
        worker?.terminate().catch(() => {});
    }

    close() {
        this.closed = true;
        this.searchJobs?.close();
        this.metadataService?.close();
        this.journeys.clear();
        this.resetWorker(new PlannerError('DATASET_UNAVAILABLE', 'Journey planning is closed.', 503));
    }
}
