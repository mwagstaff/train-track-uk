import SwiftUI
import UIKit

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
    @State private var showUnsavedChangesDialog = false
    @State private var didApplyExisting = false
    @State private var initialDraftState: ScheduleDraftState?

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

    private var orderedSelectedDays: [DayOfWeek] {
        DayOfWeek.allCases.filter(selectedDays.contains)
    }

    private var draftState: ScheduleDraftState {
        ScheduleDraftState(days: orderedSelectedDays, legs: legs)
    }

    private var hasUnsavedChanges: Bool {
        if existing == nil {
            return true
        }
        guard let initialDraftState else { return false }
        return draftState != initialDraftState
    }

    private var canSave: Bool {
        !selectedDays.isEmpty && hasEnabledLegs && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Days") {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: DayOfWeek.allCases.count),
                        spacing: 8
                    ) {
                        ForEach(DayOfWeek.allCases) { day in
                            dayCheckbox(day)
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

                if existing != nil {
                    Section {
                        Button("Delete schedule", role: .destructive) {
                            showDeleteDialog = true
                        }
                    }
                }
            }
            .navigationTitle("Schedule journey updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        attemptDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                    .disabled(isSaving || isDeleting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if hasUnsavedChanges {
                        Button {
                            save()
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel(existing == nil ? "Schedule journey updates" : "Save changes")
                        .disabled(!canSave)
                    }
                }
            }
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
            .confirmationDialog(
                "Save changes before closing?",
                isPresented: $showUnsavedChangesDialog,
                titleVisibility: .visible
            ) {
                if canSave {
                    Button(existing == nil ? "Schedule journey updates" : "Save changes") {
                        save()
                    }
                }
                Button("Discard changes", role: .destructive) {
                    dismiss()
                }
                Button("Keep editing", role: .cancel) { }
            } message: {
                Text("You have unsaved notification changes for this journey.")
            }
            .task {
                await NotificationAuthorizationManager.registerIfAuthorized()
                await notificationStore.refresh()
                applyExistingIfNeeded()
                captureInitialDraftStateIfNeeded()
            }
            .background(
                SheetDismissGuard(isDisabled: hasUnsavedChanges || isSaving || isDeleting) {
                    attemptDismiss()
                }
            )
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

    private func dayCheckbox(_ day: DayOfWeek) -> some View {
        let isSelected = selectedDays.contains(day)
        return Button {
            toggleDay(day)
        } label: {
            VStack(spacing: 6) {
                Text(day.shortLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityLabel(day.shortLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func toggleDay(_ day: DayOfWeek) {
        if selectedDays.contains(day) {
            selectedDays.remove(day)
        } else {
            selectedDays.insert(day)
        }
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

    private func captureInitialDraftStateIfNeeded() {
        guard initialDraftState == nil else { return }
        initialDraftState = draftState
    }

    private func attemptDismiss() {
        guard !isSaving && !isDeleting else { return }
        if hasUnsavedChanges {
            showUnsavedChangesDialog = true
        } else {
            dismiss()
        }
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
                daysOfWeek: orderedSelectedDays,
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

private struct ScheduleDraftState: Equatable {
    let days: [DayOfWeek]
    let legs: [NotificationLeg]
}

private struct SheetDismissGuard: UIViewControllerRepresentable {
    let isDisabled: Bool
    let onAttemptToDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(isDisabled: isDisabled, onAttemptToDismiss: onAttemptToDismiss)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        context.coordinator.isDisabled = isDisabled
        context.coordinator.onAttemptToDismiss = onAttemptToDismiss

        DispatchQueue.main.async {
            uiViewController.parent?.presentationController?.delegate = context.coordinator
        }
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        var isDisabled: Bool
        var onAttemptToDismiss: () -> Void

        init(isDisabled: Bool, onAttemptToDismiss: @escaping () -> Void) {
            self.isDisabled = isDisabled
            self.onAttemptToDismiss = onAttemptToDismiss
        }

        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            !isDisabled
        }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            guard isDisabled else { return }
            onAttemptToDismiss()
        }
    }
}
