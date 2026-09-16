const HOUR = 3600000;
const RAIL_MODES = new Set(['rail', 'replacementBus']);
const blanketWarnings = new Set([
    'Some live services could not be matched safely to this timetable.',
    'Live updates could not be matched safely. These results use scheduled times.',
    'Live updates are available for some services. Other services and later connections use scheduled times.',
    'Some live updates could not be retrieved.',
    'The live lookup limit was reached; some services have not been checked.'
]);
const instant = value => typeof value === 'number' ? value : Date.parse(value);
const unique = values => [...new Set(values)];
const neutralWarning = 'Live information is not yet available for this train; scheduled times are shown.';

function railLegKey(leg) {
    return JSON.stringify([leg.scheduledServiceId ?? leg.serviceId ?? leg.operator,
        leg.from.crs, leg.to.crs, leg.scheduledDeparture ?? leg.departure, leg.scheduledArrival ?? leg.arrival]);
}

function confirmed(leg) {
    if (!leg.live) return false;
    if (leg.live.cancelled === true || leg.live.status === 'cancelled') return true;
    return leg.live.status !== 'unknown' && Number.isFinite(instant(leg.live.departure))
        && Number.isFinite(instant(leg.live.arrival));
}

/** Describe the live coverage of this visible page. Board diagnostics concern
 * many other trains, so they must not become warnings on every journey returned.
 * This changes presentation only and never invents a live forecast.
 */
export function presentLivePage(journeys, live, context) {
    const now = context.now;
    const visited = new Set(context.visited || []);
    const pending = new Set(context.pendingServiceIds || []);
    const diagnostics = context.diagnostics || [];
    const errors = context.errors || [];
    const nearTerm = new Map();
    const later = new Set();
    const gapWarning = leg => {
        const id = leg.scheduledServiceId ?? leg.serviceId;
        const relevant = diagnostics.filter(diagnostic => diagnostic.candidateServiceIds.includes(id));
        if (relevant.some(diagnostic => ['ambiguous', 'mismatch'].includes(diagnostic.reason))) {
            return 'Live information could not be matched safely to this train; scheduled times are shown.';
        }
        if (relevant.some(diagnostic => diagnostic.reason === 'missingDetail' && errors.some(error =>
            error.serviceID === diagnostic.serviceID && error.station === diagnostic.station && error.reason !== 'requestLimit'))) {
            return 'Live information for this train could not be retrieved; scheduled times are shown.';
        }
        if (context.limited && (pending.has(id) || !visited.has(leg.from.crs))) {
            return 'This train has not been checked because the live lookup limit was reached; scheduled times are shown.';
        }
        return neutralWarning;
    };
    const presented = journeys.map(journey => ({ ...journey, legs: journey.legs.map(leg => {
        if (leg.kind !== 'vehicle' || !RAIL_MODES.has(leg.mode)) return leg;
        const departure = instant(leg.live?.departure ?? leg.scheduledDeparture ?? leg.departure);
        const key = railLegKey(leg);
        if (departure > now + 4 * HOUR) { later.add(key); return leg; }
        if (!Number.isFinite(departure) || departure < now - 2 * HOUR) return leg;
        const value = nearTerm.get(key) || { checked: false, confirmed: false };
        value.checked ||= Boolean(leg.live);
        value.confirmed ||= confirmed(leg);
        nearTerm.set(key, value);
        // Partial annotations carry their own uncertainty/disruption notes. A
        // failed observation elsewhere must not relabel them as a bad match.
        return leg.live ? leg : { ...leg, warnings: unique([...(leg.warnings || []), gapWarning(leg)]) };
    }) }));
    const nearTermRailLegs = nearTerm.size;
    const confirmedRailLegs = [...nearTerm.values()].filter(value => value.confirmed).length;
    const checkedRailLegs = [...nearTerm.values()].filter(value => value.checked).length;
    const status = !journeys.length ? live?.status : !nearTermRailLegs ? 'outsideWindow' : confirmedRailLegs === nearTermRailLegs ? 'live'
        : checkedRailLegs ? 'partial' : 'unavailable';
    const warnings = (live?.warnings || []).filter(warning => !blanketWarnings.has(warning));
    if (nearTermRailLegs && status === 'partial') warnings.push('Some train times shown are scheduled because live information is incomplete.');
    if (nearTermRailLegs && status === 'unavailable') warnings.push('Live information is not available for these trains; scheduled times are shown.');
    if (later.size) warnings.push('Later trains use scheduled times; live updates are checked nearer departure.');
    const presentedLive = { ...live, status, warnings: unique(warnings),
        coverage: { nearTermRailLegs, confirmedRailLegs, scheduledLaterRailLegs: later.size } };
    if (journeys.length && !nearTermRailLegs) {
        // No observation on this page is being described; do not attach another
        // page's observation time or manufacture a timestamp for future trains.
        delete presentedLive.updatedAt;
        delete presentedLive.expiresAt;
    }
    return { journeys: presented, live: presentedLive };
}
