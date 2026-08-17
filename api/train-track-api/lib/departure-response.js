const VALID_DATA_STATUSES = new Set(['live', 'partial', 'stale', 'unavailable']);

export function shouldIncludeDepartureStatus(value) {
    const normalized = String(Array.isArray(value) ? value[0] : value || '')
        .trim()
        .toLowerCase();
    return normalized === 'true' || normalized === '1';
}

export function formatDepartureJourneyResult(key, data, includeStatus = false) {
    const departures = Array.isArray(data?.departures) ? data.departures : [];
    if (!includeStatus) {
        return { [key]: departures };
    }

    const fallbackStatus = data?.error ? 'unavailable' : 'live';
    const dataStatus = VALID_DATA_STATUSES.has(data?.dataStatus)
        ? data.dataStatus
        : fallbackStatus;

    return {
        [key]: {
            departures,
            data_status: dataStatus,
            last_successful_update: data?.lastSuccessfulUpdate || null
        }
    };
}
