// Public board observations are distinct from the time this server fetched them.
// In particular, a new HTTP response does not make an old board current.
export const SIRI_SNAPSHOT_MAX_AGE_MS = 60_000;
export const SIRI_DEPARTURE_DEADLINE_MS = 7_500;

export function observationTimestamp(value) {
    if (typeof value !== 'string'
        || !/^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$/i.test(value)) return null;
    const timestamp = Date.parse(value);
    return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : null;
}

export function boardObservation(data, requestedOffsetMinutes, fetchedAt) {
    return {
        providerObservedAt: observationTimestamp(data?.generatedAt),
        fetchedAt: observationTimestamp(fetchedAt),
        requestedOffsetsMinutes: [requestedOffsetMinutes],
        // The existing board requests use provider defaults for row/window limits.
        // They cannot establish a complete interval or an absence of all services.
        searchWindowMinutes: null,
        complete: false,
        failureReason: null
    };
}

export function departureObservation(service, board) {
    const platform = typeof service?.platform === 'string' ? service.platform.trim() : '';
    const reported = Boolean(platform && platform.toUpperCase() !== 'TBC');
    return {
        providerObservedAt: board.providerObservedAt,
        requestedOffsetMinutes: board.requestedOffsetsMinutes[0],
        platformSource: reported ? 'reported' : 'unknown',
        platformObservedAt: reported ? board.providerObservedAt : null
    };
}

export function mergedBoardObservation(responses, fetchedAt) {
    const successful = responses.filter((response) => Array.isArray(response?.departures) && !response.error);
    const dates = successful.map((response) => observationTimestamp(response.siri?.providerObservedAt));
    return {
        providerObservedAt: dates.length > 0 && dates.every(Boolean) ? dates.sort()[0] : null,
        fetchedAt: observationTimestamp(fetchedAt),
        requestedOffsetsMinutes: [0, 119],
        searchWindowMinutes: null,
        complete: false,
        failureReason: successful.length ? null : responses.find((response) => response?.failureReason)?.failureReason || 'upstream'
    };
}

export function unavailableSiriResult(reason) {
    return {
        departures: [],
        dataStatus: 'unavailable',
        lastSuccessfulUpdate: null,
        siri: {
            providerObservedAt: null,
            fetchedAt: null,
            requestedOffsetsMinutes: [0, 119],
            searchWindowMinutes: null,
            complete: false,
            failureReason: reason
        }
    };
}

export function qualifySiriResult(result, nowMs = Date.now()) {
    if (!result) return unavailableSiriResult('upstream');
    if (!Array.isArray(result.departures) || result.dataStatus === 'unavailable' || result.error) {
        return { ...unavailableSiriResult(result.siri?.failureReason || 'upstream'), ...result };
    }
    const metadata = result.siri;
    const observedAt = observationTimestamp(metadata?.providerObservedAt);
    const fetchedAt = observationTimestamp(metadata?.fetchedAt);
    let failureReason = null;
    if (!observedAt || !fetchedAt) {
        failureReason = 'unknownFreshness';
    } else if ([observedAt, fetchedAt].some((value) => {
        const age = nowMs - Date.parse(value);
        return age < 0 || age > SIRI_SNAPSHOT_MAX_AGE_MS;
    }) || result.dataStatus === 'stale') {
        failureReason = 'stale';
    }
    return {
        ...result,
        dataStatus: failureReason ? 'stale' : result.dataStatus,
        siri: { ...unavailableSiriResult(null).siri, ...metadata, failureReason }
    };
}

// Cancelling this waiter must not abort a refresh another caller is using.
export function waitForSiriResult(promise, { signal, timeoutMs = SIRI_DEPARTURE_DEADLINE_MS } = {}) {
    return new Promise((resolve) => {
        let finished = false;
        const finish = (result) => {
            if (finished) return;
            finished = true;
            clearTimeout(timer);
            signal?.removeEventListener('abort', cancelled);
            resolve(result);
        };
        const cancelled = () => finish(unavailableSiriResult('cancelled'));
        const timer = setTimeout(() => finish(unavailableSiriResult('timeout')), timeoutMs);
        if (signal?.aborted) {
            cancelled();
            return;
        }
        signal?.addEventListener('abort', cancelled, { once: true });
        promise.then((result) => finish(qualifySiriResult(result)), () => finish(unavailableSiriResult('upstream')));
    });
}
