const LEGACY_STATION_EXIT_REASONS = new Set([
    'station_exit',
    'debug_station_exit',
    'location_exit_fallback'
]);

function normalizeValue(value) {
    return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

export function resolveMuteTransition({ transition = null, reason = 'mute_on_arrival' } = {}) {
    const normalizedTransition = normalizeValue(transition);
    if (normalizedTransition) return normalizedTransition;
    return LEGACY_STATION_EXIT_REASONS.has(normalizeValue(reason)) ? 'station_exit' : 'arrival';
}

export function resolveDetectionSource({ detectionSource = null, reason = 'mute_on_arrival' } = {}) {
    const normalizedSource = normalizeValue(detectionSource);
    if (normalizedSource) return normalizedSource;

    switch (normalizeValue(reason)) {
    case 'location_exit_fallback':
        return 'location_fallback';
    case 'station_exit':
        return 'geofence';
    case 'debug_station_exit':
        return 'debug';
    default:
        return null;
    }
}

export function buildMuteNotificationPlan({ stationName, transition = null, reason = 'mute_on_arrival' } = {}) {
    const resolvedTransition = resolveMuteTransition({ transition, reason });
    const stationLabel = formatStationGreetingName(stationName);
    const greetingBody = resolvedTransition === 'station_exit'
        ? `You've left ${stationLabel}. Enjoy your journey!`
        : `Welcome to ${stationLabel}`;
    const plan = [{
        type: 'muted_greeting',
        category: 'STATION_ARRIVAL',
        body: greetingBody
    }];

    if (resolvedTransition !== 'station_exit') {
        plan.push({ type: 'muted_status', category: 'JOURNEY_LEG_ALERT' });
    }
    return plan;
}

function formatStationGreetingName(value) {
    const label = typeof value === 'string' && value.trim().length > 0 ? value.trim() : 'your station';
    return / station$/i.test(label) ? label : `${label} station`;
}
