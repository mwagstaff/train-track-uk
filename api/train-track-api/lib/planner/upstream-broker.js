// RailData requests are also spaced 100 ms apart per host. At typical provider
// latency four requests in flight reach that pace; two left most of it unused.
export const LIVE_CONCURRENCY = 4;

const cancelled = () => Object.assign(new Error('Planner upstream request cancelled'), {
    name: 'AbortError', code: 'ERR_CANCELED'
});

function ordered(value) {
    if (Array.isArray(value)) return value.map(ordered);
    return value && typeof value === 'object'
        ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
}

async function requestUpstream(options) {
    const { getWithRetry } = await import('../upstream-api-client.js');
    return getWithRetry(options);
}

/** Share the live request limit across routing workers. Only concurrent
 * identical requests share work; observations stay in worker caches. */
export class PlannerUpstreamBroker {
    constructor({ request = requestUpstream, concurrency = LIVE_CONCURRENCY } = {}) {
        this.performRequest = request;
        this.concurrency = concurrency;
        this.inflight = new Map();
        this.active = new Set();
        this.queue = [];
        this.closed = false;
    }

    request(options, { signal } = {}) {
        if (this.closed || signal?.aborted) return Promise.reject(cancelled());
        const key = JSON.stringify(ordered(options));
        let flight = this.inflight.get(key);
        if (!flight) {
            flight = { key, options, controller: new AbortController(), consumers: new Set() };
            this.inflight.set(key, flight);
            this.queue.push(flight);
        }
        const promise = new Promise((resolve, reject) => {
            const consumer = { finish: (error, value) => {
                if (!flight.consumers.delete(consumer)) return;
                signal?.removeEventListener('abort', abort);
                if (!flight.done && !flight.consumers.size) {
                    flight.controller.abort();
                    if (this.inflight.get(key) === flight) this.inflight.delete(key);
                    this.queue = this.queue.filter(value => value !== flight);
                }
                error ? reject(error) : resolve(value);
            } };
            const abort = () => consumer.finish(cancelled());
            flight.consumers.add(consumer);
            signal?.addEventListener('abort', abort, { once: true });
        });
        this.pump();
        return promise;
    }

    pump() {
        while (!this.closed && this.active.size < this.concurrency && this.queue.length) {
            const flight = this.queue.shift();
            this.active.add(flight);
            void this.run(flight);
        }
    }

    async run(flight) {
        let error, result;
        try {
            result = await this.performRequest({ ...flight.options, signal: flight.controller.signal });
        } catch (failure) { error = failure; }
        flight.done = true;
        if (this.inflight.get(flight.key) === flight) this.inflight.delete(flight.key);
        // An aborted request holds its slot until the physical request settles.
        this.active.delete(flight);
        for (const consumer of flight.consumers) consumer.finish(error, result);
        this.pump();
    }

    close() {
        if (this.closed) return;
        this.closed = true;
        for (const flight of this.inflight.values()) {
            flight.controller.abort();
            for (const consumer of flight.consumers) consumer.finish(cancelled());
        }
        this.inflight.clear();
        this.queue = [];
    }
}
