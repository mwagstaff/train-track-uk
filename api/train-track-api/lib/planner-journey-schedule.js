import { createHash } from 'node:crypto';
import { PlannerLiveProvider, createLiveRequestBudget } from './planner/live-provider.js';
import { discoverLiveMatches, matchLiveObservations } from './planner/live-matching.js';
import { matchStaffObservations } from './planner/live-staff-matching.js';

export const PLANNER_SCHEDULE_PREFIX = 'planner:';
export const PLANNER_LEAD_MINUTES = [15, 30, 45, 60, 90, 120];
const MINUTE = 60000;
const londonClock = new Intl.DateTimeFormat('en-GB', { timeZone: 'Europe/London', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const clock = value => londonClock.format(new Date(value));
const date = value => {
    if (typeof value !== 'string' || !/(Z|[+-]\d{2}:\d{2})$/.test(value) || !Number.isFinite(Date.parse(value))) {
        throw new Error('Journey times must include a date and timezone');
    }
    return new Date(value).toISOString();
};
const label = value => typeof value === 'string' ? value.trim().slice(0, 160) : '';
const place = value => {
    if (!/^[A-Z]{3}$/.test(value?.crs) || !label(value?.name)) throw new Error('Invalid journey station');
    return { crs: value.crs, name: label(value.name) };
};

// A durable, dated itinerary, independent of the planner's short-lived result cache.
export function normalizePlannerSchedule(input, now = Date.now()) {
    if (!input || !PLANNER_LEAD_MINUTES.includes(input.leadMinutes)) throw new Error('Choose a lead time between 15 and 120 minutes');
    if (input.showAllDepartures !== undefined && typeof input.showAllDepartures !== 'boolean') throw new Error('Show all departures must be true or false');
    if (!Array.isArray(input.legs) || !input.legs.length || input.legs.length > 32) throw new Error('Invalid planned itinerary');
    const legs = input.legs.map(leg => {
        const departure = date(leg.departure), arrival = date(leg.arrival);
        if (Date.parse(arrival) < Date.parse(departure)) throw new Error('Arrival precedes departure');
        const calls = (Array.isArray(leg.calls) ? leg.calls : []).slice(0, 256).map(call => ({
            station: place(call.station),
            arrival: call.arrival ? date(call.arrival) : null,
            departure: call.departure ? date(call.departure) : null
        }));
        const rail = leg.kind === 'vehicle' && leg.mode === 'rail';
        if (rail && (!label(leg.uid) || !/^\d{4}-\d{2}-\d{2}$/.test(leg.originDate) || !label(leg.operator))) {
            throw new Error('The selected train has no stable timetable identity');
        }
        const transferMinutes = Number.isFinite(leg.transferMinutes) ? Math.max(0, Math.min(1440, leg.transferMinutes)) : 0;
        return { kind: label(leg.kind), mode: label(leg.mode), from: place(leg.from), to: place(leg.to), departure, arrival, transferMinutes,
            uid: rail ? label(leg.uid) : null, originDate: rail ? leg.originDate : null,
            operator: label(leg.operator) || null, calls };
    });
    for (let index = 1; index < legs.length; index++) {
        if (legs[index - 1].to.crs !== legs[index].from.crs || Date.parse(legs[index].departure) < Date.parse(legs[index - 1].arrival)) {
            throw new Error('Journey legs must be connected and in time order');
        }
    }
    const firstTrain = legs.find(isRail);
    if (!firstTrain) throw new Error('Choose a journey containing a train');
    if (Date.parse(firstTrain.departure) <= now) throw new Error('This journey has already departed');
    const identity = createHash('sha256').update(JSON.stringify(legs.map(({ calls, ...leg }) => leg))).digest('hex');
    return { leadMinutes: input.leadMinutes, showAllDepartures: input.showAllDepartures === true, legs, identity,
        startsAt: new Date(Date.parse(firstTrain.departure) - input.leadMinutes * MINUTE).toISOString(),
        departure: firstTrain.departure, arrival: legs.at(-1).arrival,
        expiresAt: new Date(Date.parse(legs.at(-1).arrival) + 120 * MINUTE).toISOString() };
}

export const isRail = leg => leg.kind === 'vehicle' && leg.mode === 'rail';
export const plannerScheduleKey = subscription => `${PLANNER_SCHEDULE_PREFIX}${subscription.id}`;

function networkFor(leg) {
    const calls = leg.calls.map((call, index) => ({ station: call.station.crs, sequence: index,
        arrival: call.arrival ? Date.parse(call.arrival) : null,
        departure: call.departure ? Date.parse(call.departure) : null,
        canAlight: Boolean(call.arrival), canBoard: Boolean(call.departure) }));
    return { services: [{ id: 'selected', uid: leg.uid, originDate: leg.originDate, operator: leg.operator, mode: 'rail', calls }],
        stations: new Map(leg.calls.map(call => [call.station.crs, { crs: call.station.crs, name: call.station.name, minimumChangeMinutes: 0 }])),
        rules: { tsi: [], links: [] } };
}

export class PlannerScheduleResolver {
    constructor(provider = new PlannerLiveProvider()) { this.provider = provider; }

    async resolve(leg, now = Date.now()) {
        if (!isRail(leg) || leg.calls.length < 2) return null;
        const network = networkFor(leg);
        const origin = network.services[0].calls.findIndex(call => call.station === leg.from.crs && call.departure === Date.parse(leg.departure));
        const destination = network.services[0].calls.findIndex((call, index) => index > origin && call.station === leg.to.crs && call.arrival === Date.parse(leg.arrival));
        if (origin < 0 || destination < 0) return null;
        const budget = createLiveRequestBudget(10);
        const options = { budget, signal: AbortSignal.timeout(12000), now };
        let update;
        let actualDeparture = false, actualArrival = false;
        if (this.provider.supportsStaffRecovery()) {
            const records = await this.provider.fetchStaffBoards([{ station: leg.from.crs, departure: Date.parse(leg.departure) }], options);
            update = matchStaffObservations(network, records.boards, { now, serviceIds: ['selected'] }).services[0];
            if (update) {
                const item = records.boards.flatMap(record => record.services).find(item => item.uid === leg.uid
                    && item.sdd?.slice(0, 10) === leg.originDate && item.operatorCode === leg.operator);
                const locations = [...(item?.previousLocations || []), { ...item, crs: leg.from.crs }, ...(item?.subsequentLocations || [])]
                    .filter(call => !call.isPass && !call.isOperational && !call.isOperationalCall);
                const arrival = locations[destination];
                actualDeparture = item?.departureType === 'Actual' && item.atdSpecified !== false
                    && Number.isFinite(update.calls.find(call => call.index === origin)?.departure);
                actualArrival = arrival?.arrivalType === 'Actual' && arrival.ataSpecified !== false
                    && Number.isFinite(update.calls.find(call => call.index === destination)?.arrival);
            }
        }
        if (!update) {
            const boards = await this.provider.fetchBoards([leg.from.crs], options);
            const matches = discoverLiveMatches(network, boards.boards, { now });
            const details = await this.provider.fetchDetails(matches.slice(0, 6).map(match => ({ station: match.station, serviceID: match.serviceID })), options);
            // Never merge two different board IDs that could represent competing trains.
            const verified = details.details.filter(detail => matchLiveObservations(network, { boards: boards.boards, details: [detail] }, { now }).services.length === 1);
            if (verified.length !== 1) return null;
            update = matchLiveObservations(network, { boards: boards.boards, details: verified }, { now }).services[0];
            const detail = verified[0].detail;
            const isActual = value => typeof value === 'string' && (/^(?:[01]\d|2[0-3]):[0-5]\d$/.test(value) || value.toLowerCase() === 'on time');
            actualDeparture = isActual(detail.atd);
            const arrival = detail.subsequentCallingPoints?.[0]?.callingPoint?.find(call => call.crs === leg.to.crs && call.st === clock(leg.arrival));
            actualArrival = isActual(arrival?.at);
        }
        const from = update.calls.find(call => call.index === origin);
        const to = update.calls.find(call => call.index === destination);
        return { from, to, actualDeparture, actualArrival, observedAt: Math.min(from?.observedAt ?? now, to?.observedAt ?? now) };
    }
}

export function plannerContent(subscription, state, now = Date.now()) {
    const plan = subscription.plannerJourney;
    const leg = plan.legs[state.legIndex];
    const live = state.live;
    const rail = isRail(leg);
    const enRoute = rail && live?.actualDeparture && !live?.actualArrival;
    const cancelled = live?.from?.cancelled === true || live?.to?.cancelled === true;
    const arrivalPresentation = enRoute || state.completed;
    const estimated = arrivalPresentation ? live?.to?.arrival : live?.from?.departure;
    const scheduled = arrivalPresentation ? leg.arrival : leg.departure;
    const delay = Number.isFinite(estimated) ? Math.max(0, Math.round((estimated - Date.parse(scheduled)) / MINUTE)) : 0;
    const title = `${plan.legs[0].from.name} → ${plan.legs.at(-1).to.name}`;
    let status = rail ? (live ? (delay ? `${delay} min late` : 'On time') : 'Scheduled · live updates unavailable') : `Transfer to ${leg.to.name}`;
    if (live?.from?.departureUnknown || live?.to?.arrivalUnknown) status = 'Delayed · time not confirmed';
    if (cancelled) status = 'Cancelled · choose another journey';
    if (state.missedConnection) status = 'Connection missed · choose another journey';
    if (state.completed) status = 'Journey complete';
    return { fromCRS: leg.from.crs, toCRS: leg.to.crs, routeTitle: title,
        deepLinkFromCRS: plan.legs[0].from.crs, deepLinkToCRS: plan.legs.at(-1).to.crs,
        destinationTitle: leg.to.name, arrivalLabel: rail && !cancelled ? `Arr ${clock(live?.to?.arrival ?? leg.arrival)}` : null,
        scheduledDeparture: clock(leg.departure), length: live?.from?.length ?? null,
        platform: (enRoute ? live?.to?.platform : live?.from?.platform) || '',
        estimated: clock(estimated ?? scheduled), isCancelled: cancelled, statusText: status, delayMinutes: delay,
        upcomingDepartures: [], lastUpdated: Math.floor((live?.observedAt ?? now) / 1000),
        activityID: null, revision: 0, appIsActive: false, journeyUpdatesEnabled: true,
        scheduleKey: plannerScheduleKey(subscription), windowStart: null, windowEnd: null,
        journeyPhase: state.completed ? 'arrived' : enRoute ? 'en_route' : 'pending_start',
        journeyStartName: leg.from.name, journeyDestinationName: leg.to.name };
}

export class PlannerJourneyScheduler {
    constructor(owner, { resolver = new PlannerScheduleResolver(), now = Date.now, routeContent } = {}) {
        this.owner = owner;
        this.resolver = resolver;
        this.now = now;
        this.tasks = owner.scheduledStartTasks;
        this.routeContent = routeContent;
    }

    find(deviceId, key) {
        if (!key?.startsWith(PLANNER_SCHEDULE_PREFIX)) return null;
        const subscription = this.owner.subscriptions.get(key.slice(PLANNER_SCHEDULE_PREFIX.length));
        return subscription?.deviceId === deviceId && subscription.plannerJourney ? subscription : null;
    }

    async snapshot(subscription) {
        const now = this.now(), plan = subscription.plannerJourney;
        const state = subscription.plannerState ||= { legIndex: plan.legs.findIndex(isRail) };
        const showAllDepartures = plan.showAllDepartures === true;
        if (state.checkedAt && now - state.checkedAt < 15000 && state.content
            && Boolean(state.contentShowsAllDepartures) === showAllDepartures) return state.content;
        let leg = plan.legs[state.legIndex];
        if (!state.completed && !state.missedConnection) {
            state.live = null;
            if (isRail(leg)) {
                try { state.live = await this.resolver.resolve(leg, now); } catch { /* Retain the dated timetable, never substitute another train. */ }
                if (state.live?.actualArrival && !state.live?.to?.cancelled) {
                    state.previousArrival = state.live.to?.arrival ?? now;
                    if (state.legIndex === plan.legs.length - 1) state.completed = true;
                    else { state.legIndex++; state.live = null; }
                }
            } else if (now >= Math.max(Date.parse(leg.arrival), (state.previousArrival ?? Date.parse(leg.departure)) + leg.transferMinutes * MINUTE)) {
                state.previousArrival = Math.max(Date.parse(leg.arrival), (state.previousArrival ?? Date.parse(leg.departure)) + leg.transferMinutes * MINUTE);
                if (state.legIndex === plan.legs.length - 1) state.completed = true;
                else state.legIndex++;
            }
            leg = plan.legs[state.legIndex];
            if (isRail(leg) && state.previousArrival && state.previousArrival > Date.parse(leg.departure)) {
                // A delayed connecting train may still be catchable; verify before flagging it.
                try { state.live = await this.resolver.resolve(leg, now); } catch { state.live = null; }
                if (state.live?.actualDeparture && (state.live.from?.departure ?? Infinity) < state.previousArrival) state.missedConnection = true;
            }
        }
        const content = showAllDepartures && isRail(leg)
            ? await this.routeContent(subscription) : plannerContent(subscription, state, now);
        if ((plan.showAllDepartures === true) !== showAllDepartures) return this.snapshot(subscription);
        state.checkedAt = now;
        state.contentShowsAllDepartures = showAllDepartures;
        state.content = content;
        await this.owner._saveSubscription(subscription);
        return state.content;
    }

    async poll(subscription) {
        const prior = this.tasks.get(subscription.deviceId) || Promise.resolve();
        const task = prior.catch(() => {}).then(() => this.startIfDue(subscription));
        this.tasks.set(subscription.deviceId, task);
        try { await task; } finally { if (this.tasks.get(subscription.deviceId) === task) this.tasks.delete(subscription.deviceId); }
    }

    async startIfDue(subscription) {
        const plan = subscription.plannerJourney, now = this.now();
        const retryDue = subscription.plannerState?.status === 'retry' && now >= subscription.plannerState.retryAt;
        if (this.owner.subscriptions.get(subscription.id) !== subscription || this.owner.isHolidayModeEnabled(subscription.deviceId)
            || now < Date.parse(plan.startsAt) || (subscription.plannerState?.status && !retryDue)) return;
        if (now >= Date.parse(plan.departure)) {
            subscription.plannerState = { ...subscription.plannerState, status: 'expired' };
            await this.owner._saveSubscription(subscription);
            return;
        }
        const token = await this.owner.getPlannerPushToken(subscription.deviceId);
        if (!token?.pushToStartToken) return;
        const content = await this.snapshot(subscription);
        if (this.owner.subscriptions.get(subscription.id) !== subscription || this.owner.isHolidayModeEnabled(subscription.deviceId)
            || this.now() >= Date.parse(plan.departure)) return;
        const occupied = this.owner.deviceHasLiveActivity(subscription.deviceId) || this.owner.activeAdHocJourneyForDevice(subscription.deviceId);
        if (occupied) {
            subscription.plannerState.status = 'conflict';
            await this.owner._saveSubscription(subscription);
            await this.owner.pushClient.sendNotification(subscription.pushToken, { aps: { alert: {
                title: 'Scheduled journey not started', body: `${content.routeTitle}: another journey is still being tracked.`
            }, sound: 'default' } }, { useSandbox: subscription.useSandbox, event: 'planner_schedule_conflict' });
            return;
        }
        // Persist the claim before APNs: retries/restarts must not create duplicate activities.
        subscription.plannerState.status = 'starting';
        subscription.plannerState.attempts = (subscription.plannerState.attempts || 0) + 1;
        await this.owner._saveSubscription(subscription);
        if (this.owner.subscriptions.get(subscription.id) !== subscription || this.owner.isHolidayModeEnabled(subscription.deviceId)) return;
        if (this.owner.deviceHasLiveActivity(subscription.deviceId, subscription.id) || this.owner.activeAdHocJourneyForDevice(subscription.deviceId)) {
            subscription.plannerState.status = null;
            return this.startIfDue(subscription);
        }
        const payload = { aps: { timestamp: Math.floor(now / 1000), event: 'start', 'input-push-token': 1,
            'attributes-type': 'JourneyActivityAttributes', attributes: { displayName: content.routeTitle },
            'content-state': content, 'stale-date': Math.floor(now / 1000) + 300,
            alert: { title: 'Journey updates', body: `${clock(plan.departure)} ${content.routeTitle}`, sound: 'default' } } };
        let result;
        try {
            result = await this.owner.liveActivityPushClient.sendLiveActivityUpdate(token.pushToStartToken, payload,
                { useSandbox: token.useSandbox === true, disableRetries: true, event: 'live_activity_start', context: { subscription_id: subscription.id, source: 'planner' } });
        } catch {
            // Delivery is uncertain. Re-sending could create a second activity.
            subscription.plannerState.status = 'unconfirmed';
            await this.owner._saveSubscription(subscription);
            return;
        }
        if (this.owner.subscriptions.get(subscription.id) !== subscription) return;
        if (result?.status >= 200 && result.status < 300) subscription.plannerState.status = 'started';
        else if ((result?.status === 429 || result?.status >= 500) && subscription.plannerState.attempts < 3) {
            subscription.plannerState.status = 'retry';
            subscription.plannerState.retryAt = this.now() + 30000;
        } else subscription.plannerState.status = Number.isFinite(result?.status) ? 'failed' : 'unconfirmed';
        await this.owner._saveSubscription(subscription);
    }
}
