import SwiftUI

// Shared helper to apply the modern containerBackground on iOS 17+
// while keeping iOS 16.x compatibility for the widget extension.
extension View {
    @ViewBuilder
    func widgetContainerBackground() -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(.fill.tertiary, for: .widget)
        } else {
            self.background(Color.clear)
        }
    }
}

