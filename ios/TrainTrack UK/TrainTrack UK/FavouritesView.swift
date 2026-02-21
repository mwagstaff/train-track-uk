import SwiftUI
import CoreLocation

struct FavouritesView: View {
    @EnvironmentObject var store: JourneyStore
    @EnvironmentObject var depStore: DeparturesStore
    @EnvironmentObject var activityMgr: LiveActivityManager
    @EnvironmentObject var router: TabRouter
    @State private var journeyPendingDelete: JourneyGroup? = nil
    @State private var showDeleteDialog = false
    @State private var journeyPendingFav: JourneyGroup? = nil
    @State private var showFavDialog = false
    @State private var manualOrderedJourneys: [JourneyGroup] = []
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @StateObject private var location = LocationManagerPhone()
    @State private var isSelecting = false
    @State private var selectedJourneyIds: Set<UUID> = []
    @State private var showMultiDeleteDialog = false
    @AppStorage("showClosestJourneyLegOnly") private var showClosestJourneyLegOnly: Bool = true
    @AppStorage("distanceVeryCloseMiles") private var veryCloseMiles: Double = 3
    @AppStorage("distanceModeratelyCloseMiles") private var moderatelyCloseMiles: Double = 5
    @AppStorage("journeySortMode") private var journeySortModeRaw: String = JourneySortMode.distance.rawValue

    private var sortMode: JourneySortMode {
        JourneySortMode(rawValue: journeySortModeRaw) ?? .distance
    }

    private let longPressDuration: Double = 0.2
    private let longPressDistance: CGFloat = 20

    private var normalizedActiveSearchText: String {
        debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var hasEnteredSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasActiveSearch: Bool { !normalizedActiveSearchText.isEmpty }

    var favourites: [JourneyGroup] {
        store.journeyGroups().filter { $0.favorite }
    }

    private var visibleFavourites: [JourneyGroup] { applyClosestLegFilter(favourites) }
    private var filteredFavourites: [JourneyGroup] { visibleFavourites.filter(matchesSearch) }

    private var alphabeticallySortedFavourites: [JourneyGroup] {
        filteredFavourites.sorted { $0.startStation.name < $1.startStation.name }
    }

    private var groups: [Group] { grouped(from: filteredFavourites) }
    private var filteredManualJourneys: [JourneyGroup] { applyClosestLegFilter(manualOrderedJourneys).filter(matchesSearch) }
    private var shouldShowSearchBar: Bool { visibleFavourites.count >= 2 }

    var body: some View { toolbarView }

    private var baseListView: AnyView {
        let snapshot = groups
        return AnyView(
            VStack(spacing: 0) {
                List { listContent(snapshot) }
                if shouldShowSearchBar {
                    searchBar
                }
            }
        )
    }

    private var navigationView: some View {
        baseListView
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Favourites")
            .navigationDestination(for: JourneyGroup.self) { group in
                JourneyDetailsView(group: group)
                    .onAppear { searchFocused = false }
            }
    }

    private var lifecycleView: some View {
        navigationView
            .onAppear {
                location.request()
                refreshManualOrder()
            }
            .onDisappear {
                searchFocused = false
                isSelecting = false
                selectedJourneyIds.removeAll()
                debounceTask?.cancel()
            }
            .onChange(of: store.journeys) { _ in
                refreshManualOrder()
            }
            .onChange(of: searchText) { value in
                debounceTask?.cancel()
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    debouncedSearchText = ""
                    return
                }
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        debouncedSearchText = trimmed
                    }
                }
            }
    }

    private var alertsView: some View {
        lifecycleView
            .alert(item: Binding(get: {
                activityMgr.lastMessage.map { AlertMsg(text: $0) }
            }, set: { _ in activityMgr.lastMessage = nil })) { m in
                Alert(title: Text(m.text))
            }
            .confirmationDialog(
                "Delete this journey?",
                isPresented: $showDeleteDialog,
                presenting: journeyPendingDelete
            ) { j in
                Button("Delete journey", role: .destructive) {
                    store.remove(group: j, includeReturn: true)
                }
                Button("Cancel", role: .cancel) { }
            } message: { _ in
                Text("Delete this journey?")
            }
            .confirmationDialog(
                multiDeleteTitle,
                isPresented: $showMultiDeleteDialog
            ) {
                Button("Delete \(multiDeleteNoun)", role: .destructive) {
                    let selected = store.journeyGroups().filter { selectedJourneyIds.contains($0.id) }
                    selected.forEach { store.remove(group: $0, includeReturn: true) }
                    selectedJourneyIds.removeAll()
                    isSelecting = false
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Are you sure you want to delete the selected \(multiDeleteNoun)?")
            }
        .confirmationDialog(
            "Remove from favourites?",
            isPresented: $showFavDialog,
            presenting: journeyPendingFav
        ) { j in
            Button("Remove from favourites", role: .destructive) {
                store.setFavorite(group: j, includeReturn: true, value: false)
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Remove this journey from favourites?")
        }
    }

    private var toolbarView: AnyView {
        let view = alertsView
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if isSelecting {
                        Button("Cancel") {
                            selectedJourneyIds.removeAll()
                            isSelecting = false
                        }
                    }
                    if isSelecting && !selectedJourneyIds.isEmpty {
                        Button("Unfavourite", role: .destructive) {
                            let selected = store.journeyGroups().filter { selectedJourneyIds.contains($0.id) }
                            selected.forEach { store.setFavorite(group: $0, includeReturn: true, value: false) }
                            selectedJourneyIds.removeAll()
                            isSelecting = false
                        }
                    }
                    if isSelecting && !selectedJourneyIds.isEmpty {
                        Button("Delete") {
                            showMultiDeleteDialog = true
                        }
                    }
                    if sortMode == .manual && !manualOrderedJourneys.isEmpty && !hasEnteredSearch && !isSelecting {
                        EditButton()
                    }
                }
            }
        return AnyView(view)
    }

    // MARK: - Grouping helpers
    private func distanceMiles(from coord: CLLocationCoordinate2D?, to station: Station) -> Double? {
        guard let loc = coord else { return nil }
        let d = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
            .distance(from: CLLocation(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude))
        return d / 1609.344 // meters -> miles
    }

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let items: [JourneyGroup]
    }

    private func groupsEmpty(_ groups: [Group]) -> Bool {
        groups.allSatisfy { $0.items.isEmpty }
    }

    private func sortedByDistance(_ journeys: [JourneyGroup]) -> [JourneyGroup] {
        if let _ = location.coordinate {
            return journeys.sorted { (a, b) in
                let da = distanceMiles(from: location.coordinate, to: a.startStation) ?? .greatestFiniteMagnitude
                let db = distanceMiles(from: location.coordinate, to: b.startStation) ?? .greatestFiniteMagnitude
                if da != db { return da < db }
                let endCompare = a.endStation.name.localizedCaseInsensitiveCompare(b.endStation.name)
                if endCompare != .orderedSame { return endCompare == .orderedAscending }
                return a.displayTitle.localizedCaseInsensitiveCompare(b.displayTitle) == .orderedAscending
            }
        } else {
            return journeys.sorted { $0.startStation.name < $1.startStation.name }
        }
    }

    private func grouped(from journeys: [JourneyGroup]) -> [Group] {
        let sorted = sortedByDistance(journeys)
        var veryClose: [JourneyGroup] = []
        var moderately: [JourneyGroup] = []
        var far: [JourneyGroup] = []
        for j in sorted {
            let miles = distanceMiles(from: location.coordinate, to: j.startStation) ?? .infinity
            if miles < veryCloseMiles { veryClose.append(j) }
            else if miles <= moderatelyCloseMiles { moderately.append(j) }
            else { far.append(j) }
        }
        return [
            Group(title: "Very close (<\(formatMiles(veryCloseMiles)) miles)", items: veryClose),
            Group(title: "Moderately close (≤\(formatMiles(moderatelyCloseMiles)) miles)", items: moderately),
            Group(title: "Far away (>\(formatMiles(moderatelyCloseMiles)) miles)", items: far)
        ]
    }
}

// MARK: - Extracted helpers to keep type-checking simple

extension FavouritesView {
    @ViewBuilder
    private func compatUnavailable(
        title: String,
        systemImage: String,
        description: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        if #available(iOS 17.0, *) {
            VStack(spacing: 12) {
                ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 34)).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Text(description).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
        }
    }
    @ViewBuilder
    private var emptySection: some View {
        Section("Favourites") {
            if hasActiveSearch {
                compatUnavailable(title: "No matches", systemImage: "magnifyingglass", description: "Try searching for another station or CRS code.")
            } else {
                compatUnavailable(
                    title: "No favourites yet",
                    systemImage: "star",
                    description: "Add favourite journeys to see them here.",
                    actionTitle: "Add favourite journey",
                    action: {
                        router.addJourneyPrefillFavourite = true
                        router.selected = .addJourney
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func listContent(_ groups: [Group]) -> some View {
        switch sortMode {
        case .distance:
            if groupsEmpty(groups) {
                emptySection
            } else {
                groupSections(groups)
            }
        case .alphabetical:
            if alphabeticallySortedFavourites.isEmpty {
                emptySection
            } else {
                alphabeticalSection
            }
        case .manual:
            if manualOrderedJourneys.isEmpty {
                emptySection
            } else {
                manualSection
            }
        }
    }

    @ViewBuilder
    private func groupSections(_ groups: [Group]) -> some View {
        ForEach(groups) { group in
            if !group.items.isEmpty {
                Section(group.title) {
                    ForEach(group.items) { j in
                        journeyRow(j) {
                            Button(role: .destructive) {
                                journeyPendingDelete = j
                                showDeleteDialog = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                journeyPendingFav = j
                                showFavDialog = true
                            } label: {
                                Label("Unfavourite", systemImage: "star.slash.fill")
                            }
                        }
                    }
                }
            }
        }
    }

    private func refreshManualOrder() {
        manualOrderedJourneys = store.sortedFavouritesByManualOrder()
    }

    @ViewBuilder
    private var alphabeticalSection: some View {
        Section("Favourites") {
            ForEach(alphabeticallySortedFavourites) { j in
                journeyRow(j) {
                    Button(role: .destructive) {
                        journeyPendingDelete = j
                        showDeleteDialog = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        journeyPendingFav = j
                        showFavDialog = true
                    } label: {
                        Label("Unfavourite", systemImage: "star.slash.fill")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var manualSection: some View {
        Section("Favourites") {
            ForEach(filteredManualJourneys) { j in
                journeyRow(j) {
                    Button(role: .destructive) {
                        journeyPendingDelete = j
                        showDeleteDialog = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        journeyPendingFav = j
                        showFavDialog = true
                    } label: {
                        Label("Unfavourite", systemImage: "star.slash.fill")
                    }
                }
            }
            .onMove { source, destination in
                if isSelecting { return }
                let visibleIds = Set(filteredManualJourneys.map { $0.id })
                let visibleIndices = manualOrderedJourneys.enumerated().filter { visibleIds.contains($0.element.id) }.map { $0.offset }
                let mappedSource = IndexSet(source.map { visibleIndices[$0] })
                let target = destination >= visibleIndices.count ? manualOrderedJourneys.count : visibleIndices[destination]
                manualOrderedJourneys.move(fromOffsets: mappedSource, toOffset: target)
                store.updateFavouriteManualOrder(manualOrderedJourneys.map { $0.id })
            }
        }
    }
}

// Row is now shared in JourneyListRow.swift

#Preview {
    NavigationStack {
        FavouritesView()
            .environmentObject(JourneyStore.shared)
            .environmentObject(TabRouter.shared)
    }
}

private func formatMiles(_ v: Double) -> String {
    if v.rounded() == v { return String(Int(v)) }
    return String(format: "%.1f", v)
}

private extension FavouritesView {
    struct JourneyPairKey: Hashable {
        let routeKey: String
    }

    func matchesSearch(_ group: JourneyGroup) -> Bool {
        let term = normalizedActiveSearchText
        guard !term.isEmpty else { return true }
        return group.stationSequence.contains { station in
            station.name.lowercased().contains(term) || station.crs.lowercased().contains(term)
        }
    }

    func applyClosestLegFilter(_ groups: [JourneyGroup]) -> [JourneyGroup] {
        guard showClosestJourneyLegOnly else { return groups }
        var selection: [JourneyPairKey: JourneyGroup] = [:]
        for group in groups {
            let key = pairKey(for: group)
            if let existing = selection[key] {
                if isCloser(group, than: existing) {
                    selection[key] = group
                }
            } else {
                selection[key] = group
            }
        }
        let selectedIds = Set(selection.values.map { $0.id })
        return groups.filter { selectedIds.contains($0.id) }
    }

    func pairKey(for group: JourneyGroup) -> JourneyPairKey {
        let crs = group.stationSequence.map { $0.crs.uppercased() }
        let forward = crs.joined(separator: "-")
        let reverse = crs.reversed().joined(separator: "-")
        let key = min(forward, reverse)
        return JourneyPairKey(routeKey: key)
    }

    func isCloser(_ candidate: JourneyGroup, than existing: JourneyGroup) -> Bool {
        let candidateDistance = distanceMiles(from: location.coordinate, to: candidate.startStation)
        let existingDistance = distanceMiles(from: location.coordinate, to: existing.startStation)
        switch (candidateDistance, existingDistance) {
        case let (c?, e?): return c < e
        case (_?, nil): return true
        default: return false
        }
    }

    var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .font(.callout)
                .focused($searchFocused)
                .submitLabel(.done)
                .onSubmit { searchFocused = false }
            if hasEnteredSearch {
                Button {
                    searchText = ""
                    debouncedSearchText = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .frame(maxWidth: UIScreen.main.bounds.width * ((hasEnteredSearch || searchFocused) ? 1.0 : 0.3))
        .padding(.horizontal)
        .padding(.vertical, 8)
        .animation(.easeInOut(duration: 0.2), value: hasEnteredSearch)
        .animation(.easeInOut(duration: 0.2), value: searchFocused)
    }

    private var multiDeleteNoun: String {
        selectedJourneyIds.count == 1 ? "journey" : "journeys"
    }

    private var multiDeleteTitle: String {
        "Delete selected \(multiDeleteNoun)?"
    }

    @ViewBuilder
    private func journeyRow(_ group: JourneyGroup, @ViewBuilder actions: () -> some View) -> some View {
        if isSelecting {
            Button {
                toggleSelection(group)
            } label: {
                rowContent(for: group)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink(value: group) {
                rowContent(for: group)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true, content: actions)
            .highPriorityGesture(
                LongPressGesture(minimumDuration: longPressDuration, maximumDistance: longPressDistance)
                    .onEnded { _ in startSelection(with: group) }
            )
        }
    }

    private func rowContent(for group: JourneyGroup) -> some View {
        HStack(spacing: 12) {
            if isSelecting {
                selectionIndicator(for: group)
            }
            JourneyListRow(group: group)
        }
        .contentShape(Rectangle())
    }

    private func selectionIndicator(for group: JourneyGroup) -> some View {
        let selected = selectedJourneyIds.contains(group.id)
        return Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .accessibilityLabel(selected ? "Selected" : "Not selected")
    }

    private func startSelection(with group: JourneyGroup) {
        guard !isSelecting else { return }
        isSelecting = true
        selectedJourneyIds = [group.id]
        searchFocused = false
    }

    private func toggleSelection(_ group: JourneyGroup) {
        if selectedJourneyIds.contains(group.id) {
            selectedJourneyIds.remove(group.id)
        } else {
            selectedJourneyIds.insert(group.id)
        }
        if selectedJourneyIds.isEmpty {
            isSelecting = false
        }
    }
}

private struct AlertMsg: Identifiable { let id = UUID(); let text: String }
