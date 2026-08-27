import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var notificationStore: NotificationSubscriptionStore
    @EnvironmentObject var holidayMode: HolidayModeStore
    @State private var pendingDeleteUpdate: NotificationSubscription? = nil
    @State private var showUpdateDeleteDialog = false
    @State private var viewingScheduledRoute: IdentifiableScheduledRoute? = nil
    @State private var viewingLiveSession: NotificationSubscription? = nil
    @State private var journeyUpdatesNow = Date()

    private var sortedJourneyUpdates: [NotificationSubscription] {
        JourneyUpdateOrdering.sorted(
            notificationStore.combinedSubscriptions,
            scheduledIDs: Set(notificationStore.subscriptions.map(\.id)),
            now: journeyUpdatesNow
        )
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    PreferencesView()
                } label: {
                    profileRow(
                        title: "Preferences",
                        subtitle: "Notifications, Live Activity, journey sorting, and display settings.",
                        systemImage: "slider.horizontal.3"
                    )
                }

                if holidayMode.isEnabled || !notificationStore.subscriptions.isEmpty {
                    Button {
                        holidayMode.setEnabled(!holidayMode.isEnabled)
                    } label: {
                        profileRow(
                            title: holidayMode.isEnabled ? "Holiday mode enabled" : "Holiday mode",
                            subtitle: holidayMode.isEnabled
                                ? "Your scheduled journeys, notifications, and widgets are paused. Tap to switch them back on."
                                : "Going away? Pause your scheduled journeys — no notifications or widget updates until you turn it off.",
                            systemImage: "beach.umbrella"
                        )
                    }
                }

                NavigationLink {
                    AboutView()
                } label: {
                    profileRow(
                        title: "About",
                        subtitle: "Version info, feedback, credits, and data sources.",
                        systemImage: "info.circle"
                    )
                }
            }

            Section {
                if notificationStore.isLoading && !notificationStore.hasLoadedOnce {
                    ProgressView("Loading…")
                } else if !notificationStore.hasAuthoritativeRemoteState {
                    Text("Unable to refresh journey updates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if notificationStore.combinedSubscriptions.isEmpty {
                    Text("No active journey updates.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedJourneyUpdates) { sub in
                        journeyUpdateCard(for: sub)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    }
                }
            } header: {
                RailwayBackgroundSectionHeader(title: "Journey Updates")
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await notificationStore.refresh()
            try? await StationsService.shared.loadStations()
        }
        .task {
            while !Task.isCancelled {
                journeyUpdatesNow = Date()
                do {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                } catch {
                    break
                }
            }
        }
        .alert("Delete journey update?", isPresented: $showUpdateDeleteDialog, presenting: pendingDeleteUpdate) { sub in
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
            NotificationScheduleView(
                group: route.group,
                reverseGroup: route.reverseGroup,
                existingSubscription: route.subscription
            )
                .environmentObject(notificationStore)
        }
        .sheet(item: $viewingLiveSession) { session in
            LiveSessionInfoSheet(session: session)
        }
        .railwayBackgroundPOC()
    }

    private func profileRow(title: String, subtitle: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 28, height: 28)
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func journeyUpdateCard(for sub: NotificationSubscription) -> some View {
        let scheduled = isScheduled(sub)
        let active = isActive(sub)
        let legs = chronologicalLegs(from: sub.legs)
        HStack(alignment: .center, spacing: 0) {
            Button {
                if scheduled, let route = resolvedScheduledRoute(for: sub) {
                    viewingScheduledRoute = IdentifiableScheduledRoute(
                        group: route.group,
                        reverseGroup: route.reverseGroup,
                        subscription: sub
                    )
                } else if !scheduled {
                    viewingLiveSession = sub
                }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(legs.enumerated()), id: \.offset) { index, leg in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 14)
                        }
                        legContent(
                            leg: leg,
                            subscription: sub,
                            scheduled: scheduled,
                            active: active
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(Color(.separator))
                .frame(width: 0.5)
                .frame(maxHeight: .infinity)
                .padding(.vertical, 10)

            Button {
                pendingDeleteUpdate = sub
                showUpdateDeleteDialog = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15))
                    .foregroundStyle(.red)
                    .frame(width: 44)
                    .frame(maxHeight: .infinity)
            }
            .buttonStyle(.plain)
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func legContent(
        leg: NotificationLeg,
        subscription: NotificationSubscription,
        scheduled: Bool,
        active: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(leg.fromName ?? leg.from) → \(leg.toName ?? leg.to)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            HStack(spacing: 6) {
                Text(scheduled ? "Scheduled" : "Adhoc")
                    .font(.caption)
                    .foregroundStyle(scheduled ? .blue : .orange)
                if leg.enabled {
                    Text(
                        JourneyUpdateSchedulePresentation.detail(
                            for: leg,
                            subscription: subscription,
                            scheduled: scheduled,
                            now: journeyUpdatesNow
                        )
                    )
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func isScheduled(_ sub: NotificationSubscription) -> Bool {
        notificationStore.subscriptions.contains(where: { $0.id == sub.id })
    }

    private func isActive(_ sub: NotificationSubscription) -> Bool {
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

    private func resolvedScheduledRoute(for subscription: NotificationSubscription) -> ProfileResolvedScheduledRoute? {
        let legs = chronologicalLegs(from: subscription.legs)
        guard !legs.isEmpty else { return nil }
        if let splitIndex = returnSplitIndex(for: legs) {
            let outbound = Array(legs.prefix(splitIndex))
            let inbound = Array(legs.dropFirst(splitIndex))
            return ProfileResolvedScheduledRoute(
                group: makeJourneyGroup(from: outbound),
                reverseGroup: makeJourneyGroup(from: inbound)
            )
        }
        return ProfileResolvedScheduledRoute(
            group: makeJourneyGroup(from: legs),
            reverseGroup: nil
        )
    }

    private func returnSplitIndex(for legs: [NotificationLeg]) -> Int? {
        guard legs.count >= 2 else { return nil }
        for splitIndex in 1..<legs.count {
            let outbound = Array(legs.prefix(splitIndex))
            let inbound = Array(legs.dropFirst(splitIndex))
            if stationSequence(for: inbound) == stationSequence(for: outbound).reversed() {
                return splitIndex
            }
        }
        return nil
    }

    private func chronologicalLegs(from legs: [NotificationLeg]) -> [NotificationLeg] {
        legs.enumerated()
            .sorted { lhs, rhs in
                if let lhsDate = lhs.element.travelDate,
                   let rhsDate = rhs.element.travelDate,
                   lhsDate != rhsDate {
                    return lhsDate < rhsDate
                }
                let lhsMinutes = minutesSinceMidnight(lhs.element.windowStart)
                let rhsMinutes = minutesSinceMidnight(rhs.element.windowStart)
                switch (lhsMinutes, rhsMinutes) {
                case let (lhsMinutes?, rhsMinutes?) where lhsMinutes != rhsMinutes:
                    return lhsMinutes < rhsMinutes
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    private func minutesSinceMidnight(_ time: String) -> Int? {
        let parts = time.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
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

enum JourneyUpdateOrdering {
    static func sorted(
        _ subscriptions: [NotificationSubscription],
        scheduledIDs: Set<String>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [NotificationSubscription] {
        subscriptions.enumerated()
            .sorted { lhs, rhs in
                let lhsDate = nextDate(
                    for: lhs.element,
                    isScheduled: scheduledIDs.contains(lhs.element.id),
                    now: now,
                    calendar: calendar
                )
                let rhsDate = nextDate(
                    for: rhs.element,
                    isScheduled: scheduledIDs.contains(rhs.element.id),
                    now: now,
                    calendar: calendar
                )
                switch (lhsDate, rhsDate) {
                case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                    return lhsDate < rhsDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    private static func nextDate(
        for subscription: NotificationSubscription,
        isScheduled: Bool,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        guard isScheduled else {
            guard subscription.activeUntil.map({ $0 > now }) ?? true else { return nil }
            return now
        }

        let enabledLegs = subscription.legs.filter(\.enabled)
        if subscription.scheduleKind == .oneOff || enabledLegs.contains(where: { $0.travelDate != nil }) {
            return enabledLegs.compactMap {
                nextOneOffDate(for: $0, now: now, calendar: calendar)
            }.min()
        }

        return enabledLegs.compactMap {
            nextRegularDate(
                for: $0,
                days: Set(subscription.daysOfWeek),
                now: now,
                calendar: calendar
            )
        }.min()
    }

    private static func nextRegularDate(
        for leg: NotificationLeg,
        days: Set<DayOfWeek>,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let startTime = timeComponents(from: leg.windowStart),
              let endTime = timeComponents(from: leg.windowEnd),
              !days.isEmpty else {
            return nil
        }

        let today = calendar.startOfDay(for: now)
        for dayOffset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: today),
                  let weekday = dayOfWeek(for: day, calendar: calendar),
                  days.contains(weekday),
                  let start = calendar.date(bySettingHour: startTime.hour, minute: startTime.minute, second: 0, of: day),
                  let end = calendar.date(bySettingHour: endTime.hour, minute: endTime.minute, second: 0, of: day) else {
                continue
            }
            if end >= now {
                return start
            }
        }
        return nil
    }

    private static func nextOneOffDate(
        for leg: NotificationLeg,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        guard let travelDate = leg.travelDate,
              let dateComponents = dateComponents(from: travelDate),
              let startTime = timeComponents(from: leg.windowStart),
              let endTime = timeComponents(from: leg.windowEnd) else {
            return nil
        }

        var startComponents = dateComponents
        startComponents.hour = startTime.hour
        startComponents.minute = startTime.minute
        var endComponents = dateComponents
        endComponents.hour = endTime.hour
        endComponents.minute = endTime.minute
        guard let start = calendar.date(from: startComponents),
              let end = calendar.date(from: endComponents),
              end >= now else {
            return nil
        }
        return start
    }

    private static func dayOfWeek(for date: Date, calendar: Calendar) -> DayOfWeek? {
        switch calendar.component(.weekday, from: date) {
        case 1: return .sun
        case 2: return .mon
        case 3: return .tue
        case 4: return .wed
        case 5: return .thu
        case 6: return .fri
        case 7: return .sat
        default: return nil
        }
    }

    private static func timeComponents(from value: String) -> (hour: Int, minute: Int)? {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }

    private static func dateComponents(from value: String) -> DateComponents? {
        let parts = value.split(separator: "-", maxSplits: 2)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        return DateComponents(year: year, month: month, day: day)
    }
}

enum JourneyUpdateSchedulePresentation {
    static func detail(
        for leg: NotificationLeg,
        subscription: NotificationSubscription,
        scheduled: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let window = "• \(leg.windowStart) - \(leg.windowEnd)"
        guard scheduled else { return window }

        let activeDays: String?
        if subscription.scheduleKind == .oneOff || leg.travelDate != nil {
            activeDays = leg.travelDate.flatMap {
                relativeTravelDate($0, now: now, calendar: calendar)
            }
        } else {
            activeDays = regularDays(subscription.daysOfWeek)
        }

        guard let activeDays, !activeDays.isEmpty else { return window }
        return "\(window) \(activeDays)"
    }

    static func regularDays(_ days: [DayOfWeek]) -> String? {
        let selected = Set(days)
        guard !selected.isEmpty else { return nil }
        if selected == Set(DayOfWeek.allCases) { return "every day" }
        if selected == Set([.mon, .tue, .wed, .thu, .fri]) { return "weekdays" }
        if selected == Set([.sat, .sun]) { return "weekends" }

        let names = DayOfWeek.allCases
            .filter(selected.contains)
            .map(pluralName(for:))
        if names.count == 1 { return names[0] }
        if names.count == 2 { return names.joined(separator: " and ") }
        return "\(names.dropLast().joined(separator: ", ")) and \(names.last!)"
    }

    static func relativeTravelDate(
        _ value: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard let date = date(from: value, calendar: calendar) else { return nil }
        let today = calendar.startOfDay(for: now)
        let travelDay = calendar.startOfDay(for: date)
        let dayOffset = calendar.dateComponents([.day], from: today, to: travelDay).day
        switch dayOffset {
        case 0: return "today"
        case 1: return "tomorrow"
        default:
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = .current
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }

    private nonisolated static func pluralName(for day: DayOfWeek) -> String {
        switch day {
        case .mon: return "Mondays"
        case .tue: return "Tuesdays"
        case .wed: return "Wednesdays"
        case .thu: return "Thursdays"
        case .fri: return "Fridays"
        case .sat: return "Saturdays"
        case .sun: return "Sundays"
        }
    }

    private static func date(from value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-", maxSplits: 2)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var components = DateComponents(year: year, month: month, day: day)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)
    }
}

private struct ProfileResolvedScheduledRoute {
    let group: JourneyGroup
    let reverseGroup: JourneyGroup?
}

private struct IdentifiableScheduledRoute: Identifiable {
    let id = UUID()
    let group: JourneyGroup
    let reverseGroup: JourneyGroup?
    let subscription: NotificationSubscription
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
        ProfileView()
            .environmentObject(NotificationSubscriptionStore.shared)
    }
}
