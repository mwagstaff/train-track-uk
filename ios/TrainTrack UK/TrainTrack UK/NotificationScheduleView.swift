import SwiftUI

struct NotificationScheduleView: View {
    let group: JourneyGroup
    let reverseGroup: JourneyGroup?

    @EnvironmentObject var notificationStore: NotificationSubscriptionStore
    @Environment(\.dismiss) private var dismiss

    @State private var legs: [NotificationLeg]
    @State private var selectedDays: Set<DayOfWeek>
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var showDeleteDialog = false
    @State private var didApplyExisting = false

    private let maxWindowMinutes = 120

    init(group: JourneyGroup, reverseGroup: JourneyGroup? = nil) {
        self.group = group
        self.reverseGroup = reverseGroup
        var grouped: [JourneyGroup] = [group]
        if let reverseGroup, reverseGroup.id != group.id {
            grouped.append(reverseGroup)
        }
        let initialLegs = grouped.enumerated().flatMap { groupIndex, group in
            let window = Self.defaultWindow(forGroupIndex: groupIndex)
            return group.legs.map { leg in
            return NotificationLeg(
                from: leg.fromStation.crs,
                to: leg.toStation.crs,
                fromName: leg.fromStation.name,
                toName: leg.toStation.name,
                enabled: true,
                windowStart: window.start,
                windowEnd: window.end
            )
            }
        }
        _legs = State(initialValue: initialLegs)
        _selectedDays = State(initialValue: [.mon, .tue, .wed, .thu, .fri])
    }

    private var routeKey: String {
        let crs = group.stationSequence.map { $0.crs.uppercased() }
        let forward = crs.joined(separator: "-")
        let reverse = crs.reversed().joined(separator: "-")
        return min(forward, reverse)
    }

    private var existing: NotificationSubscription? {
        notificationStore.subscription(for: routeKey)
    }

    private var hasEnabledLegs: Bool { legs.contains(where: { $0.enabled }) }

    private var canSave: Bool {
        !selectedDays.isEmpty && hasEnabledLegs && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Days") {
                    HStack(spacing: 6) {
                        ForEach(DayOfWeek.allCases) { day in
                            dayButton(day)
                        }
                    }
                }

                ForEach(legs.indices, id: \.self) { index in
                    let leg = legs[index]
                    Section("Time Window: \(legLabel(leg))") {
                        Toggle("Enabled", isOn: bindingForLegEnabled(index))
                        DatePicker("Start", selection: bindingForStartTime(index), displayedComponents: .hourAndMinute)
                            .disabled(!leg.enabled)
                        DatePicker("End", selection: bindingForEndTime(index), displayedComponents: .hourAndMinute)
                            .disabled(!leg.enabled)
                        HStack(spacing: 8) {
                            Button("Next 30m") { applyQuickWindow(index, minutes: 30) }
                            Button("Next 1h") { applyQuickWindow(index, minutes: 60) }
                            Button("Next 2h") { applyQuickWindow(index, minutes: 120) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!leg.enabled)
                        Text("Choose a window up to 2 hours.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(existing == nil ? "Schedule notifications" : "Update schedule") {
                        save()
                    }
                    .disabled(!canSave)
                }

                if existing != nil {
                    Section {
                        Button("Delete schedule", role: .destructive) {
                            showDeleteDialog = true
                        }
                    }
                }
            }
            .navigationTitle("Schedule notifications")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog(
                "Delete schedule?",
                isPresented: $showDeleteDialog
            ) {
                Button("Delete schedule", role: .destructive) {
                    deleteSchedule()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will remove scheduled notifications for this journey.")
            }
            .task {
                await NotificationAuthorizationManager.registerIfAuthorized()
                await notificationStore.refresh()
                applyExistingIfNeeded()
            }
        }
    }

    private func applyExistingIfNeeded() {
        guard !didApplyExisting, let existing else { return }
        didApplyExisting = true
        selectedDays = Set(existing.daysOfWeek)
        let existingById = Dictionary(uniqueKeysWithValues: existing.legs.map { ($0.id, $0) })
        for index in legs.indices {
            if let existingLeg = existingById[legs[index].id] {
                legs[index].enabled = existingLeg.enabled
                legs[index].windowStart = existingLeg.windowStart
                legs[index].windowEnd = existingLeg.windowEnd
                clampLegWindow(index)
            }
        }
    }

    private func clampLegWindow(_ index: Int) {
        guard legs.indices.contains(index) else { return }
        guard let startDate = timeFromString(legs[index].windowStart),
              let endDate = timeFromString(legs[index].windowEnd) else {
            return
        }
        let maxEnd = Calendar.current.date(byAdding: .minute, value: maxWindowMinutes, to: startDate) ?? startDate
        if endDate < startDate {
            legs[index].windowEnd = timeString(from: startDate)
        } else if endDate > maxEnd {
            legs[index].windowEnd = timeString(from: maxEnd)
        }
    }

    private func dayButton(_ day: DayOfWeek) -> some View {
        let isSelected = selectedDays.contains(day)
        return Button(day.shortLabel) {
            if isSelected {
                selectedDays.remove(day)
            } else {
                selectedDays.insert(day)
            }
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .blue : .gray)
        .frame(maxWidth: .infinity)
    }

    private func legLabel(_ leg: NotificationLeg) -> String {
        let from = leg.fromName ?? leg.from
        let to = leg.toName ?? leg.to
        return "\(from) → \(to)"
    }

    private func bindingForLegEnabled(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { legs[index].enabled },
            set: { legs[index].enabled = $0 }
        )
    }

    private func bindingForStartTime(_ index: Int) -> Binding<Date> {
        Binding(
            get: {
                timeFromString(legs[index].windowStart)
                    ?? defaultWindowDate(for: index, isStart: true)
            },
            set: { newValue in
                legs[index].windowStart = timeString(from: newValue)
                clampLegWindow(index)
            }
        )
    }

    private func bindingForEndTime(_ index: Int) -> Binding<Date> {
        Binding(
            get: {
                timeFromString(legs[index].windowEnd)
                    ?? defaultWindowDate(for: index, isStart: false)
            },
            set: { newValue in
                legs[index].windowEnd = timeString(from: newValue)
                clampLegWindow(index)
            }
        )
    }

    private func applyQuickWindow(_ index: Int, minutes: Int) {
        guard legs.indices.contains(index) else { return }
        let start = Date()
        let end = Calendar.current.date(byAdding: .minute, value: minutes, to: start) ?? start
        legs[index].windowStart = timeString(from: start)
        legs[index].windowEnd = timeString(from: end)
        clampLegWindow(index)
    }

    private func timeFromString(_ value: String) -> Date? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func save() {
        guard canSave else { return }
        Task {
            isSaving = true
            errorMessage = nil
            let allowed = await NotificationAuthorizationManager.ensureAuthorized()
            guard allowed else {
                errorMessage = "Notifications are disabled. Enable them in Settings."
                isSaving = false
                return
            }
            guard let pushToken = await NotificationPushTokenStore.waitForToken(timeoutSeconds: 6.0) else {
                errorMessage = "Waiting for a push token. Try again in a moment."
                isSaving = false
                return
            }

            let primaryLeg = legs.first(where: { $0.enabled }) ?? legs.first
            #if DEBUG
            let useSandbox = true
            #else
            let useSandbox = false
            #endif
            let request = NotificationSubscriptionRequest(
                subscriptionId: existing?.id,
                deviceId: DeviceIdentity.deviceToken,
                pushToken: pushToken,
                routeKey: routeKey,
                daysOfWeek: Array(selectedDays),
                notificationTypes: NotificationPreferences.effectiveTypes(for: .scheduled),
                legs: legs,
                windowStart: primaryLeg?.windowStart,
                windowEnd: primaryLeg?.windowEnd,
                from: primaryLeg?.from,
                to: primaryLeg?.to,
                fromName: primaryLeg?.fromName,
                toName: primaryLeg?.toName,
                useSandbox: useSandbox,
                muteOnArrival: (UserDefaults.standard.object(forKey: "autoMuteOnArrival") as? Bool) ?? true,
                activeUntil: nil
            )

            do {
                _ = try await notificationStore.upsert(request)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func deleteSchedule() {
        guard let existing else { return }
        Task {
            isDeleting = true
            errorMessage = nil
            do {
                try await notificationStore.delete(id: existing.id)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
            isDeleting = false
        }
    }

    private static func defaultWindow(forGroupIndex index: Int) -> (start: String, end: String) {
        if index == 0 {
            return ("07:00", "09:00")
        }
        if index == 1 {
            return ("16:00", "18:00")
        }
        return ("07:00", "09:00")
    }

    private func defaultWindowDate(for index: Int, isStart: Bool) -> Date {
        let window = Self.defaultWindow(forGroupIndex: index)
        let value = isStart ? window.start : window.end
        return timeFromString(value) ?? Date()
    }
}

#Preview {
    Group {
        if let first = JourneyStore.shared.journeyGroups().first {
            NotificationScheduleView(group: first)
                .environmentObject(NotificationSubscriptionStore.shared)
        } else {
            Text("No journeys for preview")
        }
    }
}
