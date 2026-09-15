#!/usr/bin/env node
import { parseArgs } from 'node:util';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { plannerConfig, PlannerService } from '../lib/planner/service.js';
import { MAX_CHANGES } from '../lib/planner/contract.js';

const controller = new AbortController();
process.once('SIGINT', () => controller.abort());
process.once('SIGTERM', () => controller.abort());
let service;
try {
    const command = process.argv[2];
    const { values } = parseArgs({ args: process.argv.slice(3), options: {
        source: { type: 'string' }, staging: { type: 'string' }, dataset: { type: 'string' },
        'data-dir': { type: 'string' }, mode: { type: 'string', default: 'full' },
        from: { type: 'string' }, to: { type: 'string' }, 'depart-after': { type: 'string' },
        'arrive-by': { type: 'string' }, limit: { type: 'string', default: '5' },
        'max-changes': { type: 'string', default: String(MAX_CHANGES) }, version: { type: 'string' },
        cases: { type: 'string' }, explain: { type: 'boolean', default: false },
        port: { type: 'string', default: '3013' }
    } });
    const config = plannerConfig({ ...process.env,
        ...(values['data-dir'] ? { PLANNER_DATA_DIR: values['data-dir'] } : {}),
        ...(values.dataset ? { PLANNER_DATASET_PATH: values.dataset } : {}) });
    const output = result => console.log(JSON.stringify(result, null, 2));
    const required = name => {
        if (!values[name]) throw new Error(`--${name} is required`);
        return values[name];
    };
    const progress = event => console.error(JSON.stringify(event));
    const options = { signal: controller.signal, onProgress: progress };
    if (command === 'inspect') {
        const { inspectSource } = await import('../lib/planner/source.js');
        output(await inspectSource(required('source'), options));
    } else if (command === 'import') {
        if (values.mode !== 'full') throw new Error('Only full imports are supported; incremental delivery is not configured.');
        const { importFullSnapshot } = await import('../lib/planner/repository.js');
        output(await importFullSnapshot(required('source'), path.resolve(required('staging')), options));
    } else if (command === 'validate') {
        const { validateDataset } = await import('../lib/planner/repository.js');
        const result = await validateDataset(path.resolve(required('dataset')));
        output(result);
        if (!result.valid) process.exitCode = 1;
    } else if (command === 'activate' || command === 'rollback') {
        const repo = await import('../lib/planner/repository.js');
        output(command === 'activate'
            ? await repo.activateDataset(path.resolve(required('dataset')), config.dataDirectory)
            : await repo.rollbackDataset(required('version'), config.dataDirectory));
    } else if (command === 'status' || command === 'query' || command === 'benchmark') {
        service = new PlannerService(config);
        if (command === 'status') output(await service.status({ signal: controller.signal }));
        else {
            let cases;
            if (command === 'benchmark') cases = JSON.parse(await fs.readFile(required('cases'), 'utf8'));
            else {
                if (Boolean(values['depart-after']) === Boolean(values['arrive-by'])) {
                    throw new Error('Supply exactly one of --depart-after or --arrive-by.');
                }
                cases = [{ origin: required('from'), destination: required('to'),
                    time: values['depart-after'] || values['arrive-by'],
                    timeType: values['arrive-by'] ? 'arriveBy' : 'departAfter',
                    limit: Number(values.limit), maxChanges: Number(values['max-changes']) }];
            }
            if (!Array.isArray(cases) || !cases.length) throw new Error('Benchmark cases must be a non-empty JSON array.');
            const measurements = [];
            for (const request of cases) {
                const started = performance.now();
                const result = await service.search(request, { signal: controller.signal });
                const elapsedMs = performance.now() - started;
                if (command === 'query') {
                    output(result);
                    if (values.explain) {
                        // Private CLI explanation includes exact resolved services/rules, separate from public payloads.
                        const explanation = await service.call('explain', { request }, { signal: controller.signal });
                        output({ explanation });
                    }
                } else {
                    const runtime = await service.call('runtime', {}, { signal: controller.signal });
                    const measurement = { request, elapsedMs, dataset: result.dataset.version,
                        journeys: result.journeys.length, truncated: result.search.searchTruncated, runtime };
                    measurements.push(measurement);
                    progress({ phase: 'benchmark', completed: measurements.length, total: cases.length,
                        elapsedMs: Math.round(elapsedMs), heapUsedBytes: runtime.memoryBytes.heapUsed });
                }
            }
            if (command === 'benchmark') output({ node: process.version, platform: `${os.platform()} ${os.arch()}`,
                cpus: os.cpus().length, concurrency: 1, processPeakRSS: process.resourceUsage().maxRSS,
                measurements });
        }
    } else if (command === 'serve') {
        const [{ default: express }, { registerPlannerRoutes }] = await Promise.all([
            import('express'), import('../lib/planner-routes.js')
        ]);
        const app = express();
        service = new PlannerService(config);
        registerPlannerRoutes(app, { service });
        const port = Number(values.port);
        if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid --port');
        const server = app.listen(port, '127.0.0.1', () => console.log(`Local planner: http://127.0.0.1:${port}/api/v3/journey-planner/status`));
        await new Promise(resolve => controller.signal.addEventListener('abort', () => server.close(resolve), { once: true }));
    } else {
        throw new Error('Usage: npm run planner -- inspect|import|validate|activate|rollback|status|query|benchmark|serve [options]');
    }
} catch (error) {
    console.error(JSON.stringify({ error: error.code || 'PLANNER_FAILED', message: error.message }));
    process.exitCode = controller.signal.aborted ? 130 : 1;
} finally { service?.close(); }
