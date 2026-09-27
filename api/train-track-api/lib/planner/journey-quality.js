// A passenger should not ride away from a station and then return to board
// there later. Include intermediate public calls: checking only interchange
// endpoints misses excursions such as London Bridge -> Luton -> Tulse Hill.
// Passing a station without permission to board is not a shortcut, and an
// explicitly requested via can make a return necessary.
export function hasAvoidableBacktracking(path, services, request, reverse = false, check = () => {}) {
    const legs = [];
    for (let node = path; node; node = node.previous) legs.push(node.leg);
    if (!reverse) legs.reverse();
    const via = request.via ?? [];
    let progress = 0, previousStation = request.origin;
    if (via[progress] === request.origin) progress++;
    const visited = new Map([[request.origin, { progress, serviceId: null }]]);
    const visit = (station, canBoard, canAlight, serviceId) => {
        check();
        if (!station) return false;
        if (station !== previousStation && station === via[progress]) progress++;
        const earlier = visited.get(station);
        const returns = station !== previousStation && canBoard && earlier
            && earlier.progress === progress && (serviceId === null || earlier.serviceId !== serviceId);
        if (canAlight || station === previousStation && earlier?.serviceId === null && serviceId !== null) {
            visited.set(station, { progress, serviceId });
        }
        previousStation = station;
        return Boolean(returns);
    };
    for (const leg of legs) {
        if (leg.kind === 'vehicle') {
            const service = services.get(leg.serviceId);
            for (let position = leg.boardIndex; position <= leg.alightIndex; position++) {
                const call = service.calls[position];
                if (!call.canBoard && !call.canAlight) continue;
                if (visit(call.station, call.canBoard || position === leg.alightIndex,
                    call.canAlight, service.id)) return true;
            }
        } else if (leg.from !== leg.to && visit(leg.to, true, true, null)) return true;
    }
    return false;
}
