import SwiftUI

struct AddJourneyView: View {
    @State private var fromInput = StationInput()
    @State private var stopInputs: [StationInput] = [StationInput()]
    @State private var markAsFavorite: Bool = false
    @State private var options = AddJourneyOptions()
    @State private var scrollTarget: UUID? = nil
    @State private var scheduleDestination: NotificationScheduleDestination?
    @State private var postScheduleTab: Tab?
    @State private var isSaving = false
    @State private var isStartingOneOff = false

    @EnvironmentObject var router: TabRouter
    @EnvironmentObject var depStore: DeparturesStore
    @EnvironmentObject var activityMgr: LiveActivityManager
    @EnvironmentObject var notificationStore: NotificationSubscriptionStore

    @AppStorage("liveActivityDurationMinutes") private var liveActivityDurationMinutes: Int = 60

    @FocusState private var focusedField: Field?

    enum Field: Hashable { case from, stop(UUID) }

    private let maxLegs = 5
    private var maxStops: Int { maxLegs }

    // Try to resolve from user input if a suggestion hasn't been tapped
    private var resolvedFrom: Station? { resolveInput(fromInput) }
    private var resolvedStops: [Station?] { stopInputs.map(resolveInput) }
    private var resolvedStations: [Station]? {
        guard let from = resolvedFrom else { return nil }
        let stops = resolvedStops
        guard !stops.contains(where: { $0 == nil }) else { return nil }
        let stopStations = stops.compactMap { $0 }
        guard !stopStations.isEmpty else { return nil }
        return [from] + stopStations
    }

    private var canSubmit: Bool {
        guard let stations = resolvedStations, !isSaving, !isStartingOneOff else { return false }
        return options.oneOff || !JourneyStore.shared.groupExists(for: stations)
    }

    private var journeyExists: Bool {
        guard let stations = resolvedStations else { return false }
        return JourneyStore.shared.groupExists(for: stations)
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                stationSection(title: "From", input: $fromInput, focus: .from, nextFocus: nextFocusAfterFrom)
                    .id(fromInput.id)

                ForEach(stopInputs) { input in
                    stationSection(
                        title: stopTitle(for: input.id),
                        input: binding(for: input.id),
                        focus: .stop(input.id),
                        nextFocus: nextFocusAfterStop(id: input.id),
                        allowRemove: stopInputs.count > 1,
                        onRemove: { removeStop(id: input.id) }
                    )
                    .id(input.id)
                }

                if stopInputs.count < maxStops {
                    Section {
                        Button {
                            addStop(.intermediate)
                        } label: {
                            Label("Add intermediate stop", systemImage: "plus.circle")
                        }

                        Button {
                            addStop(.destination)
                        } label: {
                            Label("Extend journey", systemImage: "arrow.right.circle")
                        }
                    } footer: {
                        Text("Intermediate stops are inserted before your destination.")
                    }
                }

                if journeyExists && !options.oneOff && !isSaving {
                    Section {
                        Label("This journey already exists", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    Toggle("Start journey now", isOn: Binding(
                        get: { options.startNow },
                        set: { options.setStartNow($0) }
                    ))

                    Toggle("Don't save, this is a one-off", isOn: Binding(
                        get: { options.oneOff },
                        set: { isOn in
                            options.setOneOff(isOn)
                            if isOn {
                                markAsFavorite = false
                            }
                        }
                    ))
                    .disabled(!options.canSelectOneOff)

                    Toggle("Schedule journey", isOn: Binding(
                        get: { options.schedule },
                        set: { options.setSchedule($0) }
                    ))
                    .disabled(options.oneOff)

                    Toggle("Mark as favourite", isOn: $markAsFavorite)
                        .disabled(options.oneOff)
                } header: {
                    RailwayBackgroundSectionHeader(title: "Options")
                }

                Section {
                    Button {
                        save()
                    } label: {
                        if isSaving || isStartingOneOff {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label(
                                options.oneOff ? "Start one-off journey" : "Save",
                                systemImage: options.oneOff ? "play.fill" : "tray.and.arrow.down"
                            )
                        }
                    }
                    .disabled(!canSubmit)
                }
            }
            .scrollContentBackground(.hidden)
            .onAppear {
                loadStations()
                if router.addJourneyPrefillFavourite {
                    markAsFavorite = true
                    router.addJourneyPrefillFavourite = false
                }
                updateFocus(for: router.selected)
            }
            .onChange(of: scrollTarget) { _, target in
                guard let target else { return }
                let exists = target == fromInput.id || stopInputs.contains(where: { $0.id == target })
                guard exists else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .navigationTitle("Add Journey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { cancel() }
                    .disabled(isSaving || isStartingOneOff)
            }
        }
        .sheet(item: $scheduleDestination, onDismiss: finishScheduling) { destination in
            NotificationScheduleView(
                group: destination.group,
                reverseGroup: destination.reverseGroup,
                existingSubscription: destination.existingSubscription
            )
        }
        .railwayBackgroundPOC()
        .onChange(of: router.selected) { _, selectedTab in
            updateFocus(for: selectedTab)
        }
        .onDisappear {
            // Ensure any pending focus/scroll updates are cleared before leaving.
            clearFocus()
        }
    }

    private func updateFocus(for selectedTab: Tab) {
        guard selectedTab == .addJourney else {
            clearFocus()
            return
        }

        DispatchQueue.main.async {
            guard router.selected == .addJourney else { return }
            focusedField = .from
            scrollTarget = fromInput.id
        }
    }

    private func clearFocus() {
        scrollTarget = nil
        focusedField = nil
    }

    private func loadStations() {
        Task { try? await StationsService.shared.loadStations() }
    }

    private func save() {
        guard let stations = resolvedStations, !isSaving, !isStartingOneOff else { return }

        if options.oneOff {
            startOneOffJourney(stations: stations)
            return
        }

        isSaving = true
        let favorite = markAsFavorite
        let targetTab: Tab = favorite ? .favourites : .myJourneys
        JourneyStore.shared.addJourneyGroup(
            stations: stations,
            favorite: favorite,
            saveReturn: true
        )

        guard let group = savedGroup(for: stations) else {
            isSaving = false
            return
        }

        if options.startNow {
            startJourneyUpdates(for: group)
        }

        if options.schedule {
            postScheduleTab = targetTab
            scheduleDestination = NotificationScheduleDestination(
                group: group,
                reverseGroup: JourneyStore.shared.reverseGroup(for: group),
                existingSubscription: nil
            )
        } else {
            leaveAddJourney(for: targetTab)
        }
    }

    private func startOneOffJourney(stations: [Station]) {
        guard let group = transientGroup(for: stations) else { return }
        isStartingOneOff = true
        Task {
            let started = await JourneyUpdateActions.start(
                group: group,
                scheduledSubscription: nil,
                liveSession: nil,
                liveActivityDurationMinutes: liveActivityDurationMinutes,
                notificationStore: notificationStore,
                activityManager: activityMgr,
                departuresStore: depStore
            )
            isStartingOneOff = false
            if started {
                leaveAddJourney(for: .inProgress)
            }
        }
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

    private func savedGroup(for stations: [Station]) -> JourneyGroup? {
        let stationCodes = stations.map { $0.crs.uppercased() }
        return JourneyStore.shared.journeyGroups().first { group in
            group.stationSequence.map { $0.crs.uppercased() } == stationCodes
        }
    }

    private func transientGroup(for stations: [Station]) -> JourneyGroup? {
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
                favorite: false
            )
        }
        return JourneyGroup(id: groupID, legs: legs)
    }

    private func finishScheduling() {
        guard let targetTab = postScheduleTab else { return }
        postScheduleTab = nil
        leaveAddJourney(for: targetTab)
    }

    private func cancel() {
        leaveAddJourney(for: router.lastNonAddTab)
    }

    private func leaveAddJourney(
        for targetTab: Tab,
        afterTransition: (() -> Void)? = nil
    ) {
        clearFocus()

        // Dismissing the standalone cover also reveals the requested destination.
        DispatchQueue.main.async {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                router.selected = targetTab
            }
            afterTransition?()
        }
    }

    private func resolveInput(_ input: StationInput) -> Station? {
        if let s = input.selected { return s }
        return resolveQueryToStation(input.query)
    }

    private func resolveQueryToStation(_ query: String) -> Station? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let all = StationsService.shared.stations
        if all.isEmpty { return nil }
        // Try CRS exact match first
        if let exactCRS = all.first(where: { $0.crs.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exactCRS
        }
        // Try exact name match
        if let exactName = all.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return exactName
        }
        // Fallback to first search result
        return StationsService.shared.search(trimmed).first
    }

    private func addStop(_ placement: JourneyStopPlacement) {
        guard stopInputs.count < maxStops else { return }
        let input = StationInput()
        stopInputs.insert(
            input,
            at: placement.insertionIndex(existingStopCount: stopInputs.count)
        )
        focusedField = .stop(input.id)
        scrollTarget = input.id
    }

    private func binding(for id: UUID) -> Binding<StationInput> {
        Binding(
            get: { stopInputs.first(where: { $0.id == id }) ?? StationInput(id: id) },
            set: { newValue in
                guard let index = stopInputs.firstIndex(where: { $0.id == id }) else { return }
                stopInputs[index] = newValue
            }
        )
    }

    private func removeStop(id: UUID) {
        guard let index = stopInputs.firstIndex(where: { $0.id == id }) else { return }
        let removed = stopInputs.remove(at: index)
        if focusedField == .stop(removed.id) {
            if stopInputs.indices.contains(index) {
                focusedField = .stop(stopInputs[index].id)
            } else if let last = stopInputs.last {
                focusedField = .stop(last.id)
            } else {
                focusedField = .from
            }
        }
        if scrollTarget == removed.id {
            scrollTarget = nil
        }
    }

    private var nextFocusAfterFrom: Field? {
        if let destination = stopInputs.last { return .stop(destination.id) }
        return nil
    }

    private func nextFocusAfterStop(id: UUID) -> Field? {
        guard let index = stopInputs.firstIndex(where: { $0.id == id }) else { return nil }
        let nextIndex = index + 1
        if stopInputs.indices.contains(nextIndex) {
            return .stop(stopInputs[nextIndex].id)
        }
        return nil
    }

    private func stopTitle(for id: UUID) -> String {
        guard let index = stopInputs.firstIndex(where: { $0.id == id }) else { return "Destination" }
        if index == stopInputs.count - 1 { return "Destination" }
        return "Intermediate stop \(index + 1)"
    }

    @ViewBuilder
    private func stationSection(
        title: String,
        input: Binding<StationInput>,
        focus: Field,
        nextFocus: Field?,
        allowRemove: Bool = false,
        onRemove: (() -> Void)? = nil
    ) -> some View {
        Section {
            TextField("Search station", text: input.query)
                .accessibilityIdentifier(stationFieldAccessibilityIdentifier(for: focus))
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textContentType(.none)
                .focused($focusedField, equals: focus)
                .onChange(of: input.wrappedValue.query) {
                    input.wrappedValue.selected = nil
                }
            if let s = input.wrappedValue.selected {
                SelectedStationRow(station: s) {
                    input.wrappedValue.selected = nil
                    input.wrappedValue.query = ""
                    focusedField = focus
                }
            } else {
                StationSuggestions(query: input.wrappedValue.query) { station in
                    input.wrappedValue.selected = station
                    input.wrappedValue.query = station.name
                    focusedField = nextFocus
                    if case let .stop(id) = nextFocus,
                       stopInputs.contains(where: { $0.id == id }) {
                        scrollTarget = id
                    }
                }
            }
            if allowRemove, let onRemove {
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Label("Remove stop", systemImage: "minus.circle")
                }
            }
        } header: {
            RailwayBackgroundSectionHeader(title: title)
        }
    }

    private func stationFieldAccessibilityIdentifier(for field: Field) -> String {
        switch field {
        case .from:
            return "add-journey.from"
        case .stop(let id):
            return id == stopInputs.last?.id ? "add-journey.destination" : "add-journey.stop.\(id)"
        }
    }
}

enum JourneyStopPlacement {
    case intermediate
    case destination

    func insertionIndex(existingStopCount: Int) -> Int {
        switch self {
        case .intermediate:
            return max(existingStopCount - 1, 0)
        case .destination:
            return existingStopCount
        }
    }
}

struct AddJourneyOptions: Equatable {
    private(set) var startNow = false
    private(set) var schedule = false
    private(set) var oneOff = false

    var canSelectOneOff: Bool { startNow }

    mutating func setStartNow(_ isOn: Bool) {
        startNow = isOn
        if !isOn {
            oneOff = false
        }
    }

    mutating func setSchedule(_ isOn: Bool) {
        guard !oneOff else { return }
        schedule = isOn
    }

    mutating func setOneOff(_ isOn: Bool) {
        oneOff = isOn && startNow
        if oneOff {
            schedule = false
        }
    }
}

private struct StationInput: Identifiable {
    let id: UUID
    var query: String
    var selected: Station?

    init(id: UUID = UUID(), query: String = "", selected: Station? = nil) {
        self.id = id
        self.query = query
        self.selected = selected
    }
}

private struct StationSuggestions: View {
    let query: String
    var onSelect: (Station) -> Void

    var matches: [Station] {
        let results = StationsService.shared.search(query)
        var seen = Set<String>()
        return results.filter { station in
            let key = station.crs.uppercased()
            return seen.insert(key).inserted
        }
    }

    var body: some View {
        if !query.isEmpty {
            if matches.isEmpty {
                Text("No matching stations")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matches) { station in
                    Button {
                        onSelect(station)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(station.name)
                                    .foregroundStyle(.primary)
                                Text(station.crs)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }
}

private struct SelectedStationRow: View {
    let station: Station
    var onClear: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(station.name).font(.body)
                Text(station.crs).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onClear) {
                Label("Clear", systemImage: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
        }
    }
}

#Preview {
    NavigationStack { AddJourneyView() }
}
