import Foundation

struct PlannerError: Error, LocalizedError, Decodable, Equatable {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

@MainActor
protocol JourneyPlannerServing {
    func status() async throws -> PlannerStatus
    func stations(query: String) async throws -> [PlannerStation]
    func search(_ request: PlannerSearchRequest) async throws -> PlannerSearchResponse
    func search(_ request: PlannerSearchRequest, progress: @escaping @MainActor (PlannerSearchProgress) -> Void) async throws -> PlannerSearchResponse
    func journey(id: String) async throws -> PlannerJourneyResponse
}

extension JourneyPlannerServing {
    func search(_ request: PlannerSearchRequest, progress: @escaping @MainActor (PlannerSearchProgress) -> Void) async throws -> PlannerSearchResponse {
        progress(.running)
        return try await search(request)
    }
}

@MainActor
final class JourneyPlannerClient: JourneyPlannerServing, SavedRouteBoardServing {
    private struct ErrorResponse: Decodable { let error: PlannerError }
    private struct HTTPFailure: Error {
        let status: Int
        let error: PlannerError
    }

    struct SearchTiming {
        let now: @MainActor () -> TimeInterval
        let sleep: @MainActor (TimeInterval) async throws -> Void

        static var live: SearchTiming {
            let clock = ContinuousClock()
            let start = clock.now
            return SearchTiming(now: {
                let duration = start.duration(to: clock.now).components
                return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            }, sleep: { try await Task.sleep(for: .seconds($0)) })
        }
    }

    private let session: URLSession
    private let selectedBaseURL: @MainActor () -> String
    private let clientID: String
    private let timing: SearchTiming

    init(session: URLSession = .shared, selectedBaseURL: (@MainActor () -> String)? = nil,
         clientID: String? = nil, timing: SearchTiming? = nil) {
        self.session = session
        self.selectedBaseURL = selectedBaseURL ?? { ApiHostPreference.currentBaseURL }
        self.clientID = clientID ?? Self.installationID()
        self.timing = timing ?? .live
    }

    private static func installationID() -> String {
        let key = "journeyPlanner.clientID.v1"
        if let existing = UserDefaults.standard.string(forKey: key), UUID(uuidString: existing) != nil { return existing }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    // Version only this new service. Existing departures, tracking and configuration keep their v2 URLs.
    static func plannerBaseURL(from existingBase: String) throws -> URL {
        guard var components = URLComponents(string: existingBase),
              ["http", "https"].contains(components.scheme), components.host != nil else {
            throw PlannerError(code: "CONFIGURATION", message: "The journey planner server address is invalid.")
        }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path.hasSuffix("api/v2") else {
            throw PlannerError(code: "CONFIGURATION", message: "The selected server does not have a supported API address.")
        }
        components.path = "/" + String(path.dropLast("api/v2".count)) + "api/v3/journey-planner"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw PlannerError(code: "CONFIGURATION", message: "The journey planner server address is invalid.")
        }
        return url
    }

    func status() async throws -> PlannerStatus {
        try await send(path: ["status"])
    }

    var routeBoardsServerIdentity: String { selectedBaseURL() }

    func routeBoards(_ routes: [SavedRouteQuery]) async throws -> SavedRouteBoardsResponse {
        struct Request: Encodable { let routes: [SavedRouteQuery] }
        let base = try Self.plannerBaseURL(from: selectedBaseURL())
        do {
            return try await send(path: ["route-boards"], body: JSONEncoder().encode(Request(routes: routes)),
                                  base: base, headers: ["X-Planner-Client": clientID], timeout: 15, preserveHTTPStatus: true)
        } catch let failure as HTTPFailure {
            if failure.status == 404 { throw SavedRouteBoardError.unsupported }
            throw failure.error
        }
    }

    func stations(query: String) async throws -> [PlannerStation] {
        struct Response: Decodable { let stations: [PlannerStation] }
        let response: Response = try await send(path: ["stations"], query: [URLQueryItem(name: "q", value: query)])
        return response.stations
    }

    func search(_ request: PlannerSearchRequest) async throws -> PlannerSearchResponse {
        try await search(request, progress: { _ in })
    }

    func search(_ request: PlannerSearchRequest, progress: @escaping @MainActor (PlannerSearchProgress) -> Void) async throws -> PlannerSearchResponse {
        let base = try Self.plannerBaseURL(from: selectedBaseURL())
        let body: Data
        if let cursor = request.cursor {
            struct Page: Encodable { let cursor: String }
            body = try JSONEncoder().encode(Page(cursor: cursor))
        } else {
            body = try JSONEncoder().encode(request)
        }
        let deadline = timing.now() + 20 * 60
        let idempotencyKey = UUID().uuidString
        var jobID: String?
        var terminal = false
        do {
            progress(.queued(position: nil))
            var job: PlannerSearchJob
            do {
                job = try await jobRequest(base: base, path: ["search-jobs"], body: body,
                                           idempotencyKey: idempotencyKey, deadline: deadline)
            } catch let failure as HTTPFailure where failure.status == 404 {
                progress(.running)
                return try await send(path: ["search"], body: body, base: base)
            }
            guard !job.id.isEmpty else { throw invalidJobResponse() }
            jobID = job.id
            while true {
                try checkDeadline(deadline)
                guard job.id == jobID else { throw invalidJobResponse() }
                switch job.status {
                case .completed:
                    guard let result = job.result else { throw invalidJobResponse() }
                    terminal = true
                    return result
                case .failed:
                    terminal = true
                    throw job.error ?? PlannerError(code: "SEARCH_FAILED", message: "This search could not be completed. Please try again.")
                case .cancelled:
                    terminal = true
                    throw job.error ?? PlannerError(code: "SEARCH_CANCELLED", message: "This search was cancelled. Please try again.")
                case .queued:
                    progress(.queued(position: job.queuePosition))
                case .running:
                    progress(.running)
                }
                let interval = min(5, max(0.5, (job.pollAfterMs ?? 1000) / 1000))
                try await timing.sleep(max(0, min(interval, deadline - timing.now())))
                job = try await jobRequest(base: base, path: ["search-jobs", job.id], deadline: deadline)
            }
        } catch {
            if let jobID, !terminal { cancelJob(id: jobID, base: base) }
            try Task.checkCancellation()
            if let failure = error as? HTTPFailure {
                if failure.status == 410 {
                    throw PlannerError(code: "SEARCH_EXPIRED", message: "This search has expired. Please search again.")
                }
                throw failure.error
            }
            throw error
        }
    }

    private func checkDeadline(_ deadline: TimeInterval) throws {
        try Task.checkCancellation()
        guard timing.now() < deadline else {
            throw PlannerError(code: "SEARCH_TIMEOUT", message: "This search took too long. Please try again, or choose a different time.")
        }
    }

    private func jobRequest(base: URL, path: [String], body: Data? = nil,
                            idempotencyKey: String? = nil, deadline: TimeInterval) async throws -> PlannerSearchJob {
        var retryUntil: TimeInterval?
        var delay: TimeInterval = 1
        while true {
            try checkDeadline(deadline)
            do {
                let remaining = min(deadline, retryUntil ?? deadline) - timing.now()
                return try await send(path: path, body: body, base: base,
                                      headers: ["X-Planner-Client": clientID].merging(idempotencyKey.map { ["Idempotency-Key": $0] } ?? [:]) { _, new in new },
                                      timeout: min(30, max(0.1, remaining)), preserveHTTPStatus: true)
            } catch {
                try Task.checkCancellation()
                guard isTransient(error) else { throw error }
                if retryUntil == nil { retryUntil = timing.now() + 60 }
                let remaining = min(deadline, retryUntil!) - timing.now()
                guard remaining > 0 else { throw error }
                try await timing.sleep(min(delay, remaining))
                guard timing.now() < retryUntil! else { throw error }
                delay = min(5, delay * 2)
            }
        }
    }

    private func isTransient(_ error: Error) -> Bool {
        if let failure = error as? HTTPFailure { return [429, 502, 503, 504].contains(failure.status) }
        if let error = error as? PlannerError { return error.code == "NETWORK_TIMEOUT" }
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
                    .dnsLookupFailed, .cannotFindHost].contains(error.code)
        }
        return false
    }

    private func invalidJobResponse() -> PlannerError {
        PlannerError(code: "INVALID_RESPONSE", message: "The journey planner returned an unreadable response. Please try again.")
    }

    private func cancelJob(id: String, base: URL) {
        var request = URLRequest(url: base.appendingPathComponent("search-jobs").appendingPathComponent(id))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 10
        request.setValue(clientID, forHTTPHeaderField: "X-Planner-Client")
        // A cancelled search task must not also cancel the request releasing its server lease.
        let session = session
        Task.detached(priority: .utility) { [session, request] in _ = try? await session.data(for: request) }
    }

    func journey(id: String) async throws -> PlannerJourneyResponse {
        try await send(path: ["journeys", id])
    }

    private func send<Response: Decodable>(
        path: [String], query: [URLQueryItem]? = nil, body: Data? = nil, base: URL? = nil,
        headers: [String: String] = [:], timeout: TimeInterval = 30, preserveHTTPStatus: Bool = false
    ) async throws -> Response {
        var url = try base ?? Self.plannerBaseURL(from: selectedBaseURL())
        for component in path { url.appendPathComponent(component) }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw PlannerError(code: "CONFIGURATION", message: "The journey planner server address is invalid.")
        }
        components.queryItems = query
        guard let requestURL = components.url else {
            throw PlannerError(code: "CONFIGURATION", message: "The journey planner server address is invalid.")
        }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let timeoutMessage = path.first == "search" || path.first == "search-jobs"
            ? "This search took too long. Try again, or choose a different time."
            : "The journey planner took too long to respond. Please try again."
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            try Task.checkCancellation()
            throw PlannerError(code: "NETWORK_TIMEOUT", message: timeoutMessage)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw PlannerError(code: "UNAVAILABLE", message: "The journey planner is unavailable. Please try again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let error: PlannerError
            if let response = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                error = response.error
            } else if http.statusCode == 504 {
                error = PlannerError(code: "HTTP_504", message: timeoutMessage)
            } else {
                error = PlannerError(code: "HTTP_\(http.statusCode)", message: "The journey planner is unavailable. Please try again. Saved routes are still available.")
            }
            if preserveHTTPStatus { throw HTTPFailure(status: http.statusCode, error: error) }
            throw error
        }
        do {
            return try PlannerTime.decoder().decode(Response.self, from: data)
        } catch {
            throw PlannerError(code: "INVALID_RESPONSE", message: "The journey planner returned an unreadable response. Please try again.")
        }
    }
}
