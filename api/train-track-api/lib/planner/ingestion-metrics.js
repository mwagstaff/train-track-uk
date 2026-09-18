import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { hostname } from 'node:os';
import client from 'prom-client';
import { plannerConfig } from './service.js';

const RESULTS = ['activated', 'unchanged', 'gap', 'error', 'disabled'];
const ERROR_CODES = new Set(['S3_ACCESS_DENIED', 'S3_UNAVAILABLE', 'S3_OBJECT_CHANGED',
    'DOWNLOAD_INVALID', 'UPDATE_GAP', 'UPDATE_TARGET_MISSING', 'INVALID_DELIVERY',
    'VALIDATION_FAILED', 'ACTIVATION_BLOCKED', 'CONFIG_INVALID', 'INGESTION_FAILED',
    'CANCELLED', 'LOCKED']);
const DIAGNOSTIC_CODES = new Set(['INVALID_CHRONOLOGY', 'UNSUPPORTED_ACTIVITY',
    'MODE_CHANGE_EN_ROUTE', 'SUPPLEMENTARY_DIALECT_NOT_ENABLED', 'HOLIDAY_CALENDAR_NOT_CONFIGURED',
    'UNSUPPORTED_MODE', 'CONFLICTING_VARIANTS', 'INSUFFICIENT_PASSENGER_CALLS',
    'INVALID_SERVICE_TIME', 'AMBIGUOUS_MIDNIGHT_PUBLIC_TIME', 'MISSING_OPERATOR',
    'UNMAPPED_PASSENGER_CALLS', 'AMBIGUOUS_CLOCK_CHANGE', 'CANCELLED']);
const RECORDS = {
    stations: 'stations', schedules: 'schedule_variants', supportedSchedules: 'supported_schedule_variants',
    calls: 'source_calls', passengerCalls: 'passenger_calls', routingCalls: 'routing_calls',
    associations: 'associations', fixedLinks: 'fixed_links', interchanges: 'interchanges'
};

// The ingestion worker persists these small summaries. Scrapes do no timetable
// parsing, SQLite scans, or S3 requests, and missing values stay absent (unknown).
export function registerTimetableIngestionMetrics({ register, dataDirectory = plannerConfig().dataDirectory, currentEnabled } = {}) {
    const gauges = {};
    function gauge(key, help, labelNames = []) {
        gauges[key] = new client.Gauge({ name: `timetable_${key}`, help, labelNames, registers: [register] });
    }
    gauge('ingestion_state_readable', 'Whether the persisted timetable ingestion state is readable and supported');
    gauge('ingestion_enabled', 'Whether hourly S3 timetable ingestion is enabled');
    gauge('ingestion_in_progress', 'Whether a timetable ingestion run is in progress');
    gauge('ingestion_abandoned_run', 'Whether a persisted in-progress run has a confirmed dead local worker, absent when worker status is unknown');
    gauge('ingestion_check_interval_seconds', 'Configured timetable bucket check interval in seconds');
    gauge('ingestion_last_check_timestamp_seconds', 'Start time of the last timetable bucket check');
    gauge('ingestion_last_successful_check_timestamp_seconds', 'Time of the last successful bucket check, including unchanged deliveries');
    gauge('ingestion_last_successful_import_timestamp_seconds', 'Time of the last successful timetable import, not unchanged checks');
    gauge('ingestion_last_activation_timestamp_seconds', 'Time of the last timetable activation');
    gauge('ingestion_last_result', 'One-hot bounded outcome of the last ingestion run', ['result']);
    gauge('ingestion_last_error', 'Last bounded ingestion error code, absent when no error is recorded', ['code']);
    gauge('ingestion_last_run_duration_seconds', 'Duration of the last completed ingestion run in seconds');
    gauge('ingestion_last_download_bytes', 'Bytes downloaded during the last completed ingestion run');
    gauge('ingestion_pending_gap_sequences', 'Number of missing deliveries in the pending update chain');
    gauge('ingestion_pending_gap_sequence', 'Expected and received sequence at the pending update gap', ['boundary']);
    gauge('remote_last_modified_timestamp_seconds', 'Last observed S3 delivery object modification time', ['feed']);
    gauge('remote_size_bytes', 'Last observed S3 delivery object size in bytes', ['feed']);
    gauge('active_snapshot_available', 'Whether ingestion state contains an active timetable snapshot');
    gauge('active_publication_timestamp_seconds', 'Publication date of the active timetable source at UTC midnight');
    gauge('active_coverage_timestamp_seconds', 'Supported MCA schedule coverage boundaries, not a completeness guarantee', ['boundary']);
    gauge('active_sequence', 'Active full baseline and current applied delivery sequence', ['kind']);
    gauge('active_schema_version', 'Schema version of the active timetable snapshot');
    gauge('active_optimized', 'Whether the active snapshot uses the schema 2 compact routing projection');
    gauge('active_validation_valid', 'Whether the last active snapshot validation passed');
    gauge('active_validation_timestamp_seconds', 'Time of the last active snapshot validation');
    gauge('active_validation_issues', 'Number of active snapshot validation messages', ['severity']);
    gauge('active_database_bytes', 'Validated active timetable SQLite database size in bytes');
    gauge('active_records', 'Active timetable inventory by bounded record kind', ['kind']);
    gauge('active_routing_payload_bytes', 'Bytes of compact routing call JSON in the active snapshot');
    gauge('active_diagnostics', 'Active timetable import diagnostic record counts, not individual unmapped call counts', ['code']);
    gauge('representative_date_timestamp_seconds', 'Validated representative date by bounded sample slot at UTC midnight', ['sample']);
    gauge('representative_services', 'Resolved passenger services on each representative date', ['sample']);
    gauge('representative_stations', 'Passenger stations served on each representative date', ['sample']);
    gauge('representative_operator_services', 'Resolved passenger services by operator and bounded representative date slot', ['sample', 'operator']);
    gauge('representative_diagnostics', 'Dated timetable resolution diagnostic counts by bounded representative date slot', ['sample', 'code']);

    function set(key, value, labels) {
        if (value === null || value === undefined || value === '' || typeof value === 'boolean') return;
        const number = Number(value);
        if (Number.isFinite(number) && number >= 0) gauges[key].set(labels || {}, number);
    }
    function timestamp(key, value, labels) {
        if (typeof value !== 'string' || !value.trim()) return;
        set(key, Date.parse(value) / 1000, labels);
    }
    function boolean(key, value) {
        if (typeof value === 'boolean') set(key, value ? 1 : 0);
    }
    function diagnostics(key, counts, labels = {}) {
        if (!counts || typeof counts !== 'object') return;
        const bounded = new Map();
        for (const [code, value] of Object.entries(counts)) {
            if (typeof value !== 'number' || !Number.isFinite(value) || value < 0) continue;
            const safeCode = DIAGNOSTIC_CODES.has(code) ? code : 'OTHER';
            bounded.set(safeCode, (bounded.get(safeCode) || 0) + value);
        }
        // A known diagnostic inventory with no entries means zero, unlike a
        // missing inventory, which must not falsely advertise clean data.
        for (const code of DIAGNOSTIC_CODES) set(key, bounded.get(code) || 0, { ...labels, code });
        set(key, bounded.get('OTHER') || 0, { ...labels, code: 'OTHER' });
    }
    let refreshing;
    async function collect() {
        for (const metric of Object.values(gauges)) {
            metric.reset();
            // prom-client resets an unlabelled gauge to zero automatically;
            // remove that default sample so unknown values remain absent.
            if (metric.labelNames.length === 0) metric.remove();
        }
        boolean('ingestion_enabled', currentEnabled);
        let state;
        try {
            state = JSON.parse(await readFile(join(dataDirectory, 'ingestion-state.json'), 'utf8'));
            if (!state || state.schemaVersion !== 1) throw new Error('Unsupported ingestion state');
        } catch {
            set('ingestion_state_readable', 0);
            return;
        }
        set('ingestion_state_readable', 1);
        if (typeof currentEnabled !== 'boolean') boolean('ingestion_enabled', state.enabled);
        let inProgress = state.inProgress;
        if (inProgress === false) set('ingestion_abandoned_run', 0);
        else if (inProgress === true && state.worker?.hostname === hostname()
            && Number.isSafeInteger(state.worker.pid) && state.worker.pid > 0) {
            try {
                process.kill(state.worker.pid, 0);
                set('ingestion_abandoned_run', 0);
            } catch (error) {
                // EPERM or another host's PID cannot prove the worker is dead.
                if (error.code === 'ESRCH') { inProgress = false; set('ingestion_abandoned_run', 1); }
            }
        }
        boolean('ingestion_in_progress', inProgress);
        set('ingestion_check_interval_seconds', state.intervalSeconds);
        timestamp('ingestion_last_check_timestamp_seconds', state.lastCheckAt);
        timestamp('ingestion_last_successful_check_timestamp_seconds', state.lastSuccessfulCheckAt);
        timestamp('ingestion_last_successful_import_timestamp_seconds', state.lastSuccessAt);
        timestamp('ingestion_last_activation_timestamp_seconds', state.lastActivatedAt);
        if (RESULTS.includes(state.lastResult)) {
            for (const result of RESULTS) set('ingestion_last_result', result === state.lastResult ? 1 : 0, { result });
        }
        if (state.lastErrorCode) set('ingestion_last_error', 1, {
            code: ERROR_CODES.has(state.lastErrorCode) ? state.lastErrorCode : 'INGESTION_FAILED'
        });
        if (state.lastDurationMs !== null && state.lastDurationMs !== undefined) set('ingestion_last_run_duration_seconds', state.lastDurationMs / 1000);
        set('ingestion_last_download_bytes', state.lastDownloadBytes);
        if (state.pendingGap === null) set('ingestion_pending_gap_sequences', 0);
        else if (state.pendingGap) {
            set('ingestion_pending_gap_sequences', state.pendingGap.missingCount);
            set('ingestion_pending_gap_sequence', state.pendingGap.expectedSequence, { boundary: 'expected' });
            set('ingestion_pending_gap_sequence', state.pendingGap.actualSequence, { boundary: 'received' });
        }
        for (const feed of ['full', 'update']) {
            timestamp('remote_last_modified_timestamp_seconds', state.remote?.[feed]?.lastModified, { feed });
            set('remote_size_bytes', state.remote?.[feed]?.size, { feed });
        }
        const active = state.active;
        if (Object.hasOwn(state, 'active')) set('active_snapshot_available', active?.metadata ? 1 : 0);
        if (!active?.metadata) return;
        const metadata = active.metadata, validation = active.validation;
        timestamp('active_publication_timestamp_seconds', metadata.source?.generationDate);
        timestamp('active_coverage_timestamp_seconds', metadata.coverage?.startDate, { boundary: 'start' });
        timestamp('active_coverage_timestamp_seconds', metadata.coverage?.endDate, { boundary: 'end' });
        set('active_sequence', active.baselineSequence, { kind: 'baseline' });
        set('active_sequence', active.currentSequence, { kind: 'current' });
        set('active_schema_version', metadata.schemaVersion);
        if (Number.isInteger(metadata.schemaVersion)) set('active_optimized', metadata.schemaVersion === 2 ? 1 : 0);
        for (const [field, kind] of Object.entries(RECORDS)) set('active_records', metadata.counts?.[field], { kind });
        set('active_routing_payload_bytes', metadata.counts?.routingCallBytes);
        diagnostics('active_diagnostics', metadata.diagnostics?.counts);
        boolean('active_validation_valid', validation?.valid);
        timestamp('active_validation_timestamp_seconds', validation?.checkedAt);
        if (Array.isArray(validation?.errors)) set('active_validation_issues', validation.errors.length, { severity: 'errors' });
        if (Array.isArray(validation?.warnings)) set('active_validation_issues', validation.warnings.length, { severity: 'warnings' });
        set('active_database_bytes', validation?.databaseBytes);
        const dates = Array.isArray(validation?.representativeDates) ? validation.representativeDates : [];
        for (const [index, date] of dates.slice(0, 5).entries()) {
            if (!date || typeof date !== 'object') continue;
            const labels = { sample: String(index) };
            timestamp('representative_date_timestamp_seconds', date.date, labels);
            set('representative_services', date.serviceCount, labels);
            set('representative_stations', date.stationCount, labels);
            for (const [operator, count] of Object.entries(date.operatorCounts || {})) {
                if (/^[A-Z0-9]{2}$/.test(operator)) set('representative_operator_services', count, { ...labels, operator });
            }
            diagnostics('representative_diagnostics', date.diagnostics?.counts, labels);
        }
    }
    return {
        // Share a pending read across concurrent /metrics requests. Resetting
        // all series prevents old successful values lingering after bad state.
        async refresh() {
            if (!refreshing) refreshing = collect().finally(() => { refreshing = null; });
            await refreshing;
        }
    };
}
