import moment from 'moment';
import { getTrainTimes } from './realtime-trains-api.js';
import { LiveActivityPushClient } from './live-activity-push-client.js';
import { getServiceDetails } from './service-details.js';
import { recordNotificationEvent } from './admin-data-store.js';
import { getDeviceLastSeen } from './metrics.js';

const DEFAULT_POLL_INTERVAL_SECONDS = Number(process.env.LIVE_ACTIVITY_POLL_INTERVAL_SECONDS || '20');
const DEFAULT_END_AFTER_SECONDS = Number(process.env.LIVE_ACTIVITY_END_AFTER_SECONDS || '7200'); // default 2 hours
const DEFAULT_STALE_DATE_REFRESH_SECONDS = Number(process.env.LIVE_ACTIVITY_STALE_DATE_REFRESH_SECONDS || '240'); // refresh stale-date every 4 minutes
const APP_CHECKIN_WARNING_AFTER_SECONDS = Number(process.env.LIVE_ACTIVITY_APP_CHECKIN_WARNING_AFTER_SECONDS || '120');
const DEFAULT_MAX_ACTIVE_PER_DEVICE = Number(process.env.LIVE_ACTIVITY_MAX_ACTIVE_PER_DEVICE || '1');

class LiveActivityManager {
    constructor() {
        this.subscriptions = new Map();
        this.pushClient = new LiveActivityPushClient();
        this.pollIntervalMs = DEFAULT_POLL_INTERVAL_SECONDS * 1000;
        this.isPolling = false;
        this.startPollingLoop();
    }

    startPollingLoop() {
        setInterval(() => {
            this.pollAll().catch((error) => {
                console.error(`Live activity poll failed: ${error?.message || error}`);
            });
        }, this.pollIntervalMs).unref?.();
    }

    registerSubscription({
        deviceId,
        activityId,
        pushToken,
        fromStation,
        toStation,
        preferredServiceId,
        useSandbox,
        muteOnArrival,
        muteDelayMinutes,
        autoEndOnArrival,
        scheduleKey,
        windowStart,
        windowEnd
    }) {
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
            preferredServiceId: (typeof preferredServiceId === 'string' && preferredServiceId.length > 0)
                ? preferredServiceId
                : (existing?.preferredServiceId || null),
            useSandbox: Boolean(useSandbox), // Defaults to false (production) if not provided
            muteOnArrival: muteOnArrival !== undefined ? Boolean(muteOnArrival) : (existing?.muteOnArrival ?? true),
            muteDelayMinutes: Number.isFinite(Number(muteDelayMinutes)) && Number(muteDelayMinutes) >= 0
                ? Math.min(10, Math.max(1, Math.round(Number(muteDelayMinutes))))
                : (existing?.muteDelayMinutes ?? 5),
            autoEndOnArrival: autoEndOnArrival !== undefined ? Boolean(autoEndOnArrival) : (existing?.autoEndOnArrival ?? false),
            createdAt: existing?.createdAt || new Date().toISOString(),
            lastSnapshot: existing?.lastSnapshot || null,
            lastPushAt: existing?.lastPushAt || null,
            revision: existing?.revision || 0,
            tokenUpdatedAt: new Date().toISOString(),
            appIsActive: existing?.appIsActive ?? false,
            scheduleKey: scheduleKey || existing?.scheduleKey || null,
            windowStart: windowStart || existing?.windowStart || null,
            windowEnd: windowEnd || existing?.windowEnd || null
        };

        this.subscriptions.set(key, subscription);
        this.scheduleEnd(subscription);
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
                preferred_service_id: subscription.preferredServiceId || null,
                mute_on_arrival: subscription.muteOnArrival,
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
        const endAfterMs = this.getEndAfterMs();
        subscription.endAt = new Date(Date.now() + endAfterMs).toISOString();
        subscription.endTimer = setTimeout(() => {
            this.sendEndUpdate(subscription).catch((error) => {
                const key = this.buildKey(subscription.deviceId, subscription.activityId);
                console.error(`Final live activity end push failed for ${key}: ${error?.message || error}`);
            });
        }, endAfterMs);
        subscription.endTimer.unref?.();
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
            const snapshot = await this.getDeparturesSnapshot(
                subscription.fromStation,
                subscription.toStation,
                subscription.preferredServiceId
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

            const payload = this.buildPayload(subscription, snapshot, { appIsActive });

            if (dryRun) {
                this.log(`[live-activity] dry_run ${subscription.deviceId}/${subscription.activityId}`);
                return { sent: false, reason: 'dry_run', snapshot, payload };
            }

            const pushResponse = await this.pushClient.sendLiveActivityUpdate(subscription.pushToken, payload, {
                useSandbox: subscription.useSandbox,
                event: 'live_activity_update'
            });
            this.logPushEvent(subscription, payload, pushResponse, 'live_activity_update');

            // If the token is bad/expired, remove this subscription
            if (pushResponse?.isBadToken) {
                const key = this.buildKey(subscription.deviceId, subscription.activityId);
                console.log(`🗑️ [live-activity] Removing subscription ${key} due to bad/expired token`);
                this.clearEndTimer(subscription);
                this.subscriptions.delete(key);
                return { sent: false, reason: 'bad_token', snapshot, payload, pushResponse };
            }

            subscription.lastSnapshot = snapshot;
            subscription.lastPushAt = snapshot.fetchedAt;
            subscription.revision = (subscription.revision || 0) + 1;
            subscription.appIsActive = appIsActive;

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

    async sendEndUpdate(subscription) {
        const key = this.buildKey(subscription.deviceId, subscription.activityId);
        const snapshot = subscription.lastSnapshot || (
            await this.getDeparturesSnapshot(
                subscription.fromStation,
                subscription.toStation,
                subscription.preferredServiceId
            )
        );
        const payload = this.buildPayload(subscription, snapshot, {
            end: true,
            appIsActive: this.shouldShowAppActive(subscription)
        });
        const pushResponse = await this.pushClient.sendLiveActivityUpdate(subscription.pushToken, payload, {
            useSandbox: subscription.useSandbox,
            event: 'live_activity_end'
        });
        this.logPushEvent(subscription, payload, pushResponse, 'live_activity_end');

        // Clean up subscription regardless of push result
        this.clearEndTimer(subscription);
        this.subscriptions.delete(key);

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
                endAt: subscription.endAt
            }
        );
        return { snapshot, payload, pushResponse };
    }

    logPushEvent(subscription, payload, pushResponse, type) {
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
                created_at: subscription.createdAt || null
            }
        }).catch((error) => {
            console.error('[admin] Failed to log live activity event:', error?.message || error);
        });
    }

    async getDeparturesSnapshot(fromStation, toStation, preferredServiceId = null) {
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

        const sortedUpcoming = this.sortDepartures(normalizedAll);
        const departures = this.selectDeparturesForActivity(
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
                statusText: richStatus // Include rich status for comparison
            };
        });

        return {
            departures: normalized,
            fetchedAt: new Date().toISOString()
        };
    }

    buildPayload(subscription, snapshot, { end = false, appIsActive = false } = {}) {
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
            const alert = this.buildAlert(subscription.lastSnapshot, snapshot);
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
     * when a significant change is detected for the primary (first) departure:
     *  - Cancellation
     *  - Platform change
     *  - Delay increase of ≥ 5 minutes (and at least 3 minutes worse than before)
     *
     * Returns null if no significant change is detected or if the snapshots represent
     * different services (to avoid false alerts on service rotations).
     */
    buildAlert(prevSnapshot, newSnapshot) {
        if (!prevSnapshot || !newSnapshot) return null;
        const prev = prevSnapshot.departures[0];
        const next = newSnapshot.departures[0];
        if (!prev || !next) return null;

        // Only compare the same service to avoid false positives when a different
        // train becomes the primary departure between polls.
        if (prev.serviceID && next.serviceID && prev.serviceID !== next.serviceID) {
            return null;
        }

        // Cancellation
        if (!prev.isCancelled && next.isCancelled) {
            const time = next.scheduled ? ` ${next.scheduled}` : '';
            return {
                title: 'Train Cancelled',
                body: `Your${time} service has been cancelled.`
            };
        }

        // Platform change (only alert when both sides have a known platform)
        if (prev.platform && next.platform && prev.platform !== next.platform) {
            return {
                title: 'Platform Change',
                body: `Platform changed from ${prev.platform} to ${next.platform}.`
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

    sortDepartures(departures) {
        const now = moment();
        return departures
            .filter((dep) => dep.scheduled || dep.estimated)
            .filter((dep) => {
                // Filter out trains that have already departed (give 1 minute grace period)
                const depTime = this.parseTime(dep.estimated || dep.scheduled);
                const gracePeriodMs = 60 * 1000; // 1 minute
                return depTime > (now.valueOf() - gracePeriodMs);
            })
            .sort((a, b) => {
                const timeA = this.parseTime(a.estimated || a.scheduled);
                const timeB = this.parseTime(b.estimated || b.scheduled);
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

        const preferred = allDepartures.find((dep) => dep.serviceID === normalizedPreferred);
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
        const estimated = this.getTimeString(primary.estimated, primary.scheduled);
        const delayMinutes = this.calculateDelay(primary.scheduled, primary.estimated);

        const platform = this.ensureString(primary.platform);
        const destinationTitle = this.ensureString(primary.destination?.locationName);
        const upcomingDepartures = snapshot.departures.slice(1).map((dep) => ({
            time: this.getTimeString(dep.estimated, dep.scheduled),
            delayMinutes: this.calculateDelay(dep.scheduled, dep.estimated),
            isCancelled: Boolean(dep.isCancelled),
            platform: this.ensureString(dep.platform),
            hasFasterLaterService: false // Server doesn't compute this; client handles it
        }));

        return {
            fromCRS: this.ensureString(subscription.fromStation),
            toCRS: this.ensureString(subscription.toStation),
            destinationTitle,
            arrivalLabel: null,
            length: Number.isFinite(primary.length) && primary.length > 0 ? primary.length : null,
            platform,
            estimated,
            statusText: this.buildStatusText(primary),
            delayMinutes,
            upcomingDepartures,
            lastUpdated: moment(snapshot.fetchedAt).unix(), // Convert to Unix timestamp for iOS Date decoding
            activityID: subscription.activityId, // Include activity ID for iOS ContentState
            revision: subscription.revision || 0,
            appIsActive,
            scheduleKey: this.ensureOptionalString(subscription.scheduleKey),
            windowStart: this.ensureOptionalString(subscription.windowStart),
            windowEnd: this.ensureOptionalString(subscription.windowEnd)
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
                at: serviceDetails.atd || serviceDetails.ata
            });
        }

        // Add subsequent calling points (upcoming)
        if (serviceDetails.subsequentCallingPoints && serviceDetails.subsequentCallingPoints.length > 0) {
            const next = serviceDetails.subsequentCallingPoints[0].callingPoint || [];
            stations.push(...next);
        }

        return stations;
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

    ensureString(value, fallback = '') {
        if (typeof value === 'string' && value.length > 0) return value;
        if (typeof value === 'number') return String(value);
        return fallback;
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

    unregisterSubscription(deviceId, activityId, { fallbackDeviceIds = [] } = {}) {
        const subscription = this.getSubscription(deviceId, activityId, { fallbackDeviceIds });
        if (!subscription) {
            this.log(`[live-activity] unregister_not_found ${deviceId}/${activityId}`);
            return false;
        }
        const key = this.buildKey(subscription.deviceId, subscription.activityId);
        this.clearEndTimer(subscription);
        this.subscriptions.delete(key);
        this.log(`[live-activity] unregistered ${deviceId}/${activityId}`);
        return true;
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
            await this.sendEndUpdate(subscription);
            return;
        } catch (error) {
            console.error(`[live-activity] cleanup end push failed for ${key}: ${error?.message || error}`);
        }

        this.clearEndTimer(subscription);
        this.subscriptions.delete(key);
        this.log(`[live-activity] cleanup_removed ${key} reason=${reason}`);
    }

    async sendEndPushForEvictedSubscription(subscription, reason = 'evicted') {
        try {
            await this.sendEndUpdate(subscription);
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

    /**
     * Called when the iOS app detects the user has arrived at a departure station.
     * Ends any matching Live Activity subscriptions that have autoEndOnArrival enabled.
     */
    async handleArrival(deviceId, { fromStation = null, toStation = null, fallbackDeviceIds = [] } = {}) {
        const candidateDeviceIds = this.uniqueDeviceIds([deviceId, ...fallbackDeviceIds]);
        if (candidateDeviceIds.length === 0) return { ended: 0 };

        const subs = this.findSubscriptionsByDeviceIds(candidateDeviceIds).filter((sub) => {
            if (!sub.autoEndOnArrival) return false;
            if (fromStation && sub.fromStation?.toUpperCase() !== fromStation.toUpperCase()) return false;
            if (toStation && sub.toStation?.toUpperCase() !== toStation.toUpperCase()) return false;
            return true;
        });

        if (subs.length === 0) {
            this.log(`[live-activity] arrival_no_subscriptions ${candidateDeviceIds.join(',')} (autoEndOnArrival=false or no match)`);
            return { ended: 0 };
        }

        const results = await Promise.all(subs.map(async (sub) => {
            try {
                await this.sendEndUpdate(sub);
                this.log(`[live-activity] ended_on_arrival ${sub.deviceId}/${sub.activityId}`);
                return 1;
            } catch (error) {
                const key = this.buildKey(sub.deviceId, sub.activityId);
                console.error(`[live-activity] arrival end failed for ${key}: ${error?.message || error}`);
                return 0;
            }
        }));

        return { ended: results.reduce((sum, v) => sum + v, 0) };
    }

    maskToken(token) {
        if (!token || typeof token !== 'string') return 'null';
        if (token.length <= 16) return token.slice(0, 6) + '***';
        return token.slice(0, 8) + '...' + token.slice(-8);
    }

    buildKey(deviceId, activityId) {
        return `${deviceId}::${activityId}`;
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
