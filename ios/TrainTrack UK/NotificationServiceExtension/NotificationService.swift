import UserNotifications

/// Notification Service Extension that intercepts remote notifications before they're displayed
/// This allows us to filter out muted notifications client-side as a backup to the backend mute
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        NotificationServiceDiagnosticsLogger.log("did_receive", metadata: diagnosticMetadata(for: request.content, identifier: request.identifier))

        if let bestAttemptContent = bestAttemptContent {
            ensureCategoriesRegistered()
            enhanceNotificationIfNeeded(content: bestAttemptContent)
            if shouldSuppressScheduledSummaryOutsideWindow(content: bestAttemptContent) {
                NotificationServiceDiagnosticsLogger.log("suppressed_outside_window", metadata: diagnosticMetadata(for: bestAttemptContent, identifier: request.identifier))
                contentHandler(UNNotificationContent())
                return
            }
            // Check if this notification should be muted based on local arrival tracking
            if shouldMuteNotification(content: bestAttemptContent) {
                // Don't deliver the notification
                NotificationServiceDiagnosticsLogger.log("suppressed_muted_leg", metadata: diagnosticMetadata(for: bestAttemptContent, identifier: request.identifier))
                contentHandler(UNNotificationContent())
                return
            }

            // Deliver the notification as-is
            NotificationServiceDiagnosticsLogger.log("delivered", metadata: diagnosticMetadata(for: bestAttemptContent, identifier: request.identifier))
            contentHandler(bestAttemptContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            NotificationServiceDiagnosticsLogger.log("time_will_expire", metadata: diagnosticMetadata(for: bestAttemptContent, identifier: nil))
            contentHandler(bestAttemptContent)
        }
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
            title: "Mute for today",
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
