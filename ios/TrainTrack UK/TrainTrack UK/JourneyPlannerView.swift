import CoreLocation
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
            }, changeLiveTimes: { enabled in
                store.useLiveTimes = enabled
                startSearch(repeatingLastSearch: true)
            })
        }
        .onChange(of: resultsPresented) { _, presented in
            if !presented {
                searchTask?.cancel()
                store.cancelSearch()
            }
        }
        .onChange(of: store.intent) { previous, current in
            // The live-times toggle owns its rerun; route/date edits cancel the old query.
            if let previous, let current, previous.matches(current) { return }
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
            Toggle("Use live times", isOn: Binding(get: { store.useLiveTimes }, set: { enabled in
                store.useLiveTimes = enabled
                if store.isSearching { startSearch() }
            }))
            .accessibilityIdentifier("planner.live-times")
            Text("Live times cover journeys in the next 4 hours. Turn off to use scheduled times; live disruption warnings will still be shown.")
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

    private func startSearch(cursor: String? = nil, repeatingLastSearch: Bool = false) {
        searchTask?.cancel()
        searchTask = Task {
            await store.search(cursor: cursor, repeatingLastSearch: repeatingLastSearch)
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
    @EnvironmentObject private var historyStore: JourneyHistoryStore
    @State private var query = ""
    @State private var stations: [PlannerStation] = []
    @State private var stationCatalogue = StationsService.shared.stations
    @State private var nearbyStations: [StationSuggestionPolicy.NearbyStation] = []
    @State private var recentStations: [Station] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var retry = UUID()
    @State private var showsMoreNearby = false
    @State private var showsAllRecent = false
    @StateObject private var location = LocationManagerPhone()

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if normalizedQuery.isEmpty {
                nearbySection
                recentSection
            } else {
                if isLoading { ProgressView("Finding stations…") }
                if let error {
                    Text(error).foregroundStyle(Color.primary)
                    Button("Retry") { retry = UUID() }
                } else if normalizedQuery.count < 2 {
                    Text("Enter at least two letters or a three-letter station code.")
                        .foregroundStyle(Color.plannerSecondaryText)
                } else if !isLoading && stations.isEmpty {
                    Text("No matching stations in the available timetable.")
                        .foregroundStyle(Color.plannerSecondaryText)
                }
                ForEach(stations) { station in
                    stationButton(station)
                }
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Station name or code")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task {
            location.request()
            try? await StationsService.shared.loadStations()
            stationCatalogue = StationsService.shared.stations
            refreshNearbyStations()
            refreshRecentStations()
        }
        .onChange(of: location.coordinateTimestamp) {
            refreshNearbyStations()
        }
        .onChange(of: historyStore.records.map(\.id)) {
            refreshRecentStations()
        }
        .task(id: "\(query)|\(retry)") {
            let requestedQuery = normalizedQuery
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

    private var nearbySection: some View {
        Section("Nearby stations") {
            if location.lastKnownCoordinate == nil {
                Text("Allow location access to see the closest stations.")
                    .foregroundStyle(Color.plannerSecondaryText)
            } else if nearbyStations.isEmpty {
                Text("No nearby stations available.")
                    .foregroundStyle(Color.plannerSecondaryText)
            } else {
                ForEach(nearbyStations.prefix(
                    showsMoreNearby
                        ? StationSuggestionPolicy.expandedNearbyCount
                        : StationSuggestionPolicy.defaultNearbyCount
                )) { nearby in
                    stationButton(plannerStation(from: nearby.station), detail: distanceText(nearby.distance))
                }
                if nearbyStations.count > StationSuggestionPolicy.defaultNearbyCount {
                    Button {
                        showsMoreNearby.toggle()
                    } label: {
                        Label(
                            showsMoreNearby ? "Show fewer nearby stations" : "Show more nearby stations",
                            systemImage: showsMoreNearby ? "chevron.up" : "chevron.down"
                        )
                    }
                    .accessibilityIdentifier("planner.nearby.toggle")
                }
            }
        }
    }

    private var recentSection: some View {
        Section("Recently used") {
            if recentStations.isEmpty {
                Text("Stations from completed journeys will appear here.")
                    .foregroundStyle(Color.plannerSecondaryText)
            } else {
                ForEach(recentStations.prefix(
                    showsAllRecent ? recentStations.count : StationSuggestionPolicy.defaultRecentCount
                )) { station in
                    stationButton(plannerStation(from: station))
                }
                if recentStations.count > StationSuggestionPolicy.defaultRecentCount {
                    Button {
                        showsAllRecent.toggle()
                    } label: {
                        Label(
                            showsAllRecent ? "Show fewer recently used stations" : "Show all recently used stations",
                            systemImage: showsAllRecent ? "chevron.up" : "chevron.down"
                        )
                    }
                    .accessibilityIdentifier("planner.recent.toggle")
                }
            }
        }
    }

    private func stationButton(_ station: PlannerStation, detail: String? = nil) -> some View {
        Button {
            select(station)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name).foregroundStyle(Color.primary)
                    Text(station.crs).font(.caption).foregroundStyle(Color.plannerSecondaryText)
                }
                Spacer()
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Color.plannerSecondaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("planner.station.\(station.crs)")
    }

    private func refreshNearbyStations() {
        guard let coordinate = location.lastKnownCoordinate else {
            nearbyStations = []
            return
        }
        nearbyStations = StationSuggestionPolicy.nearbyStations(
            in: stationCatalogue,
            from: coordinate
        )
    }

    private func refreshRecentStations() {
        recentStations = StationSuggestionPolicy.recentStations(
            from: historyStore.records,
            catalogue: stationCatalogue
        )
    }

    private func plannerStation(from station: Station) -> PlannerStation {
        let coordinate = station.hasUsableCoordinate ? station.coordinate : nil
        return PlannerStation(
            crs: station.crs,
            name: station.name,
            latitude: coordinate?.latitude,
            longitude: coordinate?.longitude
        )
    }

    private func distanceText(_ distance: Double) -> String {
        let miles = distance / 1_609.344
        if miles < 0.1 { return "<0.1 mi" }
        return miles.formatted(.number.precision(.fractionLength(1))) + " mi"
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
    let changeLiveTimes: (Bool) -> Void
    @State private var loadingButtonTitle: String?
    @State private var selectedJourneyID: String?
    @ObservedObject private var config = ServerConfigStore.shared

    var body: some View {
        List {
            if let response = store.response {
                Section {
                    Text("\(stationName(response.search.origin)) → \(stationName(response.search.destination))")
                        .font(.headline)
                    Toggle("Use live times", isOn: Binding(get: { store.useLiveTimes }, set: changeLiveTimes))
                        .accessibilityIdentifier("planner.live-times")
                    PlannerLiveContextView(live: response.live)
                    Text(PlannerTime.displayRange(from: response.search.window.from, to: response.search.window.to, separator: " – "))
                        .font(.caption)
                    if response.search.searchTruncated {
                        Text("Some journeys may be missing.").foregroundStyle(Color.primary)
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
                        Text("\(response.search.timeType == "arriveBy" ? "Arrivals" : "Departures") searched: \(PlannerTime.displayRange(from: response.search.window.from, to: response.search.window.to, separator: " – "))")
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
                            pageButton("Search later times", cursor: later)
                                .accessibilityIdentifier("planner.empty.later")
                        }
                        if let earlier = response.pagination.earlier {
                            pageButton("Search earlier times", cursor: earlier)
                                .accessibilityIdentifier("planner.empty.earlier")
                        }
                    }
                }
                if !response.journeys.isEmpty {
                    departureCard(response.journeys)
                }
                if let disrupted = response.disruptedJourneys, !disrupted.isEmpty {
                    Section {
                        DisclosureGroup("Unavailable options (\(disrupted.count))") {
                            Text("These scheduled options are affected by cancellations or connections that can no longer be made.")
                                .font(.caption)
                            ForEach(disrupted) { journey in
                                NavigationLink {
                                    PlannerJourneyDetailView(id: journey.id, client: store.client)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.red)
                                        PlannerJourneySummary(journey: journey)
                                    }
                                }
                                .accessibilityIdentifier("planner.disrupted.\(journey.id)")
                            }
                        }
                        .accessibilityIdentifier("planner.disrupted-options")
                    }
                }
                Section {
                    if let more = response.pagination.more {
                        pageButton("More journeys", cursor: more, systemImage: "plus")
                            .accessibilityIdentifier("planner.more")
                    }
                    if !response.journeys.isEmpty {
                        if let earlier = response.pagination.earlier {
                            pageButton("Earlier journeys", cursor: earlier, systemImage: "arrow.up")
                                .accessibilityIdentifier("planner.earlier")
                        }
                        if let later = response.pagination.later {
                            pageButton("Later journeys", cursor: later, systemImage: "arrow.down")
                                .accessibilityIdentifier("planner.later")
                        }
                    }
                }
                .disabled(store.isSearching)
                let searchNotes = PlannerLivePresentation.unique(response.warnings)
                    .filter { !(response.live?.warnings ?? []).contains($0) }
                if !searchNotes.isEmpty {
                    Section {
                        DisclosureGroup("Search notes") {
                            ForEach(searchNotes, id: \.self) { note in
                                Text(note).font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Journeys")
        .navigationBarTitleDisplayMode(.inline)
        .railwayBackgroundPOC(showsInfoButton: false)
        .navigationDestination(item: $selectedJourneyID) { id in
            PlannerJourneyDetailView(id: id, client: store.client)
        }
    }

    private func departureCard(_ journeys: [PlannedJourney]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(journeys.enumerated()), id: \.element.id) { index, journey in
                Button {
                    selectedJourneyID = journey.id
                } label: {
                    PlannerJourneySummary(journey: journey, showsChevron: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(PlannerJourneyOperators.brandings(for: journey, in: config.operatorBranding).first?.color ?? Color.secondary.opacity(0.35))
                                .frame(width: 4)
                                .padding(.top, 2)
                                .padding(.bottom, index == journeys.count - 1 ? 16 : 2)
                                .accessibilityHidden(true)
                                .allowsHitTesting(false)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("planner.journey.\(journey.id)")
                .accessibilityHint("Opens journey details and calling points.")
                if index < journeys.count - 1 {
                    Divider().padding(.horizontal, 16)
                }
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
    }

    private func stationName(_ crs: String) -> String {
        if store.origin?.crs == crs { return store.origin?.name ?? crs }
        if store.destination?.crs == crs { return store.destination?.name ?? crs }
        return crs
    }

    private func pageButton(_ title: String, cursor: String, systemImage: String? = nil) -> some View {
        Button {
            loadingButtonTitle = title
            loadPage(cursor)
        } label: {
            HStack {
                if store.isSearching && loadingButtonTitle == title {
                    ProgressView()
                        .accessibilityIdentifier("planner.pagination.spinner")
                } else if let systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(store.isSearching)
    }
}

private struct PlannerJourneySummary: View {
    let journey: PlannedJourney
    var showsChevron = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4

    private var cancelled: Bool { journey.legs.contains { $0.live?.isCancelled == true } }
    private var departureLeg: PlannedJourney.Leg? { journey.legs.first }
    private var includesDate: Bool {
        !PlannerTime.calendar.isDate(journey.departure, inSameDayAs: journey.arrival)
    }

    private var status: (text: String, color: Color) {
        let annotations = journey.legs.compactMap(\.live)
        if cancelled { return ("Cancelled", .plannerDestructiveText) }
        if annotations.contains(where: \.isDelayed) {
            let delay = annotations.map { max($0.departureDelayMinutes ?? 0, $0.arrivalDelayMinutes ?? 0) }.max() ?? 0
            return ("Delayed", delay >= 5 ? .plannerDestructiveText : .plannerWarningText)
        }
        if annotations.contains(where: { $0.partCancelled == true || $0.status == "partCancelled" }) {
            return ("Part cancelled", .plannerWarningText)
        }
        if let summary = PlannerLivePresentation.onTimeSummary(for: journey) {
            return summary == "Train on time" || summary == "All trains on time"
                ? ("On time", .plannerOnTimeText) : ("Some live times", .plannerSecondaryText)
        }
        return annotations.isEmpty ? ("Scheduled", .plannerSecondaryText) : ("Unknown", .plannerSecondaryText)
    }

    var body: some View {
        DepartureSummaryRow(timing: {
            VStack(alignment: .leading, spacing: 0) {
                Text(PlannerTime.display(journey.departure, includeDate: includesDate))
                    .font(.title3)
                    .monospacedDigit()
                    .foregroundStyle(cancelled ? Color.plannerSecondaryText : Color.primary)
                    .strikethrough(cancelled)
                if !cancelled, departureLeg?.mode == "rail" {
                    TrainLengthIndicator(cars: departureLeg?.live?.length, warningThreshold: minShortTrainCars)
                }
            }
        }, platform: {
            if !cancelled, let leg = departureLeg, leg.kind == "vehicle" {
                PlatformBadge(platform: leg.live?.platform ?? "TBC", isBus: leg.mode == "bus" || leg.mode == "replacementBus")
            }
        }, status: {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(status.color)
                    .fixedSize(horizontal: false, vertical: true)
                if !cancelled {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(JourneyCardPresentation.relativeDepartureLabel(departure: journey.departure, now: context.date))
                            .font(.caption)
                            .foregroundStyle(Color.plannerSecondaryText)
                            .monospacedDigit()
                    }
                }
            }
        }, details: {
            departureDetails
        }, footer: {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    durationAndChanges
                    PlannerJourneyOperators(journey: journey)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack(alignment: .bottom, spacing: 8) {
                    durationAndChanges
                    Spacer(minLength: 8)
                    PlannerJourneyOperators(journey: journey)
                }
            }
        }, showsChevron: showsChevron)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var durationAndChanges: some View {
        Text("\(PlannerTime.minutes(journey.durationMinutes)) · \(journey.changes == 0 ? "Direct" : "\(journey.changes) change\(journey.changes == 1 ? "" : "s")")")
            .font(.caption)
            .foregroundStyle(Color.plannerSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var departureDetails: some View {
        VStack(alignment: .leading, spacing: 1) {
            let destination = journey.legs.last?.to.name
            Text(destination.map {
                JourneyCardPresentation.arrivalLabel(
                    time: PlannerTime.display(journey.arrival, includeDate: includesDate), destinationName: $0
                )
            } ?? "Arr \(PlannerTime.display(journey.arrival, includeDate: includesDate))")
                .strikethrough(cancelled)
            let scheduledDeparture = journey.scheduledDeparture ?? departureLeg?.scheduledDeparture ?? journey.departure
            let scheduledArrival = journey.scheduledArrival ?? journey.legs.last?.scheduledArrival ?? journey.arrival
            if abs(journey.departure.timeIntervalSince(scheduledDeparture)) >= 30 || abs(journey.arrival.timeIntervalSince(scheduledArrival)) >= 30 {
                Text("Scheduled \(PlannerTime.displayRange(from: scheduledDeparture, to: scheduledArrival))")
            }
            if let summary = PlannerLivePresentation.onTimeSummary(for: journey),
               summary != "Train on time", summary != "All trains on time" {
                Text(summary)
            }
            let warnings = PlannerLivePresentation.warnings(for: journey)
            ForEach(Array(warnings.prefix(2)), id: \.self) { warning in
                Text(warning).foregroundStyle(Color.primary)
            }
            if warnings.count > 2 { Text("More travel notes in journey details.") }
        }
        .font(.caption)
        .foregroundStyle(Color.plannerSecondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 1)
    }
}

private struct PlannerJourneyOperators: View {
    let journey: PlannedJourney
    @ObservedObject private var config = ServerConfigStore.shared

    static func brandings(for journey: PlannedJourney, in branding: OperatorBrandingConfig?) -> [OperatorBranding] {
        let operators = journey.legs.filter { $0.kind == "vehicle" || $0.isTubeTransfer }.map { leg in
            leg.isTubeTransfer
                ? OperatorBranding(name: "Tube", operatorCodes: [], aliases: [], colorHex: "#FFFFFF")
                : OperatorBrandingResolver.resolve(name: leg.operator, code: leg.operator, in: branding)
                ?? OperatorBranding(name: leg.operator ?? "Train service", operatorCodes: [], aliases: [], colorHex: "666666")
        }
        return operators.enumerated().filter { index, branding in
            !operators.prefix(index).contains { $0.id == branding.id }
        }.map(\.element)
    }

    var body: some View {
        let names = Self.brandings(for: journey, in: config.operatorBranding).map(\.name)
        Text(names.joined(separator: " · ").uppercased())
            .font(.caption.weight(.medium))
            .foregroundStyle(Color.primary.opacity(0.7))
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(names.joined(separator: ", "))
    }
}

private struct PlannerTransportPill: View {
    let branding: OperatorBranding
    var showsRoundel = false

    var body: some View {
        HStack(spacing: 5) {
            if showsRoundel {
                ZStack {
                    Circle().stroke(Color.red, lineWidth: 4).frame(width: 16, height: 16)
                    Rectangle().fill(Color(red: 0, green: 0.1, blue: 0.4)).frame(width: 24, height: 5)
                }
                .frame(width: 24, height: 20)
                .accessibilityHidden(true)
            }
            Text(branding.name)
                .foregroundStyle(branding.usesBlackText ? Color.black : Color.white)
        }
        .font(.caption)
        .frame(minHeight: 20)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(branding.color, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 1))
        .fixedSize()
    }
}

private struct PlannerLegPill: View {
    let leg: PlannedJourney.Leg
    @ObservedObject private var config = ServerConfigStore.shared
    var body: some View {
        let branding = leg.isTubeTransfer
            ? OperatorBranding(name: "Tube", operatorCodes: [], aliases: [], colorHex: "#FFFFFF")
            : OperatorBrandingResolver.resolve(name: leg.operator, code: leg.operator, in: config.operatorBranding)
                ?? OperatorBranding(name: leg.operator ?? "Train service", operatorCodes: [], aliases: [], colorHex: "#666666")
        PlannerTransportPill(branding: branding, showsRoundel: leg.isTubeTransfer)
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
                    Text("Summary").font(.headline)
                    PlannerLiveContextView(live: response.live)
                    PlannerJourneySummary(journey: response.journey)
                        .accessibilityIdentifier("planner.detail.summary")
                    ForEach(Array(PlannerLivePresentation.warnings(for: response.journey).dropFirst(2)), id: \.self) { warning in
                        Text(warning).font(.caption)
                    }
                }
                ForEach(Array(response.journey.legs.enumerated()), id: \.offset) { index, leg in
                    Section {
                        if leg.isTrainChange {
                            Text("Allow at least \(PlannerTime.minutes(leg.transfer?.interchangeMinutes ?? leg.arrival.timeIntervalSince(leg.departure) / 60)) to change trains.")
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            if leg.kind == "vehicle" || leg.isTubeTransfer { PlannerLegPill(leg: leg) }
                            let includeDate = !PlannerTime.calendar.isDate(leg.departure, inSameDayAs: leg.arrival)
                            if let live = leg.live { PlannerLiveBadge(live: live) }
                            LabeledContent("Depart from \(leg.from.name)") {
                                PlannerEventTimeView(time: leg.departure, scheduled: leg.scheduledDeparture,
                                    expected: leg.live?.departure, cancelled: leg.live?.isCancelled == true, includeDate: includeDate)
                            }
                            LabeledContent("Arrive at \(leg.to.name)") {
                                PlannerEventTimeView(time: leg.arrival, scheduled: leg.scheduledArrival,
                                    expected: leg.live?.arrival, cancelled: leg.live?.isCancelled == true, includeDate: includeDate)
                            }
                            if let points = leg.callingPoints, !points.isEmpty {
                                DisclosureGroup("Calling points") {
                                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(point.station.name)
                                                .foregroundStyle(point.live?.isCancelled == true ? Color.red : Color.primary)
                                                .strikethrough(point.live?.isCancelled == true, color: .red)
                                            if let live = point.live { PlannerLiveBadge(live: live) }
                                            if let arrival = point.arrival ?? point.scheduledArrival {
                                                LabeledContent(point.arrival == nil ? "Scheduled arrival" : "Arrive") {
                                                    PlannerEventTimeView(time: arrival, scheduled: point.scheduledArrival,
                                                        expected: point.live?.arrival, cancelled: point.live?.isCancelled == true, includeDate: includeDate)
                                                }
                                            }
                                            if let departure = point.departure ?? point.scheduledDeparture {
                                                LabeledContent(point.departure == nil ? "Scheduled departure" : "Depart") {
                                                    PlannerEventTimeView(time: departure, scheduled: point.scheduledDeparture,
                                                        expected: point.live?.departure, cancelled: point.live?.isCancelled == true, includeDate: includeDate)
                                                }
                                            }
                                            ForEach(PlannerLivePresentation.unique(point.live?.warnings ?? []), id: \.self) { Text($0).font(.caption) }
                                        }
                                        .accessibilityElement(children: .combine)
                                        .accessibilityIdentifier("planner.calling-point.\(point.station.crs)")
                                    }
                                }
                                .accessibilityIdentifier("planner.calling-points.\(index)")
                            }
                            if let transfer = leg.transfer {
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
                            NavigationLink {
                                PlannerJourneyRouteMapView(journey: response.journey, selectedLegIndex: index)
                            } label: {
                                Label("Route map", systemImage: "map")
                            }
                            .accessibilityIdentifier("planner.route-map.\(index)")
                            ForEach(PlannerLivePresentation.visibleWarnings((leg.warnings ?? []) + (leg.live?.warnings ?? [])), id: \.self) { Text($0).font(.caption).foregroundStyle(Color.primary) }
                        }
                    } header: {
                        Text("\(index + 1). \(leg.heading)")
                            .textCase(nil)
                            .fixedSize(horizontal: false, vertical: true)
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
}

extension Color {
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

    static var plannerOnTimeText: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemGreen : UIColor(red: 0, green: 0.42, blue: 0.16, alpha: 1)
        })
    }

    static var plannerWarningText: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemYellow : UIColor(red: 0.5, green: 0.32, blue: 0, alpha: 1)
        })
    }

    static var plannerSecondaryText: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .lightGray : .darkGray
        })
    }
}
