import SwiftUI
import CoreLocation

struct MyJourneysView: View {
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

    var nonFavourites: [JourneyGroup] { store.journeyGroups().filter { !$0.favorite } }
    private var visibleJourneys: [JourneyGroup] { applyClosestLegFilter(nonFavourites) }
    private var filteredJourneys: [JourneyGroup] { visibleJourneys.filter(matchesSearch) }
    private var filteredManualJourneys: [JourneyGroup] { applyClosestLegFilter(manualOrderedJourneys).filter(matchesSearch) }
    private var shouldShowSearchBar: Bool { visibleJourneys.count >= 2 }

    private var alphabeticallySortedJourneys: [JourneyGroup] {
        filteredJourneys.sorted { $0.startStation.name < $1.startStation.name }
    }

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let items: [JourneyGroup]
    }

    private func distanceMiles(from coord: CLLocationCoordinate2D?, to station: Station) -> Double? {
        guard let loc = coord else { return nil }
        let d = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
            .distance(from: CLLocation(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude))
        return d / 1609.344
    }

    private func sortedByDistance(_ journeys: [JourneyGroup]) -> [JourneyGroup] {
        if let _ = location.coordinate {
            return journeys.sorted { a, b in
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

    private func grouped() -> [Group] {
        let sorted = sortedByDistance(filteredJourneys)
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

    private var groups: [Group] { grouped() }
    private func groupsEmpty(_ groups: [Group]) -> Bool { groups.allSatisfy { $0.items.isEmpty } }

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
            .navigationTitle("My Journeys")
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
                Text("This will delete both directions.")
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
            "Add to favourites?",
            isPresented: $showFavDialog,
            presenting: journeyPendingFav
        ) { j in
            Button("Add to favourites", role: .destructive) {
                store.setFavorite(group: j, includeReturn: true, value: true)
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("Add this journey to favourites?")
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
                        Button("Favourite") {
                            let selected = store.journeyGroups().filter { selectedJourneyIds.contains($0.id) }
                            selected.forEach { store.setFavorite(group: $0, includeReturn: true, value: true) }
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

    // MARK: - Helper functions
    private func refreshManualOrder() {
        manualOrderedJourneys = store.sortedMyJourneysByManualOrder()
    }

    @ViewBuilder
    private func listContent(_ groups: [Group]) -> some View {
        switch sortMode {
        case .distance:
            if groupsEmpty(groups) {
                emptySection
            } else {
                distanceGroupSections(groups)
            }
        case .alphabetical:
            if alphabeticallySortedJourneys.isEmpty {
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
    private var emptySection: some View {
        Section("My Journeys") {
            if hasActiveSearch {
                if #available(iOS 17.0, *) {
                    ContentUnavailableView(
                        "No matches",
                        systemImage: "magnifyingglass",
                        description: Text("Try searching for another station or CRS code.")
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("No matches").font(.headline)
                        Text("Try searching for another station or CRS code.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                }
            } else {
                if #available(iOS 17.0, *) {
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "No journeys",
                            systemImage: "train.side.front.car",
                            description: Text("Your saved journeys will appear here.")
                        )
                        Button("Add journey") {
                            router.selected = .addJourney
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "train.side.front.car").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("No journeys").font(.headline)
                        Text("Your saved journeys will appear here.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("Add journey") {
                            router.selected = .addJourney
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                }
            }
        }
    }

    @ViewBuilder
    private func distanceGroupSections(_ groups: [Group]) -> some View {
        ForEach(groups) { group in
            if !group.items.isEmpty {
                Section(group.title) {
                    ForEach(group.items) { j in
                        journeyRow(j) {
                            Button(role: .destructive) {
                                journeyPendingDelete = j
                                showDeleteDialog = true
                            } label: { Label("Delete", systemImage: "trash") }
                            Button {
                                journeyPendingFav = j
                                showFavDialog = true
                            } label: { Label("Favourite", systemImage: "star.fill") }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var alphabeticalSection: some View {
        Section("My Journeys") {
            ForEach(alphabeticallySortedJourneys) { j in
                journeyRow(j) {
                    Button(role: .destructive) {
                        journeyPendingDelete = j
                        showDeleteDialog = true
                    } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        journeyPendingFav = j
                        showFavDialog = true
                    } label: { Label("Favourite", systemImage: "star.fill") }
                }
            }
        }
    }

    @ViewBuilder
    private var manualSection: some View {
        Section("My Journeys") {
            ForEach(filteredManualJourneys) { j in
                journeyRow(j) {
                    Button(role: .destructive) {
                        journeyPendingDelete = j
                        showDeleteDialog = true
                    } label: { Label("Delete", systemImage: "trash") }
                    Button {
                        journeyPendingFav = j
                        showFavDialog = true
                    } label: { Label("Favourite", systemImage: "star.fill") }
                }
            }
            .onMove { source, destination in
                if isSelecting { return }
                let visibleIds = Set(filteredManualJourneys.map { $0.id })
                let visibleIndices = manualOrderedJourneys.enumerated().filter { visibleIds.contains($0.element.id) }.map { $0.offset }
                let mappedSource = IndexSet(source.map { visibleIndices[$0] })
                let target = destination >= visibleIndices.count ? manualOrderedJourneys.count : visibleIndices[destination]
                manualOrderedJourneys.move(fromOffsets: mappedSource, toOffset: target)
                store.updateMyJourneysManualOrder(manualOrderedJourneys.map { $0.id })
            }
        }
    }
}

// Row is now shared in JourneyListRow.swift

#Preview {
    NavigationStack {
        MyJourneysView()
            .environmentObject(JourneyStore.shared)
            .environmentObject(TabRouter.shared)
    }
}

private func formatMiles(_ v: Double) -> String {
    if v.rounded() == v { return String(Int(v)) }
    return String(format: "%.1f", v)
}

private extension MyJourneysView {
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

private struct PinnedDepartureUnpinButton: View {
    let fromName: String
    let destinationName: String
    let onConfirm: () -> Void
    @State private var showingConfirmation = false

    var body: some View {
        Button {
            showingConfirmation = true
        } label: {
            Image(systemName: "pin.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Unpin departure")
        .accessibilityHint("Removes this pinned departure.")
        .confirmationDialog(
            "Remove pinned departure?",
            isPresented: $showingConfirmation
        ) {
            Button("Unpin departure", role: .destructive) {
                onConfirm()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove the pinned \(fromName) → \(destinationName) departure.")
        }
    }
}

private struct PinnedJourneyUnpinButton: View {
    let heading: String
    let onConfirm: () -> Void
    @State private var showingConfirmation = false

    var body: some View {
        Button {
            showingConfirmation = true
        } label: {
            Image(systemName: "pin.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Unpin journey")
        .accessibilityHint("Removes this pinned multi-leg journey.")
        .confirmationDialog(
            "Remove pinned journey?",
            isPresented: $showingConfirmation
        ) {
            Button("Unpin journey", role: .destructive) {
                onConfirm()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove the pinned \(heading) journey.")
        }
    }
}

private struct PinnedDepartureLiveActivityButton: View {
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Image(systemName: isActive ? "stop.fill" : "dot.radiowaves.left.and.right")
                Text(isActive ? "Stop" : "Start")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(isActive ? .red : .blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background((isActive ? Color.red : Color.blue).opacity(0.15), in: Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isActive ? "Stop Live Activity" : "Start Live Activity")
        .accessibilityHint(isActive ? "Stops Live Activity tracking for this pinned journey." : "Starts Live Activity tracking for this pinned journey.")
    }
}

struct PinnedJourneysView: View {
    @EnvironmentObject var store: JourneyStore
    @EnvironmentObject var depStore: DeparturesStore
    @EnvironmentObject var activityMgr: LiveActivityManager
    @StateObject private var location = LocationManagerPhone()
    @State private var searchText: String = ""
    @State private var debouncedSearchText: String = ""
    @State private var debounceTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool
    @AppStorage("distanceVeryCloseMiles") private var veryCloseMiles: Double = 3
    @AppStorage("distanceModeratelyCloseMiles") private var moderatelyCloseMiles: Double = 5

    private struct Group: Identifiable {
        let id = UUID()
        let title: String
        let items: [PinnedJourneyBucket]
    }

    private struct PinnedJourneyBucket: Identifiable {
        let id: String
        let heading: String
        let pinSetID: String?
        let isMultiLeg: Bool
        let fromStation: Station
        var rows: [PinnedDepartureRowItem]
    }

    fileprivate struct PinnedDepartureRowItem: Identifiable {
        let id: String
        let leg: Journey
        let departure: DepartureV2
        let metadata: PinnedDepartureMetadata
    }

    private var pinnedDepartureRows: [PinnedDepartureRowItem] {
        var rows: [PinnedDepartureRowItem] = []
        var seen = Set<String>()
        for group in store.journeyGroups() {
            for leg in group.legs {
                for dep in depStore.departures(for: leg) where depStore.isPinned(dep, fromCRS: leg.fromStation.crs, toCRS: leg.toStation.crs) {
                    guard let metadata = depStore.pinnedMetadata(for: dep, fromCRS: leg.fromStation.crs, toCRS: leg.toStation.crs) else { continue }
                    let key = "\(leg.fromStation.crs.uppercased())_\(leg.toStation.crs.uppercased())_\(dep.serviceID)"
                    if seen.insert(key).inserted {
                        rows.append(PinnedDepartureRowItem(id: key, leg: leg, departure: dep, metadata: metadata))
                    }
                }
            }
        }
        return rows
    }

    private var visiblePinnedDepartureRows: [PinnedDepartureRowItem] {
        pinnedDepartureRows
    }

    private var shouldShowSearchBar: Bool {
        visiblePinnedDepartureRows.count >= 2
    }

    private var hasEnteredSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var normalizedActiveSearchText: String {
        debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var hasActiveSearch: Bool {
        !normalizedActiveSearchText.isEmpty
    }

    private var filteredPinnedDepartureRows: [PinnedDepartureRowItem] {
        visiblePinnedDepartureRows.filter(matchesSearch)
    }

    private var groupedJourneys: [Group] {
        grouped(from: filteredPinnedDepartureRows)
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if groupedJourneys.allSatisfy({ $0.items.isEmpty }) {
                    Section("Pinned Departures") {
                        if hasActiveSearch {
                            if #available(iOS 17.0, *) {
                                ContentUnavailableView(
                                    "No matches",
                                    systemImage: "magnifyingglass",
                                    description: Text("Try searching for another station or CRS code.")
                                )
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 34))
                                        .foregroundStyle(.secondary)
                                    Text("No matches")
                                        .font(.headline)
                                    Text("Try searching for another station or CRS code.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                            }
                        } else {
                            if #available(iOS 17.0, *) {
                                ContentUnavailableView(
                                    "No pinned departures",
                                    systemImage: "pin.slash",
                                    description: Text("Pin a departure or multi-leg journey option from Journey Details to keep tracking it.")
                                )
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "pin.slash")
                                        .font(.system(size: 34))
                                        .foregroundStyle(.secondary)
                                    Text("No pinned departures")
                                        .font(.headline)
                                    Text("Pin a departure or multi-leg journey option from Journey Details to keep tracking it.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 24)
                            }
                        }
                    }
                } else {
                    ForEach(groupedJourneys) { group in
                        if !group.items.isEmpty {
                            Section(group.title) {
                                ForEach(group.items) { bucket in
                                    VStack(alignment: .leading, spacing: 10) {
                                        HStack(alignment: .center, spacing: 10) {
                                            Text(bucket.heading)
                                                .font(.headline)
                                                .foregroundStyle(.primary)
                                            Spacer(minLength: 0)
                                            PinnedDepartureLiveActivityButton(
                                                isActive: isLiveActivityActive(for: bucket)
                                            ) {
                                                Task {
                                                    await toggleLiveActivityForPinnedBucket(bucket)
                                                }
                                            }
                                        }
                                        if bucket.isMultiLeg {
                                            HStack(spacing: 8) {
                                                Text("Dep \(journeyDepartureLabel(for: bucket))")
                                                Text("Arr \(journeyArrivalLabel(for: bucket))")
                                                Spacer(minLength: 0)
                                                if let pinSetID = bucket.pinSetID {
                                                    PinnedJourneyUnpinButton(heading: bucket.heading) {
                                                        depStore.unpinPinSet(pinSetID)
                                                    }
                                                }
                                            }
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        }
                                        ForEach(Array(bucket.rows.enumerated()), id: \.element.id) { index, row in
                                            HStack(spacing: 10) {
                                                NavigationLink(
                                                    destination: ServiceMapView(
                                                        serviceID: row.departure.serviceID,
                                                        fromCRS: row.leg.fromStation.crs,
                                                        toCRS: row.leg.toStation.crs
                                                    )
                                                ) {
                                                    PinnedDepartureRowContent(
                                                        row: row,
                                                        showLegRoute: bucket.isMultiLeg
                                                    )
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                }
                                                .buttonStyle(.plain)

                                                if !bucket.isMultiLeg {
                                                    PinnedDepartureUnpinButton(
                                                        fromName: row.leg.fromStation.name,
                                                        destinationName: row.departure.destination.first?.locationName ?? row.leg.toStation.name
                                                    ) {
                                                        depStore.unpin(row.departure, fromCRS: row.leg.fromStation.crs, toCRS: row.leg.toStation.crs)
                                                    }
                                                }
                                            }
                                            if index < bucket.rows.count - 1 {
                                                Divider()
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if shouldShowSearchBar {
                searchBar
            }
        }
        .navigationTitle("Pinned")
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            location.request()
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
        .onDisappear {
            searchFocused = false
            debounceTask?.cancel()
        }
    }

    private func matchesSearch(_ row: PinnedDepartureRowItem) -> Bool {
        guard !normalizedActiveSearchText.isEmpty else { return true }
        let destinationName = row.departure.destination.first?.locationName ?? row.leg.toStation.name
        return row.leg.fromStation.name.lowercased().contains(normalizedActiveSearchText)
            || row.leg.toStation.name.lowercased().contains(normalizedActiveSearchText)
            || row.leg.fromStation.crs.lowercased().contains(normalizedActiveSearchText)
            || row.leg.toStation.crs.lowercased().contains(normalizedActiveSearchText)
            || destinationName.lowercased().contains(normalizedActiveSearchText)
    }

    private func activityLegsForPinnedRow(_ row: PinnedDepartureRowItem) -> [Journey] {
        let allGroups = store.journeyGroups()
        let group = allGroups.first { $0.id == row.leg.groupId }
            ?? allGroups.first { g in g.legs.contains(where: { $0.id == row.leg.id }) }

        return {
            guard let group else { return [row.leg] }
            guard let startIndex = group.legs.firstIndex(where: { $0.id == row.leg.id }) else {
                return Array(group.legs.prefix(3))
            }
            let tail = Array(group.legs.dropFirst(startIndex))
            return Array(tail.prefix(3))
        }()
    }

    private func isLiveActivityActive(for row: PinnedDepartureRowItem) -> Bool {
        activityMgr.isActive(for: row.leg, preferredServiceID: row.departure.serviceID)
    }

    private func isLiveActivityActive(for bucket: PinnedJourneyBucket) -> Bool {
        bucket.rows.contains { isLiveActivityActive(for: $0) }
    }

    private func toggleLiveActivityForPinnedBucket(_ bucket: PinnedJourneyBucket) async {
        if let activeRow = bucket.rows.first(where: { isLiveActivityActive(for: $0) }) {
            await toggleLiveActivityForPinnedRow(activeRow)
            return
        }
        guard let firstRow = bucket.rows.first else { return }
        await toggleLiveActivityForPinnedRow(firstRow)
    }

    private func toggleLiveActivityForPinnedRow(_ row: PinnedDepartureRowItem) async {
        let legsToTrack = activityLegsForPinnedRow(row)
        let isSelectedPinnedServiceActive = activityMgr.isActive(for: row.leg, preferredServiceID: row.departure.serviceID)
        let activeLegs = legsToTrack.filter { activityMgr.isActive(for: $0) }

        if isSelectedPinnedServiceActive {
            for leg in activeLegs {
                await activityMgr.stop(for: leg)
            }
            let stillActive = activeLegs.filter { activityMgr.isActive(for: $0) }.count
            let stoppedCount = activeLegs.count - stillActive
            if stoppedCount > 0 {
                let message = stoppedCount == 1
                    ? "Live Activity stopped"
                    : "Live Activity stopped for \(stoppedCount) legs"
                ToastStore.shared.show(message, icon: "stop.fill")
            } else {
                ToastStore.shared.show("Unable to stop Live Activity", icon: "exclamationmark.triangle.fill")
            }
            return
        }

        // Always start/retarget the selected leg to this exact pinned service.
        // For downstream legs, only start if they are not already active.
        let legsToStart: [Journey] = legsToTrack.filter { leg in
            if leg.id == row.leg.id { return true }
            return !activityMgr.isActive(for: leg)
        }
        guard !legsToStart.isEmpty else {
            ToastStore.shared.show("Unable to start Live Activity", icon: "exclamationmark.triangle.fill")
            return
        }

        for leg in legsToStart {
            let preferredServiceID = (leg.id == row.leg.id) ? row.departure.serviceID : nil
            await activityMgr.start(
                for: leg,
                depStore: depStore,
                preferredServiceID: preferredServiceID,
                triggeredByUser: true,
                bypassSuppression: true
            )
        }

        let selectedNowActive = activityMgr.isActive(for: row.leg, preferredServiceID: row.departure.serviceID)
        let downstreamStartedCount = legsToTrack
            .filter { $0.id != row.leg.id && activityMgr.isActive(for: $0) }
            .count
        if selectedNowActive {
            let totalStarted = 1 + downstreamStartedCount
            let message = totalStarted == 1
                ? "Live Activity started"
                : "Live Activity started for \(totalStarted) legs"
            ToastStore.shared.show(message, icon: "dot.radiowaves.left.and.right")
        } else {
            ToastStore.shared.show("Unable to start Live Activity", icon: "exclamationmark.triangle.fill")
        }
    }

    private func distanceMiles(from coord: CLLocationCoordinate2D?, to station: Station) -> Double? {
        guard let loc = coord else { return nil }
        let d = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
            .distance(from: CLLocation(latitude: station.coordinate.latitude, longitude: station.coordinate.longitude))
        return d / 1609.344
    }

    private func grouped(from rows: [PinnedDepartureRowItem]) -> [Group] {
        let sorted: [PinnedDepartureRowItem]
        if location.coordinate != nil {
            sorted = rows.sorted { lhs, rhs in
                let lhsMiles = distanceMiles(from: location.coordinate, to: lhs.leg.fromStation) ?? .greatestFiniteMagnitude
                let rhsMiles = distanceMiles(from: location.coordinate, to: rhs.leg.fromStation) ?? .greatestFiniteMagnitude
                if lhsMiles != rhsMiles { return lhsMiles < rhsMiles }
                let fromCompare = lhs.leg.fromStation.name.localizedCaseInsensitiveCompare(rhs.leg.fromStation.name)
                if fromCompare != .orderedSame { return fromCompare == .orderedAscending }
                let endCompare = lhs.leg.toStation.name.localizedCaseInsensitiveCompare(rhs.leg.toStation.name)
                if endCompare != .orderedSame { return endCompare == .orderedAscending }
                let lhsDate = departureComparableDate(lhs.departure) ?? .distantFuture
                let rhsDate = departureComparableDate(rhs.departure) ?? .distantFuture
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.id < rhs.id
            }
        } else {
            sorted = rows.sorted { lhs, rhs in
                let fromCompare = lhs.leg.fromStation.name.localizedCaseInsensitiveCompare(rhs.leg.fromStation.name)
                if fromCompare != .orderedSame { return fromCompare == .orderedAscending }
                let toCompare = lhs.leg.toStation.name.localizedCaseInsensitiveCompare(rhs.leg.toStation.name)
                if toCompare != .orderedSame { return toCompare == .orderedAscending }
                let lhsDate = departureComparableDate(lhs.departure) ?? .distantFuture
                let rhsDate = departureComparableDate(rhs.departure) ?? .distantFuture
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.id < rhs.id
            }
        }

        var byJourney: [String: PinnedJourneyBucket] = [:]
        var journeyOrder: [String] = []
        for row in sorted {
            let key = journeyBucketKey(for: row)
            if var existing = byJourney[key] {
                existing.rows.append(row)
                byJourney[key] = existing
            } else {
                journeyOrder.append(key)
                byJourney[key] = PinnedJourneyBucket(
                    id: key,
                    heading: "\(row.leg.fromStation.name) → \(row.leg.toStation.name)",
                    pinSetID: row.metadata.pinSetID,
                    isMultiLeg: false,
                    fromStation: row.leg.fromStation,
                    rows: [row]
                )
            }
        }

        var orderedBuckets: [PinnedJourneyBucket] = journeyOrder.compactMap { byJourney[$0] }
        orderedBuckets = orderedBuckets.map { bucket in
            var sortedBucket = bucket
            let isMultiLeg = sortedBucket.pinSetID != nil && sortedBucket.rows.count > 1

            sortedBucket.rows.sort { lhs, rhs in
                if isMultiLeg {
                    let lhsIndex = legSortIndex(lhs)
                    let rhsIndex = legSortIndex(rhs)
                    if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
                }
                let lhsDate = departureComparableDate(lhs.departure) ?? .distantFuture
                let rhsDate = departureComparableDate(rhs.departure) ?? .distantFuture
                if lhsDate != rhsDate { return lhsDate < rhsDate }
                return lhs.id < rhs.id
            }

            guard let first = sortedBucket.rows.first, let last = sortedBucket.rows.last else {
                return sortedBucket
            }
            let heading: String = {
                if isMultiLeg {
                    return "\(first.leg.fromStation.name) → \(last.leg.toStation.name)"
                }
                return "\(first.leg.fromStation.name) → \(first.leg.toStation.name)"
            }()

            return PinnedJourneyBucket(
                id: sortedBucket.id,
                heading: heading,
                pinSetID: sortedBucket.pinSetID,
                isMultiLeg: isMultiLeg,
                fromStation: first.leg.fromStation,
                rows: sortedBucket.rows
            )
        }

        var veryClose: [PinnedJourneyBucket] = []
        var moderately: [PinnedJourneyBucket] = []
        var far: [PinnedJourneyBucket] = []

        for bucket in orderedBuckets {
            let miles = distanceMiles(from: location.coordinate, to: bucket.fromStation) ?? .infinity
            if miles < veryCloseMiles {
                veryClose.append(bucket)
            } else if miles <= moderatelyCloseMiles {
                moderately.append(bucket)
            } else {
                far.append(bucket)
            }
        }

        return [
            Group(title: "Very close (<\(formatMiles(veryCloseMiles)) miles)", items: veryClose),
            Group(title: "Moderately close (≤\(formatMiles(moderatelyCloseMiles)) miles)", items: moderately),
            Group(title: "Far away (>\(formatMiles(moderatelyCloseMiles)) miles)", items: far)
        ]
    }

    private func journeyBucketKey(for row: PinnedDepartureRowItem) -> String {
        if let pinSetID = row.metadata.pinSetID {
            return "pinset_\(pinSetID)"
        }
        return "\(row.leg.fromStation.crs.uppercased())_\(row.leg.toStation.crs.uppercased())"
    }

    private func legSortIndex(_ row: PinnedDepartureRowItem) -> Int {
        row.metadata.journeyLegIndex ?? row.leg.legIndex
    }

    private func journeyDepartureLabel(for bucket: PinnedJourneyBucket) -> String {
        guard let first = bucket.rows.first else { return "—" }
        return displayDepartureTime(first.departure)
    }

    private func journeyArrivalLabel(for bucket: PinnedJourneyBucket) -> String {
        guard let last = bucket.rows.last else { return "—" }
        guard let details = depStore.serviceDetailsById[last.departure.serviceID] else { return "—" }
        if let cp = details.allStations.first(where: { $0.crs == last.leg.toStation.crs }) {
            if let et = cp.et, !et.isEmpty, et.lowercased() != "on time" { return et }
            return cp.st
        }
        return "—"
    }

    private func displayDepartureTime(_ dep: DepartureV2) -> String {
        let est = dep.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = est.lowercased()
        if est.isEmpty || lower == "delayed" || lower == "cancelled" || lower == "on time" {
            return dep.departureTime.scheduled
        }
        return est
    }

    private func departureComparableDate(_ dep: DepartureV2) -> Date? {
        parseHHmm(dep.departureTime.estimated) ?? parseHHmm(dep.departureTime.scheduled)
    }

    private func parseHHmm(_ t: String?) -> Date? {
        guard let t = t else { return nil }
        let lower = t.lowercased()
        if lower == "delayed" || lower == "cancelled" || lower == "on time" { return nil }
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let now = Date()
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = h
        comps.minute = m
        guard var candidate = Calendar.current.date(from: comps) else { return nil }
        if candidate < now && now.timeIntervalSince(candidate) > 6 * 3600 {
            candidate = Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private var searchBar: some View {
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
}

private struct PinnedDepartureRowContent: View {
    let row: PinnedJourneysView.PinnedDepartureRowItem
    let showLegRoute: Bool
    @EnvironmentObject var depStore: DeparturesStore
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4

    private var isCancelledDeparture: Bool {
        if row.departure.isCancelled { return true }
        return row.departure.departureTime.estimated
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "cancelled"
    }

    private var originalScheduledLabel: String {
        let scheduled = row.departure.departureTime.scheduled
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = scheduled.isEmpty ? row.departure.departureTime.estimated : scheduled
        return "Originally scheduled for \(value)"
    }

    private var timeColor: Color {
        colorForDelay(estimated: row.departure.departureTime.estimated, scheduled: row.departure.departureTime.scheduled)
    }

    private var isBus: Bool {
        row.departure.serviceType.lowercased() == "bus" || (row.departure.platform?.uppercased() == "BUS")
    }

    private var destinationLabel: String {
        if let first = row.departure.destination.first {
            if let via = first.via, !via.isEmpty {
                return "\(first.locationName) \(via)"
            }
            return first.locationName
        }
        return row.leg.toStation.name
    }

    private var routeLabel: String {
        "\(row.leg.fromStation.name) → \(destinationLabel)"
    }

    private func arrivalLabel() -> String? {
        guard let details = depStore.serviceDetailsById[row.departure.serviceID] else { return nil }
        if let cp = details.allStations.first(where: { $0.crs == row.leg.toStation.crs }) {
            if let et = cp.et, !et.isEmpty, et.lowercased() != "on time" { return "Arr \(et)" }
            return "Arr \(cp.st)"
        }
        return nil
    }

    private func statusInfo() -> (text: String, color: Color)? {
        if let mins = departureDelayMinutes(
            estimated: row.departure.departureTime.estimated,
            scheduled: row.departure.departureTime.scheduled
        ), mins > 0 {
            return ("Departure delayed by \(mins) minute\(mins == 1 ? "" : "s")", .yellow)
        }
        let estimated = row.departure.departureTime.estimated
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if estimated == "delayed" {
            return ("Departure status unknown at present", .yellow)
        }
        guard let details = depStore.serviceDetailsById[row.departure.serviceID] else { return nil }
        if let live = computeLiveStatus(from: details, within: row.leg.fromStation.crs, toCRS: row.leg.toStation.crs) {
            let c: Color = live.delayMinutes >= 5 ? .red : (live.delayMinutes > 0 ? .yellow : .green)
            return (live.text, c)
        }
        return nil
    }

    @ViewBuilder
    private var metaLine: some View {
        if isCancelledDeparture {
            Text(originalScheduledLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 10) {
                if let arr = arrivalLabel() {
                    Text(arr)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isBus {
                    EmptyView()
                } else if let l = row.departure.length, l > 0 {
                    HStack(spacing: 4) {
                        Text("\(l) cars")
                        if l <= minShortTrainCars {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 4) {
                        Text("Unknown length")
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showLegRoute ? routeLabel : destinationLabel)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: 8) {
                metaLine
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if !isCancelledDeparture {
                        PlatformBadge(
                            platform: row.departure.platform?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                            ? (row.departure.platform ?? "TBC")
                            : "TBC",
                            isBus: isBus
                        )
                    }
                    Text(row.departure.departureTime.estimated)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundStyle(timeColor)
                        .monospacedDigit()
                }
            }

            if let info = statusInfo() {
                HStack(spacing: 6) {
                    Circle().fill(info.color).frame(width: 8, height: 8)
                    Text(info.text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
        .task {
            await depStore.ensureServiceDetails(for: [row.departure.serviceID])
        }
    }
}
