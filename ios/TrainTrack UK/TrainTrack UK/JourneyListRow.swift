import SwiftUI

enum JourneyCardPresentation {
    static func isUpcomingDeparture(_ departure: DepartureV2, now: Date = Date()) -> Bool {
        let departureDate = JourneyItineraryBuilder.date(
            for: JourneyItineraryBuilder.departureDisplayTime(departure),
            now: now
        ) ?? JourneyItineraryBuilder.date(for: departure.departureTime.scheduled, now: now)
        guard let departureDate else { return true }
        return departureDate >= now.addingTimeInterval(-60)
    }

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
        arrivalTimeLabel(time, departure: nil)
    }

    static func arrivalTimeLabel(_ time: String?, departure: Date? = nil) -> String {
        guard let time, !time.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "TBC" }
        if time.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delayed" { return "TBC (delayed)" }
        guard let departure, let arrival = arrivalDate(time: time, after: departure),
              !PlannerTime.calendar.isDate(departure, inSameDayAs: arrival) else { return time }
        return "\(time) (+1 day)"
    }

    static func arrivalDate(time: String?, after departure: Date?) -> Date? {
        guard let time, let departure else { return nil }
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        var components = PlannerTime.calendar.dateComponents([.year, .month, .day], from: departure)
        components.hour = hour
        components.minute = minute
        guard let arrival = PlannerTime.calendar.date(from: components) else { return nil }
        return PlannerTime.calendar.compare(arrival, to: departure, toGranularity: .minute) == .orderedAscending
            ? PlannerTime.calendar.date(byAdding: .day, value: 1, to: arrival) : arrival
    }

    static func serviceLabel(for departure: DepartureV2, details: ServiceDetails?) -> String? {
        guard let operatorName = details?.operator?.trimmingCharacters(in: .whitespacesAndNewlines),
              !operatorName.isEmpty else { return nil }
        let destinations = departure.destination
            .map { $0.locationName.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !destinations.isEmpty else { return nil }
        return "\(operatorName) service to \(destinations.joined(separator: " & "))"
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
    let scheduledSubscriptions: [NotificationSubscription]
    let canAddSchedule: Bool
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
    let onAddJourneySchedule: () -> Void
    let onEditJourneySchedule: (NotificationSubscription) -> Void
    let onRemoveJourney: () -> Void
    var showsHeader: Bool = true
    var allowsExpansion: Bool = true
    var plannedBoard: SavedRouteBoardState? = nil
    var laterBoard: SavedRouteBoardState? = nil
    var onSearchLater: (() -> Void)? = nil
    var onRetryLater: (() -> Void)? = nil

    @EnvironmentObject private var depStore: DeparturesStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var serverConfig = ServerConfigStore.shared
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4
    @State private var isLoadingServiceDetails = false

    private struct Summary: Identifiable {
        let firstLeg: Journey
        let firstDeparture: DepartureV2
        let finalArrivalTime: String?
        let departureDate: Date?
        let durationMinutes: Double?
        let cancellation: JourneyCancellation?

        var id: String { firstDeparture.serviceID }
    }

    private var usesDirectDepartures: Bool { plannedBoard?.usesDirectDepartures == true }
    private var presentationGroup: JourneyGroup { usesDirectDepartures ? SavedRouteDirectPresentation.throughGroup(group) : group }
    private var firstLeg: Journey { presentationGroup.legs.first! }
    private var isScheduled: Bool { !scheduledSubscriptions.isEmpty }

    private var upcomingDepartures: [DepartureV2] {
        if let direct = plannedBoard?.direct {
            return SavedRouteDirectPresentation.upcoming(direct.departures, useLiveTimes: true,
                now: Date(), observedAt: direct.lastSuccessfulUpdate)
        }
        return depStore.departures(for: firstLeg).filter {
            JourneyCardPresentation.isUpcomingDeparture($0)
        }
    }

    private var summaries: [Summary] {
        upcomingDepartures.compactMap(buildSummary)
    }

    private var displayedSummaries: [Summary] {
        Array(summaries.prefix(isExpanded ? summaries.count : defaultDepartureCount))
    }

    private var durationComparison: JourneyDurationComparison {
        JourneyDurationComparison(durations: displayedSummaries.compactMap(\.durationMinutes))
    }

    private var canExpand: Bool {
        allowsExpansion && summaries.count > defaultDepartureCount
    }

    private var usesPlannedJourneys: Bool {
        guard let plannedBoard else { return false }
        return !plannedBoard.usesLegacyDepartures && !plannedBoard.usesDirectDepartures
    }

    private var showsLaterDeparturesControl: Bool {
        allowsExpansion && (canExpand || onSearchLater != nil)
    }

    private var hasVisibleStandaloneLaterJourneys: Bool {
        guard isExpanded, !usesPlannedJourneys, let laterBoard else { return false }
        return !laterBoard.upcomingJourneys(at: Date()).isEmpty
    }

    private var isFindingStandaloneLaterJourneys: Bool {
        isExpanded && !usesPlannedJourneys && laterBoard?.isPending == true
    }

    private var firstSummary: Summary? { summaries.first }

    private var dataAvailability: JourneyDataAvailability {
        if let direct = plannedBoard?.directAvailability() { return direct }
        return group.legs
            .map(depStore.dataAvailability(for:))
            .max { $0.status.severity < $1.status.severity }
            ?? .live
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                header
                    .padding(16)

                Divider()
                    .padding(.horizontal, 16)
            }

            if let plannedBoard, !plannedBoard.usesLegacyDepartures, !plannedBoard.usesDirectDepartures {
                SavedRouteBoardView(state: plannedBoard, routeKey: group.stationSequence.map(\.crs).joined(separator: "-"), departureCount: defaultDepartureCount,
                    isInteractive: isInteractive, isExpanded: isExpanded,
                    onRetry: nil,
                    supplementalState: laterBoard,
                    onRetrySupplemental: onRetryLater)
            } else {
            if let message = plannedBoard?.message {
                Text(message).font(.caption).foregroundStyle(.secondary).padding(16)
            }
            if dataAvailability.status != .live && (plannedBoard == nil || plannedBoard?.hasPersistentFailure == true) {
                dataAvailabilityNotice
                Divider().padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 0) {
                if displayedSummaries.isEmpty {
                    if hasVisibleStandaloneLaterJourneys || isFindingStandaloneLaterJourneys {
                        EmptyView()
                    } else if depStore.isInitialLoadInProgress || isLoadingServiceDetails {
                        EmptyView()
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
                        departureLink(
                            summary,
                            isLast: index == displayedSummaries.count - 1
                        )
                        if index < displayedSummaries.count - 1 {
                            Divider().padding(.horizontal, 16)
                        }
                    }
                }
            }

            if isExpanded, let laterBoard {
                if !displayedSummaries.isEmpty && hasVisibleStandaloneLaterJourneys {
                    Divider().padding(.horizontal, 16)
                }
                SavedRouteBoardView(
                    state: laterBoard,
                    routeKey: "later-\(group.stationSequence.map(\.crs).joined(separator: "-"))",
                    departureCount: defaultDepartureCount,
                    isInteractive: isInteractive,
                    isExpanded: true,
                    onRetry: onRetryLater,
                    showsEmptyState: false
                )
            }
            }

            if showsLaterDeparturesControl {
                laterDeparturesControl
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .task(id: prefetchTaskID) {
            guard plannedBoard == nil || plannedBoard?.usesLegacyDepartures == true || usesDirectDepartures else { return }
            await prefetchVisibleServiceDetails()
        }
    }

    private var laterDeparturesControl: some View {
        Button {
            let shouldSearch = !isExpanded
            withAnimation(.easeInOut(duration: 0.2)) {
                onToggleExpanded()
            }
            if shouldSearch {
                onSearchLater?()
            }
        } label: {
            HStack(spacing: 6) {
                Text(isExpanded ? "Fewer departures" : "More departures")
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
        .accessibilityLabel(isExpanded ? "Fewer departures" : "More departures")
        .accessibilityIdentifier("saved-route.later-departures")
        .overlay(alignment: .top) {
            Divider().padding(.horizontal, 16)
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

    @ViewBuilder private var header: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    favouriteControl
                    routeTitle.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 16) {
                    journeyUpdatesControl
                    Spacer(minLength: 0)
                    reverseJourneyControl
                    journeyMenu
                }
            }
        } else {
        HStack(alignment: .center, spacing: 10) {
            favouriteControl

            VStack(alignment: .leading, spacing: 6) {
                routeTitle
            }

            Spacer(minLength: 0)
            HStack(spacing: 4) {
                journeyUpdatesControl
                reverseJourneyControl
                journeyMenu
            }
        }
        }
    }

    @ViewBuilder
    private var favouriteControl: some View {
        if isInteractive {
            Button(action: onToggleFavourite) {
                favouriteImage
                    .frame(minWidth: 30, minHeight: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavourite ? "Remove from favourites" : "Add to favourites")
            .accessibilityHint("Shows a confirmation before changing this journey.")
        } else {
            favouriteImage.frame(minWidth: 30, minHeight: 30)
        }
    }

    private var favouriteImage: some View {
        Image(systemName: isFavourite ? "heart.fill" : "heart")
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.accentColor)
    }

    @ViewBuilder
    private var journeyUpdatesControl: some View {
        if isInteractive {
            Button(action: onToggleJourneyUpdates) {
                if dynamicTypeSize.isAccessibilitySize {
                    HStack(spacing: 10) {
                        journeyUpdatesIndicator
                    }
                } else {
                    VStack(spacing: 3) {
                        journeyUpdatesIndicator
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .accessibilityLabel(isLiveActive ? "Stop route updates" : "Start route updates")
            .accessibilityValue(isLiveActive ? "Active" : "Inactive")
            .accessibilityHint(isLiveActive
                ? "Stops live updates for this journey."
                : "Starts updates for the saved route. Choose a train in journey details to track that train separately.")
        } else {
            journeyUpdatesImage
        }
    }

    private var journeyUpdatesIndicator: some View {
        Group {
            if isBusy { ProgressView().controlSize(.small) }
            else { journeyUpdatesImage }
        }
        .frame(minWidth: 30, minHeight: 30)
        .contentShape(Rectangle())
    }

    private var journeyUpdatesImage: some View {
        Image(systemName: isLiveActive ? "stop.fill" : "play.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(isLiveActive ? Color.white : Color.accentColor)
            .frame(minWidth: 30, minHeight: 30)
            .background {
                Circle()
                    .fill(isLiveActive ? Color.accentColor : Color.clear)
            }
            .contentShape(Rectangle())
    }

    private var isRefreshingDepartures: Bool {
        plannedBoard?.showsActivity == true
            || (isExpanded && laterBoard?.showsActivity == true)
            || (plannedBoard == nil && depStore.isInitialLoadInProgress)
            || isLoadingServiceDetails
    }

    private var routeTitle: some View {
        HStack(spacing: 6) {
            Text(group.displayTitle)
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
            // Keep the title's available width unchanged as refreshes start and finish.
            ProgressView()
                .controlSize(.small)
                .dynamicTypeSize(.medium)
                .frame(width: 16, height: 16)
                .opacity(isRefreshingDepartures ? 1 : 0)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.displayTitle)
        .accessibilityValue(isRefreshingDepartures ? "Updating departures" : "")
        .accessibilityIdentifier("saved-route.progress.\(group.stationSequence.map(\.crs).joined(separator: "-"))")
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
            .frame(minWidth: 30, minHeight: 30)
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
                if isLiveActive {
                    Button(role: .destructive, action: onToggleJourneyUpdates) {
                        Label("Stop journey updates", systemImage: "stop.fill")
                    }
                    .disabled(isBusy)

                    Divider()
                }

                if scheduledSubscriptions.count == 1, let schedule = scheduledSubscriptions.first {
                    Button {
                        onEditJourneySchedule(schedule)
                    } label: {
                        Label("Edit scheduled updates", systemImage: "clock.fill")
                    }
                } else if scheduledSubscriptions.count > 1 {
                    Menu {
                        ForEach(scheduledSubscriptions) { schedule in
                            Button {
                                onEditJourneySchedule(schedule)
                            } label: {
                                Text(schedule.daysLabel)
                                Text(schedule.windowLabel)
                            }
                        }
                    } label: {
                        Label("Edit scheduled updates", systemImage: "clock.fill")
                    }
                }

                Button(action: onAddJourneySchedule) {
                    Label(
                        isScheduled ? "Add another schedule" : "Schedule journey updates",
                        systemImage: "clock.badge.plus"
                    )
                }
                .disabled(!canAddSchedule)

                Divider()

                Button(role: .destructive, action: onRemoveJourney) {
                    Label("Remove journey", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 30, minHeight: 30)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Journey actions")
        }
    }

    @ViewBuilder
    private func departureLink(_ summary: Summary, isLast: Bool) -> some View {
        if isInteractive {
            Button {
                onOpenDeparture(summary.firstLeg, summary.firstDeparture)
            } label: {
                styledDepartureRow(summary, isLast: isLast)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens live calling points for this service.")
        } else {
            styledDepartureRow(summary, isLast: isLast)
        }
    }

    private func styledDepartureRow(_ summary: Summary, isLast: Bool) -> some View {
        departureRow(summary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(operatorColor(for: summary.firstDeparture))
                    .frame(width: 4)
                    .padding(.top, 2)
                    .padding(.bottom, isLast && !canExpand ? 16 : 2)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func departureRow(_ summary: Summary) -> some View {
        DepartureSummaryRow {
            departureTiming(summary)
        } platform: {
            platform(for: summary.firstDeparture, cancellation: summary.cancellation)
        } status: {
            departureStatus(summary)
        } details: {
            departureDetails(summary)
        } footer: {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    departureNotes(summary)
                    operatorLabel(for: summary.firstDeparture)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    departureNotes(summary)
                    Spacer(minLength: 8)
                    operatorLabel(for: summary.firstDeparture)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func departureNotes(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let tag = durationComparison.tag(for: summary.durationMinutes) {
                JourneyDurationBadge(tag: tag)
            }
            detailedStatusView(summary)
        }
    }

    @ViewBuilder
    private func detailedStatusView(_ summary: Summary) -> some View {
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
        }
    }

    @ViewBuilder
    private func operatorLabel(for departure: DepartureV2) -> some View {
        if let operatorName = operatorDisplayName(for: departure) {
            Text(operatorName.uppercased())
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.primary.opacity(0.7))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Operator \(operatorName)")
        }
    }

    private func operatorDisplayName(for departure: DepartureV2) -> String? {
        let identity = operatorIdentity(for: departure)
        if let branding = OperatorBrandingResolver.resolve(
            name: identity.name,
            code: identity.code,
            in: serverConfig.operatorBranding
        ) {
            return branding.name
        }
        return identity.name
    }

    private func operatorColor(for departure: DepartureV2) -> Color {
        let identity = operatorIdentity(for: departure)
        return OperatorBrandingResolver.resolve(
            name: identity.name,
            code: identity.code,
            in: serverConfig.operatorBranding
        )?.color ?? Color.secondary.opacity(0.35)
    }

    private func operatorIdentity(for departure: DepartureV2) -> (name: String?, code: String?) {
        let details = depStore.serviceDetailsById[departure.serviceID]
        return (
            normalizedOperatorValue(departure.operator) ?? normalizedOperatorValue(details?.operator),
            normalizedOperatorValue(departure.operatorCode) ?? normalizedOperatorValue(details?.operatorCode)
        )
    }

    private func normalizedOperatorValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func departureTiming(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            JourneyTimesView(
                departure: departureDisplayTime(summary.firstDeparture),
                arrival: JourneyCardPresentation.arrivalTimeLabel(summary.finalArrivalTime, departure: summary.departureDate),
                departureColor: summary.cancellation != nil ? (usesDirectDepartures ? .red : .secondary)
                    : (usesDirectDepartures && isRunningLate(summary.firstDeparture) ? .yellow : .primary),
                cancelled: summary.cancellation != nil
            )
            if summary.cancellation == nil {
                TrainLengthIndicator(
                    cars: summary.firstDeparture.length,
                    warningThreshold: minShortTrainCars,
                    carriageLoading: depStore.loadingDetailsByServiceId[summary.firstDeparture.serviceID]?.freshCoaches
                )
            }
        }
    }

    @ViewBuilder
    private func departureDetails(_ summary: Summary) -> some View {
        if summary.cancellation == nil {
            if isRunningLate(summary.firstDeparture) {
                Text("Scheduled \(summary.firstDeparture.departureTime.scheduled)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
            }

            if let service = JourneyCardPresentation.serviceLabel(
                for: summary.firstDeparture,
                details: depStore.serviceDetailsById[summary.firstDeparture.serviceID]
            ) {
                Text(service)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }

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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func buildSummary(startingWith firstDeparture: DepartureV2) -> Summary? {
        let itinerary = JourneyItineraryBuilder.build(
            group: presentationGroup,
            firstDeparture: firstDeparture,
            departuresForJourney: depStore.departures(for:),
            serviceDetailsByID: depStore.serviceDetailsById
        )
        guard JourneyCardPresentation.shouldDisplaySummary(
            legCount: presentationGroup.legs.count,
            hasServicesForAllLegs: itinerary.hasServicesForAllLegs
        ) else { return nil }

        let arrivalTime = itinerary.finalArrivalTime
        let departure = departureDate(firstDeparture)
        let cancellation = JourneyItineraryBuilder.cancellation(
            for: firstDeparture,
            at: firstLeg.toStation.crs,
            serviceDetailsByID: depStore.serviceDetailsById
        )
        let arrival = JourneyCardPresentation.arrivalDate(time: arrivalTime, after: departure)
        let duration = departure.flatMap { start in arrival.map { $0.timeIntervalSince(start) / 60 } }
        return Summary(
            firstLeg: firstLeg,
            firstDeparture: firstDeparture,
            finalArrivalTime: arrivalTime,
            departureDate: departure,
            durationMinutes: cancellation == nil ? duration : nil,
            cancellation: cancellation
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
            return ("Delayed", usesDirectDepartures ? .yellow : (minutes >= 5 ? .red : .yellow))
        }
        let estimated = departure.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if estimated == "delayed" { return ("Delayed", .yellow) }
        if usesDirectDepartures && [.stale, .unavailable].contains(dataAvailability.status) {
            return ("Updates unavailable", .secondary)
        }
        return ("On time", .green)
    }

    private func departureDisplayTime(_ departure: DepartureV2) -> String {
        if usesDirectDepartures {
            return SavedRouteDirectPresentation.time(departure, useLiveTimes: true)
        }
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
        if usesDirectDepartures {
            return SavedRouteDirectPresentation.departureDate(departure, useLiveTimes: true,
                now: Date(), observedAt: plannedBoard?.direct?.lastSuccessfulUpdate)
        }
        return parseHHmm(departureDisplayTime(departure)) ?? parseHHmm(departure.departureTime.scheduled)
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
        let observed = plannedBoard?.direct?.lastSuccessfulUpdate
            ?? plannedBoard?.direct?.departures.compactMap(\.evidenceObservedAt).max()
        return "\(usesDirectDepartures)-\(firstLeg.fromStation.crs)-\(firstLeg.toStation.crs)-\(isExpanded)-\(ids)-\(observed?.timeIntervalSince1970 ?? 0)"
    }

    private func prefetchVisibleServiceDetails() async {
        let requestedTaskID = prefetchTaskID
        let visibleCount = isExpanded ? upcomingDepartures.count : defaultDepartureCount
        var ids = upcomingDepartures.prefix(visibleCount).map(\.serviceID)
        for leg in presentationGroup.legs.dropFirst() {
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
        let context = usesDirectDepartures ? ServiceDetailsLookupContext(fromCRS: firstLeg.fromStation.crs,
            toCRS: firstLeg.toStation.crs, originCRS: nil, operator: nil,
            destinationCRSs: [firstLeg.toStation.crs], length: nil) : nil
        await depStore.ensureServiceDetails(for: uniqueIDs, freshFor: usesDirectDepartures ? 30 : nil, context: context)
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
                    .foregroundStyle(carCount <= warningThreshold ? Color.plannerWarningText : Color.primary.opacity(0.65))
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
