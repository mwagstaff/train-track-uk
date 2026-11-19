// Resolve a live board's opaque service reference using dated timetable evidence.
// A route/time alone is insufficient: require ordered calls and reject ambiguity.
export function liveScheduleIdentity(leg, services) {
    const departure = Date.parse(leg.scheduledDeparture ?? leg.departure);
    const arrival = Date.parse(leg.scheduledArrival ?? leg.arrival);
    const points = leg.serviceCallingPoints ?? leg.callingPoints ?? [];
    if (!leg.operator || !Number.isFinite(departure) || !Number.isFinite(arrival) || points.length < 2) return null;
    const matches = new Map();
    for (const service of services) {
        if (service.mode !== 'rail' || service.operator !== leg.operator || !service.uid || !service.originDate) continue;
        const calls = service.calls;
        const starts = calls.flatMap((call, index) => call.station === leg.from.crs && call.departure === departure ? [index] : []);
        const ends = calls.flatMap((call, index) => call.station === leg.to.crs && call.arrival === arrival ? [index] : []);
        if (starts.length !== 1 || ends.length !== 1 || ends[0] <= starts[0]) continue;
        let positions = [-1];
        for (const point of points) {
            const at = Date.parse(point.scheduledArrival ?? point.arrival);
            const dt = Date.parse(point.scheduledDeparture ?? point.departure);
            if (!Number.isFinite(at) && !Number.isFinite(dt)) { positions = []; break; }
            const next = [];
            for (let index = 0; index < calls.length; index++) {
                const call = calls[index];
                if (call.station !== point.station.crs || (Number.isFinite(at) && call.arrival !== at)
                    || (Number.isFinite(dt) && call.departure !== dt)) continue;
                for (const previous of positions) if (index > previous) next.push(index);
            }
            // More than one ordered mapping is ambiguous, even within one train.
            positions = next;
            if (!positions.length || positions.length > 256) break;
        }
        if (positions.length === 1) matches.set(`${service.uid}|${service.originDate}`, service);
    }
    return matches.size === 1 ? [...matches.values()][0] : null;
}
