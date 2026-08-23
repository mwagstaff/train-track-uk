import CoreLocation
import SwiftUI

struct InProgressJourneyView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var depStore: DeparturesStore
    @EnvironmentObject private var notificationStore: NotificationSubscriptionStore
    @EnvironmentObject private var recentStore: RecentServiceStore
    @EnvironmentObject private var activityManager: LiveActivityManager
    @EnvironmentObject private var historyStore: JourneyHistoryStore
    @EnvironmentObject private var router: TabRouter
    @ObservedObject private var coordinator = JourneyTrackingCoordinator.shared

    @AppStorage("inProgressSelectedSubscriptionID") private var selectedSubscriptionID = ""
    @State private var mapSelection: InProgressMapSelection?
    @State private var isShowingServicePicker = false
    @State private var isShowingEndConfirmation = false
    @State private var replacementChoice: JourneyChoice?
    @State private var isWorking = false

    @MainActor private var choices: [JourneyChoice] {
        var result = coordinator.armedCandidates.map(JourneyChoice.init(candidate:))
        if let active = coordinator.activeJourney {
            result.removeAll { $0.subscriptionID == active.subscriptionId }
            result.insert(JourneyChoice(checkpoint: active, status: "Underway"), at: 0)
        } else if let completed = coordinator.recentlyCompleted {
            result.removeAll { $0.subscriptionID == completed.checkpoint.subscriptionId }
            result.insert(JourneyChoice(
                checkpoint: completed.checkpoint,
                status: completed.outcome.displayName
            ), at: 0)
        }
        return result
    }

    private var effectiveSubscriptionID: String? {
        if let active = coordinator.activeJourney { return active.subscriptionId }
        if let completed = coordinator.recentlyCompleted { return completed.checkpoint.subscriptionId }
        if choices.contains(where: { $0.subscriptionID == selectedSubscriptionID }) {
            return selectedSubscriptionID
        }
        return choices.first?.subscriptionID
    }

    private var selectedCandidate: ArmedJourneyHistoryCandidate? {
        guard let effectiveSubscriptionID else { return nil }
        return coordinator.armedCandidates.first { $0.subscriptionId == effectiveSubscriptionID }
    }

    private var selectedSession: NotificationSubscription? {
        guard let effectiveSubscriptionID else { return nil }
        return notificationStore.liveSessions.first { $0.id == effectiveSubscriptionID }
    }

    private var selectedGroup: JourneyGroup? {
        if let active = coordinator.activeJourney { return makeGroup(stations: active.plannedStations) }
        if let completed = coordinator.recentlyCompleted { return makeGroup(stations: completed.checkpoint.plannedStations) }
        if let candidate = selectedCandidate { return makeGroup(stations: candidate.stations) }
        if let selectedSession { return makeGroup(legs: selectedSession.legs.filter(\.enabled)) }
        return nil
    }

    private var currentLegIndex: Int {
        min(coordinator.activeJourney?.plannedLegIndex ?? 0, max(0, (selectedGroup?.legs.count ?? 1) - 1))
    }

    private var currentJourney: Journey? {
        guard let group = selectedGroup, group.legs.indices.contains(currentLegIndex) else { return nil }
        return group.legs[currentLegIndex]
    }

    private var departureContextJourney: Journey? {
        guard let group = selectedGroup else { return nil }
        let index = currentLegIndex + (coordinator.activeJourney?.phase == .atInterchange ? 1 : 0)
        guard group.legs.indices.contains(index) else { return nil }
        return group.legs[index]
    }

    private var nextDeparture: DepartureV2? {
        guard let departureContextJourney else { return nil }
        return depStore.departures(for: departureContextJourney).first { !$0.isCancelled }
    }

    private var activeDeparture: DepartureV2? {
        guard let active = coordinator.activeJourney,
              let serviceID = active.currentLeg?.serviceID else { return nil }
        if let currentJourney,
           let departure = depStore.departure(
               serviceID: serviceID,
               fromCRS: currentJourney.fromStation.crs,
               toCRS: currentJourney.toStation.crs
           ) {
            return departure
        }
        guard let leg = active.currentLeg else { return nil }
        return DepartureV2(
            departureTime: DepartureTimeV2(
                scheduled: leg.scheduledDepartureAt.map(clockTime) ?? "Service",
                estimated: leg.estimatedDepartureTime ?? leg.scheduledDepartureAt.map(clockTime) ?? "Service"
            ),
            serviceType: "train",
            platform: nil,
            isCancelled: false,
            length: nil,
            destination: [PlaceInfoV2(crs: leg.toStation.crs, locationName: leg.toStation.name, via: nil)],
            origin: [PlaceInfoV2(crs: leg.fromStation.crs, locationName: leg.fromStation.name, via: nil)],
            serviceID: serviceID,
            delayReason: nil,
            cancelReason: nil,
            timestamp: nil
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let completion = coordinator.recentlyCompleted {
                    completionContent(completion)
                } else if let group = selectedGroup {
                    statusCard(group: group)
                    if coordinator.activeJourney == nil || coordinator.activeJourney?.phase == .atInterchange {
                        departureContext(group: group)
                    } else {
                        underwayContent(group: group)
                    }
                    manualActions
                } else {
                    ContentUnavailableView(
                        "No journey in progress",
                        systemImage: "location.slash",
                        description: Text("Start journey updates to see live progress here.")
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("In Progress")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { journeyChooserToolbar }
        .sheet(item: $mapSelection) { selection in
            ExpandedInProgressMap(selection: selection)
        }
        .sheet(isPresented: $isShowingServicePicker) {
            if let departureContextJourney {
                RecentServicePicker(
                    journey: departureContextJourney,
                    onSelect: selectService,
                    onSelectUnlisted: selectUnlistedService
                )
            }
        }
        .alert("End journey?", isPresented: $isShowingEndConfirmation) {
            Button("End journey", role: .destructive) { endJourney() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This records the journey as ended early and stops live updates.")
        }
        .alert(
            "Start a different journey?",
            isPresented: Binding(
                get: { replacementChoice != nil },
                set: { if !$0 { replacementChoice = nil } }
            ),
            presenting: replacementChoice
        ) { choice in
            Button("Start instead", role: .destructive) { replaceJourney(with: choice) }
            Button("Cancel", role: .cancel) { replacementChoice = nil }
        } message: { _ in
            Text("The current journey will be recorded as ended early.")
        }
        .task(id: refreshKey) { await refreshContent() }
        .task(id: coordinator.recentlyCompleted?.autoDismissAt) {
            guard let expiry = coordinator.recentlyCompleted?.autoDismissAt else { return }
            let delay = expiry.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            coordinator.pruneExpiredCompletion()
        }
        .onAppear {
            if selectedSubscriptionID.isEmpty, let effectiveSubscriptionID {
                selectedSubscriptionID = effectiveSubscriptionID
            }
        }
    }

    @ToolbarContentBuilder
    private var journeyChooserToolbar: some ToolbarContent {
        if choices.count > 1 {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(choices) { choice in
                        Button {
                            choose(choice)
                        } label: {
                            if choice.subscriptionID == effectiveSubscriptionID {
                                Label("\(choice.title) — \(choice.status)", systemImage: "checkmark")
                            } else {
                                Text("\(choice.title) — \(choice.status)")
                            }
                        }
                    }
                } label: {
                    Label("Change journey", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
    }

    private func statusCard(group: JourneyGroup) -> some View {
        let presentation = statusPresentation(group: group)
        return HStack(alignment: .top, spacing: 14) {
            Image(systemName: presentation.icon)
                .font(.title2.weight(.semibold))
                .foregroundStyle(presentation.color)
                .frame(width: 42, height: 42)
                .background(presentation.color.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func departureContext(group: JourneyGroup) -> some View {
        if let legGroup = departureContextGroup(from: group),
           let journey = legGroup.legs.first {
            VStack(alignment: .leading, spacing: 10) {
                Text("Next departures")
                    .font(.headline)
                JourneyCard(
                    group: legGroup,
                    isFavourite: false,
                    defaultDepartureCount: 3,
                    isLiveActive: true,
                    scheduledSubscriptions: [],
                    canAddSchedule: false,
                    isBusy: false,
                    isInteractive: true,
                    isExpanded: false,
                    canReverseJourney: false,
                    isJourneyReversed: false,
                    onToggleExpanded: {},
                    onToggleJourneyReversed: {},
                    onOpenDeparture: { journey, departure in
                        mapSelection = mapSelection(for: departure, journey: journey)
                    },
                    onToggleFavourite: {},
                    onToggleJourneyUpdates: {},
                    onAddJourneySchedule: {},
                    onEditJourneySchedule: { _ in },
                    onRemoveJourney: {},
                    showsHeader: false,
                    allowsExpansion: false
                )
            }

            if let nextDeparture {
                miniMap(
                    selection: mapSelection(for: nextDeparture, journey: journey),
                    title: "Next service location",
                    caption: serviceCaption(nextDeparture, destination: journey.toStation.name),
                    status: serviceStatus(nextDeparture, journey: journey)
                )
            }
        }
    }

    @ViewBuilder
    private func underwayContent(group: JourneyGroup) -> some View {
        if let active = coordinator.activeJourney,
           let departure = activeDeparture,
           let journey = currentJourney {
            etaCards(group: group, active: active, departure: departure)
            nextLegDepartures(group: group)
            miniMap(
                selection: mapSelection(
                    for: departure,
                    journey: journey,
                    fallback: historyCallingPoints(active.currentLeg)
                ),
                title: "Current train location",
                caption: serviceCaption(departure, destination: journey.toStation.name),
                status: serviceStatus(departure, journey: journey)
            )
        } else {
            ContentUnavailableView(
                "Service details unavailable",
                systemImage: "train.side.front.car",
                description: Text("This journey will continue without live train information. You can still advance it manually.")
            )
            .frame(minHeight: 180)
        }
    }

    @ViewBuilder
    private func nextLegDepartures(group: JourneyGroup) -> some View {
        if let nextLegGroup = nextLegGroup(from: group),
           let nextLeg = nextLegGroup.legs.first {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next leg departures")
                        .font(.headline)
                    Text("\(nextLeg.fromStation.name) to \(nextLeg.toStation.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                JourneyCard(
                    group: nextLegGroup,
                    isFavourite: false,
                    defaultDepartureCount: 3,
                    isLiveActive: true,
                    scheduledSubscriptions: [],
                    canAddSchedule: false,
                    isBusy: false,
                    isInteractive: true,
                    isExpanded: false,
                    canReverseJourney: false,
                    isJourneyReversed: false,
                    onToggleExpanded: {},
                    onToggleJourneyReversed: {},
                    onOpenDeparture: { journey, departure in
                        mapSelection = mapSelection(for: departure, journey: journey)
                    },
                    onToggleFavourite: {},
                    onToggleJourneyUpdates: {},
                    onAddJourneySchedule: {},
                    onEditJourneySchedule: { _ in },
                    onRemoveJourney: {},
                    showsHeader: false,
                    allowsExpansion: false
                )
            }
        }
    }

    private func etaCards(
        group: JourneyGroup,
        active: ActiveJourneyHistoryCheckpoint,
        departure: DepartureV2
    ) -> some View {
        Group {
            if nextLegGroup(from: group) == nil {
                finalDestinationETACard(group: group, departure: departure)
            } else {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) {
                        currentLegETACard(group: group, active: active, departure: departure)
                        finalDestinationETACard(group: group, departure: departure)
                    }
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        currentLegETACard(group: group, active: active, departure: departure)
                        finalDestinationETACard(group: group, departure: departure)
                    }
                }
            }
        }
    }

    @MainActor private func currentLegETACard(
        group: JourneyGroup,
        active: ActiveJourneyHistoryCheckpoint,
        departure: DepartureV2
    ) -> some View {
        etaCard(
            label: "\(active.currentPlannedLegDestination.name) ETA",
            subtitle: estimatedChangeTime(group: group, departure: departure),
            time: currentLegETA(active: active, departure: departure)
        )
    }

    @MainActor private func finalDestinationETACard(
        group: JourneyGroup,
        departure: DepartureV2
    ) -> some View {
        etaCard(
            label: "Final destination",
            subtitle: group.endStation.name,
            time: finalDestinationETA(group: group, departure: departure)
        )
    }

    @MainActor private func etaCard(label: String, subtitle: String, time: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            Text(time.map(JourneyCardPresentation.arrivalTimeLabel) ?? "Unavailable")
                .font(.title2.weight(.bold))
                .monospacedDigit()
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private func miniMap(
        selection: InProgressMapSelection,
        title: String,
        caption: String,
        status: (text: String, color: Color)
    ) -> some View {
        Button {
            mapSelection = selection
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                        Text(status.text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.top, 2)
                }
                ServiceMapView(
                    serviceID: selection.serviceID,
                    fromCRS: selection.fromCRS,
                    toCRS: selection.toCRS,
                    departureTime: selection.departureTime,
                    destinationName: selection.destinationName,
                    fallbackCallingPoints: selection.fallbackCallingPoints,
                    isCompact: true
                )
                .frame(height: 220)
                .allowsHitTesting(false)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                Label("Expand map", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(14)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens an interactive service map")
    }

    @ViewBuilder
    private var manualActions: some View {
        VStack(spacing: 12) {
            if let candidate = selectedCandidate, coordinator.activeJourney == nil {
                if candidate.originArrivedAt == nil {
                    actionButton("I’m at \(candidate.stations.first?.name ?? "the station")", icon: "mappin.and.ellipse") {
                        run { await coordinator.manuallyConfirmOriginArrival(subscriptionID: candidate.subscriptionId) }
                    }
                } else {
                    actionButton("Choose the train I caught", icon: "train.side.front.car") {
                        isShowingServicePicker = true
                    }
                }
            } else if let active = coordinator.activeJourney {
                if active.phase == .atInterchange {
                    actionButton("Choose my next train", icon: "arrow.triangle.branch") {
                        isShowingServicePicker = true
                    }
                } else {
                    actionButton("I’ve arrived at \(active.currentPlannedLegDestination.name)", icon: "checkmark.circle.fill") {
                        run { await coordinator.manuallyConfirmNextLegEndpoint() }
                    }
                    Button("Change the train I’m on") { isShowingServicePicker = true }
                        .buttonStyle(.bordered)
                }
                Button("End journey", role: .destructive) { isShowingEndConfirmation = true }
                    .font(.subheadline.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func actionButton(
        _ title: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if isWorking { ProgressView() } else { Label(title, systemImage: icon) }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isWorking)
    }

    private func completionContent(_ completion: RecentlyCompletedJourneyCheckpoint) -> some View {
        let record = historyStore.records.first { $0.id == completion.checkpoint.id }
        return VStack(spacing: 20) {
            Image(systemName: completion.outcome == .completed ? "checkmark.circle.fill" : "flag.checkered")
                .font(.system(size: 54))
                .foregroundStyle(completion.outcome == .completed ? Color.green : Color.orange)
            VStack(spacing: 6) {
                Text(completion.outcome.displayName)
                    .font(.title2.bold())
                Text("\(completion.checkpoint.plannedOrigin.name) to \(completion.checkpoint.plannedDestination.name)")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text(completionTimingSummary(completion, record: record))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let record, record.isDelayRepay15Plus {
                JourneyHistoryDelayRepayActions(record: record)
                    .frame(maxWidth: 360)
            }

            if let record {
                Button {
                    router.openHistoryRecord(id: record.id)
                } label: {
                    Label("View in your journey history", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            Button("Close") {
                coordinator.clearRecentlyCompletedJourney()
                router.selected = .history
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("This screen closes automatically one hour after the journey ended.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .task(id: completion.checkpoint.id) {
            guard let record else { return }
            _ = await historyStore.refreshOfficialArrival(for: record)
        }
    }

    private func completionTimingSummary(
        _ completion: RecentlyCompletedJourneyCheckpoint,
        record: JourneyHistoryRecord?
    ) -> String {
        let legs = record?.legs ?? completion.checkpoint.legs
        let firstLeg = legs.min { $0.plannedLegIndex < $1.plannedLegIndex }
        let departure = firstLeg?.actualDepartureAt
            ?? firstLeg?.detectedDepartureAt
            ?? record?.detectedDepartureAt
            ?? completion.checkpoint.detectedDepartureAt
        let finalLeg = legs.max { $0.plannedLegIndex < $1.plannedLegIndex }
        let arrival = record?.actualArrivalAt
            ?? finalLeg?.actualArrivalAt
            ?? record?.detectedArrivalAt
            ?? completion.checkpoint.detectedArrivalAt
            ?? completion.completedAt
        let delay = record?.delayMinutes ?? JourneyHistoryDelayPolicy.confirmedDelayMinutes(
            scheduledArrival: finalLeg?.scheduledArrivalAt,
            actualArrival: finalLeg?.actualArrivalAt
        )
        let status: String
        if let delay {
            if delay == 0 {
                status = "on time"
            } else {
                status = "\(delay) min\(delay == 1 ? "" : "s") late"
            }
        } else if completion.outcome == .completed {
            status = "confirmation pending"
        } else {
            status = completion.outcome.displayName.lowercased()
        }
        return "\(clockTime(departure)) → \(clockTime(arrival)) (\(status))"
    }

    private func statusPresentation(group: JourneyGroup) -> (title: String, detail: String, icon: String, color: Color) {
        if let active = coordinator.activeJourney {
            if active.phase == .atInterchange {
                return (
                    "At \(active.currentPlannedLegDestination.name)",
                    "Choose the service you caught for the next leg to \(active.plannedDestination.name).",
                    "arrow.triangle.branch",
                    .orange
                )
            }
            let detail = activeDeparture.map {
                "You’re on the \(onboardServiceCaption($0, destination: active.currentPlannedLegDestination.name))."
            } ?? "You’re travelling to \(active.currentPlannedLegDestination.name) on an unlisted service."
            return (
                "Journey underway",
                detail,
                "train.side.front.car",
                .blue
            )
        }
        if selectedCandidate?.originArrivedAt != nil {
            return (
                "At \(group.startStation.name)",
                "Select the train you caught when you leave the station.",
                "building.2.fill",
                .blue
            )
        }
        return (
            "Waiting for you to arrive",
            "Journey tracking is watching for your arrival at \(group.startStation.name).",
            "location.fill",
            .blue
        )
    }

    private func currentLegETA(
        active: ActiveJourneyHistoryCheckpoint,
        departure: DepartureV2
    ) -> String? {
        let destinationCRS = active.currentPlannedLegDestination.crs
        if let details = depStore.serviceDetailsById[departure.serviceID],
           let point = details.stationBranches.flatMap({ $0 }).first(where: {
               $0.crs.caseInsensitiveCompare(destinationCRS) == .orderedSame
           }) {
            return point.displayTime
        }
        return active.currentLeg?.callingPoints.first(where: {
            $0.crs.caseInsensitiveCompare(destinationCRS) == .orderedSame
        }).map { $0.actualTime ?? $0.estimatedTime ?? $0.scheduledTime }
    }

    private func finalDestinationETA(group: JourneyGroup, departure: DepartureV2) -> String? {
        remainingItinerary(group: group, departure: departure)?.finalArrivalTime
    }

    private func estimatedChangeTime(group: JourneyGroup, departure: DepartureV2) -> String {
        guard let itinerary = remainingItinerary(group: group, departure: departure),
              itinerary.legs.count > 1,
              let minutes = JourneyItineraryBuilder.connectionMinutes(
                  arrivingAt: itinerary.legs[0].arrivalDate,
                  departingAt: itinerary.legs[1].departureDate
              ) else {
            return "Est. change time unavailable"
        }
        return "Est. change time: \(minutes) min\(minutes == 1 ? "" : "s")"
    }

    private func remainingItinerary(
        group: JourneyGroup,
        departure: DepartureV2
    ) -> JourneyItinerary? {
        guard let remaining = remainingGroup(from: group) else { return nil }
        return JourneyItineraryBuilder.build(
            group: remaining,
            firstDeparture: departure,
            departuresForJourney: depStore.departures(for:),
            serviceDetailsByID: depStore.serviceDetailsById
        )
    }

    private func remainingGroup(from group: JourneyGroup) -> JourneyGroup? {
        guard group.legs.indices.contains(currentLegIndex) else { return nil }
        let legs = Array(group.legs[currentLegIndex...]).enumerated().map { index, journey in
            Journey(
                id: journey.id,
                groupId: group.id,
                legIndex: index,
                fromStation: journey.fromStation,
                toStation: journey.toStation,
                createdAt: journey.createdAt,
                favorite: false
            )
        }
        return JourneyGroup(id: group.id, legs: legs)
    }

    private func nextLegGroup(from group: JourneyGroup) -> JourneyGroup? {
        let nextIndex = currentLegIndex + 1
        guard group.legs.indices.contains(nextIndex) else { return nil }
        let next = group.legs[nextIndex]
        let leg = Journey(
            id: next.id,
            groupId: group.id,
            legIndex: 0,
            fromStation: next.fromStation,
            toStation: next.toStation,
            createdAt: next.createdAt,
            favorite: false
        )
        return JourneyGroup(id: group.id, legs: [leg])
    }

    private func departureContextGroup(from group: JourneyGroup) -> JourneyGroup? {
        if coordinator.activeJourney?.phase == .atInterchange {
            return nextLegGroup(from: group)
        }
        return remainingGroup(from: group)
    }

    private var refreshKey: String {
        let groupKey = selectedGroup?.legs.map { "\($0.fromStation.crs)-\($0.toStation.crs)" }.joined(separator: "|") ?? "none"
        let phase = coordinator.activeJourney?.phase.rawValue ?? "inactive"
        return "\(effectiveSubscriptionID ?? "none"):\(currentLegIndex):\(phase):\(groupKey)"
    }

    private func refreshContent() async {
        guard let group = selectedGroup else { return }
        for journey in group.legs.dropFirst(currentLegIndex) {
            await depStore.refreshSpecificJourney(
                fromCRS: journey.fromStation.crs,
                toCRS: journey.toStation.crs
            )
        }
        guard let departureContextJourney else { return }
        await recentStore.refresh(
            fromCRS: departureContextJourney.fromStation.crs,
            toCRS: departureContextJourney.toStation.crs
        )
        var ids = depStore.departures(for: departureContextJourney).prefix(3).map(\.serviceID)
        if let activeID = coordinator.activeJourney?.currentLeg?.serviceID { ids.append(activeID) }
        _ = await depStore.ensureServiceDetails(for: Array(Set(ids)))
    }

    private func selectService(_ recent: RecentDepartureV2) {
        guard let currentJourney else { return }
        isShowingServicePicker = false
        let departure = departure(from: recent, journey: currentJourney)
        run {
            if let active = coordinator.activeJourney {
                if active.phase == .atInterchange {
                    await coordinator.manuallyBoardNextLeg(departure: departure)
                } else {
                    await coordinator.manuallyReplaceCurrentService(with: departure)
                }
            } else if let candidate = selectedCandidate {
                await coordinator.manuallyBoard(subscriptionID: candidate.subscriptionId, departure: departure)
            }
        }
    }

    private func selectUnlistedService() {
        isShowingServicePicker = false
        run {
            if let active = coordinator.activeJourney {
                if active.phase == .atInterchange {
                    await coordinator.manuallyBoardNextLegWithoutMatchedService()
                } else {
                    await coordinator.manuallyUseUnlistedService()
                }
            } else if let candidate = selectedCandidate {
                await coordinator.manuallyBoardWithoutMatchedService(
                    subscriptionID: candidate.subscriptionId
                )
            }
        }
    }

    private func choose(_ choice: JourneyChoice) {
        if let active = coordinator.activeJourney, active.subscriptionId != choice.subscriptionID {
            replacementChoice = choice
        } else {
            selectedSubscriptionID = choice.subscriptionID
        }
    }

    private func replaceJourney(with choice: JourneyChoice) {
        replacementChoice = nil
        run {
            await coordinator.endActiveJourney()
            if let session = notificationStore.liveSessions.first(where: { $0.id == choice.subscriptionID }) {
                await coordinator.arm(
                    subscription: session,
                    source: session.liveSessionOrigin == .scheduled ? .scheduled : .adhoc
                )
            }
            selectedSubscriptionID = choice.subscriptionID
        }
    }

    private func endJourney() {
        guard let active = coordinator.activeJourney else { return }
        run {
            if let session = notificationStore.liveSessions.first(where: { $0.id == active.subscriptionId }) {
                try? await notificationStore.deleteLiveSession(id: session.id)
            }
            await activityManager.stopJourneyActivities(
                deepLinkFromCRS: active.plannedOrigin.crs,
                deepLinkToCRS: active.plannedDestination.crs
            )
            await coordinator.endActiveJourney()
        }
    }

    private func run(_ operation: @escaping @MainActor () async -> Void) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await operation()
            isWorking = false
        }
    }

    private func mapSelection(
        for departure: DepartureV2,
        journey: Journey,
        fallback: [CallingPoint] = []
    ) -> InProgressMapSelection {
        InProgressMapSelection(
            serviceID: departure.serviceID,
            fromCRS: journey.fromStation.crs,
            toCRS: journey.toStation.crs,
            departureTime: JourneyItineraryBuilder.departureDisplayTime(departure),
            destinationName: journey.toStation.name,
            fallbackCallingPoints: fallback
        )
    }

    private func serviceCaption(_ departure: DepartureV2, destination: String) -> String {
        let operatorName = depStore.serviceDetailsById[departure.serviceID]?.operator
        return [
            JourneyItineraryBuilder.departureDisplayTime(departure),
            operatorName,
            "to \(destination)"
        ].compactMap { $0 }.joined(separator: " ")
    }

    private func onboardServiceCaption(_ departure: DepartureV2, destination: String) -> String {
        let operatorName = depStore.serviceDetailsById[departure.serviceID]?.operator.map { "(\($0))" }
        return [
            JourneyItineraryBuilder.departureDisplayTime(departure),
            operatorName,
            "to \(destination)"
        ].compactMap { $0 }.joined(separator: " ")
    }

    private func serviceStatus(
        _ departure: DepartureV2,
        journey: Journey
    ) -> (text: String, color: Color) {
        if departure.isCancelled {
            return ("Service cancelled", .red)
        }
        if let details = depStore.serviceDetailsById[departure.serviceID],
           let live = computeLiveStatus(
               from: details,
               within: journey.fromStation.crs,
               toCRS: journey.toStation.crs
           ) {
            let color: Color = live.delayMinutes >= 5 ? .red : (live.delayMinutes > 0 ? .yellow : .green)
            return (live.text, color)
        }
        return ("Live status unavailable", .secondary)
    }

    private func historyCallingPoints(_ leg: JourneyHistoryLeg?) -> [CallingPoint] {
        (leg?.serviceCallingPoints ?? leg?.callingPoints ?? []).map { point in
            CallingPoint(
                locationName: point.locationName,
                crs: point.crs,
                st: point.scheduledTime,
                et: point.estimatedTime,
                at: point.actualTime,
                isCancelled: false,
                cancelReason: nil,
                platform: nil,
                length: nil,
                detachFront: nil,
                affectedByDiversion: false,
                rerouteDelay: 0
            )
        }
    }

    private func departure(from recent: RecentDepartureV2, journey: Journey) -> DepartureV2 {
        DepartureV2(
            departureTime: DepartureTimeV2(
                scheduled: recent.scheduledDeparture,
                estimated: recent.actualDeparture ?? recent.estimatedDeparture ?? recent.scheduledDeparture
            ),
            serviceType: recent.serviceType,
            platform: recent.platform,
            isCancelled: recent.isCancelled,
            length: nil,
            destination: [PlaceInfoV2(crs: journey.toStation.crs, locationName: journey.toStation.name, via: nil)],
            origin: [PlaceInfoV2(crs: journey.fromStation.crs, locationName: journey.fromStation.name, via: nil)],
            serviceID: recent.serviceID,
            delayReason: nil,
            cancelReason: nil,
            timestamp: recent.lastObservedAt
        )
    }

    private func makeGroup(stations: [Station]) -> JourneyGroup? {
        guard stations.count >= 2 else { return nil }
        let groupID = UUID()
        let legs = stations.indices.dropLast().map { index in
            Journey(
                id: UUID(),
                groupId: groupID,
                legIndex: index,
                fromStation: stations[index],
                toStation: stations[index + 1],
                createdAt: Date(),
                favorite: false
            )
        }
        return JourneyGroup(id: groupID, legs: legs)
    }

    private func makeGroup(legs: [NotificationLeg]) -> JourneyGroup? {
        guard let first = legs.first else { return nil }
        let stations = [station(crs: first.from, name: first.fromName)]
            + legs.map { station(crs: $0.to, name: $0.toName) }
        return makeGroup(stations: stations)
    }

    private func station(crs: String, name: String?) -> Station {
        StationsService.shared.stations.first {
            $0.crs.caseInsensitiveCompare(crs) == .orderedSame
        } ?? Station(crs: crs.uppercased(), name: name ?? crs.uppercased(), longitude: "0", latitude: "0")
    }

    private func clockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

private struct JourneyChoice: Identifiable {
    let subscriptionID: String
    let title: String
    let status: String

    var id: String { subscriptionID }

    init(candidate: ArmedJourneyHistoryCandidate) {
        subscriptionID = candidate.subscriptionId
        title = Self.routeTitle(candidate.stations)
        status = candidate.originArrivedAt == nil ? "Waiting to start" : "At start station"
    }

    init(checkpoint: ActiveJourneyHistoryCheckpoint, status: String) {
        subscriptionID = checkpoint.subscriptionId
        title = Self.routeTitle(checkpoint.plannedStations)
        self.status = status
    }

    private static func routeTitle(_ stations: [Station]) -> String {
        guard let first = stations.first, let last = stations.last else { return "Journey" }
        return "\(first.name) → \(last.name)"
    }
}

private struct InProgressMapSelection: Identifiable {
    let serviceID: String
    let fromCRS: String
    let toCRS: String
    let departureTime: String
    let destinationName: String
    let fallbackCallingPoints: [CallingPoint]

    var id: String { "\(serviceID):\(fromCRS):\(toCRS)" }
}

private struct ExpandedInProgressMap: View {
    let selection: InProgressMapSelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ServiceMapView(
                serviceID: selection.serviceID,
                fromCRS: selection.fromCRS,
                toCRS: selection.toCRS,
                departureTime: selection.departureTime,
                destinationName: selection.destinationName,
                fallbackCallingPoints: selection.fallbackCallingPoints
            )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct RecentServicePicker: View {
    let journey: Journey
    let onSelect: (RecentDepartureV2) -> Void
    let onSelectUnlisted: () -> Void

    @EnvironmentObject private var recentStore: RecentServiceStore
    @EnvironmentObject private var depStore: DeparturesStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var location = LocationManagerPhone()
    @State private var hasLoadedPreviousDepartures = false

    private var departures: [RecentDepartureV2] {
        recentStore.departures(
            fromCRS: journey.fromStation.crs,
            toCRS: journey.toStation.crs
        ).sorted(by: isMoreLikely)
    }

    var body: some View {
        NavigationStack {
            List {
                if !hasLoadedPreviousDepartures {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading departures from the last two hours…")
                            .foregroundStyle(.secondary)
                    }
                } else if departures.isEmpty {
                    ContentUnavailableView(
                        "No recent services",
                        systemImage: "clock.badge.questionmark",
                        description: Text("No services were observed in the last two hours.")
                    )
                } else {
                    Section("Tap the service you caught") {
                        ForEach(Array(departures.enumerated()), id: \.element.id) { index, departure in
                            Button { onSelect(departure) } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(departure.scheduledDeparture)
                                                    .font(.title3.weight(.semibold))
                                                    .monospacedDigit()
                                                Text(reportedDepartureText(departure))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            PlatformBadge(
                                                platform: departure.platform ?? "TBC",
                                                isBus: departure.serviceType.lowercased() == "bus"
                                            )
                                        }
                                        if index == 0 {
                                            Label("Most likely", systemImage: "sparkles")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(Color.accentColor)
                                        }
                                        Text(statusText(departure))
                                            .font(.subheadline)
                                            .foregroundStyle(departure.isCancelled ? Color.red : Color.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                        .accessibilityHidden(true)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Selects this service for your journey")
                        }
                    }
                }

                if hasLoadedPreviousDepartures {
                    Section {
                        Button(action: onSelectUnlisted) {
                            HStack(spacing: 12) {
                                Image(systemName: "questionmark.circle")
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("I got another service not shown here")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("Continue without linking a listed train")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Continues the journey without matching a service")
                    }
                }
            }
            .navigationTitle("Choose your service")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                location.request(forceFresh: true)
                await recentStore.refresh(
                    fromCRS: journey.fromStation.crs,
                    toCRS: journey.toStation.crs
                )
                hasLoadedPreviousDepartures = true
                _ = await depStore.ensureServiceDetails(
                    for: recentStore.departures(
                        fromCRS: journey.fromStation.crs,
                        toCRS: journey.toStation.crs
                    ).map(\.serviceID),
                    force: true
                )
            }
        }
    }

    private func isMoreLikely(_ left: RecentDepartureV2, _ right: RecentDepartureV2) -> Bool {
        if left.isCancelled != right.isCancelled { return !left.isCancelled }
        let leftDistance = distanceToEstimatedTrain(left)
        let rightDistance = distanceToEstimatedTrain(right)
        if let leftDistance, let rightDistance, leftDistance != rightDistance {
            return leftDistance < rightDistance
        }
        if leftDistance != nil && rightDistance == nil { return true }
        if leftDistance == nil && rightDistance != nil { return false }
        let now = Date()
        let leftDifference = abs(
            (left.actualDepartureAt ?? left.estimatedDepartureAt ?? left.scheduledDepartureAt)
                .timeIntervalSince(now)
        )
        let rightDifference = abs(
            (right.actualDepartureAt ?? right.estimatedDepartureAt ?? right.scheduledDepartureAt)
                .timeIntervalSince(now)
        )
        return leftDifference < rightDifference
    }

    private func reportedDepartureText(_ departure: RecentDepartureV2) -> String {
        if let actual = normalizedTime(departure.actualDeparture) {
            return "Actual: \(actual)"
        }
        if let expected = normalizedTime(departure.estimatedDeparture) {
            if expected.caseInsensitiveCompare("On time") == .orderedSame {
                return "Expected: \(departure.scheduledDeparture)"
            }
            return "Expected: \(expected)"
        }
        return "Actual/expected: Not reported"
    }

    private func normalizedTime(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }

    private func distanceToEstimatedTrain(_ departure: RecentDepartureV2) -> CLLocationDistance? {
        guard let userLocation = location.lastLocation,
              let details = depStore.serviceDetailsById[departure.serviceID] else { return nil }
        let stations = details.stationBranches.first(where: { branch in
            branch.contains { $0.crs.caseInsensitiveCompare(journey.toStation.crs) == .orderedSame }
        }) ?? details.allStations
        let progress = ServiceProgressEstimator.estimate(for: stations, at: Date())
        guard progress.isAvailable,
              stations.indices.contains(progress.previousStationIndex),
              stations.indices.contains(progress.nextStationIndex),
              let previous = stationLocation(stations[progress.previousStationIndex].crs),
              let next = stationLocation(stations[progress.nextStationIndex].crs) else { return nil }
        let fraction = min(max(progress.fraction, 0), 1)
        let estimate = CLLocation(
            latitude: previous.coordinate.latitude + ((next.coordinate.latitude - previous.coordinate.latitude) * fraction),
            longitude: previous.coordinate.longitude + ((next.coordinate.longitude - previous.coordinate.longitude) * fraction)
        )
        return userLocation.distance(from: estimate)
    }

    private func stationLocation(_ crs: String) -> CLLocation? {
        guard let station = StationsService.shared.stations.first(where: {
            $0.crs.caseInsensitiveCompare(crs) == .orderedSame
        }), station.hasUsableCoordinate else { return nil }
        return CLLocation(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude)
    }

    private func statusText(_ departure: RecentDepartureV2) -> String {
        if departure.isCancelled { return "Service cancelled" }
        guard let details = depStore.serviceDetailsById[departure.serviceID],
              let live = computeLiveStatus(
                  from: details,
                  within: journey.fromStation.crs,
                  toCRS: journey.toStation.crs
              ) else {
            return "Live position unavailable"
        }
        return live.text
    }
}
