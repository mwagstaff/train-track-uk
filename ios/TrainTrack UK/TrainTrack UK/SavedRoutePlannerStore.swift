import Foundation
import Observation

struct SavedRouteQuery: Encodable, Hashable {
    let origin: String
    let destination: String
    let via: [String]
    var realtime = "apply"
    var id: String { ([origin] + via + [destination, realtime]).joined(separator: "-") }

    init(group: JourneyGroup) {
        origin = group.startStation.crs.uppercased()
        destination = group.endStation.crs.uppercased()
        via = group.viaStations.map { $0.crs.uppercased() }
    }

    enum CodingKeys: String, CodingKey { case id, origin, destination, via, realtime }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(origin, forKey: .origin)
        try values.encode(destination, forKey: .destination)
        try values.encode(via, forKey: .via)
        try values.encode(realtime, forKey: .realtime)
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
}

struct SavedRouteBoardsResponse: Decodable {
    let apiVersion: Int
    let boards: [SavedRouteBoard]
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

    var result: PlannerSearchResponse? { board?.result }
    var isPending: Bool { (board == nil && message == nil) || board?.status == "queued" || board?.status == "refreshing" }
    var isStale: Bool { board?.status != "ready" || message != nil }
}

/// Shared by saved-route screens; background refresh never adds a recent search.
@MainActor @Observable
final class SavedRoutePlannerStore {
    static let shared = SavedRoutePlannerStore()
    private(set) var states: [String: SavedRouteBoardState] = [:]
    private var liveModes: [String: Bool] = [:]
    @ObservationIgnored private let client: any SavedRouteBoardServing
    @ObservationIgnored private var flights: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let now: () -> Date

    init(client: (any SavedRouteBoardServing)? = nil, now: @escaping () -> Date = Date.init) {
        self.client = client ?? JourneyPlannerClient()
        self.now = now
    }

    private func key(_ query: SavedRouteQuery) -> String { client.routeBoardsServerIdentity + "|" + query.id }

    func query(for group: JourneyGroup) -> SavedRouteQuery {
        var query = SavedRouteQuery(group: group)
        query.realtime = usesLiveTimes(for: group) ? "apply" : "ignore"
        return query
    }

    func usesLiveTimes(for group: JourneyGroup) -> Bool { liveModes[SavedRouteQuery(group: group).id] ?? true }

    func setLiveTimes(_ value: Bool, for group: JourneyGroup) { liveModes[SavedRouteQuery(group: group).id] = value }

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
            let task = Task { [weak self] in
                guard let self else { return }
                defer { for key in keys { self.flights[key] = nil } }
                guard self.client.routeBoardsServerIdentity == server else { return }
                do {
                    let response = try await self.client.routeBoards(batch)
                    try Task.checkCancellation()
                    guard response.apiVersion == 3 else { throw PlannerError(code: "INVALID_RESPONSE", message: "Journey options could not be read. Please try again.") }
                    for (query, key) in zip(batch, keys) {
                        guard var board = response.boards.first(where: { $0.id == query.id }) else {
                            self.fail(key: key, message: "Journey options were not returned. Please try again.")
                            continue
                        }
                        let previous = self.states[key]?.result
                        if board.result == nil { board.result = previous }
                        let interval = min(20, max(1, (board.pollAfterMs ?? 20000) / 1000))
                        self.states[key] = SavedRouteBoardState(board: board, message: board.error?.message,
                            nextRefresh: self.now().addingTimeInterval(interval))
                    }
                } catch SavedRouteBoardError.unsupported {
                    for key in keys {
                        self.states[key] = SavedRouteBoardState(message: "Journey planning is not available on this server. Showing saved-route departures.",
                            usesLegacyDepartures: true, nextRefresh: self.now().addingTimeInterval(300))
                    }
                } catch {
                    guard !Task.isCancelled else { return }
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
        state.message = message
        state.nextRefresh = now().addingTimeInterval(20)
        states[key] = state
    }
}
