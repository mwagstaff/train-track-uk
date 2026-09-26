import Foundation
import Observation

@MainActor
protocol WatchBoardServing {
    func fetch(route: WatchRoute, apiBase: String) async throws -> WatchBoard
}

@MainActor
struct WatchBoardClient: WatchBoardServing {
    let session: URLSession
    let clientID: String

    init(session: URLSession = .shared, clientID: String? = nil) {
        self.session = session
        if let clientID {
            self.clientID = clientID
        } else {
            let key = "watchPlanner.clientID.v1"
            let id = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
            UserDefaults.standard.set(id, forKey: key)
            self.clientID = id
        }
    }

    static func request(route: WatchRoute, apiBase: String, version: Int, clientID: String) throws -> URLRequest {
        guard var url = URLComponents(string: apiBase), url.host != nil,
              ["https", "http"].contains(url.scheme), url.path.hasSuffix("/api/v2") else { throw URLError(.badURL) }
        url.path = String(url.path.dropLast("/api/v2".count)) + "/api/v\(version)/journey-planner/route-boards"
        url.query = nil
        url.fragment = nil
        guard let address = url.url else { throw URLError(.badURL) }
        struct Query: Encodable {
            let id: String
            let origin: String
            let destination: String
            let via: [String]
            let realtime = "apply"
        }
        struct Body: Encodable { let routes: [Query] }
        var request = URLRequest(url: address)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientID, forHTTPHeaderField: "X-Planner-Client")
        request.httpBody = try JSONEncoder().encode(Body(routes: [Query(id: route.id.uuidString,
            origin: route.origin.crs, destination: route.destination.crs, via: route.via.map(\.crs))]))
        return request
    }

    func fetch(route: WatchRoute, apiBase: String) async throws -> WatchBoard {
        #if DEBUG && targetEnvironment(simulator)
        if WatchAppFixture.enabled { return WatchAppFixture.board(for: route) }
        #endif
        for version in [4, 3] {
            let request = try Self.request(route: route, apiBase: apiBase, version: version, clientID: clientID)
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if response.statusCode == 404 && version == 4 { continue }
            guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
            let decoded = try JSONDecoder().decode(WatchBoardResponse.self, from: data)
            guard [3, 4].contains(decoded.apiVersion), let board = decoded.boards.first(where: { $0.id == route.id.uuidString }) else {
                throw URLError(.cannotParseResponse)
            }
            return try board.presentation(at: Date())
        }
        throw URLError(.unsupportedURL)
    }
}

@MainActor @Observable
final class WatchBoardStore {
    private(set) var board: WatchBoard?
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let client: any WatchBoardServing
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var currentKey: String?

    init(client: (any WatchBoardServing)? = nil, defaults: UserDefaults = .standard) {
        self.client = client ?? WatchBoardClient()
        self.defaults = defaults
    }

    func watch(route: WatchRoute, apiBase: String) async {
        let key = "watchBoard.v1.\(apiBase).\(route.id)"
        if currentKey != key {
            currentKey = key
            board = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(WatchBoard.self, from: $0) }
            errorMessage = nil
        }
        while !Task.isCancelled {
            await refresh(route: route, apiBase: apiBase)
            do { try await Task.sleep(for: .seconds(errorMessage == nil ? board?.pollInterval ?? 20 : 30)) }
            catch { return }
        }
    }

    func refresh(route: WatchRoute, apiBase: String) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let key = "watchBoard.v1.\(apiBase).\(route.id)"
        do {
            let result = try await client.fetch(route: route, apiBase: apiBase)
            try Task.checkCancellation()
            guard currentKey == nil || currentKey == key else { return }
            // A pending response must not erase the last useful board or renew its age.
            if !result.pending || !result.departures.isEmpty || board == nil {
                board = result
                if !result.pending {
                    defaults.set(try JSONEncoder().encode(result), forKey: key)
                }
            }
            errorMessage = result.message
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = "Couldn't update departures. Check your connection and try again."
        }
    }
}
