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

struct Live_ActivityLiveActivity: Widget {
    private func deepLinkURL(for context: ActivityViewContext<JourneyActivityAttributes>) -> URL? {
        var components = URLComponents()
        components.scheme = "traintrack"
        components.host = deepLinkHost(for: context.state.journeyPhase)
        let queryItems = [
            URLQueryItem(name: "from", value: context.state.deepLinkFromCRS ?? context.state.fromCRS),
            URLQueryItem(name: "to", value: context.state.deepLinkToCRS ?? context.state.toCRS)
        ]
        components.queryItems = queryItems
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
                        Text(primaryTimeLabel(for: context.state))
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
                                    .strikethrough(true, color: .red)
                            } else if let length = context.state.length, length > 0 {
                                Text("\(length) cars")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        if let status = primaryStatusText(for: context.state) {
                            HStack(spacing: 6) {
                                if context.state.delayRepayMessage != nil {
                                    Image(systemName: "info.circle.fill")
                                        .foregroundStyle(appIconBlue)
                                } else {
                                    Circle()
                                        .fill(statusColor(context.state.delayMinutes))
                                        .frame(width: 6, height: 6)
                                }
                                Text(status)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                Spacer()
                            }
                        }

                        if context.state.journeyPhase.showsInProgressService {
                            JourneyCallToAction(
                                title: callToActionTitle(for: context.state),
                                raisesLabel: primaryStatusText(for: context.state) != nil
                            )
                        } else if !context.state.upcomingDepartures.isEmpty {
                            UpcomingDeparturesStrip(departures: context.state.upcomingDepartures)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            } compactLeading: {
                PlatformPill(platform: context.state.platform, font: .caption, horizontalPadding: 6, verticalPadding: 1.5)
            } compactTrailing: {
                PrimaryDepartureTimeText(
                    state: context.state,
                    font: .caption,
                    weight: .semibold
                )
            } minimal: {
                PlatformPill(platform: context.state.platform, font: .caption2, horizontalPadding: 5, verticalPadding: 1)
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
        components.host = deepLinkHost(for: state.journeyPhase)
        let queryItems = [
            URLQueryItem(name: "from", value: state.deepLinkFromCRS ?? state.fromCRS),
            URLQueryItem(name: "to", value: state.deepLinkToCRS ?? state.toCRS)
        ]
        components.queryItems = queryItems
        return components.url
    }

    private var routeTitle: String {
        state.routeTitle ?? attributes.displayName
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(routeTitle)
                .font(.headline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)

            // Main departure info
            HStack(alignment: .top, spacing: 12) {

                // Departure time
                VStack(alignment: .leading, spacing: 4) {
                    Text(primaryTimeLabel(for: state))
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
                            .strikethrough(true, color: .red)
                    } else if let length = state.length, length > 0 {
                        Text("\(length) cars")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Platform number
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Platform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    PlatformPill(
                        platform: state.platform,
                        font: .title,
                        horizontalPadding: 10,
                        verticalPadding: 3
                    )
                }
            }

            // Live status
            if let status = primaryStatusText(for: state) {
                HStack(spacing: 6) {
                    if state.delayRepayMessage != nil {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(appIconBlue)
                    } else {
                        Circle()
                            .fill(statusColor(state.delayMinutes))
                            .frame(width: 10, height: 10)
                    }
                    Text(status)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.top, 4)
            }

            // Upcoming departures
            if state.journeyPhase.showsInProgressService {
                JourneyCallToAction(
                    title: callToActionTitle(for: state),
                    raisesLabel: primaryStatusText(for: state) != nil
                )
                .padding(.horizontal, -16)
                .padding(.bottom, -16)
            } else if !state.upcomingDepartures.isEmpty {
                UpcomingDeparturesStrip(departures: state.upcomingDepartures)
            }
        }
        .padding(16)
        .widgetURL(deepLinkURL)
    }
}

private struct JourneyCallToAction: View {
    let title: String
    let raisesLabel: Bool

    var body: some View {
        Text(title)
            .font(.caption)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .offset(y: raisesLabel ? -4 : 0)
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .center)
            .multilineTextAlignment(.center)
            .background(appIconBlue)
            .accessibilityAddTraits(.isButton)
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
        StruckThroughTimeText(
            time: text,
            color: primaryAccentColor(for: state),
            isStruckThrough: state.isCancelled,
            font: font,
            weight: weight,
            lineHeight: 2
        )
    }
}

private struct UpcomingDeparturesStrip: View {
    let departures: [JourneyActivityAttributes.UpcomingDeparture]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(departures.prefix(3).enumerated()), id: \.offset) { _, departure in
                HStack(spacing: 6) {
                    HStack(spacing: 3) {
                        if departure.hasFasterLaterService {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.yellow)
                        }
                        StruckThroughTimeText(
                            time: departure.time,
                            color: departure.isCancelled ? .red : estimatedTimeColor(departure.delayMinutes),
                            isStruckThrough: departure.isCancelled,
                            font: .caption,
                            weight: .medium
                        )
                    }

                    if let arrivalTime = departure.arrivalTime, !departure.isCancelled {
                        Text("→ \(arrivalTime)")
                            .font(.caption2)
                            .fontWeight(.regular)
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    PlatformPill(
                        platform: (departure.platform?.isEmpty ?? true) ? "TBC" : departure.platform!,
                        font: .system(size: 10),
                        horizontalPadding: 2,
                        verticalPadding: 0.5
                    )
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct StruckThroughTimeText: View {
    let time: String
    let color: Color
    let isStruckThrough: Bool
    let font: Font
    let weight: Font.Weight
    var lineHeight: CGFloat = 1

    var body: some View {
        Text(time)
            .font(font)
            .fontWeight(weight)
            .monospacedDigit()
            .foregroundColor(color)
            .overlay {
                if isStruckThrough {
                    Rectangle()
                        .fill(color)
                        .frame(height: lineHeight)
                }
            }
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

private let appIconBlue = colorFromHex("#0047F8")

private func deepLinkHost(for phase: JourneyActivityAttributes.JourneyPhase) -> String {
    switch phase {
    case .pendingStart, .atStart, .enRoute:
        return "in-progress"
    case .arrived:
        return "history"
    }
}

private func callToActionTitle(for state: JourneyActivityAttributes.ContentState) -> String {
    state.journeyPhase == .arrived
        ? "Tap to view journey history"
        : "Tap to view journey"
}

private func primaryTimeLabel(for state: JourneyActivityAttributes.ContentState) -> String {
    switch state.journeyPhase {
    case .enRoute:
        return "Est. arrival"
    case .arrived:
        return "Arrived"
    case .pendingStart, .atStart:
        return "Departs"
    }
}

private func primaryStatusText(for state: JourneyActivityAttributes.ContentState) -> String? {
    if state.journeyPhase == .arrived {
        return state.delayRepayMessage
    }
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
                JourneyActivityAttributes.UpcomingDeparture(time: "09:50", arrivalTime: "10:02", delayMinutes: 0, isCancelled: false, platform: "2", hasFasterLaterService: false),
                JourneyActivityAttributes.UpcomingDeparture(time: "10:05", arrivalTime: "10:14", delayMinutes: 3, isCancelled: false, platform: "3", hasFasterLaterService: true),
                JourneyActivityAttributes.UpcomingDeparture(time: "10:20", arrivalTime: "10:35", delayMinutes: 0, isCancelled: false, platform: "2", hasFasterLaterService: false)
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
                JourneyActivityAttributes.UpcomingDeparture(time: "10:03", arrivalTime: "10:24", delayMinutes: 0, isCancelled: false, platform: "15", hasFasterLaterService: false),
                JourneyActivityAttributes.UpcomingDeparture(time: "10:18", arrivalTime: nil, delayMinutes: 0, isCancelled: true, platform: "14", hasFasterLaterService: false),
                JourneyActivityAttributes.UpcomingDeparture(time: "10:33", arrivalTime: "10:58", delayMinutes: 8, isCancelled: false, platform: "15", hasFasterLaterService: false)
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
