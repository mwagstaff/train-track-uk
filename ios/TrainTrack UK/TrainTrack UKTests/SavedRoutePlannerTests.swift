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
        var response = try result()
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

    private func result() throws -> PlannerSearchResponse {
        try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: Data(JourneyPlannerTests.emptyResult.utf8))
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
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func routeBoards(_ routes: [SavedRouteQuery]) async throws -> SavedRouteBoardsResponse {
        requests.append(routes)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        return SavedRouteBoardsResponse(apiVersion: 3, boards: routes.map {
            SavedRouteBoard(id: $0.id, status: status, pollAfterMs: 20000, result: result, computedAt: nil, expiresAt: nil, error: nil)
        })
    }
}
