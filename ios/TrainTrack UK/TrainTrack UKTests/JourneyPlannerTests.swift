import Foundation
import Testing
@testable import TrainTrack_UK

@Suite(.serialized)
@MainActor
struct JourneyPlannerTests {
    private let origin = PlannerStation(crs: "KTH", name: "Kent House")
    private let destination = PlannerStation(crs: "VIC", name: "London Victoria")
    private let now = Date(timeIntervalSince1970: 1_799_999_000)

    @Test func plannerUsesV3WithoutChangingExistingHostPaths() throws {
        #expect(try JourneyPlannerClient.plannerBaseURL(from: ApiHost.prod.baseURL).absoluteString == "https://api.skynolimit.dev/train-track/api/v3/journey-planner")
        #expect(try JourneyPlannerClient.plannerBaseURL(from: ApiHost.dev.baseURL).absoluteString == "http://Mikes-MacBook-Air.local:3000/api/v3/journey-planner")
        #expect(ApiHost.prod.baseURL.hasSuffix("/api/v2"))
        #expect(ApiHost.dev.baseURL.hasSuffix("/api/v2"))
        #expect(throws: PlannerError.self) { try JourneyPlannerClient.plannerBaseURL(from: "https://example.com/unknown") }
    }

    @Test func departNowResolvesWhenSubmittingAndExplicitTimesDoNotMove() throws {
        let relative = intent(mode: .now)
        #expect(try relative.request(now: now).time != relative.request(now: now.addingTimeInterval(60)).time)
        #expect(try relative.request(now: now.addingTimeInterval(0.5)).time.contains(".500"))
        let date = now.addingTimeInterval(3600)
        let explicit = intent(mode: .arriveBy, date: date)
        #expect(try explicit.request(now: now).time == PlannerTime.iso8601(date))
        #expect(try explicit.request(now: now).timeType == "arriveBy")
        #expect(throws: PlannerError.self) { try explicit.request(now: date.addingTimeInterval(1)) }
        #expect(throws: PlannerError.self) { try intent(mode: .departAt).request(now: now) }
    }

    @Test func searchUsesServerChangeLimitUnlessCallerExplicitlyOverridesIt() throws {
        var request = try intent(mode: .now).request(now: now)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(!json.keys.contains("maxChanges"))
        #expect(json["limit"] as? Int == 5)
        request.maxChanges = 2
        json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(json["maxChanges"] as? Int == 2)
    }

    @Test func responseChangeLimitIsOptionalForOlderServers() throws {
        let old = try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: Data(Self.emptyResult.utf8))
        #expect(old.search.maxChanges == nil)
        var json = try #require(JSONSerialization.jsonObject(with: Data(Self.emptyResult.utf8)) as? [String: Any])
        var search = try #require(json["search"] as? [String: Any])
        search["maxChanges"] = 5
        json["search"] = search
        let current = try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(current.search.maxChanges == 5)
    }

    @Test func railwayClockUsesLondonOffsetsAndInclusiveCoverageDates() throws {
        let summer = try #require(ISO8601DateFormatter().date(from: "2026-09-08T06:12:00Z"))
        let winter = try #require(ISO8601DateFormatter().date(from: "2026-12-08T07:12:00Z"))
        #expect(PlannerTime.iso8601(summer).hasSuffix("+01:00"))
        #expect(PlannerTime.iso8601(winter).hasSuffix("Z"))
        #expect(PlannerTime.display(summer, includeDate: false) == "07:12")
        let coverage = PlannerDataset.Coverage(from: "2026-10-25", to: "2026-10-25")
        let range = try #require(coverage.dateRange)
        #expect(range.upperBound.timeIntervalSince(range.lowerBound) == 25 * 3600 - 1)
    }

    @Test func recentSearchesPersistDeduplicateIntentAndStaySeparateFromSavedRoutes() throws {
        let defaults = isolatedDefaults()
        defaults.set("unchanged", forKey: "saved-routes-test-marker")
        let recents = PlannerRecentSearchStore(defaults: defaults)
        recents.record(intent(mode: .now), at: now)
        recents.record(intent(mode: .now), at: now.addingTimeInterval(60))
        #expect(recents.searches.count == 1)
        for i in 1...12 {
            recents.record(intent(mode: .departAt, date: now.addingTimeInterval(Double(i) * 3600)), at: now)
        }
        #expect(recents.searches.count == 10)
        let restored = PlannerRecentSearchStore(defaults: defaults)
        #expect(restored.searches.count == 10)
        #expect(restored.searches.first?.intent.explicitTime == now.addingTimeInterval(12 * 3600))
        restored.remove(id: try #require(restored.searches.first?.id))
        #expect(PlannerRecentSearchStore(defaults: defaults).searches.count == 9)
        restored.clear()
        #expect(PlannerRecentSearchStore(defaults: defaults).searches.isEmpty)
        #expect(defaults.string(forKey: "saved-routes-test-marker") == "unchanged")
    }

    @Test func restoredPastExplicitSearchRequiresCorrection() throws {
        let store = makeStore()
        let past = now.addingTimeInterval(-60)
        store.restore(PlannerRecentSearch(id: UUID(), intent: intent(mode: .departAt, date: past), searchedAt: past))
        #expect(store.explicitTime == past)
        #expect(store.timeMode == .departAt)
        #expect(store.validationMessage(now: now)?.contains("has passed") == true)
        store.timeMode = .now
        #expect(store.validationMessage(now: now) == nil)
    }

    @Test func successfulEmptySearchIsRecentButServerFailureIsNot() async throws {
        let service = PlannerStubService()
        let store = makeStore(client: service)
        store.origin = origin
        store.destination = destination
        await store.search(now: now)
        #expect(store.response?.journeys.isEmpty == true)
        #expect(store.recents.searches.count == 1)
        #expect(service.requests.first?.time == PlannerTime.iso8601(now))
        store.recents.clear()
        service.failure = PlannerError(code: "DATASET_UNAVAILABLE", message: "No timetable is available.")
        await store.search(now: now)
        #expect(store.recents.searches.isEmpty)
        #expect(store.searchError?.code == "DATASET_UNAVAILABLE")
        #expect(!store.isSearching)
    }

    @Test func supersededSearchCannotReplaceNewResultsOrCreateRecentHistory() async throws {
        let service = PlannerStubService()
        service.holdSearches = true
        let store = makeStore(client: service)
        store.origin = origin
        store.destination = destination
        let first = Task { await store.search(now: now) }
        while service.pending.isEmpty { await Task.yield() }
        store.destination = PlannerStation(crs: "LBG", name: "London Bridge")
        let second = Task { await store.search(now: now) }
        while service.pending.count < 2 { await Task.yield() }
        service.pending[1].resume(returning: try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: Data(Self.emptyResult.utf8)))
        await second.value
        service.pending[0].resume(returning: try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: Data(Self.emptyResult.utf8)))
        await first.value
        #expect(store.recents.searches.count == 1)
        #expect(store.recents.searches.first?.intent.destination.crs == "LBG")
        #expect(!store.isSearching)
    }

    @Test func morePagesAppendDistinctJourneysAndAdjacentWindowsReplaceThem() async throws {
        let service = PlannerStubService()
        service.results = [try result(ids: ["a", "b"], more: "more"), try result(ids: ["b", "c"]), try result(ids: ["d"])]
        let store = makeStore(client: service)
        store.origin = origin
        store.destination = destination
        await store.search(now: now)
        await store.search(cursor: "more", now: now)
        #expect(store.response?.journeys.map(\.id) == ["a", "b", "c"])
        await store.search(cursor: "later", now: now)
        #expect(store.response?.journeys.map(\.id) == ["d"])
        #expect(store.recents.searches.count == 1)
    }

    @Test func emptyWindowCanPageEarlierAndLaterWithoutChangingTheOriginalSearch() async throws {
        let service = PlannerStubService()
        service.results = [try result(ids: []), try result(ids: []), try result(ids: ["later-journey"])]
        let store = makeStore(client: service)
        store.origin = origin
        store.destination = destination
        await store.search(now: now)
        #expect(store.response?.journeys.isEmpty == true)
        let earlier = try #require(store.response?.pagination.earlier)
        await store.search(cursor: earlier, now: now.addingTimeInterval(60))
        #expect(store.response?.journeys.isEmpty == true)
        let later = try #require(store.response?.pagination.later)
        await store.search(cursor: later, now: now.addingTimeInterval(120))
        #expect(store.response?.journeys.map(\.id) == ["later-journey"])
        #expect(service.requests.map(\.cursor) == [nil, earlier, later])
        #expect(service.requests.allSatisfy { $0.time == PlannerTime.iso8601(now) && $0.maxChanges == nil })
        #expect(store.recents.searches.count == 1)
        #expect(store.intent?.timeMode == .now)
        #expect(!store.isSearching)
        #expect(store.searchError == nil)
    }

    @Test func invalidStationRequestsReselectionWithoutLosingOtherIntent() async {
        let service = PlannerStubService()
        service.validStations = [destination]
        service.failure = PlannerError(code: "INVALID_STATION", message: "Select a supported station.")
        let store = makeStore(client: service)
        store.origin = origin
        store.destination = destination
        store.timeMode = .arriveBy
        store.explicitTime = now.addingTimeInterval(3600)
        await store.search(now: now)
        #expect(store.origin == nil)
        #expect(store.destination?.crs == destination.crs)
        #expect(store.timeMode == .arriveBy)
        #expect(store.explicitTime == now.addingTimeInterval(3600))
        #expect(store.recents.searches.isEmpty)
    }

    @Test func publicClientUsesVersionedPathsNoEntitlementHeadersAndCursorOnlyPagination() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlannerStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.test/train-track/api/v2" })
        PlannerStubProtocol.handler = { request in
            #expect(request.url?.path == "/train-track/api/v3/journey-planner/search")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "X-Device-Token") == nil)
            let body = try JSONSerialization.jsonObject(with: PlannerStubProtocol.body(request)) as? [String: String]
            #expect(body == ["cursor": "opaque-version-bound-cursor"])
            return (200, Data(JourneyPlannerTests.emptyResult.utf8))
        }
        var request = try intent(mode: .now).request(now: now)
        request.cursor = "opaque-version-bound-cursor"
        _ = try await client.search(request)
        PlannerStubProtocol.handler = { _ in
            (410, Data(#"{"error":{"code":"JOURNEY_EXPIRED","message":"This journey has expired. Search again."}}"#.utf8))
        }
        await #expect(throws: PlannerError(code: "JOURNEY_EXPIRED", message: "This journey has expired. Search again.")) {
            try await client.journey(id: "expired")
        }
    }

    @Test func plainTextAndHTMLGatewayTimeoutsHaveAnActionableMessage() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlannerStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.test/api/v2" })
        let request = try intent(mode: .now).request(now: now)
        for body in ["Gateway Timeout", "<html><body>504 Gateway Timeout</body></html>"] {
            PlannerStubProtocol.handler = { request in
                #expect(request.timeoutInterval == 30)
                return (504, Data(body.utf8))
            }
            await #expect(throws: PlannerError(code: "HTTP_504", message: "This search took too long. Try again, or choose a different time.")) {
                try await client.search(request)
            }
        }
        PlannerStubProtocol.handler = { _ in (502, Data("Bad Gateway".utf8)) }
        await #expect(throws: PlannerError(code: "HTTP_502", message: "The journey planner is unavailable. Please try again. Saved routes are still available.")) {
            try await client.search(request)
        }
    }

    @Test func structuredServerErrorsTakePrecedenceOverHTTPTimeoutFallback() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlannerStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.test/api/v2" })
        PlannerStubProtocol.handler = { _ in
            (504, Data(#"{"error":{"code":"SEARCH_TIMEOUT","message":"Search limit reached. Choose another time."}}"#.utf8))
        }
        let request = try intent(mode: .now).request(now: now)
        await #expect(throws: PlannerError(code: "SEARCH_TIMEOUT", message: "Search limit reached. Choose another time.")) {
            try await client.search(request)
        }
    }

    @Test func transportTimeoutIsExplainedWithoutConvertingCancellation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlannerStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.test/api/v2" })
        let request = try intent(mode: .now).request(now: now)
        PlannerStubProtocol.handler = { _ in throw URLError(.timedOut) }
        await #expect(throws: PlannerError(code: "NETWORK_TIMEOUT", message: "This search took too long. Try again, or choose a different time.")) {
            try await client.search(request)
        }
        await #expect(throws: PlannerError(code: "NETWORK_TIMEOUT", message: "The journey planner took too long to respond. Please try again.")) {
            try await client.status()
        }
        PlannerStubProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await client.search(request)
            Issue.record("Expected the transport cancellation to be preserved.")
        } catch {
            #expect((error as? URLError)?.code == .cancelled)
        }
    }

    @Test func datedJourneyDecodesOvernightCallingPointsAndTransferBreakdown() throws {
        let data = Data(#"{"id":"v:1","departure":"2026-09-08T23:55:00+01:00","arrival":"2026-09-09T00:30:00+01:00","durationMinutes":35,"changes":1,"legs":[{"kind":"transfer","mode":"walk","from":{"crs":"WAT","name":"London Waterloo"},"to":{"crs":"WAE","name":"London Waterloo East"},"departure":"2026-09-08T23:55:00+01:00","arrival":"2026-09-09T00:15:00+01:00","transfer":{"exitMinutes":15,"travelMinutes":1,"entryMinutes":4,"extraMinutes":0}},{"kind":"vehicle","mode":"rail","operator":"SE","serviceId":"dated-service","from":{"crs":"WAE","name":"London Waterloo East"},"to":{"crs":"LBG","name":"London Bridge"},"departure":"2026-09-09T00:15:00.000+01:00","arrival":"2026-09-09T00:30:00+01:00","callingPoints":[{"station":{"crs":"LBG","name":"London Bridge"},"arrival":"2026-09-09T00:30:00+01:00"}]}]}"#.utf8)
        let journey = try PlannerTime.decoder().decode(PlannedJourney.self, from: data)
        #expect(journey.arrival.timeIntervalSince(journey.departure) == 35 * 60)
        #expect(journey.legs[0].transfer?.travelMinutes == 1)
        #expect(journey.legs[0].transfer?.exitMinutes == 15)
        #expect(journey.legs[1].callingPoints?.first?.arrival == journey.arrival)
    }

    private func intent(mode: PlannerTimeMode, date: Date? = nil) -> PlannerSearchIntent {
        PlannerSearchIntent(origin: origin, destination: destination, timeMode: mode, explicitTime: date)
    }

    private func isolatedDefaults() -> UserDefaults { UserDefaults(suiteName: "PlannerTests.\(UUID())")! }

    private func result(ids: [String], more: String? = nil) throws -> PlannerSearchResponse {
        var json = try #require(JSONSerialization.jsonObject(with: Data(Self.emptyResult.utf8)) as? [String: Any])
        json["journeys"] = ids.map { id in
            ["id": id, "departure": "2026-09-15T12:00:00Z", "arrival": "2026-09-15T12:21:00Z",
             "durationMinutes": 21, "changes": 0, "legs": []] as [String: Any]
        }
        var pagination = ["earlier": "earlier", "later": "later"]
        if let more { pagination["more"] = more }
        json["pagination"] = pagination
        return try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func makeStore(client: PlannerStubService? = nil) -> JourneyPlannerStore {
        JourneyPlannerStore(client: client ?? PlannerStubService(), recents: PlannerRecentSearchStore(defaults: isolatedDefaults()))
    }

    nonisolated static let emptyResult = #"{"journeys":[],"dataset":{"version":"fixture","sourceGenerationDate":"2026-08-25","importedAt":"2026-09-15T12:00:00.000Z","coverage":{"from":"2026-05-17","to":"2027-05-15"},"freshness":"stale","scheduledOnly":true},"search":{"origin":"KTH","destination":"VIC","time":"2026-09-15T12:00:00Z","timeType":"departAfter","window":{"from":"2026-09-15T12:00:00Z","to":"2026-09-15T14:00:00Z"},"searchTruncated":false},"warnings":[],"pagination":{"earlier":"previous","later":"next"}}"#
}

@MainActor
private final class PlannerStubService: JourneyPlannerServing {
    var requests: [PlannerSearchRequest] = []
    var failure: PlannerError?
    var validStations: [PlannerStation] = []
    var results: [PlannerSearchResponse] = []
    var holdSearches = false
    var pending: [CheckedContinuation<PlannerSearchResponse, Error>] = []
    func status() async throws -> PlannerStatus { throw PlannerError(code: "TEST", message: "Unused") }
    func stations(query: String) async throws -> [PlannerStation] { validStations.filter { $0.crs == query } }
    func journey(id: String) async throws -> PlannerJourneyResponse { throw PlannerError(code: "TEST", message: "Unused") }
    func search(_ request: PlannerSearchRequest) async throws -> PlannerSearchResponse {
        requests.append(request)
        if let failure { throw failure }
        if !results.isEmpty { return results.removeFirst() }
        if holdSearches { return try await withCheckedThrowingContinuation { pending.append($0) } }
        return try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: Data(JourneyPlannerTests.emptyResult.utf8))
    }
}

private final class PlannerStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
}
