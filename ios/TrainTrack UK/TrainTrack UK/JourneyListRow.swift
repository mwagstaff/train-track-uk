import SwiftUI

enum JourneyCardPresentation {
    static func defaultDepartureCount(journeyCount: Int) -> Int {
        journeyCount == 1 ? 5 : 3
    }

    static func shouldDisplaySummary(legCount: Int, hasServicesForAllLegs: Bool) -> Bool {
        legCount == 1 || hasServicesForAllLegs
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

    static func cancellationStatusText(_ reason: String?) -> String {
        guard let reason = reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else {
            return "Cancelled"
        }
        return reason
    }

    static func cancellationStatusText(_ cancellation: JourneyCancellation) -> String {
        guard cancellation.isPartial,
              let cancelledFrom = cancellation.cancelledFrom,
              let destinationName = cancellation.destinationName else {
            return cancellationStatusText(cancellation.reason)
        }
        if cancellation.serviceContinuesBeyondDestination {
            return "Service no longer stopping at \(destinationName)"
        }
        if cancelledFrom == destinationName {
            return "Partial cancellation · Not calling at \(destinationName)"
        }
        return "Partial cancellation · Not running from \(cancelledFrom) to \(destinationName)"
    }

    static func splitGuidanceLabel(_ guidance: SplitGuidanceV1, destinationName: String) -> String? {
        let position = guidance.position.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (position == "front" || position == "rear"), guidance.coachCount > 0 else { return nil }
        let splitLocation = guidance.splitAt.locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !splitLocation.isEmpty else { return nil }
        let coachLabel = guidance.coachCount == 1 ? "coach" : "coaches"
        return "Train divides at \(splitLocation). Travel in the \(position) \(guidance.coachCount) \(coachLabel) for \(destinationName)."
    }
}

enum JourneyCardNavigationDestination: Hashable, Identifiable {
    case service(
        serviceID: String,
        fromCRS: String,
        toCRS: String,
        departureTime: String,
        destinationName: String
    )
    case itinerary(group: JourneyGroup, firstDeparture: DepartureV2)

    var id: String {
        switch self {
        case .service(let serviceID, let fromCRS, let toCRS, _, _):
            return "service-\(serviceID)-\(fromCRS)-\(toCRS)"
        case .itinerary(let group, let firstDeparture):
            return "itinerary-\(group.id)-\(firstDeparture.serviceID)"
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
    let canReverseJourney: Bool
    let isJourneyReversed: Bool
    let onToggleExpanded: () -> Void
    let onToggleJourneyReversed: () -> Void
    let onOpenDeparture: (Journey, DepartureV2) -> Void
    let onToggleFavourite: () -> Void
    let onToggleJourneyUpdates: () -> Void
    let onScheduleJourneyUpdates: () -> Void
    let onRemoveJourney: () -> Void

    @EnvironmentObject private var depStore: DeparturesStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4
    @State private var isLoadingServiceDetails = false

    private struct Summary: Identifiable {
        let firstLeg: Journey
        let firstDeparture: DepartureV2
        let finalArrivalTime: String?
        let cancellation: JourneyCancellation?

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
        upcomingDepartures.compactMap(buildSummary)
    }

    private var displayedSummaries: [Summary] {
        Array(summaries.prefix(isExpanded ? summaries.count : defaultDepartureCount))
    }

    private var canExpand: Bool {
        summaries.count > defaultDepartureCount
    }

    private var firstSummary: Summary? { summaries.first }

    private var dataAvailability: JourneyDataAvailability {
        group.legs
            .map(depStore.dataAvailability(for:))
            .max { $0.status.severity < $1.status.severity }
            ?? .live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)

            Divider()
                .padding(.horizontal, 16)

            if dataAvailability.status != .live {
                dataAvailabilityNotice
                Divider().padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 0) {
                if displayedSummaries.isEmpty {
                    if depStore.isInitialLoadInProgress || isLoadingServiceDetails {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                            Text("Loading upcoming departures…")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    } else if dataAvailability.status == .live {
                        Text("No upcoming departures found")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                    } else {
                        EmptyView()
                    }
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

    private var dataAvailabilityNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            dataAvailabilityText
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var dataAvailabilityText: Text {
        switch dataAvailability.status {
        case .live:
            return Text("")
        case .partial:
            return Text("Some live departures may be missing")
        case .stale:
            if let updatedAt = dataAvailability.lastSuccessfulUpdate {
                return Text("Live updates unavailable · Updated \(updatedAt, style: .relative)")
            }
            return Text("Live updates unavailable · Showing earlier data")
        case .unavailable:
            return Text("Live departure data is temporarily unavailable. We get our data from National Rail, who might be having issues with this journey right now. Please try again later.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            favouriteControl

            VStack(alignment: .leading, spacing: 6) {
                routeTitle
            }

            Spacer(minLength: 0)
            HStack(spacing: 4) {
                reverseJourneyControl
                journeyMenu
            }
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
    private var reverseJourneyControl: some View {
        if isInteractive {
            Button(action: onToggleJourneyReversed) {
                reverseJourneyImage
            }
            .buttonStyle(.plain)
            .disabled(!canReverseJourney)
            .opacity(canReverseJourney ? 1 : 0.35)
            .accessibilityLabel("Reverse journey")
            .accessibilityValue(isJourneyReversed ? "On" : "Off")
            .accessibilityHint("Switches the origin and destination shown on this card.")
        } else {
            reverseJourneyImage
                .opacity(canReverseJourney ? 1 : 0.35)
        }
    }

    private var reverseJourneyImage: some View {
        Image(systemName: "arrow.left.arrow.right")
            .font(.body.weight(.semibold))
            .foregroundStyle(isJourneyReversed ? Color.white : Color.secondary)
            .frame(width: 30, height: 30)
            .background {
                Circle()
                    .fill(isJourneyReversed ? Color.accentColor : Color.clear)
            }
            .contentShape(Rectangle())
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
        VStack(alignment: .leading, spacing: 8) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    departureIdentity(summary)
                    HStack(spacing: 12) {
                        platform(for: summary.firstDeparture, cancellation: summary.cancellation)
                        departureStatus(summary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    departureIdentity(summary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    platform(for: summary.firstDeparture, cancellation: summary.cancellation)
                    departureStatus(summary)
                        .frame(minWidth: 86, alignment: .leading)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }

            if summary.id == firstSummary?.id,
               let status = detailedStatus(for: summary) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle()
                        .fill(status.color)
                        .frame(width: 8, height: 8)
                    Text(status.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func departureIdentity(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(departureDisplayTime(summary.firstDeparture))
                .font(.title3)
                .monospacedDigit()
                .strikethrough(summary.cancellation != nil)
                .foregroundStyle(summary.cancellation != nil ? Color.secondary : Color.primary)
            if summary.cancellation == nil {
                TrainLengthIndicator(
                    cars: summary.firstDeparture.length,
                    warningThreshold: minShortTrainCars,
                    carriageLoading: depStore.loadingDetailsByServiceId[summary.firstDeparture.serviceID]?.freshCoaches
                )
            }
            if summary.cancellation == nil {
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

                if let guidance = depStore.loadingDetailsByServiceId[summary.firstDeparture.serviceID]?.splitGuidance,
                   let note = JourneyCardPresentation.splitGuidanceLabel(
                    guidance,
                    destinationName: summary.firstLeg.toStation.name
                   ) {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        Text(note)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Important. \(note)")
                }
            }
        }
    }

    @ViewBuilder
    private func platform(for departure: DepartureV2, cancellation: JourneyCancellation?) -> some View {
        if cancellation == nil {
            PlatformBadge(
                platform: departure.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    ? (departure.platform ?? "TBC")
                    : "TBC",
                isBus: isBus(departure)
            )
        }
    }

    private func departureStatus(_ summary: Summary) -> some View {
        let status = compactStatus(for: summary.firstDeparture, cancellation: summary.cancellation)
        return VStack(alignment: .leading, spacing: 2) {
            Text(status.text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(status.color)
            if summary.cancellation == nil, let date = departureDate(summary.firstDeparture) {
                Text(JourneyCardPresentation.relativeDepartureLabel(departure: date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private func buildSummary(startingWith firstDeparture: DepartureV2) -> Summary? {
        let itinerary = JourneyItineraryBuilder.build(
            group: group,
            firstDeparture: firstDeparture,
            departuresForJourney: depStore.departures(for:),
            serviceDetailsByID: depStore.serviceDetailsById
        )
        guard JourneyCardPresentation.shouldDisplaySummary(
            legCount: group.legs.count,
            hasServicesForAllLegs: itinerary.hasServicesForAllLegs
        ) else { return nil }

        return Summary(
            firstLeg: firstLeg,
            firstDeparture: firstDeparture,
            finalArrivalTime: itinerary.finalArrivalTime,
            cancellation: JourneyItineraryBuilder.cancellation(
                for: firstDeparture,
                at: firstLeg.toStation.crs,
                serviceDetailsByID: depStore.serviceDetailsById
            )
        )
    }

    private func detailedStatus(for summary: Summary) -> (text: String, color: Color)? {
        let departure = summary.firstDeparture
        if let cancellation = summary.cancellation {
            return (JourneyCardPresentation.cancellationStatusText(cancellation), .red)
        }
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

    private func compactStatus(
        for departure: DepartureV2,
        cancellation: JourneyCancellation?
    ) -> (text: String, color: Color) {
        if cancellation != nil { return ("Cancelled", .red) }
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
        let requestedTaskID = prefetchTaskID
        let visibleCount = isExpanded ? upcomingDepartures.count : defaultDepartureCount
        var ids = upcomingDepartures.prefix(visibleCount).map(\.serviceID)
        for leg in group.legs.dropFirst() {
            ids.append(contentsOf: depStore.departures(for: leg).prefix(8).map(\.serviceID))
        }
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else { return }
        isLoadingServiceDetails = true
        defer {
            if requestedTaskID == prefetchTaskID {
                isLoadingServiceDetails = false
            }
        }
        await depStore.ensureServiceDetails(for: uniqueIDs)
    }
}

struct TrainLengthIndicator: View {
    let cars: Int?
    let warningThreshold: Int
    let carriageLoading: [CoachLoadingV1]?

    init(cars: Int?, warningThreshold: Int, carriageLoading: [CoachLoadingV1]? = nil) {
        self.cars = cars
        self.warningThreshold = warningThreshold
        self.carriageLoading = carriageLoading
    }

    private var carCount: Int? {
        let loadingCount = carriageLoading?.count ?? 0
        let knownCount = max(cars ?? 0, loadingCount)
        return knownCount > 0 ? knownCount : nil
    }

    private var orderedLoading: [CoachLoadingV1] {
        (carriageLoading ?? []).sorted {
            if $0.position == $1.position { return $0.number < $1.number }
            return $0.position < $1.position
        }
    }

    var body: some View {
        if let carCount {
            HStack(spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    formation(carCount)
                    shortenedFormation
                }
                Text("x\(carCount)")
                    .monospacedDigit()
                    .foregroundStyle(carCount <= warningThreshold ? Color.yellow : Color.secondary)
            }
            .font(.system(size: 8, weight: .medium))
            .frame(height: 9, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityDescription(carCount: carCount))
        }
    }

    private func formation(_ count: Int) -> some View {
        HStack(spacing: 1) {
            ForEach(0..<count, id: \.self) { index in
                carImage(index: index, count: count)
                    .foregroundStyle(color(for: index, carCount: count))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .lineLimit(1)
    }

    private var shortenedFormation: some View {
        HStack(spacing: 1) {
            ForEach(0..<(carCount ?? 0), id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(color(for: index, carCount: carCount ?? 0))
                    .frame(width: 4, height: 7)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .lineLimit(1)
    }

    @ViewBuilder
    private func carImage(index: Int, count: Int) -> some View {
        if index == 0 {
            Image(systemName: "train.side.front.car")
                .scaleEffect(x: -1, y: 1)
        } else if index == count - 1 {
            Image(systemName: "train.side.front.car")
        } else {
            Image(systemName: "train.side.middle.car")
        }
    }

    private func color(for index: Int, carCount: Int) -> Color {
        if let coach = loading(for: index) {
            switch CarriageLoadingBand.value(for: coach.percentage) {
            case .green: return .green
            case .amber: return .orange
            case .red: return .red
            case .unknown: break
            }
        }
        return carCount <= warningThreshold ? .yellow : .secondary
    }

    private func loading(for index: Int) -> CoachLoadingV1? {
        if let positioned = orderedLoading.first(where: { $0.position == index + 1 }) {
            return positioned
        }
        guard orderedLoading.indices.contains(index) else { return nil }
        return orderedLoading[index]
    }

    private func accessibilityDescription(carCount: Int) -> String {
        var components = ["\(carCount) car train"]
        if carCount <= warningThreshold {
            components.append("short train warning")
        }
        for coach in orderedLoading {
            let band = CarriageLoadingBand.value(for: coach.percentage)
            let percentage = coach.percentage.map { ", \($0) percent" } ?? ""
            components.append("Coach \(coach.number), \(band.accessibilityDescription)\(percentage)")
        }
        return components.joined(separator: ". ")
    }
}
