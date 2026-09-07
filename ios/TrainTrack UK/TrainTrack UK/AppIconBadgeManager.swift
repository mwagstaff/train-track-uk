import UserNotifications

enum AppIconBadgeManager {
    static func update(isJourneyInProgress: Bool) async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(
                isJourneyInProgress ? 1 : 0
            )
        } catch {
            debugLog("🔴 [App Badge] Failed to update journey badge: \(error.localizedDescription)")
        }
    }
}
