import SwiftUI
import ActivityKit

struct ScheduledPlannerJourney: Codable, Hashable {
    static let leadTimeChoices = [15, 30, 45, 60, 90, 120]
    var leadMinutes: Int = 60
    var showAllDepartures: Bool = false
    let legs: [Leg]

    private enum CodingKeys: String, CodingKey { case leadMinutes, showAllDepartures, legs }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        leadMinutes = try values.decode(Int.self, forKey: .leadMinutes)
        showAllDepartures = try values.decodeIfPresent(Bool.self, forKey: .showAllDepartures) ?? false
        legs = try values.decode([Leg].self, forKey: .legs)
    }

    struct Place: Codable, Hashable {
        let crs: String
        let name: String
    }

    struct Call: Codable, Hashable {
        let station: Place
        let arrival: Date?
        let departure: Date?
    }

    struct Leg: Codable, Hashable {
        let kind: String
        let mode: String
        let from: Place
        let to: Place
        let departure: Date
        let arrival: Date
        let uid: String?
        let originDate: String?
        let `operator`: String?
        let calls: [Call]
        var transferMinutes: Double = 0
        var isRail: Bool { kind == "vehicle" && mode == "rail" }
    }

    init(journey: PlannedJourney) {
        legs = journey.legs.map { leg in
            Leg(kind: leg.kind, mode: leg.mode,
                from: Place(crs: leg.from.crs, name: leg.from.name), to: Place(crs: leg.to.crs, name: leg.to.name),
                departure: leg.scheduledDeparture ?? leg.departure, arrival: leg.scheduledArrival ?? leg.arrival,
                uid: leg.uid ?? leg.tracking?.uid, originDate: leg.originDate, operator: leg.operator,
                calls: (leg.serviceCallingPoints ?? leg.callingPoints ?? []).map {
                    Call(station: Place(crs: $0.station.crs, name: $0.station.name),
                         arrival: $0.scheduledArrival ?? $0.arrival, departure: $0.scheduledDeparture ?? $0.departure)
                }, transferMinutes: [leg.transfer?.exitMinutes, leg.transfer?.travelMinutes, leg.transfer?.entryMinutes,
                    leg.transfer?.extraMinutes, leg.transfer?.interchangeMinutes].compactMap { $0 }.reduce(0, +))
        }
    }

    var departure: Date { legs.first(where: \.isRail)?.departure ?? .distantPast }
    var arrival: Date { legs.last?.arrival ?? departure }
    var startsAt: Date { departure.addingTimeInterval(-Double(leadMinutes) * 60) }
    var expiresAt: Date { arrival.addingTimeInterval(2 * 3600) }
    var title: String { "\(legs.first?.from.name ?? "") → \(legs.last?.to.name ?? "")" }
    var canSchedule: Bool {
        legs.contains(where: \.isRail) && legs.filter(\.isRail).allSatisfy {
            $0.uid?.isEmpty == false && $0.originDate != nil && $0.operator?.isEmpty == false
        }
    }
    func matches(_ other: ScheduledPlannerJourney) -> Bool { legs == other.legs }

    var notificationLegs: [NotificationLeg] {
        legs.filter(\.isRail).map { leg in
            NotificationLeg(from: leg.from.crs, to: leg.to.crs, fromName: leg.from.name, toName: leg.to.name,
                enabled: true, windowStart: PlannerTime.display(leg.departure), windowEnd: PlannerTime.display(leg.arrival),
                travelDate: Self.travelDate(leg.departure))
        }
    }

    private static func travelDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = PlannerTime.calendar
        formatter.timeZone = PlannerTime.calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct PlannerScheduleAction: View {
    let journey: PlannedJourney
    @EnvironmentObject private var store: NotificationSubscriptionStore
    @State private var showsSchedule = false
    private var plan: ScheduledPlannerJourney { ScheduledPlannerJourney(journey: journey) }
    private var existing: NotificationSubscription? {
        store.subscriptions.first { $0.plannerJourney?.matches(plan) == true }
    }

    var body: some View {
        if plan.canSchedule && (plan.departure > Date() || existing != nil) {
            Button { showsSchedule = true } label: {
                Label(existing == nil ? "Schedule journey" : "Journey scheduled", systemImage: "calendar.badge.clock")
            }
            .accessibilityIdentifier("planner.detail.schedule")
            .sheet(isPresented: $showsSchedule) {
                PlannerJourneyScheduleView(plan: existing?.plannerJourney ?? plan, existing: existing)
            }
            .task { await store.refresh() }
        }
    }
}

struct PlannerJourneyScheduleView: View {
    @State var plan: ScheduledPlannerJourney
    let existing: NotificationSubscription?
    @EnvironmentObject private var store: NotificationSubscriptionStore
    @EnvironmentObject private var activities: LiveActivityManager
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @State private var confirmCancellation = false

    private var current: NotificationSubscription? {
        existing.flatMap { saved in store.subscriptions.first { $0.id == saved.id } } ?? existing
    }
    private var hasStarted: Bool { current?.plannerStatus != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(plan.title).font(.headline)
                    Text(plan.departure, format: .dateTime.weekday().day().month().hour().minute())
                    ForEach(Array(plan.legs.enumerated()), id: \.offset) { index, leg in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1). \(leg.isRail ? "Train" : "Transfer"): \(leg.from.name) → \(leg.to.name)")
                            Text(PlannerTime.displayRange(from: leg.departure, to: leg.arrival))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Picker("Show before departure", selection: $plan.leadMinutes) {
                        ForEach(ScheduledPlannerJourney.leadTimeChoices, id: \.self) { minutes in
                            Text(minutes == 60 ? "1 hour" : minutes == 120 ? "2 hours" : "\(minutes) minutes").tag(minutes)
                        }
                    }
                    .disabled(hasStarted || busy)
                    .accessibilityIdentifier("planner.schedule.lead-time")
                    if let status = current?.plannerStatus {
                        Text(statusText(status))
                    } else if plan.startsAt <= Date() {
                        Text("Live Activity starts now.")
                    } else {
                        Text("Live Activity starts \(plan.startsAt, format: .dateTime.weekday().day().month().hour().minute()).")
                    }
                } footer: {
                    Text("Live Activities must be enabled and your device needs an internet connection. An existing active journey will keep priority.")
                }
                Section {
                    Toggle("Show all departures", isOn: $plan.showAllDepartures)
                        .disabled(busy)
                        .accessibilityIdentifier("planner.schedule.all-departures")
                } footer: {
                    Text("Show the next departures for the current train leg instead of only the selected service. You can change this while the Live Activity is running. Its scheduled start time stays the same.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("planner.schedule.error") }
                }
                if !hasStarted || existing != nil {
                    Section {
                        Button(action: save) {
                            if busy { ProgressView("Saving…") }
                            else { Text(existing != nil ? "Save changes" : plan.startsAt <= Date() ? "Start now" : "Schedule journey") }
                        }
                        .disabled(busy || (existing == nil && plan.departure <= Date()))
                        .accessibilityIdentifier("planner.schedule.save")
                    }
                }
                if existing != nil {
                    Section {
                        Button("Cancel scheduled journey", role: .destructive) { confirmCancellation = true }
                            .disabled(busy)
                            .accessibilityIdentifier("planner.schedule.cancel")
                    }
                }
            }
            .environment(\.timeZone, PlannerTime.calendar.timeZone)
            .navigationTitle(existing == nil ? "Schedule journey" : "Scheduled journey")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
            .confirmationDialog("Cancel this scheduled journey and its Live Activity?", isPresented: $confirmCancellation, titleVisibility: .visible) {
                Button("Cancel journey", role: .destructive, action: cancel)
            }
        }
        .onDisappear { operation?.cancel() }
        .task { await store.refresh() }
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "starting": return "Requesting Live Activity…"
        case "retry": return "Live Activity temporarily unavailable. Retrying before departure."
        case "unconfirmed": return "Live Activity delivery could not be confirmed. Check your Lock Screen before scheduling again."
        case "started": return "Live Activity requested."
        case "completed": return "Journey complete."
        case "ended": return "Live Activity ended."
        case "conflict": return "Not started: another journey was already being tracked."
        case "expired": return "Not started before departure."
        default: return "Live Activity could not be started. Cancel this schedule and try again before departure."
        }
    }

    private func save() {
        busy = true
        error = nil
        operation = Task { @MainActor in
            defer { busy = false }
            if let current, hasStarted || plan.leadMinutes == current.plannerJourney?.leadMinutes {
                do {
                    _ = try await store.updatePlannerDisplay(id: current.id, showAllDepartures: plan.showAllDepartures)
                    dismiss()
                } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                return
            }
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                error = "Enable Live Activities for TrainTrack UK in Settings to schedule this journey."
                return
            }
            guard await NotificationAuthorizationManager.ensureAuthorized() else {
                error = "Enable notifications in Settings to schedule this journey."
                return
            }
            guard await activities.ensurePushToStartTokenRegistered(),
                  let token = await NotificationPushTokenStore.waitForToken(timeoutSeconds: 6) else {
                error = "Live Activities are not ready yet. Please try again in a moment."
                return
            }
            #if DEBUG
            let sandbox = true
            #else
            let sandbox = false
            #endif
            do {
                try Task.checkCancellation()
                let request = NotificationSubscriptionRequest(subscriptionId: existing?.id,
                    deviceId: DeviceIdentity.deviceToken, pushToken: token,
                    routeKey: "planner:" + plan.legs.filter(\.isRail).map { "\($0.from.crs)-\($0.to.crs)" }.joined(separator: "|"),
                    scheduleKind: .oneOff, daysOfWeek: [], notificationTypes: NotificationPreferences.effectiveTypes(for: .scheduled),
                    legs: plan.notificationLegs, windowStart: nil, windowEnd: nil, from: nil, to: nil, fromName: nil, toName: nil,
                    useSandbox: sandbox, muteOnArrival: false, liveSessionOrigin: nil, activeUntil: nil, plannerJourney: plan)
                let saved = try await store.upsert(request)
                guard saved.plannerJourney != nil else {
                    try? await store.delete(id: saved.id)
                    error = "This server needs an update before it can schedule a selected train."
                    return
                }
                dismiss()
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func cancel() {
        guard let existing else { return }
        busy = true
        error = nil
        operation = Task { @MainActor in
            defer { busy = false }
            do { try await store.delete(id: existing.id); dismiss() }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct ScheduledPlannerJourneysSection: View {
    var searchText = ""
    let onSelect: (NotificationSubscription) -> Void
    @EnvironmentObject private var store: NotificationSubscriptionStore
    private var schedules: [NotificationSubscription] {
        store.subscriptions.filter {
            guard let plan = $0.plannerJourney else { return false }
            return searchText.isEmpty || plan.title.localizedCaseInsensitiveContains(searchText)
        }.sorted { ($0.plannerJourney?.departure ?? .distantFuture) < ($1.plannerJourney?.departure ?? .distantFuture) }
    }

    var body: some View {
        if !schedules.isEmpty {
            Section {
                Text("Scheduled")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.88))
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                ForEach(schedules) { schedule in
                    if let plan = schedule.plannerJourney {
                        Button { onSelect(schedule) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(plan.title)
                                        .font(.headline)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                Divider()
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(plan.departure, format: .dateTime.weekday().day().month().hour().minute())
                                        .font(.subheadline)
                                    Text("Live Activity · \(plan.leadMinutes) min before departure")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .journeyCardSurface()
                            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .accessibilityHint("Opens scheduled journey settings.")
                        .accessibilityIdentifier("planner.scheduled.\(schedule.id)")
                    }
                }
            }
            .environment(\.timeZone, PlannerTime.calendar.timeZone)
        }
    }
}
