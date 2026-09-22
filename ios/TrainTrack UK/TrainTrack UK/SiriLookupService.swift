import Foundation

nonisolated enum SiriLookupError: Error, LocalizedError {
    case unavailable
    case timeout

    var errorDescription: String? {
        "Live train information is unavailable right now. Please try again shortly."
    }
}

@MainActor
final class SiriLookupService {
    static let shared = SiriLookupService()

    private let clock: @Sendable () -> Date
    private let deadlineSeconds: Double
    private let fetchBoard: @MainActor (Station, Station) async throws -> JourneyDeparturesSnapshot
    private let fetchDetails: @MainActor ([String]) async throws -> [String: ServiceDetails]
    private let loadStations: @MainActor () async throws -> [Station]
    private let readActive: @MainActor () -> ActiveJourneyHistoryCheckpoint?
    private let recordOutcome: @MainActor (String, String?, Double) -> Void

    init(
        clock: @escaping @Sendable () -> Date = { Date() },
        deadlineSeconds: Double = 8,
        fetchBoard: @escaping @MainActor (Station, Station) async throws -> JourneyDeparturesSnapshot = { from, to in
            let response = try await NetworkServicePhone.shared.fetchDeparturesAggregated(
                pairs: [(from.crs, to.crs)], requireFresh: true, timeout: 8
            )
            guard let snapshot = response["\(from.crs)_\(to.crs)"] else { throw SiriLookupError.unavailable }
            return snapshot
        },
        fetchDetails: @escaping @MainActor ([String]) async throws -> [String: ServiceDetails] = { ids in
            // No context: context-based lookup can substitute an associated service.
            try await NetworkServicePhone.shared.fetchServiceDetailsAggregated(ids: ids, timeout: 8)
        },
        loadStations: @escaping @MainActor () async throws -> [Station] = {
            try await StationsService.shared.loadStations(timeout: 8)
            return StationsService.shared.stations
        },
        readActive: @escaping @MainActor () -> ActiveJourneyHistoryCheckpoint? = {
            JourneyTrackingCheckpointStore.activeJourney()
        },
        recordOutcome: @escaping @MainActor (String, String?, Double) -> Void = { outcome, failure, duration in
            ClientDiagnosticsLogger.log("siri", "lookup", metadata: [
                "outcome": outcome, "failure": failure, "duration_ms": duration
            ])
        }
    ) {
        self.clock = clock
        self.deadlineSeconds = deadlineSeconds
        self.fetchBoard = fetchBoard
        self.fetchDetails = fetchDetails
        self.loadStations = loadStations
        self.readActive = readActive
        self.recordOutcome = recordOutcome
    }

    func lookup(from: Station, to: Station) async throws -> SiriLookupResult {
        let route = "\(from.name) to \(to.name)"
        guard from.crs.caseInsensitiveCompare(to.crs) != .orderedSame else {
            return SiriLookupResult(dialog: "Choose two different stations.", routeLabel: route,
                                    departures: [], freshnessLabel: "Invalid route", outcome: .invalidRoute)
        }
        return try await performResult(routeLabel: route) { [self] in
            let snapshot = try await fetchBoard(from, to)
            try Task.checkCancellation()
            let initial = SiriDeparturePolicy.result(snapshot: snapshot, from: from, to: to, now: clock())
            guard !initial.departures.isEmpty else { return initial }
            // Verify calling/cancellation state through the same detail endpoint used
            // by the app. Cap the sequence; a partial result never proves no trains run.
            let ids = Array(snapshot.departures.filter { $0.hasProviderServiceID && !$0.isCancelled }
                .prefix(12).map(\.serviceID))
            let details = try await fetchDetails(ids)
            return SiriDeparturePolicy.result(snapshot: snapshot, from: from, to: to, now: clock(),
                                               details: details, requireDetails: true)
        }
    }

    func stations(matching query: String?) async throws -> [Station] {
        do {
            let all = try await withDeadline { [self] in try await loadStations() }
            try Task.checkCancellation()
            if let query, !StationsService.normalizedSearchText(query).isEmpty {
                return StationsService.search(query, in: all, limit: 20)
            }
            // No location or journey-tracking initialization for a station prompt.
            let savedCodes = SiriRouteStore.shared.routes.flatMap { [$0.origin.crs, $0.destination.crs] }
            let byCode = Dictionary(all.map { ($0.crs, $0) }, uniquingKeysWith: { first, _ in first })
            var seen = Set<String>()
            let relevant = savedCodes.compactMap { byCode[$0] }.filter { seen.insert($0.crs).inserted }
            return Array((relevant + all.sorted { $0.name < $1.name }.filter { seen.insert($0.crs).inserted }).prefix(20))
        } catch {
            try rethrowCancellation(error)
            throw SiriLookupError.unavailable
        }
    }

    func stations(identifiers: [String]) async throws -> [Station] {
        do {
            let all = try await withDeadline { [self] in try await loadStations() }
            let byCode = Dictionary(all.map { ($0.crs.uppercased(), $0) }, uniquingKeysWith: { first, _ in first })
            return identifiers.prefix(100).compactMap { byCode[$0.uppercased()] }
        } catch {
            try rethrowCancellation(error)
            throw SiriLookupError.unavailable
        }
    }

    func resolveDeparture(id: String) async throws -> SiriDeparture? {
        try await resolveDepartures(ids: [id]).first
    }

    func resolveDepartures(ids: [String]) async throws -> [SiriDeparture] {
        let references = ids.prefix(3).compactMap(SiriDepartureReference.init(id:)).filter {
            abs($0.scheduledDeparture.timeIntervalSince(clock())) < 24 * 3600
        }
        guard !references.isEmpty else { return [] }
        do {
            return try await withDeadline { [self] in
                let stations = try await loadStations()
                let byCode = Dictionary(stations.map { ($0.crs, $0) }, uniquingKeysWith: { first, _ in first })
                let details = try await fetchDetails(references.map(\.serviceID))
                return try await withThrowingTaskGroup(of: SiriDeparture?.self) { group in
                    for reference in references {
                        guard let from = byCode[reference.originCRS], let to = byCode[reference.destinationCRS] else { continue }
                        group.addTask { @MainActor [self] in
                            let board = try await fetchBoard(from, to)
                            let exact = JourneyDeparturesSnapshot(
                                departures: board.departures.filter { $0.serviceID == reference.serviceID },
                                dataStatus: board.dataStatus, lastSuccessfulUpdate: board.lastSuccessfulUpdate,
                                siri: board.siri
                            )
                            let result = SiriDeparturePolicy.result(snapshot: exact, from: from, to: to, now: clock(),
                                                                   details: details, requireDetails: true)
                            return result.departures.first { $0.id == reference.id }
                        }
                    }
                    var departures: [SiriDeparture] = []
                    for try await departure in group {
                        if let departure { departures.append(departure) }
                    }
                    return references.compactMap { reference in departures.first { $0.id == reference.id } }
                }
            }
        } catch {
            try rethrowCancellation(error)
            // An expired/unresolvable entity must not silently become another train.
            return []
        }
    }

    func trackedJourneyStatus() async throws -> SiriLookupResult {
        try await trackedResult(platformOnly: false)
    }

    func trackedJourneyPlatform() async throws -> SiriLookupResult {
        try await trackedResult(platformOnly: true)
    }

    private func trackedResult(platformOnly: Bool) async throws -> SiriLookupResult {
        try Task.checkCancellation()
        guard let active = readActive(), active.plannedStations.count >= 2,
              active.phase != .atInterchange, active.phase != .matchingService,
              let leg = active.currentLeg, leg.outcome == .active,
              let serviceID = leg.serviceID, !serviceID.isEmpty,
              clock().timeIntervalSince(active.detectedDepartureAt) >= -60,
              clock().timeIntervalSince(active.detectedDepartureAt) < 24 * 3600 else {
            return SiriLookupResult(dialog: "You don't have a train selected for tracking.",
                                    routeLabel: "Tracked journey", departures: [], freshnessLabel: "", outcome: .noTrackedTrain)
        }
        let route = "\(leg.fromStation.name) to \(leg.toStation.name)"
        return try await performResult(routeLabel: route) { [self] in
            let response = try await fetchDetails([serviceID])
            try Task.checkCancellation()
            guard let current = readActive(), current.id == active.id,
                  current.currentLeg?.id == leg.id, current.currentLeg?.serviceID == serviceID,
                  current.phase != .atInterchange else {
                return SiriLookupResult(dialog: "Your tracked train changed. Please ask again.",
                                        routeLabel: route, departures: [], freshnessLabel: "")
            }
            guard let details = response[serviceID],
                  SiriRailTime.isFresh(SiriRailTime.parseISO(details.generatedAt), now: clock()) else {
                return .unavailable(routeLabel: route)
            }
            let freshness = "Live snapshot · London time"
            if details.isCancelled == true {
                return SiriLookupResult(dialog: "Your tracked service from \(leg.fromStation.name) to \(leg.toStation.name) is cancelled.",
                                        routeLabel: route, departures: [], freshnessLabel: freshness)
            }
            guard let calls = SiriDeparturePolicy.trackedCalls(details: details, from: leg.fromStation.crs, to: leg.toStation.crs) else {
                return SiriLookupResult(dialog: "I couldn't confirm that your tracked train still calls at \(leg.toStation.name).",
                                        routeLabel: route, departures: [], freshnessLabel: freshness)
            }
            let destination = calls.destination
            if destination.isCancelledAtStation {
                return SiriLookupResult(dialog: "Your tracked train's call at \(leg.toStation.name) is cancelled.",
                                        routeLabel: route, departures: [], freshnessLabel: freshness)
            }
            let platform = SiriDeparturePolicy.confirmedPlatform(calls.boarding.platform)
            let status: String
            if SiriDeparturePolicy.hasActual(destination.at) {
                status = "Your tracked train has arrived at \(leg.toStation.name)."
            } else if destination.et == "Delayed" {
                status = "Your tracked train to \(leg.toStation.name) is delayed, with no expected arrival time yet."
            } else if let estimate = destination.et, estimate == "On time" || !SiriRailTime.candidates(estimate, near: clock()).isEmpty {
                let time = estimate == "On time" ? destination.st : estimate
                status = "Your tracked train is expected at \(leg.toStation.name) at \(time) London time."
            } else {
                status = "Your train is being tracked, but its expected arrival time at \(leg.toStation.name) is unavailable."
            }
            let dialog = platformOnly
                ? platform.map { "The recorded boarding platform for your tracked train at \(leg.fromStation.name) is platform \(SiriResponseFormatter.platform($0))." }
                    ?? "There is no confirmed boarding platform available for your tracked train at \(leg.fromStation.name)."
                : status
            var departures: [SiriDeparture] = []
            if let scheduled = leg.scheduledDepartureAt {
                let reference = SiriDepartureReference(serviceID: serviceID, originCRS: leg.fromStation.crs,
                                                      destinationCRS: leg.toStation.crs, scheduledDeparture: scheduled)
                departures = [SiriDeparture(id: reference.id, originCRS: leg.fromStation.crs, originName: leg.fromStation.name,
                                            destinationCRS: leg.toStation.crs, destinationName: leg.toStation.name,
                                            serviceID: serviceID, operatingDate: nil, scheduledDeparture: scheduled,
                                            expectedDeparture: nil, platform: platform, statusLabel: status,
                                            transportLabel: details.serviceType == "bus" ? "Replacement bus" : "Train",
                                            freshnessLabel: freshness,
                                            providerObservedAt: SiriRailTime.parseISO(details.generatedAt), clientFetchedAt: clock())]
            }
            return SiriLookupResult(dialog: dialog, routeLabel: route, departures: departures, freshnessLabel: freshness)
        }
    }

    private func performResult(routeLabel: String,
                               operation: @escaping @MainActor @Sendable () async throws -> SiriLookupResult) async throws -> SiriLookupResult {
        let started = ContinuousClock.now
        do {
            let result = try await withDeadline(operation: operation)
            try Task.checkCancellation()
            logResult(result.outcome.rawValue, started: started)
            return result
        } catch {
            try rethrowCancellation(error)
            logResult("unavailable", started: started, failure: failureKind(error))
            return .unavailable(routeLabel: routeLabel)
        }
    }

    private func withDeadline<Value: Sendable>(
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let nanoseconds = UInt64(max(0, min(deadlineSeconds, 8)) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                throw SiriLookupError.timeout
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw SiriLookupError.unavailable }
            return value
        }
    }

    private func rethrowCancellation(_ error: Error) throws {
        if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
            throw CancellationError()
        }
    }

    private func failureKind(_ error: Error) -> String {
        if case SiriLookupError.timeout = error { return "timeout" }
        if let error = error as? URLError { return error.code == .timedOut ? "timeout" : "connectivity" }
        if case PhoneNetworkError.httpStatus(let status) = error {
            if status == 401 || status == 403 { return "authentication" }
            if status == 429 { return "rate_limited" }
            return "server"
        }
        return error is DecodingError ? "malformed" : "unavailable"
    }

    private func logResult(_ outcome: String, started: ContinuousClock.Instant, failure: String? = nil) {
        let duration = started.duration(to: .now).components
        recordOutcome(outcome, failure,
                      Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
    }
}
