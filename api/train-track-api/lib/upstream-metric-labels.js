// Keep URL labels bounded: station pairs, request times and service IDs must
// never create a new Prometheus series for every upstream request.
export function normalizeUpstreamUrl(url) {
    try {
        const segments = new URL(url).pathname.split('/');
        for (const [operation, parameter] of [
            ['GetDepartureBoard', ':station'],
            ['GetDepBoardWithDetails', ':station'],
            ['GetServiceDetails', ':serviceId']
        ]) {
            if (segments.includes(operation)) return `/${operation}/${parameter}`;
        }
        return 'other';
    } catch {
        return 'unknown';
    }
}
