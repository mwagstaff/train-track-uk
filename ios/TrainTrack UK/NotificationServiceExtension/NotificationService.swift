import UserNotifications

/// Notification Service Extension that intercepts remote notifications before they're displayed
/// This allows us to filter out muted notifications client-side as a backup to the backend mute
class NotificationService: UNNotificationServiceExtension {

    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttemptContent: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        if let bestAttemptContent = bestAttemptContent {
            ensureCategoriesRegistered()
            enhanceNotificationIfNeeded(content: bestAttemptContent)
            // Check if this notification should be muted based on local arrival tracking
            if shouldMuteNotification(content: bestAttemptContent) {
                // Don't deliver the notification
                contentHandler(UNNotificationContent())
                return
            }

            // Deliver the notification as-is
            contentHandler(bestAttemptContent)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        if let contentHandler = contentHandler, let bestAttemptContent = bestAttemptContent {
            contentHandler(bestAttemptContent)
        }
    }

    private func shouldMuteNotification(content: UNNotificationContent) -> Bool {
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

        UNUserNotificationCenter.current().setNotificationCategories([journeyCategory, arrivalCategory])
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

    private func currentDateKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
