// Measurements are deltas so a logical search can span several worker tasks.
// Heap/RSS values are sampled high-water marks, not allocator-level maxima.
export function createPlannerTelemetry(emit = () => {}) {
    const sample = () => {
        const memory = process.memoryUsage();
        emit({ resourcePeaks: { heapUsedBytes: memory.heapUsed, rssBytes: memory.rss } });
    };
    const measure = async (name, work) => {
        const started = performance.now();
        const cpu = typeof process.threadCpuUsage === 'function' ? process.threadCpuUsage() : null;
        try { return await work(); }
        finally {
            const elapsed = performance.now() - started;
            const used = cpu && process.threadCpuUsage(cpu);
            emit({ metricsDelta: { [name]: elapsed,
                ...(used && name !== 'liveLookupMs' ? { cpuMs: (used.user + used.system) / 1000 } : {}) } });
            sample();
        }
    };
    return { measure, sample };
}
