import SwiftUI

@MainActor enum PlannerTrainTracking {
    static func canStart(_ departure: DepartureV2, details: ServiceDetails, leg: PlannedJourney.Leg,
                         selectedServer: String, currentServer: String, now: Date) -> Bool {
        selectedServer == currentServer && leg.departure >= now
            && matches(departure, details: details, leg: leg, now: now)
    }

    static func matchesBoard(_ departure: DepartureV2, leg: PlannedJourney.Leg, now: Date) -> Bool {
        guard departure.hasProviderServiceID, departure.serviceType == "train",
              let observed = departure.evidenceObservedAt,
              let scheduled = date(departure.departureTime.scheduled, near: observed),
              (-2 * 3600...4 * 3600).contains(scheduled.timeIntervalSince(observed)),
              abs(scheduled.timeIntervalSince(leg.scheduledDeparture ?? leg.departure)) < 30 else { return false }
        return operatorMatches(name: departure.operator, code: departure.operatorCode, leg: leg)
    }

    private static func operatorMatches(name: String?, code: String?, leg: PlannedJourney.Leg) -> Bool {
        guard let expected = leg.operator, !expected.isEmpty else { return false }
        let branding = ServerConfigStore.shared.operatorBranding
        let planned = OperatorBrandingResolver.resolve(name: expected, code: expected, in: branding)
        let actual = OperatorBrandingResolver.resolve(name: name, code: code, in: branding)
        return (planned != nil && planned?.id == actual?.id)
            || expected.caseInsensitiveCompare(code ?? name ?? "") == .orderedSame
    }
    static func matches(_ departure: DepartureV2, details: ServiceDetails, leg: PlannedJourney.Leg, now: Date) -> Bool {
        guard leg.kind == "vehicle", leg.mode == "rail", leg.live?.isCancelled != true,
              !departure.isCancelled, details.isCancelled != true,
              let observed = departure.evidenceObservedAt, now.timeIntervalSince(observed) < 90,
              observed <= now.addingTimeInterval(30),
              let generated = try? PlannerTime.decoder().decode(Date.self, from: JSONEncoder().encode(details.generatedAt)),
              now.timeIntervalSince(generated) < 90, generated <= now.addingTimeInterval(30),
              operatorMatches(name: details.operator, code: details.operatorCode, leg: leg),
              matchesBoard(departure, leg: leg, now: now) else { return false }

        let hasVerifiedReference: Bool
        if let reference = leg.tracking {
            guard reference.providerServiceId == departure.serviceID,
                  reference.station == leg.from.crs, !reference.uid.isEmpty,
                  reference.originDate == leg.originDate,
                  now.timeIntervalSince(reference.verifiedAt) < 90,
                  reference.verifiedAt <= now.addingTimeInterval(30) else { return false }
            if let uid = leg.uid, reference.uid != uid { return false }
            hasVerifiedReference = true
        } else { hasVerifiedReference = false }

        // A provider reference is not a timetable ID. Without a verified reference,
        // require the complete ordered passenger pattern as well as a unique board match.
        let planned = leg.serviceCallingPoints ?? []
        if !hasVerifiedReference && planned.count < 2 { return false }
        let matchingBranches = details.stationBranches.filter { branch in
            guard let from = branch.firstIndex(where: { $0.crs == leg.from.crs }),
                  let to = branch.lastIndex(where: { $0.crs == leg.to.crs }), from < to,
                  branch[from].isCancelled != true, branch[to].isCancelled != true,
                  matchesTime(branch[from].st, scheduled: leg.scheduledDeparture ?? leg.departure),
                  matchesDestinationTime(branch[to].st, leg: leg) else { return false }
            if hasVerifiedReference { return true }
            guard planned.count == branch.count else { return false }
            return zip(planned, branch).allSatisfy { expected, actual in
                guard expected.station.crs == actual.crs else { return false }
                let times = [expected.scheduledDeparture ?? expected.departure, expected.scheduledArrival ?? expected.arrival].compactMap { $0 }
                return !times.isEmpty && times.contains { matchesTime(actual.st, scheduled: $0) }
            }
        }
        return matchingBranches.count == 1
    }

    private static func matchesTime(_ value: String, scheduled: Date) -> Bool {
        guard let date = date(value, near: scheduled) else { return false }
        return abs(date.timeIntervalSince(scheduled)) < 30
    }

    private static func matchesDestinationTime(_ value: String, leg: PlannedJourney.Leg) -> Bool {
        if matchesTime(value, scheduled: leg.scheduledArrival ?? leg.arrival) { return true }
        let stop = (leg.callingPoints ?? leg.serviceCallingPoints ?? []).last { $0.station.crs == leg.to.crs }
        guard let departure = stop?.scheduledDeparture ?? stop?.departure else { return false }
        return matchesTime(value, scheduled: departure)
    }

    static func date(_ value: String, near reference: Date) -> Date? {
        let parts = value.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (-1...1).compactMap { offset -> Date? in
            guard let day = PlannerTime.calendar.date(byAdding: .day, value: offset, to: reference) else { return nil }
            let calendar = PlannerTime.calendar
            let first = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                matchingPolicy: .strict, repeatedTimePolicy: .first)
            let last = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day,
                matchingPolicy: .strict, repeatedTimePolicy: .last)
            guard let first, first == last, calendar.isDate(first, inSameDayAs: day) else { return nil }
            return first
        }.filter { abs($0.timeIntervalSince(reference)) < 12 * 3600 }
            .min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
    }

    static func resolve(_ leg: PlannedJourney.Leg) async throws -> (departure: DepartureV2, details: ServiceDetails) {
        let selectedServer = ApiHostPreference.currentBaseURL
        let network = NetworkServicePhone.shared
        let boards = try await network.fetchDeparturesAggregated(pairs: [(leg.from.crs, leg.to.crs)],
            requireFresh: true, timeout: 8)
        try Task.checkCancellation()
        guard selectedServer == ApiHostPreference.currentBaseURL else { throw unavailable }
        let candidates = (boards["\(leg.from.crs)_\(leg.to.crs)"]?.departures ?? []).filter {
            matchesBoard($0, leg: leg, now: Date()) && !$0.isCancelled
        }
        guard !candidates.isEmpty, candidates.count <= 4 else { throw unavailable }
        let details = try await network.fetchServiceDetailsAggregated(ids: candidates.map(\.serviceID),
            context: ServiceDetailsLookupContext(fromCRS: leg.from.crs, toCRS: leg.to.crs, originCRS: nil,
                operator: leg.operator, destinationCRSs: [leg.to.crs], length: nil), timeout: 8)
        try Task.checkCancellation()
        let verified = candidates.filter { departure in
            details[departure.serviceID].map { matches(departure, details: $0, leg: leg, now: Date()) } ?? false
        }
        guard selectedServer == ApiHostPreference.currentBaseURL,
              verified.count == 1, let selected = verified.first, let detail = details[selected.serviceID] else { throw unavailable }
        return (selected, detail)
    }

    static var unavailable: PlannerError {
        PlannerError(code: "TRAIN_UNVERIFIED", message: "This train could not be confirmed for tracking. Refresh the journey options or try again nearer departure.")
    }
}

struct PlannerTrainTrackingButton: View {
    let leg: PlannedJourney.Leg
    @EnvironmentObject private var departures: DeparturesStore
    @EnvironmentObject private var notifications: NotificationSubscriptionStore
    @EnvironmentObject private var activities: LiveActivityManager
    @EnvironmentObject private var router: TabRouter
    @AppStorage("liveActivityDurationMinutes") private var duration = 60
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                busy = true
                error = nil
                task = Task {
                    defer { busy = false }
                    do {
                        let selectedServer = ApiHostPreference.currentBaseURL
                        let verified = try await PlannerTrainTracking.resolve(leg)
                        if StationsService.shared.stations.isEmpty { try await StationsService.shared.loadStations() }
                        try Task.checkCancellation()
                        guard let from = StationsService.shared.stations.first(where: { $0.crs == leg.from.crs }),
                              let to = StationsService.shared.stations.first(where: { $0.crs == leg.to.crs }) else {
                            throw PlannerTrainTracking.unavailable
                        }
                        let journey = Journey(fromStation: from, toStation: to)
                        let group = JourneyGroup(id: journey.groupId, legs: [journey])
                        departures.recordVerifiedService(verified.departure, details: verified.details, fromCRS: leg.from.crs, toCRS: leg.to.crs)
                        let started = await JourneyUpdateActions.start(group: group, scheduledSubscription: nil,
                            liveSession: nil, liveActivityDurationMinutes: duration, notificationStore: notifications,
                            activityManager: activities, departuresStore: departures, preferredServiceID: verified.departure.serviceID,
                            validatePreferredService: {
                                guard let current = departures.departures(for: journey).first(where: { $0.serviceID == verified.departure.serviceID }),
                                      let details = departures.serviceDetailsById[current.serviceID] else { return false }
                                return PlannerTrainTracking.canStart(current, details: details, leg: leg,
                                    selectedServer: selectedServer, currentServer: ApiHostPreference.currentBaseURL, now: Date())
                            })
                        if started { router.selected = .inProgress }
                        else if !Task.isCancelled { error = activities.lastMessage ?? "Train tracking could not be started. Please try again." }
                    } catch {
                        if !Task.isCancelled { self.error = error.localizedDescription }
                    }
                }
            } label: {
                if busy { ProgressView("Confirming train…") }
                else { Label("Track this train", systemImage: "location.fill") }
            }
            .disabled(busy || leg.live?.isCancelled == true)
            .accessibilityIdentifier("planner.track.\(leg.from.crs).\(leg.to.crs)")
            Text("Tracks this train from \(leg.from.name) to \(leg.to.name). Other trains in this itinerary are tracked separately.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.primary) }
        }
        .onDisappear { task?.cancel() }
    }
}
