import ActivityKit
import Foundation
import JourneyActivityShared
import UserNotifications

private typealias NotificationJourneyActivityAttributes = JourneyActivityShared.JourneyActivityAttributes

/// Notification Service Extension that intercepts remote notifications before they're displayed
/// This allows us to filter out muted notifications client-side as a backup to the backend mute
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?
    private let completionLock = NSLock()
    private var suppressOnExpiry = false

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        NotificationServiceDiagnosticsLogger.log("did_receive", metadata: diagnosticMetadata(for: request.content, identifier: request.identifier))

        if let bestAttemptContent = bestAttemptContent {
            ensureCategoriesRegistered()
            enhanceNotificationIfNeeded(content: bestAttemptContent)
            if shouldSuppressScheduledSummaryOutsideWindow(content: bestAttemptContent) {
                NotificationServiceDiagnosticsLogger.log("suppressed_outside_window", metadata: diagnosticMetadata(for: bestAttemptContent, identifier: request.identifier))
                finish(with: UNNotificationContent())
                return
            }
            if let lifecycle = dismissedPendingActivity(for: bestAttemptContent) {
                suppressOnExpiry = true
                NotificationServiceDiagnosticsLogger.log("suppressed_dismissed_pending_activity", metadata: diagnosticMetadata(for: bestAttemptContent, identifier: request.identifier).merging([
                    "activity_id": lifecycle.activityID,
                    "journey_phase": lifecycle.phase.rawValue,
                    "live_session_id": lifecycle.liveSessionID
                ]) { _, new in new })
                Task {
                    let dismissed = await self.dismissScheduledJourney(
                        scheduleKey: lifecycle.scheduleKey,
                        fallbackLiveSessionID: lifecycle.liveSessionID
                    )
                    NotificationServiceDiagnosticsLogger.log("dismissed_pending_activity_cleanup", metadata: self.diagnosticMetadata(for: bestAttemptContent, identifier: request.identifier).merging([
                        "activity_id": lifecycle.activityID,
                        "live_session_id": lifecycle.liveSessionID,
                        "server_cleanup_succeeded": dismissed
                    ]) { _, new in new })
                    self.finish(with: UNNotificationContent())
                }
                return
            }
            // Check if this notification should be muted based on local arrival tracking
            if shouldMuteNotification(content: bestAttemptContent) {
                // Don't deliver the notification
                NotificationServiceDiagnosticsLogger.log("suppressed_muted_leg", metadata: diagnosticMetadata(for: bestAttemptContent, identifier: request.identifier))
                finish(with: UNNotificationContent())
                return
            }

            // Deliver the notification as-is
            NotificationServiceDiagnosticsLogger.log("delivered", metadata: diagnosticMetadata(for: bestAttemptContent, identifier: request.identifier))
            finish(with: bestAttemptContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let bestAttemptContent = bestAttemptContent {
            NotificationServiceDiagnosticsLogger.log("time_will_expire", metadata: diagnosticMetadata(for: bestAttemptContent, identifier: nil))
            finish(with: suppressOnExpiry ? UNNotificationContent() : bestAttemptContent)
        }
    }

    private func finish(with content: UNNotificationContent) {
        completionLock.lock()
        let handler = contentHandler
        contentHandler = nil
        completionLock.unlock()
        handler?(content)
    }

    private func dismissedPendingActivity(
        for content: UNNotificationContent,
        now: Date = Date()
    ) -> JourneyActivityLifecycleRecord? {
        guard let scheduleKey = stringValue(for: "schedule_key", in: content.userInfo) else {
            return nil
        }

        let savedRecord = JourneyActivityLifecycleStore.record(scheduleKey: scheduleKey, now: now)
        if let activity = Activity<NotificationJourneyActivityAttributes>.activities.first(where: {
            $0.content.state.scheduleKey == scheduleKey || $0.id == savedRecord?.activityID
        }) {
            let state = activity.content.state
            JourneyActivityLifecycleStore.update(activityID: activity.id, state: state, now: now)
            guard activity.activityState == .dismissed || activity.activityState == .ended,
                  state.journeyPhase == .pendingStart else {
                return nil
            }
            JourneyActivityLifecycleStore.markDismissedBeforeStart(activityID: activity.id, now: now)
            return JourneyActivityLifecycleStore.record(scheduleKey: scheduleKey, now: now)
        }

        if let savedRecord {
            if savedRecord.dismissedBeforeStart {
                return savedRecord
            }
            // Avoid treating a just-created activity as dismissed while ActivityKit is
            // still making it visible to the extension process.
            guard savedRecord.phase == .pendingStart,
                  now.timeIntervalSince(savedRecord.updatedAt) >= 5 else {
                return nil
            }
            JourneyActivityLifecycleStore.markDismissedBeforeStart(activityID: savedRecord.activityID, now: now)
            return JourneyActivityLifecycleStore.record(scheduleKey: scheduleKey, now: now) ?? savedRecord
        }

        guard boolValue(for: "live_activity_auto_started", in: content.userInfo),
              let startedAtText = stringValue(for: "live_activity_auto_started_at", in: content.userInfo),
              let startedAt = iso8601Date(from: startedAtText),
              now.timeIntervalSince(startedAt) >= 5,
              let fromCRS = stringValue(for: "from", in: content.userInfo),
              let toCRS = stringValue(for: "to", in: content.userInfo) else {
            return nil
        }
        JourneyActivityLifecycleStore.seedPendingRemoteStart(
            scheduleKey: scheduleKey,
            fromCRS: fromCRS,
            toCRS: toCRS,
            startedAt: startedAt
        )
        guard let seededRecord = JourneyActivityLifecycleStore.record(scheduleKey: scheduleKey, now: now) else {
            return nil
        }
        JourneyActivityLifecycleStore.markDismissedBeforeStart(activityID: seededRecord.activityID, now: now)
        return JourneyActivityLifecycleStore.record(scheduleKey: scheduleKey, now: now) ?? seededRecord
    }

    private func dismissScheduledJourney(
        scheduleKey: String,
        fallbackLiveSessionID: String?
    ) async -> Bool {
        guard let defaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack"),
              let deviceID = defaults.string(forKey: "device_token"), !deviceID.isEmpty,
              let url = URL(string: "\(apiBaseURL(defaults: defaults))/notifications/scheduled/dismiss") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": deviceID,
            "schedule_key": scheduleKey
        ])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            if (200..<300).contains(httpResponse.statusCode) {
                return true
            }
        } catch {
            // Fall through to the older live-session cleanup as a best effort.
        }
        return await deleteLiveSession(fallbackLiveSessionID, defaults: defaults, deviceID: deviceID)
    }

    private func deleteLiveSession(
        _ liveSessionID: String?,
        defaults: UserDefaults,
        deviceID: String
    ) async -> Bool {
        guard let liveSessionID, !liveSessionID.isEmpty,
              let url = URL(string: "\(apiBaseURL(defaults: defaults))/notifications/live_sessions") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "device_id": deviceID,
            "subscription_id": liveSessionID
        ])
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
        } catch {
            return false
        }
    }

    private func boolValue(for key: String, in userInfo: [AnyHashable: Any]) -> Bool {
        if let value = userInfo[key] as? Bool { return value }
        if let value = userInfo[key] as? NSNumber { return value.boolValue }
        if let value = stringValue(for: key, in: userInfo) {
            return value.caseInsensitiveCompare("true") == .orderedSame || value == "1"
        }
        return false
    }

    private func iso8601Date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private func apiBaseURL(defaults: UserDefaults) -> String {
        #if DEBUG
        if defaults.string(forKey: "api_host_preference") == "dev" {
            return "http://Mikes-MacBook-Air.local:3000/api/v2"
        }
        #endif
        return "https://api.skynolimit.dev/train-track/api/v2"
    }

    private func shouldSuppressScheduledSummaryOutsideWindow(content: UNNotificationContent, now: Date = Date()) -> Bool {
        guard stringValue(for: "alert_type", in: content.userInfo) == "summary",
              let windowStart = stringValue(for: "window_start", in: content.userInfo),
              let windowEnd = stringValue(for: "window_end", in: content.userInfo),
              let startMinutes = minutes(from: windowStart),
              let endMinutes = minutes(from: windowEnd) else {
            return false
        }

        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMinutes = ((components.hour ?? 0) * 60) + (components.minute ?? 0)
        return nowMinutes < startMinutes || nowMinutes > endMinutes
    }

    private func shouldMuteNotification(content: UNNotificationContent) -> Bool {
        if let alertType = content.userInfo["alert_type"] as? String,
           shouldAlwaysDeliver(alertType: alertType) {
            return false
        }

        if let fromStation = content.userInfo["from"] as? String,
           let toStation = content.userInfo["to"] as? String {
            return isLegMutedToday(from: fromStation, to: toStation)
        }

        // Fallback: Extract station codes from the notification title
        // Expected format: "Station A → Station B" or similar
        guard let title = content.title as String? else { return false }

        // Try to extract station codes from the title
        // This is a simple heuristic - we look for the arrow pattern
        let components = title.components(separatedBy: " → ")
        guard components.count >= 2 else { return false }

        let fromStation = components[0].trimmingCharacters(in: .whitespaces)
        let toStation = components[1].trimmingCharacters(in: .whitespaces)

        // Check if this leg was muted today
        return isLegMutedToday(from: fromStation, to: toStation)
    }

    private func enhanceNotificationIfNeeded(content: UNMutableNotificationContent) {
        if content.categoryIdentifier.isEmpty {
            if content.userInfo["from"] != nil || content.userInfo["to"] != nil || content.title.contains(" → ") {
                content.categoryIdentifier = "JOURNEY_LEG_ALERT"
            }
        }

        if content.userInfo["from_name"] == nil || content.userInfo["to_name"] == nil {
            let components = content.title.components(separatedBy: " → ")
            if components.count >= 2 {
                var info = content.userInfo
                if info["from_name"] == nil {
                    info["from_name"] = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if info["to_name"] == nil {
                    info["to_name"] = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                }
                content.userInfo = info
            }
        }
    }

    private func ensureCategoriesRegistered() {
        let muteAction = UNNotificationAction(
            identifier: "MUTE_LEG_TODAY",
            title: "Mute this journey",
            options: [.foreground]
        )

        let journeyCategory = UNNotificationCategory(
            identifier: "JOURNEY_LEG_ALERT",
            actions: [muteAction],
            intentIdentifiers: [],
            options: []
        )

        let arrivalCategory = UNNotificationCategory(
            identifier: "STATION_ARRIVAL",
            actions: [muteAction],
            intentIdentifiers: [],
            options: []
        )

        let activationCategory = UNNotificationCategory(
            identifier: "JOURNEY_UPDATES_ACTIVATION",
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([journeyCategory, arrivalCategory, activationCategory])
    }

    private func isLegMutedToday(from: String, to: String) -> Bool {
        // Access shared UserDefaults to check mute status
        guard let sharedDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") else {
            return false
        }

        // Get muted legs dictionary: [legKey: dateString]
        guard let mutedLegs = sharedDefaults.dictionary(forKey: "mutedLegsToday") as? [String: String] else {
            return false
        }

        // Create leg keys to check (both with station names and CRS codes)
        let possibleKeys = [
            "\(from)-\(to)",
            "\(from.uppercased())-\(to.uppercased())"
        ]

        let todayString = currentDateKey()

        // Check if any of the possible leg keys are muted for today
        for key in possibleKeys {
            if let mutedDate = mutedLegs[key], mutedDate == todayString {
                return true
            }
        }

        return false
    }

    private func stringValue(for key: String, in userInfo: [AnyHashable: Any]) -> String? {
        if let value = userInfo[key] as? String { return value }
        if let value = userInfo[key] as? NSString { return value as String }
        return nil
    }

    private func diagnosticMetadata(for content: UNNotificationContent, identifier: String?) -> [String: Any?] {
        [
            "identifier": identifier,
            "title": content.title,
            "subtitle": content.subtitle,
            "body": content.body,
            "diagnostic_marker": stringValue(for: "diagnostic_marker", in: content.userInfo),
            "diagnostic_channel": stringValue(for: "diagnostic_channel", in: content.userInfo),
            "diagnostic_event": stringValue(for: "diagnostic_event", in: content.userInfo),
            "alert_type": stringValue(for: "alert_type", in: content.userInfo),
            "aps_event": apsStringValue(for: "event", in: content.userInfo),
            "from": stringValue(for: "from", in: content.userInfo),
            "to": stringValue(for: "to", in: content.userInfo),
            "from_name": stringValue(for: "from_name", in: content.userInfo),
            "to_name": stringValue(for: "to_name", in: content.userInfo),
            "route_key": stringValue(for: "route_key", in: content.userInfo),
            "leg_key": stringValue(for: "leg_key", in: content.userInfo),
            "schedule_key": stringValue(for: "schedule_key", in: content.userInfo),
            "subscription_id": stringValue(for: "subscription_id", in: content.userInfo),
            "live_activity_auto_started": boolValue(for: "live_activity_auto_started", in: content.userInfo),
            "live_activity_auto_started_at": stringValue(for: "live_activity_auto_started_at", in: content.userInfo),
            "window_start": stringValue(for: "window_start", in: content.userInfo),
            "window_end": stringValue(for: "window_end", in: content.userInfo),
            "category": content.categoryIdentifier,
            "keys": content.userInfo.keys.map { String(describing: $0) }.sorted()
        ]
    }

    private func apsStringValue(for key: String, in userInfo: [AnyHashable: Any]) -> String? {
        guard let aps = userInfo["aps"] as? [AnyHashable: Any] else { return nil }
        if let value = aps[key] as? String { return value }
        if let value = aps[key] as? NSString { return value as String }
        return nil
    }

    private func minutes(from hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return (hour * 60) + minute
    }

    private func shouldAlwaysDeliver(alertType: String) -> Bool {
        switch alertType {
        case "muted_greeting", "muted_status":
            return true
        default:
            return false
        }
    }

    private func currentDateKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
