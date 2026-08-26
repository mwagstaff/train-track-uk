import crypto from 'crypto';

import { recordSubscriptionAuditEvent } from './admin-data-store.js';
import { NotificationPushClient } from './notification-push-client.js';
import { getServiceDetailsWithContext } from './service-details.js';
import { allowDeviceData } from './device-data-deletion-state.js';

const DEFAULT_POLL_INTERVAL_SECONDS = Number(process.env.JOURNEY_TRACKING_POLL_INTERVAL_SECONDS || '30');
const DEFAULT_SESSION_LIFETIME_MS = 24 * 60 * 60 * 1000;
const MAX_SESSIONS_PER_DEVICE = Number(process.env.JOURNEY_TRACKING_MAX_SESSIONS_PER_DEVICE || '3');

export class JourneyTrackingManager {
    constructor(options = {}) {
        this.sessions = new Map();
        this.getDetails = options.getDetails || getServiceDetailsWithContext;
        this.pushClient = options.pushClient || new NotificationPushClient();
        this.recordAudit = options.recordAudit || null;
        this.onJourneyCompleted = options.onJourneyCompleted || null;
        this.now = options.now || (() => new Date());
        this.pollIntervalMs = options.pollIntervalMs
            || Math.max(5, DEFAULT_POLL_INTERVAL_SECONDS) * 1000;
        this.pollTimer = null;
        this.isPolling = false;
        this.deletedDeviceIds = new Set();
    }

    setJourneyCompletionHandler(handler) {
        this.onJourneyCompleted = typeof handler === 'function' ? handler : null;
    }

    startPollingLoop() {
        if (this.pollTimer) return;
        this.pollTimer = setInterval(() => {
            this.pollAll().catch((error) => {
                console.error('[journey-tracking] Poll failed:', error?.message || error);
            });
        }, this.pollIntervalMs);
        this.pollTimer.unref?.();
    }

    stopPollingLoop() {
        if (this.pollTimer) clearInterval(this.pollTimer);
        this.pollTimer = null;
    }

    upsertSession(payload = {}) {
        this.pruneExpired();
        const normalized = normalizeRegistration(payload);
        if (!allowDeviceData(normalized.deviceId)) {
            throw new Error('Device data deletion is in progress');
        }
        this.deletedDeviceIds.delete(normalized.deviceId);
        const existing = Array.from(this.sessions.values()).find((session) => (
            session.journeyId === normalized.journeyId
                && session.deviceId === normalized.deviceId
        ));
        const deviceSessionCount = Array.from(this.sessions.values())
            .filter((session) => session.deviceId === normalized.deviceId)
            .length;
        if (!existing && deviceSessionCount >= MAX_SESSIONS_PER_DEVICE) {
            throw new Error(`Maximum of ${MAX_SESSIONS_PER_DEVICE} journey tracking sessions reached`);
        }
        const now = this.now();
        const session = {
            ...existing,
            ...normalized,
            id: existing?.id || crypto.randomUUID(),
            createdAt: existing?.createdAt || now.toISOString(),
            updatedAt: now.toISOString(),
            expiresAt: new Date(now.getTime() + DEFAULT_SESSION_LIFETIME_MS).toISOString(),
            lastFingerprint: existing?.serviceId === normalized.serviceId
                ? (existing.lastFingerprint || null)
                : null,
            lastDetectedFingerprint: existing?.serviceId === normalized.serviceId
                ? (existing.lastDetectedFingerprint || null)
                : null,
            lastPushAuditState: existing?.serviceId === normalized.serviceId
                ? (existing.lastPushAuditState || null)
                : null
        };
        this.sessions.set(session.id, session);
        this.audit(existing ? 'journey_tracking_updated' : 'journey_tracking_registered', session, {
            expires_at: session.expiresAt,
            use_sandbox: session.useSandbox
        });
        return publicSession(session);
    }

    listSessions(deviceId) {
        this.pruneExpired();
        return Array.from(this.sessions.values())
            .filter((session) => !deviceId || session.deviceId === deviceId)
            .map(publicSession);
    }

    deleteSession({ id, deviceId }) {
        const session = this.sessions.get(id);
        if (!session || (deviceId && session.deviceId !== deviceId)) return false;
        const removed = this.sessions.delete(id);
        if (removed) this.audit('journey_tracking_deleted', session);
        return removed;
    }

    purgeDeviceRuntimeState(deviceId) {
        const normalizedDeviceId = cleanString(deviceId);
        if (!normalizedDeviceId) return 0;

        this.deletedDeviceIds.add(normalizedDeviceId);

        let removed = 0;
        for (const [id, session] of this.sessions.entries()) {
            if (session.deviceId !== normalizedDeviceId) continue;
            this.sessions.delete(id);
            removed += 1;
        }
        return removed;
    }

    async pollAll() {
        if (this.isPolling) return;
        this.isPolling = true;
        try {
            this.pruneExpired();
            for (const session of Array.from(this.sessions.values())) {
                try {
                    await this.pollSession(session);
                } catch (error) {
                    console.error('[journey-tracking] Session poll failed', JSON.stringify({
                        session_id: session.id,
                        journey_id: session.journeyId,
                        error: error?.message || String(error)
                    }));
                    this.audit('journey_tracking_poll_failed', session, {
                        error: error?.message || String(error)
                    });
                }
            }
        } finally {
            this.isPolling = false;
        }
    }

    async pollSession(sessionOrId) {
        const session = typeof sessionOrId === 'string'
            ? this.sessions.get(sessionOrId)
            : sessionOrId;
        if (this.deletedDeviceIds.has(session?.deviceId)) return { status: 'device_data_deleted' };
        if (!session || !this.sessions.has(session.id)) return { status: 'not_found' };

        const details = await this.getDetails(session.serviceId, {
            fromCRS: session.from,
            toCRS: session.to,
            destinationCRSs: [session.destinationCRS]
        });
        if (!details || details.error) {
            if (session.lastAuditState !== 'upstream_unavailable') {
                session.lastAuditState = 'upstream_unavailable';
                this.audit('journey_tracking_upstream_unavailable', session, {
                    error: details?.error || 'No service details returned'
                });
            }
            return { status: 'upstream_unavailable' };
        }
        session.lastAuditState = 'available';

        const progress = progressFromDetails(details, session.destinationCRS);
        const fingerprint = JSON.stringify({
            progress,
            operator: cleanString(details?.operator),
            operatorCode: cleanString(details?.operatorCode)
        });
        if (fingerprint === session.lastFingerprint) {
            return { status: 'unchanged' };
        }

        if (session.lastDetectedFingerprint !== fingerprint) {
            session.lastDetectedFingerprint = fingerprint;
            this.audit('journey_tracking_progress_detected', session, {
                station_crs: progress.stationCRS,
                scheduled_arrival: progress.scheduledArrival,
                actual_arrival: progress.actualArrival,
                actual_calling_point_count: progress.actualCallingPointCount,
                operator: cleanString(details?.operator),
                operator_code: cleanString(details?.operatorCode)
            });
        }

        let completionReconciliationError = null;
        if (progress.actualArrival) {
            try {
                await this.onJourneyCompleted?.({
                    deviceId: session.deviceId,
                    subscriptionId: session.subscriptionId,
                    from: session.from,
                    to: session.to,
                    journeyId: session.journeyId,
                    serviceId: session.serviceId,
                    actualArrival: progress.actualArrival
                });
            } catch (error) {
                completionReconciliationError = error;
                this.audit('journey_tracking_completion_reconciliation_failed', session, {
                    station_crs: progress.stationCRS,
                    scheduled_arrival: progress.scheduledArrival,
                    actual_arrival: progress.actualArrival,
                    error: error?.message || String(error)
                });
            }
        }

        const payload = buildProgressPayload(session, details, progress);
        const result = await this.pushClient.sendNotification(session.pushToken, payload, {
            useSandbox: session.useSandbox,
            event: 'journey_tracking_update',
            context: {
                device_id: session.deviceId,
                journey_id: session.journeyId,
                session_id: session.id,
                service_id: session.serviceId
            }
        });

        if (result?.isBadToken) {
            this.audit('journey_tracking_push_bad_token', session, pushAuditMetadata(result, progress));
            if (completionReconciliationError) {
                return {
                    status: 'completion_reconciliation_failed',
                    progress,
                    push: result
                };
            }
            this.sessions.delete(session.id);
            return { status: 'bad_token', progress, push: result };
        }
        if (!pushSucceeded(result)) {
            const failureState = `failed:${result?.status ?? 'unknown'}`;
            if (session.lastPushAuditState !== failureState) {
                session.lastPushAuditState = failureState;
                this.audit('journey_tracking_push_failed', session, pushAuditMetadata(result, progress));
            }
            return { status: 'push_failed', progress, push: result };
        }

        if (completionReconciliationError) {
            return { status: 'completion_reconciliation_failed', progress, push: result };
        }

        session.lastPushAuditState = 'succeeded';
        session.lastFingerprint = fingerprint;
        session.updatedAt = this.now().toISOString();
        if (progress.actualArrival) {
            this.audit('journey_tracking_completed', session, pushAuditMetadata(result, progress));
            this.sessions.delete(session.id);
        } else {
            this.audit('journey_tracking_progress_pushed', session, pushAuditMetadata(result, progress));
        }
        return {
            status: progress.actualArrival ? 'completed' : 'updated',
            progress,
            push: result
        };
    }

    pruneExpired() {
        const now = this.now().getTime();
        for (const session of this.sessions.values()) {
            if (Date.parse(session.expiresAt) <= now) {
                this.audit('journey_tracking_expired', session);
                this.sessions.delete(session.id);
            }
        }
    }

    audit(action, session, metadata = {}) {
        if (this.deletedDeviceIds.has(session?.deviceId)) return;
        const event = {
            action,
            reason: action,
            source: 'journey_tracking',
            subscription_id: session?.subscriptionId || null,
            device_id: session?.deviceId || null,
            route_key: session ? `${session.from}-${session.to}` : null,
            from_station: session?.from || null,
            to_station: session?.to || null,
            metadata: {
                journey_id: session?.journeyId || null,
                session_id: session?.id || null,
                service_id: session?.serviceId || null,
                destination_crs: session?.destinationCRS || null,
                ...metadata
            }
        };
        console.log('[journey-tracking]', action, JSON.stringify({
            device_id: event.device_id,
            journey_id: event.metadata.journey_id,
            session_id: event.metadata.session_id,
            service_id: event.metadata.service_id,
            station_crs: event.metadata.station_crs || null,
            status: event.metadata.push_status || null
        }));
        if (this.recordAudit) {
            Promise.resolve(this.recordAudit(event)).catch((error) => {
                console.error('[journey-tracking] Failed to persist audit event:', error?.message || error);
            });
        }
    }
}

function normalizeRegistration(payload) {
    const required = {
        journeyId: cleanString(payload.journeyId),
        subscriptionId: cleanString(payload.subscriptionId),
        deviceId: cleanString(payload.deviceId),
        pushToken: cleanString(payload.pushToken),
        serviceId: cleanString(payload.serviceId),
        from: normalizeCRS(payload.from),
        to: normalizeCRS(payload.to),
        destinationCRS: normalizeCRS(payload.destinationCRS)
    };
    const missing = Object.entries(required)
        .filter(([, value]) => !value)
        .map(([key]) => key);
    if (missing.length > 0) {
        throw new Error(`Missing required journey tracking fields: ${missing.join(', ')}`);
    }
    return {
        ...required,
        useSandbox: payload.useSandbox === true
    };
}

function progressFromDetails(details, destinationCRS) {
    const route = routeForDestination(details, destinationCRS);
    const destination = [...route].reverse().find((point) => normalizeCRS(point?.crs) === destinationCRS);
    const detailsAtDestination = normalizeCRS(details?.crs) === destinationCRS;
    const actualPoints = route.filter((point) => confirmedActualTime(point?.at, point?.st));
    const lastActualPoint = actualPoints.at(-1) || null;
    return {
        stationCRS: normalizeCRS(lastActualPoint?.crs) || null,
        scheduledArrival: cleanTime(destination?.st)
            || (detailsAtDestination ? cleanTime(details?.sta) : null),
        actualArrival: confirmedActualTime(destination?.at, destination?.st)
            || (detailsAtDestination ? confirmedActualTime(details?.ata, details?.sta) : null),
        actualCallingPointCount: actualPoints.length
    };
}

function routeForDestination(details, destinationCRS) {
    const previous = firstCallingPointList(details?.previousCallingPoints);
    const current = details?.crs ? [{
        crs: details.crs,
        locationName: details.locationName,
        st: details.std || details.sta,
        at: details.atd || details.ata
    }] : [];
    const subsequentGroups = Array.isArray(details?.subsequentCallingPoints)
        ? details.subsequentCallingPoints.map((group) => Array.isArray(group?.callingPoint) ? group.callingPoint : [])
        : [];
    const subsequent = subsequentGroups.find((points) => (
        points.some((point) => normalizeCRS(point?.crs) === destinationCRS)
    )) || subsequentGroups[0] || [];
    return deduplicateAdjacentPoints([...previous, ...current, ...subsequent]);
}

function firstCallingPointList(groups) {
    if (!Array.isArray(groups)) return [];
    return Array.isArray(groups[0]?.callingPoint) ? groups[0].callingPoint : [];
}

function deduplicateAdjacentPoints(points) {
    return points.filter((point, index) => (
        index === 0 || normalizeCRS(point?.crs) !== normalizeCRS(points[index - 1]?.crs)
    ));
}

function confirmedActualTime(actual, scheduled) {
    const value = cleanString(actual);
    if (!value || value.toLowerCase() === 'cancelled') return null;
    if (value.toLowerCase() === 'on time') return cleanTime(scheduled);
    return cleanTime(value);
}

function buildProgressPayload(session, details, progress) {
    const completed = Boolean(progress.actualArrival);
    return {
        aps: { 'content-available': 1 },
        alert_type: 'journey_tracking_update',
        journey_event: completed
            ? 'service_completed'
            : (progress.stationCRS ? 'station_departed' : 'progress'),
        journey_id: session.journeyId,
        subscription_id: session.subscriptionId,
        service_id: session.serviceId,
        station_crs: progress.stationCRS,
        destination_crs: session.destinationCRS,
        operator: cleanString(details?.operator),
        operator_code: cleanString(details?.operatorCode),
        scheduled_arrival: progress.scheduledArrival,
        actual_arrival: progress.actualArrival
    };
}

function publicSession(session) {
    return {
        id: session.id,
        journey_id: session.journeyId,
        subscription_id: session.subscriptionId,
        service_id: session.serviceId,
        from: session.from,
        to: session.to,
        destination_crs: session.destinationCRS,
        created_at: session.createdAt,
        updated_at: session.updatedAt,
        expires_at: session.expiresAt
    };
}

function cleanString(value) {
    return typeof value === 'string' && value.trim() ? value.trim() : null;
}

function normalizeCRS(value) {
    return cleanString(value)?.toUpperCase() || null;
}

function cleanTime(value) {
    const normalized = cleanString(value);
    return /^([01]\d|2[0-3]):[0-5]\d$/.test(normalized || '') ? normalized : null;
}

function pushSucceeded(result) {
    if (result?.skipped === true) return true;
    return Number.isInteger(result?.status) && result.status >= 200 && result.status < 300;
}

function pushAuditMetadata(result, progress) {
    return {
        station_crs: progress?.stationCRS || null,
        scheduled_arrival: progress?.scheduledArrival || null,
        actual_arrival: progress?.actualArrival || null,
        push_status: result?.status ?? null,
        push_skipped: result?.skipped === true,
        is_bad_token: result?.isBadToken === true
    };
}

export const journeyTrackingManager = new JourneyTrackingManager({
    recordAudit: recordSubscriptionAuditEvent
});
