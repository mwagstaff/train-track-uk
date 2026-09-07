import SwiftUI
import UIKit

struct NotificationScheduleView: View {
    let group: JourneyGroup
    let reverseGroup: JourneyGroup?
    let existingSubscription: NotificationSubscription?

    @EnvironmentObject var activityMgr: LiveActivityManager
    @EnvironmentObject var notificationStore: NotificationSubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var legs: [NotificationLeg]
    @State private var scheduleKind: NotificationScheduleKind = .regular
    @State private var windowPattern: NotificationWindowPattern = .same
    @State private var selectedDays: Set<DayOfWeek>
    @State private var outboundTravelDate = Calendar.current.startOfDay(for: Date())
    @State private var returnTravelDate = Calendar.current.startOfDay(for: Date())
    @State private var errorMessage: String?
    @State private var showErrorAlert = false
    @State private var isSaving = false
    @State private var isDeleting = false
    @State private var showDeleteDialog = false
    @State private var showUnsavedChangesDialog = false
    @State private var didApplyExisting = false
    @State private var initialDraftState: ScheduleDraftState?
    @State private var showWindowHint: Set<Int> = []

    @State private var reversalCount = 0

    private let maxWindowMinutes = 300
    private let defaultWindowMinutes = 120
    private let outboundLegCount: Int
    private let regularLegCount: Int

    init(
        group: JourneyGroup,
        reverseGroup: JourneyGroup? = nil,
        existingSubscription: NotificationSubscription? = nil
    ) {
        self.group = group
        self.reverseGroup = reverseGroup
        self.existingSubscription = existingSubscription
        var grouped: [JourneyGroup] = [group]
        if let reverseGroup, reverseGroup.id != group.id {
            grouped.append(reverseGroup)
        }
        let regularLegs = grouped.enumerated().flatMap { groupIndex, group in
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
        let returnLegs: [NotificationLeg]
        if reverseGroup == nil {
            let window = Self.defaultWindow(forGroupIndex: 1)
            returnLegs = group.legs.reversed().map { leg in
                NotificationLeg(
                    from: leg.toStation.crs,
                    to: leg.fromStation.crs,
                    fromName: leg.toStation.name,
                    toName: leg.fromStation.name,
                    enabled: false,
                    windowStart: window.start,
                    windowEnd: window.end
                )
            }
        } else {
            returnLegs = []
        }
        outboundLegCount = group.legs.count
        regularLegCount = regularLegs.count
        _legs = State(initialValue: regularLegs + returnLegs)
        _selectedDays = State(initialValue: [.mon, .tue, .wed, .thu, .fri])
    }

    private var routeKey: String {
        let crs = group.stationSequence.map { $0.crs.uppercased() }
        let forward = crs.joined(separator: "-")
        let reverse = crs.reversed().joined(separator: "-")
        return min(forward, reverse)
    }

    private var existing: NotificationSubscription? {
        existingSubscription
    }

    private var activeLegIndices: [Int] {
        scheduleKind == .regular ? regularLegIndices : Array(legs.indices)
    }

    private var hasEnabledLegs: Bool {
        activeLegIndices.contains { legs[$0].enabled }
    }

    private var outboundLegIndices: [Int] {
        Array(0..<min(outboundLegCount, legs.count))
    }

    private var returnLegIndices: [Int] {
        Array(min(outboundLegCount, legs.count)..<legs.count)
    }

    private var regularLegIndices: [Int] {
        Array(0..<min(regularLegCount, legs.count))
    }

    private var orderedSelectedDays: [DayOfWeek] {
        DayOfWeek.allCases.filter(selectedDays.contains)
    }

    private var draftState: ScheduleDraftState {
        ScheduleDraftState(
            scheduleKind: scheduleKind,
            days: orderedSelectedDays,
            windowPattern: windowPattern,
            outboundTravelDate: travelDateString(from: outboundTravelDate),
            returnTravelDate: travelDateString(from: returnTravelDate),
            legs: legs
        )
    }

    private var hasUnsavedChanges: Bool {
        if existing == nil {
            return true
        }
        guard let initialDraftState else { return false }
        return draftState != initialDraftState
    }

    private var canSave: Bool {
        let hasDays = scheduleKind == .oneOff || !selectedDays.isEmpty
        return hasDays && hasEnabledLegs && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Journey frequency", selection: $scheduleKind) {
                        ForEach(NotificationScheduleKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if scheduleKind == .regular {
                    Section {
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: DayOfWeek.allCases.count),
                            spacing: 8
                        ) {
                            ForEach(DayOfWeek.allCases) { day in
                                dayCheckbox(day)
                            }
                        }
                    } header: {
                        RailwayBackgroundSectionHeader(title: "Days")
                    }

                    Section {
                        Picker("Time windows", selection: Binding(
                            get: { windowPattern },
                            set: { applyWindowPattern($0) }
                        )) {
                            ForEach(NotificationWindowPattern.allCases) { pattern in
                                Text(pattern.rawValue).tag(pattern)
                            }
                        }
                        Text("Use the same times, split weekdays and weekends, or customise each day. Each window can be up to 5 hours.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    ForEach(regularLegIndices, id: \.self) { index in
                        Section {
                            Toggle("Enabled", isOn: bindingForLegEnabled(index))
                            ForEach(windowPattern.dayGroups, id: \.self) { group in
                                let days = group.filter(selectedDays.contains)
                                if !days.isEmpty {
                                    regularWindowEditor(index, days: days)
                                }
                            }
                            if showWindowHint.contains(index) {
                                windowHint
                            }
                        } header: {
                            journeySectionHeader(legLabel(legs[index]))
                        }
                    }
                } else {
                    Section {
                        AutoDismissDatePicker(
                            title: "Day of travel",
                            selection: $outboundTravelDate,
                            minimumDate: Calendar.current.startOfDay(for: Date())
                        )
                    } header: {
                        RailwayBackgroundSectionHeader(title: "Date")
                    }

                    travelWindowSection(
                        title: "Outbound travel window",
                        indices: outboundLegIndices,
                        travelDate: nil
                    )

                    travelWindowSection(
                        title: "Return travel window",
                        indices: returnLegIndices,
                        travelDate: $returnTravelDate
                    )
                }

                if existing != nil {
                    Section {
                        Button("Delete schedule", role: .destructive) {
                            showDeleteDialog = true
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .railwayBackgroundPOC(showsInfoButton: false)
            .navigationTitle("Schedule journey updates")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: outboundTravelDate) { oldDate, newDate in
                if Calendar.current.isDate(returnTravelDate, inSameDayAs: oldDate)
                    || returnTravelDate < newDate {
                    returnTravelDate = newDate
                }
            }
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

                ToolbarItemGroup(placement: .confirmationAction) {
                    Button {
                        reverseLegs()
                    } label: {
                        Image(systemName: "arrow.left.arrow.right")
                            .rotationEffect(.degrees(reduceMotion ? 0 : Double(reversalCount) * 180))
                    }
                    .accessibilityLabel("Reverse legs")
                    .accessibilityHint("Swaps the journey directions while keeping the time windows in place")
                    .disabled(isSaving || isDeleting || legs.isEmpty)

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
            .alert("Delete schedule?", isPresented: $showDeleteDialog) {
                Button("Delete", role: .destructive) {
                    deleteSchedule()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will remove scheduled notifications for this journey.")
            }
            .alert("Save changes before closing?", isPresented: $showUnsavedChangesDialog) {
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
            .alert("Could not save", isPresented: $showErrorAlert, presenting: errorMessage) { _ in
                Button("OK", role: .cancel) { }
            } message: { message in
                Text(message)
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

    private func reverseLegs() {
        withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.45)) {
            legs = NotificationScheduleEditing.reversingDirections(in: legs, outboundLegCount: outboundLegCount)
            reversalCount += 1
        }
        showWindowHint.removeAll()
        UIAccessibility.post(notification: .announcement, argument: "Journey directions reversed. Time windows unchanged.")
    }

    private func journeySectionHeader(_ title: String) -> some View {
        ZStack(alignment: .leading) {
            RailwayBackgroundSectionHeader(title: title)
                .id(title)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func applyExistingIfNeeded() {
        guard !didApplyExisting, let existing else { return }
        didApplyExisting = true
        scheduleKind = existing.scheduleKind
            ?? (existing.legs.contains { $0.travelDate != nil } ? .oneOff : .regular)
        selectedDays = Set(existing.daysOfWeek)
        for (index, existingLeg) in existing.legs.enumerated() where legs.indices.contains(index) {
            legs[index] = existingLeg
            clampLegWindow(index)
        }
        if existing.legs.count == outboundLegCount, legs.count > outboundLegCount {
            let returnRoutes = legs.prefix(outboundLegCount).reversed()
            for (index, route) in zip(returnLegIndices, returnRoutes) {
                let schedule = legs[index]
                legs[index] = NotificationLeg(
                    from: route.to, to: route.from,
                    fromName: route.toName, toName: route.fromName,
                    enabled: schedule.enabled,
                    windowStart: schedule.windowStart, windowEnd: schedule.windowEnd
                )
            }
        }
        windowPattern = .matching(legs: regularLegIndices.map { legs[$0] }, days: orderedSelectedDays)
        if let value = outboundLegIndices.compactMap({ legs[$0].travelDate }).first,
           let date = travelDate(from: value) {
            outboundTravelDate = date
        }
        if let value = returnLegIndices.compactMap({ legs[$0].travelDate }).first,
           let date = travelDate(from: value) {
            returnTravelDate = date
        } else {
            returnTravelDate = outboundTravelDate
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

    private func travelWindowSection(
        title: String,
        indices: [Int],
        travelDate: Binding<Date>?
    ) -> some View {
        let isEnabled = indices.contains { legs[$0].enabled }
        let hintIsVisible = !showWindowHint.isDisjoint(with: indices)
        return Section {
            Toggle("Enabled", isOn: bindingForLegsEnabled(indices))
            if let travelDate {
                AutoDismissDatePicker(
                    title: "Date",
                    selection: travelDate,
                    minimumDate: outboundTravelDate
                )
                .disabled(!isEnabled)
            }
            DatePicker(
                "Start",
                selection: bindingForStartTime(indices),
                displayedComponents: .hourAndMinute
            )
            .disabled(!isEnabled)
            DatePicker(
                "End",
                selection: bindingForEndTime(indices),
                displayedComponents: .hourAndMinute
            )
            .disabled(!isEnabled)
            if hintIsVisible {
                windowHint
            }
        } header: {
            let route = indices.first.map { first in
                let last = indices.last ?? first
                return "\(legs[first].fromName ?? legs[first].from) → \(legs[last].toName ?? legs[last].to)"
            }
            journeySectionHeader(route.map { "\(title): \($0)" } ?? title)
        }
    }

    private var windowHint: some View {
        Text("Choose a window up to 5 hours.")
            .font(.footnote)
            .foregroundStyle(.secondary)
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
        .accessibilityLabel(day.fullLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func toggleDay(_ day: DayOfWeek) {
        if selectedDays.contains(day) {
            selectedDays.remove(day)
        } else {
            if let group = windowPattern.dayGroups.first(where: { $0.contains(day) }),
               let source = group.first(where: selectedDays.contains) {
                for index in regularLegIndices {
                    legs[index].setWindow(legs[index].window(on: source), for: [day])
                }
            }
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

    private func bindingForLegsEnabled(_ indices: [Int]) -> Binding<Bool> {
        Binding(
            get: { indices.contains { legs[$0].enabled } },
            set: { isEnabled in
                for index in indices {
                    legs[index].enabled = isEnabled
                }
            }
        )
    }

    private func applyWindowPattern(_ pattern: NotificationWindowPattern) {
        if pattern == .split { selectedDays = Set(DayOfWeek.allCases) }
        for index in regularLegIndices {
            for group in pattern.dayGroups {
                let first = group.first(where: selectedDays.contains) ?? group[0]
                let window = legs[index].window(on: first)
                legs[index].setWindow(window, for: group)
                if pattern == .same {
                    legs[index].windowStart = window.windowStart
                    legs[index].windowEnd = window.windowEnd
                }
            }
        }
        windowPattern = pattern
    }

    private func regularWindowEditor(_ index: Int, days: [DayOfWeek]) -> some View {
        let label = DayOfWeek.friendlyLabel(for: days)
        return VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            DatePicker("Start", selection: bindingForRegularTime(index, days: days, isStart: true), displayedComponents: .hourAndMinute)
                .accessibilityLabel("\(label) start")
            DatePicker("End", selection: bindingForRegularTime(index, days: days, isStart: false), displayedComponents: .hourAndMinute)
                .accessibilityLabel("\(label) end")
        }
        .disabled(!legs[index].enabled)
    }

    private func bindingForRegularTime(_ index: Int, days: [DayOfWeek], isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let window = legs[index].window(on: days[0])
                return timeFromString(isStart ? window.windowStart : window.windowEnd) ?? Date()
            },
            set: { value in
                var window = legs[index].window(on: days[0])
                let lastMinute = Calendar.current.date(bySettingHour: 23, minute: 59, second: 0, of: value) ?? value
                if isStart {
                    window.windowStart = timeString(from: value)
                    let end = Calendar.current.date(byAdding: .minute, value: defaultWindowMinutes, to: value) ?? value
                    window.windowEnd = timeString(from: min(end, lastMinute))
                    showWindowHint.remove(index)
                } else if let start = timeFromString(window.windowStart) {
                    let maxEnd = min(Calendar.current.date(byAdding: .minute, value: maxWindowMinutes, to: start) ?? start, lastMinute)
                    if value > maxEnd || value < start { showWindowHint.insert(index) }
                    else { showWindowHint.remove(index) }
                    window.windowEnd = timeString(from: min(max(value, start), maxEnd))
                }
                let group = windowPattern.dayGroups.first(where: { $0.contains(days[0]) }) ?? days
                legs[index].setWindow(window, for: group)
                if windowPattern == .same {
                    legs[index].windowStart = window.windowStart
                    legs[index].windowEnd = window.windowEnd
                }
            }
        )
    }

    private func bindingForStartTime(_ indices: [Int]) -> Binding<Date> {
        guard let firstIndex = indices.first else {
            return .constant(Date())
        }
        return Binding(
            get: {
                timeFromString(legs[firstIndex].windowStart)
                    ?? defaultWindowDate(for: firstIndex, isStart: true)
            },
            set: { newValue in
                let endDate = Calendar.current.date(byAdding: .hour, value: 2, to: newValue) ?? newValue
                for index in indices {
                    legs[index].windowStart = timeString(from: newValue)
                    legs[index].windowEnd = timeString(from: endDate)
                    showWindowHint.remove(index)
                }
            }
        )
    }

    private func bindingForEndTime(_ indices: [Int]) -> Binding<Date> {
        guard let firstIndex = indices.first else {
            return .constant(Date())
        }
        return Binding(
            get: {
                timeFromString(legs[firstIndex].windowEnd)
                    ?? defaultWindowDate(for: firstIndex, isStart: false)
            },
            set: { newValue in
                for index in indices {
                    legs[index].windowEnd = timeString(from: newValue)
                    if let startDate = timeFromString(legs[index].windowStart) {
                        let maxEnd = Calendar.current.date(byAdding: .minute, value: maxWindowMinutes, to: startDate) ?? startDate
                        if newValue > maxEnd {
                            showWindowHint.insert(index)
                        } else {
                            showWindowHint.remove(index)
                        }
                    }
                    clampLegWindow(index)
                }
            }
        )
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

    private func travelDate(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private func travelDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
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

    private func showError(_ message: String) {
        errorMessage = message
        showErrorAlert = true
    }

    private func save() {
        guard canSave else { return }
        Task {
            isSaving = true
            errorMessage = nil
            let allowed = await NotificationAuthorizationManager.ensureAuthorized()
            guard allowed else {
                showError("Notifications are disabled. Enable them in Settings.")
                isSaving = false
                return
            }

            // Journey detection establishes the durable authorization goal for every schedule.
            NotificationGeofenceManager.shared.requestAlwaysAuthorizationIfNeeded()

            let pushToStartReady = await activityMgr.ensurePushToStartTokenRegistered()
            guard pushToStartReady else {
                showError("Live Activity server start isn't ready yet. Please try again in a moment.")
                isSaving = false
                return
            }

            guard let pushToken = await NotificationPushTokenStore.waitForToken(timeoutSeconds: 6.0) else {
                showError("Waiting for a push token. Try again in a moment.")
                isSaving = false
                return
            }

            let requestLegs = activeLegIndices.map { index in
                var leg = legs[index]
                if scheduleKind == .oneOff {
                    let date = outboundLegIndices.contains(index) ? outboundTravelDate : returnTravelDate
                    leg.travelDate = travelDateString(from: date)
                    leg.dayWindows = nil
                } else {
                    leg.travelDate = nil
                }
                return leg
            }
            let primaryLeg = requestLegs.first(where: { $0.enabled }) ?? requestLegs.first
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
                scheduleKind: scheduleKind,
                daysOfWeek: scheduleKind == .regular ? orderedSelectedDays : [],
                notificationTypes: NotificationPreferences.effectiveTypes(for: .scheduled),
                legs: requestLegs,
                windowStart: primaryLeg?.windowStart,
                windowEnd: primaryLeg?.windowEnd,
                from: primaryLeg?.from,
                to: primaryLeg?.to,
                fromName: primaryLeg?.fromName,
                toName: primaryLeg?.toName,
                useSandbox: useSandbox,
                muteOnArrival: true,
                liveSessionOrigin: nil,
                activeUntil: nil
            )

            do {
                _ = try await notificationStore.upsert(request)
                dismiss()
            } catch {
                showError(error.localizedDescription)
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
                showError(error.localizedDescription)
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

struct NotificationScheduleDestination: Identifiable {
    let id = UUID()
    let group: JourneyGroup
    let reverseGroup: JourneyGroup?
    let existingSubscription: NotificationSubscription?
}

#Preview {
    Group {
        if let first = JourneyStore.shared.journeyGroups().first {
            NotificationScheduleView(group: first)
                .environmentObject(NotificationSubscriptionStore.shared)
                .environmentObject(LiveActivityManager.shared)
        } else {
            Text("No journeys for preview")
        }
    }
}

private struct ScheduleDraftState: Equatable {
    let scheduleKind: NotificationScheduleKind
    let days: [DayOfWeek]
    let windowPattern: NotificationWindowPattern
    let outboundTravelDate: String
    let returnTravelDate: String
    let legs: [NotificationLeg]
}

private struct AutoDismissDatePicker: View {
    let title: String
    @Binding var selection: Date
    let minimumDate: Date

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Text(selection.formatted(date: .abbreviated, time: .omitted))
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(selection.formatted(date: .long, time: .omitted))
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            DatePicker(
                title,
                selection: Binding(
                    get: { selection },
                    set: { newDate in
                        selection = newDate
                        isPresented = false
                    }
                ),
                in: minimumDate...,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding()
            .frame(width: 340)
            .presentationCompactAdaptation(.popover)
        }
    }
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
