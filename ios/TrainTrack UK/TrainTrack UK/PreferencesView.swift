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
    @AppStorage("muteDelayMinutes") private var muteDelayMinutes: Int = 5
    @AppStorage("autoEndLiveActivity") private var autoEndLiveActivity: Bool = false
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

            #if DEBUG
            Section("API Host (Testing)") {
                Picker("API Host", selection: apiHostBinding) {
                    ForEach(ApiHost.allCases) { host in
                        Text(host.displayName).tag(host)
                    }
                }
                Text("Switch between production (\(ApiHost.prod.hostDescription)) and dev (\(ApiHost.dev.hostDescription)) for API calls. Intended for local testing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            #endif

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

            Section("Notification Preferences") {
                Toggle(NotificationType.summary.displayName, isOn: notificationTypeBinding(.summary))
                Toggle(NotificationType.delays.displayName, isOn: notificationTypeBinding(.delays))
                Toggle(NotificationType.platform.displayName, isOn: notificationTypeBinding(.platform))
                Text("Pick at least one type. Service status summary at start time only applies to scheduled notifications, not ad hoc live-session ones.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let notificationPreferencesError {
                    Text(notificationPreferencesError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Live Activities") {
                Text("Use the Start button at the top of a journey to begin a Live Activity and matching notifications manually.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Mute notifications on arrival", isOn: $autoMuteOnArrival)
                Text("When you arrive at a departure station, notifications for that journey are paused for the rest of the day. Requires 'Always' location permission.")
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
                    Toggle("End Live Activity on arrival", isOn: $autoEndLiveActivity)
                    Text("When notifications are muted, automatically dismiss the Live Activity widget from your lock screen and home screen.")
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
                Text("How long a Live Activity stays visible. Default is 1 hour.")
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

            Section("Scheduled Notifications") {
                if notificationStore.isLoading {
                    ProgressView("Loading…")
                } else if notificationStore.subscriptions.isEmpty {
                    Text("No scheduled notifications yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(notificationStore.subscriptions) { sub in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(sub.routeTitle)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("\(sub.daysLabel) • \(sub.windowLabel)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                notificationPendingDelete = sub
                                showNotificationDeleteDialog = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                Text("Notification types above apply to all schedules. You can schedule notifications for up to 3 journeys.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            Section("Debug") {
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
            if autoMuteOnArrival {
                NotificationGeofenceManager.shared.requestAlwaysAuthorizationIfNeeded()
            }
        }
        .onChange(of: autoMuteOnArrival) { newValue in
            if newValue {
                NotificationGeofenceManager.shared.requestAlwaysAuthorizationIfNeeded()
            }
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
