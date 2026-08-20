import moment from 'moment';
import { primaryPlace } from './departure-places.js';
import crypto from 'crypto';
import { getTrainTimes } from './realtime-trains-api.js';
import { NotificationPushClient } from './notification-push-client.js';
import { LiveActivityPushClient } from './live-activity-push-client.js';
import { pushToStartTokenStore } from './push-to-start-token-store.js';
import { recordNotificationEvent, recordSubscriptionAuditEvent } from './admin-data-store.js';
import { holidayModeStore } from './holiday-mode-store.js';
import { COLLECTIONS, getMongoCollection } from './mongo-client.js';
import { sleep } from './retry-utils.js';
import { allowDeviceData } from './device-data-deletion-state.js';
import {
    buildMuteNotificationPlan,
    resolveDetectionSource,
    resolveMuteTransition
} from './notification-mute-policy.js';

const DEFAULT_POLL_INTERVAL_SECONDS = Number(process.env.NOTIFICATION_POLL_INTERVAL_SECONDS || '30');
const MAX_SUBSCRIPTIONS_PER_DEVICE = Number(process.env.NOTIFICATION_MAX_SUBSCRIPTIONS || '3');
const MAX_WINDOW_MINUTES = 120;
const MAX_LIVE_SESSION_DURATION_MS = 2 * 60 * 60 * 1000;
const SCHEDULED_SOURCE = 'scheduled';
const LIVE_SESSION_SOURCE = 'live_session';
const SUMMARY_START_GRACE_MINUTES = Math.max(1, Math.ceil(DEFAULT_POLL_INTERVAL_SECONDS / 60));
const SCHEDULED_LIVE_ACTIVITY_MIN_REMAINING_MINUTES = Math.max(
    1,
    Number(process.env.SCHEDULED_LIVE_ACTIVITY_MIN_REMAINING_MINUTES || '1')
);
const MONGO_HYDRATION_RETRY_DELAY_MS = Math.max(
    1000,
    Number(process.env.NOTIFICATION_MONGO_HYDRATION_RETRY_DELAY_MS || process.env.NOTIFICATION_REDIS_HYDRATION_RETRY_DELAY_MS || '5000')
);
const SCHEDULED_LIVE_ACTIVITY_WAKE_RETRY_DELAY_MS = Math.max(
    0,
    Number(process.env.SCHEDULED_LIVE_ACTIVITY_WAKE_RETRY_DELAY_MS || '8000')
);
const SCHEDULED_LIVE_ACTIVITY_REGISTRATION_WATCHDOG_DELAY_MS = Math.max(
    1000,
    Number(process.env.SCHEDULED_LIVE_ACTIVITY_REGISTRATION_WATCHDOG_DELAY_MS || '30000')
);
const SCHEDULE_TIME_ZONE = process.env.NOTIFICATION_SCHEDULE_TIME_ZONE || 'Europe/London';
const LIVE_ACTIVITY_ATTRIBUTES_TYPE = process.env.APNS_LIVE_ACTIVITY_ATTRIBUTES_TYPE || 'JourneyActivityAttributes';

const VALID_TYPES = new Set(['summary', 'delays', 'platform']);
const DAY_MAP = {
    sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6
};

export class NotificationSubscriptionManager {
    constructor(options = {}) {
        this.subscriptions = new Map();
        this.getCollection = options.getCollection || getMongoCollection;
        this.pushClient = new NotificationPushClient();
        this.liveActivityPushClient = new LiveActivityPushClient();
        this.pollIntervalMs = DEFAULT_POLL_INTERVAL_SECONDS * 1000;
        this.isPolling = false;
        this.hasHydratedFromMongo = false;
        this.pollTimer = null;
        this.holidayModeDeviceIds = new Set();
        this.deletedDeviceIds = new Set();
        // Polling loop is started by init() after Mongo hydration.
    }

    // Load all persisted subscriptions from Mongo, then start the polling loop.
    // Must be called once at server startup before handling requests.
    async init() {
        await this.hydrateFromMongoWithRetry();
        await this.hydrateHolidayModeFromMongo();
        await this.pruneExpiredLiveSessions();
        this.startPollingLoop();
    }

    startPollingLoop() {
        if (this.pollTimer) {
            return;
        }
        this.pollTimer = setInterval(() => {
            this.pollAll().catch((error) => {
                console.error(`Notification poll failed: ${error?.message || error}`);
            });
        }, this.pollIntervalMs).unref?.();
    }

    async hydrateFromMongoWithRetry() {
        let attempt = 0;
        while (!this.hasHydratedFromMongo) {
            attempt += 1;
            try {
                await this.loadSubscriptionsFromMongo();
                this.hasHydratedFromMongo = true;
            } catch (err) {
                console.error('[notifications] Failed to load subscriptions from Mongo:', err?.message || err);
                console.error('[notifications] Retrying Mongo hydration before starting notification polling', JSON.stringify({
                    attempt,
                    retry_delay_ms: MONGO_HYDRATION_RETRY_DELAY_MS
                }));
                await sleep(MONGO_HYDRATION_RETRY_DELAY_MS);
            }
        }
    }

    async loadSubscriptionsFromMongo() {
        const collection = await this.getCollection(COLLECTIONS.notificationSubscriptions);
        const documents = await collection.find({}).toArray();
        this.subscriptions.clear();
        if (documents.length === 0) {
            console.log('[notifications] No subscriptions found in Mongo');
            await this.recordSubscriptionAudit({
                action: 'hydrate',
                reason: 'empty_sub_ids',
                mongo: await this.buildMongoSubscriptionDiagnostics()
            });
            return;
        }

        let loaded = 0;
        for (const document of documents) {
            try {
                const sub = stripMongoId(document);
                // Migrate: fill in fields added after initial schema to avoid
                // "Cannot set properties of undefined" on old records.
                sub.lastAutoStartSentByLeg = sub.lastAutoStartSentByLeg || {};
                sub.lastAutoStartSentAtByLeg = sub.lastAutoStartSentAtByLeg || {};
                sub.lastActivationPromptSentByLeg = sub.lastActivationPromptSentByLeg || {};
                sub.lastPushToStartMissingLoggedByLeg = sub.lastPushToStartMissingLoggedByLeg || {};
                sub.lastSummarySentByLeg = sub.lastSummarySentByLeg || {};
                sub.lastStateByLeg = sub.lastStateByLeg || {};
                sub.mutedByLegDay = sub.mutedByLegDay || {};
                sub.mutedAtByLegDay = sub.mutedAtByLegDay || {};
                sub.pushTokenInvalidAt = sub.pushTokenInvalidAt || null;
                sub.lastBadTokenReason = sub.lastBadTokenReason || null;
                this.subscriptions.set(sub.id, sub);
                loaded++;
            } catch (e) {
                console.error('[notifications] Failed to parse subscription from Mongo:', e?.message);
            }
        }
        console.log(`[notifications] Loaded ${loaded} subscription(s) from Mongo`);
        await this.recordSubscriptionAudit({
            action: 'hydrate',
            reason: 'startup',
            mongo: await this.buildMongoSubscriptionDiagnostics(),
            metadata: {
                documents_count: documents.length,
                loaded
            }
        });
        const pruned = await this.pruneDuplicateScheduledSubscriptions();
        if (pruned > 0) {
            console.log(`[notifications] Pruned ${pruned} duplicate scheduled subscription(s) from Mongo`);
        }
    }

    // --- Mongo persistence helpers ---

    async _saveSubscription(sub) {
        if (this.deletedDeviceIds.has(sub?.deviceId)) return;
        const collection = await this.getCollection(COLLECTIONS.notificationSubscriptions);
        if (this.deletedDeviceIds.has(sub?.deviceId)) return;
        await collection.updateOne(
            { _id: sub.id },
            { $set: { _id: sub.id, ...sub } },
            { upsert: true }
        );
        if (this.deletedDeviceIds.has(sub?.deviceId)) {
            await collection.deleteOne({ _id: sub.id });
        }
    }

    async _deleteFromMongo(id) {
        const collection = await getMongoCollection(COLLECTIONS.notificationSubscriptions);
        await collection.deleteOne({ _id: id });
    }

    async _getSubscriptionFromMongo(id) {
        if (!id) return null;
        const collection = await getMongoCollection(COLLECTIONS.notificationSubscriptions);
        const document = await collection.findOne({ _id: id });
        return document ? stripMongoId(document) : null;
    }

    // --- Public API ---

    listSubscriptions(deviceId, { source = null } = {}) {
        return Array.from(this.subscriptions.values())
            .filter((sub) => {
                if (sub.deviceId !== deviceId) return false;
                if (source && this.subscriptionSource(sub) !== source) return false;
                if (this.isExpiredLiveSession(sub)) {
                    this.deleteSubscription({
                        deviceId: sub.deviceId,
                        subscriptionId: sub.id,
                        reason: 'expired_live_session_list'
                    }).catch((error) => {
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
            liveSessionOrigin: liveSessionOriginInput,
            activeUntil,
            auditContext = null
        } = payload || {};

        if (!deviceId || !pushToken) {
            throw new Error('device_id and push_token are required');
        }
        if (!allowDeviceData(deviceId)) {
            throw new Error('Device data deletion is in progress');
        }
        this.deletedDeviceIds.delete(deviceId);
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

        const notificationTypes = normalizeTypes(typesInput, source);
        if (source === SCHEDULED_SOURCE && notificationTypes.length === 0) {
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

        const existingById = subscriptionId
            ? this.subscriptions.get(subscriptionId)
            : null;
        const existing = (
            existingById
            && existingById.deviceId === deviceId
            && this.subscriptionSource(existingById) === source
        )
            ? existingById
            : Array.from(this.subscriptions.values()).find(
                (sub) => sub.deviceId === deviceId
                    && sub.routeKey === routeKey
                    && this.subscriptionSource(sub) === source
            );
        const overlappingScheduledSubscriptions = source === SCHEDULED_SOURCE
            ? Array.from(this.subscriptions.values()).filter((sub) =>
                sub.deviceId === deviceId
                && sub.id !== existing?.id
                && this.subscriptionSource(sub) === SCHEDULED_SOURCE
                && (
                    sub.routeKey === routeKey
                    || scheduledSubscriptionsOverlap(sub, daysOfWeek, normalizedLegs)
                )
            )
            : [];
        const deviceCount = this.countSubscriptionsForDevice(deviceId, { source });
        const effectiveDeviceCount = Math.max(0, deviceCount - overlappingScheduledSubscriptions.length);
        if (!existing && effectiveDeviceCount >= MAX_SUBSCRIPTIONS_PER_DEVICE) {
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
            ? resolveLiveSessionActiveUntil(activeUntil, existing?.activeUntil)
            : null;
        const resolvedLiveSessionOrigin = source === LIVE_SESSION_SOURCE
            ? normalizeLiveSessionOrigin(liveSessionOriginInput ?? existing?.liveSessionOrigin)
            : null;
        const resetScheduledDeliveryState = source === SCHEDULED_SOURCE && Boolean(existing);

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
            liveSessionOrigin: resolvedLiveSessionOrigin,
            activeUntil: resolvedActiveUntil,
            createdAt: existing?.createdAt || nowIso,
            updatedAt: nowIso,
            lastSummarySentByLeg: resetScheduledDeliveryState ? {} : (existing?.lastSummarySentByLeg || {}),
            lastAutoStartSentByLeg: resetScheduledDeliveryState ? {} : (existing?.lastAutoStartSentByLeg || {}),
            lastAutoStartSentAtByLeg: resetScheduledDeliveryState ? {} : (existing?.lastAutoStartSentAtByLeg || {}),
            lastActivationPromptSentByLeg: resetScheduledDeliveryState ? {} : (existing?.lastActivationPromptSentByLeg || {}),
            lastPushToStartMissingLoggedByLeg: resetScheduledDeliveryState ? {} : (existing?.lastPushToStartMissingLoggedByLeg || {}),
            lastStateByLeg: resetScheduledDeliveryState ? {} : (existing?.lastStateByLeg || {}),
            mutedByLegDay: resetScheduledDeliveryState ? {} : (existing?.mutedByLegDay || {}),
            mutedAtByLegDay: resetScheduledDeliveryState ? {} : (existing?.mutedAtByLegDay || {}),
            pushTokenInvalidAt: null,
            lastBadTokenReason: null,
            lastActiveAt: existing?.lastActiveAt || null
        };

        this.subscriptions.set(subscription.id, subscription);
        try {
            await this._saveSubscription(subscription);
        } catch (error) {
            if (!existing) {
                this.subscriptions.delete(subscription.id);
            } else {
                this.subscriptions.set(existing.id, existing);
            }
            throw error;
        }
        await this.recordSubscriptionAudit({
            action: existing ? 'update' : 'create',
            reason: existing ? 'upsert_existing' : 'upsert_new',
            source,
            before: existing || null,
            after: subscription,
            metadata: {
                request: auditContext,
                overlapping_scheduled_subscription_ids: overlappingScheduledSubscriptions.map((sub) => sub.id)
            }
        });
        if (source === SCHEDULED_SOURCE) {
            await this.auditScheduledPushToStartReadiness(subscription);
        }
        await Promise.all(overlappingScheduledSubscriptions.map(async (staleSubscription) => {
            this.subscriptions.delete(staleSubscription.id);
            await this._deleteFromMongo(staleSubscription.id);
            await this.recordSubscriptionAudit({
                action: 'delete',
                reason: 'overlapping_schedule_replaced',
                source: this.subscriptionSource(staleSubscription),
                before: staleSubscription,
                metadata: {
                    replacement_subscription_id: subscription.id
                }
            });
        }));
        return this.publicSubscription(subscription);
    }

    async deleteSubscription({ deviceId, subscriptionId, reason = 'explicit_delete', metadata = null } = {}) {
        const sub = this.subscriptions.get(subscriptionId) || await this._getSubscriptionFromMongo(subscriptionId);
        if (!sub) return false;
        if (deviceId && sub.deviceId !== deviceId) return false;
        this.subscriptions.delete(subscriptionId);
        try {
            await this._deleteFromMongo(subscriptionId);
        } catch (error) {
            this.subscriptions.set(subscriptionId, sub);
            throw error;
        }
        await this.recordSubscriptionAudit({
            action: 'delete',
            reason,
            source: this.subscriptionSource(sub),
            before: sub,
            metadata
        });
        return true;
    }

    async getSubscription({ deviceId, subscriptionId, source = null } = {}) {
        const sub = this.subscriptions.get(subscriptionId) || await this._getSubscriptionFromMongo(subscriptionId);
        if (!sub) return null;
        if (deviceId && sub.deviceId !== deviceId) return null;
        if (source && this.subscriptionSource(sub) !== source) return null;
        return sub;
    }

    async muteScheduledLegsForToday({ deviceId, legs = [], reason = 'manual_mute', metadata = null } = {}) {
        if (!deviceId || !Array.isArray(legs) || legs.length === 0) {
            return [];
        }

        const todayKey = currentScheduleDateKey();
        const targetLegKeys = new Set(
            legs
                .map((leg) => legKeyForMute(leg))
                .filter(Boolean)
        );
        if (targetLegKeys.size === 0) {
            return [];
        }

        const muted = [];
        const scheduledSubscriptions = Array.from(this.subscriptions.values()).filter((sub) =>
            sub.deviceId === deviceId && this.subscriptionSource(sub) === SCHEDULED_SOURCE
        );

        for (const subscription of scheduledSubscriptions) {
            const matchingLegs = subscription.legs.filter((leg) => targetLegKeys.has(legKeyForMute(leg)));
            if (matchingLegs.length === 0) {
                continue;
            }

            const before = cloneSubscription(subscription);
            const mutedAt = new Date().toISOString();
            subscription.mutedByLegDay = subscription.mutedByLegDay || {};
            subscription.mutedAtByLegDay = subscription.mutedAtByLegDay || {};

            for (const leg of matchingLegs) {
                const legKey = legKeyForMute(leg);
                subscription.mutedByLegDay[legKey] = todayKey;
                subscription.mutedAtByLegDay[legKey] = mutedAt;
                muted.push({
                    subscription_id: subscription.id,
                    leg: legKey,
                    date: todayKey
                });
            }

            await this._saveSubscription(subscription);
            await this.recordSubscriptionAudit({
                action: 'mute_scheduled_legs',
                reason,
                source: SCHEDULED_SOURCE,
                before,
                after: subscription,
                metadata: {
                    ...metadata,
                    muted_legs: matchingLegs.map((leg) => legKeyForMute(leg)),
                    date: todayKey
                }
            });
        }

        if (muted.length > 0) {
            console.log('[notifications] muted_scheduled_legs', JSON.stringify({
                device_id: deviceId,
                reason,
                muted
            }));
        }

        return muted;
    }

    // Holiday mode: a single on/off flag per device. While enabled, pollSubscription
    // returns immediately for every subscription belonging to that device, so no
    // summary/update/auto-start/wake pushes are sent for scheduled or live-session
    // subscriptions. The flag is cached in memory (hydrated at startup) and persisted
    // via the existing device-preferences store so it survives a server restart.
    isHolidayModeEnabled(deviceId) {
        return this.holidayModeDeviceIds.has(deviceId);
    }

    async setHolidayMode({ deviceId, enabled, auditContext = null }) {
        if (!deviceId) {
            throw new Error('device_id is required');
        }
        if (!allowDeviceData(deviceId)) {
            throw new Error('Device data deletion is in progress');
        }
        this.deletedDeviceIds.delete(deviceId);
        const isEnabling = Boolean(enabled);
        if (isEnabling) {
            this.holidayModeDeviceIds.add(deviceId);
        } else {
            this.holidayModeDeviceIds.delete(deviceId);
        }

        await holidayModeStore.set(deviceId, isEnabling);
        await this.recordSubscriptionAudit({
            action: isEnabling ? 'holiday_mode_enabled' : 'holiday_mode_disabled',
            reason: 'holiday_mode',
            device_id: deviceId,
            metadata: { request: auditContext }
        });

        console.log('[notifications] holiday_mode', JSON.stringify({ device_id: deviceId, enabled: isEnabling }));
        return { paused: isEnabling };
    }

    async hydrateHolidayModeFromMongo() {
        try {
            this.holidayModeDeviceIds = new Set(await holidayModeStore.listEnabledDeviceIds());
        } catch (error) {
            console.error('[notifications] Failed to hydrate holiday mode state from Mongo:', error?.message || error);
        }
    }

    findScheduledSubscriptionForLeg({ deviceId, from, to }) {
        const fromCode = typeof from === 'string' ? from.trim().toUpperCase() : '';
        const toCode = typeof to === 'string' ? to.trim().toUpperCase() : '';
        if (!deviceId || !fromCode || !toCode) return null;

        return Array.from(this.subscriptions.values()).find((sub) => {
            if (sub.deviceId !== deviceId) return false;
            if (this.subscriptionSource(sub) !== SCHEDULED_SOURCE) return false;
            return Array.isArray(sub.legs) && sub.legs.some((leg) =>
                String(leg?.from || '').trim().toUpperCase() === fromCode
                    && String(leg?.to || '').trim().toUpperCase() === toCode
            );
        }) || null;
    }

    async deleteLiveSessionsForLeg({ deviceId, from, to, fallbackDeviceIds = [] }) {
        const fromCode = typeof from === 'string' ? from.trim().toUpperCase() : '';
        const toCode = typeof to === 'string' ? to.trim().toUpperCase() : '';
        if (!deviceId || !fromCode || !toCode) return 0;

        const candidateDeviceIds = new Set(
            [deviceId, ...fallbackDeviceIds]
                .filter((value) => typeof value === 'string' && value.trim().length > 0)
                .map((value) => value.trim())
        );
        const matching = Array.from(this.subscriptions.values()).filter((sub) => {
            if (this.subscriptionSource(sub) !== LIVE_SESSION_SOURCE) return false;
            if (!candidateDeviceIds.has(sub.deviceId)) return false;
            return Array.isArray(sub.legs) && sub.legs.some((leg) =>
                String(leg?.from || '').trim().toUpperCase() === fromCode
                    && String(leg?.to || '').trim().toUpperCase() === toCode
            );
        });

        await Promise.all(matching.map((sub) => this.deleteSubscription({
            deviceId: sub.deviceId,
            subscriptionId: sub.id,
            reason: 'delete_live_session_for_leg',
            metadata: { from: fromCode, to: toCode }
        })));

        return matching.length;
    }

    async deleteLiveSessionsForDevice({ deviceId, reason = 'delete_live_sessions_for_device' }) {
        if (!deviceId) return 0;

        const matching = Array.from(this.subscriptions.values()).filter((sub) =>
            sub.deviceId === deviceId && this.subscriptionSource(sub) === LIVE_SESSION_SOURCE
        );

        await Promise.all(matching.map((sub) => this.deleteSubscription({
            deviceId,
            subscriptionId: sub.id,
            reason,
            metadata: { device_id: deviceId }
        })));

        return matching.length;
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
        if (!this.hasHydratedFromMongo || this.isPolling || this.subscriptions.size === 0) {
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
        if (this.deletedDeviceIds.has(subscription?.deviceId)) return;
        if (this.isExpiredLiveSession(subscription)) {
            await this.deleteSubscription({
                deviceId: subscription.deviceId,
                subscriptionId: subscription.id,
                reason: 'expired_live_session_poll'
            });
            return;
        }
        if (this.isHolidayModeEnabled(subscription.deviceId)) {
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
            const snapshot = applyLastKnownPlatforms(
                await getDeparturesSnapshot(leg.from, leg.to),
                subscription.lastStateByLeg[legKey]
            );
            if (!snapshot.departures.length) {
                continue;
            }

            const notificationTypes = getEffectiveNotificationTypes(subscription);

            if (this.subscriptionSource(subscription) === SCHEDULED_SOURCE) {
                if (notificationTypes.includes('summary')) {
                    await this.sendSummaryIfNeeded(subscription, leg, legKey, snapshot);
                }
                await this.sendScheduledLiveActivityStartIfNeeded(subscription, leg, legKey, snapshot);
            } else if (notificationTypes.includes('summary')) {
                await this.sendSummaryIfNeeded(subscription, leg, legKey, snapshot);
            }

            if (
                this.subscriptionSource(subscription) === LIVE_SESSION_SOURCE
                || this.subscriptionSource(subscription) === SCHEDULED_SOURCE
            ) {
                const updateNotificationTypes = this.notificationTypesAfterDuplicateSuppression(
                    subscription,
                    leg,
                    legKey,
                    notificationTypes
                );
                await this.sendUpdateNotifications(subscription, leg, legKey, snapshot, updateNotificationTypes);
            }
        }
    }

    notificationTypesAfterDuplicateSuppression(subscription, leg, legKey, notificationTypes) {
        if (this.subscriptionSource(subscription) !== SCHEDULED_SOURCE) {
            return notificationTypes;
        }

        const liveSession = this.activeLiveSessionForLeg(subscription, leg);
        if (!liveSession) {
            return notificationTypes;
        }

        const liveSessionTypes = new Set(getEffectiveNotificationTypes(liveSession));
        const filtered = notificationTypes.filter((type) =>
            !isUpdateNotificationType(type) || !liveSessionTypes.has(type)
        );
        const suppressedTypes = notificationTypes.filter((type) => !filtered.includes(type));

        if (suppressedTypes.length > 0) {
            console.log('[notifications] suppress_duplicate_scheduled_update', JSON.stringify({
                subscription_id: subscription.id,
                live_session_id: liveSession.id,
                device_id: subscription.deviceId,
                route_key: subscription.routeKey,
                leg: legKey,
                suppressed_notification_types: suppressedTypes,
                remaining_notification_types: filtered
            }));
        }

        return filtered;
    }

    activeLiveSessionForLeg(subscription, leg) {
        const legKey = legKeyForMute(leg);
        if (!subscription?.deviceId || !legKey) {
            return null;
        }

        return Array.from(this.subscriptions.values()).find((candidate) => {
            if (candidate.id === subscription.id) return false;
            if (candidate.deviceId !== subscription.deviceId) return false;
            if (this.subscriptionSource(candidate) !== LIVE_SESSION_SOURCE) return false;
            if (this.isExpiredLiveSession(candidate)) return false;
            if (this.isMutedToday(candidate, legKey)) return false;
            if (!getEffectiveNotificationTypes(candidate).some(isUpdateNotificationType)) return false;

            return Array.isArray(candidate.legs) && candidate.legs.some((candidateLeg) =>
                candidateLeg?.enabled && legKeyForMute(candidateLeg) === legKey
            );
        }) || null;
    }

    async sendSummaryIfNeeded(subscription, leg, legKey, snapshot) {
        if (this.isMutedToday(subscription, legKey)) {
            return;
        }
        const todayKey = currentScheduleDateKey();
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
        if (
            nowMinutes < startMinutes
            || nowMinutes > endMinutes
            || nowMinutes >= (startMinutes + SUMMARY_START_GRACE_MINUTES)
        ) {
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
            {
                useSandbox: activeSubscription.useSandbox,
                event: summary.type,
                context: buildPushContext(activeSubscription, leg, 'scheduled_summary')
            }
        );
        this.logSendEvent(activeSubscription, leg, summary, pushResult);
        console.log('[notifications] summary_push', JSON.stringify({
            subscription_id: activeSubscription.id,
            device_id: activeSubscription.deviceId,
            route_key: activeSubscription.routeKey,
            leg: legKey,
            use_sandbox: activeSubscription.useSandbox,
            status: pushResult?.status,
            reason: pushResult?.body?.reason || pushResult?.reason || null
        }));
        if (pushResult?.isBadToken) {
            await this.handleBadNotificationToken(activeSubscription, 'sendSummaryIfNeeded', pushResult);
            return;
        }

        activeSubscription.lastSummarySentByLeg[legKey] = todayKey;
        // Fire-and-forget: persist the updated lastSummarySentByLeg.
        this._saveSubscription(activeSubscription).catch((err) => {
            console.error('[notifications] Failed to persist lastSummarySentByLeg:', err?.message || err);
        });
    }

    async sendScheduledLiveActivityStartIfNeeded(subscription, leg, legKey, snapshot) {
        if (this.isMutedToday(subscription, legKey)) {
            return false;
        }

        const startWindow = getLiveActivityStartWindowState(leg);
        if (!startWindow.allowed) {
            console.log('[notifications] auto_start_skip', JSON.stringify({
                subscription_id: subscription.id,
                device_id: subscription.deviceId,
                route_key: subscription.routeKey,
                leg: legKey,
                reason: startWindow.reason,
                now_minutes: startWindow.nowMinutes,
                start_minutes: startWindow.startMinutes,
                end_minutes: startWindow.endMinutes,
                min_remaining_minutes: SCHEDULED_LIVE_ACTIVITY_MIN_REMAINING_MINUTES
            }));
            return false;
        }

        const todayKey = currentScheduleDateKey();
        if (subscription.lastAutoStartSentByLeg?.[legKey] === todayKey) {
            console.log('[notifications] auto_start_skip', JSON.stringify({
                subscription_id: subscription.id,
                device_id: subscription.deviceId,
                route_key: subscription.routeKey,
                leg: legKey,
                reason: 'already_sent_today',
                date: todayKey
            }));
            return true;
        }

        const activeSubscription = this.getActiveSubscriptionForPush(subscription.id, leg, 'scheduled_live_activity_start_pre_send');
        if (!activeSubscription) {
            console.log('[notifications] auto_start_skip', JSON.stringify({
                subscription_id: subscription.id,
                device_id: subscription.deviceId,
                route_key: subscription.routeKey,
                leg: legKey,
                reason: 'missing_active_subscription'
            }));
            return false;
        }

        const pushToStartRecord = await pushToStartTokenStore.get(activeSubscription.deviceId);
        if (!pushToStartRecord?.pushToStartToken) {
            console.log('[notifications] auto_start_skip', JSON.stringify({
                subscription_id: activeSubscription.id,
                device_id: activeSubscription.deviceId,
                route_key: activeSubscription.routeKey,
                leg: legKey,
                reason: 'missing_push_to_start_token'
            }));
            if (activeSubscription.lastPushToStartMissingLoggedByLeg?.[legKey] !== todayKey) {
                activeSubscription.lastPushToStartMissingLoggedByLeg = {
                    ...(activeSubscription.lastPushToStartMissingLoggedByLeg || {}),
                    [legKey]: todayKey
                };
                await this.recordSubscriptionAudit({
                    action: 'live_activity_start_blocked',
                    reason: 'missing_push_to_start_token',
                    source: this.subscriptionSource(activeSubscription),
                    subscription: activeSubscription,
                    metadata: {
                        leg: legKey,
                        date: todayKey,
                        schedule_key: buildScheduleKeyForLeg(leg)
                    }
                });
                this._saveSubscription(activeSubscription).catch((err) => {
                    console.error('[notifications] Failed to persist lastPushToStartMissingLoggedByLeg:', err?.message || err);
                });
            }
            return false;
        }

        const payload = buildScheduledLiveActivityStartPayload(activeSubscription, leg, snapshot);
        const pushResult = await this.liveActivityPushClient.sendLiveActivityUpdate(
            pushToStartRecord.pushToStartToken,
            payload,
            {
                useSandbox: pushToStartRecord.useSandbox === true,
                event: 'live_activity_start',
                context: {
                    device_id: activeSubscription.deviceId,
                    subscription_id: activeSubscription.id,
                    route_key: legRouteKey(leg),
                    subscription_route_key: activeSubscription.routeKey,
                    from: leg.from,
                    to: leg.to,
                    schedule_key: buildScheduleKeyForLeg(leg),
                    source: 'scheduled'
                }
            }
        );

        this.logLiveActivityStartEvent(activeSubscription, leg, payload, pushResult);
        console.log('[notifications] auto_start_push', JSON.stringify({
            subscription_id: activeSubscription.id,
            device_id: activeSubscription.deviceId,
            route_key: activeSubscription.routeKey,
            leg_route_key: legRouteKey(leg),
            leg: legKey,
            attributes_type: LIVE_ACTIVITY_ATTRIBUTES_TYPE,
            use_sandbox: pushToStartRecord.useSandbox === true,
            status: pushResult?.status,
            reason: pushResult?.body?.reason || pushResult?.reason || null,
            alert_included: true
        }));

        if (pushResult?.isBadToken) {
            console.warn('[notifications] bad_push_to_start_token_delete', JSON.stringify({
                device_id: activeSubscription.deviceId,
                route_key: activeSubscription.routeKey,
                leg: legKey,
                context: 'sendScheduledLiveActivityStartIfNeeded'
            }));
            await pushToStartTokenStore.delete(activeSubscription.deviceId, {
                reason: 'bad_push_to_start_token',
                metadata: {
                    subscription_id: activeSubscription.id,
                    route_key: activeSubscription.routeKey,
                    leg: legKey,
                    status: pushResult?.status ?? null,
                    apns_reason: pushResult?.body?.reason || pushResult?.reason || null
                }
            });
            return false;
        }

        if (!(typeof pushResult?.status === 'number' && pushResult.status >= 200 && pushResult.status < 300)) {
            return false;
        }

        // Wake the app in background so it can detect the new live activity and
        // register its per-activity push token with the server. Without this, a
        // killed app never runs Activity.activityUpdates and the server has no
        // token to send update pushes — leaving the widget frozen at launch state.
        if (activeSubscription.pushToken) {
            const wakePayload = buildNotificationPayload(null, null, { context: 'live_activity_wake' }, 'live_activity_wake');
            const sendWakePush = (attempt, delayMs = 0) => {
                const send = () => {
                    this.pushClient.sendNotification(
                        activeSubscription.pushToken,
                        wakePayload.payload,
                        {
                            useSandbox: activeSubscription.useSandbox === true,
                            event: 'live_activity_wake',
                            context: {
                                device_id: activeSubscription.deviceId,
                                subscription_id: activeSubscription.id,
                                route_key: legRouteKey(leg),
                                subscription_route_key: activeSubscription.routeKey,
                                from: leg.from,
                                to: leg.to,
                                schedule_key: buildScheduleKeyForLeg(leg),
                                source: 'scheduled',
                                wake_attempt: attempt,
                                wake_delay_ms: delayMs
                            }
                        }
                    ).then((wakeResult) => {
                        console.log('[notifications] live_activity_wake_push', JSON.stringify({
                            subscription_id: activeSubscription.id,
                            device_id: activeSubscription.deviceId,
                            route_key: activeSubscription.routeKey,
                            leg_route_key: legRouteKey(leg),
                            leg: legKey,
                            attempt,
                            delay_ms: delayMs,
                            status: wakeResult?.status,
                            reason: wakeResult?.body?.reason || wakeResult?.reason || null
                        }));
                    }).catch((err) => {
                        console.warn('[notifications] live_activity_wake_push_failed', JSON.stringify({
                            subscription_id: activeSubscription.id,
                            device_id: activeSubscription.deviceId,
                            leg: legKey,
                            attempt,
                            delay_ms: delayMs,
                            error: err?.message || String(err)
                        }));
                    });
                };
                if (delayMs > 0) {
                    setTimeout(send, delayMs).unref?.();
                } else {
                    send();
                }
            };
            sendWakePush(1, 0);
            if (SCHEDULED_LIVE_ACTIVITY_WAKE_RETRY_DELAY_MS > 0) {
                sendWakePush(2, SCHEDULED_LIVE_ACTIVITY_WAKE_RETRY_DELAY_MS);
            }
        }

        this.scheduleScheduledLiveActivityRegistrationWatchdog(activeSubscription, leg, legKey, snapshot?.fetchedAt);

        const sentAt = snapshot?.fetchedAt || new Date().toISOString();
        activeSubscription.lastAutoStartSentByLeg[legKey] = todayKey;
        activeSubscription.lastAutoStartSentAtByLeg[legKey] = sentAt;
        this._saveSubscription(activeSubscription).catch((err) => {
            console.error('[notifications] Failed to persist scheduled live activity start state:', err?.message || err);
        });
        return true;
    }

    scheduleScheduledLiveActivityRegistrationWatchdog(subscription, leg, legKey, startedAt = null) {
        const scheduleKey = buildScheduleKeyForLeg(leg);
        const startedAtIso = startedAt || new Date().toISOString();
        setTimeout(() => {
            this.checkScheduledLiveActivityRegistration({
                subscription,
                leg,
                legKey,
                scheduleKey,
                startedAtIso
            }).catch((error) => {
                console.error('[notifications] live_activity_registration_watchdog_failed', JSON.stringify({
                    subscription_id: subscription.id,
                    device_id: subscription.deviceId,
                    route_key: subscription.routeKey,
                    leg: legKey,
                    schedule_key: scheduleKey,
                    error: error?.message || String(error)
                }));
            });
        }, SCHEDULED_LIVE_ACTIVITY_REGISTRATION_WATCHDOG_DELAY_MS).unref?.();
    }

    async checkScheduledLiveActivityRegistration({ subscription, leg, legKey, scheduleKey, startedAtIso }) {
        const collection = await getMongoCollection(COLLECTIONS.liveActivitySessions);
        const registered = await collection.findOne({
            deviceId: subscription.deviceId,
            scheduleKey,
            tokenUpdatedAt: { $gte: startedAtIso }
        });
        if (registered) {
            console.log('[notifications] live_activity_registration_watchdog_ok', JSON.stringify({
                subscription_id: subscription.id,
                device_id: subscription.deviceId,
                route_key: subscription.routeKey,
                leg: legKey,
                schedule_key: scheduleKey,
                activity_id: registered.activityId || null
            }));
            return;
        }

        console.warn('[notifications] live_activity_registration_missing', JSON.stringify({
            subscription_id: subscription.id,
            device_id: subscription.deviceId,
            route_key: subscription.routeKey,
            leg_route_key: legRouteKey(leg),
            leg: legKey,
            schedule_key: scheduleKey,
            watchdog_delay_ms: SCHEDULED_LIVE_ACTIVITY_REGISTRATION_WATCHDOG_DELAY_MS
        }));
        await this.recordSubscriptionAudit({
            action: 'live_activity_registration_missing',
            reason: 'scheduled_start_without_update_token',
            source: this.subscriptionSource(subscription),
            subscription,
            metadata: {
                leg: legKey,
                schedule_key: scheduleKey,
                started_at: startedAtIso,
                watchdog_delay_ms: SCHEDULED_LIVE_ACTIVITY_REGISTRATION_WATCHDOG_DELAY_MS
            }
        });

        if (subscription.pushToken) {
            const wakePayload = buildNotificationPayload(
                null,
                null,
                { context: 'live_activity_recovery_wake' },
                'live_activity_recovery_wake'
            );
            const wakeResult = await this.pushClient.sendNotification(
                subscription.pushToken,
                wakePayload.payload,
                {
                    useSandbox: subscription.useSandbox === true,
                    event: 'live_activity_recovery_wake',
                    context: {
                        device_id: subscription.deviceId,
                        subscription_id: subscription.id,
                        route_key: legRouteKey(leg),
                        subscription_route_key: subscription.routeKey,
                        from: leg.from,
                        to: leg.to,
                        schedule_key: scheduleKey,
                        source: 'scheduled',
                        watchdog_delay_ms: SCHEDULED_LIVE_ACTIVITY_REGISTRATION_WATCHDOG_DELAY_MS
                    }
                }
            );
            console.log('[notifications] live_activity_recovery_wake_push', JSON.stringify({
                subscription_id: subscription.id,
                device_id: subscription.deviceId,
                route_key: subscription.routeKey,
                leg_route_key: legRouteKey(leg),
                leg: legKey,
                schedule_key: scheduleKey,
                status: wakeResult?.status,
                reason: wakeResult?.body?.reason || wakeResult?.reason || null
            }));
        }
    }

    async sendUpdateNotifications(subscription, leg, legKey, snapshot, notificationTypes = getEffectiveNotificationTypes(subscription)) {
        if (this.isMutedToday(subscription, legKey)) {
            return;
        }
        const updateReason = this.subscriptionSource(subscription) === SCHEDULED_SOURCE
            ? 'scheduled_update'
            : 'live_session_update';
        const previous = subscription.lastStateByLeg[legKey] || {};
        const nextState = {};
        const nextDepartureServiceID = snapshot.departures[0]?.serviceID || null;

        for (const dep of snapshot.departures) {
            const serviceID = dep.serviceID;
            const delayMinutes = calculateDelayMinutes(dep.scheduled, dep.estimated);
            const platform = normalizePlatform(dep.platform);
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

            const isNextDeparture = Boolean(nextDepartureServiceID) && serviceID === nextDepartureServiceID;

            if (notificationTypes.includes('delays')) {
                if (current.isCancelled && !prev.isCancelled) {
                    await this.sendNotification(subscription, buildCancellationMessage(subscription, leg, current), leg, updateReason);
                } else if (isNextDeparture && current.delayMinutes > 0 && current.delayMinutes !== prev.delayMinutes) {
                    await this.sendNotification(subscription, buildDelayMessage(subscription, leg, current), leg, updateReason);
                }
            }

            if (notificationTypes.includes('platform')) {
                const previousPlatform = normalizePlatform(prev.platform);
                if (isNextDeparture && previousPlatform && current.platform && previousPlatform !== current.platform) {
                    await this.sendNotification(subscription, buildPlatformMessage(subscription, leg, current), leg, updateReason);
                }
            }
        }

        subscription.lastStateByLeg[legKey] = nextState;
        // Fire-and-forget: persist the updated lastStateByLeg.
        this._saveSubscription(subscription).catch((err) => {
            console.error('[notifications] Failed to persist lastStateByLeg:', err?.message || err);
        });
    }

    async sendNotification(subscription, notification, leg = null, reason = 'update') {
        if (!notification) return;
        const activeSubscription = this.getActiveSubscriptionForPush(subscription.id, leg, 'update_pre_send');
        if (!activeSubscription) {
            return;
        }
        const result = await this.pushClient.sendNotification(
            activeSubscription.pushToken,
            notification.payload,
            {
                useSandbox: activeSubscription.useSandbox,
                event: notification.type,
                context: buildPushContext(activeSubscription, leg, reason)
            }
        );
        this.logSendEvent(activeSubscription, leg, notification, result);
        console.log('[notifications] update_push', JSON.stringify({
            subscription_id: activeSubscription.id,
            device_id: activeSubscription.deviceId,
            route_key: activeSubscription.routeKey,
            use_sandbox: activeSubscription.useSandbox,
            status: result?.status,
            reason: result?.body?.reason || result?.reason || null
        }));
        if (result?.isBadToken) {
            await this.handleBadNotificationToken(activeSubscription, 'sendNotification', result);
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
            route_key: leg ? legRouteKey(leg) : subscription.routeKey,
            from_station: leg?.from || null,
            to_station: leg?.to || null,
            token: subscription.pushToken || null,
            is_bad_token: Boolean(result?.isBadToken),
            payload: result?.payload ?? notification?.payload ?? null,
            response: result || null,
            metadata: {
                subscription_route_key: subscription.routeKey,
                notification_types: getEffectiveNotificationTypes(subscription),
                days_of_week: subscription.daysOfWeek
            }
        }).catch((error) => {
            console.error('[admin] Failed to log notification send event:', error?.message || error);
        });
    }

    logLiveActivityStartEvent(subscription, leg, payload, result) {
        const status = result?.status ?? null;
        const success = typeof status === 'number' && status >= 200 && status < 300;
        recordNotificationEvent({
            channel: 'live_activity',
            type: 'live_activity_start',
            success,
            status,
            error: result?.error || result?.body?.reason || result?.reason || null,
            apns_environment: subscription.useSandbox ? 'sandbox' : 'prod',
            device_id: subscription.deviceId,
            route_key: leg ? legRouteKey(leg) : subscription.routeKey,
            from_station: leg?.from || null,
            to_station: leg?.to || null,
            is_bad_token: Boolean(result?.isBadToken),
            payload: result?.payload ?? payload,
            response: result || null,
            metadata: {
                source: this.subscriptionSource(subscription),
                subscription_route_key: subscription.routeKey,
                schedule_key: buildScheduleKeyForLeg(leg),
                notification_types: getEffectiveNotificationTypes(subscription),
                days_of_week: subscription.daysOfWeek
            }
        }).catch((error) => {
            console.error('[admin] Failed to log live activity start event:', error?.message || error);
        });
    }

    publicSubscription(subscription) {
        return {
            id: subscription.id,
            device_id: subscription.deviceId,
            route_key: subscription.routeKey,
            days_of_week: subscription.daysOfWeek,
            notification_types: getEffectiveNotificationTypes(subscription),
            use_sandbox: subscription.useSandbox,
            mute_on_arrival: subscription.muteOnArrival,
            source: this.subscriptionSource(subscription),
            live_session_origin: subscription.liveSessionOrigin || null,
            active_until: subscription.activeUntil || null,
            push_token_invalid_at: subscription.pushTokenInvalidAt || null,
            last_bad_token_reason: subscription.lastBadTokenReason || null,
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

    async muteLegForDate({
        deviceId,
        subscriptionId,
        from,
        to,
        date,
        reason = 'mute_on_arrival',
        transition = null,
        detectionSource = null,
        journeyNotificationBody = null
    }) {
        const fromCode = typeof from === 'string' ? from.trim().toUpperCase() : '';
        const toCode = typeof to === 'string' ? to.trim().toUpperCase() : '';
        const muteReason = normalizeMuteReason(reason);
        const muteTransition = resolveMuteTransition({ transition, reason: muteReason });
        const muteDetectionSource = resolveDetectionSource({ detectionSource, reason: muteReason });
        const isStationExit = muteTransition === 'station_exit';
        let subscription = this.subscriptions.get(subscriptionId);
        if (!subscription && isStationExit) {
            subscription = this.findScheduledSubscriptionForLeg({
                deviceId,
                from: fromCode,
                to: toCode
            });
            if (subscription) {
                console.log('[notifications] station_exit_terminate_fallback', JSON.stringify({
                    requested_subscription_id: subscriptionId,
                    scheduled_subscription_id: subscription.id,
                    device_id: deviceId,
                    leg: `${fromCode}-${toCode}`
                }));
            }
        }
        if (!subscription) return null;
        if (deviceId && subscription.deviceId !== deviceId) return null;
        const legKey = `${fromCode}-${toCode}`;
        const leg = subscription.legs.find((l) => l.from === fromCode && l.to === toCode);
        if (!leg) return null;
        const todayKey = currentScheduleDateKey();
        const dateKey = typeof date === 'string' && date ? date : todayKey;
        const mutedAt = new Date().toISOString();
        subscription.mutedByLegDay[legKey] = dateKey;
        subscription.mutedAtByLegDay[legKey] = mutedAt;
        await this._saveSubscription(subscription);

        // When muting for today (i.e. triggered by geofence arrival), send a
        // confirmation push so the user knows notifications have been muted.
        if (dateKey === todayKey && !this.isHolidayModeEnabled(subscription.deviceId)) {
            let snapshot = null;
            if (!isStationExit) {
                try {
                    snapshot = await getDeparturesSnapshot(leg.from, leg.to);
                } catch (error) {
                    console.warn('[notifications] Failed to fetch departures snapshot for muted notification:', error?.message || error);
                }
            }

            const mutedNotifications = buildMutedMessages(subscription, leg, snapshot, {
                reason: muteReason,
                transition: muteTransition,
                journeyNotificationBody
            });
            const pushResults = [];

            for (let index = 0; index < mutedNotifications.length; index += 1) {
                const mutedNotification = mutedNotifications[index];
                if (index > 0) {
                    await sleep(1000);
                }

                const pushResult = await this.pushClient.sendNotification(
                    subscription.pushToken,
                    mutedNotification.payload,
                    {
                        useSandbox: subscription.useSandbox,
                        event: mutedNotification.type,
                        context: buildPushContext(subscription, leg, muteReason, {
                            transition: muteTransition,
                            detection_source: muteDetectionSource
                        })
                    }
                );
                pushResults.push({
                    type: mutedNotification.type,
                    status: pushResult?.status ?? null,
                    reason: pushResult?.body?.reason || null
                });
                this.logSendEvent(subscription, leg, mutedNotification, pushResult);

                if (pushResult?.isBadToken) {
                    await this.handleBadNotificationToken(subscription, 'muteLegForDate', pushResult);
                    return null;
                }
            }

            console.log('[notifications] mute_leg_for_date', JSON.stringify({
                subscription_id: subscription.id,
                device_id: subscription.deviceId,
                route_key: subscription.routeKey,
                leg: legKey,
                use_sandbox: subscription.useSandbox,
                reason: muteReason,
                transition: muteTransition,
                detection_source: muteDetectionSource,
                notifications: pushResults
            }));
        }

        if (this.subscriptionSource(subscription) === LIVE_SESSION_SOURCE) {
            const liveSessionMuteReason = isStationExit
                ? 'live_session_muted_on_station_exit'
                : 'live_session_muted_on_arrival';
            await this.muteScheduledLegsForToday({
                deviceId: subscription.deviceId,
                legs: [leg],
                reason: liveSessionMuteReason,
                metadata: {
                    live_session_id: subscription.id,
                    date: dateKey,
                    trigger_reason: muteReason,
                    transition: muteTransition,
                    detection_source: muteDetectionSource
                }
            });
            this.subscriptions.delete(subscription.id);
            await this._deleteFromMongo(subscription.id);
            await this.recordSubscriptionAudit({
                action: 'delete',
                reason: liveSessionMuteReason,
                source: LIVE_SESSION_SOURCE,
                before: subscription,
                metadata: {
                    date: dateKey,
                    trigger_reason: muteReason,
                    transition: muteTransition,
                    detection_source: muteDetectionSource
                }
            });
        }

        return {
            date: dateKey,
            transition: muteTransition,
            detectionSource: muteDetectionSource
        };
    }

    isMutedToday(subscription, legKey) {
        const mutedDate = subscription.mutedByLegDay?.[legKey];
        if (!mutedDate) return false;
        const todayKey = currentScheduleDateKey();
        return mutedDate === todayKey;
    }

    getSubscriptionCount() {
        return this.subscriptions.size;
    }

    purgeDeviceRuntimeState(deviceId) {
        const normalizedDeviceId = typeof deviceId === 'string' ? deviceId.trim() : '';
        if (!normalizedDeviceId) {
            return { subscriptions: 0, holidayMode: false };
        }

        this.deletedDeviceIds.add(normalizedDeviceId);

        let subscriptions = 0;
        for (const [id, subscription] of this.subscriptions.entries()) {
            if (subscription?.deviceId !== normalizedDeviceId) continue;
            this.subscriptions.delete(id);
            subscriptions += 1;
        }

        const holidayMode = this.holidayModeDeviceIds.delete(normalizedDeviceId);
        return { subscriptions, holidayMode };
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
        const collection = await getMongoCollection(COLLECTIONS.notificationSubscriptions);
        const expiredDocuments = await collection
            .find({
                source: LIVE_SESSION_SOURCE,
                activeUntil: { $lte: new Date(now).toISOString() }
            })
            .project({ _id: 1 })
            .toArray();
        const allExpiredIds = Array.from(new Set([
            ...expiredIds,
            ...expiredDocuments.map((doc) => doc._id).filter(Boolean)
        ]));
        if (allExpiredIds.length === 0) return;
        await Promise.all(allExpiredIds.map((id) => this.deleteSubscription({
            subscriptionId: id,
            reason: 'expired_live_session_prune'
        })));
    }

    async pruneDuplicateScheduledSubscriptions() {
        const groups = new Map();
        for (const sub of this.subscriptions.values()) {
            if (this.subscriptionSource(sub) !== SCHEDULED_SOURCE) continue;
            const key = [
                String(sub.deviceId || '').trim(),
                String(sub.routeKey || '').trim()
            ].join('|');
            if (!key || key === '|') continue;
            const current = groups.get(key) || [];
            current.push(sub);
            groups.set(key, current);
        }

        const staleIds = [];
        for (const group of groups.values()) {
            if (group.length <= 1) continue;
            const sorted = [...group].sort((left, right) =>
                subscriptionTimestamp(right) - subscriptionTimestamp(left)
            );
            staleIds.push(...sorted.slice(1).map((sub) => sub.id).filter(Boolean));
        }

        if (staleIds.length === 0) return 0;
        await Promise.all(staleIds.map(async (id) => {
            const stale = this.subscriptions.get(id);
            this.subscriptions.delete(id);
            await this._deleteFromMongo(id);
            await this.recordSubscriptionAudit({
                action: 'delete',
                reason: 'duplicate_scheduled_prune',
                source: this.subscriptionSource(stale),
                before: stale || { id },
                metadata: {
                    duplicate_group_prune: true
                }
            });
        }));
        return staleIds.length;
    }

    async handleBadNotificationToken(subscription, context, pushResult) {
        const source = this.subscriptionSource(subscription);
        const apnsReason = pushResult?.body?.reason || pushResult?.reason || null;
        const metadata = {
            context,
            status: pushResult?.status ?? null,
            apns_reason: apnsReason
        };

        if (source === SCHEDULED_SOURCE) {
            const before = { ...subscription };
            subscription.pushTokenInvalidAt = new Date().toISOString();
            subscription.lastBadTokenReason = apnsReason || 'BadDeviceToken';
            await this._saveSubscription(subscription);
            await this.recordSubscriptionAudit({
                action: 'mark_token_invalid',
                reason: 'bad_token_scheduled_push',
                source,
                before,
                after: subscription,
                metadata
            });
            console.warn('[notifications] bad_token_mark_invalid', JSON.stringify({
                subscription_id: subscription.id,
                device_id: subscription.deviceId,
                route_key: subscription.routeKey,
                context,
                reason: apnsReason
            }));
            return;
        }

        console.warn('[notifications] bad_token_delete', JSON.stringify({
            subscription_id: subscription.id,
            device_id: subscription.deviceId,
            route_key: subscription.routeKey,
            context,
            reason: apnsReason
        }));
        this.subscriptions.delete(subscription.id);
        await this._deleteFromMongo(subscription.id);
        await this.recordSubscriptionAudit({
            action: 'delete',
            reason: 'bad_token_live_session_push',
            source,
            before: subscription,
            metadata
        });
    }

    async auditScheduledPushToStartReadiness(subscription) {
        const record = await pushToStartTokenStore.get(subscription.deviceId);
        await this.recordSubscriptionAudit({
            action: record?.pushToStartToken ? 'schedule_push_to_start_ready' : 'schedule_push_to_start_missing',
            reason: 'scheduled_subscription_saved',
            source: this.subscriptionSource(subscription),
            subscription,
            metadata: {
                push_to_start_updated_at: record?.updatedAt || null,
                push_to_start_use_sandbox: record?.useSandbox ?? null
            }
        });
    }

    async recordSubscriptionAudit(event) {
        const deviceId = event?.device_id
            || event?.subscription?.deviceId
            || event?.before?.deviceId
            || event?.after?.deviceId;
        if (this.deletedDeviceIds.has(deviceId)) return;
        try {
            await recordSubscriptionAuditEvent(event);
        } catch (error) {
            console.error('[notifications] Failed to record subscription audit event:', error?.message || error);
        }
    }

    async buildMongoSubscriptionDiagnostics() {
        try {
            const collection = await getMongoCollection(COLLECTIONS.notificationSubscriptions);
            const [documentCount, scheduledCount, liveSessionCount] = await Promise.all([
                collection.countDocuments({}),
                collection.countDocuments({ source: SCHEDULED_SOURCE }),
                collection.countDocuments({ source: LIVE_SESSION_SOURCE })
            ]);
            return {
                collection: COLLECTIONS.notificationSubscriptions,
                document_count: documentCount,
                scheduled_count: scheduledCount,
                live_session_count: liveSessionCount
            };
        } catch (error) {
            return {
                error: error?.message || String(error)
            };
        }
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

function stripMongoId(value) {
    if (!value || typeof value !== 'object') return value;
    const { _id, ...rest } = value;
    return rest;
}

function cloneSubscription(subscription) {
    return JSON.parse(JSON.stringify(subscription));
}

function legKeyForMute(leg) {
    const from = typeof leg?.from === 'string' ? leg.from.trim().toUpperCase() : '';
    const to = typeof leg?.to === 'string' ? leg.to.trim().toUpperCase() : '';
    return from && to ? `${from}-${to}` : null;
}

function normalizeTypes(typesInput, source = SCHEDULED_SOURCE) {
    const raw = Array.isArray(typesInput) ? typesInput : [];
    const types = raw
        .map((t) => (typeof t === 'string' ? t.trim().toLowerCase() : ''))
        .filter((t) => VALID_TYPES.has(t));
    return source === LIVE_SESSION_SOURCE
        ? types.filter((type) => type !== 'summary')
        : types;
}

function normalizeSource(value) {
    const raw = typeof value === 'string' ? value.trim().toLowerCase() : '';
    return raw === LIVE_SESSION_SOURCE ? LIVE_SESSION_SOURCE : SCHEDULED_SOURCE;
}

function normalizeLiveSessionOrigin(value) {
    const raw = typeof value === 'string' ? value.trim().toLowerCase() : '';
    return raw === 'scheduled' ? 'scheduled' : 'manual';
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
    const { hour, minute } = getScheduleTimeParts();
    return hour * 60 + minute;
}

function getLiveActivityStartWindowState(leg) {
    let startMinutes;
    let endMinutes;
    try {
        ({ startMinutes, endMinutes } = parseWindow(leg.windowStart, leg.windowEnd));
    } catch {
        return {
            allowed: false,
            reason: 'invalid_window',
            nowMinutes: currentMinutes(),
            startMinutes: null,
            endMinutes: null
        };
    }
    const nowMinutes = currentMinutes();
    if (nowMinutes < startMinutes) {
        return { allowed: false, reason: 'before_window', nowMinutes, startMinutes, endMinutes };
    }
    if (nowMinutes > endMinutes) {
        return { allowed: false, reason: 'after_window', nowMinutes, startMinutes, endMinutes };
    }
    if ((endMinutes - nowMinutes) < SCHEDULED_LIVE_ACTIVITY_MIN_REMAINING_MINUTES) {
        return { allowed: false, reason: 'too_late_in_window', nowMinutes, startMinutes, endMinutes };
    }
    return { allowed: true, reason: 'within_window', nowMinutes, startMinutes, endMinutes };
}

function shouldPollNow(subscription, leg) {
    if (normalizeSource(subscription?.source) === LIVE_SESSION_SOURCE) {
        const activeUntil = Date.parse(subscription?.activeUntil || '');
        return !Number.isFinite(activeUntil) || activeUntil > Date.now();
    }
    const today = currentScheduleWeekdayKey();
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

function getScheduleTimeParts(date = new Date()) {
    const formatter = new Intl.DateTimeFormat('en-GB', {
        timeZone: SCHEDULE_TIME_ZONE,
        weekday: 'short',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        hourCycle: 'h23'
    });
    const parts = Object.fromEntries(
        formatter
            .formatToParts(date)
            .filter((part) => part.type !== 'literal')
            .map((part) => [part.type, part.value])
    );

    return {
        weekday: String(parts.weekday || '').toLowerCase().slice(0, 3),
        year: String(parts.year || ''),
        month: String(parts.month || '').padStart(2, '0'),
        day: String(parts.day || '').padStart(2, '0'),
        hour: Number(parts.hour || '0'),
        minute: Number(parts.minute || '0')
    };
}

function currentScheduleWeekdayKey(date = new Date()) {
    return getScheduleTimeParts(date).weekday;
}

function currentScheduleDateKey(date = new Date()) {
    const { year, month, day } = getScheduleTimeParts(date);
    return `${year}-${month}-${day}`;
}

function normalizeIsoDate(value) {
    if (!value || typeof value !== 'string') return null;
    const timestamp = Date.parse(value);
    if (!Number.isFinite(timestamp)) return null;
    return new Date(timestamp).toISOString();
}

function resolveLiveSessionActiveUntil(activeUntil, existingActiveUntil = null) {
    const now = Date.now();
    const maxAllowed = now + MAX_LIVE_SESSION_DURATION_MS;
    const preferred = normalizeIsoDate(activeUntil) || normalizeIsoDate(existingActiveUntil);
    const preferredTimestamp = preferred ? Date.parse(preferred) : NaN;
    const clampedTimestamp = Number.isFinite(preferredTimestamp)
        ? Math.min(Math.max(preferredTimestamp, now), maxAllowed)
        : maxAllowed;
    return new Date(clampedTimestamp).toISOString();
}

function getEffectiveNotificationTypes(subscription) {
    return normalizeTypes(subscription?.notificationTypes, normalizeSource(subscription?.source));
}

function isUpdateNotificationType(type) {
    return type === 'delays' || type === 'platform';
}

async function getDeparturesSnapshot(fromStation, toStation) {
    const result = await getTrainTimes(fromStation, toStation);
    const gracePeriodMs = 60 * 1000; // 1 minute grace, matching live-activity-manager sortDepartures
    const gracePeriodMinutes = gracePeriodMs / (60 * 1000);
    const nowMinutes = currentMinutes();
    const allDepartures = Array.isArray(result?.departures) ? result.departures : [];
    const upcomingDepartures = allDepartures
        .map((dep) => {
            const timeStr = dep.departure_time?.estimated || dep.departure_time?.scheduled;
            return {
                dep,
                relativeMinutes: relativeTimeMinutes(timeStr, nowMinutes)
            };
        })
        .filter(({ relativeMinutes }) => relativeMinutes !== null && relativeMinutes >= -gracePeriodMinutes)
        .sort((left, right) => left.relativeMinutes - right.relativeMinutes)
        .map(({ dep }) => dep);
    if (allDepartures.length > 0 && upcomingDepartures.length === 0) {
        console.log('[notifications] departures_filter_empty', JSON.stringify({
            from: fromStation,
            to: toStation,
            now_minutes: nowMinutes,
            raw_departures: allDepartures.slice(0, 5).map((dep) => ({
                scheduled: dep.departure_time?.scheduled || null,
                estimated: dep.departure_time?.estimated || null,
                relative_minutes: relativeTimeMinutes(dep.departure_time?.estimated || dep.departure_time?.scheduled, nowMinutes)
            }))
        }));
    }
    const departures = upcomingDepartures.slice(0, 3);
    const normalized = departures.map((dep) => ({
        serviceID: dep.serviceID,
        scheduled: dep.departure_time?.scheduled,
        estimated: dep.departure_time?.estimated || dep.departure_time?.scheduled,
        platform: dep.platform,
        isCancelled: dep.isCancelled,
        length: dep.length,
        destination: dep.destination
    }));
    return {
        departures: normalized,
        error: typeof result?.error === 'string' ? result.error : null,
        fetchedAt: new Date().toISOString()
    };
}

function relativeTimeMinutes(timeStr, referenceMinutes = currentMinutes()) {
    const minutes = parseTimeToMinutes(timeStr);
    if (minutes === null) {
        return null;
    }
    let diff = minutes - referenceMinutes;
    if (diff < -12 * 60) {
        diff += 24 * 60;
    } else if (diff > 12 * 60) {
        diff -= 24 * 60;
    }
    return diff;
}

function applyLastKnownPlatforms(snapshot, previousStateByService = {}) {
    if (!snapshot || !Array.isArray(snapshot.departures) || snapshot.departures.length === 0) {
        return snapshot;
    }

    return {
        ...snapshot,
        departures: snapshot.departures.map((dep) => {
            const currentPlatform = normalizePlatform(dep?.platform);
            if (currentPlatform || !dep?.serviceID) {
                return currentPlatform ? { ...dep, platform: currentPlatform } : dep;
            }

            const previousPlatform = normalizePlatform(previousStateByService?.[dep.serviceID]?.platform);
            if (!previousPlatform) {
                return dep;
            }

            return {
                ...dep,
                platform: previousPlatform
            };
        })
    };
}

function calculateDelayMinutes(scheduled, estimated) {
    if (!scheduled || !estimated) return 0;
    const scheduledMinutes = parseTimeToMinutes(scheduled);
    const estimatedMinutes = parseTimeToMinutes(estimated);
    if (scheduledMinutes === null || estimatedMinutes === null) return 0;
    let diff = estimatedMinutes - scheduledMinutes;
    if (diff < -12 * 60) {
        diff += 24 * 60;
    } else if (diff > 12 * 60) {
        diff -= 24 * 60;
    }
    return Math.max(0, diff);
}

function buildSummaryMessage(subscription, leg, snapshot) {
    const primary = snapshot.departures[0];
    if (!primary) return null;
    const departures = snapshot.departures.map((dep) => compactDepartureSummary(dep)).join(', ');
    const body = `Departures: ${departures}.`;
    return buildNotificationPayload(legRouteTitle(leg), body, buildLegMeta(subscription, leg, 'summary'), 'summary');
}

function buildScheduledLiveActivityStartPayload(subscription, leg, snapshot) {
    const routeTitle = legRouteTitle(leg);
    const contentState = buildScheduledLiveActivityContentState(subscription, leg, snapshot, routeTitle);
    const summary = buildSummaryMessage(subscription, leg, snapshot);
    const alert = summary?.payload?.aps?.alert || {
        title: routeTitle,
        body: contentState.statusText || 'Journey update'
    };

    return {
        aps: {
            timestamp: moment(snapshot?.fetchedAt || new Date().toISOString()).unix(),
            event: 'start',
            'relevance-score': 1.0,
            'stale-date': moment(snapshot?.fetchedAt || new Date().toISOString()).add(5, 'minutes').unix(),
            'input-push-token': 1,
            'content-state': contentState,
            'attributes-type': LIVE_ACTIVITY_ATTRIBUTES_TYPE,
            attributes: {
                displayName: routeTitle
            },
            alert: {
                ...alert,
                sound: 'default'
            }
        }
    };
}

function buildScheduledLiveActivityContentState(subscription, leg, snapshot, routeTitle) {
    const departures = Array.isArray(snapshot?.departures) ? snapshot.departures : [];
    const primary = departures[0] || {};
    const updatedAt = snapshot?.fetchedAt || new Date().toISOString();
    const estimated = getValidDepartureTime(primary.estimated) || getValidDepartureTime(primary.scheduled) || '--:--';
    const delayMinutes = calculateDelayMinutes(primary.scheduled, primary.estimated);
    const primaryPlatform = normalizePlatform(primary.platform) || '';

    return {
        fromCRS: String(leg?.from || '').toUpperCase(),
        toCRS: String(leg?.to || '').toUpperCase(),
        routeTitle,
        deepLinkFromCRS: String(leg?.from || '').toUpperCase(),
        deepLinkToCRS: String(leg?.to || '').toUpperCase(),
        destinationTitle: sanitizeDisplayLabel(primaryPlace(primary.destination)?.locationName) || legToLabel(leg),
        arrivalLabel: null,
        scheduledDeparture: getValidDepartureTime(primary.scheduled),
        length: Number.isFinite(primary.length) && primary.length > 0 ? primary.length : null,
        platform: primaryPlatform,
        estimated,
        isCancelled: Boolean(primary.isCancelled),
        statusText: buildStatusText(primary),
        delayMinutes,
        upcomingDepartures: departures.slice(1).map((dep) => ({
            time: getValidDepartureTime(dep.estimated) || getValidDepartureTime(dep.scheduled) || '--:--',
            arrivalTime: null,
            delayMinutes: calculateDelayMinutes(dep.scheduled, dep.estimated),
            isCancelled: Boolean(dep.isCancelled),
            platform: normalizePlatform(dep.platform),
            hasFasterLaterService: false
        })),
        lastUpdated: moment(updatedAt).unix(),
        activityID: null,
        revision: 0,
        appIsActive: false,
        journeyUpdatesEnabled: false,
        scheduleKey: buildScheduleKeyForLeg(leg),
        windowStart: leg.windowStart || null,
        windowEnd: leg.windowEnd || null
    };
}

function buildStatusText(dep) {
    if (dep.isCancelled) {
        return 'Cancelled';
    }
    const delayMinutes = calculateDelayMinutes(dep.scheduled, dep.estimated);
    if (delayMinutes > 0) {
        return `${delayMinutes} minute${delayMinutes === 1 ? '' : 's'} late`;
    }
    return 'On time';
}

function compactDepartureSummary(dep) {
    const time = formatDepartureTime(dep);
    const platform = normalizePlatform(dep?.platform) || 'TBC';
    return `${time} ${compactDepartureStatus(dep)} (plat. ${platform})`;
}

function compactDepartureStatus(dep) {
    if (dep?.isCancelled) {
        return '❌';
    }
    if (isUnknownDelay(dep)) {
        return '⚠️ delayed';
    }
    const delayMinutes = calculateDelayMinutes(dep?.scheduled, dep?.estimated);
    if (delayMinutes > 0) {
        return `⚠️ ${delayMinutes}m late`;
    }
    return '✅';
}

function buildDelayMessage(subscription, leg, dep) {
    const platform = dep.platform ? ` (platform ${dep.platform})` : ' (platform TBC)';
    const body = `${dep.scheduled} expected ${dep.estimated}${platform}.`;
    return buildNotificationPayload(legRouteTitle(leg), body, buildLegMeta(subscription, leg, 'delay'), 'delay');
}

function buildCancellationMessage(subscription, leg, dep) {
    const body = `${dep.scheduled} - cancelled.`;
    return buildNotificationPayload(legRouteTitle(leg), body, buildLegMeta(subscription, leg, 'cancellation'), 'cancellation');
}

function buildPlatformMessage(subscription, leg, dep) {
    const platform = normalizePlatform(dep.platform);
    if (!platform) {
        return null;
    }
    const expected = dep.estimated && dep.estimated !== dep.scheduled ? `, expected ${dep.estimated}` : '';
    const body = `${dep.scheduled} - platform ${platform}${expected}.`;
    return buildNotificationPayload(legRouteTitle(leg), body, buildLegMeta(subscription, leg, 'platform'), 'platform');
}

function normalizeMuteReason(reason) {
    const value = typeof reason === 'string' ? reason.trim().toLowerCase() : '';
    return value || 'mute_on_arrival';
}

function buildMutedMessages(
    subscription,
    leg,
    snapshot = null,
    context = { reason: 'mute_on_arrival' }
) {
    const muteContext = typeof context === 'string' ? { reason: context } : context;
    const notificationPlan = buildMuteNotificationPlan({
        stationName: legFromLabel(leg),
        ...muteContext
    });
    const routeTitle = legRouteTitle(leg);
    const greeting = buildNotificationPayload(
        routeTitle,
        notificationPlan[0].body,
        buildLegMeta(subscription, leg, 'muted_greeting'),
        'muted_greeting',
        'STATION_ARRIVAL'
    );

    if (!notificationPlan.some((notification) => notification.type === 'muted_status')) {
        return [greeting];
    }

    return [
        greeting,
        buildNotificationPayload(
            routeTitle,
            buildMutedStatusBody(leg, snapshot),
            buildLegMeta(subscription, leg, 'muted_status'),
            'muted_status'
        )
    ];
}

function buildMutedStatusBody(leg, snapshot) {
    const toLabel = legToLabel(leg);
    const departures = Array.isArray(snapshot?.departures) ? snapshot.departures : null;
    const primary = departures?.[0] || null;

    if (departures && departures.length === 0) {
        return `No upcoming departures to ${toLabel}. Please check station information.`;
    }

    if (!primary || snapshot?.error) {
        return 'Notifications are muted for today.';
    }

    if (primary.isCancelled) {
        const nextAvailable = snapshot.departures.find((dep) => dep && !dep.isCancelled);
        const cancelledTime = formatDepartureTime(primary);
        if (!nextAvailable) {
            return `${cancelledTime} to ${toLabel} is cancelled. No later trains are listed right now.`;
        }

        return `${cancelledTime} to ${toLabel} is cancelled. Next train: ${formatDepartureTime(nextAvailable)}${formatPlatformSuffix(nextAvailable)}.`;
    }

    if (isUnknownDelay(primary)) {
        return `Next train is delayed${formatUnknownDelayPlatformSuffix(primary)}.`;
    }

    const delayMinutes = calculateDelayMinutes(primary.scheduled, primary.estimated);
    if (delayMinutes > 0) {
        if (hasPlatform(primary)) {
            return `${formatEstimatedDepartureTime(primary)} from platform ${primary.platform.trim()}, ${delayMinutes} minute${delayMinutes === 1 ? '' : 's'} late.`;
        }
        return `${formatEstimatedDepartureTime(primary)}, ${delayMinutes} minute${delayMinutes === 1 ? '' : 's'} late. Platform TBC.`;
    }

    if (hasPlatform(primary)) {
        return `${formatDepartureTime(primary)} from platform ${primary.platform.trim()}, on time.`;
    }

    return `${formatDepartureTime(primary)}, on time. Platform TBC.`;
}

function scheduledSubscriptionsOverlap(existingSubscription, nextDaysOfWeek, nextLegs) {
    const existingDays = new Set(Array.isArray(existingSubscription?.daysOfWeek) ? existingSubscription.daysOfWeek : []);
    const nextDays = new Set(Array.isArray(nextDaysOfWeek) ? nextDaysOfWeek : []);
    const hasSharedDay = nextDays.size === 0
        ? true
        : Array.from(nextDays).some((day) => existingDays.has(day));

    if (!hasSharedDay) {
        return false;
    }

    const nextLegKeys = new Set(
        (Array.isArray(nextLegs) ? nextLegs : [])
            .filter((leg) => leg?.enabled)
            .map((leg) => scheduledLegKey(leg))
    );

    return (Array.isArray(existingSubscription?.legs) ? existingSubscription.legs : []).some(
        (leg) => leg?.enabled && nextLegKeys.has(scheduledLegKey(leg))
    );
}

function scheduledLegKey(leg) {
    return [
        String(leg?.from || '').toUpperCase(),
        String(leg?.to || '').toUpperCase(),
        leg?.windowStart || '',
        leg?.windowEnd || ''
    ].join('|');
}

function subscriptionTimestamp(subscription) {
    const updated = Date.parse(subscription?.updatedAt || '');
    if (Number.isFinite(updated)) return updated;
    const created = Date.parse(subscription?.createdAt || '');
    return Number.isFinite(created) ? created : 0;
}

function hasPlatform(dep) {
    return normalizePlatform(dep?.platform) !== null;
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

function legRouteTitle(leg) {
    return `${legFromLabel(leg)} → ${legToLabel(leg)}`;
}

function legFromLabel(leg) {
    return sanitizeDisplayLabel(leg?.fromName) || sanitizeDisplayLabel(leg?.from) || 'Origin';
}

function legToLabel(leg) {
    return sanitizeDisplayLabel(leg?.toName) || sanitizeDisplayLabel(leg?.to) || 'Destination';
}

function sanitizeDisplayLabel(value) {
    const label = ensureNonEmptyString(value);
    if (!label) return null;
    return label.replace(/\s*\[v\d+\]\s*$/i, '').trim();
}

function legRouteKey(leg) {
    return `${String(leg?.from || '').toUpperCase()}-${String(leg?.to || '').toUpperCase()}`;
}

function buildScheduleKeyForLeg(leg) {
    return [
        String(leg?.from || '').toUpperCase(),
        String(leg?.to || '').toUpperCase()
    ].join('-') + `|${leg?.windowStart || ''}|${leg?.windowEnd || ''}|${currentScheduleDateKey()}`;
}

function ensureNonEmptyString(value) {
    return typeof value === 'string' && value.trim().length > 0 ? value.trim() : null;
}

function formatPlatformSuffix(dep) {
    return hasPlatform(dep) ? ` from platform ${dep.platform.trim()}` : ', platform TBC';
}

function formatUnknownDelayPlatformSuffix(dep) {
    return hasPlatform(dep) ? `. Due from platform ${dep.platform.trim()}` : '. Platform TBC';
}

function normalizePlatform(value) {
    if (typeof value !== 'string') return null;
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
}

function buildNotificationPayload(
    title,
    body,
    meta = {},
    type = 'unknown',
    category = 'JOURNEY_LEG_ALERT',
    { includeContentAvailable = false } = {}
) {
    const aps = {};
    if (title || body) {
        aps.alert = { title, body };
        aps.sound = 'default';
        aps['mutable-content'] = 1;
        aps.category = category;
        if (includeContentAvailable) {
            aps['content-available'] = 1;
        }
    } else {
        aps['content-available'] = 1;
    }
    return {
        type,
        payload: {
            aps,
            ...meta
        }
    };
}

function buildLegMeta(subscription, leg, alertType) {
    const meta = {
        subscription_id: subscription.id,
        route_key: legRouteKey(leg),
        subscription_route_key: subscription.routeKey,
        from: leg.from,
        to: leg.to,
        leg_key: `${leg.from}-${leg.to}`,
        schedule_key: buildScheduleKeyForLeg(leg),
        alert_type: alertType,
        window_start: leg.windowStart,
        window_end: leg.windowEnd
    };
    if (leg.fromName) meta.from_name = sanitizeDisplayLabel(leg.fromName);
    if (leg.toName) meta.to_name = sanitizeDisplayLabel(leg.toName);
    return meta;
}

function buildPushContext(subscription, leg, reason, metadata = {}) {
    return {
        reason,
        ...metadata,
        device_id: subscription?.deviceId || null,
        subscription_id: subscription?.id || null,
        route_key: leg ? legRouteKey(leg) : (subscription?.routeKey || null),
        subscription_route_key: subscription?.routeKey || null,
        source: subscription?.source || null,
        from: leg?.from || null,
        to: leg?.to || null,
        leg_key: leg ? `${leg.from}-${leg.to}` : null,
        window_start: leg?.windowStart || null,
        window_end: leg?.windowEnd || null,
        schedule_key: leg ? buildScheduleKeyForLeg(leg) : null,
        notification_types: getEffectiveNotificationTypes(subscription)
    };
}

export const notificationSubscriptionManager = new NotificationSubscriptionManager();
