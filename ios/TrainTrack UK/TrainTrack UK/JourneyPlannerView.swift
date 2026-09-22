import CoreLocation
import SwiftUI

enum AddJourneyNavigationDestination: Hashable {
    case plannerResults
}

struct AddJourneyEntryView: View {
    let plannerStore: JourneyPlannerStore
    @Binding var navigationPath: [AddJourneyNavigationDestination]

    var body: some View {
        if JourneyPlannerFeature.isEnabled {
            JourneyPlannerView(store: plannerStore, navigationPath: $navigationPath)
        } else {
            AddJourneyView(isTabRoot: true)
        }
    }
}

struct JourneyPlannerView: View {
    let store: JourneyPlannerStore
    @Binding var navigationPath: [AddJourneyNavigationDestination]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stationField: StationField?
    @State private var stationFieldsFlash = false
    @State private var stationFieldsFlashTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?

    private enum ScrollTarget: Hashable {
        case stationFields
    }

    private enum StationField: String, Identifiable {
        case origin, destination
        var id: String { rawValue }
        var title: String { self == .origin ? "From" : "To" }
    }

    var body: some View {
        @Bindable var store = store
        ScrollViewReader { scrollProxy in
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
            .id(ScrollTarget.stationFields)

            Section {
                Picker("When", selection: Binding(get: { store.timeMode }, set: { mode in
                    if store.timeMode == .now && mode != .now {
                        store.explicitTime = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970 / 60) * 60)
                    }
                    store.timeMode = mode
                })) {
                    ForEach(PlannerTimeMode.searchCases) { mode in Text(mode.title).tag(mode) }
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
                if let notice = PlannerTime.localTimeNotice() {
                    Label(notice, systemImage: "globe")
                        .font(.caption)
                        .foregroundStyle(Color.primary)
                        .accessibilityIdentifier("planner.local-time-zone-note")
                }
                if let message = store.validationMessage(), store.origin != nil && store.destination != nil {
                    Text(message).foregroundStyle(Color.primary)
                }
            }

            plannerAvailabilitySection

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
                if store.recents.searches.isEmpty {
                    Text("Completed searches will appear here.").foregroundStyle(Color.plannerSecondaryText)
                }
                ForEach(store.recents.searches) { recent in
                    Button {
                        restore(recent, scrollProxy: scrollProxy)
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
                    .accessibilityHint("Fills the station fields and returns to the top.")
                    .accessibilityAction(named: "Remove recent search") { store.recents.remove(id: recent.id) }
                }
                if !store.recents.searches.isEmpty {
                    Button(role: .destructive) { store.recents.clear() } label: {
                        Text("Clear recent searches").foregroundStyle(Color.plannerDestructiveText)
                    }
                }
            } header: {
                RailwayBackgroundSectionHeader(title: "Recent searches")
            }
        }
        .tint(Color.plannerActionText)
        .navigationTitle("New journey")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.timeZone, PlannerTime.displayZone)
        .environment(\.calendar, PlannerTime.displayCalendar)
        .sheet(item: $stationField) { field in
            NavigationStack {
                PlannerStationPicker(title: field.title, client: store.client) { station in
                    if field == .origin { store.origin = station } else { store.destination = station }
                }
            }
        }
        .navigationDestination(for: AddJourneyNavigationDestination.self) { destination in
            switch destination {
            case .plannerResults:
                PlannerResultsView(store: store, loadPage: { startSearch(cursor: $0) }, cancelSearch: {
                    searchTask?.cancel()
                    store.cancelSearch()
                }, rerunSearch: { startSearch() })
            }
        }
        .onChange(of: navigationPath) { _, path in
            if !path.contains(.plannerResults) {
                searchTask?.cancel()
                store.cancelSearch()
            }
        }
        .onChange(of: store.intent) { previous, current in
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
            stationFieldsFlashTask?.cancel()
        }
        }
        .railwayBackgroundPOC()
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
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.plannerActionText.opacity(stationFieldsFlash ? 0.18 : 0))
                .padding(.horizontal, -8)
                .padding(.vertical, -4)
        }
        .scaleEffect(stationFieldsFlash && !reduceMotion ? 1.015 : 1)
        .accessibilityIdentifier("planner.\(field.rawValue)")
        .accessibilityLabel("\(title), \(station?.name ?? "select station")")
    }

    private func restore(_ recent: PlannerRecentSearch, scrollProxy: ScrollViewProxy) {
        searchTask?.cancel()
        store.restore(recent)
        stationFieldsFlashTask?.cancel()
        stationFieldsFlash = false

        if reduceMotion {
            scrollProxy.scrollTo(ScrollTarget.stationFields, anchor: .top)
            stationFieldsFlash = true
            stationFieldsFlashTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                stationFieldsFlash = false
            }
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                scrollProxy.scrollTo(ScrollTarget.stationFields, anchor: .top)
            }
            stationFieldsFlashTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    stationFieldsFlash = true
                }
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    stationFieldsFlash = false
                }
            }
        }
    }

    @ViewBuilder private var plannerAvailabilitySection: some View {
        if store.isLoadingStatus {
            Section { ProgressView("Checking journey planner…") }
        } else if let status = store.status, !status.available {
            Section {
                Text(status.reason ?? "The journey planner is unavailable.")
                    .foregroundStyle(Color.primary)
                Button("Retry") { Task { await store.loadStatus() } }
            }
        } else if let error = store.statusError {
            Section {
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
            if cursor == nil,
               store.response != nil,
               !navigationPath.contains(.plannerResults) {
                navigationPath.append(.plannerResults)
            }
            if cursor == nil && !repeatingLastSearch {
                await store.searchForLaterTrainsWhenInitialWindowIsEmpty()
            }
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
    var excludedStationCodes: Set<String> = []
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
                ForEach(stations.filter { !excludedStationCodes.contains($0.crs.uppercased()) }) { station in
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
                ForEach(nearbyStations.filter { !excludedStationCodes.contains($0.station.crs.uppercased()) }.prefix(
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
                ForEach(recentStations.filter { !excludedStationCodes.contains($0.crs.uppercased()) }.prefix(
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

private struct PendingPlannerJourneySave {
    let stations: [Station]
    let destinationTab: Tab
    let startUpdates: Bool
    let saveAsFavourite: Bool
}

private struct PlannerResultsView: View {
    let store: JourneyPlannerStore
    let loadPage: (String) -> Void
    let cancelSearch: () -> Void
    let rerunSearch: () -> Void
    @State private var loadingButtonTitle: String?
    @State private var selectedJourneyID: String?
    @State private var travelVia = false
    @State private var selectingVia = false
    @State private var saveJourney = false
    @State private var startTrackingNow = false
    @State private var scheduleJourney = false
    @State private var saveAsFavourite = false
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var scheduleDestination: NotificationScheduleDestination?
    @State private var pendingScheduledSave: PendingPlannerJourneySave?
    @State private var scheduleWasSaved = false
    @State private var stationCatalogue = StationsService.shared.stations
    @ObservedObject private var config = ServerConfigStore.shared
    @EnvironmentObject private var router: TabRouter
    @EnvironmentObject private var depStore: DeparturesStore
    @EnvironmentObject private var activityMgr: LiveActivityManager
    @EnvironmentObject private var notificationStore: NotificationSubscriptionStore
    @AppStorage("liveActivityDurationMinutes") private var liveActivityDurationMinutes: Int = 60

    var body: some View {
        List {
            journeyOptionsSection
            if let error = store.searchError {
                Text(error.message).foregroundStyle(Color.primary)
            }
            if store.isSearching {
                ProgressView(store.searchProgress.title)
                Button("Cancel search", role: .cancel, action: cancelSearch)
                    .accessibilityIdentifier("planner.cancel-search")
            }
            if let response = store.response {
                if response.journeys.isEmpty {
                    Section {
                        Label(store.automaticSearchState == .noJourneysInNext24Hours ? "No journeys in the next 24 hours" : "No journeys in this window", systemImage: "tram")
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
                        Text(store.automaticSearchState == .noJourneysInNext24Hours
                             ? "We looked ahead for 24 hours but couldn't find a journey. You can keep searching later times, or go back to change your search."
                             : "Try another time window, or go back to change your search.")
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
                        .disclosureGroupStyle(NavigationChevronDisclosureStyle())
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
                        .disclosureGroupStyle(NavigationChevronDisclosureStyle())
                    }
                }
            }
        }
        .navigationTitle(routeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .railwayBackgroundPOC(showsInfoButton: false)
        .task {
            try? await StationsService.shared.loadStations()
            stationCatalogue = StationsService.shared.stations
            if store.via != nil { travelVia = true }
        }
        .sheet(isPresented: $selectingVia) {
            NavigationStack {
                PlannerStationPicker(
                    title: "Travel via",
                    client: store.client,
                    excludedStationCodes: Set([store.origin?.crs, store.destination?.crs].compactMap { $0?.uppercased() })
                ) { station in
                    store.via = station
                    rerunSearch()
                }
            }
        }
        .sheet(item: $scheduleDestination, onDismiss: finishScheduling) { destination in
            NotificationScheduleView(
                group: destination.group,
                reverseGroup: destination.reverseGroup,
                existingSubscription: destination.existingSubscription,
                dismissControl: .back,
                onSaved: { scheduleWasSaved = true }
            )
        }
        .navigationDestination(item: $selectedJourneyID) { id in
            PlannerJourneyDetailView(id: id, client: store.client)
        }
    }

    private var routeTitle: String {
        "\(store.origin?.name ?? "Journey") → \(store.destination?.name ?? "Journey")"
    }

    @ViewBuilder private var journeyOptionsSection: some View {
        Section {
            Toggle("Travel via", isOn: Binding(
                get: { travelVia },
                set: { enabled in
                    travelVia = enabled
                    saveMessage = nil
                    if !enabled, store.via != nil {
                        store.via = nil
                        rerunSearch()
                    }
                }
            ))
            .accessibilityIdentifier("planner.travel-via")

            if travelVia {
                Button { selectingVia = true } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Intermediate station")
                            .font(.caption)
                            .foregroundStyle(Color.plannerSecondaryText)
                        Text(store.via.map { "\($0.name) (\($0.crs))" } ?? "Select station")
                            .foregroundStyle(store.via == nil ? Color.plannerActionText : Color.primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("planner.via-station")
            }

            Toggle("Save journey", isOn: $saveJourney)
                .accessibilityIdentifier("planner.save-journey")

            if saveJourney {
                Toggle("Start journey updates now", isOn: $startTrackingNow)
                    .accessibilityIdentifier("planner.save.start-tracking")
                Toggle("Schedule journey", isOn: $scheduleJourney)
                    .accessibilityIdentifier("planner.save.schedule")
                Toggle("Save to Favourites", isOn: $saveAsFavourite)
                    .accessibilityIdentifier("planner.save.favourite")
                if let saveMessage {
                    Label(saveMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.primary)
                }
                Button(action: saveSelectedJourney) {
                    if isSaving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Label("Save", systemImage: "tray.and.arrow.down")
                    }
                }
                .disabled(!canSaveJourney)
                .accessibilityIdentifier("planner.save.submit")
            }
        }
    }

    private var selectedStations: [Station]? {
        guard let origin = store.origin, let destination = store.destination else { return nil }
        var stations = [station(from: origin)]
        if travelVia {
            guard let via = store.via else { return nil }
            stations.append(station(from: via))
        }
        stations.append(station(from: destination))
        return stations
    }

    private var canSaveJourney: Bool { selectedStations != nil && !isSaving }

    private func station(from value: PlannerStation) -> Station {
        if let station = stationCatalogue.first(where: { $0.crs.caseInsensitiveCompare(value.crs) == .orderedSame }) {
            return station
        }
        return Station(
            crs: value.crs,
            name: value.name,
            longitude: value.longitude.map { String($0) } ?? "0",
            latitude: value.latitude.map { String($0) } ?? "0"
        )
    }

    private func saveSelectedJourney() {
        guard let stations = selectedStations else { return }
        isSaving = true
        saveMessage = nil
        let destinationTab: Tab = saveAsFavourite ? .favourites : .myJourneys
        if scheduleJourney {
            guard let group = savedGroup(for: stations)
                    ?? transientGroup(for: stations, favorite: saveAsFavourite),
                  let reverseGroup = savedGroup(for: Array(stations.reversed()))
                    ?? transientGroup(for: Array(stations.reversed()), favorite: saveAsFavourite) else {
                saveMessage = "This journey could not be prepared for scheduling."
                isSaving = false
                return
            }
            pendingScheduledSave = PendingPlannerJourneySave(
                stations: stations,
                destinationTab: destinationTab,
                startUpdates: startTrackingNow,
                saveAsFavourite: saveAsFavourite
            )
            scheduleWasSaved = false
            scheduleDestination = NotificationScheduleDestination(
                group: group,
                reverseGroup: reverseGroup,
                existingSubscription: nil
            )
            return
        }

        guard let group = commitJourney(stations: stations, saveAsFavourite: saveAsFavourite) else {
            saveMessage = "This journey could not be saved."
            isSaving = false
            return
        }
        if startTrackingNow { startJourneyUpdates(for: group) }
        finishSave(on: group.favorite ? .favourites : destinationTab)
    }

    private func finishScheduling() {
        let pending = pendingScheduledSave
        let shouldCommit = scheduleWasSaved
        pendingScheduledSave = nil
        scheduleWasSaved = false

        guard shouldCommit, let pending else {
            isSaving = false
            return
        }
        guard let group = commitJourney(
            stations: pending.stations,
            saveAsFavourite: pending.saveAsFavourite
        ) else {
            saveMessage = "This journey could not be saved."
            isSaving = false
            return
        }
        if pending.startUpdates { startJourneyUpdates(for: group) }
        finishSave(on: group.favorite ? .favourites : pending.destinationTab)
    }

    private func commitJourney(stations: [Station], saveAsFavourite: Bool) -> JourneyGroup? {
        let journeyStore = JourneyStore.shared
        if !journeyStore.groupExists(for: stations) {
            journeyStore.addJourneyGroup(stations: stations, favorite: saveAsFavourite, saveReturn: true)
        }
        let shouldFavouritePair = saveAsFavourite || savedGroup(for: stations)?.favorite == true
        let reverseStations = Array(stations.reversed())
        if !journeyStore.groupExists(for: reverseStations) {
            journeyStore.addJourneyGroup(stations: reverseStations, favorite: shouldFavouritePair, saveReturn: false)
        }
        guard var group = savedGroup(for: stations) else { return nil }
        if saveAsFavourite && !group.favorite {
            journeyStore.setFavorite(group: group, includeReturn: true, value: true)
            group = savedGroup(for: stations) ?? group
        }
        return group
    }

    private func savedGroup(for stations: [Station]) -> JourneyGroup? {
        let stationCodes = stations.map { $0.crs.uppercased() }
        return JourneyStore.shared.journeyGroups().first { group in
            group.stationSequence.map { $0.crs.uppercased() } == stationCodes
        }
    }

    private func transientGroup(for stations: [Station], favorite: Bool) -> JourneyGroup? {
        guard stations.count >= 2 else { return nil }
        let groupID = UUID()
        let createdAt = Date()
        let legs = stations.indices.dropLast().map { index in
            Journey(
                id: UUID(),
                groupId: groupID,
                legIndex: index,
                fromStation: stations[index],
                toStation: stations[index + 1],
                createdAt: createdAt,
                favorite: favorite
            )
        }
        return JourneyGroup(id: groupID, legs: legs)
    }

    private func startJourneyUpdates(for group: JourneyGroup) {
        Task {
            _ = await JourneyUpdateActions.start(
                group: group,
                scheduledSubscription: nil,
                liveSession: nil,
                liveActivityDurationMinutes: liveActivityDurationMinutes,
                notificationStore: notificationStore,
                activityManager: activityMgr,
                departuresStore: depStore
            )
        }
    }

    private func finishSave(on tab: Tab) {
        isSaving = false
        router.selected = tab
    }

    private func departureCard(_ journeys: [PlannedJourney]) -> some View {
        let comparison = JourneyDurationComparison(journeys: journeys)
        let firstFastestIndex = journeys.indices.first { comparison.tag(for: journeys[$0]) == .fastest }
        return VStack(spacing: 0) {
            ForEach(Array(journeys.enumerated()), id: \.element.id) { index, journey in
                let comparisonTag = comparison.tag(for: journey)
                let displayedTag = comparisonTag == .fastest && index != firstFastestIndex ? nil : comparisonTag
                Button {
                    selectedJourneyID = journey.id
                } label: {
                    PlannerJourneySummary(journey: journey, showsChevron: true, durationTag: displayedTag)
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

struct PlannerChangesBadge: View {
    let changes: Int

    private var fill: Color {
        let rgb: (Double, Double, Double)
        switch changes {
        case 1: rgb = (191, 232, 195)
        case 2: rgb = (231, 232, 160)
        case 3: rgb = (244, 211, 138)
        case 4: rgb = (244, 179, 131)
        default: rgb = (236, 146, 139)
        }
        return Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255)
    }

    var body: some View {
        if changes > 0 {
            JourneyMetadataBadge(
                text: "\(changes) change\(changes == 1 ? "" : "s")",
                foreground: .black,
                background: fill
            )
                .accessibilityIdentifier("planner.changes.\(changes)")
        } else {
            Text("Direct").font(.caption).foregroundStyle(Color.plannerSecondaryText)
        }
    }
}

struct PlannerJourneySummary: View {
    let journey: PlannedJourney
    var showsChevron = false
    var liveIsStale = false
    var durationTag: JourneyDurationTag? = nil
    var showsRefreshWarnings = true
    var showsTravelNotes = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4

    private var cancelled: Bool { journey.legs.contains { $0.live?.isCancelled == true } }
    private var departureLeg: PlannedJourney.Leg? { journey.legs.first }
    var status: (text: String, color: Color) {
        let annotations = journey.legs.compactMap(\.live)
        if cancelled { return ("Cancelled", .plannerDestructiveText) }
        if annotations.contains(where: \.isDelayed) {
            let delay = annotations.map { max($0.departureDelayMinutes ?? 0, $0.arrivalDelayMinutes ?? 0) }.max() ?? 0
            return ("Delayed", delay >= 5 ? .plannerDestructiveText : .plannerWarningText)
        }
        if annotations.contains(where: { $0.partCancelled == true || $0.status == "partCancelled" }) {
            return ("Part cancelled", .plannerWarningText)
        }
        if liveIsStale, !PlannerLivePresentation.timingEvidence(for: journey).isEmpty {
            return ("Live times out of date", .plannerSecondaryText)
        }
        // Disruption on any train is reported above. Otherwise headline the first train, as
        // single-train cards do; the details line says how many trains are confirmed.
        if let summary = PlannerLivePresentation.onTimeSummary(for: journey),
           summary == "Train on time" || summary == "All trains on time"
            || journey.legs.first(where: { $0.kind == "vehicle" && $0.mode == "rail" })?.live?.status == "onTime" {
            return ("On time", .plannerOnTimeText)
        }
        if journey.legs.contains(where: { $0.localJourney?.isAvailable == true }),
           !journey.legs.contains(where: { $0.kind == "vehicle" }) {
            return ("Estimated", .plannerSecondaryText)
        }
        return PlannerLivePresentation.timingEvidence(for: journey).isEmpty
            ? ("Scheduled", .plannerSecondaryText) : ("Unknown", .plannerSecondaryText)
    }

    var body: some View {
        let times = PlannerTime.journeyResultTimes(from: journey.departure, to: journey.arrival)
        DepartureSummaryRow(timing: {
            VStack(alignment: .leading, spacing: 0) {
                JourneyTimesView(
                    departure: times.departure,
                    arrival: times.arrival,
                    departureColor: cancelled ? .plannerSecondaryText : .primary,
                    cancelled: cancelled
                )
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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }, details: {
            departureDetails
        }, footer: {
            summaryFooter
        }, showsChevron: showsChevron)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var summaryFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            durationLabel
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    journeyBadges
                    PlannerJourneyOperators(journey: journey)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 8) {
                        journeyBadges
                        Spacer(minLength: 8)
                        PlannerJourneyOperators(journey: journey)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        journeyBadges
                        PlannerJourneyOperators(journey: journey)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var journeyBadges: some View {
        HStack(spacing: 6) {
            if journey.changes > 0 { PlannerChangesBadge(changes: journey.changes) }
            if let durationTag { JourneyDurationBadge(tag: durationTag) }
        }
    }

    @ViewBuilder private var durationLabel: some View {
        if journey.changes == 0 {
            Text("\(PlannerTime.minutes(journey.durationMinutes)) · Direct")
                .font(.caption).foregroundStyle(Color.plannerSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(PlannerTime.minutes(journey.durationMinutes))
                .font(.caption)
                .foregroundStyle(Color.plannerSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var departureDetails: some View {
        VStack(alignment: .leading, spacing: 1) {
            if journey.requiresTransferCheck {
                Label("Check transfer options", systemImage: "exclamationmark.triangle.fill")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.plannerWarningText)
                    .accessibilityLabel("Warning: check transfer options")
                    .accessibilityIdentifier("planner.transfer-warning.\(journey.id)")
            }
            let scheduledDeparture = journey.scheduledDeparture ?? departureLeg?.scheduledDeparture ?? journey.departure
            let scheduledArrival = journey.scheduledArrival ?? journey.legs.last?.scheduledArrival ?? journey.arrival
            if abs(journey.departure.timeIntervalSince(scheduledDeparture)) >= 30 || abs(journey.arrival.timeIntervalSince(scheduledArrival)) >= 30 {
                Text("Scheduled \(PlannerTime.displayRange(from: scheduledDeparture, to: scheduledArrival))")
            }
            if !liveIsStale, let summary = PlannerLivePresentation.onTimeSummary(for: journey),
               summary != "Train on time", summary != "All trains on time" {
                Text(summary)
            }
            let localChanges = journey.legs.reduce(0) { $0 + ($1.localJourney?.changes ?? 0) }
            if localChanges > 0 {
                Text("Includes \(localChanges) \(localChanges == 1 ? "change" : "changes") within London transport.")
            }
            if showsTravelNotes {
                let warnings = PlannerLivePresentation.searchResultWarnings(for: journey).filter {
                    showsRefreshWarnings || !PlannerLivePresentation.isRefreshFailureWarning($0)
                }
                ForEach(Array(warnings.prefix(2)), id: \.self) { warning in
                    Text(warning).foregroundStyle(Color.primary)
                }
                if warnings.count > 2 { Text("More travel notes in journey details.") }
            }
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
        let operators = journey.legs.filter { $0.kind == "vehicle" || $0.isTubeTransfer }.flatMap { leg -> [OperatorBranding] in
            if leg.localJourney?.isWalkingOnly == true {
                return [OperatorBranding(name: "Walk", operatorCodes: [], aliases: [], colorHex: "#FFFFFF")]
            }
            if let local = leg.localJourney, local.isAvailable, !local.lines.isEmpty {
                return local.lines.map { OperatorBranding(name: $0.name, operatorCodes: [], aliases: [], colorHex: $0.colour ?? "666666") }
            }
            return [leg.isTubeTransfer
                ? OperatorBranding(name: "Tube", operatorCodes: [], aliases: [], colorHex: "#FFFFFF")
                : OperatorBrandingResolver.resolve(name: leg.operator, code: leg.operator, in: branding)
                ?? OperatorBranding(name: leg.operator ?? "Train service", operatorCodes: [], aliases: [], colorHex: "666666")]
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
        if leg.mode == "bus" || leg.mode == "replacementBus" {
            HStack(spacing: 8) {
                operatorPill
                Spacer(minLength: 8)
                PlatformBadge(platform: "BUS", isBus: true)
                    .accessibilityIdentifier("planner.leg.bus")
            }
        } else {
            operatorPill
        }
    }

    @ViewBuilder private var operatorPill: some View {
        if leg.localJourney?.isWalkingOnly == true {
            Label("Walk", systemImage: "figure.walk").font(.caption)
        } else if let local = leg.localJourney, local.isAvailable, !local.lines.isEmpty {
            PlannerLocalLinePills(lines: local.lines)
        } else {
            let branding = leg.isTubeTransfer
                ? OperatorBranding(name: "Tube", operatorCodes: [], aliases: [], colorHex: "#FFFFFF")
                : OperatorBrandingResolver.resolve(name: leg.operator, code: leg.operator, in: config.operatorBranding)
                    ?? OperatorBranding(name: leg.operator ?? "Train service", operatorCodes: [], aliases: [], colorHex: "#666666")
            PlannerTransportPill(branding: branding, showsRoundel: leg.isTubeTransfer)
        }
    }
}

private struct PlannerLocalLinePills: View {
    let lines: [PlannerLocalJourney.Line]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) { pills }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { pills }
                VStack(alignment: .leading, spacing: 6) { pills }
            }
        }
    }

    private var pills: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            let background = branding(hex: line.colour)
            let foreground = branding(hex: line.textColour)?.color
                ?? background.map { $0.usesBlackText ? Color.black : Color.white } ?? Color.primary
            Text(line.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(background?.color ?? Color(uiColor: .secondarySystemFill), in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.15), lineWidth: 1))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("planner.local-line.\(line.id)")
        }
    }

    private func branding(hex: String?) -> OperatorBranding? {
        guard let hex, hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).count == 6,
              UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) != nil else { return nil }
        return OperatorBranding(name: "", operatorCodes: [], aliases: [], colorHex: hex)
    }
}

private struct PlannerLocalJourneyDetails: View {
    let local: PlannerLocalJourney
    let displayDate: Date

    var body: some View {
        ForEach(Array(local.travelNotes.enumerated()), id: \.offset) { index, note in
            Label(note, systemImage: "info.circle")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("planner.local-note.\(index)")
        }
        if local.isAvailable {
            ForEach(Array((local.steps ?? []).enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 8) {
                    if let change = local.changeInstruction(before: index) {
                        Text(change).font(.subheadline.weight(.semibold))
                    }
                    if let lines = step.lines, !lines.isEmpty { PlannerLocalLinePills(lines: lines) }
                    Text("\(index + 1). \(step.instruction)")
                        .font(.subheadline.weight(.medium))
                    Text("\(step.from.name) → \(step.to.name)")
                        .font(.subheadline)
                    if let platform = step.from.platform, !platform.isEmpty {
                        Text("Platform \(platform)").font(.caption)
                    }
                    ForEach(PlannerLivePresentation.unique((step.lines ?? []).compactMap(\.direction)), id: \.self) { direction in
                        Text("Towards \(direction)").font(.caption)
                    }
                    if let departure = step.departureTime, let arrival = step.arrivalTime {
                        Text("\(PlannerTime.displayRange(from: departure, to: arrival)) · \(step.timing == "adjusted" ? "Adjusted" : "Estimated")")
                            .font(.caption)
                            .foregroundStyle(Color.plannerSecondaryText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("planner.local-step.\(index)")
            }
        }
        if let expires = local.expiresAt, expires <= displayDate {
            Label("London transport information may be out of date. Search again for an update.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let updated = local.updatedAt {
            Text("London transport checked \(PlannerTime.display(updated))")
                .font(.caption).foregroundStyle(Color.plannerSecondaryText)
        }
        if let attribution = local.attribution, !attribution.isEmpty {
            Text(attribution).font(.caption).foregroundStyle(Color.plannerSecondaryText)
        }
    }
}

struct PlannerJourneyDetailView: View {
    let id: String
    let client: any JourneyPlannerServing
    var initialResponse: PlannerJourneyResponse? = nil
    var allowsTrainTracking = false
    @State private var response: PlannerJourneyResponse?
    @State private var error: String?
    @State private var retry = UUID()
    @State private var displayDate = Date()

    private var liveIsStale: Bool {
        guard let response else { return false }
        return PlannerLivePresentation.hasExpiredEvidence(for: response.journey, context: response.live, at: displayDate)
    }

    var body: some View {
        List {
            if let response {
                Section {
                    Text("Summary").font(.headline)
                    if response.journey.legs.contains(where: { $0.localJourney?.isAvailable == true }),
                       !response.journey.legs.contains(where: { $0.kind == "vehicle" }) {
                        Label("Estimated London transport times", systemImage: "clock")
                    } else {
                        PlannerLiveContextView(live: PlannerLivePresentation.context(for: response.journey, from: response.live, at: displayDate))
                    }
                    PlannerJourneySummary(journey: response.journey, liveIsStale: liveIsStale)
                        .accessibilityIdentifier("planner.detail.summary")
                    ForEach(Array(PlannerLivePresentation.warnings(for: response.journey).dropFirst(2)), id: \.self) { warning in
                        Text(warning).font(.caption)
                    }
                    let interchanges = response.journey.legs.filter { $0.kind == "transfer" }.map(\.heading)
                    if !interchanges.isEmpty {
                        Text(interchanges.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(Array(response.journey.legs.enumerated()), id: \.offset) { index, leg in
                    Section {
                        if leg.isTrainChange {
                            Text("Allow at least \(PlannerTime.minutes(leg.transfer?.interchangeMinutes ?? leg.arrival.timeIntervalSince(leg.departure) / 60)) to change trains.")
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            if leg.requiresTransferCheck {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label("Check transfer options", systemImage: "exclamationmark.triangle.fill")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.plannerWarningText)
                                        .accessibilityLabel("Warning: check transfer options")
                                    Text("No specific transport service is listed for this transfer.")
                                    Text("Check your options before travelling. In London, you may need a taxi or night bus when the Tube is closed.")
                                }
                                .font(.subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("planner.transfer-warning.\(index)")
                            }
                            if leg.kind == "vehicle" || leg.isTubeTransfer { PlannerLegPill(leg: leg) }
                            let includeDate = !PlannerTime.calendar.isDate(leg.departure, inSameDayAs: leg.arrival)
                            if let live = leg.live, !liveIsStale { PlannerLiveBadge(live: live) }
                            LabeledContent("Depart from \(leg.from.name)") {
                                PlannerEventTimeView(time: leg.departure, scheduled: leg.scheduledDeparture,
                                    expected: leg.live?.departure, cancelled: leg.live?.isCancelled == true, includeDate: includeDate)
                            }
                            LabeledContent("Arrive at \(leg.to.name)") {
                                PlannerEventTimeView(time: leg.arrival, scheduled: leg.scheduledArrival,
                                    expected: leg.live?.arrival, cancelled: leg.live?.isCancelled == true, includeDate: includeDate)
                            }
                            if let local = leg.localJourney {
                                PlannerLocalJourneyDetails(local: local, displayDate: displayDate)
                            }
                            if let points = leg.callingPoints, !points.isEmpty {
                                DisclosureGroup("Calling points") {
                                    ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(point.station.name)
                                                .foregroundStyle(point.live?.isCancelled == true ? Color.red : Color.primary)
                                                .strikethrough(point.live?.isCancelled == true, color: .red)
                                            if let live = point.live, !liveIsStale { PlannerLiveBadge(live: live) }
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
                                .disclosureGroupStyle(NavigationChevronDisclosureStyle())
                                .accessibilityIdentifier("planner.calling-points.\(index)")
                            }
                            if let transfer = leg.transfer {
                                if let exit = transfer.exitMinutes, let travel = transfer.travelMinutes, let entry = transfer.entryMinutes {
                                    Text("Allow \(PlannerTime.minutes(exit)) to leave, \(PlannerTime.minutes(travel)) for the transfer and \(PlannerTime.minutes(entry)) before boarding.")
                                }
                                if let extra = transfer.extraMinutes, extra > 0 { Text("Extra connection time: \(PlannerTime.minutes(extra)).") }
                                if let waiting = transfer.waitingMinutes, waiting > 0 { Text("Waiting time: \(PlannerTime.minutes(waiting)).") }
                                if leg.mode != "walk" && leg.mode != "interchange" && leg.localJourney?.isAvailable != true && !leg.requiresTransferCheck {
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
                            if allowsTrainTracking && leg.kind == "vehicle" && leg.mode == "rail" {
                                PlannerTrainTrackingButton(leg: leg)
                            }
                            ForEach(PlannerLivePresentation.visibleWarnings((leg.warnings ?? []) + (leg.live?.warnings ?? []))
                                .filter { !(leg.localJourney?.travelNotes ?? []).contains($0) }, id: \.self) { Text($0).font(.caption).foregroundStyle(Color.primary) }
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
        .task {
            while !Task.isCancelled {
                displayDate = Date()
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
            }
        }
        .task(id: retry) {
            response = initialResponse
            error = nil
            if initialResponse != nil { return }
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

struct NavigationChevronDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Spacer(minLength: 8)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.navigationChevron)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")

            if configuration.isExpanded {
                configuration.content
                    .padding(.top, 8)
            }
        }
    }
}

extension Color {
    static var navigationChevron: Color {
        Color(uiColor: .tertiaryLabel)
    }

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
