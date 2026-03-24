import SwiftUI

enum JourneySortMode: String, CaseIterable, Identifiable {
    case distance = "distance"
    case alphabetical = "alphabetical"
    case manual = "manual"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .distance: return "Distance (closest first)"
        case .alphabetical: return "Alphabetical"
        case .manual: return "Manual"
        }
    }
}

struct PreferencesView: View {
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4
    @AppStorage("distanceVeryCloseMiles") private var veryCloseMiles: Double = 3
    @AppStorage("distanceModeratelyCloseMiles") private var moderatelyCloseMiles: Double = 5
    @AppStorage("liveActivityDurationMinutes") private var liveActivityDurationMinutes: Int = 60
    @AppStorage("journeySortMode") private var journeySortModeRaw: String = JourneySortMode.distance.rawValue
    @AppStorage(ApiHostPreference.storageKey, store: ApiHostPreference.store) private var apiHostRaw: String = ApiHost.prod.rawValue
    @AppStorage("autoReturnToFavouritesMinutes") private var autoReturnMinutes: Int = 0
    @AppStorage("autoMuteOnArrival") private var autoMuteOnArrival: Bool = true
    @AppStorage("muteDelayMinutes") private var muteDelayMinutes: Int = 3
    @AppStorage("autoEndLiveActivity") private var autoEndLiveActivity: Bool = true
    @AppStorage("showClosestJourneyLegOnly") private var showClosestJourneyLegOnly: Bool = true
    @AppStorage("showTransferWarnings") private var showTransferWarnings: Bool = true
    @AppStorage("transferWarningThresholdMinutes") private var transferWarningThresholdMinutes: Int = 3
    @AppStorage(NotificationPreferences.summaryKey, store: NotificationPreferences.store) private var notifySummary: Bool = true
    @AppStorage(NotificationPreferences.delaysKey, store: NotificationPreferences.store) private var notifyDelays: Bool = true
    @AppStorage(NotificationPreferences.platformKey, store: NotificationPreferences.store) private var notifyPlatform: Bool = true
    @EnvironmentObject var notificationStore: NotificationSubscriptionStore
    @State private var notificationPendingDelete: NotificationSubscription? = nil
    @State private var showNotificationDeleteDialog = false
    @State private var showDebugLogs = false
    @State private var notificationPreferencesError: String? = nil
    @State private var notificationPreferencesSyncTask: Task<Void, Never>? = nil
    @State private var pendingDeleteUpdate: NotificationSubscription? = nil
    @State private var showUpdateDeleteDialog = false
    @State private var viewingScheduledRoute: IdentifiableScheduledRoute? = nil
    @State private var viewingLiveSession: NotificationSubscription? = nil

    private var journeySortMode: Binding<JourneySortMode> {
        Binding(
            get: { JourneySortMode(rawValue: journeySortModeRaw) ?? .distance },
            set: { journeySortModeRaw = $0.rawValue }
        )
    }

    private var apiHostBinding: Binding<ApiHost> {
        Binding(
            get: { ApiHost(rawValue: apiHostRaw) ?? .prod },
            set: { apiHostRaw = $0.rawValue }
        )
    }

    private var selectedNotificationTypeCount: Int {
        [notifySummary, notifyDelays, notifyPlatform].filter { $0 }.count
    }

    private var notificationPreferencesSignature: String {
        "\(notifySummary)-\(notifyDelays)-\(notifyPlatform)"
    }

    var body: some View {
        Form {

            Section("Journey Updates") {
                ForEach(journeyUpdateItems) { item in
                    journeyUpdateRow(for: item)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteUpdate = item.subscription
                                showUpdateDeleteDialog = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }

            Section {
                Text("Use the Start button at the top of a journey to begin a Live Activity and journey update notifications.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Mute notifications on arrival", isOn: $autoMuteOnArrival)
                Text("When you arrive at a departure station, the notifications for that journey are automatically stopped. Requires 'Always' location permission.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if autoMuteOnArrival {
                    Stepper(value: $muteDelayMinutes, in: 1...10) {
                        HStack {
                            Text("Mute after")
                            Spacer()
                            Text("\(muteDelayMinutes) min\(muteDelayMinutes == 1 ? "" : "s") at station")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("End Live Activity on departure", isOn: $autoEndLiveActivity)
                    Text("Automatically dismiss the Live Activity widget after you leave the departure station area and your journey is underway.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Picker("Live Activity duration", selection: $liveActivityDurationMinutes) {
                    Text("30 min").tag(30)
                    Text("1 hr").tag(60)
                    Text("90 min").tag(90)
                    Text("2 hr").tag(120)
                }
                .pickerStyle(.segmented)
                Text("How long a Live Activity stays visible (unless dismissed manually or after leaving a departure station). Default is 1 hour.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Notification Preferences") {
                Toggle(NotificationType.summary.displayName, isOn: notificationTypeBinding(.summary))
                Toggle(NotificationType.delays.displayName, isOn: notificationTypeBinding(.delays))
                Toggle(NotificationType.platform.displayName, isOn: notificationTypeBinding(.platform))
                Text("Pick at least one type. Service status summary at start time only applies to scheduled notifications.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let notificationPreferencesError {
                    Text(notificationPreferencesError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Scheduled Notifications") {
                if notificationStore.isLoading {
                    ProgressView("Loading…")
                } else if notificationStore.subscriptions.isEmpty {
                    Text("No scheduled notifications yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(notificationStore.subscriptions) { sub in
                        if let schedule = resolvedScheduledRoute(for: sub) {
                            NavigationLink {
                                NotificationScheduleView(
                                    group: schedule.group,
                                    reverseGroup: schedule.reverseGroup
                                )
                                .environmentObject(notificationStore)
                            } label: {
                                scheduledNotificationRow(for: sub)
                            }
                        } else {
                            scheduledNotificationRow(for: sub)
                        }
                    }
                    .onDelete(perform: deleteScheduledNotifications)
                }
                Text("Notification types above apply to all schedules. You can schedule notifications for up to 3 journeys.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Journey Sorting") {
                Picker("Sort journeys by", selection: journeySortMode) {
                    ForEach(JourneySortMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Text("Choose how journeys are sorted in Favourites and My Journeys lists.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if journeySortMode.wrappedValue == .distance {
                Section("Distance Grouping") {
                    Stepper(value: $veryCloseMiles, in: 0.5...20, step: 0.5) {
                        HStack {
                            Text("Very close threshold")
                            Spacer()
                            Text("\(formatMiles(veryCloseMiles)) mile\(veryCloseMiles == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Stepper(value: $moderatelyCloseMiles, in: 1...50, step: 0.5) {
                        HStack {
                            Text("Moderately close threshold")
                            Spacer()
                            Text("\(formatMiles(moderatelyCloseMiles)) miles")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Used to group journeys by proximity to your current location in the lists. Defaults are 3 and 10 miles.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Journey Pairs") {
                Toggle("Only show closest leg", isOn: $showClosestJourneyLegOnly)
                Text("When enabled, only the journey leg whose start station is closest to you appears in lists. Use Reverse journey in the details view to see the return leg.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Journey Summary") {
                Toggle("Warn on tight changes", isOn: $showTransferWarnings)
                if showTransferWarnings {
                    Stepper(value: $transferWarningThresholdMinutes, in: 1...15) {
                        HStack {
                            Text("Warn if change is under")
                            Spacer()
                            Text("\(transferWarningThresholdMinutes) min")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Shows a warning icon in the journey summary when your change time is below the chosen threshold.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Warnings") {
                Stepper(value: $minShortTrainCars, in: 1...12) {
                    HStack {
                        Text("Highlight trains with")
                        Spacer()
                        Text("\(minShortTrainCars) car\(minShortTrainCars == 1 ? "" : "s") or fewer")
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Shows a warning icon next to train length when the train has the configured number of carriages or fewer. Default is 4.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Auto-Return to Favourites") {
                Picker("Return after inactivity", selection: $autoReturnMinutes) {
                    Text("Off").tag(0)
                    Text("30 min").tag(30)
                    Text("1 hr").tag(60)
                    Text("90 min").tag(90)
                    Text("2 hr").tag(120)
                }
                .pickerStyle(.menu)
                Text("Automatically navigate back to the Favourites screen after the app has been in the background for the selected duration. Disabled by default.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            Section("Debug") {
                Picker("API Host", selection: apiHostBinding) {
                    ForEach(ApiHost.allCases) { host in
                        Text(host.displayName).tag(host)
                    }
                }
                Text("Switch between production (\(ApiHost.prod.hostDescription)) and dev (\(ApiHost.dev.hostDescription)) for API calls. Intended for local testing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("View Debug Logs") {
                    showDebugLogs = true
                }
            }
            #endif
        }
        .navigationTitle("Preferences")
        .task {
            await notificationStore.refresh()
            try? await StationsService.shared.loadStations()
        }
        .onChange(of: veryCloseMiles) { newValue in
            // Keep thresholds sensible: moderately >= veryClose
            if moderatelyCloseMiles < newValue { moderatelyCloseMiles = newValue }
        }
        .onChange(of: moderatelyCloseMiles) { newValue in
            if newValue < veryCloseMiles { veryCloseMiles = newValue }
        }
        .onChange(of: notificationPreferencesSignature) { _ in
            syncNotificationPreferences()
        }
        .confirmationDialog(
            "Delete schedule?",
            isPresented: $showNotificationDeleteDialog,
            presenting: notificationPendingDelete
        ) { sub in
            Button("Delete schedule", role: .destructive) {
                Task {
                    try? await notificationStore.delete(id: sub.id)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This will remove the scheduled notifications for this journey.")
        }
        .sheet(isPresented: $showDebugLogs) {
            DebugLogView()
        }
        .confirmationDialog(
            "Delete journey update?",
            isPresented: $showUpdateDeleteDialog,
            presenting: pendingDeleteUpdate
        ) { sub in
            Button("Delete", role: .destructive) {
                deleteUpdate(sub)
            }
            Button("Cancel", role: .cancel) { }
        } message: { sub in
            Text(isScheduled(sub)
                ? "This will remove the scheduled notifications for this journey."
                : "This will stop live journey update notifications.")
        }
        .sheet(item: $viewingScheduledRoute) { route in
            NotificationScheduleView(group: route.group, reverseGroup: route.reverseGroup)
                .environmentObject(notificationStore)
        }
        .sheet(item: $viewingLiveSession) { session in
            LiveSessionInfoSheet(session: session)
        }
    }

    private func notificationTypeBinding(_ type: NotificationType) -> Binding<Bool> {
        Binding(
            get: { notificationTypeValue(type) },
            set: { newValue in
                let wasEnabled = notificationTypeValue(type)
                if wasEnabled && !newValue && selectedNotificationTypeCount == 1 {
                    return
                }
                setNotificationTypeValue(newValue, for: type)
            }
        )
    }

    private func notificationTypeValue(_ type: NotificationType) -> Bool {
        switch type {
        case .summary:
            return notifySummary
        case .delays:
            return notifyDelays
        case .platform:
            return notifyPlatform
        }
    }

    private func setNotificationTypeValue(_ value: Bool, for type: NotificationType) {
        switch type {
        case .summary:
            notifySummary = value
        case .delays:
            notifyDelays = value
        case .platform:
            notifyPlatform = value
        }
    }

    private func syncNotificationPreferences() {
        notificationPreferencesSyncTask?.cancel()
        notificationPreferencesSyncTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                try await notificationStore.applyGlobalNotificationTypes()
                notificationPreferencesError = nil
            } catch {
                guard !Task.isCancelled else { return }
                notificationPreferencesError = error.localizedDescription
            }
        }
    }

    private func deleteScheduledNotifications(at offsets: IndexSet) {
        guard let index = offsets.first,
              notificationStore.subscriptions.indices.contains(index) else { return }
        notificationPendingDelete = notificationStore.subscriptions[index]
        showNotificationDeleteDialog = true
    }

    @ViewBuilder
    private func journeyUpdateRow(for item: JourneyLegItem) -> some View {
        let sub = item.subscription
        let leg = item.leg
        let scheduled = isScheduled(sub)
        let fromName = leg.fromName ?? leg.from
        let toName = leg.toName ?? leg.to
        let active = isActive(sub)
        Button {
            if scheduled, let route = resolvedScheduledRoute(for: sub) {
                viewingScheduledRoute = IdentifiableScheduledRoute(group: route.group, reverseGroup: route.reverseGroup)
            } else if !scheduled {
                viewingLiveSession = sub
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(scheduled ? "Scheduled" : "Adhoc")
                            .font(.caption)
                            .foregroundStyle(scheduled ? .blue : .orange)
                        if leg.enabled {
                            Text("• \(leg.windowStart)–\(leg.windowEnd)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if active {
                            Text("Active")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(fromName) → \(toName)")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var journeyUpdateItems: [JourneyLegItem] {
        notificationStore.combinedSubscriptions.flatMap { sub in
            sub.legs.map { leg in JourneyLegItem(subscription: sub, leg: leg) }
        }
    }

    private func isScheduled(_ sub: NotificationSubscription) -> Bool {
        notificationStore.subscriptions.contains(where: { $0.id == sub.id })
    }

    private func isActive(_ sub: NotificationSubscription) -> Bool {
        // Scheduled subscriptions fire on a timetable — never "Active" in the real-time sense
        guard !isScheduled(sub) else { return false }
        guard let activeUntil = sub.activeUntil else { return true }
        return activeUntil > Date()
    }

    private func deleteUpdate(_ sub: NotificationSubscription) {
        Task {
            if isScheduled(sub) {
                try? await notificationStore.delete(id: sub.id)
            } else {
                try? await notificationStore.deleteLiveSession(id: sub.id)
            }
        }
    }

    private func scheduledNotificationRow(for sub: NotificationSubscription) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scheduledNotificationTitle(for: sub))
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("\(sub.daysLabel) • \(sub.windowLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scheduledNotificationTitle(for subscription: NotificationSubscription) -> String {
        if let splitIndex = returnSplitIndex(for: subscription) {
            let outbound = Array(subscription.legs.prefix(splitIndex))
            guard let first = outbound.first, let last = outbound.last else {
                return subscription.routeTitle
            }
            let from = first.fromName ?? first.from
            let to = last.toName ?? last.to
            return "\(from) → \(to) (and return)"
        }
        return subscription.routeTitle
    }

    private func resolvedScheduledRoute(for subscription: NotificationSubscription) -> ResolvedScheduledRoute? {
        guard !subscription.legs.isEmpty else { return nil }
        if let splitIndex = returnSplitIndex(for: subscription) {
            let outbound = Array(subscription.legs.prefix(splitIndex))
            let inbound = Array(subscription.legs.dropFirst(splitIndex))
            return ResolvedScheduledRoute(
                group: makeJourneyGroup(from: outbound),
                reverseGroup: makeJourneyGroup(from: inbound)
            )
        }

        return ResolvedScheduledRoute(
            group: makeJourneyGroup(from: subscription.legs),
            reverseGroup: nil
        )
    }

    private func returnSplitIndex(for subscription: NotificationSubscription) -> Int? {
        guard subscription.legs.count >= 2 else { return nil }

        for splitIndex in 1..<subscription.legs.count {
            let outbound = Array(subscription.legs.prefix(splitIndex))
            let inbound = Array(subscription.legs.dropFirst(splitIndex))
            if stationSequence(for: inbound) == stationSequence(for: outbound).reversed() {
                return splitIndex
            }
        }

        return nil
    }

    private func stationSequence(for legs: [NotificationLeg]) -> [String] {
        guard let first = legs.first else { return [] }
        return [first.from.uppercased()] + legs.map { $0.to.uppercased() }
    }

    private func makeJourneyGroup(from legs: [NotificationLeg]) -> JourneyGroup {
        let groupId = UUID()
        let journeys = legs.enumerated().map { index, leg in
            Journey(
                id: UUID(),
                groupId: groupId,
                legIndex: index,
                fromStation: station(from: leg.from, name: leg.fromName),
                toStation: station(from: leg.to, name: leg.toName),
                createdAt: Date(),
                favorite: false
            )
        }
        return JourneyGroup(id: groupId, legs: journeys)
    }

    private func station(from crs: String, name: String?) -> Station {
        if let actual = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(crs) == .orderedSame }) {
            return actual
        }
        return Station(
            crs: crs.uppercased(),
            name: name ?? crs.uppercased(),
            longitude: "0",
            latitude: "0"
        )
    }
}

private struct ResolvedScheduledRoute {
    let group: JourneyGroup
    let reverseGroup: JourneyGroup?
}

private struct JourneyLegItem: Identifiable {
    let id: String
    let subscription: NotificationSubscription
    let leg: NotificationLeg

    init(subscription: NotificationSubscription, leg: NotificationLeg) {
        self.id = "\(subscription.id)-\(leg.from)-\(leg.to)"
        self.subscription = subscription
        self.leg = leg
    }
}

private struct IdentifiableScheduledRoute: Identifiable {
    let id = UUID()
    let group: JourneyGroup
    let reverseGroup: JourneyGroup?
}

private struct LiveSessionInfoSheet: View {
    let session: NotificationSubscription
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Journey") {
                    let from = session.legs.first?.fromName ?? session.legs.first?.from ?? "Unknown"
                    let to = session.legs.last?.toName ?? session.legs.last?.to ?? "Unknown"
                    LabeledContent("From", value: from)
                    LabeledContent("To", value: to)
                    if session.legs.count > 1 {
                        LabeledContent("Legs", value: "\(session.legs.count)")
                    }
                }
                Section("Status") {
                    if let activeUntil = session.activeUntil {
                        let active = activeUntil > Date()
                        LabeledContent("Active", value: active ? "Yes" : "No (expired)")
                        LabeledContent("Active until", value: activeUntil.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        LabeledContent("Active", value: "Yes")
                    }
                }
            }
            .navigationTitle("Adhoc Journey Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PreferencesView()
            .environmentObject(NotificationSubscriptionStore.shared)
    }
}

private func formatMiles(_ v: Double) -> String {
    if v.rounded() == v { return String(Int(v)) }
    return String(format: "%.1f", v)
}
