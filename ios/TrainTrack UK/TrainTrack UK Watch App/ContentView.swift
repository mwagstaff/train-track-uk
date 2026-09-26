import SwiftUI

struct ContentView: View {
    @State private var library = WatchLibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if let snapshot = library.library {
                    Section {
                        NavigationLink {
                            WatchRoutesView(library: library, favourites: true)
                        } label: {
                            Label("Favourites", systemImage: "star.fill").foregroundStyle(.yellow)
                        }
                        NavigationLink {
                            WatchRoutesView(library: library, favourites: false)
                        } label: {
                            Label("My Journeys", systemImage: "train.side.front.car")
                        }
                    }
                    Section {
                        syncButton
                    } footer: {
                        Text(library.syncMessage ?? "\(snapshot.routes.count) saved routes · synced \(WatchRailTime.display(snapshot.updatedAt))")
                    }
                } else {
                    Section {
                        Label("Your routes, on your wrist", systemImage: "train.side.front.car")
                            .font(.headline)
                        Text("Open TrainTrack UK on your iPhone to bring your Favourites and My Journeys here.")
                            .font(.footnote).foregroundStyle(.secondary)
                        syncButton
                        if let message = library.syncMessage {
                            Text(message).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("TrainTrack UK")
        }
        .task { library.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.requestSync() }
        }
    }

    private var syncButton: some View {
        Button("Sync with iPhone", systemImage: "arrow.triangle.2.circlepath") { library.requestSync() }
    }
}

private struct WatchRoutesView: View {
    let library: WatchLibraryStore
    let favourites: Bool

    private var routes: [WatchRoute] {
        library.library?.routes.filter { $0.favourite == favourites } ?? []
    }

    var body: some View {
        List {
            if routes.isEmpty {
                Text(favourites ? "No favourites yet" : "No saved journeys yet").font(.headline)
                Text("Save routes in the iPhone app, then sync them to your watch.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(routes) { route in
                NavigationLink {
                    WatchDeparturesView(routeID: route.id, library: library)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(route.origin.name).font(.headline)
                        Text("→ \(route.destination.name)").font(.subheadline)
                        if !route.via.isEmpty {
                            Text("Via \(route.via.map(\.name).joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle(favourites ? "Favourites" : "My Journeys")
    }
}

private struct WatchDeparturesView: View {
    let routeID: UUID
    let library: WatchLibraryStore
    @State private var store = WatchBoardStore()
    @State private var refreshGeneration = 0
    @Environment(\.scenePhase) private var scenePhase

    private var route: WatchRoute? { library.library?.routes.first { $0.id == routeID } }
    private var apiBase: String { library.library?.apiBase ?? "" }
    private var refreshIdentity: String { "\(scenePhase == .active)-\(apiBase)-\(String(describing: route))-\(refreshGeneration)" }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            List {
                if let route {
                    Section {
                        Text(route.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        if !route.via.isEmpty {
                            Text("Via \(route.via.map(\.name).joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if let error = store.errorMessage {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if let board = store.board {
                        let stale = board.isStale(at: timeline.date) || store.errorMessage != nil
                        Section {
                            let departures = board.upcoming(at: timeline.date)
                            ForEach(departures.prefix(8)) { departure in
                                NavigationLink {
                                    WatchServiceView(departure: departure, stale: stale, observedAt: board.observedAt ?? board.checkedAt)
                                } label: {
                                    WatchDepartureRow(departure: departure, stale: stale)
                                }
                            }
                            if departures.isEmpty {
                                if board.pending {
                                    ProgressView("Finding departures…")
                                } else {
                                    Text(stale ? "No current departures available. Try refreshing." : "No more departures in this time window.")
                                        .font(.footnote)
                                }
                            }
                        } footer: {
                            Text("\(stale ? "Last known times" : board.dataStatus == "live" ? "Live departures" : "Some live times unavailable") · checked \(WatchRailTime.display(board.observedAt ?? board.checkedAt))")
                        }
                    } else if store.isRefreshing {
                        ProgressView("Loading departures…")
                    }
                    Button {
                        refreshGeneration += 1
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                } else {
                    Text("This route was removed on your iPhone.")
                }
            }
        }
        .navigationTitle("Departures")
        .task(id: refreshIdentity) {
            guard scenePhase == .active, let route else { return }
            await store.watch(route: route, apiBase: apiBase)
        }
    }
}

private struct WatchDepartureRow: View {
    let departure: WatchDeparture
    var stale = false

    private var tint: Color {
        if stale { return .secondary }
        if departure.cancelled { return .red }
        if departure.status == "On time" { return .green }
        return departure.status == "Scheduled" ? .primary : .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(WatchRailTime.display(departure.departure))
                    .font(.title3.bold()).monospacedDigit()
                    .foregroundStyle(tint).strikethrough(departure.cancelled)
                Spacer(minLength: 4)
                Text("Plat \(departure.platformLabel)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(.cyan.opacity(0.2), in: RoundedRectangle(cornerRadius: 5))
                    .accessibilityLabel("Platform \(departure.platformLabel)")
            }
            if let arrival = departure.arrival, !departure.cancelled {
                Text("Arr \(WatchRailTime.display(arrival)) · \(departure.changes == 0 ? "Direct" : departure.changes == 1 ? "1 change" : "\(departure.changes) changes")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Text(stale ? "\(departure.status) · last known" : departure.status)
                .font(.caption2).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct WatchServiceView: View {
    let departure: WatchDeparture
    let stale: Bool
    let observedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            List {
                WatchDepartureRow(departure: departure, stale: stale || timeline.date.timeIntervalSince(observedAt) > 120)
                if let scheduled = departure.scheduled, abs(scheduled.timeIntervalSince(departure.departure)) >= 60 {
                    Text("Scheduled \(WatchRailTime.display(scheduled))").font(.footnote)
                }
                if let length = departure.length, length > 0 { Text("\(length) cars").font(.footnote) }
                if let notice = departure.notice, !notice.isEmpty { Text(notice).font(.footnote) }
                ForEach(Array(departure.legs.enumerated()), id: \.offset) { _, leg in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(leg.title).font(.headline)
                        Text("\(WatchRailTime.display(leg.departure)) → \(WatchRailTime.display(leg.arrival))")
                            .font(.footnote).monospacedDigit()
                        if let platform = leg.platform { Text("Platform \(platform)").font(.caption2) }
                        if let status = leg.status { Text(status).font(.caption2).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle("Service")
        }
    }
}

#Preview { ContentView() }
