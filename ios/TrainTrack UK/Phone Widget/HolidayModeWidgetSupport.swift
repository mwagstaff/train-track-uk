import SwiftUI
import WidgetKit

// Holiday-mode flag written by the app via the shared App Group. While
// enabled, journey widgets skip fetching departures and show a paused state.
enum WidgetHolidayMode {
    static var isEnabled: Bool {
        (UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard)
            .bool(forKey: "holidayModeEnabled")
    }
}

// Placeholder shown by journey widgets while holiday mode is on.
struct HolidayModePausedView: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "beach.umbrella")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text("Holiday mode")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Updates paused")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetContainerBackground()
    }
}
