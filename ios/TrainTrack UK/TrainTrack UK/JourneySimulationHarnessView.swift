#if DEBUG
import SwiftUI
import JourneyActivityShared

struct JourneySimulationHarnessView: View {
    @EnvironmentObject private var journeyStore: JourneyStore
    @EnvironmentObject private var departuresStore: DeparturesStore
    @EnvironmentObject private var activityManager: LiveActivityManager
    @ObservedObject private var trackingCoordinator = JourneyTrackingCoordinator.shared

    @State private var selectedGroupID: UUID?
    @State private var currentPhase: JourneyActivityAttributes.JourneyPhase?
    @State private var simulatedDeparture: DepartureV2?
    @State private var arrivalDelayMinutes = 0
    @State private var isWorking = false
    @State private var errorMessage: String?

    private let phases: [JourneyActivityAttributes.JourneyPhase] = [
        .pendingStart,
        .atStart,
        .enRoute,
        .arrived
    ]

    private var journeys: [JourneyGroup] {
        journeyStore.journeyGroups()
            .sorted { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
    }

    private var selectedGroup: JourneyGroup? {
        journeys.first { $0.id == selectedGroupID }
    }

    private var isRunning: Bool {
        currentPhase != nil
            && activityManager.hasDebugJourneySimulation
            && trackingCoordinator.hasDebugJourneySimulation
    }

    var body: some View {
        Form {
            Section {
                Label("Debug build only", systemImage: "wrench.and.screwdriver.fill")
                    .font(.headline)
                Text("This creates a real local Live Activity on this device and drives the production journey display states. It does not spoof GPS, send geofence events, or save journey history.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Journey") {
                if journeys.isEmpty {
                    ContentUnavailableView(
                        "No saved journeys",
                        systemImage: "tram",
                        description: Text("Save a journey first, then return here to simulate it.")
                    )
                } else {
                    Picker("Route", selection: $selectedGroupID) {
                        ForEach(journeys) { group in
                            Text(group.displayTitle).tag(Optional(group.id))
                        }
                    }
                    .disabled(isRunning || isWorking)

                    if let group = selectedGroup {
                        LabeledContent("Legs", value: "\(group.legs.count)")
                    }

                    Picker("Arrival delay", selection: $arrivalDelayMinutes) {
                        Text("On time").tag(0)
                        Text("15 min late — Delay Repay").tag(15)
                        Text("30 min late — Delay Repay").tag(30)
                    }
                    .disabled(isWorking)

                    if let departure = simulatedDeparture {
                        LabeledContent("Service", value: departure.departureTime.scheduled)
                        LabeledContent("Data", value: "Live API")
                    } else if isRunning {
                        LabeledContent("Data", value: "Fallback sample")
                    }
                }
            }

            Section("Simulation") {
                if let group = selectedGroup, let currentPhase {
                    LabeledContent("Current stage", value: currentPhase.debugDisplayName)
                    Text(currentPhase.statusMessage(
                        startStation: group.startStation.name,
                        destinationStation: group.endStation.name
                    ))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Start the simulation to create the Live Activity at the pending-start stage.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if isRunning {
                    Button("Advance to next stage", systemImage: "forward.fill") {
                        advanceToNextStage()
                    }
                    .disabled(isWorking || currentPhase == .arrived)
                } else {
                    Button("Start journey simulation", systemImage: "play.fill") {
                        startSimulation()
                    }
                    .disabled(selectedGroup == nil || isWorking || activityManager.hasDebugJourneySimulation)
                }

                if activityManager.hasDebugJourneySimulation {
                    Button("End simulation", systemImage: "stop.fill", role: .destructive) {
                        stopSimulation()
                    }
                    .disabled(isWorking)
                }
            }

            Section("Jump to stage") {
                ForEach(phases, id: \.rawValue) { phase in
                    Button {
                        setPhase(phase)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(phase.debugDisplayName)
                                if let group = selectedGroup {
                                    Text(phase.statusMessage(
                                        startStation: group.startStation.name,
                                        destinationStation: group.endStation.name
                                    ))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if currentPhase == phase {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .disabled(!isRunning || isWorking)
                }
            }

            Section("How to inspect") {
                Text("1. Start the simulation and leave this screen to check the in-app banner.")
                Text("2. Lock the device to inspect the full Live Activity.")
                Text("3. Long-press the Dynamic Island to inspect its expanded presentation.")
                Text("4. Return here and advance or jump to the next stage.")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Journey Simulator")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if selectedGroupID == nil {
                selectedGroupID = journeys.first?.id
            }
        }
    }

    private func startSimulation() {
        guard let group = selectedGroup else { return }
        guard !trackingCoordinator.hasNonDebugJourneyTracking else {
            errorMessage = "End the real journey currently being tracked before starting a simulation."
            return
        }

        isWorking = true
        errorMessage = nil
        Task {
            do {
                let departure = try await activityManager.startDebugJourneySimulation(
                    group: group,
                    depStore: departuresStore
                )
                simulatedDeparture = departure
                trackingCoordinator.setDebugJourneySimulationPhase(
                    .pendingStart,
                    group: group,
                    departure: departure,
                    arrivalDelayMinutes: arrivalDelayMinutes
                )
                currentPhase = .pendingStart
            } catch {
                errorMessage = error.localizedDescription
                trackingCoordinator.stopDebugJourneySimulation()
            }
            isWorking = false
        }
    }

    private func advanceToNextStage() {
        guard let currentPhase,
              let index = phases.firstIndex(of: currentPhase),
              phases.indices.contains(index + 1) else { return }
        setPhase(phases[index + 1])
    }

    private func setPhase(_ phase: JourneyActivityAttributes.JourneyPhase) {
        guard isRunning, let group = selectedGroup else { return }
        isWorking = true
        errorMessage = nil
        Task {
            trackingCoordinator.setDebugJourneySimulationPhase(
                phase,
                group: group,
                departure: simulatedDeparture,
                arrivalDelayMinutes: arrivalDelayMinutes
            )
            let checkpoint: ActiveJourneyHistoryCheckpoint? = switch phase {
            case .enRoute:
                trackingCoordinator.activeJourney
            case .arrived:
                trackingCoordinator.recentlyCompletedJourney
            case .pendingStart, .atStart:
                nil
            }
            await activityManager.updateDebugJourneySimulation(
                phase: phase,
                group: group,
                checkpoint: checkpoint
            )
            currentPhase = phase
            isWorking = false
        }
    }

    private func stopSimulation() {
        isWorking = true
        Task {
            await activityManager.stopDebugJourneySimulation()
            trackingCoordinator.stopDebugJourneySimulation()
            simulatedDeparture = nil
            currentPhase = nil
            isWorking = false
        }
    }
}

private extension JourneyActivityAttributes.JourneyPhase {
    var debugDisplayName: String {
        switch self {
        case .pendingStart: return "Pending start station"
        case .atStart: return "At start station"
        case .enRoute: return "En route"
        case .arrived: return "Arrived"
        }
    }
}
#endif
