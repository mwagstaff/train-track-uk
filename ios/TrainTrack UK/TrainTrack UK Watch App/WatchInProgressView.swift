import SwiftUI

struct WatchLinkedDeparturesView: View {
    let library: WatchLibraryStore
    let launch: WatchLaunch
    @State private var fallbackID = UUID()

    private var route: WatchRoute {
        library.library?.routes.first(where: launch.matches)
            ?? library.library?.journeys?.first(where: { launch.matches($0.route) })?.route
            ?? WatchRoute(id: fallbackID, stations: [WatchStation(crs: launch.from, name: launch.fromName),
                                                  WatchStation(crs: launch.to, name: launch.toName)], favourite: false)
    }

    var body: some View {
        if library.library != nil {
            WatchDeparturesView(routeID: route.id, library: library, fallbackRoute: route)
        } else {
            List {
                Text("Sync journey data from your iPhone to see departures.")
                Button("Sync with iPhone") { library.requestSync() }
                if let message = library.syncMessage { Text(message).font(.footnote) }
            }.navigationTitle("Departures")
        }
    }
}

struct WatchInProgressView: View {
    let library: WatchLibraryStore
    var journeyID: String? = nil
    var launch: WatchLaunch? = nil
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmation: WatchJourneyCommand.Action?
    @State private var confirmationJourney: WatchJourney?

    private var journey: WatchJourney? {
        library.library?.journeys?.first {
            if let journeyID { return $0.id == journeyID }
            if let launch { return launch.matches($0.route) }
            return true
        }
    }

    var body: some View {
        List {
            if let journey {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(journey.route.title).font(.caption2).foregroundStyle(.secondary)
                        Text(journey.title).font(.headline).foregroundStyle(.cyan)
                        Text(journey.detail).font(.footnote)
                    }
                }
                if !journey.isComplete {
                    Section(journey.destination) {
                        VStack(alignment: .leading, spacing: 6) {
                            if let arrival = journey.arrival { Text(arrival).font(.title3.bold()) }
                            if let finalArrival = journey.finalArrival { Text(finalArrival).font(.footnote) }
                            Text(journey.status ?? "Live status unavailable").font(.footnote)
                            if let platform = journey.platform { Text("Platform \(platform)").font(.caption2) }
                            if let length = journey.length, length > 0 { Text("\(length) cars").font(.caption2) }
                        }
                    }
                    if let nextRoute = journey.nextDepartureRoute {
                        NavigationLink("Next departures from \(nextRoute.origin.name)") {
                            WatchDeparturesView(routeID: nextRoute.id, library: library, fallbackRoute: nextRoute)
                        }
                    }
                    Section {
                        if let title = journey.arrivalAction {
                            Button(title) { confirmationJourney = journey; confirmation = .arrive }
                                .tint(.blue)
                        }
                        if let title = journey.serviceAction {
                            NavigationLink(title) {
                                WatchJourneyServicePicker(library: library, journey: journey)
                            }
                        }
                        Button("End journey", role: .destructive) {
                            confirmationJourney = journey
                            confirmation = .end
                        }
                    }.disabled(library.isPerformingAction)
                }
                if library.isPerformingAction { ProgressView("Updating journey…") }
                if let message = library.actionMessage { Text(message).font(.footnote) }
                Section {
                    Button("Refresh") { library.requestSync(refreshJourney: true) }
                } footer: {
                    Text(library.syncMessage ?? "Synced \(WatchRailTime.display(journey.updatedAt))")
                }
            } else {
                Text("No matching journey in progress").font(.headline)
                Text("Open TrainTrack UK on your iPhone to sync your current journey.").font(.footnote)
                if let message = library.syncMessage { Text(message).font(.footnote) }
                Button("Sync with iPhone") { library.requestSync(refreshJourney: true) }
            }
        }
        .navigationTitle("In Progress")
        .confirmationDialog(confirmation == .end ? "End journey?" : "Confirm arrival?",
                            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            titleVisibility: .visible) {
            if let action = confirmation, let snapshot = confirmationJourney {
                Button(action == .end ? "End journey" : "Yes, I’m here", role: action == .end ? .destructive : nil) {
                    library.perform(action, journey: snapshot)
                    confirmation = nil
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: {
            Text(confirmation == .end ? "This ends the journey and stops live updates on your iPhone." : confirmationJourney?.arrivalAction ?? "Confirm your current location.")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                library.requestSync(refreshJourney: true)
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
    }
}

private struct WatchJourneyServicePicker: View {
    let library: WatchLibraryStore
    let journey: WatchJourney
    @Environment(\.dismiss) private var dismiss

    // Keep the original context; a change on the phone invalidates this picker.
    private var current: WatchJourney? {
        library.library?.journeys?.first { $0.id == journey.id && $0.context == journey.context }
    }

    var body: some View {
        List {
            if let current {
                ForEach(current.services) { service in
                    Button {
                        library.perform(.selectService, journey: journey, serviceID: service.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(service.departure).font(.headline).monospacedDigit()
                            Text(service.status).font(.caption2)
                            if let platform = service.platform { Text("Platform \(platform)").font(.caption2) }
                        }
                    }.disabled(service.cancelled || library.isPerformingAction)
                }
                if current.services.isEmpty { Text("No recent trains available. Refresh or select an unlisted train.").font(.footnote) }
                Button("My train isn’t listed") {
                    library.perform(.unlistedService, journey: journey)
                    dismiss()
                }.disabled(library.isPerformingAction)
                Button("Refresh trains") { library.requestSync(refreshJourney: true) }
            } else {
                Text("Your journey has changed. Go back to choose the current train.")
            }
        }
        .navigationTitle("Choose train")
        .task { library.requestSync(refreshJourney: true) }
    }
}
