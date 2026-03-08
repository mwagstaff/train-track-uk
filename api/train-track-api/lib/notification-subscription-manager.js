import moment from 'moment';
import crypto from 'crypto';
import { getTrainTimes } from './realtime-trains-api.js';
import { NotificationPushClient } from './notification-push-client.js';
import redis from './redis-client.js';
import { recordNotificationEvent } from './admin-data-store.js';

const DEFAULT_POLL_INTERVAL_SECONDS = Number(process.env.NOTIFICATION_POLL_INTERVAL_SECONDS || '30');
const MAX_SUBSCRIPTIONS_PER_DEVICE = Number(process.env.NOTIFICATION_MAX_SUBSCRIPTIONS || '3');
const MAX_WINDOW_MINUTES = 120;
const SCHEDULED_SOURCE = 'scheduled';
const LIVE_SESSION_SOURCE = 'live_session';

const VALID_TYPES = new Set(['summary', 'delays', 'platform']);
const DAY_MAP = {
    sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6
};

// Redis key helpers
const REDIS_SUB_IDS_KEY = 'tt:notification:sub_ids';
const redisSubKey = (id) => `tt:notification:sub:${id}`;

class NotificationSubscriptionManager {
    constructor() {
        this.subscriptions = new Map();
        this.pushClient = new NotificationPushClient();
        this.pollIntervalMs = DEFAULT_POLL_INTERVAL_SECONDS * 1000;
        this.isPolling = false;
        // Polling loop is started by init() after Redis hydration.
    }

    // Load all persisted subscriptions from Redis, then start the polling loop.
    // Must be called once at server startup before handling requests.
    async init() {
        try {
            const ids = await redis.smembers(REDIS_SUB_IDS_KEY);
            if (ids.length > 0) {
                const pipeline = redis.pipeline();
                for (const id of ids) {
                    pipeline.get(redisSubKey(id));
                }
                const results = await pipeline.exec();
                let loaded = 0;
                for (const [err, val] of results) {
                    if (err || !val) continue;
                    try {
                        const sub = JSON.parse(val);
                        this.subscriptions.set(sub.id, sub);
                        loaded++;
                    } catch (e) {
                        console.error('[notifications] Failed to parse subscription from Redis:', e?.message);
                    }
                }
                console.log(`[notifications] Loaded ${loaded} subscription(s) from Redis`);
            } else {
                console.log('[notifications] No subscriptions found in Redis');
            }
        } catch (err) {
            console.error('[notifications] Failed to load subscriptions from Redis:', err?.message || err);
        }
        this.startPollingLoop();
    }

    startPollingLoop() {
        setInterval(() => {
            this.pollAll().catch((error) => {
                console.error(`Notification poll failed: ${error?.message || error}`);
            });
        }, this.pollIntervalMs).unref?.();
    }

    // --- Redis persistence helpers ---

    async _saveSubscription(sub) {
        try {
            await redis.multi()
                .set(redisSubKey(sub.id), JSON.stringify(sub))
                .sadd(REDIS_SUB_IDS_KEY, sub.id)
                .exec();
        } catch (err) {
            console.error('[notifications] Failed to save subscription to Redis:', err?.message || err);
        }
    }

    async _deleteFromRedis(id) {
        try {
            await redis.multi()
                .del(redisSubKey(id))
                .srem(REDIS_SUB_IDS_KEY, id)
                .exec();
        } catch (err) {
            console.error('[notifications] Failed to delete subscription from Redis:', err?.message || err);
        }
    }

    // --- Public API ---

    listSubscriptions(deviceId, { source = null } = {}) {
        return Array.from(this.subscriptions.values())
            .filter((sub) => {
                if (sub.deviceId !== deviceId) return false;
                if (source && this.subscriptionSource(sub) !== source) return false;
                if (this.isExpiredLiveSession(sub)) {
                    this.deleteSubscription({ deviceId: sub.deviceId, subscriptionId: sub.id }).catch((error) => {
                        console.error('[notifications] Failed to delete expired live session:', error?.message || error);
                    });
                    return false;
                }
                return true;
            })
            .map((sub) => this.publicSubscription(sub));
    }

    listAllSubscriptions() {
        return Array.from(this.subscriptions.values()).map((sub) => this.publicSubscription(sub));
    }

    async upsertSubscription(payload) {
        const {
            deviceId,
            pushToken,
            routeKey: routeKeyInput,
            daysOfWeek: daysInput,
            notificationTypes: typesInput,
            legs: legsInput,
            subscriptionId,
            useSandbox,
            muteOnArrival,
            source: sourceInput,
            activeUntil
        } = payload || {};

        if (!deviceId || !pushToken) {
            throw new Error('device_id and push_token are required');
        }
        const legs = Array.isArray(legsInput) ? legsInput : [];
        if (legs.length === 0) {
            throw new Error('At least one journey leg is required');
        }
        if (!legs.some((leg) => leg.enabled)) {
            throw new Error('At least one journey leg must be enabled');
        }

        const source = normalizeSource(sourceInput);
        const daysOfWeek = normalizeDays(daysInput);
        if (source === SCHEDULED_SOURCE && daysOfWeek.length === 0) {
            throw new Error('At least one day of week is required');
        }

        const notificationTypes = normalizeTypes(typesInput);
        if (notificationTypes.length === 0) {
            throw new Error('At least one notification type is required');
        }

        const normalizedLegs = legs.map((leg, index) => {
            const enabled = Boolean(leg.enabled);
            const windowStart = leg.window_start || leg.windowStart;
            const windowEnd = leg.window_end || leg.windowEnd;
            if (enabled && source === SCHEDULED_SOURCE) {
                const { startMinutes, endMinutes } = parseWindow(windowStart, windowEnd);
                const duration = endMinutes - startMinutes;
                if (duration < 0 || duration > MAX_WINDOW_MINUTES) {
                    throw new Error(`Time window must be within 2 hours for leg ${index + 1}`);
                }
            }
            return {
                from: leg.from,
                to: leg.to,
                fromName: leg.from_name || leg.fromName,
                toName: leg.to_name || leg.toName,
                enabled,
                windowStart,
                windowEnd
            };
        });

        const routeKey = routeKeyInput || buildRouteKey(normalizedLegs);
        if (!routeKey) {
            throw new Error('route_key is required');
        }

        const existing = Array.from(this.subscriptions.values()).find(
            (sub) => sub.deviceId === deviceId
                && sub.routeKey === routeKey
                && this.subscriptionSource(sub) === source
        );
        const deviceCount = this.countSubscriptionsForDevice(deviceId, { source });
        if (!existing && deviceCount >= MAX_SUBSCRIPTIONS_PER_DEVICE) {
            if (source === LIVE_SESSION_SOURCE) {
                throw new Error(`Maximum of ${MAX_SUBSCRIPTIONS_PER_DEVICE} live journeys reached`);
            }
            throw new Error(`Maximum of ${MAX_SUBSCRIPTIONS_PER_DEVICE} scheduled journeys reached`);
        }

        const nowIso = new Date().toISOString();
        const resolvedMuteOnArrival = muteOnArrival === undefined
            ? (existing?.muteOnArrival ?? true)
            : Boolean(muteOnArrival);
        const resolvedActiveUntil = source === LIVE_SESSION_SOURCE
            ? normalizeIsoDate(activeUntil) || existing?.activeUntil || nowIso
            : null;

        const subscription = {
            id: existing?.id || subscriptionId || crypto.randomUUID(),
            deviceId,
            pushToken,
            routeKey,
            daysOfWeek: daysOfWeek.length > 0 ? daysOfWeek : (existing?.daysOfWeek || []),
            notificationTypes,
            legs: normalizedLegs,
            useSandbox: Boolean(useSandbox),
            muteOnArrival: resolvedMuteOnArrival,
            source,
            activeUntil: resolvedActiveUntil,
            createdAt: existing?.createdAt || nowIso,
            updatedAt: nowIso,
            lastSummarySentByLeg: existing?.lastSummarySentByLeg || {},
            lastStateByLeg: existing?.lastStateByLeg || {},
            mutedByLegDay: existing?.mutedByLegDay || {},
            mutedAtByLegDay: existing?.mutedAtByLegDay || {},
            lastActiveAt: existing?.lastActiveAt || null
        };

        this.subscriptions.set(subscription.id, subscription);
        await this._saveSubscription(subscription);
        return this.publicSubscription(subscription);
    }

    async deleteSubscription({ deviceId, subscriptionId }) {
        const sub = this.subscriptions.get(subscriptionId);
        if (!sub) return false;
        if (deviceId && sub.deviceId !== deviceId) return false;
        this.subscriptions.delete(subscriptionId);
        await this._deleteFromRedis(subscriptionId);
        return true;
    }

    countSubscriptionsForDevice(deviceId, { source = null } = {}) {
        return Array.from(this.subscriptions.values()).filter((sub) => {
            if (sub.deviceId !== deviceId) return false;
            if (source && this.subscriptionSource(sub) !== source) return false;
            if (this.isExpiredLiveSession(sub)) return false;
            return true;
        }).length;
    }

    getActiveCounts(now = Date.now()) {
        return {
            last1m: this.countActiveWithin(60 * 1000, now),
            last5m: this.countActiveWithin(5 * 60 * 1000, now),
            last1h: this.countActiveWithin(60 * 60 * 1000, now),
            last24h: this.countActiveWithin(24 * 60 * 60 * 1000, now)
        };
    }

    countActiveWithin(windowMs, now = Date.now()) {
        const cutoff = now - windowMs;
        return Array.from(this.subscriptions.values()).filter((sub) => {
            const last = sub.lastActiveAt ? new Date(sub.lastActiveAt).getTime() : 0;
            return last >= cutoff;
        }).length;
    }

    async pollAll() {
        if (this.isPolling || this.subscriptions.size === 0) {
            return;
        }
        this.isPolling = true;
        try {
            await this.pruneExpiredLiveSessions();
            const jobs = Array.from(this.subscriptions.values()).map((sub) =>
                this.pollSubscription(sub).catch((error) => {
                    console.error(`Notification poll failed for ${sub.deviceId}/${sub.routeKey}: ${error?.message || error}`);
                    return null;
                })
            );
            await Promise.all(jobs);
        } finally {
            this.isPolling = false;
        }
    }

    async pollSubscription(subscription) {
        if (this.isExpiredLiveSession(subscription)) {
            await this.deleteSubscription({ deviceId: subscription.deviceId, subscriptionId: subscription.id });
            return;
        }
        for (const leg of subscription.legs) {
            if (!leg.enabled) continue;
            if (!shouldPollNow(subscription, leg)) continue;
            const legKey = `${leg.from}-${leg.to}`;
            if (this.isMutedToday(subscription, legKey)) continue;
            subscription.lastActiveAt = new Date().toISOString();
            // Fire-and-forget: persist lastActiveAt without blocking the poll.
            this._saveSubscription(subscription).catch((err) => {
                console.error('[notifications] Failed to persist lastActiveAt:', err?.message || err);
            });
            const snapshot = await getDeparturesSnapshot(leg.from, leg.to);
            if (!snapshot.departures.length) {
                continue;
            }

            if (subscription.notificationTypes.includes('summary')) {
                await this.sendSummaryIfNeeded(subscription, leg, legKey, snapshot);
            }

            await this.sendUpdateNotifications(subscription, leg, legKey, snapshot);
        }
    }

    async sendSummaryIfNeeded(subscription, leg, legKey, snapshot) {
        if (this.isMutedToday(subscription, legKey)) {
            return;
        }
        const todayKey = moment().format('YYYY-MM-DD');
        if (subscription.lastSummarySentByLeg[legKey] === todayKey) {
            return;
        }

        let startMinutes;
        let endMinutes;
        try {
            ({ startMinutes, endMinutes } = parseWindow(leg.windowStart, leg.windowEnd));
        } catch {
            return;
        }
        const nowMinutes = currentMinutes();
        if (nowMinutes < startMinutes || nowMinutes > endMinutes) {
            return;
        }

        const summary = buildSummaryMessage(subscription, leg, snapshot);
        if (!summary) {
            return;
        }

        const activeSubscription = this.getActiveSubscriptionForPush(subscription.id, leg, 'summary_pre_send');
        if (!activeSubscription) {
            return;
        }

        const pushResult = await this.pushClient.sendNotification(
            activeSubscription.pushToken,
            summary.payload,
            { useSandbox: activeSubscription.useSandbox, event: summary.type }
        );
        this.logSendEvent(activeSubscription, leg, summary, pushResult);
        console.log('[notifications] summary_push', JSON.stringify({
            subscription_id: activeSubscription.id,
            device_id: activeSubscription.deviceId,
            route_key: activeSubscription.routeKey,
            leg: legKey,
            use_sandbox: activeSubscription.useSandbox,
            status: pushResult?.status,
            reason: pushResult?.body?.reason || null
        }));
        if (pushResult?.isBadToken) {
            console.warn('[notifications] bad_token_delete', JSON.stringify({
                subscription_id: activeSubscription.id,
                device_id: activeSubscription.deviceId,
                route_key: activeSubscription.routeKey,
                context: 'sendSummaryIfNeeded'
            }));
            this.subscriptions.delete(activeSubscription.id);
            await this._deleteFromRedis(activeSubscription.id);
            return;
        }

        activeSubscription.lastSummarySentByLeg[legKey] = todayKey;
        // Fire-and-forget: persist the updated lastSummarySentByLeg.
        this._saveSubscription(activeSubscription).catch((err) => {
            console.error('[notifications] Failed to persist lastSummarySentByLeg:', err?.message || err);
        });
    }

    async sendUpdateNotifications(subscription, leg, legKey, snapshot) {
        if (this.isMutedToday(subscription, legKey)) {
            return;
        }
        const previous = subscription.lastStateByLeg[legKey] || {};
        const nextState = {};

        for (const dep of snapshot.departures) {
            const serviceID = dep.serviceID;
            const delayMinutes = calculateDelayMinutes(dep.scheduled, dep.estimated);
            const platform = dep.platform || 'TBC';
            const current = {
                delayMinutes,
                isCancelled: Boolean(dep.isCancelled),
                platform,
                estimated: dep.estimated || dep.scheduled,
                scheduled: dep.scheduled
            };
            nextState[serviceID] = current;

            const prev = previous[serviceID];
            if (!prev) {
                continue;
            }

            if (subscription.notificationTypes.includes('delays')) {
                if (current.isCancelled && !prev.isCancelled) {
                    await this.sendNotification(subscription, buildCancellationMessage(subscription, leg, current), leg);
                } else if (current.delayMinutes > 0 && current.delayMinutes !== prev.delayMinutes) {
                    await this.sendNotification(subscription, buildDelayMessage(subscription, leg, current), leg);
                }
            }

            if (subscription.notificationTypes.includes('platform')) {
                if (prev.platform && current.platform && prev.platform !== current.platform) {
                    await this.sendNotification(subscription, buildPlatformMessage(subscription, leg, current), leg);
                }
            }
        }

        subscription.lastStateByLeg[legKey] = nextState;
        // Fire-and-forget: persist the updated lastStateByLeg.
        this._saveSubscription(subscription).catch((err) => {
            console.error('[notifications] Failed to persist lastStateByLeg:', err?.message || err);
        });
    }

    async sendNotification(subscription, notification, leg = null) {
        if (!notification) return;
        const activeSubscription = this.getActiveSubscriptionForPush(subscription.id, leg, 'update_pre_send');
        if (!activeSubscription) {
            return;
        }
        const result = await this.pushClient.sendNotification(
            activeSubscription.pushToken,
            notification.payload,
            { useSandbox: activeSubscription.useSandbox, event: notification.type }
        );
        this.logSendEvent(activeSubscription, leg, notification, result);
        console.log('[notifications] update_push', JSON.stringify({
            subscription_id: activeSubscription.id,
            device_id: activeSubscription.deviceId,
            route_key: activeSubscription.routeKey,
            use_sandbox: activeSubscription.useSandbox,
            status: result?.status,
            reason: result?.body?.reason || null
        }));
        if (result?.isBadToken) {
            console.warn('[notifications] bad_token_delete', JSON.stringify({
                subscription_id: activeSubscription.id,
                device_id: activeSubscription.deviceId,
                route_key: activeSubscription.routeKey,
                context: 'sendNotification'
            }));
            this.subscriptions.delete(activeSubscription.id);
            await this._deleteFromRedis(activeSubscription.id);
        }
    }

    getActiveSubscriptionForPush(subscriptionId, leg, context) {
        const activeSubscription = this.subscriptions.get(subscriptionId);
        const legKey = leg ? `${leg.from}-${leg.to}` : null;

        if (!activeSubscription) {
            console.log('[notifications] suppress_push', JSON.stringify({
                subscription_id: subscriptionId,
                leg: legKey,
                context,
                reason: 'subscription_missing'
            }));
            return null;
        }

        if (legKey && this.isMutedToday(activeSubscription, legKey)) {
            console.log('[notifications] suppress_push', JSON.stringify({
                subscription_id: subscriptionId,
                device_id: activeSubscription.deviceId,
                route_key: activeSubscription.routeKey,
                leg: legKey,
                context,
                reason: 'muted'
            }));
            return null;
        }

        return activeSubscription;
    }

    logSendEvent(subscription, leg, notification, result) {
        const status = result?.status ?? null;
        const success = typeof status === 'number' && status >= 200 && status < 300;
        recordNotificationEvent({
            channel: 'notification',
            type: notification?.type || 'unknown',
            success,
            status,
            error: result?.error || result?.body?.reason || result?.reason || null,
            apns_environment: subscription.useSandbox ? 'sandbox' : 'prod',
            subscription_id: subscription.id,
            device_id: subscription.deviceId,
            route_key: subscription.routeKey,
            from_station: leg?.from || null,
            to_station: leg?.to || null,
            token: subscription.pushToken || null,
            is_bad_token: Boolean(result?.isBadToken),
            payload: notification?.payload ?? null,
            response: result || null,
            metadata: {
                notification_types: subscription.notificationTypes,
                days_of_week: subscription.daysOfWeek
            }
        }).catch((error) => {
            console.error('[admin] Failed to log notification send event:', error?.message || error);
        });
    }

    publicSubscription(subscription) {
        return {
            id: subscription.id,
            device_id: subscription.deviceId,
            route_key: subscription.routeKey,
            days_of_week: subscription.daysOfWeek,
            notification_types: subscription.notificationTypes,
            use_sandbox: subscription.useSandbox,
            mute_on_arrival: subscription.muteOnArrival,
            source: this.subscriptionSource(subscription),
            active_until: subscription.activeUntil || null,
            muted_by_leg_day: subscription.mutedByLegDay,
            muted_at_by_leg_day: subscription.mutedAtByLegDay,
            legs: subscription.legs.map((leg) => ({
                from: leg.from,
                to: leg.to,
                from_name: leg.fromName,
                to_name: leg.toName,
                enabled: leg.enabled,
                window_start: leg.windowStart,
                window_end: leg.windowEnd
            })),
            created_at: subscription.createdAt,
            updated_at: subscription.updatedAt
        };
    }

    async muteLegForDate({ deviceId, subscriptionId, from, to, date }) {
        const subscription = this.subscriptions.get(subscriptionId);
        if (!subscription) return null;
        if (deviceId && subscription.deviceId !== deviceId) return null;
        const legKey = `${from}-${to}`;
        const leg = subscription.legs.find((l) => l.from === from && l.to === to);
        if (!leg) return null;
        const todayKey = moment().format('YYYY-MM-DD');
        const dateKey = typeof date === 'string' && date ? date : todayKey;
        const mutedAt = new Date().toISOString();
        subscription.mutedByLegDay[legKey] = dateKey;
        subscription.mutedAtByLegDay[legKey] = mutedAt;
        await this._saveSubscription(subscription);

        // When muting for today (i.e. triggered by geofence arrival), send a
        // confirmation push so the user knows notifications have been muted.
        if (dateKey === todayKey) {
            let snapshot = null;
            try {
                snapshot = await getDeparturesSnapshot(leg.from, leg.to);
            } catch (error) {
                console.warn('[notifications] Failed to fetch departures snapshot for muted notification:', error?.message || error);
            }

            const mutedNotification = buildMutedMessage(subscription, leg, snapshot);
            const pushResult = await this.pushClient.sendNotification(
                subscription.pushToken,
                mutedNotification.payload,
                { useSandbox: subscription.useSandbox, event: mutedNotification.type }
            );
            this.logSendEvent(subscription, leg, mutedNotification, pushResult);
            console.log('[notifications] mute_on_arrival', JSON.stringify({
                subscription_id: subscription.id,
                device_id: subscription.deviceId,
                route_key: subscription.routeKey,
                leg: legKey,
                use_sandbox: subscription.useSandbox,
                status: pushResult?.status,
                reason: pushResult?.body?.reason || null
            }));
            if (pushResult?.isBadToken) {
                console.warn('[notifications] bad_token_delete', JSON.stringify({
                    subscription_id: subscription.id,
                    device_id: subscription.deviceId,
                    route_key: subscription.routeKey,
                    context: 'muteLegForDate'
                }));
                this.subscriptions.delete(subscription.id);
                await this._deleteFromRedis(subscription.id);
                return null;
            }
        }

        return dateKey;
    }

    isMutedToday(subscription, legKey) {
        const mutedDate = subscription.mutedByLegDay?.[legKey];
        if (!mutedDate) return false;
        const todayKey = moment().format('YYYY-MM-DD');
        return mutedDate === todayKey;
    }

    getSubscriptionCount() {
        return this.subscriptions.size;
    }

    subscriptionSource(subscription) {
        return normalizeSource(subscription?.source);
    }

    isExpiredLiveSession(subscription, now = Date.now()) {
        if (this.subscriptionSource(subscription) !== LIVE_SESSION_SOURCE) {
            return false;
        }
        const activeUntil = Date.parse(subscription?.activeUntil || '');
        if (!Number.isFinite(activeUntil)) {
            return false;
        }
        return activeUntil <= now;
    }

    async pruneExpiredLiveSessions(now = Date.now()) {
        const expiredIds = Array.from(this.subscriptions.values())
            .filter((sub) => this.isExpiredLiveSession(sub, now))
            .map((sub) => sub.id);
        if (expiredIds.length === 0) return;
        await Promise.all(expiredIds.map((id) => this.deleteSubscription({ subscriptionId: id })));
    }
}

function normalizeDays(daysInput) {
    const raw = Array.isArray(daysInput) ? daysInput : [];
    const result = new Set();
    for (const day of raw) {
        if (typeof day === 'number') {
            const label = Object.keys(DAY_MAP).find((key) => DAY_MAP[key] === day);
            if (label) result.add(label);
        } else if (typeof day === 'string') {
            const lower = day.trim().toLowerCase();
            if (DAY_MAP[lower] !== undefined) {
                result.add(lower);
            }
        }
    }
    return Array.from(result);
}

function normalizeTypes(typesInput) {
    const raw = Array.isArray(typesInput) ? typesInput : [];
    return raw
        .map((t) => (typeof t === 'string' ? t.trim().toLowerCase() : ''))
        .filter((t) => VALID_TYPES.has(t));
}

function normalizeSource(value) {
    const raw = typeof value === 'string' ? value.trim().toLowerCase() : '';
    return raw === LIVE_SESSION_SOURCE ? LIVE_SESSION_SOURCE : SCHEDULED_SOURCE;
}

function buildRouteKey(legs) {
    if (!Array.isArray(legs) || legs.length === 0) return null;
    const parts = [legs[0].from];
    for (const leg of legs) {
        parts.push(leg.to);
    }
    return parts.join('-');
}

function parseWindow(windowStart, windowEnd) {
    const startMinutes = parseTimeToMinutes(windowStart);
    const endMinutes = parseTimeToMinutes(windowEnd);
    if (startMinutes === null || endMinutes === null) {
        throw new Error('window_start and window_end must be valid HH:mm times');
    }
    return { startMinutes, endMinutes };
}

function parseTimeToMinutes(value) {
    if (!value || typeof value !== 'string') return null;
    const parts = value.split(':');
    if (parts.length !== 2) return null;
    const hour = Number(parts[0]);
    const minute = Number(parts[1]);
    if (!Number.isFinite(hour) || !Number.isFinite(minute)) return null;
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null;
    return hour * 60 + minute;
}

function currentMinutes() {
    const now = new Date();
    return now.getHours() * 60 + now.getMinutes();
}

function shouldPollNow(subscription, leg) {
    if (normalizeSource(subscription?.source) === LIVE_SESSION_SOURCE) {
        const activeUntil = Date.parse(subscription?.activeUntil || '');
        return !Number.isFinite(activeUntil) || activeUntil > Date.now();
    }
    const dayKey = moment().format('ddd').toLowerCase();
    const today = dayKey.slice(0, 3);
    if (!subscription.daysOfWeek.includes(today)) {
        return false;
    }
    let startMinutes;
    let endMinutes;
    try {
        ({ startMinutes, endMinutes } = parseWindow(leg.windowStart, leg.windowEnd));
    } catch {
        return false;
    }
    const nowMinutes = currentMinutes();
    return nowMinutes >= startMinutes && nowMinutes <= endMinutes;
}

function normalizeIsoDate(value) {
    if (!value || typeof value !== 'string') return null;
    const timestamp = Date.parse(value);
    if (!Number.isFinite(timestamp)) return null;
    return new Date(timestamp).toISOString();
}

async function getDeparturesSnapshot(fromStation, toStation) {
    const result = await getTrainTimes(fromStation, toStation);
    const departures = Array.isArray(result?.departures) ? result.departures.slice(0, 3) : [];
    const normalized = departures.map((dep) => ({
        serviceID: dep.serviceID,
        scheduled: dep.departure_time?.scheduled,
        estimated: dep.departure_time?.estimated || dep.departure_time?.scheduled,
        platform: dep.platform,
        isCancelled: dep.isCancelled
    }));
    return { departures: normalized, fetchedAt: new Date().toISOString() };
}

function calculateDelayMinutes(scheduled, estimated) {
    if (!scheduled || !estimated) return 0;
    const sched = moment(scheduled, 'HH:mm');
    const est = moment(estimated, 'HH:mm');
    if (!sched.isValid() || !est.isValid()) return 0;
    return Math.max(0, est.diff(sched, 'minutes'));
}

function buildSummaryMessage(subscription, leg, snapshot) {
    const primary = snapshot.departures[0];
    if (!primary) return null;
    const status = buildStatusText(primary);
    const departures = snapshot.departures.map((dep) => {
        const time = dep.estimated || dep.scheduled;
        const platform = dep.platform || 'TBC';
        return `${time} (plat. ${platform})`;
    }).join(', ');
    const fromLabel = leg.fromName || leg.from;
    const toLabel = leg.toName || leg.to;
    const body = `Next train status: ${status}\nDepartures: ${departures}.`;
    return buildNotificationPayload(`${fromLabel} → ${toLabel}`, body, buildLegMeta(subscription, leg, 'summary'), 'summary');
}

function buildStatusText(dep) {
    if (dep.isCancelled) {
        return '❌ Cancelled';
    }
    const delayMinutes = calculateDelayMinutes(dep.scheduled, dep.estimated);
    if (delayMinutes > 0) {
        return `⚠️ Running ${delayMinutes} minute${delayMinutes === 1 ? '' : 's'} late`;
    }
    return '✅ On time';
}

function buildDelayMessage(subscription, leg, dep) {
    const fromLabel = leg.fromName || leg.from;
    const toLabel = leg.toName || leg.to;
    const delay = dep.delayMinutes;
    const platform = dep.platform ? ` from platform ${dep.platform}` : '';
    const body = `${fromLabel} → ${toLabel} status update: The ${dep.scheduled} departure is now running ${delay} minute${delay === 1 ? '' : 's'} late, and is expected to depart at ${dep.estimated}${platform}.`;
    return buildNotificationPayload(`${fromLabel} → ${toLabel}`, body, buildLegMeta(subscription, leg, 'delay'), 'delay');
}

function buildCancellationMessage(subscription, leg, dep) {
    const fromLabel = leg.fromName || leg.from;
    const toLabel = leg.toName || leg.to;
    const body = `${fromLabel} → ${toLabel} status update: The ${dep.scheduled} departure has been cancelled.`;
    return buildNotificationPayload(`${fromLabel} → ${toLabel}`, body, buildLegMeta(subscription, leg, 'cancellation'), 'cancellation');
}

function buildPlatformMessage(subscription, leg, dep) {
    const fromLabel = leg.fromName || leg.from;
    const toLabel = leg.toName || leg.to;
    const platform = dep.platform || 'TBC';
    const body = `${fromLabel} → ${toLabel} platform update: The ${dep.scheduled} departure is now expected to depart at ${dep.estimated} from platform ${platform}.`;
    return buildNotificationPayload(`${fromLabel} → ${toLabel}`, body, buildLegMeta(subscription, leg, 'platform'), 'platform');
}

function buildMutedMessage(subscription, leg, snapshot = null) {
    const fromLabel = leg.fromName || leg.from;
    const toLabel = leg.toName || leg.to;
    const body = buildMutedMessageBody(leg, snapshot);
    return buildNotificationPayload(`${fromLabel} → ${toLabel}`, body, buildLegMeta(subscription, leg, 'muted'), 'muted');
}

function buildMutedMessageBody(leg, snapshot) {
    const fromLabel = leg.fromName || leg.from;
    const toLabel = leg.toName || leg.to;
    const welcome = `Welcome to ${fromLabel}!`;
    const primary = Array.isArray(snapshot?.departures) ? snapshot.departures[0] : null;

    if (!primary) {
        return `Notifications for ${fromLabel} → ${toLabel} have been muted for today. Have a good journey! 🚆`;
    }

    if (primary.isCancelled) {
        const nextAvailable = snapshot.departures.find((dep) => dep && !dep.isCancelled);
        const cancelledTime = formatDepartureTime(primary);
        if (!nextAvailable) {
            return `${welcome} The ${cancelledTime} departure has been cancelled. There are no later departures listed for ${toLabel} right now.`;
        }

        return `${welcome} The ${cancelledTime} departure has been cancelled. Next train to ${toLabel} is the ${formatDepartureTime(nextAvailable)} service${formatPlatformSuffix(nextAvailable)}.`;
    }

    if (isUnknownDelay(primary)) {
        return `${welcome} Your next train to ${toLabel} is delayed for an unknown period of time${formatUnknownDelayPlatformSuffix(primary)}.`;
    }

    const delayMinutes = calculateDelayMinutes(primary.scheduled, primary.estimated);
    if (delayMinutes > 0) {
        return `${welcome} Your next train to ${toLabel} is scheduled to depart ${delayMinutes} minute${delayMinutes === 1 ? '' : 's'} late at ${formatEstimatedDepartureTime(primary)}${formatPlatformSuffix(primary)}.`;
    }

    if (hasPlatform(primary)) {
        return `${welcome} Your next train to ${toLabel} is the ${formatDepartureTime(primary)} from platform ${primary.platform}, currently on time.`;
    }

    return `${welcome} Your next train to ${toLabel} is the ${formatDepartureTime(primary)}, currently on time, platform TBC.`;
}

function hasPlatform(dep) {
    return typeof dep?.platform === 'string' && dep.platform.trim().length > 0;
}

function isUnknownDelay(dep) {
    return typeof dep?.estimated === 'string' && dep.estimated.trim().toLowerCase() === 'delayed';
}

function formatDepartureTime(dep) {
    return getValidDepartureTime(dep?.scheduled) || getValidDepartureTime(dep?.estimated) || 'scheduled service';
}

function formatEstimatedDepartureTime(dep) {
    return getValidDepartureTime(dep?.estimated) || formatDepartureTime(dep);
}

function getValidDepartureTime(value) {
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    if (!trimmed) return null;
    return moment(trimmed, 'HH:mm', true).isValid() ? trimmed : null;
}

function formatPlatformSuffix(dep) {
    return hasPlatform(dep) ? ` from platform ${dep.platform.trim()}` : ', platform TBC';
}

function formatUnknownDelayPlatformSuffix(dep) {
    return hasPlatform(dep) ? `, due to depart from platform ${dep.platform.trim()}` : ', platform TBC';
}

function buildNotificationPayload(title, body, meta = {}, type = 'unknown') {
    return {
        type,
        payload: {
            aps: {
                alert: { title, body },
                sound: 'default',
                'mutable-content': 1,
                category: 'JOURNEY_LEG_ALERT'
            },
            ...meta
        }
    };
}

function buildLegMeta(subscription, leg, alertType) {
    const meta = {
        subscription_id: subscription.id,
        route_key: subscription.routeKey,
        from: leg.from,
        to: leg.to,
        leg_key: `${leg.from}-${leg.to}`,
        alert_type: alertType
    };
    if (leg.fromName) meta.from_name = leg.fromName;
    if (leg.toName) meta.to_name = leg.toName;
    return meta;
}

export const notificationSubscriptionManager = new NotificationSubscriptionManager();
