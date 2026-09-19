const HOUR = 3600000;
const validDate = value => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)
    && Number.isFinite(Date.parse(`${value}T12:00:00Z`))
    && new Date(`${value}T12:00:00Z`).toISOString().slice(0, 10) === value;
const weekday = date => new Date(`${date}T12:00:00Z`).getUTCDay();
const finite = value => typeof value === 'number' && Number.isFinite(value);
const validWindow = value => Number.isInteger(value?.startMinutes) && Number.isInteger(value?.endMinutes)
    && value.startMinutes >= 0 && value.startMinutes < 1440 && value.endMinutes > value.startMinutes
    && value.endMinutes <= value.startMinutes + 1440;

/** Alert readiness is stricter than the interactive planner's stale-data policy.
 * Publication time, not a recent import or successful HTTP check, establishes age. */
export function assessTimetableReadiness(status, ingestionState, { now = Date.now(), maxSourceAgeHours = 48,
    maxCheckAgeHours = 6 } = {}) {
    const instant = typeof now === 'function' ? now() : Number(now);
    const dataset = status?.dataset;
    const summary = { datasetVersion: dataset?.version ?? null, sourceGenerationDate: dataset?.sourceGenerationDate ?? null };
    const unavailable = reason => ({ ready: false, reason, ...summary });
    if (!Number.isFinite(instant) || !finite(maxSourceAgeHours) || maxSourceAgeHours <= 0
        || !finite(maxCheckAgeHours) || maxCheckAgeHours <= 0) return unavailable('invalid_readiness_policy');
    if (status?.available !== true || !dataset?.version) return unavailable('timetable_unavailable');
    if (!validDate(dataset.sourceGenerationDate)) return unavailable('publication_unknown');
    const publication = Date.parse(`${dataset.sourceGenerationDate}T00:00:00Z`);
    if (publication > instant || instant - publication > maxSourceAgeHours * HOUR) return unavailable('timetable_stale');
    if (ingestionState?.schemaVersion !== 1 || ingestionState.enabled !== true) return unavailable('ingestion_unavailable');
    if (ingestionState.inProgress !== false) return unavailable('ingestion_in_progress');
    if (ingestionState.pendingGap !== null || ingestionState.lastResult === 'gap'
        || ingestionState.lastErrorCode === 'UPDATE_GAP') return unavailable('timetable_update_gap');
    if (ingestionState.active?.validation?.valid !== true) return unavailable('timetable_not_validated');
    if ((ingestionState.active?.metadata?.version ?? ingestionState.active?.version) !== dataset.version
        || ingestionState.active?.metadata?.source?.generationDate !== dataset.sourceGenerationDate) {
        return unavailable('timetable_version_mismatch');
    }
    const lastCheck = Date.parse(ingestionState.lastSuccessfulCheckAt);
    if (!Number.isFinite(lastCheck) || lastCheck > instant || instant - lastCheck > maxCheckAgeHours * HOUR) {
        return unavailable('ingestion_check_stale');
    }
    return { ready: true, reason: null, ...summary };
}

/** Compare equivalent scheduled windows. The caller excludes known notices,
 * holidays and unreliable feed history before offering baseline candidates. */
export function decideProfileAdvisories(current, baselines = [], context = {}) {
    const unknown = reason => ({ state: 'unknown', reason, comparisonReady: false, advisories: [] });
    if (context.readiness?.ready === false) return unknown(context.readiness.reason || 'timetable_unavailable');
    if (current?.complete !== true) return unknown(current?.reason || 'incomplete_profile');
    if (!validDate(current.date) || !validWindow(current)) return unknown('invalid_profile_window');
    if (current.servicesAvailable !== true) return unknown('no_services_found');
    if (!Number.isInteger(current.directTrains) || current.directTrains < 0
        || typeof current.replacementBus !== 'boolean' || typeof current.railOnlyAvailable !== 'boolean') {
        return unknown('incomplete_profile');
    }
    const matching = new Map();
    for (const baseline of Array.isArray(baselines) ? baselines : []) {
        if (current.holiday === true || context.holiday === true || baseline?.holiday === true
            || baseline?.complete !== true || baseline.servicesAvailable !== true || baseline.excluded === true
            || !baseline.datasetVersion || !validDate(baseline.sourceGenerationDate)
            || !Number.isInteger(baseline.directTrains) || baseline.directTrains < 0
            || !finite(baseline.durationMinutes) || baseline.durationMinutes <= 0
            || !validDate(baseline.date) || baseline.date === current.date || weekday(baseline.date) !== weekday(current.date)
            || current.timetableSeason && baseline.timetableSeason !== current.timetableSeason
            || baseline.startMinutes !== current.startMinutes || baseline.endMinutes !== current.endMinutes) continue;
        // Repeated observations of the same day do not create independent evidence.
        if (!matching.has(baseline.date)) matching.set(baseline.date, baseline);
    }
    const normal = [...matching.values()];
    // Consumers may clear a previous comparative warning only with this
    // evidence, rather than counting raw (possibly ineligible) input rows.
    const comparisonReady = normal.length >= 2 && finite(current.durationMinutes) && current.durationMinutes > 0;
    const advisories = [];
    const add = (kind, title, body, details = {}) => advisories.push({ kind, title, body,
        date: current.date, startMinutes: current.startMinutes, endMinutes: current.endMinutes, ...details });
    if (current.replacementBus && !current.railOnlyAvailable) {
        add('replacement_bus', 'Replacement bus in your journey',
            'The available journeys in this travel window include a replacement bus; no all-rail alternative was found.');
    }
    if (normal.length >= 2 && current.directTrains === 0
        && normal.every(value => Number.isInteger(value.directTrains) && value.directTrains > 0)) {
        add('direct_unavailable', 'Your usual direct trains appear unavailable',
            'No direct trains were found in the supported timetable for this travel window, although they normally run on this day of the week.');
    }
    const durations = normal.map(value => value.durationMinutes).filter(value => finite(value) && value > 0).sort((a, b) => a - b);
    if (durations.length >= 2 && finite(current.durationMinutes) && current.durationMinutes > 0) {
        const middle = Math.floor(durations.length / 2);
        const baselineDurationMinutes = durations.length % 2 ? durations[middle] : (durations[middle - 1] + durations[middle]) / 2;
        const extraMinutes = current.durationMinutes - baselineDurationMinutes;
        if (extraMinutes >= 15 || extraMinutes >= 5 && extraMinutes / baselineDurationMinutes >= 0.25) {
            add('longer_journey', 'Allow longer for your journey',
                `The fastest available journey in this travel window takes about ${Math.round(extraMinutes)} minutes longer than usual.`,
                { durationMinutes: current.durationMinutes, baselineDurationMinutes, extraMinutes });
        }
    }
    return { state: 'ready', reason: null, comparisonReady, advisories };
}
