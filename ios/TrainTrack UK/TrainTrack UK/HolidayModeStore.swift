import SwiftUI
import Combine
import WidgetKit

@MainActor
final class HolidayModeStore: ObservableObject {
    static let shared = HolidayModeStore()

    @Published private(set) var isEnabled: Bool

    private static let defaultsKey = "holidayModeEnabled"
    // Shared with the widget extension so widgets can show a paused state.
    private static let store: UserDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard

    private init() {
        isEnabled = Self.store.bool(forKey: Self.defaultsKey)
    }

    func setEnabled(_ enabled: Bool) {
        let previous = isEnabled
        guard enabled != previous else { return }
        apply(enabled)
        Task {
            do {
                try await NotificationSubscriptionService.shared.setHolidayMode(enabled: enabled)
            } catch {
                // The server didn't record the change, so scheduled notifications
                // wouldn't actually pause/resume. Revert so the UI stays honest.
                apply(previous)
                ToastStore.shared.show(
                    enabled
                        ? "Couldn't enable holiday mode. Please try again."
                        : "Couldn't disable holiday mode. Please try again.",
                    icon: "exclamationmark.triangle"
                )
            }
        }
    }

    /// Best-effort re-send of the current state so the server stays in step
    /// (e.g. after server-side data loss). Called when the app becomes active.
    func syncWithServer() async {
        try? await NotificationSubscriptionService.shared.setHolidayMode(enabled: isEnabled)
    }

    private func apply(_ enabled: Bool) {
        isEnabled = enabled
        Self.store.set(enabled, forKey: Self.defaultsKey)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
