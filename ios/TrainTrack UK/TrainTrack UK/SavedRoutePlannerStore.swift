import Foundation
import Observation

struct SavedRouteQuery: Encodable, Hashable {
    let origin: String
    let destination: String
    let via: [String]
    var realtime = "apply"
    var time: String? = nil
    var id: String { ([origin] + via + [destination, realtime, time ?? "now"]).joined(separator: "-") }

    init(group: JourneyGroup) {
        origin = group.startStation.crs.uppercased()
        destination = group.endStation.crs.uppercased()
        via = group.viaStations.map { $0.crs.uppercased() }
    }

    enum CodingKeys: String, CodingKey { case id, origin, destination, via, realtime, time }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(origin, forKey: .origin)
        try values.encode(destination, forKey: .destination)
        try values.encode(via, forKey: .via)
        try values.encode(realtime, forKey: .realtime)
        try values.encodeIfPresent(time, forKey: .time)
    }
}

struct SavedRouteBoard: Decodable {
    let id: String
    let status: String
    let pollAfterMs: Double?
    var result: PlannerSearchResponse?
    let computedAt: Date?
    let expiresAt: Date?
    let error: PlannerError?
    var progress: SavedRouteBoardProgress? = nil
    var source: String? = nil
    var direct: JourneyDeparturesSnapshot? = nil
}

struct SavedRouteBoardProgress: Decodable {
    let phase: String
    var queuePosition: Int? = nil
    var queuedAt: Date? = nil
    var startedAt: Date? = nil
    var completedWindows: Int? = nil
    var totalWindows: Int? = nil
}

struct SavedRouteBoardsResponse: Decodable {
    let apiVersion: Int
    let boards: [SavedRouteBoard]
}

/// The v4 server has verified that this train serves every required stop.
/// Present it as one through service without changing the user's saved route.
enum SavedRouteDirectPresentation {
    static func throughGroup(_ group: JourneyGroup) -> JourneyGroup {
        let first = group.legs.first!
        let leg = Journey(id: first.id, groupId: group.id, legIndex: 0,
                          fromStation: group.startStation, toStation: group.endStation,
                          createdAt: first.createdAt, favorite: group.favorite)
        return JourneyGroup(id: group.id, legs: [leg])
    }

    static func time(_ departure: DepartureV2, useLiveTimes: Bool) -> String {
        useLiveTimes ? JourneyItineraryBuilder.departureDisplayTime(departure) : departure.departureTime.scheduled
    }

    static func departureDate(_ departure: DepartureV2, useLiveTimes: Bool, now: Date, observedAt: Date? = nil) -> Date? {
        PlannerTrainTracking.date(time(departure, useLiveTimes: useLiveTimes), near: departure.evidenceObservedAt ?? observedAt ?? now)
    }

    static func upcoming(_ departures: [DepartureV2], useLiveTimes: Bool, now: Date, observedAt: Date? = nil) -> [DepartureV2] {
        departures.filter {
            let delayedWithoutTime = useLiveTimes && $0.departureTime.estimated
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "delayed"
            let earliest = now.addingTimeInterval(delayedWithoutTime ? -2 * 3600 : -60)
            return departureDate($0, useLiveTimes: useLiveTimes, now: now, observedAt: observedAt).map { $0 >= earliest } ?? true
        }.sorted {
            let left = departureDate($0, useLiveTimes: useLiveTimes, now: now, observedAt: observedAt) ?? .distantFuture
            let right = departureDate($1, useLiveTimes: useLiveTimes, now: now, observedAt: observedAt) ?? .distantFuture
            return left == right ? $0.serviceID < $1.serviceID : left < right
        }
    }
}

enum SavedRouteBoardError: Error { case unsupported }

@MainActor
protocol SavedRouteBoardServing {
    var routeBoardsServerIdentity: String { get }
    func routeBoards(_ routes: [SavedRouteQuery]) async throws -> SavedRouteBoardsResponse
}

struct SavedRouteBoardState {
    var board: SavedRouteBoard?
    var message: String?
    var usesLegacyDepartures = false
    var nextRefresh = Date.distantPast
    var requestedAt: Date? = nil
    var waitingForCapacity = false
    var consecutiveFailures = 0
    var isRefreshing = false

    var hasPersistentFailure: Bool { consecutiveFailures >= 3 }
    var showsActivity: Bool { isRefreshing || isPending }

    var result: PlannerSearchResponse? { board?.result }
    var direct: JourneyDeparturesSnapshot? { board?.source == "direct" ? board?.direct : nil }
    var usesDirectDepartures: Bool { direct != nil }
    var isPending: Bool { (consecutiveFailures > 0 && !hasPersistentFailure) || board?.progress?.phase == "retrying" || waitingForCapacity || (board == nil && message == nil) || board?.status == "queued" || board?.status == "refreshing" }
    var isStale: Bool { board?.status != "ready" || consecutiveFailures > 0 || message != nil }

    func directAvailability(at now: Date = Date()) -> JourneyDataAvailability? {
        guard let direct else { return nil }
        let observed = direct.lastSuccessfulUpdate ?? direct.departures.compactMap(\.evidenceObservedAt).min()
        let expired = observed.map { now.timeIntervalSince($0) >= 90 } ?? false
        let status: JourneyDataStatus = (isStale || expired) && direct.dataStatus.severity < JourneyDataStatus.stale.severity
            ? .stale : direct.dataStatus
        return JourneyDataAvailability(status: status, lastSuccessfulUpdate: observed)
    }
}

/// Shared by saved-route screens; background refresh never adds a recent search.
@MainActor @Observable
final class SavedRoutePlannerStore {
    static let shared = SavedRoutePlannerStore()
    private(set) var states: [String: SavedRouteBoardState] = [:]
    private var laterQueries: [String: SavedRouteQuery] = [:]
    @ObservationIgnored private let client: any SavedRouteBoardServing
    @ObservationIgnored private var flights: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var firstRequestStarted: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var laterSearches: Set<String> = []
    @ObservationIgnored private let now: () -> Date

    init(client: (any SavedRouteBoardServing)? = nil, now: @escaping () -> Date = Date.init) {
        self.client = client ?? JourneyPlannerClient()
        self.now = now
    }

    private func key(_ query: SavedRouteQuery) -> String { client.routeBoardsServerIdentity + "|" + query.id }

    func query(for group: JourneyGroup) -> SavedRouteQuery {
        SavedRouteQuery(group: group)
    }

    func laterState(for group: JourneyGroup) -> SavedRouteBoardState? {
        guard let query = laterQueries[SavedRouteQuery(group: group).id] else { return nil }
        return states[key(query)]
    }

    func searchLater(for group: JourneyGroup) async {
        let routeID = SavedRouteQuery(group: group).id
        guard laterQueries[routeID] == nil else { return }

        var query = SavedRouteQuery(group: group)
        // Continue from the end of the primary six-hour timetable window. The
        // presentation layer merges this result with it and removes overlaps.
        query.time = PlannerTime.iso8601(now().addingTimeInterval(6 * 60 * 60))
        laterQueries[routeID] = query
        await performLaterSearch(query)
    }

    func retryLater(for group: JourneyGroup) async {
        guard let query = laterQueries[SavedRouteQuery(group: group).id] else { return }
        await performLaterSearch(query)
    }

    private func performLaterSearch(_ query: SavedRouteQuery) async {
        let queryKey = key(query)
        guard laterSearches.insert(queryKey).inserted else { return }
        defer { laterSearches.remove(queryKey) }

        for attempt in 0...2 {
            guard !Task.isCancelled else { return }
            if attempt == 0 { states[queryKey] = SavedRouteBoardState(requestedAt: now()) }
            if attempt > 0 {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
            while !Task.isCancelled {
                await refresh(queries: [query], force: true)
                guard let state = states[queryKey], state.isPending, state.consecutiveFailures == 0 else {
                    if states[queryKey]?.result != nil && states[queryKey]?.consecutiveFailures == 0 { return }
                    break
                }
                let pause = min(5, max(1, state.nextRefresh.timeIntervalSince(now())))
                do { try await Task.sleep(for: .seconds(pause)) }
                catch { return }
            }
        }
    }

    private func queries(for groups: [JourneyGroup]) -> [SavedRouteQuery] {
        var seen = Set<String>()
        return groups.map(query(for:)).filter { seen.insert($0.id).inserted }
    }

    func state(for group: JourneyGroup) -> SavedRouteBoardState {
        states[key(query(for: group))] ?? SavedRouteBoardState()
    }

    func watch(groups: [JourneyGroup]) async {
        guard !groups.isEmpty else { return }
        let queries = queries(for: groups)
        while !Task.isCancelled {
            await refresh(queries: queries)
            guard !Task.isCancelled else { return }
            let next = queries.compactMap { states[key($0)]?.nextRefresh }.min() ?? now().addingTimeInterval(20)
            do { try await Task.sleep(for: .seconds(min(20, max(1, next.timeIntervalSince(now()))))) }
            catch { return }
        }
    }

    func refresh(groups: [JourneyGroup], force: Bool = false) async {
        await refresh(queries: queries(for: groups), force: force)
    }

    private func refresh(queries: [SavedRouteQuery], force: Bool = false) async {
        let server = client.routeBoardsServerIdentity
        let requested = queries.filter { force || (states[key($0)]?.nextRefresh ?? .distantPast) <= now() }
        var pending = requested.compactMap { flights[key($0)] }
        let missing = requested.filter { flights[key($0)] == nil }
        for offset in stride(from: 0, to: missing.count, by: 8) {
            let batch = Array(missing[offset..<min(offset + 8, missing.count)])
            let keys = batch.map { server + "|" + $0.id }
            let trace = String(UUID().uuidString.prefix(8))
            for key in keys {
                var state = self.states[key] ?? SavedRouteBoardState()
                if state.requestedAt == nil { firstRequestStarted[key] = .now }
                state.requestedAt = state.requestedAt ?? now()
                state.isRefreshing = true
                self.states[key] = state
            }
            let task = Task { [weak self] in
                guard let self else { return }
                let started = ContinuousClock.now
                ClientPerf.log("savedRoutes.batch.start id=\(trace) routes=\(batch.count) force=\(force)")
                defer {
                    for key in keys {
                        self.flights[key] = nil
                        self.states[key]?.isRefreshing = false
                    }
                }
                guard self.client.routeBoardsServerIdentity == server else { return }
                do {
                    let response = try await self.client.routeBoards(batch)
                    try Task.checkCancellation()
                    ClientPerf.log("savedRoutes.batch.response id=\(trace) elapsedMs=\(ClientPerf.elapsedMilliseconds(since: started)) boards=\(response.boards.map { "\($0.source ?? "unknown"):\($0.status)" }.joined(separator: ","))")
                    guard [3, 4].contains(response.apiVersion) else { throw PlannerError(code: "INVALID_RESPONSE", message: "Journey options could not be read. Please try again.") }
                    for (query, key) in zip(batch, keys) {
                        guard var board = response.boards.first(where: { $0.id == query.id }) else {
                            self.fail(key: key, message: "Journey options were not returned. Please try again.")
                            continue
                        }
                        guard response.apiVersion == 3 || (["direct", "planned"].contains(board.source ?? "")
                            && !(board.source == "direct" && board.status == "ready" && board.direct == nil)) else {
                            self.fail(key: key, message: "Departure options could not be read. Please try again.")
                            continue
                        }
                        let previous = self.states[key]?.board
                        if board.source == "direct" {
                            board.result = nil
                            if board.direct == nil && previous?.source == "direct" { board.direct = previous?.direct }
                        } else {
                            board.direct = nil
                            if board.result == nil && previous?.source != "direct" { board.result = previous?.result }
                        }
                        let interval = min(20, max(1, (board.pollAfterMs ?? 20000) / 1000))
                        let waiting = board.error?.code == "SEARCH_BUSY"
                        let liveRefreshFailed = board.result?.journeys.contains { journey in
                            PlannerLivePresentation.warnings(for: journey).contains(where: PlannerLivePresentation.isRefreshFailureWarning)
                        } == true || (board.direct.map { $0.dataStatus != .live } ?? false)
                        let failures = (board.error != nil || liveRefreshFailed) && !waiting
                            ? (self.states[key]?.consecutiveFailures ?? 0) + 1
                            : (board.status == "ready" ? 0 : self.states[key]?.consecutiveFailures ?? 0)
                        if (board.result != nil || board.direct != nil), self.states[key]?.board?.result == nil,
                           self.states[key]?.board?.direct == nil, let requestStarted = self.firstRequestStarted[key] {
                            ClientPerf.log("savedRoutes.firstData route=\(query.origin)-\(query.destination) elapsedMs=\(ClientPerf.elapsedMilliseconds(since: requestStarted)) source=\(board.source ?? "unknown") status=\(board.status)")
                        }
                        if board.status == "ready" { self.firstRequestStarted[key] = nil }
                        self.states[key] = SavedRouteBoardState(board: board,
                            message: failures >= 3 ? board.error?.message ?? self.states[key]?.message : nil,
                            nextRefresh: self.now().addingTimeInterval(interval),
                            requestedAt: board.status == "ready" ? nil : self.states[key]?.requestedAt,
                            waitingForCapacity: waiting, consecutiveFailures: failures)
                    }
                } catch SavedRouteBoardError.unsupported {
                    ClientPerf.log("savedRoutes.batch.unsupported id=\(trace) elapsedMs=\(ClientPerf.elapsedMilliseconds(since: started))")
                    for key in keys {
                        self.states[key] = SavedRouteBoardState(message: "Journey planning is not available on this server. Showing saved-route departures.",
                            usesLegacyDepartures: true, nextRefresh: self.now().addingTimeInterval(300))
                    }
                } catch let error as PlannerError where error.code == "SEARCH_BUSY" {
                    ClientPerf.log("savedRoutes.batch.busy id=\(trace) elapsedMs=\(ClientPerf.elapsedMilliseconds(since: started))")
                    for key in keys {
                        var state = self.states[key] ?? SavedRouteBoardState()
                        state.message = nil
                        state.waitingForCapacity = true
                        state.nextRefresh = self.now().addingTimeInterval(5)
                        self.states[key] = state
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    ClientPerf.log("savedRoutes.batch.failed id=\(trace) elapsedMs=\(ClientPerf.elapsedMilliseconds(since: started)) errorType=\(type(of: error))")
                    for key in keys { self.fail(key: key, message: error.localizedDescription) }
                }
            }
            for key in keys { flights[key] = task }
            pending.append(task)
        }
        for task in pending { await task.value }
    }

    private func fail(key: String, message: String) {
        var state = states[key] ?? SavedRouteBoardState()
        state.consecutiveFailures += 1
        state.message = state.hasPersistentFailure ? message : nil
        state.waitingForCapacity = false
        state.nextRefresh = now().addingTimeInterval(20)
        states[key] = state
    }
}
