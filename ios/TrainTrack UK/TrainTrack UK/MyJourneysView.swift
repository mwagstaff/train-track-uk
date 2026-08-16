import SwiftUI
import CoreLocation

struct MyJourneysView: View {
    @EnvironmentObject var store: JourneyStore
    @EnvironmentObject var depStore: DeparturesStore
    @EnvironmentObject var activityMgr: LiveActivityManager
    @EnvironmentObject var notificationStore: NotificationSubscriptionStore
    @EnvironmentObject var router: TabRouter
    @Environment(\.scenePhase) private var scenePhase
    @State private var journeyPendingDelete: JourneyGroup? = nil
    @State private var showDeleteDialog = false
    @State private var journeyPendingFav: JourneyGroup? = nil
    @State private var showFavDialog = false
    @State private var manualOrderedJourneys: [JourneyGroup] = []
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var debounceTask: Task<Void, Never>?
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool
    @StateObject private var location = LocationManagerPhone()
    @State private var isSelecting = false
    @State private var selectedJourneyIds: Set<UUID> = []
    @State private var showMultiDeleteDialog = false
    @State private var scheduleGroup: JourneyGroup?
    @State private var liveActionGroupIDs: Set<UUID> = []
    @State private var expandedJourneyIDs: Set<UUID> = []
    @State private var reversedJourneyIDs: Set<UUID> = []
    @State private var cardDestination: JourneyCardNavigationDestination?
    @AppStorage("showClosestJourneyLegOnly") private var showClosestJourneyLegOnly: Bool = true
    @AppStorage("distanceVeryCloseMiles") private var veryCloseMiles: Double = 3
    @AppStorage("distanceModeratelyCloseMiles") private var moderatelyCloseMiles: Double = 5
    @AppStorage("journeySortMode") private var journeySortModeRaw: String = JourneySortMode.distance.rawValue
    @AppStorage("liveActivityDurationMinutes") private var liveActivityDurationMinutes: Int = 60

    private var sortMode: JourneySortMode {
        JourneySortMode(rawValue: journeySortModeRaw) ?? .distance
    }

    private let longPressDuration: Double = 0.5
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

    private var alphabeticallySortedJourneys: [JourneyGroup] {
        filteredJourneys.sorted { $0.startStation.name < $1.startStation.name }
    }

    private enum GroupID: Hashable {
        case all
        case veryClose
        case moderatelyClose
        case far
    }

    private struct Group: Identifiable {
        let id: GroupID
        let title: String
        let items: [JourneyGroup]
    }

    private func distanceMiles(from coord: CLLocationCoordinate2D?, to station: Station) -> Double? {
        guard let loc = coord else { return nil }
        let currentLocation = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
        let d = station.distance(from: currentLocation)
        return d / 1609.344
    }

    private func sortedByDistance(_ journeys: [JourneyGroup]) -> [JourneyGroup] {
        if let currentLocation = location.lastKnownCoordinate {
            return journeys.sorted { a, b in
                let da = distanceMiles(from: currentLocation, to: a.startStation) ?? .greatestFiniteMagnitude
                let db = distanceMiles(from: currentLocation, to: b.startStation) ?? .greatestFiniteMagnitude
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
        guard location.lastKnownCoordinate != nil else {
            return [
                Group(
                    id: .all,
                    title: "My Journeys",
                    items: filteredJourneys.sorted { $0.startStation.name < $1.startStation.name }
                )
            ]
        }
        let sorted = sortedByDistance(filteredJourneys)
        var veryClose: [JourneyGroup] = []
        var moderately: [JourneyGroup] = []
        var far: [JourneyGroup] = []
        for j in sorted {
            let miles = distanceMiles(from: location.lastKnownCoordinate, to: j.startStation) ?? .infinity
            if miles < veryCloseMiles { veryClose.append(j) }
            else if miles <= moderatelyCloseMiles { moderately.append(j) }
            else { far.append(j) }
        }
        return [
            Group(id: .veryClose, title: "Very close (<\(formatMiles(veryCloseMiles)) miles)", items: veryClose),
            Group(id: .moderatelyClose, title: "Moderately close (≤\(formatMiles(moderatelyCloseMiles)) miles)", items: moderately),
            Group(id: .far, title: "Far away (>\(formatMiles(moderatelyCloseMiles)) miles)", items: far)
        ]
    }

    private var groups: [Group] { grouped() }
    private func groupsEmpty(_ groups: [Group]) -> Bool { groups.allSatisfy { $0.items.isEmpty } }

    var body: some View { toolbarView }

    private var baseListView: AnyView {
        let snapshot = groups
        return AnyView(
            VStack(spacing: 0) {
                if isSearching {
                    searchBar
                }
                List { listContent(snapshot) }
                    .refreshable { await manualRefresh() }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
            }
        )
    }

    private var navigationView: some View {
        baseListView
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("My Journeys")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $cardDestination) { destination in
                cardDestinationView(destination)
            }
            .task { await notificationStore.refresh() }
    }

    private var lifecycleView: some View {
        navigationView
            .onAppear {
                refreshManualOrder()
                location.request(forceFresh: true)
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
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    location.request(forceFresh: true)
                }
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
            .alert(
                "Delete journey?",
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
        .alert(
            "Add to favourites?",
            isPresented: $showFavDialog,
            presenting: journeyPendingFav
        ) { j in
            Button("Add to favourites") {
                store.setFavorite(group: j, includeReturn: true, value: true)
            }
            Button("Cancel", role: .cancel) { }
        } message: { journey in
            Text("Add \(journey.displayTitle) to favourites?")
        }
        .sheet(item: $scheduleGroup) { group in
            NotificationScheduleView(group: group, reverseGroup: store.reverseGroup(for: group))
        }
    }

    private var toolbarView: AnyView {
        let view = alertsView
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    if !isSelecting && !isSearching {
                        Button {
                            openSearch()
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("Search journeys")
                    }
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
                Section {
                    distanceSectionLabel(group.title)
                    ForEach(group.items) { j in
                        journeyRow(j)
                    }
                }
            }
        }
    }

    private func distanceSectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.secondary)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
    }

    @ViewBuilder
    private var alphabeticalSection: some View {
        Section("My Journeys") {
            ForEach(alphabeticallySortedJourneys) { j in
                journeyRow(j)
            }
        }
    }

    @ViewBuilder
    private var manualSection: some View {
        Section("My Journeys") {
            ForEach(filteredManualJourneys) { j in
                journeyRow(j)
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

// Journey cards are shared in JourneyListRow.swift.

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
        guard location.lastKnownCoordinate != nil else { return groups }
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
        let candidateDistance = distanceMiles(from: location.lastKnownCoordinate, to: candidate.startStation)
        let existingDistance = distanceMiles(from: location.lastKnownCoordinate, to: existing.startStation)
        switch (candidateDistance, existingDistance) {
        case let (c?, e?): return c < e
        case (_?, nil): return true
        default: return false
        }
    }

    func manualRefresh() async {
        refreshManualOrder()
        location.request(forceFresh: true)
        depStore.refreshNow(journeyStore: store)
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
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
            Button("Close") {
                closeSearch()
            }
            .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    func openSearch() {
        guard !isSearching else {
            searchFocused = true
            return
        }
        isSearching = true
        Task { @MainActor in
            await Task.yield()
            searchFocused = true
        }
    }

    func closeSearch() {
        searchFocused = false
        isSearching = false
        searchText = ""
        debouncedSearchText = ""
    }


    private var multiDeleteNoun: String {
        selectedJourneyIds.count == 1 ? "journey" : "journeys"
    }

    private var multiDeleteTitle: String {
        "Delete selected \(multiDeleteNoun)?"
    }

    @ViewBuilder
    private func journeyRow(_ group: JourneyGroup) -> some View {
        if isSelecting {
            Button {
                toggleSelection(group)
            } label: {
                rowContent(for: group)
            }
            .buttonStyle(.plain)
        } else {
            rowContent(for: group)
            .simultaneousGesture(
                LongPressGesture(minimumDuration: longPressDuration, maximumDistance: longPressDistance)
                    .onEnded { _ in startSelection(with: group) }
            )
        }
    }

    private func rowContent(for group: JourneyGroup) -> some View {
        let reverseGroup = store.reverseGroup(for: group)
        let isReversed = reversedJourneyIDs.contains(group.id) && reverseGroup != nil
        let displayedGroup = isReversed ? (reverseGroup ?? group) : group

        return HStack(spacing: 12) {
            if isSelecting {
                selectionIndicator(for: group)
            }
            JourneyCard(
                group: displayedGroup,
                isFavourite: false,
                defaultDepartureCount: JourneyCardPresentation.defaultDepartureCount(
                    journeyCount: visibleJourneys.count
                ),
                isLiveActive: liveSession(for: displayedGroup) != nil,
                isScheduled: scheduledSubscription(for: displayedGroup) != nil,
                isBusy: liveActionGroupIDs.contains(displayedGroup.id),
                isInteractive: !isSelecting,
                isExpanded: expandedJourneyIDs.contains(group.id),
                canReverseJourney: reverseGroup != nil,
                isJourneyReversed: isReversed,
                onToggleExpanded: { toggleExpanded(group.id) },
                onToggleJourneyReversed: { toggleReversed(group.id) },
                onOpenDeparture: { leg, departure in
                    if displayedGroup.legs.count > 1 {
                        cardDestination = .itinerary(
                            group: displayedGroup,
                            firstDeparture: departure
                        )
                    } else {
                        cardDestination = .service(
                            serviceID: departure.serviceID,
                            fromCRS: leg.fromStation.crs,
                            toCRS: leg.toStation.crs,
                            departureTime: JourneyItineraryBuilder.departureDisplayTime(departure),
                            destinationName: leg.toStation.name
                        )
                    }
                },
                onToggleFavourite: {
                    journeyPendingFav = displayedGroup
                    showFavDialog = true
                },
                onToggleJourneyUpdates: { toggleJourneyUpdates(for: displayedGroup) },
                onScheduleJourneyUpdates: { scheduleGroup = displayedGroup },
                onRemoveJourney: {
                    journeyPendingDelete = displayedGroup
                    showDeleteDialog = true
                }
            )
        }
        .contentShape(Rectangle())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    private func toggleExpanded(_ groupID: UUID) {
        if expandedJourneyIDs.contains(groupID) {
            expandedJourneyIDs.remove(groupID)
        } else {
            expandedJourneyIDs.insert(groupID)
        }
    }

    private func toggleReversed(_ groupID: UUID) {
        if reversedJourneyIDs.contains(groupID) {
            reversedJourneyIDs.remove(groupID)
        } else {
            reversedJourneyIDs.insert(groupID)
        }
    }

    @ViewBuilder
    private func cardDestinationView(_ destination: JourneyCardNavigationDestination) -> some View {
        switch destination {
        case .service(let serviceID, let fromCRS, let toCRS, let departureTime, let destinationName):
            ServiceMapView(
                serviceID: serviceID,
                fromCRS: fromCRS,
                toCRS: toCRS,
                departureTime: departureTime,
                destinationName: destinationName
            )
                .onAppear { searchFocused = false }
        case .itinerary(let group, let firstDeparture):
            JourneyItineraryView(group: group, firstDeparture: firstDeparture)
                .onAppear { searchFocused = false }
        }
    }

    private func scheduledSubscription(for group: JourneyGroup) -> NotificationSubscription? {
        notificationStore.subscription(for: JourneyUpdateActions.scheduledRouteKey(for: group))
    }

    private func liveSession(for group: JourneyGroup) -> NotificationSubscription? {
        notificationStore.liveSession(for: JourneyUpdateActions.liveSessionRouteKey(for: group))
    }

    private func toggleJourneyUpdates(for group: JourneyGroup) {
        guard liveActionGroupIDs.insert(group.id).inserted else { return }
        Task {
            defer { liveActionGroupIDs.remove(group.id) }
            if let session = liveSession(for: group) {
                do {
                    try await JourneyUpdateActions.stop(
                        session: session,
                        notificationStore: notificationStore,
                        activityManager: activityMgr
                    )
                    ToastStore.shared.show("Journey updates stopped", icon: "stop.fill")
                } catch {
                    activityMgr.lastMessage = error.localizedDescription
                    ToastStore.shared.show("Unable to stop journey updates", icon: "exclamationmark.triangle.fill")
                }
            } else {
                _ = await JourneyUpdateActions.start(
                    group: group,
                    scheduledSubscription: scheduledSubscription(for: group),
                    liveSession: nil,
                    liveActivityDurationMinutes: liveActivityDurationMinutes,
                    notificationStore: notificationStore,
                    activityManager: activityMgr,
                    departuresStore: depStore
                )
            }
        }
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
