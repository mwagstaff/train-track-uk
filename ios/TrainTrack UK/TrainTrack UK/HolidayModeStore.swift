import SwiftUI
import Combine
import UserNotifications

@MainActor
final class HolidayModeStore: ObservableObject {
    static let shared = HolidayModeStore()

    @Published private(set) var isEnabled: Bool

    private static let defaultsKey = "holidayModeEnabled"

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        Task {
            if enabled {
                async let serverSync: Void = syncToServer()
                async let localTermination: Void = terminateExistingJourneyUpdates()
                _ = await (serverSync, localTermination)
            } else {
                await syncToServer()
            }
        }
    }

    // Re-sends the current local state to the server. Called on toggle and again
    // each time the app becomes active, so a transient network failure doesn't
    // leave the server out of sync with what the banner is showing on-device.
    func syncToServer() async {
        do {
            try await NotificationSubscriptionService.shared.setHolidayMode(enabled: isEnabled)
        } catch {
            print("⚠️ [HolidayMode] Failed to sync holiday mode to server: \(error.localizedDescription)")
        }
    }

    private func terminateExistingJourneyUpdates() async {
        await LiveActivityManager.shared.stop()
        await NotificationSubscriptionStore.shared.deleteAllLiveSessions()
        ScheduledLiveActivityAutoStartManager.shared.clearRecords()

        let notificationCenter = UNUserNotificationCenter.current()
        notificationCenter.removeAllPendingNotificationRequests()
        notificationCenter.removeAllDeliveredNotifications()
    }
}
