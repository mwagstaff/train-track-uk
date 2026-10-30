import { getDevicePreferences } from './admin-data-store.js';

export function normalizeNotificationPreferences(value = {}) {
    const minutes = value.connectionDelayMinutes;
    return {
        platformOnlyNearStation: value.platformOnlyNearStation !== false,
        notificationPlatform: value.notificationPlatform !== false,
        connectionAlerts: value.connectionAlerts !== false,
        connectionDelayMinutes: typeof minutes === 'number' && Number.isFinite(minutes)
            ? Math.min(30, Math.max(1, Math.round(minutes))) : 5,
        connectionUnknownDelay: value.connectionUnknownDelay !== false
    };
}

export async function loadNotificationPreferences(deviceId) {
    try {
        return normalizeNotificationPreferences((await getDevicePreferences(deviceId))?.preferences);
    } catch (error) {
        console.error('[notifications] Could not load notification preferences:', error?.message || error);
        // Keep the Live Activity fresh without sending optional alerts using unknown settings.
        return normalizeNotificationPreferences({ notificationPlatform: false, connectionAlerts: false });
    }
}

export function allowsPlatformNotification(preferences, atStation) {
    const policy = normalizeNotificationPreferences(preferences);
    return policy.notificationPlatform && (!policy.platformOnlyNearStation || atStation);
}

// Each observation identifies a selected, unboarded itinerary leg, never a whole departure board.
// Return the proposed state separately so failed APNs sends can retry the alert.
export function connectionNotification(observations, previous = {}, preferences = {}) {
    const policy = normalizeNotificationPreferences(preferences);
    const state = { ...previous };
    const messages = [];
    for (const observation of observations) {
        const { key, label, cancelled, unknownDelay, delayMinutes } = observation;
        if (!key) continue;
        const eligible = policy.connectionAlerts && (cancelled
            || (unknownDelay ? policy.connectionUnknownDelay : delayMinutes >= policy.connectionDelayMinutes));
        const kind = cancelled ? 'cancelled' : unknownDelay ? 'unknown' : 'delay';
        const last = previous[key];
        // Alert on a new disruption or worsening known delay, not every poll or improvement.
        if (eligible && (!last || last.kind !== kind || (kind === 'delay' && delayMinutes > last.delayMinutes))) {
            messages.push(`${label}: ${cancelled ? 'cancelled' : unknownDelay ? 'delayed, time not confirmed' : `${delayMinutes} min late`}.`);
            state[key] = { kind, delayMinutes };
        } else if (!cancelled && !unknownDelay && delayMinutes === 0) {
            delete state[key];
        }
    }
    return { state, alert: messages.length ? { title: 'Connection update', body: messages.join('\n') } : null };
}
