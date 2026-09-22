import SwiftUI

struct DisruptionMonitoringRow: View {
    let group: JourneyGroup
    @State private var store = DisruptionMonitoringStore.shared

    var body: some View {
        // Routine check status stays in the journey menu; the card only shows a found disruption.
        let warnings = store.advisories(for: group)
        if !warnings.isEmpty {
            Button {
                store.presentedGroup = group
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.summary(for: group))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let first = warnings.first {
                            Text(first.nextAffectedPeriod()?.startAt ?? first.startAt,
                                 format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .environment(\.timeZone, PlannerTime.displayZone)
            .accessibilityHint("Shows upcoming disruptions and monitoring settings for this direction.")
            .accessibilityIdentifier("disruptions.row.\(group.stationSequence.map(\.crs).joined(separator: "-"))")
        }
    }
}

@MainActor
struct DisruptionMonitoringView: View {
    let group: JourneyGroup
    @State private var store: DisruptionMonitoringStore
    @State private var settings: DisruptionMonitorSettings
    @State private var requestingPush = false
    @State private var permissionMessage: String?
    @Environment(\.dismiss) private var dismiss

    init(group: JourneyGroup, store: DisruptionMonitoringStore? = nil) {
        let store = store ?? .shared
        self.group = group
        _store = State(initialValue: store)
        _settings = State(initialValue: store.settings(for: group))
    }

    private var validWindows: Bool {
        !settings.days.isEmpty && settings.days.allSatisfy { day in
            let window = settings.window(on: day)
            return window.start != window.end
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(group.displayTitle).font(.headline)
                    Text(store.summary(for: group)).fixedSize(horizontal: false, vertical: true)
                    if let explanation = store.status(for: group)?.explanation {
                        Text(explanation).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let lastChecked = store.status(for: group)?.lastCheckedAt {
                        LabeledContent("Last checked") {
                            Text(lastChecked, format: .dateTime.day().month(.abbreviated).hour().minute())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    if let error = store.lastError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                    if store.isSuspended {
                        Text("Your server data was deleted. Advance checks remain paused for this installation.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Upcoming disruptions")
                } footer: {
                    Text("We check the next seven days when capacity is available, including while the app is closed. Published engineering notices may give earlier warning. Timetables can change; an incomplete or old check cannot confirm that your route is clear.")
                }

                ForEach(store.advisories(for: group)) { advisory in
                    Section {
                        Label(advisory.title, systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                        Text(advisory.body)
                        DisruptionAffectedPeriodsView(periods: advisory.affectedPeriods)
                        Text(advisory.confidence == "confirmed" ? "Confirmed published notice" : "Based on the currently published timetable")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Checked \(advisory.checkedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let url = advisory.safeSourceURL {
                            Link("Read the published notice", destination: url)
                        }
                        if JourneyPlannerFeature.isEnabled {
                            NavigationLink("Find alternative journeys") {
                                DisruptionAlternativesView(group: group,
                                    travelDate: advisory.nextAffectedPeriod()?.startAt ?? advisory.startAt)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Monitor this direction", isOn: $settings.enabled)
                    Toggle("Push notifications", isOn: Binding(
                        get: { settings.pushEnabled },
                        set: { enabled in
                            if !enabled { settings.pushEnabled = false; return }
                            requestingPush = true
                            Task {
                                let authorized = await NotificationAuthorizationManager.ensureAuthorized()
                                settings.pushEnabled = authorized
                                permissionMessage = authorized ? nil : "Notifications are off in iOS Settings. In-app warnings remain available."
                                requestingPush = false
                            }
                        }
                    ))
                    .disabled(!settings.enabled || requestingPush)
                    if let permissionMessage {
                        Text(permissionMessage).font(.footnote)
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            Link("Open notification settings", destination: url)
                        }
                    }
                } header: {
                    Text("Monitoring")
                } footer: {
                    Text("Pushes are optional. We notify you when a disruption is found and for important changes, outside quiet hours (22:00–07:00 UK time). Holiday Mode pauses pushes; in-app warnings remain available.")
                }
                .disabled(store.isSuspended)

                if settings.enabled && !store.isSuspended {
                    scheduleSection
                }
            }
            .environment(\.timeZone, TimeZone(identifier: "Europe/London")!)
            .navigationTitle("Advance warnings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.save(settings, for: group)
                        dismiss()
                    }
                    .disabled(requestingPush || store.isSuspended || (settings.enabled && !validWindows))
                    .accessibilityIdentifier("disruptions.save")
                }
            }
        }
    }

    private var scheduleSection: some View {
        Section {
            if let travelDate = settings.travelDate {
                LabeledContent("Travel date", value: travelDate)
                Button("Monitor every week instead") { settings.travelDate = nil }
            } else {
                ForEach(1...7, id: \.self) { day in
                    Toggle(DayOfWeek.allCases[day - 1].fullLabel, isOn: Binding(
                        get: { settings.days.contains(day) },
                        set: { selected in
                            settings.days.removeAll { $0 == day }
                            if selected { settings.days.append(day); settings.days.sort() }
                        }
                    ))
                }
            }
            Toggle("Different hours for each day", isOn: Binding(
                get: { settings.dayWindows != nil },
                set: { custom in
                    settings.dayWindows = custom ? Dictionary(uniqueKeysWithValues: settings.days.map {
                        (String($0), settings.window)
                    }) : nil
                }
            ))
            if settings.dayWindows != nil {
                ForEach(settings.days.sorted(), id: \.self) { day in
                    DisruptionWindowEditor(title: DayOfWeek.allCases[day - 1].fullLabel, window: Binding(
                        get: { settings.window(on: day) },
                        set: { settings.dayWindows?[String(day)] = $0 }
                    ))
                }
            } else {
                DisruptionWindowEditor(title: "Travel hours", window: $settings.window)
            }
            if !validWindows {
                Text(settings.days.isEmpty ? "Choose at least one travel day." : "Choose different start and end times, or select All day.")
                    .font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Travel days and hours")
        } footer: {
            Text("Times use UK local time. An end time before the start runs into the following day. These settings apply only to advance disruption warnings for this direction.")
        }
    }
}

private struct DisruptionAffectedPeriodsView: View {
    let periods: [DisruptionAffectedWindow]

    var body: some View {
        if periods.count > 1 {
            Text("Affected travel windows").font(.subheadline.weight(.semibold))
        }
        ForEach(Array(periods.prefix(3).enumerated()), id: \.offset) { _, period in
            times(for: period)
        }
        if periods.count > 3 {
            DisclosureGroup("Show \(periods.count - 3) more affected periods") {
                ForEach(Array(periods.dropFirst(3).enumerated()), id: \.offset) { _, period in
                    times(for: period)
                }
            }
        }
    }

    private func times(for period: DisruptionAffectedWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("From") {
                Text(period.startAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Until") {
                Text(period.endAt, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
                    .multilineTextAlignment(.trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct DisruptionWindowEditor: View {
    let title: String
    @Binding var window: DisruptionTimeWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("\(title): all day", isOn: Binding(
                get: { window.isAllDay },
                set: { window = $0 ? DisruptionTimeWindow() : DisruptionTimeWindow(start: "07:00", end: "09:00") }
            ))
            if !window.isAllDay {
                DatePicker("From", selection: timeBinding(isEnd: false), displayedComponents: .hourAndMinute)
                DatePicker("Until", selection: timeBinding(isEnd: true), displayedComponents: .hourAndMinute)
            }
        }
    }

    private func timeBinding(isEnd: Bool) -> Binding<Date> {
        Binding(get: {
            let parts = (isEnd ? window.end : window.start).split(separator: ":")
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/London")!
            return calendar.date(from: DateComponents(year: 2026, month: 1, day: 1,
                hour: (Int(parts.first ?? "0") ?? 0) % 24, minute: Int(parts.last ?? "0") ?? 0)) ?? Date()
        }, set: { date in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "Europe/London")!
            let components = calendar.dateComponents([.hour, .minute], from: date)
            let value = String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
            if isEnd { window.end = value == "00:00" ? "24:00" : value }
            else { window.start = value }
        })
    }
}

private struct DisruptionAlternativesView: View {
    @State private var planner: JourneyPlannerStore
    @State private var path: [AddJourneyNavigationDestination] = []

    init(group: JourneyGroup, travelDate: Date) {
        let store = JourneyPlannerStore()
        store.origin = PlannerStation(crs: group.startStation.crs, name: group.startStation.name)
        store.destination = PlannerStation(crs: group.endStation.crs, name: group.endStation.name)
        store.timeMode = .departAt
        store.explicitTime = max(travelDate,
            Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970 / 60) * 60 + 60))
        _planner = State(initialValue: store)
    }

    var body: some View {
        // Alternatives intentionally allow other connections between the saved endpoints.
        NavigationStack(path: $path) {
            JourneyPlannerView(store: planner, navigationPath: $path)
        }
    }
}
