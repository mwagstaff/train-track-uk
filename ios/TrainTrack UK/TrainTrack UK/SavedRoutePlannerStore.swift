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
    var searchedWindow: PlannerSearchResponse.Window? = nil
    var reachedSearchLimit = false
    var isSearchingLater = false

    var hasPersistentFailure: Bool { consecutiveFailures >= 3 }
    var showsActivity: Bool { isRefreshing || isPending }

    var result: PlannerSearchResponse? { board?.result }
    var direct: JourneyDeparturesSnapshot? { board?.source == "direct" ? board?.direct : nil }
    var usesDirectDepartures: Bool { direct != nil }
    var hasPlannedResult: Bool { !usesLegacyDepartures && !usesDirectDepartures && result != nil }
    var isPending: Bool { isSearchingLater || (consecutiveFailures > 0 && !hasPersistentFailure) || board?.progress?.phase == "retrying" || waitingForCapacity || (board == nil && message == nil) || board?.status == "queued" || board?.status == "refreshing" }

    var emptySearchMessage: String {
        let window = searchedWindow ?? result.map {
            PlannerSearchResponse.Window(from: max($0.search.time, $0.search.window.from), to: $0.search.window.to)
        }
        guard result?.search.searchTruncated != true, let window, window.to > window.from else {
            return "The search could not check the full time window. Try again."
        }
        let minutes = Int((window.to.timeIntervalSince(window.from) / 60).rounded(.up))
        let hours = minutes / 60
        let remainder = minutes % 60
        let duration = remainder == 0 ? "\(hours) \(hours == 1 ? "hour" : "hours")"
            : hours == 0 ? "\(minutes) minutes" : "\(hours)h \(remainder)m"
        return "No journeys found in the next \(duration)."
    }

    /// Boards pass through "refreshing" every live check, single requests fail, and routine
    /// refreshes leave data up to ~80s old. None of that is an outage: only failing refreshes
    /// that leave data on screen past this age are worth telling the traveller about.
    static let outageDataAge: TimeInterval = 120

    func hasSustainedOutage(observedAt observed: Date?, at now: Date) -> Bool {
        guard consecutiveFailures > 0 else { return false }
        return observed.map { now.timeIntervalSince($0) >= Self.outageDataAge } ?? hasPersistentFailure
    }

    func directAvailability(at now: Date = Date()) -> JourneyDataAvailability? {
        guard let direct else { return nil }
        let observed = direct.lastSuccessfulUpdate ?? direct.departures.compactMap(\.evidenceObservedAt).min()
        let status: JourneyDataStatus = hasSustainedOutage(observedAt: observed, at: now)
            && direct.dataStatus.severity < JourneyDataStatus.stale.severity ? .stale : direct.dataStatus
        return JourneyDataAvailability(status: status, lastSuccessfulUpdate: observed)
    }
}

/// Shared by saved-route screens; background refresh never adds a recent search.
@MainActor @Observable
final class SavedRoutePlannerStore {
    static let shared = SavedRoutePlannerStore()
    private(set) var states: [String: SavedRouteBoardState] = [:]
    private struct LaterSearch {
        var query: SavedRouteQuery
        let from: Date
        var searchedUntil: Date
        var isSearching = false
        var finished = false
        var message: String? = nil
        var limit: Date { from.addingTimeInterval(24 * 60 * 60) }
    }
    private var laterQueries: [String: LaterSearch] = [:]
    @ObservationIgnored private let client: any SavedRouteBoardServing
    @ObservationIgnored private var flights: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var firstRequestStarted: [String: ContinuousClock.Instant] = [:]
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
        guard let search = laterQueries[key(SavedRouteQuery(group: group))] else { return nil }
        var state = states[key(search.query)] ?? SavedRouteBoardState()
        state.isSearchingLater = search.isSearching
        state.searchedWindow = .init(from: search.from, to: search.searchedUntil)
        state.reachedSearchLimit = search.searchedUntil >= search.limit
        state.message = search.message ?? state.message
        if let result = state.result {
            // The last server window may extend past our 24-hour departure limit.
            state.board?.result = PlannerSearchResponse(
                journeys: result.journeys.filter { $0.departure < search.limit },
                dataset: result.dataset, search: result.search, warnings: result.warnings,
                pagination: result.pagination, live: result.live,
                disruptedJourneys: result.disruptedJourneys?.filter { $0.departure < search.limit })
        }
        return state
    }

    func searchLater(for group: JourneyGroup) async {
        let routeID = key(SavedRouteQuery(group: group))
        if laterQueries[routeID] == nil {
            let primary = state(for: group)
            let window = primary.result?.search.window
            let canContinue = primary.result?.search.searchTruncated == false && primary.result?.search.provisional != true
                && window.map { $0.from <= now() && $0.to > now() } == true
            // Shared board profiles include past hours. Count 24 hours from the
            // requested departure time, not the beginning of that cache bucket.
            let from = canContinue ? max(window!.from, primary.result!.search.time) : now()
            let until = canContinue ? min(window!.to, from.addingTimeInterval(24 * 60 * 60))
                : primary.direct?.departures.isEmpty == false ? from.addingTimeInterval(6 * 60 * 60) : from
            var created = SavedRouteQuery(group: group)
            created.time = PlannerTime.iso8601(until)
            laterQueries[routeID] = LaterSearch(query: created, from: from, searchedUntil: until)
        }
        guard laterState(for: group)?.hasPersistentFailure != true else { return }
        await continueLaterSearch(routeID)
    }

    func retryLater(for group: JourneyGroup) async {
        await continueLaterSearch(key(SavedRouteQuery(group: group)))
    }

    private func continueLaterSearch(_ routeID: String) async {
        guard let search = laterQueries[routeID], !search.isSearching, !search.finished else { return }
        let server = client.routeBoardsServerIdentity
        laterQueries[routeID]?.isSearching = true
        laterQueries[routeID]?.message = nil
        defer { laterQueries[routeID]?.isSearching = false }
        while !Task.isCancelled, client.routeBoardsServerIdentity == server,
              var search = laterQueries[routeID] {
            await performLaterSearch(search.query, before: search.limit)
            guard !Task.isCancelled, client.routeBoardsServerIdentity == server,
                  let state = states[key(search.query)], state.consecutiveFailures == 0,
                  state.message == nil, let result = state.result else { return }
            if result.journeys.contains(where: { $0.departure >= now() && $0.departure < search.limit }) {
                laterQueries[routeID]?.finished = true
                return
            }
            let window = result.search.window
            guard state.board?.status == "ready", !result.search.searchTruncated, result.search.provisional != true,
                  abs(window.from.timeIntervalSince(search.searchedUntil)) < 1,
                  window.to > search.searchedUntil else {
                laterQueries[routeID]?.message = "The search could not check the full time window. Try again."
                return
            }
            search.searchedUntil = min(window.to, search.limit)
            search.finished = search.searchedUntil >= search.limit
            if !search.finished { search.query.time = PlannerTime.iso8601(window.to) }
            laterQueries[routeID] = search
            if search.finished { return }
        }
    }

    private func performLaterSearch(_ query: SavedRouteQuery, before limit: Date) async {
        let queryKey = key(query)
        let server = client.routeBoardsServerIdentity

        for attempt in 0...2 {
            guard !Task.isCancelled else { return }
            if attempt == 0 && states[queryKey] == nil { states[queryKey] = SavedRouteBoardState(requestedAt: now()) }
            if attempt > 0 {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
            while !Task.isCancelled {
                await refresh(queries: [query], force: true)
                guard !Task.isCancelled, client.routeBoardsServerIdentity == server else { return }
                guard let state = states[queryKey] else { break }
                if state.consecutiveFailures == 0 {
                    let hasOptions = state.result?.journeys.contains { $0.departure >= now() && $0.departure < limit } == true
                    if hasOptions || (state.board?.status == "ready" && state.result != nil) || state.direct != nil { return }
                }
                guard state.isPending, state.consecutiveFailures == 0 else {
                    break
                }
                let pause = min(20, max(1, state.nextRefresh.timeIntervalSince(now())))
                do { try await Task.sleep(for: .seconds(pause)) }
                catch { return }
            }
            if states[queryKey]?.hasPersistentFailure == true { return }
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
                        let atCapacity = board.error?.code == "SEARCH_CAPACITY"
                        let liveRefreshFailed = board.result?.journeys.contains { journey in
                            PlannerLivePresentation.warnings(for: journey).contains(where: PlannerLivePresentation.isRefreshFailureWarning)
                        } == true || (board.direct.map { $0.dataStatus != .live } ?? false)
                        let failures = atCapacity ? 3 : (board.error != nil || liveRefreshFailed) && !waiting
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
        let retryDelay = min(20, 3 * (1 << min(state.consecutiveFailures - 1, 3)))
        state.nextRefresh = now().addingTimeInterval(TimeInterval(retryDelay))
        states[key] = state
    }
}
