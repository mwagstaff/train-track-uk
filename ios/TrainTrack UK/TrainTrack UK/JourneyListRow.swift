import SwiftUI

enum JourneyCardPresentation {
    static func defaultDepartureCount(journeyCount: Int) -> Int {
        journeyCount == 1 ? 5 : 3
    }

    static func relativeDepartureLabel(departure: Date, now: Date = Date()) -> String {
        let seconds = departure.timeIntervalSince(now)
        guard seconds > 0 else { return "Due" }
        let minutes = Int(ceil(seconds / 60))
        if minutes < 60 {
            return "in \(minutes) min"
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "in \(hours)h"
        }
        return "in \(hours)h \(String(format: "%02d", remainingMinutes))m"
    }

    static func arrivalTimeLabel(_ time: String) -> String {
        time.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delayed"
            ? "TBC (delayed)"
            : time
    }

    static func arrivalLabel(
        time: String,
        destinationName: String,
        scheduledDeparture: String? = nil
    ) -> String {
        let arrival = "Arr \(arrivalTimeLabel(time)) at \(destinationName)"
        guard let scheduledDeparture else { return arrival }
        return "\(scheduledDeparture) • \(arrival)"
    }
}

enum JourneyCardNavigationDestination: Hashable, Identifiable {
    case service(serviceID: String, fromCRS: String, toCRS: String)

    var id: String {
        switch self {
        case .service(let serviceID, let fromCRS, let toCRS):
            return "service-\(serviceID)-\(fromCRS)-\(toCRS)"
        }
    }
}

struct JourneyCard: View {
    let group: JourneyGroup
    let isFavourite: Bool
    let defaultDepartureCount: Int
    let isLiveActive: Bool
    let isScheduled: Bool
    let isBusy: Bool
    let isInteractive: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onOpenDeparture: (Journey, DepartureV2) -> Void
    let onToggleFavourite: () -> Void
    let onToggleJourneyUpdates: () -> Void
    let onScheduleJourneyUpdates: () -> Void
    let onRemoveJourney: () -> Void

    @EnvironmentObject private var depStore: DeparturesStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4

    private struct Summary: Identifiable {
        let firstLeg: Journey
        let firstDeparture: DepartureV2
        let finalArrivalTime: String?
        let completedLegCount: Int

        var id: String { firstDeparture.serviceID }
    }

    private var firstLeg: Journey { group.legs.first! }

    private var upcomingDepartures: [DepartureV2] {
        depStore.departures(for: firstLeg).filter { departure in
            guard let date = departureDate(departure) else { return true }
            return date >= Date().addingTimeInterval(-60)
        }
    }

    private var summaries: [Summary] {
        upcomingDepartures.map(buildSummary)
    }

    private var displayedSummaries: [Summary] {
        Array(summaries.prefix(isExpanded ? summaries.count : defaultDepartureCount))
    }

    private var canExpand: Bool {
        summaries.count > defaultDepartureCount
    }

    private var firstSummary: Summary? { summaries.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)

            Divider()
                .padding(.horizontal, 16)

            VStack(alignment: .leading, spacing: 0) {
                Text("Upcoming departures")
                    .font(.caption2.weight(.medium))
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                if displayedSummaries.isEmpty {
                    Text("No upcoming departures found")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                } else {
                    ForEach(Array(displayedSummaries.enumerated()), id: \.element.id) { index, summary in
                        departureLink(summary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        if index < displayedSummaries.count - 1 {
                            Divider().padding(.horizontal, 16)
                        }
                    }
                }

                if canExpand {
                    Divider().padding(.horizontal, 16)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            onToggleExpanded()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(isExpanded ? "Show fewer departures" : "View all departures")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(!isInteractive)
                    .accessibilityLabel(isExpanded ? "Show fewer departures" : "View all departures")
                }
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .task(id: prefetchTaskID) {
            await prefetchVisibleServiceDetails()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            favouriteControl

            VStack(alignment: .leading, spacing: 6) {
                routeTitle

                if let summary = firstSummary {
                    metadata(for: summary)
                    if let status = detailedStatus(for: summary.firstDeparture) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Circle()
                                .fill(status.color)
                                .frame(width: 8, height: 8)
                            Text(status.text)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            journeyMenu
        }
    }

    @ViewBuilder
    private var favouriteControl: some View {
        if isInteractive {
            Button(action: onToggleFavourite) {
                favouriteImage
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavourite ? "Remove from favourites" : "Add to favourites")
            .accessibilityHint("Shows a confirmation before changing this journey.")
        } else {
            favouriteImage.frame(width: 30, height: 30)
        }
    }

    private var favouriteImage: some View {
        Image(systemName: isFavourite ? "heart.fill" : "heart")
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.accentColor)
    }

    private var routeTitle: some View {
        Text(group.displayTitle)
            .font(.headline)
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var journeyMenu: some View {
        if isInteractive {
            Menu {
                Button(role: isLiveActive ? .destructive : nil, action: onToggleJourneyUpdates) {
                    Label(
                        isLiveActive ? "Stop journey updates" : "Start journey updates",
                        systemImage: isLiveActive ? "stop.fill" : "play.fill"
                    )
                }
                .disabled(isBusy)

                Button(action: onScheduleJourneyUpdates) {
                    Label(
                        isScheduled ? "Edit scheduled updates" : "Schedule journey updates",
                        systemImage: isScheduled ? "clock.fill" : "clock"
                    )
                }

                Divider()

                Button(role: .destructive, action: onRemoveJourney) {
                    Label("Remove journey", systemImage: "trash")
                }
            } label: {
                Group {
                    if isBusy {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                    }
                }
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Journey actions")
        }
    }

    private func metadata(for summary: Summary) -> some View {
        HStack(spacing: 6) {
            if !summary.firstDeparture.isCancelled {
                if let arrival = summary.finalArrivalTime {
                    Text("Arr \(JourneyCardPresentation.arrivalTimeLabel(arrival))")
                } else if group.legs.count > summary.completedLegCount {
                    Text("Loading connection")
                }
            }

            if !isBus(summary.firstDeparture) {
                if !summary.firstDeparture.isCancelled,
                   summary.finalArrivalTime != nil || group.legs.count > summary.completedLegCount {
                    Text("•")
                }
                if let length = summary.firstDeparture.length, length > 0 {
                    Text("\(length) cars")
                    if length <= minShortTrainCars {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                            .accessibilityLabel("Short train")
                    }
                } else {
                    Text("Unknown length")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func departureLink(_ summary: Summary) -> some View {
        if isInteractive {
            Button {
                onOpenDeparture(summary.firstLeg, summary.firstDeparture)
            } label: {
                departureRow(summary)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens live calling points for this service.")
        } else {
            departureRow(summary)
        }
    }

    @ViewBuilder
    private func departureRow(_ summary: Summary) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                departureIdentity(summary)
                HStack(spacing: 12) {
                    platform(for: summary.firstDeparture)
                    departureStatus(summary.firstDeparture)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                departureIdentity(summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                platform(for: summary.firstDeparture)
                departureStatus(summary.firstDeparture)
                    .frame(minWidth: 86, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func departureIdentity(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(departureDisplayTime(summary.firstDeparture))
                .font(.title3)
                .monospacedDigit()
                .strikethrough(summary.firstDeparture.isCancelled)
                .foregroundStyle(summary.firstDeparture.isCancelled ? Color.secondary : Color.primary)
            if !summary.firstDeparture.isCancelled {
                TrainLengthIndicator(
                    cars: summary.firstDeparture.length,
                    warningThreshold: minShortTrainCars
                )
            }
            if !summary.firstDeparture.isCancelled {
                Group {
                    if let arrival = summary.finalArrivalTime {
                        Text(JourneyCardPresentation.arrivalLabel(
                            time: arrival,
                            destinationName: group.endStation.name,
                            scheduledDeparture: isRunningLate(summary.firstDeparture)
                                ? summary.firstDeparture.departureTime.scheduled
                                : nil
                        ))
                    } else {
                        Text("Arrival time unavailable")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.top, 1)
            }
        }
    }

    @ViewBuilder
    private func platform(for departure: DepartureV2) -> some View {
        if !departure.isCancelled {
            PlatformBadge(
                platform: departure.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (departure.platform ?? "TBC")
                    : "TBC",
                isBus: isBus(departure)
            )
        }
    }

    private func departureStatus(_ departure: DepartureV2) -> some View {
        let status = compactStatus(for: departure)
        return VStack(alignment: .leading, spacing: 2) {
            Text(status.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(status.color)
            if !departure.isCancelled, let date = departureDate(departure) {
                Text(JourneyCardPresentation.relativeDepartureLabel(departure: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func buildSummary(startingWith firstDeparture: DepartureV2) -> Summary {
        var previousArrivalDate: Date?
        var previousDepartureDate: Date?
        var finalArrivalTime: String?
        var completedLegCount = 0

        for (index, leg) in group.legs.enumerated() {
            let departure: DepartureV2
            if index == 0 {
                departure = firstDeparture
            } else {
                let earliest = previousArrivalDate ?? previousDepartureDate
                guard let selected = selectDeparture(for: leg, earliest: earliest) else { break }
                departure = selected
            }

            let arrival = arrivalInfo(for: departure, toCRS: leg.toStation.crs)
            previousArrivalDate = arrival.date
            previousDepartureDate = departureDate(departure)
            finalArrivalTime = arrival.time
            completedLegCount += 1

            if index < group.legs.count - 1, arrival.date == nil {
                break
            }
        }

        return Summary(
            firstLeg: firstLeg,
            firstDeparture: firstDeparture,
            finalArrivalTime: completedLegCount == group.legs.count ? finalArrivalTime : nil,
            completedLegCount: completedLegCount
        )
    }

    private func selectDeparture(for leg: Journey, earliest: Date?) -> DepartureV2? {
        let departures = depStore.departures(for: leg).filter { !$0.isCancelled }
        if let earliest,
           let match = departures.first(where: { departure in
               guard let date = departureDate(departure) else { return false }
               return date >= earliest
           }) {
            return match
        }
        return departures.first
    }

    private func arrivalInfo(for departure: DepartureV2, toCRS: String) -> (time: String?, date: Date?) {
        guard let details = depStore.serviceDetailsById[departure.serviceID] else { return (nil, nil) }
        let targetCRS = toCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let callingPoint = details.allStations.first(where: {
            $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS
        }) {
            let display: String = {
                if let actual = callingPoint.at, actual != "Cancelled" {
                    return actual == "On time" ? callingPoint.st : actual
                }
                if let estimated = callingPoint.et, estimated != "Cancelled" {
                    return estimated == "On time" ? callingPoint.st : estimated
                }
                return callingPoint.st
            }()
            return (display, parseHHmm(display))
        }
        if details.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == targetCRS {
            let display: String? = {
                if let actual = details.ata, actual != "Cancelled" {
                    return actual == "On time" ? details.sta : actual
                }
                return details.sta
            }()
            return (display, parseHHmm(display))
        }
        return (nil, nil)
    }

    private func detailedStatus(for departure: DepartureV2) -> (text: String, color: Color)? {
        if departure.isCancelled { return ("Cancelled", .red) }
        if let minutes = departureDelayMinutes(
            estimated: departure.departureTime.estimated,
            scheduled: departure.departureTime.scheduled
        ), minutes > 0 {
            return ("Departure delayed by \(minutes) minute\(minutes == 1 ? "" : "s")", .yellow)
        }
        if departure.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delayed" {
            return ("Departure status unknown at present", .yellow)
        }
        if let details = depStore.serviceDetailsById[departure.serviceID],
           let live = computeLiveStatus(from: details, within: firstLeg.fromStation.crs, toCRS: firstLeg.toStation.crs) {
            let color: Color = live.delayMinutes >= 5 ? .red : (live.delayMinutes > 0 ? .yellow : .green)
            return (live.text, color)
        }
        return ("Scheduled to depart on time", .green)
    }

    private func compactStatus(for departure: DepartureV2) -> (text: String, color: Color) {
        if departure.isCancelled { return ("Cancelled", .red) }
        if let minutes = departureDelayMinutes(
            estimated: departure.departureTime.estimated,
            scheduled: departure.departureTime.scheduled
        ), minutes > 0 {
            return ("Delayed", minutes >= 5 ? .red : .yellow)
        }
        let estimated = departure.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if estimated == "delayed" { return ("Delayed", .yellow) }
        return ("On time", .green)
    }

    private func departureDisplayTime(_ departure: DepartureV2) -> String {
        let estimated = departure.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = estimated.lowercased()
        if estimated.isEmpty || lower == "delayed" || lower == "cancelled" || lower == "on time" {
            return departure.departureTime.scheduled
        }
        return estimated
    }

    private func isRunningLate(_ departure: DepartureV2) -> Bool {
        guard let minutes = departureDelayMinutes(
            estimated: departure.departureTime.estimated,
            scheduled: departure.departureTime.scheduled
        ) else { return false }
        return minutes > 0
    }

    private func departureDate(_ departure: DepartureV2) -> Date? {
        parseHHmm(departureDisplayTime(departure)) ?? parseHHmm(departure.departureTime.scheduled)
    }

    private func parseHHmm(_ value: String?) -> Date? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        let now = Date()
        var components = Calendar.current.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        guard var candidate = Calendar.current.date(from: components) else { return nil }
        if candidate < now && now.timeIntervalSince(candidate) > 6 * 3600 {
            candidate = Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private func isBus(_ departure: DepartureV2) -> Bool {
        departure.serviceType.lowercased() == "bus" || departure.platform?.uppercased() == "BUS"
    }

    private var prefetchTaskID: String {
        let visibleCount = isExpanded ? upcomingDepartures.count : defaultDepartureCount
        let ids = upcomingDepartures.prefix(visibleCount).map(\.serviceID).joined(separator: ",")
        return "\(isExpanded)-\(ids)"
    }

    private func prefetchVisibleServiceDetails() async {
        let visibleCount = isExpanded ? upcomingDepartures.count : defaultDepartureCount
        var ids = upcomingDepartures.prefix(visibleCount).map(\.serviceID)
        for leg in group.legs.dropFirst() {
            ids.append(contentsOf: depStore.departures(for: leg).prefix(8).map(\.serviceID))
        }
        await depStore.ensureServiceDetails(for: Array(Set(ids)))
    }
}

private struct TrainLengthIndicator: View {
    let cars: Int?
    let warningThreshold: Int

    private var carCount: Int? {
        guard let cars, cars > 0 else { return nil }
        return cars
    }

    var body: some View {
        if let carCount {
            ViewThatFits(in: .horizontal) {
                formation(carCount)
                shortenedFormation
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(carCount <= warningThreshold ? Color.yellow : Color.secondary)
            .frame(height: 9, alignment: .leading)
            .accessibilityLabel("\(carCount) car train\(carCount <= warningThreshold ? ", short train warning" : "")")
        }
    }

    private func formation(_ count: Int) -> some View {
        HStack(spacing: 1) {
            terminatingCar(facingRight: true)
            ForEach(1..<max(1, count - 1), id: \.self) { _ in
                Image(systemName: "train.side.middle.car")
            }
            if count > 1 {
                terminatingCar(facingRight: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .lineLimit(1)
    }

    private var shortenedFormation: some View {
        HStack(spacing: 2) {
            terminatingCar(facingRight: true)
            Image(systemName: "ellipsis")
            terminatingCar(facingRight: false)
        }
        .fixedSize(horizontal: true, vertical: false)
        .lineLimit(1)
    }

    private func terminatingCar(facingRight: Bool) -> some View {
        Image(systemName: "train.side.front.car")
            .scaleEffect(x: facingRight ? -1 : 1, y: 1)
    }
}
