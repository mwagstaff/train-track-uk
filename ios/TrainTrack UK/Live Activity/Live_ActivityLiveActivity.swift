//
//  Live_ActivityLiveActivity.swift
//  Live Activity
//
//  Created by Mike Wagstaff on 27/11/2025.
//

import ActivityKit
import WidgetKit
import SwiftUI
import JourneyActivityShared
import UIKit

struct Live_ActivityLiveActivity: Widget {
    private func deepLinkURL(for context: ActivityViewContext<JourneyActivityAttributes>) -> URL? {
        var components = URLComponents()
        components.scheme = "traintrack"
        components.host = "journey"
        components.queryItems = [
            URLQueryItem(name: "from", value: context.state.fromCRS),
            URLQueryItem(name: "to", value: context.state.toCRS)
        ]
        return components.url
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: JourneyActivityAttributes.self) { context in
            // Lock screen/banner UI
            LiveActivityLockScreenView(state: context.state, attributes: context.attributes)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Platform")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        PlatformPill(platform: context.state.platform, font: .title2)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Departs")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        PrimaryDepartureTimeText(
                            state: context.state,
                            font: .title2,
                            weight: .bold
                        )
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        HStack {
                            Text(context.state.destinationTitle)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Spacer()
                            if context.state.isCancelled {
                                Text("Cancelled")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.red)
                            } else if let length = context.state.length, length > 0 {
                                Text("\(length) cars")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let status = primaryStatusText(for: context.state) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(statusColor(context.state.delayMinutes))
                                    .frame(width: 6, height: 6)
                                Text(status)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                Spacer()
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                HStack(spacing: 4) {
                    Image(systemName: "train.side.front.car")
                        .font(.caption2)
                    PlatformPill(platform: context.state.platform, font: .caption, horizontalPadding: 6, verticalPadding: 1.5)
                }
            } compactTrailing: {
                PrimaryDepartureTimeText(
                    state: context.state,
                    font: .caption,
                    weight: .semibold
                )
            } minimal: {
                Image(systemName: "train.side.front.car")
                    .font(.caption2)
            }
            .keylineTint(primaryAccentColor(for: context.state))
            .widgetURL(deepLinkURL(for: context))
        }
    }
}

// MARK: - Lock Screen View
struct LiveActivityLockScreenView: View {
    let state: JourneyActivityAttributes.ContentState
    let attributes: JourneyActivityAttributes

    private var deepLinkURL: URL? {
        var components = URLComponents()
        components.scheme = "traintrack"
        components.host = "journey"
        components.queryItems = [
            URLQueryItem(name: "from", value: state.fromCRS),
            URLQueryItem(name: "to", value: state.toCRS)
        ]
        return components.url
    }

    var body: some View {
        VStack(spacing: 12) {
            // Header with journey name and optional app-active indicator
            HStack {
                Image(systemName: "train.side.front.car")
                    .font(.headline)
                Text(attributes.displayName)
                    .font(.headline)
                    .fontWeight(.semibold)
                Spacer()
                // Navigation arrow: shown when the app is open and tracking
                if state.appIsActive {
                    Image(systemName: "location.north.fill")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            // Main departure info
            HStack(alignment: .top, spacing: 12) {

                // Departure time
                VStack(alignment: .leading, spacing: 4) {
                    Text("Departs")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    PrimaryDepartureTimeText(
                        state: state,
                        font: .title,
                        weight: .bold
                    )
                }

                Spacer()

                // Destination & Details
                VStack(alignment: .trailing, spacing: 4) {
                    Text(state.destinationTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let arrivalLabel = state.arrivalLabel {
                        Text(arrivalLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    if state.isCancelled {
                        Text("Cancelled")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.red)
                    } else if let length = state.length, length > 0 {
                        Text("\(length) cars")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Platform number
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Platform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    PlatformPill(platform: state.platform, font: .title, horizontalPadding: 10, verticalPadding: 3)
                }
            }

            // Live status
            if let status = primaryStatusText(for: state) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor(state.delayMinutes))
                        .frame(width: 10, height: 10)
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.top, 4)
            }

            // Upcoming departures
            if !state.upcomingDepartures.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(state.upcomingDepartures.prefix(3).enumerated()), id: \.offset) { _, departure in
                        HStack(spacing: 10) {
                            HStack(spacing: 2) {
                                if departure.hasFasterLaterService {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 8))
                                        .foregroundStyle(.yellow)
                                }
                                Text(departure.time)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .monospacedDigit()
                                    .foregroundColor(departure.isCancelled ? .red : estimatedTimeColor(departure.delayMinutes))
                                    .strikethrough(departure.isCancelled, color: .red)
                            }

                            // Show platform badge if available, otherwise show TBC
                            PlatformPill(
                                platform: (departure.platform?.isEmpty ?? true) ? "TBC" : departure.platform!,
                                font: .system(size:10),
                                horizontalPadding: 2,
                                verticalPadding: 0.5
                            )
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(16)
        .widgetURL(deepLinkURL)
    }
}

// MARK: - Helper Functions
private func colorFromHex(_ hex: String) -> Color {
    var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if hexSanitized.hasPrefix("#") { hexSanitized.removeFirst() }
    guard hexSanitized.count == 6,
          let intCode = Int(hexSanitized, radix: 16) else {
        return Color.black
    }
    let r = Double((intCode >> 16) & 0xFF) / 255.0
    let g = Double((intCode >> 8) & 0xFF) / 255.0
    let b = Double(intCode & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

private func platformIsColorable(_ raw: String) -> Bool {
    let p = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return !p.isEmpty && p != "TBC" && p != "BUS"
}

private func platformColor(for platform: String) -> Color {
    let palette: [String] = [
        "#FF6B6B", "#4ECDC4", "#45B7D1", "#96CEB4", "#FFEAA7",
        "#DDA0DD", "#98D8C8", "#F7DC6F", "#BB8FCE", "#85C1E9",
        "#F8C471", "#82E0AA", "#F1948A", "#85C1E9", "#F7DC6F",
        "#D7BDE2", "#A9DFBF", "#FAD7A0", "#AED6F1", "#F9E79F"
    ]

    let trimmed = platform.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = trimmed.filter { $0.isNumber }
    var index: Int? = nil
    if !digits.isEmpty { index = Int(digits) }
    else {
        let letters = trimmed.filter { $0.isLetter }.uppercased()
        if !letters.isEmpty {
            var hash = 0
            for u in letters.unicodeScalars {
                hash = Int(u.value) + ((hash << 5) - hash)
            }
            index = abs(hash)
        }
    }

    guard let i = index, !palette.isEmpty else { return Color.black }
    let hex = palette[i % palette.count]
    return colorFromHex(hex)
}

private struct PlatformPill: View {
    let platform: String
    var font: Font = .headline
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 2

    private var trimmed: String {
        let t = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "TBC" : t
    }

    var body: some View {
        let upper = trimmed.uppercased()
        let isBus = upper == "BUS"
        if isBus {
            HStack(spacing: 2) {
                Image(systemName: "bus")
                    .font(font)
                Text("Bus")
                    .font(font)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .fontWeight(.semibold)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(Color.yellow)
            .foregroundStyle(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            let colorable = platformIsColorable(trimmed)
            let bg: Color = colorable ? platformColor(for: platform) : Color.gray.opacity(0.18)
            let fg: Color = colorable ? .black : .secondary
            Text(trimmed)
                .font(font)
                .fontWeight(.semibold)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(bg)
                .foregroundStyle(fg)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .lineLimit(1)
        }
    }
}

private struct PrimaryDepartureTimeText: View {
    let state: JourneyActivityAttributes.ContentState
    let font: Font
    let weight: Font.Weight

    private var text: String {
        if state.isCancelled {
            return state.scheduledDeparture ?? state.estimated
        }
        return state.estimated
    }

    var body: some View {
        Text(text)
            .font(font)
            .fontWeight(weight)
            .monospacedDigit()
            .foregroundStyle(primaryAccentColor(for: state))
            .strikethrough(state.isCancelled, color: .red)
    }
}

private func estimatedTimeColor(_ delayMinutes: Int) -> Color {
    if delayMinutes >= 5 {
        return .red
    } else if delayMinutes > 0 {
        return .orange
    }
    return .green
}

private func statusColor(_ delayMinutes: Int) -> Color {
    if delayMinutes >= 5 {
        return .red
    } else if delayMinutes > 0 {
        return .yellow
    }
    return .green
}

private func primaryAccentColor(for state: JourneyActivityAttributes.ContentState) -> Color {
    if state.isCancelled {
        return .red
    }
    return estimatedTimeColor(state.delayMinutes)
}

private func primaryStatusText(for state: JourneyActivityAttributes.ContentState) -> String? {
    guard let status = state.statusText?.trimmingCharacters(in: .whitespacesAndNewlines),
          !status.isEmpty else {
        return nil
    }
    if state.isCancelled && status.caseInsensitiveCompare("Cancelled") == .orderedSame {
        return nil
    }
    return status
}

private func formatLastUpdated(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
}


// Resolve the live activity icon with extra logging to catch bundle/name issues.
private func resolvedIconImage() -> Image? {
    if let uiImage = UIImage(named: "LiveActivityIcon") {
        return Image(uiImage: uiImage)
    }
    // Extra fallback: look up in the bundle by path and log once.
    if let path = Bundle.main.path(forResource: "LiveActivityIcon", ofType: "png"),
       let uiImage = UIImage(contentsOfFile: path) {
        print("✅ [LiveActivity] Loaded LiveActivityIcon via path lookup")
        return Image(uiImage: uiImage)
    }
    print("⚠️ [LiveActivity] LiveActivityIcon not found in bundle; using SF Symbol fallback")
    return nil
}

// MARK: - Previews
extension JourneyActivityAttributes {
    fileprivate static var preview: JourneyActivityAttributes {
        JourneyActivityAttributes(displayName: "VIC → KTH")
    }
}

extension JourneyActivityAttributes.ContentState {
    fileprivate static var onTime: JourneyActivityAttributes.ContentState {
        JourneyActivityAttributes.ContentState(
            fromCRS: "VIC",
            toCRS: "KTH",
            destinationTitle: "Kent House",
            arrivalLabel: "Arr 09:47",
            scheduledDeparture: "09:35",
            length: 8,
            platform: "2",
            estimated: "09:35",
            isCancelled: false,
            statusText: "Currently on time, between Clapham Junction and Battersea Park",
            delayMinutes: 0,
            upcomingDepartures: [
                JourneyActivityAttributes.UpcomingDeparture(time: "09:50", delayMinutes: 0, isCancelled: false, platform: "2", hasFasterLaterService: false),
                JourneyActivityAttributes.UpcomingDeparture(time: "10:05", delayMinutes: 3, isCancelled: false, platform: "3", hasFasterLaterService: true),
                JourneyActivityAttributes.UpcomingDeparture(time: "10:20", delayMinutes: 0, isCancelled: false, platform: "2", hasFasterLaterService: false)
            ]
        )
    }

    fileprivate static var delayed: JourneyActivityAttributes.ContentState {
        JourneyActivityAttributes.ContentState(
            fromCRS: "VIC",
            toCRS: "KTH",
            destinationTitle: "Orpington via Bromley South",
            arrivalLabel: "Arr 10:12",
            scheduledDeparture: "09:48",
            length: 4,
            platform: "15",
            estimated: "09:48",
            isCancelled: false,
            statusText: "Currently 7 minutes late, approaching London Victoria",
            delayMinutes: 7,
            upcomingDepartures: [
                JourneyActivityAttributes.UpcomingDeparture(time: "10:03", delayMinutes: 0, isCancelled: false, platform: "15", hasFasterLaterService: false),
                JourneyActivityAttributes.UpcomingDeparture(time: "10:18", delayMinutes: 0, isCancelled: true, platform: "14", hasFasterLaterService: false),
                JourneyActivityAttributes.UpcomingDeparture(time: "10:33", delayMinutes: 8, isCancelled: false, platform: "15", hasFasterLaterService: false)
            ]
        )
    }
}

#Preview("Notification", as: .content, using: JourneyActivityAttributes.preview) {
   Live_ActivityLiveActivity()
} contentStates: {
    JourneyActivityAttributes.ContentState.onTime
    JourneyActivityAttributes.ContentState.delayed
}
