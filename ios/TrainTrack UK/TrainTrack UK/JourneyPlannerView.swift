import SwiftUI

struct AddJourneyEntryView: View {
    var body: some View {
        if JourneyPlannerFeature.isEnabled {
            JourneyPlannerView()
        } else {
            AddJourneyView()
        }
    }
}

struct JourneyPlannerView: View {
    @EnvironmentObject private var router: TabRouter
    @State private var store = JourneyPlannerStore()
    @State private var stationField: StationField?
    @State private var resultsPresented = false
    @State private var searchTask: Task<Void, Never>?

    private enum StationField: String, Identifiable {
        case origin, destination
        var id: String { rawValue }
        var title: String { self == .origin ? "From" : "To" }
    }

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                stationButton("From", station: store.origin, field: .origin)
                stationButton("To", station: store.destination, field: .destination)
                Button {
                    (store.origin, store.destination) = (store.destination, store.origin)
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "arrow.up.arrow.down").accessibilityHidden(true)
                        Text("Swap stations").fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(store.origin == nil && store.destination == nil)
                .accessibilityIdentifier("planner.swap")
                .accessibilityLabel("Swap stations")
            }

            Section {
                Picker("When", selection: Binding(get: { store.timeMode }, set: { mode in
                    if store.timeMode == .now && mode != .now {
                        store.explicitTime = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970 / 60) * 60)
                    }
                    store.timeMode = mode
                })) {
                    ForEach(PlannerTimeMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .accessibilityIdentifier("planner.when")
                if store.timeMode != .now {
                    if let range = store.status?.dataset?.coverage.dateRange {
                        if range.contains(store.explicitTime) {
                            DatePicker("Date and time", selection: $store.explicitTime, in: range)
                                .accessibilityIdentifier("planner.date")
                        } else {
                            Text("Selected: \(PlannerTime.display(store.explicitTime))")
                            Button("Choose a supported date") {
                                store.explicitTime = min(max(Date(), range.lowerBound), range.upperBound)
                            }
                        }
                    } else {
                        DatePicker("Date and time", selection: $store.explicitTime)
                            .accessibilityIdentifier("planner.date")
                    }
                }
                Text("All train times are UK time (Europe/London).")
                    .font(.caption).foregroundStyle(Color.plannerSecondaryText)
                if let message = store.validationMessage(), store.origin != nil && store.destination != nil {
                    Text(message).foregroundStyle(Color.primary)
                }
            }

            timetableSection

            Section {
                if let error = store.searchError {
                    Label(error.message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.primary)
                }
                Button { startSearch() } label: {
                    HStack {
                        if store.isSearching { ProgressView() }
                        Text(store.isSearching ? store.searchProgress.title : "Find journeys")
                    }
                }
                .disabled(store.status?.available != true || store.origin == nil || store.destination == nil || store.isSearching)
                .accessibilityIdentifier("planner.search")
                if store.isSearching {
                    Button("Cancel search", role: .cancel) {
                        searchTask?.cancel()
                        store.cancelSearch()
                    }
                    .accessibilityIdentifier("planner.cancel-search")
                }
            }

            Section {
                NavigationLink { AddJourneyView() } label: {
                    Label("Add a saved route", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("planner.saved-route")
            } footer: {
                Text("Save a route, add intermediate stops, or start journey updates.")
                    .foregroundStyle(Color.plannerSecondaryText)
            }

            Section {
                if store.recents.searches.isEmpty {
                    Text("Completed searches will appear here.").foregroundStyle(Color.plannerSecondaryText)
                }
                ForEach(store.recents.searches) { recent in
                    Button {
                        searchTask?.cancel()
                        store.restore(recent)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(recent.intent.origin.name) → \(recent.intent.destination.name)")
                                .foregroundStyle(Color.primary)
                            Text(recentDescription(recent))
                                .font(.caption).foregroundStyle(Color.plannerSecondaryText)
                        }
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { store.recents.remove(id: recent.id) }
                    }
                    .accessibilityAction(named: "Remove recent search") { store.recents.remove(id: recent.id) }
                }
                if !store.recents.searches.isEmpty {
                    Button(role: .destructive) { store.recents.clear() } label: {
                        Text("Clear recent searches").foregroundStyle(Color.plannerDestructiveText)
                    }
                }
            } header: {
                Text("Recent searches").foregroundStyle(Color.plannerSecondaryText)
            }
        }
        .tint(Color.plannerActionText)
        .navigationTitle("Find journeys")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.timeZone, PlannerTime.zone)
        .environment(\.calendar, PlannerTime.calendar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    searchTask?.cancel()
                    store.cancelSearch()
                    router.addJourneyPrefillFavourite = false
                    router.selected = router.lastNonAddTab
                }
            }
        }
        .sheet(item: $stationField) { field in
            NavigationStack {
                PlannerStationPicker(title: field.title, client: store.client) { station in
                    if field == .origin { store.origin = station } else { store.destination = station }
                }
            }
        }
        .navigationDestination(isPresented: $resultsPresented) {
            PlannerResultsView(store: store, loadPage: { startSearch(cursor: $0) }, cancelSearch: {
                searchTask?.cancel()
                store.cancelSearch()
            })
        }
        .onChange(of: resultsPresented) { _, presented in
            if !presented {
                searchTask?.cancel()
                store.cancelSearch()
            }
        }
        .onChange(of: store.intent) { _, _ in
            if store.isSearching {
                searchTask?.cancel()
                store.cancelSearch()
            }
        }
        .task { await store.loadStatus() }
        .onDisappear {
            searchTask?.cancel()
            store.cancelSearch()
        }
    }

    private func stationButton(_ title: String, station: PlannerStation?, field: StationField) -> some View {
        Button { stationField = field } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(Color.plannerSecondaryText)
                Text(station.map { "\($0.name) (\($0.crs))" } ?? "Select station")
                    .foregroundStyle(station == nil ? Color.plannerActionText : Color.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("planner.\(field.rawValue)")
        .accessibilityLabel("\(title), \(station?.name ?? "select station")")
    }

    @ViewBuilder private var timetableSection: some View {
        Section {
            Label("Scheduled times only", systemImage: "calendar")
            Text("Live delays, cancellations and platform changes are not included.")
                .font(.caption).foregroundStyle(Color.plannerSecondaryText)
            if store.isLoadingStatus {
                ProgressView("Checking timetable…")
            } else if let status = store.status {
                if let dataset = status.dataset { PlannerDatasetView(dataset: dataset) }
                if !status.available {
                    Text(status.reason ?? "The journey planner is unavailable. Saved routes are still available.")
                        .foregroundStyle(Color.primary)
                    Button("Retry") { Task { await store.loadStatus() } }
                }
            } else if let error = store.statusError {
                Text(error).foregroundStyle(Color.primary)
                Button("Retry") { Task { await store.loadStatus() } }
            }
        }
    }

    private func startSearch(cursor: String? = nil) {
        searchTask?.cancel()
        searchTask = Task {
            await store.search(cursor: cursor)
            guard !Task.isCancelled else { return }
            if cursor == nil && store.response != nil { resultsPresented = true }
        }
    }

    private func recentDescription(_ recent: PlannerRecentSearch) -> String {
        guard let date = recent.intent.explicitTime, recent.intent.timeMode != .now else { return "Depart now" }
        let suffix = date < Date() ? " · Choose a new time" : ""
        return "\(recent.intent.timeMode.title) \(PlannerTime.display(date))\(suffix)"
    }
}

private struct PlannerStationPicker: View {
    let title: String
    let client: any JourneyPlannerServing
    let select: (PlannerStation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var stations: [PlannerStation] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var retry = UUID()

    var body: some View {
        List {
            if isLoading { ProgressView("Finding stations…") }
            if let error {
                Text(error).foregroundStyle(Color.primary)
                Button("Retry") { retry = UUID() }
            } else if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                Text("Enter a station name or three-letter code.").foregroundStyle(Color.plannerSecondaryText)
            } else if !isLoading && stations.isEmpty {
                Text("No matching stations in the available timetable.").foregroundStyle(Color.plannerSecondaryText)
            }
            ForEach(stations) { station in
                Button {
                    select(station)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(station.name).foregroundStyle(Color.primary)
                        Text(station.crs).font(.caption).foregroundStyle(Color.plannerSecondaryText)
                    }
                }
                .accessibilityIdentifier("planner.station.\(station.crs)")
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Station name or code")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task(id: "\(query)|\(retry)") {
            let requestedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            stations = []
            error = nil
            isLoading = requestedQuery.count >= 2
            guard isLoading else { return }
            do {
                try await Task.sleep(for: .milliseconds(250))
                let found = try await client.stations(query: requestedQuery)
                try Task.checkCancellation()
                stations = found
                isLoading = false
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                isLoading = false
            }
        }
    }
}

private struct PlannerDatasetView: View {
    let dataset: PlannerDataset
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Timetable published \(dataset.sourceGenerationDate)")
            Text("Available dates: \(dataset.coverage.from) to \(dataset.coverage.to)")
            if let warnings = dataset.warnings, !warnings.isEmpty {
                DisclosureGroup("Timetable limitations") {
                    ForEach(warnings, id: \.self) { Text($0).foregroundStyle(Color.primary) }
                }
            }
            if dataset.freshness != "fresh" {
                Label("This timetable is out of date. Check current travel information before travelling.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.primary)
            }
        }
        .font(.caption).foregroundStyle(Color.plannerSecondaryText)
    }
}

private struct PlannerResultsView: View {
    let store: JourneyPlannerStore
    let loadPage: (String) -> Void
    let cancelSearch: () -> Void

    var body: some View {
        List {
            if let response = store.response {
                Section {
                    Text("\(stationName(response.search.origin)) → \(stationName(response.search.destination))")
                        .font(.headline)
                    Label("Scheduled times only", systemImage: "calendar")
                    Text("\(PlannerTime.display(response.search.window.from)) – \(PlannerTime.display(response.search.window.to))")
                        .font(.caption)
                    PlannerDatasetView(dataset: response.dataset)
                    if !response.warnings.isEmpty {
                        DisclosureGroup("Search notes") {
                            ForEach(response.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(Color.primary) }
                        }
                    }
                    if response.search.searchTruncated {
                        Text("Some journeys may be missing. See search notes for details.").foregroundStyle(Color.primary)
                    }
                }
                if let error = store.searchError { Text(error.message).foregroundStyle(Color.primary) }
                if store.isSearching {
                    ProgressView(store.searchProgress.title)
                    Button("Cancel search", role: .cancel, action: cancelSearch)
                        .accessibilityIdentifier("planner.cancel-search")
                }
                if response.journeys.isEmpty {
                    Section {
                        Label("No journeys in this window", systemImage: "tram")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("\(response.search.timeType == "arriveBy" ? "Arrivals" : "Departures") searched: \(PlannerTime.display(response.search.window.from)) – \(PlannerTime.display(response.search.window.to))")
                            .foregroundStyle(Color.plannerSecondaryText)
                            .accessibilityIdentifier("planner.empty.interval")
                        if let maxChanges = response.search.maxChanges {
                            Text(maxChanges == 0 ? "Direct journeys only." : "Up to \(maxChanges) change\(maxChanges == 1 ? "" : "s").")
                                .foregroundStyle(Color.plannerSecondaryText)
                                .accessibilityIdentifier("planner.empty.change-limit")
                        }
                        Text("Try another time window, or go back to change your search.")
                            .foregroundStyle(Color.plannerSecondaryText)
                        if let later = response.pagination.later {
                            Button("Search later times") { loadPage(later) }
                                .disabled(store.isSearching)
                                .accessibilityIdentifier("planner.empty.later")
                        }
                        if let earlier = response.pagination.earlier {
                            Button("Search earlier times") { loadPage(earlier) }
                                .disabled(store.isSearching)
                                .accessibilityIdentifier("planner.empty.earlier")
                        }
                    }
                }
                ForEach(response.journeys) { journey in
                    NavigationLink {
                        PlannerJourneyDetailView(id: journey.id, client: store.client)
                    } label: {
                        PlannerJourneySummary(journey: journey)
                    }
                    .accessibilityIdentifier("planner.journey.\(journey.id)")
                }
                Section {
                    if let more = response.pagination.more {
                        Button { loadPage(more) } label: { Label("More journeys", systemImage: "plus") }
                    }
                    if !response.journeys.isEmpty {
                        if let earlier = response.pagination.earlier {
                            Button { loadPage(earlier) } label: { Label("Earlier journeys", systemImage: "arrow.up") }
                        }
                        if let later = response.pagination.later {
                            Button { loadPage(later) } label: { Label("Later journeys", systemImage: "arrow.down") }
                        }
                    }
                }
                .disabled(store.isSearching)
            }
        }
        .navigationTitle("Journeys")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func stationName(_ crs: String) -> String {
        if store.origin?.crs == crs { return store.origin?.name ?? crs }
        if store.destination?.crs == crs { return store.destination?.name ?? crs }
        return crs
    }
}

private struct PlannerJourneySummary: View {
    let journey: PlannedJourney
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(PlannerTime.display(journey.departure)) → \(PlannerTime.display(journey.arrival))")
                .font(.headline)
            Text("\(PlannerTime.minutes(journey.durationMinutes)) · \(journey.changes == 0 ? "Direct" : "\(journey.changes) change\(journey.changes == 1 ? "" : "s")")")
                .font(.subheadline).foregroundStyle(Color.plannerSecondaryText)
            ForEach(Array(journey.legs.enumerated()), id: \.offset) { _, leg in
                if leg.kind == "vehicle" { PlannerOperatorLabel(leg: leg) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private struct PlannerOperatorLabel: View {
    let leg: PlannedJourney.Leg
    @ObservedObject private var config = ServerConfigStore.shared
    var body: some View {
        let branding = OperatorBrandingResolver.resolve(name: leg.operator, code: leg.operator, in: config.operatorBranding)
        Label {
            Text(branding?.name ?? leg.operator ?? "Train service").foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: leg.mode == "replacementBus" ? "bus" : "tram")
                .foregroundStyle(branding?.color ?? .secondary)
        }
        .font(.caption)
    }
}

private struct PlannerJourneyDetailView: View {
    let id: String
    let client: any JourneyPlannerServing
    @State private var response: PlannerJourneyResponse?
    @State private var error: String?
    @State private var retry = UUID()

    var body: some View {
        List {
            if let response {
                Section {
                    Label("Scheduled times only", systemImage: "calendar")
                    Text("Live delays and cancellations are not included. All times are UK time.").font(.caption)
                    PlannerJourneySummary(journey: response.journey)
                    PlannerDatasetView(dataset: response.dataset)
                }
                ForEach(Array(response.journey.legs.enumerated()), id: \.offset) { index, leg in
                    Section("\(index + 1). \(leg.kind == "transfer" ? transferTitle(leg.mode) : "Travel")") {
                        if leg.kind == "vehicle" { PlannerOperatorLabel(leg: leg) }
                        Text("\(leg.from.name) → \(leg.to.name)").font(.headline)
                        LabeledContent("Depart", value: PlannerTime.display(leg.departure))
                        LabeledContent("Arrive", value: PlannerTime.display(leg.arrival))
                        if let transfer = leg.transfer {
                            if let interchange = transfer.interchangeMinutes {
                                Text("Allow at least \(PlannerTime.minutes(interchange)) to change trains.")
                            }
                            if let exit = transfer.exitMinutes, let travel = transfer.travelMinutes, let entry = transfer.entryMinutes {
                                Text("Allow \(PlannerTime.minutes(exit)) to leave, \(PlannerTime.minutes(travel)) for the transfer and \(PlannerTime.minutes(entry)) before boarding.")
                            }
                            if let extra = transfer.extraMinutes, extra > 0 { Text("Extra connection time: \(PlannerTime.minutes(extra)).") }
                            if let waiting = transfer.waitingMinutes, waiting > 0 { Text("Waiting time: \(PlannerTime.minutes(waiting)).") }
                            if leg.mode != "walk" && leg.mode != "interchange" {
                                Text("A supplied connecting transfer. Specific departures and intermediate stops are not provided.")
                                    .font(.caption).foregroundStyle(Color.plannerSecondaryText)
                            }
                        }
                        if let points = leg.callingPoints, !points.isEmpty {
                            DisclosureGroup("Calling points") {
                                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(point.station.name)
                                        if let arrival = point.arrival { Text("Arrive \(PlannerTime.display(arrival))").font(.caption).foregroundStyle(Color.plannerSecondaryText) }
                                        if let departure = point.departure { Text("Depart \(PlannerTime.display(departure))").font(.caption).foregroundStyle(Color.plannerSecondaryText) }
                                    }
                                }
                            }
                        }
                        ForEach(leg.warnings ?? [], id: \.self) { Text($0).font(.caption).foregroundStyle(Color.primary) }
                    }
                }
            } else if let error {
                ContentUnavailableView("Journey unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                Button("Retry") { retry = UUID() }
                Text("Return to the search to find journeys in the current timetable.").font(.caption)
            } else {
                ProgressView("Checking journey…")
            }
        }
        .navigationTitle("Journey details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: retry) {
            response = nil
            error = nil
            do {
                let value = try await client.journey(id: id)
                try Task.checkCancellation()
                response = value
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func transferTitle(_ mode: String) -> String {
        switch mode {
        case "interchange": "Change trains"
        case "walk": "Walk between stations"
        case "tubeTransfer", "tube": "Tube transfer"
        case "bus", "replacementBus": "Bus transfer"
        default: "Connecting transfer"
        }
    }
}

private extension Color {
    static var plannerActionText: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemCyan : UIColor(red: 0, green: 0.3, blue: 0.65, alpha: 1)
        })
    }

    static var plannerDestructiveText: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemRed : UIColor(red: 0.75, green: 0.05, blue: 0.06, alpha: 1)
        })
    }

    static var plannerSecondaryText: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .lightGray : .darkGray
        })
    }
}
