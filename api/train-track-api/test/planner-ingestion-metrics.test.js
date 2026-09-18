import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir, hostname } from 'node:os';
import client from 'prom-client';
import { registerTimetableIngestionMetrics } from '../lib/planner/ingestion-metrics.js';

async function fixture(t, state, options = {}) {
    const dataDirectory = await mkdtemp(join(tmpdir(), 'traintrack-ingestion-metrics-'));
    t.after(() => rm(dataDirectory, { recursive: true, force: true }));
    const register = new client.Registry();
    register.setDefaultLabels({ service_name: 'test-service', instance_id: 'test-instance', pid: '123' });
    const collector = registerTimetableIngestionMetrics({ register, dataDirectory, ...options });
    const statePath = join(dataDirectory, 'ingestion-state.json');
    if (state !== undefined) await writeFile(statePath, JSON.stringify(state));
    async function metrics() {
        await collector.refresh();
        return register.metrics();
    }
    return { metrics, statePath, register, collector };
}

const active = {
    baselineSequence: 939, currentSequence: 962,
    metadata: {
        schemaVersion: 2, source: { generationDate: '2026-09-17' },
        coverage: { startDate: '2026-08-25', endDate: '2027-05-16' },
        counts: { stations: 2600, schedules: 455000, supportedSchedules: 350000,
            routingCalls: 1200000, calls: 5000000, routingCallBytes: 96000000 },
        diagnostics: { counts: { UNMAPPED_PASSENGER_CALLS: 3, HOLIDAY_CALENDAR_NOT_CONFIGURED: 2,
            'SENSITIVE-RAW-ERROR-TEXT': 4 } }
    },
    validation: {
        valid: true, checkedAt: '2026-09-18T15:00:00Z', errors: [], warnings: ['Exclusions exist'],
        databaseBytes: 276000000,
        representativeDates: [
            { date: '2026-09-17', serviceCount: 20000, stationCount: 2600,
                operatorCounts: { SE: 1300, SN: 1400, 'RAW-OBJECT-VERSION-ID': 99 },
                diagnostics: { counts: { CONFLICTING_VARIANTS: 1 } } },
            { date: '2026-09-19', serviceCount: 18000, stationCount: 2590, operatorCounts: { SE: 1200 },
                diagnostics: { counts: {} } }
        ]
    }
};

test('persisted ingestion metrics distinguish successful checks, imports, publication, and S3 upload', async t => {
    const { metrics } = await fixture(t, {
        schemaVersion: 1, enabled: true, inProgress: false, intervalSeconds: 3600,
        lastCheckAt: '2026-09-18T16:00:00Z', lastSuccessfulCheckAt: '2026-09-18T16:00:03Z',
        lastSuccessAt: '2026-09-18T15:00:00Z', lastActivatedAt: '2026-09-18T15:00:00Z',
        lastResult: 'unchanged', lastDurationMs: 3000, lastDownloadBytes: 0, pendingGap: null,
        remote: { full: { lastModified: '2026-09-18T14:09:14Z', size: 69600000 },
            update: { lastModified: '2026-09-18T13:48:58Z', size: 1200000 } }, active
    });
    const text = await metrics();
    assert.match(text, /timetable_ingestion_enabled\{[^}]*service_name="test-service"[^}]*\} 1/);
    assert.match(text, /timetable_ingestion_last_result\{[^}]*result="unchanged"[^}]*\} 1/);
    assert.match(text, /timetable_ingestion_last_result\{[^}]*result="activated"[^}]*\} 0/);
    assert.match(text, /timetable_ingestion_last_run_duration_seconds\{[^}]*\} 3/);
    assert.match(text, /timetable_ingestion_last_download_bytes\{[^}]*\} 0/);
    assert.match(text, /timetable_ingestion_last_successful_check_timestamp_seconds\{[^}]*\} 1789747203/);
    assert.match(text, /timetable_ingestion_last_successful_import_timestamp_seconds\{[^}]*\} 1789743600/);
    assert.match(text, /timetable_active_publication_timestamp_seconds\{[^}]*\} 1789603200/);
    assert.match(text, /timetable_remote_last_modified_timestamp_seconds\{[^}]*feed="update"[^}]*\} 1789739338/);
    assert.match(text, /timetable_active_optimized\{[^}]*\} 1/);
    assert.match(text, /timetable_active_validation_valid\{[^}]*\} 1/);
    assert.match(text, /timetable_active_validation_issues\{[^}]*severity="warnings"[^}]*\} 1/);
    assert.match(text, /timetable_active_records\{[^}]*kind="routing_calls"[^}]*\} 1200000/);
    assert.match(text, /timetable_active_diagnostics\{[^}]*code="UNMAPPED_PASSENGER_CALLS"[^}]*\} 3/);
    assert.match(text, /timetable_active_diagnostics\{[^}]*code="OTHER"[^}]*\} 4/);
    assert.match(text, /timetable_representative_operator_services\{[^}]*sample="0"[^}]*operator="SE"[^}]*\} 1300/);
    assert.match(text, /timetable_representative_diagnostics\{[^}]*sample="1"[^}]*code="CONFLICTING_VARIANTS"[^}]*\} 0/);
    assert.doesNotMatch(text, /SENSITIVE-RAW-ERROR-TEXT|RAW-OBJECT-VERSION-ID|date="2026-/);
});

test('missing and invalid state is unavailable, never fabricated successful or clean data', async t => {
    const { metrics, statePath } = await fixture(t);
    let text = await metrics();
    assert.match(text, /timetable_ingestion_state_readable\{[^}]*\} 0/);
    assert.doesNotMatch(text, /^timetable_ingestion_last_successful_check_timestamp_seconds\{/m);
    assert.doesNotMatch(text, /^timetable_active_validation_valid\{/m);
    await writeFile(statePath, JSON.stringify({ schemaVersion: 1, active }));
    assert.match(await metrics(), /timetable_active_database_bytes\{[^}]*\} 276000000/);
    await writeFile(statePath, '{broken');
    text = await metrics();
    assert.match(text, /timetable_ingestion_state_readable\{[^}]*\} 0/);
    assert.doesNotMatch(text, /^timetable_active_database_bytes\{/m);
    await writeFile(statePath, JSON.stringify({ schemaVersion: 2, active }));
    assert.match(await metrics(), /timetable_ingestion_state_readable\{[^}]*\} 0/);
});

test('pending chain gaps and bounded errors preserve independently reported active data', async t => {
    const { metrics } = await fixture(t, {
        schemaVersion: 1, lastResult: 'gap', lastErrorCode: 'UPDATE_GAP',
        pendingGap: { expectedSequence: 940, actualSequence: 962, missingCount: 22 },
        remote: { update: { lastModified: null, size: null } },
        active: { ...active, currentSequence: 939, validation: null,
            metadata: { ...active.metadata, source: { generationDate: '2026-08-25' } } }
    });
    const text = await metrics();
    assert.match(text, /timetable_ingestion_pending_gap_sequences\{[^}]*\} 22/);
    assert.match(text, /timetable_ingestion_pending_gap_sequence\{[^}]*boundary="expected"[^}]*\} 940/);
    assert.match(text, /timetable_ingestion_pending_gap_sequence\{[^}]*boundary="received"[^}]*\} 962/);
    assert.match(text, /timetable_ingestion_last_error\{[^}]*code="UPDATE_GAP"[^}]*\} 1/);
    assert.match(text, /timetable_active_sequence\{[^}]*kind="current"[^}]*\} 939/);
    assert.doesNotMatch(text, /^timetable_remote_size_bytes\{/m);
    assert.doesNotMatch(text, /^timetable_active_validation_valid\{/m);
});

test('representative samples and arbitrary diagnostics/errors cannot create unbounded labels', async t => {
    const { metrics, collector } = await fixture(t, {
        schemaVersion: 1, lastErrorCode: '/raw/path?access_key=secret',
        active: { ...active, validation: { ...active.validation,
            representativeDates: Array(12).fill(active.validation.representativeDates[0]) } }
    });
    await Promise.all([collector.refresh(), collector.refresh()]);
    const text = await metrics();
    assert.match(text, /timetable_ingestion_last_error\{[^}]*code="INGESTION_FAILED"[^}]*\} 1/);
    assert.doesNotMatch(text, /access_key|sample="[5-9]"|sample="1[01]"/);
});

test('malformed optional summaries do not break metrics scraping', async t => {
    const { metrics } = await fixture(t, {
        schemaVersion: 1, lastDurationMs: null,
        active: { metadata: { schemaVersion: 1, counts: { stations: null } },
            validation: { representativeDates: 'not-an-array' } }
    });
    const text = await metrics();
    assert.match(text, /timetable_active_optimized\{[^}]*\} 0/);
    assert.doesNotMatch(text, /^timetable_active_records\{/m);
    assert.doesNotMatch(text, /^timetable_ingestion_last_run_duration_seconds\{/m);
});

test('current automatic-ingestion configuration overrides old persisted enabled state, even without state', async t => {
    const configured = await fixture(t, { schemaVersion: 1, enabled: true }, { currentEnabled: false });
    assert.match(await configured.metrics(), /timetable_ingestion_enabled\{[^}]*\} 0/);
    const missing = await fixture(t, undefined, { currentEnabled: true });
    const text = await missing.metrics();
    assert.match(text, /timetable_ingestion_enabled\{[^}]*\} 1/);
    assert.match(text, /timetable_ingestion_state_readable\{[^}]*\} 0/);
    assert.doesNotMatch(text, /^timetable_ingestion_last_successful_check_timestamp_seconds\{/m);
});

test('worker liveness is conservative: only confirmed dead local workers clear in-progress state', async t => {
    const running = await fixture(t, {
        schemaVersion: 1, inProgress: true, worker: { pid: process.pid, hostname: hostname() }
    });
    let text = await running.metrics();
    assert.match(text, /timetable_ingestion_in_progress\{[^}]*\} 1/);
    assert.match(text, /timetable_ingestion_abandoned_run\{[^}]*\} 0/);
    const unknown = await fixture(t, {
        schemaVersion: 1, inProgress: true, worker: { pid: process.pid, hostname: 'different-host' }
    });
    text = await unknown.metrics();
    assert.match(text, /timetable_ingestion_in_progress\{[^}]*\} 1/);
    assert.doesNotMatch(text, /^timetable_ingestion_abandoned_run\{/m);
    // A short-lived child supplies an actual dead PID without assuming an
    // arbitrary process number is absent on the developer's machine.
    const { spawn } = await import('node:child_process');
    const child = spawn(process.execPath, ['-e', '']);
    await new Promise((resolve, reject) => { child.once('close', resolve); child.once('error', reject); });
    const interrupted = await fixture(t, {
        schemaVersion: 1, inProgress: true, worker: { pid: child.pid, hostname: hostname() }
    });
    text = await interrupted.metrics();
    assert.match(text, /timetable_ingestion_in_progress\{[^}]*\} 0/);
    assert.match(text, /timetable_ingestion_abandoned_run\{[^}]*\} 1/);
});

test('Grafana ingestion dashboard automatically follows the service without datasource/instance/PID selectors', async t => {
    const dashboard = JSON.parse(await readFile(new URL('../observability/grafana/dashboards/timetable-ingestion.json', import.meta.url), 'utf8'));
    const { register } = await fixture(t);
    const names = new Set(register.getMetricsAsArray().map(metric => metric.name));
    names.add('planner_request_duration_ms_bucket');
    names.add('process_start_time_seconds');
    const scope = 'service_name="train-track-api"';
    const currentProcess = `topk by (service_name) (1, max by (service_name, instance_id, pid) (process_start_time_seconds{${scope}}))`;
    assert.equal(dashboard.uid, 'tt-timetable-ingestion');
    assert.equal(dashboard.title, 'Timetable Ingestion & Data Quality');
    assert.equal(new Set(dashboard.panels.map(panel => panel.id)).size, dashboard.panels.length);
    assert.deepEqual(dashboard.templating.list, []);
    for (const panel of dashboard.panels) {
        assert.deepEqual(panel.datasource, { type: 'prometheus', uid: '' }, 'Deployment must inject the configured datasource, like sibling dashboards');
        for (const target of panel.targets) {
            const queriedNames = target.expr.match(/(?:timetable_[a-z_]+|planner_request_duration_ms_bucket|process_start_time_seconds)(?=\{)/g) || [];
            assert.ok(queriedNames.length > 0, `No registered metrics in ${panel.title}`);
            for (const name of queriedNames) assert.ok(names.has(name), `Unknown dashboard metric ${name}`);
            assert.ok(target.expr.includes(scope), `Missing service scope in ${panel.title}`);
            assert.doesNotMatch(target.expr, /\$(?:pid|instance_id|service_name|datasource)\b/, `Stale URL/selector values must not affect ${panel.title}`);
            for (const match of target.expr.matchAll(/(timetable_[a-z_]+)\{[^}]*\}/g)) {
                assert.ok(target.expr.includes(`max without (pid, job, instance, instance_id) (${match[0]} and on (service_name, instance_id, pid) ${currentProcess})`),
                    `Gauges must select the newest process, not the highest/stale value in ${panel.title}`);
            }
            if (panel.type === 'timeseries') {
                assert.equal(target.range, true, `History requires a range query in ${panel.title}`);
                if (queriedNames.includes('planner_request_duration_ms_bucket')) {
                    assert.equal(target.expr, `histogram_quantile(0.95, sum by (le, operation) (rate(planner_request_duration_ms_bucket{${scope}}[$__rate_interval])))`,
                        'Histogram resets must be handled per process before aggregation');
                }
            } else {
                assert.equal(target.instant, true, `Current status requires an instant query in ${panel.title}`);
            }
            assert.ok(!target.expr.includes('or vector(0)'), 'Unavailable data must not be replaced with zero');
        }
    }
    for (let left = 0; left < dashboard.panels.length; left++) {
        const a = dashboard.panels[left].gridPos;
        assert.ok(a.x + a.w <= 24 && a.x >= 0 && a.y >= 0, 'Panel outside Grafana grid');
        for (const other of dashboard.panels.slice(left + 1)) {
            const b = other.gridPos;
            assert.ok(!(a.x < b.x + b.w && a.x + a.w > b.x && a.y < b.y + b.h && a.y + a.h > b.y), 'Overlapping dashboard panels');
        }
    }
});

test('Grafana ingestion dashboard defaults to a recent view and formats only numeric timestamps as dates', async () => {
    const dashboard = JSON.parse(await readFile(new URL('../observability/grafana/dashboards/timetable-ingestion.json', import.meta.url), 'utf8'));
    assert.deepEqual(dashboard.time, { from: 'now-1h', to: 'now' });
    const timestamps = dashboard.panels.find(panel => panel.id === 11);
    assert.equal(timestamps.fieldConfig.defaults.noValue, 'N/A');
    assert.equal(timestamps.fieldConfig.defaults.unit, undefined, 'Event labels must not be date-formatted');
    assert.deepEqual(timestamps.fieldConfig.overrides, [{
        matcher: { id: 'byName', options: 'Timestamp' },
        properties: [{ id: 'unit', value: 'dateTimeAsIso' }]
    }]);
    const organize = timestamps.transformations.find(transform => transform.id === 'organize');
    assert.deepEqual(organize.options.renameByName, { Metric: 'Event', Value: 'Timestamp' });
    for (const target of timestamps.targets) {
        assert.match(target.expr, /\* 1000$/, 'Grafana dates require milliseconds');
    }
});
