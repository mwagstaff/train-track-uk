import moment from 'moment';
import { getTrainTimes } from './realtime-trains-api.js';
import { LiveActivityPushClient } from './live-activity-push-client.js';
import { getServiceDetails } from './service-details.js';
import { primaryPlace } from './departure-places.js';
import { recordNotificationEvent } from './admin-data-store.js';
import { getDeviceLastSeen } from './metrics.js';
import { notificationSubscriptionManager } from './notification-subscription-manager.js';
import { COLLECTIONS, getMongoCollection } from './mongo-client.js';
import { minutesUntilDeparture } from './live-activity-departure-order.js';
import { allowDeviceData } from './device-data-deletion-state.js';

const DEFAULT_POLL_INTERVAL_SECONDS = Number(process.env.LIVE_ACTIVITY_POLL_INTERVAL_SECONDS || '20');
const DEFAULT_END_AFTER_SECONDS = Number(process.env.LIVE_ACTIVITY_END_AFTER_SECONDS || '7200'); // default 2 hours
const DEFAULT_STALE_DATE_REFRESH_SECONDS = Number(process.env.LIVE_ACTIVITY_STALE_DATE_REFRESH_SECONDS || '240'); // refresh stale-date every 4 minutes
const APP_CHECKIN_WARNING_AFTER_SECONDS = Number(process.env.LIVE_ACTIVITY_APP_CHECKIN_WARNING_AFTER_SECONDS || '120');
const DEFAULT_MAX_ACTIVE_PER_DEVICE = Number(process.env.LIVE_ACTIVITY_MAX_ACTIVE_PER_DEVICE || '5');

export class LiveActivityManager {
    constructor() {
        this.subscriptions = new Map();
        this.pushClient = new LiveActivityPushClient();
        this.pollIntervalMs = DEFAULT_POLL_INTERVAL_SECONDS * 1000;
        this.isPolling = false;
        this.pollTimer = null;
        this.deletedDeviceIds = new Set();
        this.startPollingLoop();
    }

    async init() {
        await this.loadSubscriptionsFromMongo();
    }

    startPollingLoop() {
        if (this.pollTimer) {
            return;
        }
        this.pollTimer = setInterval(() => {
            this.pollAll().catch((error) => {
                console.error(`Live activity poll failed: ${error?.message || error}`);
            });
        }, this.pollIntervalMs).unref?.();
    }

    async loadSubscriptionsFromMongo() {
        const collection = await getMongoCollection(COLLECTIONS.liveActivitySessions);
        const documents = await collection.find({}).toArray();
        let loaded = 0;
        const now = Date.now();
        for (const document of documents) {
            const subscription = stripMongoId(document);
            if (!subscription?.deviceId || !subscription?.activityId || !subscription?.pushToken) {
                continue;
            }
            const endAtMs = Date.parse(subscription.endAt || '');
            if (Number.isFinite(endAtMs) && endAtMs <= now) {
                await this.deleteSubscriptionFromMongo(subscription);
                continue;
            }
            const key = this.buildKey(subscription.deviceId, subscription.activityId);
            this.subscriptions.set(key, subscription);
            this.scheduleEnd(subscription);
            loaded += 1;
        }
        console.log(`[live-activity] Loaded ${loaded} active session(s) from Mongo`);
    }

    registerSubscription({
        deviceId,
        activityId,
        pushToken,
        fromStation,
        toStation,
        displayName,
        deepLinkFromStation,
        deepLinkToStation,
        preferredServiceId,
        useSandbox,
        muteOnArrival,
        muteDelayMinutes,
        autoEndOnArrival,
        autoEndOnDeparture,
        journeyPhase,
        scheduleKey,
        journeyUpdatesEnabled,
        windowStart,
        windowEnd
    }) {
        if (!allowDeviceData(deviceId)) {
            throw new Error('Device data deletion is in progress');
        }
        this.deletedDeviceIds.delete(deviceId);
        const key = this.buildKey(deviceId, activityId);
        const existing = this.subscriptions.get(key);

        // Track token changes for debugging
        const tokenPreview = this.maskToken(pushToken);
        const isTokenUpdate = existing && existing.pushToken !== pushToken;

        if (isTokenUpdate) {
            const oldTokenPreview = this.maskToken(existing.pushToken);
            this.log(`[live-activity] token_rotation ${deviceId}/${activityId} old=${oldTokenPreview} new=${tokenPreview}`);
            console.log(`🔄 [live-activity] Token rotation detected for ${key}: ${oldTokenPreview} → ${tokenPreview}`);
        } else if (existing) {
            this.log(`[live-activity] token_reregister ${deviceId}/${activityId} token=${tokenPreview} (same token)`);
        } else {
            this.log(`[live-activity] token_initial ${deviceId}/${activityId} token=${tokenPreview} sandbox=${useSandbox}`);
        }

        const subscription = {
            deviceId,
            activityId,
            pushToken,
            fromStation,
            toStation,
            displayName: (typeof displayName === 'string' && displayName.length > 0)
                ? displayName
                : (existing?.displayName || null),
            deepLinkFromStation: (typeof deepLinkFromStation === 'string' && deepLinkFromStation.length > 0)
                ? deepLinkFromStation
                : (existing?.deepLinkFromStation || null),
            deepLinkToStation: (typeof deepLinkToStation === 'string' && deepLinkToStation.length > 0)
                ? deepLinkToStation
                : (existing?.deepLinkToStation || null),
            preferredServiceId: (typeof preferredServiceId === 'string' && preferredServiceId.length > 0)
                ? preferredServiceId
                : (existing?.preferredServiceId || null),
            useSandbox: Boolean(useSandbox), // Defaults to false (production) if not provided
            muteOnArrival: muteOnArrival !== undefined ? Boolean(muteOnArrival) : (existing?.muteOnArrival ?? true),
            muteDelayMinutes: Number.isFinite(Number(muteDelayMinutes)) && Number(muteDelayMinutes) >= 0
                ? Math.min(10, Math.max(1, Math.round(Number(muteDelayMinutes))))
                : (existing?.muteDelayMinutes ?? 5),
            autoEndOnArrival: autoEndOnArrival !== undefined ? Boolean(autoEndOnArrival) : (existing?.autoEndOnArrival ?? false),
            autoEndOnDeparture: autoEndOnDeparture !== undefined ? Boolean(autoEndOnDeparture) : (existing?.autoEndOnDeparture ?? false),
            createdAt: existing?.createdAt || new Date().toISOString(),
            lastSnapshot: existing?.lastSnapshot || null,
            preferredDepartureSnapshot: existing?.preferredDepartureSnapshot || null,
            lastPushAt: existing?.lastPushAt || null,
            revision: existing?.revision || 0,
            tokenUpdatedAt: new Date().toISOString(),
            appIsActive: existing?.appIsActive ?? false,
            cancelledDepartureAlertsSent: existing?.cancelledDepartureAlertsSent || {},
            journeyPhase: ['pending_start', 'at_start', 'en_route', 'arrived'].includes(journeyPhase)
                ? journeyPhase
                : (existing?.journeyPhase || 'pending_start'),
            journeyUpdatesEnabled: journeyUpdatesEnabled !== undefined
                ? Boolean(journeyUpdatesEnabled)
                : (existing?.journeyUpdatesEnabled ?? !(scheduleKey || existing?.scheduleKey)),
            scheduleKey: scheduleKey || existing?.scheduleKey || null,
            windowStart: windowStart || existing?.windowStart || null,
            windowEnd: windowEnd || existing?.windowEnd || null
        };

        this.subscriptions.set(key, subscription);
        this.scheduleEnd(subscription);
        this.saveSubscriptionToMongo(subscription).catch((error) => {
            console.error(`[live-activity] Failed to persist registered session ${key}: ${error?.message || error}`);
        });
        const evicted = this.evictDuplicateSessionsForDevice(deviceId, activityId);
        for (const stale of evicted) {
            this.sendEndPushForEvictedSubscription(stale, 'register_duplicate_evict').catch((error) => {
                const staleKey = this.buildKey(stale.deviceId, stale.activityId);
                console.error(`[live-activity] evicted end push failed for ${staleKey}: ${error?.message || error}`);
            });
        }

        // Log registration event for admin visibility
        recordNotificationEvent({
            channel: 'live_activity',
            type: isTokenUpdate ? 'live_activity_token_rotation' : (existing ? 'live_activity_reregister' : 'live_activity_register'),
            success: true,
            status: 200,
            apns_environment: subscription.useSandbox ? 'sandbox' : 'prod',
            activity_id: activityId,
            device_id: deviceId,
            route_key: `${fromStation || ''}-${toStation || ''}`,
            from_station: fromStation || null,
            to_station: toStation || null,
            token: pushToken || null,
            metadata: {
                display_name: subscription.displayName || null,
                deep_link_from: subscription.deepLinkFromStation || null,
                deep_link_to: subscription.deepLinkToStation || null,
                preferred_service_id: subscription.preferredServiceId || null,
                mute_on_arrival: subscription.muteOnArrival,
                auto_end_on_arrival: subscription.autoEndOnArrival,
                auto_end_on_departure: subscription.autoEndOnDeparture,
                created_at: subscription.createdAt || null
            }
        }).catch((error) => {
            console.error('[admin] Failed to log live activity registration event:', error?.message || error);
        });

        // Trigger an immediate check so the caller gets fresh data right away
        this.pollSubscription(subscription, { force: true }).catch((error) => {
            console.error(`Initial poll for ${key} failed: ${error?.message || error}`);
        });

        return subscription;
    }

    scheduleEnd(subscription) {
        this.clearEndTimer(subscription);
        let endAfterMs = this.getEndAfterMs();
        let endReason = 'duration_elapsed';
        let endPolicy = 'fixed_duration';
        let windowEndBufferMs = null;

        const persistedEndAtMs = Date.parse(subscription.endAt || '');
        if (Number.isFinite(persistedEndAtMs) && persistedEndAtMs > Date.now()) {
            endAfterMs = Math.max(persistedEndAtMs - Date.now(), 0);
            endReason = subscription.endReason || endReason;
            endPolicy = subscription.endPolicy || endPolicy;
            windowEndBufferMs = subscription.windowEndBufferMs ?? null;
        }

        // If the subscription has a windowEnd, end the live activity shortly after
        // the window closes rather than using a fixed duration from registration time.
        if (!Number.isFinite(persistedEndAtMs) && subscription.windowEnd) {
            const windowEndMs = this.computeWindowEndMs(subscription.windowEnd);
            if (windowEndMs !== null) {
                const bufferMs = 5 * 60 * 1000; // 5-minute grace after window end
                endAfterMs = Math.max((windowEndMs - Date.now()) + bufferMs, 0);
                endReason = 'window_end_grace_elapsed';
                endPolicy = 'window_end_plus_grace';
                windowEndBufferMs = bufferMs;
            }
        }

        subscription.endAt = new Date(Date.now() + endAfterMs).toISOString();
        subscription.endReason = endReason;
        subscription.endPolicy = endPolicy;
        subscription.endAfterMs = endAfterMs;
        subscription.windowEndBufferMs = windowEndBufferMs;
        subscription.endTimer = setTimeout(() => {
            this.sendEndUpdate(subscription, { reason: endReason, trigger: 'timer' }).catch((error) => {
                const key = this.buildKey(subscription.deviceId, subscription.activityId);
                console.error(`Final live activity end push failed for ${key}: ${error?.message || error}`);
            });
        }, endAfterMs);
        subscription.endTimer.unref?.();
    }

    /**
     * Computes the Unix timestamp (ms) for a given HH:mm window-end time today,
     * expressed in the Europe/London schedule timezone.
     * Returns null if the input is invalid.
     */
    computeWindowEndMs(windowEnd) {
        if (!windowEnd || typeof windowEnd !== 'string') return null;
        const parts = windowEnd.split(':');
        if (parts.length !== 2) return null;
        const endHour = Number(parts[0]);
        const endMinute = Number(parts[1]);
        if (!Number.isFinite(endHour) || !Number.isFinite(endMinute)) return null;
        if (endHour < 0 || endHour > 23 || endMinute < 0 || endMinute > 59) return null;

        // Get current time in the schedule timezone to find current local h/m
        const SCHEDULE_TIME_ZONE = process.env.NOTIFICATION_SCHEDULE_TIME_ZONE || 'Europe/London';
        const formatter = new Intl.DateTimeFormat('en-GB', {
            timeZone: SCHEDULE_TIME_ZONE,
            hour: '2-digit',
            minute: '2-digit',
            hourCycle: 'h23'
        });
        const now = new Date();
        const timeParts = Object.fromEntries(
            formatter.formatToParts(now)
                .filter((p) => p.type !== 'literal')
                .map((p) => [p.type, p.value])
        );
        const localNowMinutes = Number(timeParts.hour) * 60 + Number(timeParts.minute);
        const endWindowMinutes = endHour * 60 + endMinute;
        const diffMinutes = endWindowMinutes - localNowMinutes;
        return Date.now() + diffMinutes * 60 * 1000;
    }

    clearEndTimer(subscription) {
        if (subscription?.endTimer) {
            clearTimeout(subscription.endTimer);
            delete subscription.endTimer;
        }
    }

    async pollAll() {
        if (this.isPolling || this.subscriptions.size === 0) {
            return;
        }

        this.isPolling = true;
        try {
            await this.tidyDuplicateSessions();
            const jobs = Array.from(this.subscriptions.values()).map((subscription) =>
                this.pollSubscription(subscription).catch((error) => {
                    const key = this.buildKey(subscription.deviceId, subscription.activityId);
                    console.error(`Poll for ${key} failed: ${error?.message || error}`);
                    return null;
                })
            );
            await Promise.all(jobs);
        } finally {
            this.isPolling = false;
        }
    }

    async pollSubscription(subscription, { force = false, dryRun = false } = {}) {
        if (this.deletedDeviceIds.has(subscription?.deviceId)) {
            return { sent: false, reason: 'device_data_deleted' };
        }
        // Guard against concurrent polls of the same subscription. This prevents a
        // double-push race between the registration-forced poll and the periodic pollAll()
        // timer both firing for the same subscription at almost the same moment.
        if (subscription.isPollInProgress) {
            if (force) {
                subscription.pendingForcedPoll = true;
            }
            this.log(`[live-activity] poll_skipped_concurrent ${subscription.deviceId}/${subscription.activityId}`);
            return { sent: false, reason: 'concurrent_poll' };
        }
        subscription.isPollInProgress = true;
        try {
            const snapshot = this.applyLastKnownPlatforms(
                await this.getDeparturesSnapshot(
                    subscription.fromStation,
                    subscription.toStation,
                    subscription.preferredServiceId,
                    {
                        journeyPhase: subscription.journeyPhase,
                        previousSnapshot: subscription.lastSnapshot,
                        preferredDepartureSnapshot: subscription.preferredDepartureSnapshot
                    }
                ),
                subscription.lastSnapshot
            );
            const appIsActive = this.shouldShowAppActive(subscription);
            const appIsActiveChanged = Boolean(subscription.appIsActive) !== appIsActive;
            const hasChanged = force || appIsActiveChanged || !this.snapshotsEqual(snapshot, subscription.lastSnapshot);

            // Check if we need to refresh stale-date even if data hasn't changed
            // This prevents iOS from marking the activity as stale and stops displaying updates
            const needsStaleDateRefresh = this.shouldRefreshStaleDate(subscription);

            if (!hasChanged && !needsStaleDateRefresh) {
                this.log(`[live-activity] no_change ${subscription.deviceId}/${subscription.activityId}`);
                return { sent: false, reason: 'no_change', snapshot };
            }

            if (!hasChanged && needsStaleDateRefresh) {
                this.log(`[live-activity] stale_date_refresh ${subscription.deviceId}/${subscription.activityId} (keeping activity fresh)`);
            }

            if (snapshot.departures.length === 0) {
                this.log(`[live-activity] no_departures ${subscription.deviceId}/${subscription.activityId}`);
                return { sent: false, reason: 'no_departures', snapshot };
            }

            const payload = this.buildPayload(subscription, snapshot, {
                appIsActive,
                markCancellationAlerts: !dryRun
            });

            if (dryRun) {
                this.log(`[live-activity] dry_run ${subscription.deviceId}/${subscription.activityId}`);
                return { sent: false, reason: 'dry_run', snapshot, payload };
            }

            const pushResponse = await this.pushClient.sendLiveActivityUpdate(subscription.pushToken, payload, {
                useSandbox: subscription.useSandbox,
                event: 'live_activity_update',
                context: this.buildPushContext(subscription, 'poll_update')
            });
            this.logPushEvent(subscription, payload, pushResponse, 'live_activity_update');

            // If the token is bad/expired, remove this subscription
            if (pushResponse?.isBadToken) {
                const key = this.buildKey(subscription.deviceId, subscription.activityId);
                console.log(`🗑️ [live-activity] Removing subscription ${key} due to bad/expired token`);
                this.clearEndTimer(subscription);
                this.subscriptions.delete(key);
                await this.deleteSubscriptionFromMongo(subscription);
                this.deleteMatchingLiveSessions(subscription).catch((error) => {
                    console.error(`[live-activity] Failed to delete matching live sessions for ${key}: ${error?.message || error}`);
                });
                return { sent: false, reason: 'bad_token', snapshot, payload, pushResponse };
            }

            subscription.lastSnapshot = snapshot;
            const preferredDeparture = snapshot.departures.find(
                (departure) => departure.serviceID === subscription.preferredServiceId
            );
            if (preferredDeparture) subscription.preferredDepartureSnapshot = preferredDeparture;
            subscription.lastPushAt = snapshot.fetchedAt;
            subscription.revision = (subscription.revision || 0) + 1;
            subscription.appIsActive = appIsActive;
            this.saveSubscriptionToMongo(subscription).catch((error) => {
                const key = this.buildKey(subscription.deviceId, subscription.activityId);
                console.error(`[live-activity] Failed to persist poll state for ${key}: ${error?.message || error}`);
            });

            this.log(
                `[live-activity] push_payload ${subscription.deviceId}/${subscription.activityId}`,
                { payload }
            );

            this.log(
                `[live-activity] pushed ${subscription.deviceId}/${subscription.activityId}`,
                {
                    status: pushResponse?.status,
                    departures: snapshot.departures.length,
                    fetchedAt: snapshot.fetchedAt
                }
            );

            return { sent: true, snapshot, payload, pushResponse };
        } finally {
            subscription.isPollInProgress = false;
            if (subscription.pendingForcedPoll) {
                subscription.pendingForcedPoll = false;
                this.pollSubscription(subscription, { force: true }).catch((error) => {
                    const key = this.buildKey(subscription.deviceId, subscription.activityId);
                    console.error(`[live-activity] queued force poll failed for ${key}: ${error?.message || error}`);
                });
            }
        }
    }

    async sendEndUpdate(subscription, { reason = subscription.endReason || 'unknown', trigger = 'unknown' } = {}) {
        const key = this.buildKey(subscription.deviceId, subscription.activityId);
        const endContext = {
            end_reason: reason,
            end_trigger: trigger,
            end_policy: subscription.endPolicy || null,
            end_scheduled_at: subscription.endAt || null,
            end_after_ms: Number.isFinite(subscription.endAfterMs) ? subscription.endAfterMs : null,
            window_end_buffer_ms: Number.isFinite(subscription.windowEndBufferMs) ? subscription.windowEndBufferMs : null
        };
        const snapshot = subscription.lastSnapshot || (
            await this.getDeparturesSnapshot(
                subscription.fromStation,
                subscription.toStation,
                subscription.preferredServiceId,
                {
                    journeyPhase: subscription.journeyPhase,
                    previousSnapshot: subscription.lastSnapshot,
                    preferredDepartureSnapshot: subscription.preferredDepartureSnapshot
                }
            )
        );
        const payload = this.buildPayload(subscription, snapshot, {
            end: true,
            appIsActive: this.shouldShowAppActive(subscription)
        });
        const pushResponse = await this.pushClient.sendLiveActivityUpdate(subscription.pushToken, payload, {
            useSandbox: subscription.useSandbox,
            event: 'live_activity_end',
            context: this.buildPushContext(subscription, 'end', endContext)
        });
        this.logPushEvent(subscription, payload, pushResponse, 'live_activity_end', endContext);

        // Clean up subscription regardless of push result
        this.clearEndTimer(subscription);
        this.subscriptions.delete(key);
        await this.deleteSubscriptionFromMongo(subscription);
        await this.deleteMatchingLiveSessions(subscription);

        // Log if token was bad/expired (expected when activity was already dismissed)
        if (pushResponse?.isBadToken) {
            console.log(`🗑️ [live-activity] Token already expired for ${key} (activity likely already dismissed)`);
        }

        this.log(
            `[live-activity] end_payload ${subscription.deviceId}/${subscription.activityId}`,
            { payload }
        );
        this.log(
            `[live-activity] ended ${subscription.deviceId}/${subscription.activityId}`,
            {
                status: pushResponse?.status,
                departures: snapshot.departures.length,
                fetchedAt: snapshot.fetchedAt,
                endAt: subscription.endAt,
                endReason: reason,
                endTrigger: trigger,
                endPolicy: subscription.endPolicy || null
            }
        );
        return { snapshot, payload, pushResponse };
    }

    async endAllForDevice(deviceId, { reason = 'manual', trigger = 'manual' } = {}) {
        const matching = Array.from(this.subscriptions.values()).filter((subscription) =>
            subscription.deviceId === deviceId
        );
        const results = await Promise.allSettled(matching.map((subscription) =>
            this.sendEndUpdate(subscription, { reason, trigger })
        ));

        for (const result of results) {
            if (result.status === 'rejected') {
                console.error(`[live-activity] Failed to end activity for ${deviceId}: ${result.reason?.message || result.reason}`);
            }
        }

        return {
            requested: matching.length,
            ended: results.filter((result) => result.status === 'fulfilled').length
        };
    }

    logPushEvent(subscription, payload, pushResponse, type, extraMetadata = {}) {
        if (this.deletedDeviceIds.has(subscription?.deviceId)) return;
        const status = pushResponse?.status ?? null;
        const success = typeof status === 'number' && status >= 200 && status < 300;
        recordNotificationEvent({
            channel: 'live_activity',
            type,
            success,
            status,
            error: pushResponse?.error || pushResponse?.body?.reason || null,
            apns_environment: subscription.useSandbox ? 'sandbox' : 'prod',
            activity_id: subscription.activityId,
            device_id: subscription.deviceId,
            route_key: `${subscription.fromStation || ''}-${subscription.toStation || ''}`,
            from_station: subscription.fromStation || null,
            to_station: subscription.toStation || null,
            token: subscription.pushToken || null,
            is_bad_token: Boolean(pushResponse?.isBadToken),
            payload,
            response: pushResponse || null,
            metadata: {
                preferred_service_id: subscription.preferredServiceId || null,
                journey_updates_enabled: Boolean(subscription.journeyUpdatesEnabled),
                created_at: subscription.createdAt || null,
                ...extraMetadata
            }
        }).catch((error) => {
            console.error('[admin] Failed to log live activity event:', error?.message || error);
        });
    }

    buildPushContext(subscription, reason, extra = {}) {
        return {
            reason,
            device_id: subscription.deviceId,
            activity_id: subscription.activityId,
            route_key: `${subscription.fromStation || ''}-${subscription.toStation || ''}`,
            from: subscription.fromStation || null,
            to: subscription.toStation || null,
            preferred_service_id: subscription.preferredServiceId || null,
            schedule_key: subscription.scheduleKey || null,
            window_start: subscription.windowStart || null,
            window_end: subscription.windowEnd || null,
            journey_updates_enabled: Boolean(subscription.journeyUpdatesEnabled),
            ...extra
        };
    }

    async getDeparturesSnapshot(
        fromStation,
        toStation,
        preferredServiceId = null,
        {
            journeyPhase = 'pending_start',
            previousSnapshot = null,
            preferredDepartureSnapshot = null
        } = {}
    ) {
        const result = await getTrainTimes(fromStation, toStation);
        const rawDepartures = Array.isArray(result?.departures) ? result.departures : [];

        const normalizedAll = rawDepartures.map((dep) => ({
            serviceID: dep.serviceID,
            scheduled: dep.departure_time?.scheduled,
            estimated: dep.departure_time?.estimated,
            platform: dep.platform,
            operator: dep.operator,
            isCancelled: dep.isCancelled,
            length: dep.length,
            destination: dep.destination,
            origin: dep.origin,
            delayReason: dep.delayReason,
            cancelReason: dep.cancelReason
        }));

        const isInProgress = journeyPhase === 'en_route' || journeyPhase === 'arrived';
        if (isInProgress && preferredServiceId && !normalizedAll.some((dep) => dep.serviceID === preferredServiceId)) {
            const previousService = previousSnapshot?.departures?.find((dep) => dep.serviceID === preferredServiceId);
            const retainedService = previousService?.serviceID === preferredServiceId
                ? previousService
                : (preferredDepartureSnapshot?.serviceID === preferredServiceId ? preferredDepartureSnapshot : null);
            if (retainedService) normalizedAll.push(retainedService);
        }

        const sortedUpcoming = this.sortDepartures(normalizedAll);
        const departures = isInProgress
            ? normalizedAll.filter((dep) => dep.serviceID === preferredServiceId).slice(0, 1)
            : this.selectDeparturesForActivity(
                normalizedAll,
                sortedUpcoming,
                preferredServiceId
            ).slice(0, 3);

        // Fetch service details only for selected departures to keep polling lightweight.
        const serviceDetailsPromises = departures.map(dep =>
            getServiceDetails(dep.serviceID).catch(err => {
                console.warn(`Failed to fetch service details for ${dep.serviceID}: ${err?.message || err}`);
                return null;
            })
        );
        const serviceDetails = await Promise.all(serviceDetailsPromises);

        const normalized = departures.map((dep, index) => {
            const details = serviceDetails[index];
            const richStatus = this.computeRichStatus(dep, details);

            return {
                ...dep,
                arrivalTime: dep.isCancelled ? null : this.arrivalTimeForDestination(details, toStation),
                actualArrivalTime: dep.isCancelled ? null : this.actualArrivalTimeForDestination(details, toStation),
                arrivalDelayMinutes: dep.isCancelled ? null : this.confirmedArrivalDelayForDestination(details, toStation),
                arrivalPlatform: this.platformForStation(details, toStation),
                departedTime: this.departureTimeForStation(details, fromStation, dep.scheduled),
                statusText: richStatus // Include rich status for comparison
            };
        });

        return {
            departures: normalized,
            fetchedAt: new Date().toISOString()
        };
    }

    buildPayload(subscription, snapshot, { end = false, appIsActive = false, markCancellationAlerts = true } = {}) {
        const aps = {
            timestamp: moment(snapshot.fetchedAt).unix(),
            event: end ? 'end' : 'update',
            'relevance-score': 1.0,  // Maximum relevance (0.0 to 1.0) - tells iOS this is important
            'content-state': this.buildContentState(subscription, snapshot, appIsActive)  // Must be inside aps for ActivityKit
        };

        if (end) {
            aps['dismissal-date'] = 0; // immediate dismissal
        } else {
            // Set stale date to 5 minutes from now - tells iOS when data becomes outdated
            aps['stale-date'] = moment(snapshot.fetchedAt).add(5, 'minutes').unix();

            // Add an alert for significant changes so iOS shows a banner notification
            const alert = this.buildAlert(subscription, subscription.lastSnapshot, snapshot, { markCancellationAlerts });
            if (alert) {
                aps.alert = alert;
                aps.sound = 'default';
            }
        }

        const payload = { aps };

        if (end) {
            payload.endedAt = snapshot.fetchedAt;
        }

        return payload;
    }

    /**
     * Compares the previous and new departure snapshots and returns an APNs alert object
     * when a significant change is detected:
     *  - Cancellation of the primary (first) departure
     *  - Cancellation of a subsequent departure when journey updates are enabled
     *  - Platform change for the primary departure
     *  - Delay increase of ≥ 5 minutes for the primary departure (and at least 3 minutes worse than before)
     *
     * Returns null if no significant change is detected or if the snapshots represent
     * different services (to avoid false alerts on service rotations).
     */
    buildAlert(subscription, prevSnapshot, newSnapshot, { markCancellationAlerts = true } = {}) {
        if (!prevSnapshot || !newSnapshot) return null;
        const prev = prevSnapshot.departures[0];
        const next = newSnapshot.departures[0];
        if (!prev || !next) return this.buildSubsequentCancellationAlert(subscription, prevSnapshot, newSnapshot, { markCancellationAlerts });

        // Only compare the same service to avoid false positives when a different
        // train becomes the primary departure between polls.
        const primaryServiceChanged = prev.serviceID && next.serviceID && prev.serviceID !== next.serviceID;

        // Cancellation
        if (!primaryServiceChanged && !prev.isCancelled && next.isCancelled && !this.hasCancellationAlertBeenSent(subscription, next)) {
            this.markCancellationAlertSent(subscription, next, markCancellationAlerts);
            const time = next.scheduled ? ` ${next.scheduled}` : '';
            return {
                title: 'Train Cancelled',
                body: `Your${time} service has been cancelled.`
            };
        }

        const subsequentCancellationAlert = this.buildSubsequentCancellationAlert(subscription, prevSnapshot, newSnapshot, { markCancellationAlerts });
        if (subsequentCancellationAlert) {
            return subsequentCancellationAlert;
        }

        if (primaryServiceChanged) {
            return null;
        }

        // Platform change (only alert when both sides have a known platform)
        const previousPlatform = this.normalizePlatform(prev.platform);
        const nextPlatform = this.normalizePlatform(next.platform);
        if (previousPlatform && nextPlatform && previousPlatform !== nextPlatform) {
            return {
                title: 'Platform Change',
                body: `Platform changed from ${previousPlatform} to ${nextPlatform}.`
            };
        }

        // Significant delay increase: new delay ≥ 5 min AND at least 3 min worse than before
        const prevDelay = this.calculateDelay(prev.scheduled, prev.estimated);
        const nextDelay = this.calculateDelay(next.scheduled, next.estimated);
        if (nextDelay >= 5 && nextDelay >= prevDelay + 3) {
            return {
                title: 'Delay Update',
                body: `Your train is now running ${nextDelay} minutes late.`
            };
        }

        return null;
    }

    buildSubsequentCancellationAlert(subscription, prevSnapshot, newSnapshot, { markCancellationAlerts = true } = {}) {
        if (!subscription?.journeyUpdatesEnabled) {
            return null;
        }

        const previousByService = new Map(
            (Array.isArray(prevSnapshot?.departures) ? prevSnapshot.departures : [])
                .filter((dep) => dep?.serviceID)
                .map((dep) => [dep.serviceID, dep])
        );
        const newDepartures = Array.isArray(newSnapshot?.departures) ? newSnapshot.departures : [];

        for (const dep of newDepartures.slice(1)) {
            if (!dep?.isCancelled) continue;
            if (this.hasCancellationAlertBeenSent(subscription, dep)) continue;

            const previous = dep.serviceID ? previousByService.get(dep.serviceID) : null;
            if (!previous || previous.isCancelled) continue;

            this.markCancellationAlertSent(subscription, dep, markCancellationAlerts);
            const time = this.getTimeString(dep.estimated, dep.scheduled, dep.scheduled || '');
            return {
                title: 'Train Cancelled',
                body: `${time || 'Service'} now cancelled`
            };
        }

        return null;
    }

    cancellationAlertKey(dep) {
        const serviceID = typeof dep?.serviceID === 'string' ? dep.serviceID.trim() : '';
        if (serviceID) return `service:${serviceID}`;
        const scheduled = typeof dep?.scheduled === 'string' ? dep.scheduled.trim() : '';
        return scheduled ? `scheduled:${scheduled}` : null;
    }

    hasCancellationAlertBeenSent(subscription, dep) {
        const key = this.cancellationAlertKey(dep);
        return Boolean(key && subscription?.cancelledDepartureAlertsSent?.[key]);
    }

    markCancellationAlertSent(subscription, dep, shouldMark = true) {
        if (!shouldMark) return;
        const key = this.cancellationAlertKey(dep);
        if (!key) return;
        subscription.cancelledDepartureAlertsSent = {
            ...(subscription.cancelledDepartureAlertsSent || {}),
            [key]: new Date().toISOString()
        };
    }

    // Returns the current time in Europe/London as minutes since midnight.
    // Used for departure filtering so results are correct regardless of the
    // server's own timezone (e.g. a UTC-based Hetzner host).
    currentLondonMinutes() {
        const parts = Object.fromEntries(
            new Intl.DateTimeFormat('en-GB', {
                timeZone: 'Europe/London',
                hour: '2-digit',
                minute: '2-digit',
                hour12: false
            }).formatToParts(new Date())
                .filter((p) => p.type !== 'literal')
                .map((p) => [p.type, p.value])
        );
        return Number(parts.hour) * 60 + Number(parts.minute);
    }

    // Converts an HH:mm string to minutes since midnight. Returns null if invalid.
    timeStringToMinutes(timeString) {
        if (!timeString) return null;
        const colonIdx = timeString.indexOf(':');
        if (colonIdx === -1) return null;
        const h = Number(timeString.slice(0, colonIdx));
        const m = Number(timeString.slice(colonIdx + 1));
        if (!Number.isFinite(h) || !Number.isFinite(m)) return null;
        return h * 60 + m;
    }

    sortDepartures(departures) {
        // Rail API departure times are always in Europe/London local time.
        // Compare against London minutes-since-midnight to avoid the server's
        // UTC offset causing departed trains to appear upcoming (e.g. BST = UTC+1
        // means a 14:12 BST departure looks like it's at 14:12 UTC = 15:12 BST,
        // i.e. still 1 hour away, so it never gets filtered out).
        const nowMinutes = this.currentLondonMinutes();
        const gracePeriodMinutes = 1;
        const departureOffset = (dep) => {
            const timeStr = this.getTimeString(dep.estimated, dep.scheduled, dep.scheduled || '');
            return minutesUntilDeparture(timeStr, nowMinutes);
        };

        return departures
            .filter((dep) => dep.scheduled || dep.estimated)
            .filter((dep) => {
                const diff = departureOffset(dep);
                return diff !== null && diff > -gracePeriodMinutes;
            })
            .sort((a, b) => {
                const timeA = departureOffset(a) ?? Infinity;
                const timeB = departureOffset(b) ?? Infinity;
                return timeA - timeB;
            });
    }

    selectDeparturesForActivity(allDepartures, sortedUpcoming, preferredServiceId) {
        const normalizedPreferred = typeof preferredServiceId === 'string'
            ? preferredServiceId.trim()
            : '';
        if (!normalizedPreferred) {
            return sortedUpcoming.slice(0, 3);
        }

        // Only pin the preferred service if it has not yet passed the grace period.
        // Searching sortedUpcoming (already filtered) rather than allDepartures
        // ensures a departed preferred train is dropped cleanly at the grace boundary.
        const preferred = sortedUpcoming.find((dep) => dep.serviceID === normalizedPreferred);
        if (!preferred) {
            return sortedUpcoming.slice(0, 3);
        }

        const remainingUpcoming = sortedUpcoming.filter((dep) => dep.serviceID !== normalizedPreferred);
        return [preferred, ...remainingUpcoming].slice(0, 3);
    }

    parseTime(timeString) {
        if (!timeString) return Number.MAX_SAFE_INTEGER;
        const parsed = moment(timeString, 'HH:mm');
        return parsed.isValid() ? parsed.valueOf() : Number.MAX_SAFE_INTEGER;
    }

    buildContentState(subscription, snapshot, appIsActive = false) {
        const primary = snapshot.departures[0] || {};
        const isInProgress = subscription.journeyPhase === 'en_route' || subscription.journeyPhase === 'arrived';
        const isArrived = subscription.journeyPhase === 'arrived';
        const estimated = isArrived
            ? this.ensureString(primary.actualArrivalTime, this.ensureString(primary.arrivalTime, this.getDisplayTime(primary.estimated, primary.scheduled)))
            : isInProgress
            ? this.ensureString(primary.arrivalTime, this.getDisplayTime(primary.estimated, primary.scheduled))
            : this.getDisplayTime(primary.estimated, primary.scheduled);
        const arrivalDelayMinutes = isArrived && Number.isFinite(primary.arrivalDelayMinutes)
            ? Math.max(0, primary.arrivalDelayMinutes)
            : null;
        const delayMinutes = arrivalDelayMinutes ?? this.calculateDelay(primary.scheduled, primary.estimated);

        const platform = this.ensureString(isInProgress ? primary.arrivalPlatform : primary.platform);
        const journeyStationNames = this.journeyStationNames(subscription);
        const destinationTitle = isArrived
            ? journeyStationNames.destination
            : this.ensureString(primaryPlace(primary.destination)?.locationName);
        const routeTitle = this.ensureOptionalString(subscription.displayName);
        const deepLinkFromCRS = this.ensureOptionalString(subscription.deepLinkFromStation) || this.ensureString(subscription.fromStation);
        const deepLinkToCRS = this.ensureOptionalString(subscription.deepLinkToStation) || this.ensureString(subscription.toStation);
        const upcomingDepartures = (isInProgress ? [] : snapshot.departures.slice(1)).map((dep) => ({
            time: this.getDisplayTime(dep.estimated, dep.scheduled),
            arrivalTime: dep.isCancelled ? null : this.ensureOptionalString(dep.arrivalTime),
            delayMinutes: this.calculateDelay(dep.scheduled, dep.estimated),
            isCancelled: Boolean(dep.isCancelled),
            platform: this.ensureString(dep.platform),
            hasFasterLaterService: false // Server doesn't compute this; client handles it
        }));

        return {
            fromCRS: this.ensureString(subscription.fromStation),
            toCRS: this.ensureString(subscription.toStation),
            routeTitle,
            deepLinkFromCRS,
            deepLinkToCRS,
            destinationTitle,
            arrivalLabel: isInProgress
                ? (primary.departedTime ? `Departed ${primary.departedTime}` : null)
                : (primary.isCancelled || !primary.arrivalTime ? null : `Arr ${primary.arrivalTime}`),
            scheduledDeparture: this.ensureOptionalString(primary.scheduled),
            length: Number.isFinite(primary.length) && primary.length > 0 ? primary.length : null,
            platform,
            estimated,
            isCancelled: Boolean(primary.isCancelled),
            statusText: isArrived ? null : this.buildStatusText(primary),
            delayMinutes,
            arrivalDelayMinutes,
            upcomingDepartures,
            lastUpdated: moment(snapshot.fetchedAt).unix(), // Convert to Unix timestamp for iOS Date decoding
            activityID: subscription.activityId, // Include activity ID for iOS ContentState
            revision: subscription.revision || 0,
            appIsActive,
            journeyUpdatesEnabled: Boolean(subscription.journeyUpdatesEnabled),
            scheduleKey: this.ensureOptionalString(subscription.scheduleKey),
            windowStart: this.ensureOptionalString(subscription.windowStart),
            windowEnd: this.ensureOptionalString(subscription.windowEnd),
            journeyPhase: subscription.journeyPhase || 'pending_start',
            journeyStartName: journeyStationNames.start,
            journeyDestinationName: journeyStationNames.destination
        };
    }

    journeyStationNames(subscription) {
        const routeTitle = this.ensureOptionalString(subscription?.displayName) || '';
        const names = routeTitle.split(/\s*(?:→|->)\s*/).filter(Boolean);
        const destination = names.at(-1)?.split(/\s+via\s+/i)[0]?.trim();
        return {
            start: names[0] || this.ensureString(subscription?.deepLinkFromStation || subscription?.fromStation),
            destination: destination || this.ensureString(subscription?.deepLinkToStation || subscription?.toStation)
        };
    }

    ensureOptionalString(value) {
        return typeof value === 'string' && value.length > 0 ? value : null;
    }

    computeRichStatus(dep, serviceDetails) {
        // If we don't have service details, fall back to simple status
        if (!serviceDetails || !serviceDetails.subsequentCallingPoints || !serviceDetails.previousCallingPoints) {
            return this.buildSimpleStatusText(dep);
        }

        try {
            // Get all stations
            const allStations = this.getAllStations(serviceDetails);
            if (allStations.length === 0) {
                return this.buildSimpleStatusText(dep);
            }

            // Check if all stations are cancelled
            if (allStations.every(s => this.isCancelledAtStation(s))) {
                return this.buildSimpleStatusText(dep);
            }

            const now = new Date();

            // Pre-departure guard: if no station has an actual time yet, the service hasn't started
            const anyActual = allStations.some(s => s.at && s.at !== 'Cancelled');
            if (!anyActual) {
                const first = allStations.find(s => !this.isCancelledAtStation(s));
                if (first) {
                    const d = this.calculateStationDelay(first);
                    if (first.et?.toLowerCase() === 'delayed') {
                        return `Departure from ${first.locationName} delayed for an unknown period of time`;
                    }
                    const phrasing = d === 0 ? 'on time' : `${d} minute${d === 1 ? '' : 's'} late`;
                    return `Scheduled to depart ${first.locationName} ${phrasing}`;
                }
            }

            // Time-based position detection (matching iOS logic)
            // approachWindow: within 1 min of next station -> approaching
            // atGraceWindow: remain "at <prev>" for 30s after its estimated departure
            const approachWindowMs = 60 * 1000;
            const atGraceWindowMs = 30 * 1000;

            for (let i = 0; i < allStations.length; i++) {
                const s = allStations[i];
                if (this.isCancelledAtStation(s)) continue;

                // If we have actual arrival/departure from this station, it's been passed - continue forward
                if (s.at && s.at !== 'Cancelled') continue;

                const stTime = this.effectiveTime(s);
                if (!stTime) continue;

                // Approach threshold for next station
                const arriveTime = new Date(stTime.getTime() - approachWindowMs);

                if (now < arriveTime) {
                    // Between previous station and this one (or before first)
                    if (i === 0) {
                        const d = this.calculateStationDelay(s);
                        if (s.et?.toLowerCase() === 'delayed') {
                            return `Departure from ${s.locationName} delayed for an unknown period of time`;
                        }
                        const lateText = d === 0 ? 'on time' : `${d} minute${d === 1 ? '' : 's'} late`;
                        return `Scheduled to depart ${s.locationName} ${lateText}`;
                    }

                    // Find previous non-cancelled station
                    let prevIdx = i - 1;
                    while (prevIdx >= 0 && this.isCancelledAtStation(allStations[prevIdx])) {
                        prevIdx--;
                    }
                    if (prevIdx >= 0) {
                        const prev = allStations[prevIdx];
                        const d = Math.max(this.calculateStationDelay(prev), this.calculateStationDelay(s));
                        const lateText = d >= 240 ? 'delayed for an unknown period of time' : (d === 0 ? 'on time' : `${d} minute${d === 1 ? '' : 's'} late`);
                        return `Currently ${lateText}, between ${prev.locationName} and ${s.locationName}`;
                    }
                } else if (now < stTime) {
                    // Within the approach window for this next station
                    // Show "at <prev>" if we've arrived there and are within grace period
                    const dNext = this.calculateStationDelay(s);
                    const lateNext = dNext === 0 ? 'on time' : `${dNext} minute${dNext === 1 ? '' : 's'} late`;

                    if (i > 0) {
                        let prevIdx = i - 1;
                        while (prevIdx >= 0 && this.isCancelledAtStation(allStations[prevIdx])) {
                            prevIdx--;
                        }
                        if (prevIdx >= 0) {
                            const prev = allStations[prevIdx];
                            if (prev.at && prev.at !== 'Cancelled') {
                                const prevET = this.effectiveTime(prev);
                                if (prevET && now <= new Date(prevET.getTime() + atGraceWindowMs)) {
                                    const dPrev = this.calculateStationDelay(prev);
                                    const latePrev = dPrev === 0 ? 'on time' : `${dPrev} minute${dPrev === 1 ? '' : 's'} late`;
                                    return `Currently ${latePrev}, at ${prev.locationName}`;
                                }
                            }
                        }
                    }
                    return `Currently ${lateNext}, at or near ${s.locationName}`;
                }
            }

            // Check for delay after the last station with an actual time
            let lastActualIdx = -1;
            for (let i = 0; i < allStations.length; i++) {
                if (allStations[i].at && allStations[i].at !== 'Cancelled') {
                    lastActualIdx = i;
                }
            }
            if (lastActualIdx >= 0 && lastActualIdx < allStations.length - 1) {
                let nextIdx = lastActualIdx + 1;
                while (nextIdx < allStations.length && this.isCancelledAtStation(allStations[nextIdx])) {
                    nextIdx++;
                }
                if (nextIdx < allStations.length) {
                    const next = allStations[nextIdx];
                    if (next.et?.toLowerCase() === 'delayed' || !next.at) {
                        const prev = allStations[lastActualIdx];
                        const d = Math.max(this.calculateStationDelay(prev), this.calculateStationDelay(next));
                        const txt = d >= 240 ? 'delayed for an unknown period of time' : (d === 0 ? 'on time' : `${d} minute${d === 1 ? '' : 's'} late`);
                        return `Currently ${txt}, between ${prev.locationName} and ${next.locationName}`;
                    }
                }
            }

            // After final station
            const last = allStations[allStations.length - 1];
            if (last) {
                const d = this.calculateStationDelay(last);
                const lateText = d === 0 ? 'on time' : `${d} minute${d === 1 ? '' : 's'} late`;
                return `Arrived ${lateText} at ${last.locationName}`;
            }

            // Fallback to simple status
            return this.buildSimpleStatusText(dep);
        } catch (error) {
            console.warn(`Error computing rich status: ${error?.message || error}`);
            return this.buildSimpleStatusText(dep);
        }
    }

    isCancelledAtStation(station) {
        return station.isCancelled === true || station.at === 'Cancelled' || station.et === 'Cancelled';
    }

    effectiveTime(station) {
        // Return the estimated time if available and not "On time"/"Cancelled", otherwise scheduled time
        const parseTime = (t) => {
            if (!t || t === 'On time' || t === 'Cancelled') return null;
            const parts = t.split(':');
            if (parts.length !== 2) return null;
            const hour = parseInt(parts[0], 10);
            const minute = parseInt(parts[1], 10);
            if (isNaN(hour) || isNaN(minute)) return null;
            const now = new Date();
            const result = new Date(now.getFullYear(), now.getMonth(), now.getDate(), hour, minute, 0, 0);
            return result;
        };

        if (station.et && station.et !== 'On time' && station.et !== 'Cancelled') {
            return parseTime(station.et);
        }
        return parseTime(station.st);
    }

    getAllStations(serviceDetails) {
        const stations = [];

        // Add previous calling points (already passed)
        if (serviceDetails.previousCallingPoints && serviceDetails.previousCallingPoints.length > 0) {
            const prev = serviceDetails.previousCallingPoints[0].callingPoint || [];
            stations.push(...prev);
        }

        // Add current location
        if (serviceDetails.locationName) {
            stations.push({
                locationName: serviceDetails.locationName,
                crs: serviceDetails.crs,
                st: serviceDetails.std || serviceDetails.sta,
                et: serviceDetails.etd || serviceDetails.eta,
                at: serviceDetails.atd || serviceDetails.ata,
                platform: serviceDetails.platform
            });
        }

        // Add subsequent calling points (upcoming)
        if (serviceDetails.subsequentCallingPoints && serviceDetails.subsequentCallingPoints.length > 0) {
            const next = serviceDetails.subsequentCallingPoints[0].callingPoint || [];
            stations.push(...next);
        }

        return stations;
    }

    arrivalTimeForDestination(serviceDetails, toStation) {
        if (!serviceDetails || !toStation) return null;

        return this.stationDisplayTime(this.arrivalStationForDestination(serviceDetails, toStation));
    }

    actualArrivalTimeForDestination(serviceDetails, toStation) {
        const station = this.arrivalStationForDestination(serviceDetails, toStation);
        if (!station?.at || station.at === 'Cancelled') return null;
        return station.at === 'On time' ? station.st : station.at;
    }

    confirmedArrivalDelayForDestination(serviceDetails, toStation) {
        const station = this.arrivalStationForDestination(serviceDetails, toStation);
        if (!station?.at || station.at === 'Cancelled') return null;
        return this.calculateStationDelay(station);
    }

    arrivalStationForDestination(serviceDetails, toStation) {
        if (!serviceDetails || !toStation) return null;
        const targetCRS = String(toStation).trim().toUpperCase();
        if (String(serviceDetails.crs || '').trim().toUpperCase() === targetCRS) {
            return {
                crs: serviceDetails.crs,
                st: serviceDetails.sta || serviceDetails.std,
                et: serviceDetails.eta || serviceDetails.etd,
                at: serviceDetails.ata || serviceDetails.atd,
                platform: serviceDetails.platform
            };
        }
        return this.getAllStations(serviceDetails).find(
            (station) => String(station.crs || '').trim().toUpperCase() === targetCRS
        ) || null;
    }

    platformForStation(serviceDetails, stationCRS) {
        if (!serviceDetails || !stationCRS) return null;
        const targetCRS = String(stationCRS).trim().toUpperCase();
        const match = this.getAllStations(serviceDetails).find(
            (station) => String(station.crs || '').trim().toUpperCase() === targetCRS
        );
        if (match?.platform) return match.platform;
        if (String(serviceDetails.crs || '').trim().toUpperCase() === targetCRS) {
            return serviceDetails.platform || null;
        }
        return null;
    }

    departureTimeForStation(serviceDetails, stationCRS, scheduledFallback = null) {
        if (!serviceDetails || !stationCRS) return scheduledFallback;
        const targetCRS = String(stationCRS).trim().toUpperCase();
        const match = this.getAllStations(serviceDetails).find(
            (station) => String(station.crs || '').trim().toUpperCase() === targetCRS
        );
        if (match?.at && match.at !== 'Cancelled') {
            return match.at === 'On time' ? (match.st || scheduledFallback) : match.at;
        }
        if (String(serviceDetails.crs || '').trim().toUpperCase() === targetCRS
            && serviceDetails.atd && serviceDetails.atd !== 'Cancelled') {
            return serviceDetails.atd === 'On time'
                ? (serviceDetails.std || scheduledFallback)
                : serviceDetails.atd;
        }
        return match?.st || serviceDetails.std || scheduledFallback;
    }

    stationDisplayTime(station) {
        if (!station) return null;
        if (station.at && station.at !== 'Cancelled') {
            return station.at === 'On time' ? station.st : station.at;
        }
        if (station.et && station.et !== 'Cancelled') {
            return station.et === 'On time' ? station.st : station.et;
        }
        return station.st || null;
    }

    calculateStationDelay(station) {
        const scheduled = station.st;

        // Check actual arrival time first (for stations already passed)
        if (station.at && station.at !== 'Cancelled') {
            if (station.at === 'On time') return 0;
            const sched = moment(scheduled, 'HH:mm');
            const actual = moment(station.at, 'HH:mm');
            if (sched.isValid() && actual.isValid()) {
                return Math.max(0, actual.diff(sched, 'minutes'));
            }
        }

        // Fall back to estimated time
        const estimated = station.et;
        if (!scheduled || !estimated || estimated === 'On time') return 0;
        if (estimated.toLowerCase() === 'delayed') return 240; // Unknown delay

        const sched = moment(scheduled, 'HH:mm');
        const est = moment(estimated, 'HH:mm');

        if (!sched.isValid() || !est.isValid()) return 0;
        return Math.max(0, est.diff(sched, 'minutes'));
    }

    parseStationTime(timeStr) {
        if (!timeStr || timeStr === 'On time' || timeStr.toLowerCase() === 'delayed') return null;
        const parsed = moment(timeStr, 'HH:mm');
        return parsed.isValid() ? parsed.toDate() : null;
    }

    buildSimpleStatusText(dep) {
        if (!dep) return '';
        if (dep.isCancelled) return 'Cancelled';
        const delay = this.calculateDelay(dep.scheduled, dep.estimated);
        if (delay > 0) return `Delayed by ${delay} min`;
        if (dep.estimated === 'On time') return 'On time';
        return this.getTimeString(dep.estimated, dep.scheduled);
    }

    buildStatusText(dep) {
        // Use the precomputed statusText from the snapshot if available
        if (dep.statusText) return dep.statusText;
        // Fallback to simple status
        return this.buildSimpleStatusText(dep);
    }

    calculateDelay(scheduled, estimated) {
        if (!scheduled || !estimated || estimated === 'On time') return 0;
        if (estimated.trim().toLowerCase() === 'delayed') return 240;
        const sched = moment(scheduled, 'HH:mm');
        const est = moment(estimated, 'HH:mm');
        if (!sched.isValid() || !est.isValid()) return 0;
        return Math.max(0, est.diff(sched, 'minutes'));
    }

    getTimeString(estimated, scheduled, fallback = '') {
        const estValid = estimated && moment(estimated, 'HH:mm', true).isValid();
        if (estValid) return estimated;
        const schedValid = scheduled && moment(scheduled, 'HH:mm', true).isValid();
        if (schedValid) return scheduled;
        return fallback;
    }

    getDisplayTime(estimated, scheduled, fallback = '') {
        if (typeof estimated === 'string' && estimated.trim().toLowerCase() === 'delayed') {
            return 'Delayed';
        }
        return this.getTimeString(estimated, scheduled, fallback);
    }

    ensureString(value, fallback = '') {
        if (typeof value === 'string' && value.length > 0) return value;
        if (typeof value === 'number') return String(value);
        return fallback;
    }

    normalizePlatform(value) {
        if (typeof value !== 'string') return null;
        const trimmed = value.trim();
        return trimmed.length > 0 ? trimmed : null;
    }

    applyLastKnownPlatforms(snapshot, previousSnapshot) {
        if (!snapshot || !Array.isArray(snapshot.departures) || snapshot.departures.length === 0) {
            return snapshot;
        }

        const previousPlatforms = new Map(
            (Array.isArray(previousSnapshot?.departures) ? previousSnapshot.departures : [])
                .map((dep) => [dep?.serviceID, this.normalizePlatform(dep?.platform)])
                .filter(([serviceID, platform]) => serviceID && platform)
        );

        return {
            ...snapshot,
            departures: snapshot.departures.map((dep) => {
                const currentPlatform = this.normalizePlatform(dep?.platform);
                if (currentPlatform || !dep?.serviceID) {
                    return currentPlatform ? { ...dep, platform: currentPlatform } : dep;
                }

                const previousPlatform = previousPlatforms.get(dep.serviceID);
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

    getSubscription(deviceId, activityId, { fallbackDeviceIds = [] } = {}) {
        const deviceIds = this.uniqueDeviceIds([deviceId, ...fallbackDeviceIds]);
        for (const candidate of deviceIds) {
            const subscription = this.subscriptions.get(this.buildKey(candidate, activityId));
            if (subscription) {
                return subscription;
            }
        }
        return null;
    }

    getLatestSubscriptionForDevice(deviceId) {
        const normalizedDeviceId = typeof deviceId === 'string' ? deviceId.trim() : '';
        if (!normalizedDeviceId) return null;
        const matches = Array.from(this.subscriptions.values())
            .filter((subscription) => subscription?.deviceId === normalizedDeviceId)
            .sort((left, right) => {
                const leftTime = Date.parse(left?.tokenUpdatedAt || left?.createdAt || '') || 0;
                const rightTime = Date.parse(right?.tokenUpdatedAt || right?.createdAt || '') || 0;
                return rightTime - leftTime;
            });
        return matches[0] || null;
    }

    async deleteMatchingLiveSessions(subscription, { fallbackDeviceIds = [] } = {}) {
        if (!subscription?.deviceId || !subscription?.fromStation || !subscription?.toStation) {
            return 0;
        }
        return notificationSubscriptionManager.deleteLiveSessionsForLeg({
            deviceId: subscription.deviceId,
            from: subscription.fromStation,
            to: subscription.toStation,
            fallbackDeviceIds
        });
    }

    unregisterSubscription(deviceId, activityId, {
        fallbackDeviceIds = [],
        preserveNotificationLiveSession = false
    } = {}) {
        const subscription = this.getSubscription(deviceId, activityId, { fallbackDeviceIds });
        if (!subscription) {
            this.log(`[live-activity] unregister_not_found ${deviceId}/${activityId}`);
            return null;
        }
        const key = this.buildKey(subscription.deviceId, subscription.activityId);
        this.clearEndTimer(subscription);
        this.subscriptions.delete(key);
        this.deleteSubscriptionFromMongo(subscription).catch((error) => {
            console.error(`[live-activity] Failed to delete unregistered session ${key}: ${error?.message || error}`);
        });
        this.log(`[live-activity] unregistered ${deviceId}/${activityId}`);
        if (preserveNotificationLiveSession) {
            this.log(`[live-activity] preserved_notification_live_session ${deviceId}/${activityId}`);
        } else {
            this.deleteMatchingLiveSessions(subscription, { fallbackDeviceIds }).catch((error) => {
                console.error(`[live-activity] Failed to delete matching live sessions for ${key}: ${error?.message || error}`);
            });
        }
        return subscription;
    }

    async setJourneyUpdatesEnabled(deviceId, activityId, enabled, { fallbackDeviceIds = [], forceRefresh = true } = {}) {
        const subscription = this.getSubscription(deviceId, activityId, { fallbackDeviceIds });
        if (!subscription) return null;
        subscription.journeyUpdatesEnabled = Boolean(enabled);
        if (forceRefresh) {
            await this.pollSubscription(subscription, { force: true });
        }
        return subscription;
    }

    async handleDeviceCheckIn(deviceId, { forceRefresh = true, fallbackDeviceIds = [], canonicalDeviceId = null } = {}) {
        const requestedDeviceIds = this.uniqueDeviceIds([deviceId, ...fallbackDeviceIds]);
        const normalizedCanonicalDeviceId = typeof canonicalDeviceId === 'string' ? canonicalDeviceId.trim() : '';
        if (requestedDeviceIds.length === 0 && !normalizedCanonicalDeviceId) {
            return {
                updated: 0,
                refreshed: 0,
                subscriptions: 0,
                migrated: 0
            };
        }

        let subs = this.findSubscriptionsByDeviceIds(
            normalizedCanonicalDeviceId
                ? [normalizedCanonicalDeviceId, ...requestedDeviceIds]
                : requestedDeviceIds
        );

        let migrated = 0;
        if (normalizedCanonicalDeviceId) {
            for (const sub of subs) {
                if (this.migrateSubscriptionDeviceId(sub, normalizedCanonicalDeviceId)) {
                    migrated += 1;
                }
            }
            subs = this.findSubscriptionsByDeviceIds([normalizedCanonicalDeviceId, ...requestedDeviceIds]);
        }

        const nowIso = new Date().toISOString();
        for (const sub of subs) {
            sub.tokenUpdatedAt = nowIso;
            this.saveSubscriptionToMongo(sub).catch((error) => {
                const key = this.buildKey(sub.deviceId, sub.activityId);
                console.error(`[live-activity] Failed to persist checkin state for ${key}: ${error?.message || error}`);
            });
        }

        let refreshed = 0;
        if (forceRefresh && subs.length > 0) {
            const results = await Promise.all(subs.map(async (sub) => {
                try {
                    const result = await this.pollSubscription(sub, { force: true });
                    return result?.sent ? 1 : 0;
                } catch (error) {
                    const key = this.buildKey(sub.deviceId, sub.activityId);
                    console.error(`[live-activity] checkin force refresh failed for ${key}: ${error?.message || error}`);
                    return 0;
                }
            }));
            refreshed = results.reduce((sum, value) => sum + value, 0);
        }

        return {
            updated: subs.length,
            refreshed,
            subscriptions: subs.length,
            migrated
        };
    }

    async tidyDuplicateSessions() {
        if (this.subscriptions.size <= DEFAULT_MAX_ACTIVE_PER_DEVICE) {
            return;
        }
        const byDevice = new Map();
        for (const sub of this.subscriptions.values()) {
            const deviceId = sub.deviceId || '';
            if (!byDevice.has(deviceId)) {
                byDevice.set(deviceId, []);
            }
            byDevice.get(deviceId).push(sub);
        }

        const jobs = [];
        for (const [deviceId, subs] of byDevice.entries()) {
            if (!deviceId || subs.length <= DEFAULT_MAX_ACTIVE_PER_DEVICE) continue;
            jobs.push(this.tidyDuplicateSessionsForDevice(deviceId));
        }
        if (jobs.length > 0) {
            await Promise.all(jobs);
        }
    }

    async tidyDuplicateSessionsForDevice(deviceId, preferredActivityId = null) {
        const evicted = this.evictDuplicateSessionsForDevice(deviceId, preferredActivityId);
        if (evicted.length === 0) {
            const kept = preferredActivityId || (
                Array.from(this.subscriptions.values()).find((sub) => sub.deviceId === deviceId)?.activityId ?? null
            );
            return {
                kept,
                removed: 0
            };
        }

        await Promise.all(evicted.map((sub) => this.sendEndPushForEvictedSubscription(sub, 'duplicate_session_cleanup')));
        const kept = Array.from(this.subscriptions.values()).find((sub) => sub.deviceId === deviceId)?.activityId ?? null;
        return {
            kept,
            removed: evicted.length
        };
    }

    evictDuplicateSessionsForDevice(deviceId, preferredActivityId = null) {
        const subs = Array.from(this.subscriptions.values())
            .filter((sub) => sub.deviceId === deviceId);
        if (subs.length <= DEFAULT_MAX_ACTIVE_PER_DEVICE) {
            return [];
        }

        const sorted = subs.sort((a, b) => this.subscriptionFreshnessMs(b) - this.subscriptionFreshnessMs(a));
        const preferred = preferredActivityId
            ? sorted.find((sub) => sub.activityId === preferredActivityId)
            : null;
        const keep = preferred || sorted[0];
        const remove = sorted.filter((sub) => sub.activityId !== keep.activityId);

        for (const sub of remove) {
            this.clearEndTimer(sub);
            this.subscriptions.delete(this.buildKey(sub.deviceId, sub.activityId));
            this.deleteSubscriptionFromMongo(sub).catch((error) => {
                const key = this.buildKey(sub.deviceId, sub.activityId);
                console.error(`[live-activity] Failed to delete evicted session ${key}: ${error?.message || error}`);
            });
            this.log(`[live-activity] duplicate_evict ${sub.deviceId}/${sub.activityId} keep=${keep.activityId}`);
        }
        return remove;
    }

    subscriptionFreshnessMs(subscription) {
        const tokenUpdatedAtMs = new Date(subscription?.tokenUpdatedAt || 0).getTime();
        if (Number.isFinite(tokenUpdatedAtMs) && tokenUpdatedAtMs > 0) {
            return tokenUpdatedAtMs;
        }
        const createdAtMs = new Date(subscription?.createdAt || 0).getTime();
        if (Number.isFinite(createdAtMs) && createdAtMs > 0) {
            return createdAtMs;
        }
        return 0;
    }

    async cleanupSubscription(subscription, reason = 'cleanup') {
        const key = this.buildKey(subscription.deviceId, subscription.activityId);
        if (!this.subscriptions.has(key)) {
            return;
        }
        this.log(`[live-activity] cleanup_start ${key} reason=${reason}`);

        try {
            await this.sendEndUpdate(subscription, { reason, trigger: 'cleanup' });
            return;
        } catch (error) {
            console.error(`[live-activity] cleanup end push failed for ${key}: ${error?.message || error}`);
        }

        this.clearEndTimer(subscription);
        this.subscriptions.delete(key);
        await this.deleteSubscriptionFromMongo(subscription);
        this.log(`[live-activity] cleanup_removed ${key} reason=${reason}`);
    }

    async sendEndPushForEvictedSubscription(subscription, reason = 'evicted') {
        try {
            await this.sendEndUpdate(subscription, { reason, trigger: 'eviction' });
        } catch (error) {
            const key = this.buildKey(subscription.deviceId, subscription.activityId);
            console.error(`[live-activity] end push failed for evicted ${key} (${reason}): ${error?.message || error}`);
        }
    }

    snapshotsEqual(a, b) {
        if (!a || !b) return false;
        return JSON.stringify(a.departures) === JSON.stringify(b.departures);
    }

    shouldRefreshStaleDate(subscription) {
        if (!subscription.lastPushAt) {
            return true; // No previous push, should update
        }
        const lastPushTime = new Date(subscription.lastPushAt).getTime();
        const now = Date.now();
        const elapsedSeconds = (now - lastPushTime) / 1000;

        // Refresh stale-date periodically to keep iOS from marking the activity as stale
        // This sends the same data with updated timestamp and stale-date
        // Note: iOS has a Live Activity update budget (~8 pushes/hour when locked)
        // We set this to 4 minutes (240s) to stay well within the budget while keeping the activity fresh
        return elapsedSeconds >= DEFAULT_STALE_DATE_REFRESH_SECONDS;
    }

    shouldShowAppActive(subscription) {
        const metricsLastSeen = getDeviceLastSeen(subscription?.deviceId);
        const fallbackLastSeen = new Date(subscription?.tokenUpdatedAt || 0).getTime();
        const lastSeen = Number.isFinite(metricsLastSeen)
            ? metricsLastSeen
            : (Number.isFinite(fallbackLastSeen) && fallbackLastSeen > 0 ? fallbackLastSeen : null);
        if (!lastSeen) return false;
        const ageMs = Date.now() - lastSeen;
        if (ageMs < 0) return false;
        // Active = checked in recently (within the threshold)
        return ageMs <= (APP_CHECKIN_WARNING_AFTER_SECONDS * 1000);
    }

    async handleJourneyPhase(deviceId, {
        fromStation = null,
        toStation = null,
        phase,
        preferredServiceId = null,
        fallbackDeviceIds = []
    } = {}) {
        const validPhases = new Set(['pending_start', 'at_start', 'en_route', 'arrived']);
        if (!validPhases.has(phase)) return { updated: 0 };

        const candidateDeviceIds = this.uniqueDeviceIds([deviceId, ...fallbackDeviceIds]);
        const fromCode = typeof fromStation === 'string' ? fromStation.trim().toUpperCase() : null;
        const toCode = typeof toStation === 'string' ? toStation.trim().toUpperCase() : null;
        const matchedServiceId = typeof preferredServiceId === 'string'
            ? preferredServiceId.trim()
            : '';
        const subscriptions = this.findSubscriptionsByDeviceIds(candidateDeviceIds).filter((subscription) => {
            const subscriptionFrom = String(
                subscription.deepLinkFromStation || subscription.fromStation || ''
            ).toUpperCase();
            const subscriptionTo = String(
                subscription.deepLinkToStation || subscription.toStation || ''
            ).toUpperCase();
            return (!fromCode || subscriptionFrom === fromCode)
                && (!toCode || subscriptionTo === toCode);
        });

        const results = await Promise.all(subscriptions.map(async (subscription) => {
            subscription.journeyPhase = phase;
            subscription.autoEndOnDeparture = false;
            if (phase === 'en_route' || phase === 'arrived') {
                const previousServiceId = subscription.preferredServiceId;
                subscription.preferredServiceId = matchedServiceId
                    || previousServiceId
                    || subscription.lastSnapshot?.departures?.[0]?.serviceID
                    || null;
                if (matchedServiceId && matchedServiceId !== previousServiceId) {
                    subscription.preferredDepartureSnapshot = subscription.lastSnapshot?.departures?.find(
                        (departure) => departure.serviceID === matchedServiceId
                    ) || null;
                }
            }
            await this.saveSubscriptionToMongo(subscription);
            const result = await this.pollSubscription(subscription, { force: true });
            return result?.sent ? 1 : 0;
        }));

        return {
            updated: subscriptions.length,
            pushed: results.reduce((sum, value) => sum + value, 0)
        };
    }

    /**
     * Called when the iOS app detects the user has arrived at a departure station.
     * Retained for older clients; current clients use the journey-status endpoint.
     */
    async handleArrival(deviceId, { fromStation = null, toStation = null, fallbackDeviceIds = [] } = {}) {
        return this.handleJourneyPhase(deviceId, {
            fromStation,
            toStation,
            phase: 'at_start',
            fallbackDeviceIds
        });
    }

    /**
     * Called when the iOS app detects the user has left the departure station geofence.
     * Retained for older clients; current clients use the journey-status endpoint.
     */
    async handleDeparture(deviceId, { fromStation = null, toStation = null, fallbackDeviceIds = [] } = {}) {
        return this.handleJourneyPhase(deviceId, {
            fromStation,
            toStation,
            phase: 'en_route',
            fallbackDeviceIds
        });
    }

    maskToken(token) {
        if (!token || typeof token !== 'string') return 'null';
        if (token.length <= 16) return token.slice(0, 6) + '***';
        return token.slice(0, 8) + '...' + token.slice(-8);
    }

    buildKey(deviceId, activityId) {
        return `${deviceId}::${activityId}`;
    }

    async saveSubscriptionToMongo(subscription) {
        if (!subscription?.deviceId || !subscription?.activityId) return;
        if (this.deletedDeviceIds.has(subscription.deviceId)) return;
        const collection = await getMongoCollection(COLLECTIONS.liveActivitySessions);
        if (this.deletedDeviceIds.has(subscription.deviceId)) return;
        const key = this.buildKey(subscription.deviceId, subscription.activityId);
        const record = this.serializeSubscription(subscription);
        await collection.updateOne(
            { _id: key },
            { $set: { _id: key, ...record } },
            { upsert: true }
        );
        if (this.deletedDeviceIds.has(subscription.deviceId)) {
            await collection.deleteOne({ _id: key });
        }
    }

    async deleteSubscriptionFromMongo(subscription) {
        if (!subscription?.deviceId || !subscription?.activityId) return;
        const collection = await getMongoCollection(COLLECTIONS.liveActivitySessions);
        await collection.deleteOne({
            _id: this.buildKey(subscription.deviceId, subscription.activityId)
        });
    }

    serializeSubscription(subscription) {
        const {
            endTimer,
            isPollInProgress,
            pendingForcedPoll,
            expiresAt,
            ...record
        } = subscription;
        const endAtMs = Date.parse(record.endAt || '');
        return {
            ...record,
            expiresAt: Number.isFinite(endAtMs)
                ? new Date(endAtMs)
                : new Date(Date.now() + this.getEndAfterMs())
        };
    }

    uniqueDeviceIds(deviceIds = []) {
        return Array.from(new Set(
            deviceIds
                .map((value) => typeof value === 'string' ? value.trim() : '')
                .filter(Boolean)
        ));
    }

    findSubscriptionsByDeviceIds(deviceIds = []) {
        const normalized = this.uniqueDeviceIds(deviceIds);
        if (normalized.length === 0) {
            return [];
        }
        const candidates = new Set(normalized);
        return Array.from(this.subscriptions.values()).filter((sub) => candidates.has(sub.deviceId));
    }

    migrateSubscriptionDeviceId(subscription, nextDeviceId) {
        const normalizedNextDeviceId = typeof nextDeviceId === 'string' ? nextDeviceId.trim() : '';
        if (!subscription || !normalizedNextDeviceId || subscription.deviceId === normalizedNextDeviceId) {
            return false;
        }

        const currentKey = this.buildKey(subscription.deviceId, subscription.activityId);
        const nextKey = this.buildKey(normalizedNextDeviceId, subscription.activityId);
        const existing = this.subscriptions.get(nextKey);
        if (existing && existing !== subscription) {
            this.log(`[live-activity] device_id_migrate_collision ${subscription.deviceId}->${normalizedNextDeviceId}/${subscription.activityId}`);
            return false;
        }

        this.subscriptions.delete(currentKey);
        subscription.deviceId = normalizedNextDeviceId;
        this.subscriptions.set(nextKey, subscription);
        this.deleteSubscriptionFromMongo({ deviceId: currentKey.split('::')[0], activityId: subscription.activityId }).catch((error) => {
            console.error(`[live-activity] Failed to delete migrated session ${currentKey}: ${error?.message || error}`);
        });
        this.saveSubscriptionToMongo(subscription).catch((error) => {
            console.error(`[live-activity] Failed to persist migrated session ${nextKey}: ${error?.message || error}`);
        });
        this.log(`[live-activity] device_id_migrated ${currentKey} -> ${nextKey}`);
        return true;
    }

    listSubscriptions() {
        return Array.from(this.subscriptions.values()).map((sub) => ({
            lastAppCheckInAt: (() => {
                const metricsLastSeen = getDeviceLastSeen(sub.deviceId);
                if (Number.isFinite(metricsLastSeen)) {
                    return new Date(metricsLastSeen).toISOString();
                }
                return sub.tokenUpdatedAt || null;
            })(),
            deviceId: sub.deviceId,
            activityId: sub.activityId,
            fromStation: sub.fromStation,
            toStation: sub.toStation,
            preferredServiceId: sub.preferredServiceId || null,
            muteOnArrival: sub.muteOnArrival,
            muteDelayMinutes: sub.muteDelayMinutes ?? 5,
            autoEndOnArrival: Boolean(sub.autoEndOnArrival),
            autoEndOnDeparture: Boolean(sub.autoEndOnDeparture),
            journeyPhase: sub.journeyPhase || 'pending_start',
            journeyUpdatesEnabled: Boolean(sub.journeyUpdatesEnabled),
            scheduleKey: sub.scheduleKey || null,
            windowStart: sub.windowStart || null,
            windowEnd: sub.windowEnd || null,
            useSandbox: sub.useSandbox,
            createdAt: sub.createdAt,
            tokenUpdatedAt: sub.tokenUpdatedAt,
            lastPushAt: sub.lastPushAt,
            endAt: sub.endAt,
            revision: sub.revision || 0,
            appIsActive: Boolean(sub.appIsActive)
        }));
    }

    getSubscriptionCount() {
        return this.subscriptions.size;
    }

    purgeDeviceRuntimeState(deviceId) {
        const normalizedDeviceId = typeof deviceId === 'string' ? deviceId.trim() : '';
        if (!normalizedDeviceId) return 0;

        this.deletedDeviceIds.add(normalizedDeviceId);

        let removed = 0;
        for (const [key, subscription] of this.subscriptions.entries()) {
            if (subscription?.deviceId !== normalizedDeviceId) continue;
            this.clearEndTimer(subscription);
            this.subscriptions.delete(key);
            removed += 1;
        }
        return removed;
    }

    isLoggingEnabled() {
        const flag = process.env.DEBUG_CONSOLE_LOGGING_APNS;
        return typeof flag === 'string' && flag.toLowerCase() === 'true';
    }

    log(message, data) {
        if (!this.isLoggingEnabled()) return;
        if (data) {
            console.log(message, JSON.stringify(data));
        } else {
            console.log(message);
        }
    }

    getEndAfterMs() {
        const fromEnv = Number(process.env.LIVE_ACTIVITY_END_AFTER_SECONDS);
        if (Number.isFinite(fromEnv) && fromEnv > 0) {
            return fromEnv * 1000;
        }
        return DEFAULT_END_AFTER_SECONDS * 1000;
    }
}

export const liveActivityManager = new LiveActivityManager();

function stripMongoId(value) {
    if (!value || typeof value !== 'object') return value;
    const { _id, ...rest } = value;
    return rest;
}
