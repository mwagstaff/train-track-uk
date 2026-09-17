import Foundation
import Testing
@testable import TrainTrack_UK

@Suite(.serialized) @MainActor
struct SavedRoutePlannerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func requiredStopsKeepTheirOrderAndDirectionInRequestAndCacheKey() throws {
        let route = group(["KTH", "VIC", "EUS", "INV"])
        let query = SavedRouteQuery(group: route)
        let data = try JSONEncoder().encode(query)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["origin"] as? String == "KTH")
        #expect(json["destination"] as? String == "INV")
        #expect(json["via"] as? [String] == ["VIC", "EUS"])
        #expect(query.id != SavedRouteQuery(group: group(["INV", "EUS", "VIC", "KTH"])).id)
        #expect(query.id != SavedRouteQuery(group: group(["KTH", "EUS", "VIC", "INV"])).id)
    }

    @Test func duplicateRoutesShareRequestsAndBatchesNeverExceedEight() async {
        let client = RouteBoardStub()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let routes = (0..<17).map { group(["KTH", "A\($0)"]) }
        await store.refresh(groups: routes + [routes[0]])
        #expect(client.requests.count == 3)
        #expect(client.requests.allSatisfy { $0.count <= 8 })
        #expect(client.requests.flatMap { $0 }.count == 17)
        await store.refresh(groups: routes)
        #expect(client.requests.count == 3)
    }

    @Test func concurrentScreensWaitForOneSharedRequest() async {
        let client = RouteBoardStub()
        client.hold = true
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let routes = [group(["KTH", "VIC"])]
        let first = Task { await store.refresh(groups: routes) }
        while client.continuation == nil { await Task.yield() }
        let second = Task { await store.refresh(groups: routes) }
        await Task.yield()
        #expect(client.requests.count == 1)
        client.continuation?.resume()
        await first.value
        await second.value
        #expect(client.requests.count == 1)
    }

    @Test func pendingAndUnavailableResponsesRetainPreviousResultsWithoutClaimingReady() async throws {
        let client = RouteBoardStub()
        client.result = try result()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])
        await store.refresh(groups: [route])
        #expect(store.state(for: route).result != nil)
        client.result = nil
        client.status = "refreshing"
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).result != nil)
        #expect(store.state(for: route).isPending)
        #expect(store.state(for: route).isStale)
        client.failure = PlannerError(code: "NETWORK", message: "Offline")
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).result != nil)
        #expect(store.state(for: route).message == "Offline")
        #expect(!store.state(for: route).usesLegacyDepartures)
    }

    @Test func onlyExplicitUnsupportedResponseEnablesLegacyDepartures() async {
        let client = RouteBoardStub()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])
        client.failure = PlannerError(code: "HTTP_503", message: "Unavailable")
        await store.refresh(groups: [route])
        #expect(!store.state(for: route).usesLegacyDepartures)
        #expect(!store.state(for: route).isPending)
        client.failure = SavedRouteBoardError.unsupported
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).usesLegacyDepartures)
    }

    @Test func changingServerDoesNotDisplayOrReusePreviousServersBoard() async throws {
        let client = RouteBoardStub()
        client.result = try result()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])
        await store.refresh(groups: [route])
        client.routeBoardsServerIdentity = "other"
        #expect(store.state(for: route).result == nil)
        await store.refresh(groups: [route])
        #expect(client.requests.count == 2)
    }

    @Test func cachedLiveEvidenceExpiresEvenWhenRowsStayVisible() throws {
        var response = try result(journeys: [try journey(live: PlannerLiveAnnotation(status: "onTime"))])
        response.live = PlannerLiveContext(mode: "apply", status: "live", updatedAt: now, expiresAt: now.addingTimeInterval(90))
        let board = SavedRouteBoard(id: "r", status: "refreshing", pollAfterMs: 1000, result: response,
            computedAt: now, expiresAt: now.addingTimeInterval(20), error: nil)
        let state = SavedRouteBoardState(board: board)
        #expect(!state.liveIsStale(at: now.addingTimeInterval(89)))
        #expect(state.liveIsStale(at: now.addingTimeInterval(90)))
        #expect(state.result != nil)
        response.live = PlannerLiveContext(mode: "apply", status: "live", updatedAt: now.addingTimeInterval(-91))
        let recentlyComputed = SavedRouteBoardState(board: SavedRouteBoard(id: "r", status: "ready", pollAfterMs: nil,
            result: response, computedAt: now, expiresAt: nil, error: nil))
        #expect(recentlyComputed.liveIsStale(at: now))
    }

    @Test func queuedProgressIsDecodedAndBusyWarningsDoNotHideItsSpinner() async throws {
        let data = Data("""
        {"id":"r","status":"queued","progress":{"phase":"queued","queuePosition":2,"queuedAt":"2027-01-15T08:00:00Z"}}
        """.utf8)
        let decoded = try PlannerTime.decoder().decode(SavedRouteBoard.self, from: data)
        #expect(decoded.progress?.queuePosition == 2)
        let client = RouteBoardStub()
        client.status = "queued"
        client.boardError = PlannerError(code: "SEARCH_BUSY", message: "Saved journeys are waiting to be planned.")
        client.progress = SavedRouteBoardProgress(phase: "queued", queuePosition: 2, queuedAt: now.addingTimeInterval(-65))
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "INV"])
        await store.refresh(groups: [route])
        let state = store.state(for: route)
        #expect(state.isPending)
        #expect(state.message == nil)
        #expect(state.progressPresentation(at: now)?.title == "Waiting to plan journeys…")
        #expect(state.progressPresentation(at: now)?.details == ["Queue position: 2", "Waiting: 1 min 5 sec"])
        client.boardError = nil
        client.progress = SavedRouteBoardProgress(phase: "searching", queuedAt: now.addingTimeInterval(-70),
            startedAt: now.addingTimeInterval(-20), completedWindows: 3, totalWindows: 8)
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).progressPresentation(at: now)?.title == "Finding journey options…")
        #expect(store.state(for: route).progressPresentation(at: now)?.details == ["Checked 3 of 8 timetable windows", "Elapsed: 1 min 10 sec"])
        client.status = "ready"
        client.result = try result()
        client.progress = nil
        await store.refresh(groups: [route], force: true)
        #expect(!store.state(for: route).isPending)
        #expect(store.state(for: route).progressPresentation(at: now) == nil)
    }

    @Test func olderBusyHTTPResponsesKeepCachedRowsAndRetryWithoutInventingAnETA() async throws {
        let client = RouteBoardStub()
        client.result = try result()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])
        await store.refresh(groups: [route])
        client.failure = PlannerError(code: "SEARCH_BUSY", message: "Busy")
        await store.refresh(groups: [route], force: true)
        let state = store.state(for: route)
        #expect(state.result != nil)
        #expect(state.message == nil)
        #expect(state.progressPresentation(at: now)?.title == "Waiting to update journeys…")
        #expect(state.nextRefresh == now.addingTimeInterval(5))
    }

    @Test func staleLiveEvidenceOnlyAppliesToTheJourneyThatHadAForecast() throws {
        let scheduled = try journey(live: nil, departure: now.addingTimeInterval(5 * 3600))
        let unknown = try journey(live: PlannerLiveAnnotation(status: "unknown", updatedAt: now.addingTimeInterval(-120)))
        let stale = try journey(live: PlannerLiveAnnotation(status: "onTime", updatedAt: now.addingTimeInterval(-120)))
        let fresh = try journey(live: PlannerLiveAnnotation(status: "onTime", updatedAt: now.addingTimeInterval(-10)))
        let expiredContext = PlannerLiveContext(mode: "apply", status: "partial", updatedAt: now.addingTimeInterval(-120), expiresAt: now.addingTimeInterval(-30), windowHours: 4)
        #expect(!PlannerLivePresentation.hasExpiredEvidence(for: scheduled, context: expiredContext, at: now))
        #expect(!PlannerLivePresentation.hasExpiredEvidence(for: unknown, context: expiredContext, at: now))
        #expect(PlannerLivePresentation.hasExpiredEvidence(for: stale, context: expiredContext, at: now))
        #expect(!PlannerLivePresentation.hasExpiredEvidence(for: fresh, context: expiredContext, at: now))
        let context = PlannerLivePresentation.context(for: scheduled, from: expiredContext, at: now)
        #expect(context?.status == "outsideWindow")
        #expect(context?.expiresAt == nil)
        #expect(context?.updatedAt == nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PlannerTime.iso8601(date))
        }
        var raw = try #require(JSONSerialization.jsonObject(with: encoder.encode(scheduled)) as? [String: Any])
        var legs = try #require(raw["legs"] as? [[String: Any]])
        legs[0]["kind"] = "transfer"
        legs[0]["mode"] = "tubeTransfer"
        raw["legs"] = legs
        let transfer = try PlannerTime.decoder().decode(PlannedJourney.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(PlannerLivePresentation.context(for: transfer, from: expiredContext, at: now) == expiredContext)
    }

    @Test func failedCalculationShowsItsErrorAlongsideAutomaticRetryProgress() {
        let error = PlannerError(code: "SEARCH_TIMEOUT", message: "The search took too long.")
        let board = SavedRouteBoard(id: "r", status: "unavailable", pollAfterMs: 5000, result: nil,
            computedAt: nil, expiresAt: nil, error: error,
            progress: SavedRouteBoardProgress(phase: "retrying", queuedAt: now.addingTimeInterval(-20)))
        let state = SavedRouteBoardState(board: board, message: error.message)
        #expect(state.isPending)
        #expect(state.message == error.message)
        #expect(state.progressPresentation(at: now)?.title == "Waiting to retry…")
    }

    @Test func modeOverrideUsesSeparateCacheWithoutChangingSavedStops() async {
        let client = RouteBoardStub()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC", "INV"])
        await store.refresh(groups: [route])
        store.setLiveTimes(false, for: route)
        #expect(store.state(for: route).board == nil)
        await store.refresh(groups: [route])
        #expect(client.requests.map { $0[0].realtime } == ["apply", "ignore"])
        #expect(client.requests.allSatisfy { $0[0].via == ["VIC"] })
        #expect(route.stationSequence.map(\.crs) == ["KTH", "VIC", "INV"])
    }

    @Test func earlierDeparturesDisappearFromCachedReadyRows() throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(JourneyPlannerTests.emptyResult.utf8)) as? [String: Any])
        json["journeys"] = [-1, 1].map { offset in
            ["id": "\(offset)", "departure": PlannerTime.iso8601(now.addingTimeInterval(Double(offset))),
             "arrival": PlannerTime.iso8601(now.addingTimeInterval(100)), "durationMinutes": 2, "changes": 0, "legs": []] as [String: Any]
        }
        let response = try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: JSONSerialization.data(withJSONObject: json))
        let state = SavedRouteBoardState(board: SavedRouteBoard(id: "r", status: "ready", pollAfterMs: nil,
            result: response, computedAt: now, expiresAt: nil, error: nil))
        #expect(state.upcomingJourneys(at: now).map(\.id) == ["1"])
    }

    @Test func trackingRequiresFreshDatedFullPatternAndRejectsCancellationOrWrongDestination() throws {
        let start = PlannerTime.dateOnly("2026-09-17")!.addingTimeInterval(23 * 3600 + 55 * 60)
        let arrival = start.addingTimeInterval(20 * 60)
        let observed = start.addingTimeInterval(-60)
        let place: (String) -> [String: String] = { ["crs": $0, "name": $0] }
        let raw: [String: Any] = ["kind": "vehicle", "mode": "rail", "operator": "SE",
            "from": place("KTH"), "to": place("VIC"), "departure": PlannerTime.iso8601(start), "arrival": PlannerTime.iso8601(arrival),
            "originDate": "2026-09-17", "serviceCallingPoints": [
                ["station": place("KTH"), "departure": PlannerTime.iso8601(start)],
                ["station": place("VIC"), "arrival": PlannerTime.iso8601(arrival)]]]
        var leg = try PlannerTime.decoder().decode(PlannedJourney.Leg.self, from: JSONSerialization.data(withJSONObject: raw))
        let departure = DepartureV2(departureTime: .init(scheduled: "23:55", estimated: "On time"), serviceType: "train", platform: nil,
            isCancelled: false, length: nil, destination: [], origin: nil, serviceID: "public-ID", delayReason: nil,
            cancelReason: nil, timestamp: observed, operatorCode: "SE")
        var detail: [String: Any] = ["generatedAt": PlannerTime.iso8601(observed), "serviceType": "train", "crs": "KTH",
            "locationName": "KTH", "operatorCode": "SE", "std": "23:55",
            "subsequentCallingPoints": [["callingPoint": [["crs": "VIC", "locationName": "VIC", "st": "00:15"]]]]]
        func details() throws -> ServiceDetails { try PlannerTime.decoder().decode(ServiceDetails.self, from: JSONSerialization.data(withJSONObject: detail)) }
        #expect(PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed))
        #expect(PlannerTrainTracking.canStart(departure, details: try details(), leg: leg, selectedServer: "A", currentServer: "A", now: observed))
        #expect(!PlannerTrainTracking.canStart(departure, details: try details(), leg: leg, selectedServer: "A", currentServer: "B", now: observed))
        #expect(!PlannerTrainTracking.canStart(departure, details: try details(), leg: leg, selectedServer: "A", currentServer: "A", now: observed.addingTimeInterval(91)))
        #expect(!PlannerTrainTracking.canStart(departure, details: try details(), leg: leg, selectedServer: "A", currentServer: "A", now: start.addingTimeInterval(1)))
        #expect(LiveActivityManager.startingDeparture(preferredServiceID: "missing", departures: [departure], requirePreferredService: true) == nil)
        #expect(LiveActivityManager.startingDeparture(preferredServiceID: "missing", departures: [departure])?.serviceID == departure.serviceID)
        #expect(LiveActivityManager.startingDeparture(preferredServiceID: departure.serviceID, departures: [departure], requirePreferredService: true)?.serviceID == departure.serviceID)

        #expect(!PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed.addingTimeInterval(91)))
        let wholePattern = leg.serviceCallingPoints
        leg.serviceCallingPoints = nil
        #expect(!PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed))
        leg.serviceCallingPoints = wholePattern
        leg.tracking = PlannerTrackingReference(providerServiceId: "wrong-ID", station: "KTH", uid: "P12345", originDate: "2026-09-17", verifiedAt: observed)
        #expect(!PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed))
        leg.tracking = PlannerTrackingReference(providerServiceId: "public-ID", station: "KTH", uid: "P12345", originDate: "2026-09-17", verifiedAt: observed)
        #expect(PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed))
        leg.uid = "WRONG"
        #expect(!PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed))
        leg.uid = "P12345"
        #expect(PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed))
        leg.tracking = PlannerTrackingReference(providerServiceId: "public-ID", station: "KTH", uid: "P12345", originDate: "2026-09-16", verifiedAt: observed)
        #expect(!PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed))
        leg.tracking = nil
        detail["subsequentCallingPoints"] = [["callingPoint": [["crs": "VIC", "locationName": "VIC", "st": "00:16"]]]]
        #expect(!PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed))
        detail["isCancelled"] = true
        #expect(!PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed))
    }

    @Test func publicClocksCannotDisambiguateAutumnFoldOrNormalizeSpringGap() throws {
        let decode: (String) throws -> Date = { try PlannerTime.decoder().decode(Date.self, from: JSONEncoder().encode($0)) }
        for value in ["2026-10-25T00:30:00Z", "2026-10-25T01:30:00Z", "2026-03-29T01:30:00Z"] {
            let expected = try decode(value)
            let publicTime = PlannerTrainTracking.date("01:30", near: expected)
            #expect(publicTime == nil)
        }
        let normal = try decode("2026-10-26T01:30:00Z")
        #expect(PlannerTrainTracking.date("01:30", near: normal) == normal)
        let observed = try decode("2026-10-25T01:10:00Z")
        let departure = DepartureV2(departureTime: .init(scheduled: "01:30", estimated: "On time"), serviceType: "train",
            platform: nil, isCancelled: false, length: nil, destination: [], origin: nil, serviceID: "public-ID",
            delayReason: nil, cancelReason: nil, timestamp: observed, operatorCode: "SE")
        let raw: [String: Any] = ["kind": "vehicle", "mode": "rail", "operator": "SE",
            "from": ["crs": "KTH", "name": "KTH"], "to": ["crs": "VIC", "name": "VIC"],
            "departure": "2026-10-26T01:30:00Z", "arrival": "2026-10-26T02:00:00Z"]
        let tomorrow = try PlannerTime.decoder().decode(PlannedJourney.Leg.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(!PlannerTrainTracking.matchesBoard(departure, leg: tomorrow, now: observed))
    }

    private func journey(live: PlannerLiveAnnotation?, departure: Date? = nil) throws -> PlannedJourney {
        let start = departure ?? now.addingTimeInterval(600)
        var leg: [String: Any] = ["kind": "vehicle", "mode": "rail", "from": ["crs": "KTH", "name": "Kent House"],
            "to": ["crs": "VIC", "name": "London Victoria"], "departure": PlannerTime.iso8601(start),
            "arrival": PlannerTime.iso8601(start.addingTimeInterval(1200))]
        if let live {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var container = encoder.singleValueContainer()
                try container.encode(PlannerTime.iso8601(date))
            }
            leg["live"] = try JSONSerialization.jsonObject(with: encoder.encode(live))
        }
        let raw: [String: Any] = ["id": UUID().uuidString, "departure": PlannerTime.iso8601(start),
            "arrival": PlannerTime.iso8601(start.addingTimeInterval(1200)), "durationMinutes": 20, "changes": 0, "legs": [leg]]
        return try PlannerTime.decoder().decode(PlannedJourney.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    private func result(journeys: [PlannedJourney] = []) throws -> PlannerSearchResponse {
        var raw = try #require(JSONSerialization.jsonObject(with: Data(JourneyPlannerTests.emptyResult.utf8)) as? [String: Any])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PlannerTime.iso8601(date))
        }
        raw["journeys"] = try JSONSerialization.jsonObject(with: encoder.encode(journeys))
        return try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: JSONSerialization.data(withJSONObject: raw))
    }

    private func group(_ codes: [String]) -> JourneyGroup {
        let id = UUID()
        let stations = codes.map { Station(crs: $0, name: $0, longitude: "0", latitude: "51") }
        return JourneyGroup(id: id, legs: zip(stations, stations.dropFirst()).enumerated().map { index, pair in
            Journey(id: UUID(), groupId: id, legIndex: index, fromStation: pair.0, toStation: pair.1, createdAt: now, favorite: true)
        })
    }
}

@MainActor private final class RouteBoardStub: SavedRouteBoardServing {
    var routeBoardsServerIdentity = "fixture"
    var requests: [[SavedRouteQuery]] = []
    var status = "ready"
    var result: PlannerSearchResponse?
    var failure: Error?
    var boardError: PlannerError?
    var progress: SavedRouteBoardProgress?
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func routeBoards(_ routes: [SavedRouteQuery]) async throws -> SavedRouteBoardsResponse {
        requests.append(routes)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        return SavedRouteBoardsResponse(apiVersion: 3, boards: routes.map {
            SavedRouteBoard(id: $0.id, status: status, pollAfterMs: 20000, result: result, computedAt: nil, expiresAt: nil, error: boardError, progress: progress)
        })
    }
}
