import SwiftUI

extension SavedRouteBoardState {
    func upcomingJourneys(at now: Date) -> [PlannedJourney] {
        (result?.journeys ?? []).filter { $0.departure >= now }
    }

    func liveIsStale(at now: Date) -> Bool {
        guard let result else { return false }
        return result.journeys.contains { liveIsStale(for: $0, at: now) }
    }

    func liveIsStale(for journey: PlannedJourney, at now: Date) -> Bool {
        PlannerLivePresentation.hasExpiredEvidence(for: journey, context: result?.live, at: now)
    }
}

struct SavedRouteJourneyOption: Identifiable {
    let journey: PlannedJourney
    let response: PlannerSearchResponse
    let semanticKey: String

    var id: String { semanticKey }
}

/// Lets journey details follow the saved route's board as it refreshes.
struct SavedRouteJourneyReference: Hashable {
    let group: JourneyGroup
    let semanticKey: String
}

extension SavedRoutePlannerStore {
    func currentJourney(for reference: SavedRouteJourneyReference) -> PlannerJourneyResponse? {
        for response in [state(for: reference.group).result, laterState(for: reference.group)?.result].compactMap({ $0 }) {
            if let journey = (response.journeys + (response.disruptedJourneys ?? [])).first(where: {
                SavedRouteJourneyPresentation.semanticKey(for: $0) == reference.semanticKey
            }) {
                return PlannerJourneyResponse(journey: journey, dataset: response.dataset, live: response.live)
            }
        }
        return nil
    }
}

enum SavedRouteJourneyPresentation {
    static func merged(
        primary: PlannerSearchResponse?,
        supplemental: PlannerSearchResponse?,
        at now: Date
    ) -> [SavedRouteJourneyOption] {
        var seen = Set<String>()
        var options: [SavedRouteJourneyOption] = []

        // Preserve the primary board's copy when the supplemental timetable
        // search returns the same scheduled journey.
        for response in [primary, supplemental].compactMap({ $0 }) {
            for journey in response.journeys where journey.departure >= now {
                let key = semanticKey(for: journey)
                guard seen.insert(key).inserted else { continue }
                options.append(SavedRouteJourneyOption(journey: journey, response: response, semanticKey: key))
            }
        }

        return options.sorted {
            if $0.journey.departure != $1.journey.departure {
                return $0.journey.departure < $1.journey.departure
            }
            if $0.journey.arrival != $1.journey.arrival {
                return $0.journey.arrival < $1.journey.arrival
            }
            return $0.semanticKey < $1.semanticKey
        }
    }

    /// Options taking far longer than the fastest (such as overnight connections) are rarely
    /// wanted, so they sit behind a disclosure rather than taking a place on the card.
    static func splitMuchSlower(_ options: [SavedRouteJourneyOption]) -> (usual: [SavedRouteJourneyOption], muchSlower: [SavedRouteJourneyOption]) {
        guard let fastest = options.compactMap({ JourneyDurationComparison.durationMinutes($0.journey) }).min() else {
            return (options, [])
        }
        func isMuchSlower(_ option: SavedRouteJourneyOption) -> Bool {
            guard let duration = JourneyDurationComparison.durationMinutes(option.journey) else { return false }
            return duration >= 2 * fastest && duration - fastest >= 60
        }
        return (options.filter { !isMuchSlower($0) }, options.filter(isMuchSlower))
    }

    static func semanticKey(for journey: PlannedJourney) -> String {
        let serviceIDs = journey.legs.filter { $0.kind == "vehicle" }.compactMap { serviceID(for: $0) }
        guard !serviceIDs.isEmpty else {
            // Without a train identity, avoid incorrectly merging two genuinely
            // different options which happen to share public times and stations.
            return "id:\(journey.id)"
        }

        let route = journey.legs.map { leg in
            [
                leg.kind,
                leg.mode,
                leg.from.crs,
                leg.to.crs,
                leg.operator ?? "",
                serviceID(for: leg) ?? "",
                leg.originDate ?? "",
                String((leg.scheduledDeparture ?? leg.departure).timeIntervalSince1970),
                String((leg.scheduledArrival ?? leg.arrival).timeIntervalSince1970),
                (leg.callingPoints ?? []).map(\.station.crs).joined(separator: ",")
            ].joined(separator: "|")
        }.joined(separator: ";")
        let departure = (journey.scheduledDeparture ?? journey.departure).timeIntervalSince1970
        let arrival = (journey.scheduledArrival ?? journey.arrival).timeIntervalSince1970
        return [
            String(departure),
            String(arrival),
            String(journey.changes),
            route
        ].joined(separator: "#")
    }

    private static func serviceID(for leg: PlannedJourney.Leg) -> String? {
        if let scheduled = leg.scheduledServiceId, !scheduled.isEmpty { return scheduled }
        if let live = leg.serviceId, !live.isEmpty { return live }
        return nil
    }
}

struct SavedRouteBoardView: View {
    let state: SavedRouteBoardState
    let routeKey: String
    let departureCount: Int
    let isInteractive: Bool
    let isExpanded: Bool
    let onRetry: (() -> Void)?
    var supplementalState: SavedRouteBoardState? = nil
    var onRetrySupplemental: (() -> Void)? = nil
    var showsEmptyState = true
    /// Cards live inside List rows, where a row's NavigationLinks all fire together and each
    /// gains a List chevron. The hosting screen pushes the chosen journey (and its semantic key) instead.
    var onOpenJourney: ((PlannerJourneyResponse, String) -> Void)? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            VStack(alignment: .leading, spacing: 0) {
                if let message = state.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).padding(16)
                }
                let supplemental = isExpanded ? supplementalState : nil
                let options = SavedRouteJourneyPresentation.merged(
                    primary: state.result,
                    supplemental: supplemental?.result,
                    at: context.date
                )
                let hasResult = state.result != nil || supplemental?.result != nil
                if hasResult {
                    if options.isEmpty && showsEmptyState && !state.isPending
                        && supplemental?.isPending != true && state.message == nil && supplemental?.message == nil {
                        Text("No journeys found in this time window.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(16)
                    }
                    let split = SavedRouteJourneyPresentation.splitMuchSlower(options)
                    let visible = Array(split.usual.prefix(isExpanded ? split.usual.count : departureCount))
                    // Only mention slow options that would otherwise have appeared on the card.
                    let hiddenSlower = isExpanded ? split.muchSlower : split.muchSlower.filter {
                        $0.journey.departure <= (visible.last?.journey.departure ?? .distantFuture)
                    }
                    let comparison = JourneyDurationComparison(journeys: visible.map(\.journey))
                    ForEach(visible) { option in
                        if isInteractive, let onOpenJourney {
                            Button {
                                onOpenJourney(detailResponse(option), option.semanticKey)
                            } label: {
                                summary(
                                    option.journey,
                                    at: context.date,
                                    live: option.response.live,
                                    durationTag: comparison.tag(for: option.journey)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("saved-route.journey.\(option.journey.id)")
                        } else {
                            summary(
                                option.journey,
                                at: context.date,
                                live: option.response.live,
                                durationTag: comparison.tag(for: option.journey)
                            )
                        }
                        if option.id != visible.last?.id { Divider().padding(.horizontal, 16) }
                    }
                    if !hiddenSlower.isEmpty {
                        Divider().padding(.horizontal, 16)
                        DisclosureGroup("\(hiddenSlower.count) much slower \(hiddenSlower.count == 1 ? "journey" : "journeys")") {
                            Text("Hidden because they take far longer than the fastest option, for example overnight connections.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            ForEach(hiddenSlower) { option in
                                Group {
                                    if isInteractive, let onOpenJourney {
                                        Button {
                                            onOpenJourney(detailResponse(option), option.semanticKey)
                                        } label: {
                                            summary(option.journey, at: context.date, live: option.response.live)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier("saved-route.journey.\(option.journey.id)")
                                    } else {
                                        summary(option.journey, at: context.date, live: option.response.live)
                                    }
                                }
                                // Rows carry their own inset; align them with the card's other rows.
                                .padding(.horizontal, -16)
                            }
                        }
                        .disclosureGroupStyle(NavigationChevronDisclosureStyle())
                        .font(.subheadline).padding(16).disabled(!isInteractive)
                        .accessibilityIdentifier("saved-route.slower-journeys")
                    }
                    let disrupted = mergedDisruptedJourneys(
                        primary: state.result,
                        supplemental: supplemental?.result,
                        at: context.date
                    )
                    if !disrupted.isEmpty {
                        DisclosureGroup("Disrupted journeys") {
                            ForEach(disrupted) { option in
                                if isInteractive, let onOpenJourney {
                                    Button {
                                        onOpenJourney(detailResponse(option), option.semanticKey)
                                    } label: {
                                        disruptedSummary(option, at: context.date)
                                    }
                                    .buttonStyle(.plain)
                                } else {
                                    disruptedSummary(option, at: context.date)
                                }
                            }
                        }
                        .disclosureGroupStyle(NavigationChevronDisclosureStyle())
                        .font(.subheadline).padding(16).disabled(!isInteractive)
                    }
                } else if !state.isPending {
                    if state.message == nil {
                        Text("Journey options are temporarily unavailable.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(16)
                    }
                    if let onRetry, isInteractive {
                        Button(action: onRetry) {
                            Label("Try again", systemImage: "arrow.clockwise")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityIdentifier("saved-route.retry.\(routeKey)")
                    }
                }
                if let supplemental {
                    supplementalStatus(supplemental)
                }
            }
        }
    }

    private func detailResponse(_ option: SavedRouteJourneyOption) -> PlannerJourneyResponse {
        PlannerJourneyResponse(journey: option.journey, dataset: option.response.dataset, live: option.response.live)
    }

    private func disruptedSummary(_ option: SavedRouteJourneyOption, at now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Unavailable option").font(.caption.weight(.semibold)).foregroundStyle(.red)
            summary(option.journey, at: now, live: option.response.live)
        }
    }

    @ViewBuilder
    private func supplementalStatus(_ supplemental: SavedRouteBoardState) -> some View {
        if let message = supplemental.message {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .padding(16)
            retrySupplementalButton
        } else if supplemental.result == nil && !supplemental.isPending {
            Text("More departures are temporarily unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
            retrySupplementalButton
        }
    }

    @ViewBuilder
    private var retrySupplementalButton: some View {
        if let onRetrySupplemental, isInteractive {
            Button(action: onRetrySupplemental) {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityIdentifier("saved-route.retry.later-\(routeKey)")
        }
    }

    private func mergedDisruptedJourneys(
        primary: PlannerSearchResponse?,
        supplemental: PlannerSearchResponse?,
        at now: Date
    ) -> [SavedRouteJourneyOption] {
        func disruptedResponse(_ response: PlannerSearchResponse?) -> PlannerSearchResponse? {
            guard let response, let journeys = response.disruptedJourneys else { return nil }
            return PlannerSearchResponse(
                journeys: journeys,
                dataset: response.dataset,
                search: response.search,
                warnings: response.warnings,
                pagination: response.pagination,
                live: response.live,
                disruptedJourneys: nil
            )
        }
        return SavedRouteJourneyPresentation.merged(
            primary: disruptedResponse(primary),
            supplemental: disruptedResponse(supplemental),
            at: now
        )
    }

    private func summary(
        _ journey: PlannedJourney,
        at date: Date,
        live: PlannerLiveContext?,
        durationTag: JourneyDurationTag? = nil
    ) -> some View {
        // Evidence ages past 90s during routine refreshes too, so only call it out of date
        // while refreshes are actually failing.
        let refreshIsFailing = state.consecutiveFailures > 0 || (supplementalState?.consecutiveFailures ?? 0) > 0
        return PlannerJourneySummary(journey: journey, showsChevron: isInteractive,
            liveIsStale: refreshIsFailing && PlannerLivePresentation.hasExpiredEvidence(for: journey, context: live, at: date),
            durationTag: durationTag,
            showsRefreshWarnings: state.hasPersistentFailure || supplementalState?.hasPersistentFailure == true,
            showsTravelNotes: false)
            .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
