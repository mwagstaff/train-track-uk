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

struct SavedRouteBoardView: View {
    let state: SavedRouteBoardState
    let routeKey: String
    let departureCount: Int
    let isInteractive: Bool
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let usesLiveTimes: Binding<Bool>?
    @State private var selectedJourney: PlannerJourneyResponse?

    var body: some View {
        TimelineView(.periodic(from: .now, by: state.isPending ? 1 : 20)) { context in
            VStack(alignment: .leading, spacing: 0) {
                if let usesLiveTimes {
                    DisclosureGroup("Journey options") {
                        Toggle("Use live times", isOn: usesLiveTimes)
                            .accessibilityIdentifier("saved-route.live-times")
                        Text("When off, journeys use scheduled times and keep live disruption warnings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.font(.subheadline).padding(16)
                        .accessibilityIdentifier("saved-route.options.\(routeKey)")
                        .disabled(!isInteractive)
                }
                if let progress = state.progressPresentation(at: context.date) {
                    HStack(alignment: .top, spacing: 10) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(progress.title).font(.subheadline)
                            ForEach(progress.details, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        }.fixedSize(horizontal: false, vertical: true)
                    }.padding(16)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("saved-route.progress.\(routeKey)")
                }
                if let message = state.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption).padding(16)
                }
                if let result = state.result {
                    if state.isStale || state.liveIsStale(at: context.date) {
                        Text("Showing earlier journey options. Check for updates before travelling.")
                            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 10)
                    }
                    let upcoming = state.upcomingJourneys(at: context.date)
                    if upcoming.isEmpty && state.board?.status == "ready" && state.message == nil {
                        Text("No journeys found in this time window.")
                            .font(.subheadline).foregroundStyle(.secondary).padding(16)
                    }
                    let visible = Array(upcoming.prefix(isExpanded ? upcoming.count : departureCount))
                    ForEach(visible) { journey in
                        if isInteractive {
                            Button {
                                selectedJourney = PlannerJourneyResponse(journey: journey, dataset: result.dataset, live: result.live)
                            } label: {
                                summary(journey, at: context.date)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("saved-route.journey.\(journey.id)")
                        } else { summary(journey, at: context.date) }
                        if journey.id != visible.last?.id { Divider().padding(.horizontal, 16) }
                    }
                    if upcoming.count > departureCount {
                        Divider().padding(.horizontal, 16)
                        Button(isExpanded ? "Show fewer journeys" : "View all journeys", action: onToggleExpanded)
                            .font(.subheadline).frame(maxWidth: .infinity).padding(13).disabled(!isInteractive)
                    }
                    let disrupted = (result.disruptedJourneys ?? []).filter { $0.departure >= context.date }
                    if !disrupted.isEmpty {
                        DisclosureGroup("Disrupted journeys") {
                            ForEach(disrupted) { journey in
                                Button {
                                    selectedJourney = PlannerJourneyResponse(journey: journey, dataset: result.dataset, live: result.live)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Unavailable option").font(.caption.weight(.semibold)).foregroundStyle(.red)
                                        summary(journey, at: context.date)
                                    }
                                }.buttonStyle(.plain).disabled(!isInteractive)
                            }
                        }.font(.subheadline).padding(16).disabled(!isInteractive)
                    }
                    let notes = PlannerLivePresentation.visibleWarnings(result.warnings + (result.live?.warnings ?? []))
                    if !notes.isEmpty {
                        DisclosureGroup("Journey notes") {
                            ForEach(notes, id: \.self) { Text($0).font(.caption) }
                        }.font(.caption).padding(16)
                    }
                } else if !state.isPending {
                    Text("Journey options are temporarily unavailable.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(16)
                }
            }
        }
        .navigationDestination(isPresented: Binding(get: { selectedJourney != nil }, set: { if !$0 { selectedJourney = nil } })) {
            if let selectedJourney {
                PlannerJourneyDetailView(id: selectedJourney.journey.id, client: JourneyPlannerClient(),
                    initialResponse: selectedJourney, allowsTrainTracking: true)
            }
        }
    }

    private func summary(_ journey: PlannedJourney, at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PlannerJourneySummary(journey: journey, showsChevron: isInteractive, liveIsStale: state.liveIsStale(for: journey, at: date))
            let interchanges = journey.legs.filter { $0.kind == "transfer" }.map(\.heading)
            if !interchanges.isEmpty {
                Text(interchanges.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }
}
