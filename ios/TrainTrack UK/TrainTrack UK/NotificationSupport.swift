import Foundation
import UserNotifications
import UIKit
import ActivityKit
import JourneyActivityShared

enum NotificationPushTokenStore {
    private static let storageKey = "notification_push_token"
    private static let store: UserDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard

    static var token: String? {
        store.string(forKey: storageKey)
    }

    static func set(token: String) {
        store.set(token, forKey: storageKey)
    }

    static func waitForToken(timeoutSeconds: Double = 4.0) async -> String? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let token = token, !token.isEmpty {
                return token
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return token
    }
}

enum NotificationAuthorizationManager {
    static func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            await registerForRemoteNotifications()
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    await registerForRemoteNotifications()
                }
                return granted
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    static func registerIfAuthorized() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            await registerForRemoteNotifications()
        default:
            break
        }
    }

    @MainActor
    private static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

final class NotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationCategoryRegistrar.register()
        ClientDiagnosticsLogger.log("app", "did_finish_launching", metadata: [
            "launch_options": launchOptions?.keys.map { String(describing: $0) } ?? [],
            "device_id": DeviceIdentity.deviceToken,
            "api_base": ApiHostPreference.currentBaseURL,
            "notification_apns_sandbox": notificationAPNsSandboxEnabled()
        ])
        DebugLogStore.shared.log(
            """
            App launch
            Device: \(DeviceIdentity.deviceToken)
            API: \(ApiHostPreference.currentBaseURL)
            Notification APNs sandbox: \(notificationAPNsSandboxEnabled())
            """,
            category: "Scheduled"
        )
        _ = LiveActivityManager.shared
        // Recreate the location authorization/session state promptly on every launch.
        // Core Location only preserves a terminated app's service-session intent for a
        // short grace period, and a location launch must not wait for a network refresh.
        let locationLaunch = launchOptions?[.location] != nil
        Task { @MainActor in
            await NotificationGeofenceManager.shared.restoreAfterLaunch(
                trigger: locationLaunch ? "location" : "application"
            )
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationPushTokenStore.set(token: token)
        ClientDiagnosticsLogger.log("notifications", "registered_remote_notifications", metadata: [
            "device_id": DeviceIdentity.deviceToken,
            "notification_apns_sandbox": notificationAPNsSandboxEnabled(),
            "token_prefix": String(token.prefix(8)),
            "token_suffix": String(token.suffix(8))
        ])
        Task { @MainActor in
            DebugLogStore.shared.log(
                """
                Remote notification token registered
                Device: \(DeviceIdentity.deviceToken)
                APNs sandbox: \(notificationAPNsSandboxEnabled())
                Token: \(String(token.prefix(8)))...\(String(token.suffix(8)))
                """,
                category: "Scheduled"
            )
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("⚠️ [Notifications] Failed to register for remote notifications: \(error.localizedDescription)")
        ClientDiagnosticsLogger.log("notifications", "remote_notification_registration_failed", metadata: [
            "error": error.localizedDescription
        ])
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            ClientDiagnosticsLogger.log("notifications", "did_receive_remote_notification", metadata: [
                "alert_type": userInfo["alert_type"] as? String,
                "aps_event": (userInfo["aps"] as? [AnyHashable: Any])?["event"] as? String,
                "aps_alert_title": apsAlertValue("title", in: userInfo),
                "aps_alert_body": apsAlertValue("body", in: userInfo),
                "diagnostic_marker": userInfo[NotificationPayloadKeys.diagnosticMarker] as? String,
                "diagnostic_channel": userInfo[NotificationPayloadKeys.diagnosticChannel] as? String,
                "diagnostic_event": userInfo[NotificationPayloadKeys.diagnosticEvent] as? String,
                "from": userInfo["from"] as? String,
                "to": userInfo["to"] as? String,
                "route_key": userInfo["route_key"] as? String,
                "schedule_key": userInfo["schedule_key"] as? String,
                "keys": userInfo.keys.map { String(describing: $0) }.sorted()
            ])
            let journeyTrackingUpdated = await JourneyTrackingCoordinator.shared.handleRemoteNotification(userInfo)
            let started = await ScheduledLiveActivityAutoStartManager.shared.handleRemoteNotification(userInfo: userInfo)

            // For push-to-start notifications (content-available: 1 is included in the
            // payload), iOS wakes the app in background. The new Activity can take a
            // moment to appear in Activity.activities, so probe a few times during the
            // runtime iOS grants us instead of betting the whole hand on a single 750ms
            // lookup.
            for delay in [750_000_000, 1_500_000_000, 3_000_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                await LiveActivityManager.shared.registerAnyUnregisteredActivities()
            }

            // Use this background wake as a fresh chance to confirm station arrival and to
            // detect silent background-location failures. Continuous updates after a geofence
            // wake aren't guaranteed to survive, so we re-sample here independently.
            await NotificationGeofenceManager.shared.refreshArrivalFromBackgroundWake(trigger: "remote_notification")

            ClientDiagnosticsLogger.log("notifications", "remote_notification_handled", metadata: [
                "started_scheduled_live_activity": started,
                "journey_tracking_updated": journeyTrackingUpdated,
                "completion": (started || journeyTrackingUpdated) ? "newData" : "noData"
            ])
            completionHandler((started || journeyTrackingUpdated) ? .newData : .noData)
        }
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundSessionCoordinator.shared.register(identifier: identifier, completion: completionHandler)
        // Ensure the relevant background session delegate is instantiated so iOS
        // can deliver its completion events.
        if identifier == GeofenceEventSender.sessionIdentifier {
            _ = GeofenceEventSender.shared
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        ClientDiagnosticsLogger.log("notifications", "will_present_notification", metadata: notificationDiagnosticMetadata(notification.request))
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        ClientDiagnosticsLogger.log("notifications", "did_receive_notification_response", metadata: notificationDiagnosticMetadata(response.notification.request).merging([
            "action_identifier": response.actionIdentifier
        ]) { _, new in new })
        Task { @MainActor in
            NotificationAlertHandler.shared.handle(response: response)
        }
        completionHandler()
    }
}

private func notificationDiagnosticMetadata(_ request: UNNotificationRequest) -> [String: Any?] {
    let content = request.content
    return [
        "identifier": request.identifier,
        "title": content.title,
        "subtitle": content.subtitle,
        "body": content.body,
        "category": content.categoryIdentifier,
        "alert_type": content.userInfo[NotificationPayloadKeys.alertType] as? String,
        "aps_event": (content.userInfo["aps"] as? [AnyHashable: Any])?["event"] as? String,
        "diagnostic_marker": content.userInfo[NotificationPayloadKeys.diagnosticMarker] as? String,
        "diagnostic_channel": content.userInfo[NotificationPayloadKeys.diagnosticChannel] as? String,
        "diagnostic_event": content.userInfo[NotificationPayloadKeys.diagnosticEvent] as? String,
        "from": content.userInfo[NotificationPayloadKeys.from] as? String,
        "to": content.userInfo[NotificationPayloadKeys.to] as? String,
        "from_name": content.userInfo[NotificationPayloadKeys.fromName] as? String,
        "to_name": content.userInfo[NotificationPayloadKeys.toName] as? String,
        "route_key": content.userInfo[NotificationPayloadKeys.routeKey] as? String,
        "leg_key": content.userInfo[NotificationPayloadKeys.legKey] as? String,
        "schedule_key": content.userInfo["schedule_key"] as? String,
        "window_start": content.userInfo[NotificationPayloadKeys.windowStart] as? String,
        "window_end": content.userInfo[NotificationPayloadKeys.windowEnd] as? String,
        "keys": content.userInfo.keys.map { String(describing: $0) }.sorted()
    ]
}

private func apsAlertValue(_ key: String, in userInfo: [AnyHashable: Any]) -> String? {
    guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return nil }
    if let alert = aps["alert"] as? [AnyHashable: Any] {
        return alert[key] as? String
    }
    if key == "body", let alert = aps["alert"] as? String {
        return alert
    }
    return nil
}

private func notificationAPNsSandboxEnabled() -> Bool {
    #if DEBUG
    return true
    #else
    return false
    #endif
}

@MainActor
enum ScheduledNotificationLiveSessionRegistrar {
    static func ensureLiveSession(
        existingLiveSessionID: String?,
        from: String,
        to: String,
        fromName: String?,
        toName: String?,
        scheduleKey: String?,
        windowStart: String?,
        windowEnd: String?,
        source: String,
        metadata: [String: Any?]
    ) async -> String? {
        await NotificationAuthorizationManager.registerIfAuthorized()
        NotificationGeofenceManager.shared.requestAlwaysAuthorizationIfNeeded()

        let fromCode = from.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let toCode = to.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let routeKey = "\(fromCode)-\(toCode)"
        let existingSession = NotificationSubscriptionStore.shared.liveSession(for: routeKey)
        let subscriptionId = existingLiveSessionID ?? existingSession?.id
        let logMetadata = registrationMetadata(
            metadata,
            routeKey: routeKey,
            from: fromCode,
            to: toCode,
            fromName: fromName,
            toName: toName,
            scheduleKey: scheduleKey,
            windowStart: windowStart,
            windowEnd: windowEnd,
            source: source,
            existingLiveSessionID: subscriptionId
        )

        guard let pushToken = await NotificationPushTokenStore.waitForToken(timeoutSeconds: 6.0),
              !pushToken.isEmpty else {
            ClientDiagnosticsLogger.log("scheduled_live_activity", "live_session_skipped_missing_push_token", metadata: logMetadata)
            DebugLogStore.shared.log(
                """
                Scheduled live session skipped: missing notification push token
                Route: \(fromCode)→\(toCode)
                Schedule: \(scheduleKey ?? "nil")
                Source: \(source)
                Existing live session: \(subscriptionId ?? "nil")
                """,
                category: "Error"
            )
            return subscriptionId
        }

        let activeUntilResult = liveSessionActiveUntil(windowStart: windowStart, windowEnd: windowEnd)
        let activeUntil = activeUntilResult.date
        let request = NotificationSubscriptionRequest(
            subscriptionId: subscriptionId,
            deviceId: DeviceIdentity.deviceToken,
            pushToken: pushToken,
            routeKey: routeKey,
            daysOfWeek: [currentDayOfWeek()],
            notificationTypes: NotificationPreferences.effectiveTypes(for: .liveSession),
            legs: [
                NotificationLeg(
                    from: fromCode,
                    to: toCode,
                    fromName: fromName,
                    toName: toName,
                    enabled: true,
                    windowStart: "00:00",
                    windowEnd: "23:59"
                )
            ],
            windowStart: "00:00",
            windowEnd: "23:59",
            from: fromCode,
            to: toCode,
            fromName: fromName,
            toName: toName,
            useSandbox: notificationAPNsSandboxEnabled(),
            muteOnArrival: true,
            liveSessionOrigin: .scheduled,
            activeUntil: activeUntil
        )

        DebugLogStore.shared.log(
            """
            Registering scheduled live session
            Route: \(fromCode)→\(toCode)
            Schedule: \(scheduleKey ?? "nil")
            Source: \(source)
            Existing live session: \(subscriptionId ?? "nil")
            Active until: \(ISO8601DateFormatter().string(from: activeUntil))
            Active until source: \(activeUntilResult.source)
            """,
            category: "Scheduled"
        )

        do {
            let subscription = try await NotificationSubscriptionStore.shared.upsertLiveSession(
                request,
                historySource: .scheduled
            )
            ClientDiagnosticsLogger.log("scheduled_live_activity", "live_session_registered", metadata: logMetadata.merging([
                "subscription_id": subscription.id,
                "active_until": subscription.activeUntil ?? activeUntil,
                "active_until_source": activeUntilResult.source,
                "push_token_prefix": String(pushToken.prefix(8)),
                "push_token_suffix": String(pushToken.suffix(8))
            ]) { _, new in new })
            DebugLogStore.shared.log(
                "Scheduled live session registered: \(subscription.id) for \(fromCode)→\(toCode) from \(source)",
                category: "Scheduled"
            )
            return subscription.id
        } catch {
            ClientDiagnosticsLogger.log("scheduled_live_activity", "live_session_registration_failed", metadata: logMetadata.merging([
                "error": error.localizedDescription
            ]) { _, new in new })
            DebugLogStore.shared.log(
                """
                Scheduled live session failed
                Route: \(fromCode)→\(toCode)
                Source: \(source)
                Error: \(error.localizedDescription)
                """,
                category: "Error"
            )
            return subscriptionId
        }
    }

    private static func registrationMetadata(
        _ metadata: [String: Any?],
        routeKey: String,
        from: String,
        to: String,
        fromName: String?,
        toName: String?,
        scheduleKey: String?,
        windowStart: String?,
        windowEnd: String?,
        source: String,
        existingLiveSessionID: String?
    ) -> [String: Any?] {
        metadata.merging([
            "route_key": routeKey,
            "from": from,
            "to": to,
            "from_name": fromName,
            "to_name": toName,
            "schedule_key": scheduleKey,
            "window_start": windowStart,
            "window_end": windowEnd,
            "source": source,
            "existing_live_session_id": existingLiveSessionID
        ]) { _, new in new }
    }

    private static func liveSessionDurationMinutes() -> Int {
        let storedMinutes = UserDefaults.standard.integer(forKey: "liveActivityDurationMinutes")
        return min(120, max(1, storedMinutes == 0 ? 60 : storedMinutes))
    }

    private static func liveSessionActiveUntil(
        windowStart: String?,
        windowEnd: String?,
        now: Date = Date()
    ) -> (date: Date, source: String) {
        if let scheduledEnd = scheduledWindowEndDate(windowStart: windowStart, windowEnd: windowEnd, now: now),
           scheduledEnd > now {
            return (scheduledEnd, "schedule_window_end")
        }

        let durationMinutes = liveSessionDurationMinutes()
        return (now.addingTimeInterval(Double(durationMinutes * 60)), "duration_preference")
    }

    private static func scheduledWindowEndDate(windowStart: String?, windowEnd: String?, now: Date) -> Date? {
        guard let endMinutes = minutesSinceMidnight(windowEnd) else { return nil }

        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = endMinutes / 60
        components.minute = endMinutes % 60
        components.second = 0
        guard var endDate = calendar.date(from: components) else { return nil }

        if let startMinutes = minutesSinceMidnight(windowStart),
           endMinutes < startMinutes {
            endDate = calendar.date(byAdding: .day, value: 1, to: endDate) ?? endDate
        }
        return endDate
    }

    private static func minutesSinceMidnight(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    private static func currentDayOfWeek() -> DayOfWeek {
        switch Calendar.current.component(.weekday, from: Date()) {
        case 1: return .sun
        case 2: return .mon
        case 3: return .tue
        case 4: return .wed
        case 5: return .thu
        case 6: return .fri
        default: return .sat
        }
    }
}

typealias ScheduledJourneyActivityAttributes = JourneyActivityShared.JourneyActivityAttributes

@MainActor
final class ScheduledLiveActivityAutoStartManager {
    static let shared = ScheduledLiveActivityAutoStartManager()

    private let suiteName = "group.dev.skynolimit.traintrack"
    private let recordsKey = "scheduled_live_activity_records"
    private let duplicateGuardInterval: TimeInterval = 30
    private let autoStartAlertType = "scheduled_live_activity_start"
    private var inFlightKeys: Set<String> = []

    private init() {}

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let trigger = ScheduledLiveActivityTrigger(userInfo: userInfo),
              trigger.alertType == autoStartAlertType else {
            ClientDiagnosticsLogger.log("scheduled_live_activity", "remote_trigger_ignored", metadata: [
                "alert_type": userInfo["alert_type"] as? String,
                "keys": userInfo.keys.map { String(describing: $0) }.sorted()
            ])
            return false
        }
        ClientDiagnosticsLogger.log("scheduled_live_activity", "remote_trigger_received", metadata: trigger.logMetadata)
        DebugLogStore.shared.log(
            """
            Scheduled start push received
            Route: \(trigger.from)→\(trigger.to)
            Schedule: \(trigger.scheduleKey)
            Window: \(trigger.windowStart)-\(trigger.windowEnd)
            """,
            category: "Scheduled"
        )
        let started = await startIfNeeded(for: trigger, overwriteExisting: true)
        ClientDiagnosticsLogger.log("scheduled_live_activity", "remote_trigger_finished", metadata: [
            "started": started,
            "schedule_key": trigger.scheduleKey,
            "from": trigger.from,
            "to": trigger.to
        ])
        DebugLogStore.shared.log(
            "Scheduled start push finished for \(trigger.from)→\(trigger.to): started=\(started)",
            category: "Scheduled"
        )
        return started
    }

    func startEligibleScheduledLiveActivities() async {
        let subscriptions = NotificationSubscriptionStore.shared.subscriptions
        let today = currentDayOfWeek()
        let now = Date()

        for subscription in subscriptions where subscription.daysOfWeek.contains(today) {
            for leg in subscription.legs where leg.enabled {
                guard isWithinWindow(now: now, start: leg.windowStart, end: leg.windowEnd) else { continue }
                guard let trigger = ScheduledLiveActivityTrigger(
                    subscriptionId: subscription.id,
                    routeKey: subscription.routeKey,
                    from: leg.from.uppercased(),
                    to: leg.to.uppercased(),
                    fromName: leg.fromName,
                    toName: leg.toName,
                    alertType: autoStartAlertType,
                    windowStart: leg.windowStart,
                    windowEnd: leg.windowEnd
                ) else {
                    continue
                }
                _ = await startIfNeeded(for: trigger, overwriteExisting: false)
            }
        }
    }

    func removeRecord(activityID: String) {
        var records = loadRecords()
        let originalCount = records.count
        records.removeAll { $0.activityID == activityID }
        guard records.count != originalCount else { return }
        saveRecords(records)
    }

    func clearRecords() {
        saveRecords([])
    }

    private func startIfNeeded(for trigger: ScheduledLiveActivityTrigger, overwriteExisting: Bool) async -> Bool {
        let scheduleKey = trigger.scheduleKey
        guard !scheduleKey.isEmpty else {
            ClientDiagnosticsLogger.log("scheduled_live_activity", "start_skipped_empty_schedule_key", metadata: trigger.logMetadata)
            return false
        }
        guard !inFlightKeys.contains(scheduleKey) else {
            ClientDiagnosticsLogger.log("scheduled_live_activity", "start_skipped_in_flight", metadata: trigger.logMetadata)
            return false
        }
        inFlightKeys.insert(scheduleKey)
        defer { inFlightKeys.remove(scheduleKey) }

        var records = pruneStaleRecords(loadRecords())
        if let existing = records.first(where: { $0.scheduleKey == scheduleKey }) {
            let existingIsActive = hasActiveActivity(id: existing.activityID)
            if existingIsActive,
               Date().timeIntervalSince(existing.startedAt) < duplicateGuardInterval || !overwriteExisting {
                let liveSessionID = await ensureLiveSessionIfNeeded(
                    existingLiveSessionID: existing.liveSessionID,
                    trigger: trigger,
                    journey: nil
                )
                if liveSessionID != existing.liveSessionID {
                    records.removeAll { $0.scheduleKey == scheduleKey }
                    records.append(existing.withLiveSessionID(liveSessionID))
                    saveRecords(records)
                }
                ClientDiagnosticsLogger.log("scheduled_live_activity", "start_skipped_existing_recent", metadata: [
                    "schedule_key": scheduleKey,
                    "activity_id": existing.activityID,
                    "live_session_id": liveSessionID,
                    "overwrite_existing": overwriteExisting
                ])
                DebugLogStore.shared.log(
                    "Scheduled start reused recent activity \(existing.activityID) for \(trigger.from)→\(trigger.to); live session=\(liveSessionID ?? "nil")",
                    category: "Scheduled"
                )
                return true
            }
            if existingIsActive {
                let liveSessionID = await ensureLiveSessionIfNeeded(
                    existingLiveSessionID: existing.liveSessionID,
                    trigger: trigger,
                    journey: nil
                )
                if liveSessionID != existing.liveSessionID {
                    records.removeAll { $0.scheduleKey == scheduleKey }
                    records.append(existing.withLiveSessionID(liveSessionID))
                    saveRecords(records)
                }
                ClientDiagnosticsLogger.log("scheduled_live_activity", "start_skipped_existing_active", metadata: [
                    "schedule_key": scheduleKey,
                    "activity_id": existing.activityID,
                    "live_session_id": liveSessionID
                ])
                DebugLogStore.shared.log(
                    "Scheduled start reused active activity \(existing.activityID) for \(trigger.from)→\(trigger.to); live session=\(liveSessionID ?? "nil")",
                    category: "Scheduled"
                )
                return true
            }
            await stopExisting(record: existing)
            records.removeAll { $0.scheduleKey == scheduleKey }
            saveRecords(records)
        }

        guard let journey = await makeJourney(from: trigger.from, to: trigger.to) else {
            ClientDiagnosticsLogger.log("scheduled_live_activity", "start_failed_make_journey", metadata: trigger.logMetadata)
            DebugLogStore.shared.log(
                "Scheduled start failed: could not build journey for \(trigger.from)→\(trigger.to)",
                category: "Scheduled"
            )
            return false
        }

        if LiveActivityManager.shared.isActive(for: journey) {
            let liveSessionID = await ensureLiveSessionIfNeeded(
                existingLiveSessionID: nil,
                trigger: trigger,
                journey: journey
            )
            ClientDiagnosticsLogger.log("scheduled_live_activity", "start_skipped_journey_already_active", metadata: trigger.logMetadata.merging([
                "live_session_id": liveSessionID
            ]) { _, new in new })
            DebugLogStore.shared.log(
                "Scheduled start found existing activity for \(trigger.from)→\(trigger.to); live session=\(liveSessionID ?? "nil")",
                category: "Scheduled"
            )
            return true
        }

        let liveSessionID = await ensureLiveSessionIfNeeded(
            existingLiveSessionID: nil,
            trigger: trigger,
            journey: journey
        )

        await LiveActivityManager.shared.start(
            for: journey,
            depStore: DeparturesStore.shared,
            triggeredByUser: false,
            bypassSuppression: true,
            allowAutomaticStart: true,
            journeyUpdatesEnabled: true,
            scheduleKey: trigger.scheduleKey,
            windowStart: trigger.windowStart,
            windowEnd: trigger.windowEnd
        )

        guard LiveActivityManager.shared.isActive(for: journey),
              let activityID = LiveActivityManager.shared.activityID(for: journey) else {
            ClientDiagnosticsLogger.log("scheduled_live_activity", "start_failed_after_request", metadata: trigger.logMetadata.merging([
                "live_session_id": liveSessionID
            ]) { _, new in new })
            DebugLogStore.shared.log(
                "Scheduled Live Activity request did not create an activity for \(trigger.from)→\(trigger.to); live session=\(liveSessionID ?? "nil")",
                category: liveSessionID == nil ? "Error" : "Scheduled"
            )
            return liveSessionID != nil
        }

        var updatedRecords = loadRecords()
        updatedRecords.removeAll { $0.scheduleKey == scheduleKey }
        updatedRecords.append(ScheduledLiveActivityRecord(
            scheduleKey: scheduleKey,
            routeKey: trigger.routeKey,
            from: trigger.from,
            to: trigger.to,
            windowStart: trigger.windowStart,
            windowEnd: trigger.windowEnd,
            activityID: activityID,
            liveSessionID: liveSessionID,
            startedAt: Date()
        ))
        saveRecords(updatedRecords)
        ClientDiagnosticsLogger.log("scheduled_live_activity", "start_succeeded", metadata: [
            "schedule_key": scheduleKey,
            "activity_id": activityID,
            "live_session_id": liveSessionID,
            "from": trigger.from,
            "to": trigger.to,
            "window_start": trigger.windowStart,
            "window_end": trigger.windowEnd
        ])
        DebugLogStore.shared.log(
            "Scheduled start active for \(trigger.from)→\(trigger.to): activity=\(activityID), live session=\(liveSessionID ?? "nil")",
            category: "Scheduled"
        )
        return true
    }

    private func ensureLiveSessionIfNeeded(
        existingLiveSessionID: String?,
        trigger: ScheduledLiveActivityTrigger,
        journey: Journey?
    ) async -> String? {
        await ScheduledNotificationLiveSessionRegistrar.ensureLiveSession(
            existingLiveSessionID: existingLiveSessionID,
            from: trigger.from,
            to: trigger.to,
            fromName: trigger.fromName ?? journey?.fromStation.name,
            toName: trigger.toName ?? journey?.toStation.name,
            scheduleKey: trigger.scheduleKey,
            windowStart: trigger.windowStart,
            windowEnd: trigger.windowEnd,
            source: "scheduled_auto_start",
            metadata: trigger.logMetadata
        )
    }

    private func stopExisting(record: ScheduledLiveActivityRecord) async {
        if let liveSessionID = record.liveSessionID {
            do {
                try await NotificationSubscriptionStore.shared.deleteLiveSession(id: liveSessionID)
            } catch {
                print("⚠️ [ScheduledLiveActivity] Failed to delete existing live session \(liveSessionID): \(error.localizedDescription)")
            }
        }
        if hasActiveActivity(id: record.activityID) {
            await LiveActivityManager.shared.stopActivity(activityID: record.activityID)
        }
    }

    private func makeJourney(from: String, to: String) async -> Journey? {
        if StationsService.shared.stations.isEmpty {
            try? await StationsService.shared.loadStations()
        }

        guard let fromStation = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(from) == .orderedSame }),
              let toStation = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(to) == .orderedSame }) else {
            return nil
        }

        return Journey(fromStation: fromStation, toStation: toStation, favorite: false)
    }

    private func hasActiveActivity(id: String) -> Bool {
        Activity<JourneyActivityAttributes>.activities.contains { $0.id == id }
    }

    private func isWithinWindow(now: Date, start: String, end: String) -> Bool {
        guard let startMinutes = minutes(from: start),
              let endMinutes = minutes(from: end) else {
            return false
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return nowMinutes >= startMinutes && nowMinutes <= endMinutes
    }

    private func minutes(from hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }
        return (hour * 60) + minute
    }

    private func currentDayOfWeek() -> DayOfWeek {
        switch Calendar.current.component(.weekday, from: Date()) {
        case 1: return .sun
        case 2: return .mon
        case 3: return .tue
        case 4: return .wed
        case 5: return .thu
        case 6: return .fri
        default: return .sat
        }
    }

    private func loadRecords() -> [ScheduledLiveActivityRecord] {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: recordsKey),
              let decoded = try? JSONDecoder().decode([ScheduledLiveActivityRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveRecords(_ records: [ScheduledLiveActivityRecord]) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(records) else {
            return
        }
        defaults.set(data, forKey: recordsKey)
    }

    private func pruneStaleRecords(_ records: [ScheduledLiveActivityRecord]) -> [ScheduledLiveActivityRecord] {
        let todayKey = ScheduledLiveActivityTrigger.currentDateKey()
        let filtered = records.filter { record in
            let keyParts = record.scheduleKey.split(separator: "|")
            guard let datePart = keyParts.last else { return false }
            return String(datePart) == todayKey
        }
        if filtered.count != records.count {
            saveRecords(filtered)
        }
        return filtered
    }
}

private struct ScheduledLiveActivityTrigger {
    let subscriptionId: String?
    let routeKey: String
    let from: String
    let to: String
    let fromName: String?
    let toName: String?
    let alertType: String?
    let windowStart: String
    let windowEnd: String

    var scheduleKey: String {
        "\(from.uppercased())-\(to.uppercased())|\(windowStart)|\(windowEnd)|\(Self.currentDateKey())"
    }

    var logMetadata: [String: Any?] {
        [
            "subscription_id": subscriptionId,
            "route_key": routeKey,
            "from": from,
            "to": to,
            "from_name": fromName,
            "to_name": toName,
            "alert_type": alertType,
            "window_start": windowStart,
            "window_end": windowEnd,
            "schedule_key": scheduleKey
        ]
    }

    init?(
        subscriptionId: String?,
        routeKey: String?,
        from: String?,
        to: String?,
        fromName: String?,
        toName: String?,
        alertType: String?,
        windowStart: String?,
        windowEnd: String?
    ) {
        guard let routeKey, !routeKey.isEmpty,
              let from, !from.isEmpty,
              let to, !to.isEmpty,
              let windowStart, !windowStart.isEmpty,
              let windowEnd, !windowEnd.isEmpty else {
            return nil
        }
        self.subscriptionId = subscriptionId
        self.routeKey = routeKey
        self.from = from.uppercased()
        self.to = to.uppercased()
        self.fromName = fromName
        self.toName = toName
        self.alertType = alertType
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }

    init?(userInfo: [AnyHashable: Any]) {
        self.init(
            subscriptionId: Self.stringValue(NotificationPayloadKeys.subscriptionId, in: userInfo),
            routeKey: Self.stringValue(NotificationPayloadKeys.routeKey, in: userInfo),
            from: Self.stringValue(NotificationPayloadKeys.from, in: userInfo),
            to: Self.stringValue(NotificationPayloadKeys.to, in: userInfo),
            fromName: Self.stringValue(NotificationPayloadKeys.fromName, in: userInfo),
            toName: Self.stringValue(NotificationPayloadKeys.toName, in: userInfo),
            alertType: Self.stringValue(NotificationPayloadKeys.alertType, in: userInfo),
            windowStart: Self.stringValue(NotificationPayloadKeys.windowStart, in: userInfo),
            windowEnd: Self.stringValue(NotificationPayloadKeys.windowEnd, in: userInfo)
        )
    }

    private static func stringValue(_ key: String, in userInfo: [AnyHashable: Any]) -> String? {
        if let value = userInfo[key] as? String { return value }
        if let value = userInfo[key] as? NSString { return value as String }
        return nil
    }

    static func currentDateKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

private struct ScheduledLiveActivityRecord: Codable {
    let scheduleKey: String
    let routeKey: String
    let from: String
    let to: String
    let windowStart: String
    let windowEnd: String
    let activityID: String
    let liveSessionID: String?
    let startedAt: Date

    func withLiveSessionID(_ liveSessionID: String?) -> ScheduledLiveActivityRecord {
        ScheduledLiveActivityRecord(
            scheduleKey: scheduleKey,
            routeKey: routeKey,
            from: from,
            to: to,
            windowStart: windowStart,
            windowEnd: windowEnd,
            activityID: activityID,
            liveSessionID: liveSessionID,
            startedAt: startedAt
        )
    }
}
