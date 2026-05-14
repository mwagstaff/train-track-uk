export function getNotificationDiagnosticMarker() {
    const raw = process.env.NOTIFICATION_DIAGNOSTIC_MARKER;
    if (typeof raw === 'string') {
        const trimmed = raw.trim();
        if (!trimmed || trimmed.toLowerCase() === 'false' || trimmed.toLowerCase() === 'off') {
            return '';
        }
        return trimmed;
    }
    return '';
}

export function markPushPayload(payload, { channel = null, event = null } = {}) {
    const marker = getNotificationDiagnosticMarker();
    if (!marker || !payload || typeof payload !== 'object') {
        return payload;
    }

    const nextPayload = {
        ...payload,
        diagnostic_marker: marker,
        diagnostic_channel: channel || payload.diagnostic_channel || null,
        diagnostic_event: event || payload.diagnostic_event || null
    };
    const aps = payload.aps && typeof payload.aps === 'object'
        ? { ...payload.aps }
        : payload.aps;

    if (aps && typeof aps === 'object' && aps.alert) {
        aps.alert = markAlert(aps.alert, marker);
        nextPayload.aps = aps;
    }

    return nextPayload;
}

export function addDiagnosticMarkerToContext(context, { channel = null, event = null } = {}) {
    const marker = getNotificationDiagnosticMarker();
    if (!marker) return context;
    return {
        ...(context && typeof context === 'object' ? context : {}),
        diagnostic_marker: marker,
        diagnostic_channel: channel,
        diagnostic_event: event
    };
}

function markAlert(alert, marker) {
    if (typeof alert === 'string') {
        return alert.includes(`[${marker}]`) ? alert : `[${marker}] ${alert}`;
    }

    if (!alert || typeof alert !== 'object') {
        return alert;
    }

    const nextAlert = { ...alert };
    if (typeof nextAlert.title === 'string' && nextAlert.title.trim()) {
        nextAlert.title = appendMarker(nextAlert.title, marker);
    } else if (typeof nextAlert.body === 'string' && nextAlert.body.trim()) {
        nextAlert.body = `[${marker}] ${nextAlert.body}`;
    } else {
        nextAlert.title = `[${marker}]`;
    }
    return nextAlert;
}

function appendMarker(text, marker) {
    return text.includes(`[${marker}]`) ? text : `${text} [${marker}]`;
}
