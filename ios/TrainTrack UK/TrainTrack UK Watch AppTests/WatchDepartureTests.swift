import Foundation
import Testing
@testable import TrainTrack_UK_Watch_App

@MainActor
struct WatchDepartureTests {
    private let route = WatchRoute(id: UUID(), stations: [
        WatchStation(crs: "KTH", name: "Kent House"),
        WatchStation(crs: "VIC", name: "London Victoria")
    ], favourite: true)

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "WatchTests.\(UUID())")!
    }

    @Test func libraryPersistsAndEmptySnapshotRemovesRoutes() throws {
        let defaults = defaults()
        let store = WatchLibraryStore(defaults: defaults)
        let first = WatchLibrary(routes: [route], apiBase: "https://example.com/api/v2", updatedAt: Date())
        store.receive(try JSONEncoder().encode(first))
        #expect(WatchLibraryStore(defaults: defaults).library == first)
        let empty = WatchLibrary(routes: [], apiBase: first.apiBase, updatedAt: first.updatedAt.addingTimeInterval(1))
        store.receive(try JSONEncoder().encode(empty))
        store.receive(try JSONEncoder().encode(first))
        #expect(store.library == empty)
    }

    @Test func invalidSnapshotDoesNotReplaceSavedRoutes() throws {
        let store = WatchLibraryStore(defaults: defaults())
        let valid = WatchLibrary(routes: [route], apiBase: "https://example.com/api/v2", updatedAt: Date())
        store.receive(try JSONEncoder().encode(valid))
        let invalid = WatchLibrary(routes: [WatchRoute(id: UUID(), stations: [], favourite: false)],
                                   apiBase: valid.apiBase, updatedAt: Date())
        store.receive(try JSONEncoder().encode(invalid))
        #expect(store.library == valid)
        #expect(store.syncMessage != nil)
    }

    @Test func routeRequestIncludesViaStationsAndSelectedServer() throws {
        let via = WatchRoute(id: UUID(), stations: route.stations + [WatchStation(crs: "BTN", name: "Brighton")], favourite: false)
        let request = try WatchBoardClient.request(route: via, apiBase: "https://example.com/train-track/api/v2", version: 4, clientID: "test")
        #expect(request.url?.absoluteString == "https://example.com/train-track/api/v4/journey-planner/route-boards")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: [[String: Any]]])
        #expect(body["routes"]?.first?["origin"] as? String == "KTH")
        #expect(body["routes"]?.first?["destination"] as? String == "BTN")
        #expect(body["routes"]?.first?["via"] as? [String] == ["VIC"])
        #expect(body["routes"]?.first?["realtime"] as? String == "apply")
    }

    @Test func clocksUseRailwayTimezoneAcrossMidnight() throws {
        let beforeMidnight = try #require(WatchRailTime.parse("2026-09-26T22:55:00Z"))
        let departure = try #require(WatchRailTime.clock("00:10", near: beforeMidnight))
        #expect(departure.timeIntervalSince(beforeMidnight) == 15 * 60)
        #expect(WatchRailTime.display(departure) == "00:10")
        #expect(WatchRailTime.clock("Delayed", near: beforeMidnight) == nil)
    }

    @Test func directBoardDecodesDelayCancellationAndDepartedTrains() throws {
        let data = Data(#"""
        {"apiVersion":4,"boards":[{"id":"test","status":"ready","source":"direct","direct":{
          "data_status":"live","last_successful_update":"2026-09-26T18:00:00Z","departures":[
          {"serviceID":"late","departure_time":{"scheduled":"19:05","estimated":"19:12"},"platform":"2","length":8},
          {"serviceID":"cancelled","departure_time":{"scheduled":"19:15","estimated":"Cancelled"},"isCancelled":true},
          {"serviceID":"gone","departure_time":{"scheduled":"19:00","estimated":"19:00","actual":"19:00"}}
        ]}}]}
        """#.utf8)
        let now = try #require(WatchRailTime.parse("2026-09-26T18:00:00Z"))
        let response = try JSONDecoder().decode(WatchBoardResponse.self, from: data)
        let board = try response.boards[0].presentation(at: now)
        #expect(board.departures.count == 2)
        #expect(board.departures[0].status == "7 min late")
        #expect(board.departures[0].platformLabel == "2")
        #expect(board.departures[1].cancelled)
        #expect(board.departures[1].platformLabel == "TBC")
        #expect(board.upcoming(at: now.addingTimeInterval(3600)).isEmpty)
        #expect(board.isStale(at: now.addingTimeInterval(121)))
    }

    @Test func camelCaseFreshnessIsPreserved() throws {
        let data = Data(#"{"apiVersion":4,"boards":[{"id":"test","status":"ready","source":"direct","direct":{"departures":[],"dataStatus":"stale","lastSuccessfulUpdate":"2026-09-26T18:00:00Z"}}]}"#.utf8)
        let board = try JSONDecoder().decode(WatchBoardResponse.self, from: data).boards[0].presentation(at: Date())
        #expect(board.dataStatus == "stale")
        #expect(board.observedAt == WatchRailTime.parse("2026-09-26T18:00:00Z"))
    }

    @Test func plannedBoardPreservesChangesAndTransferLegs() throws {
        let data = Data(#"""
        {"apiVersion":4,"boards":[{"id":"test","status":"ready","source":"planned","result":{
          "journeys":[{"id":"connection","departure":"2026-09-26T18:00:00Z","arrival":"2026-09-26T19:00:00Z","changes":1,"legs":[
            {"kind":"vehicle","mode":"rail","from":{"crs":"KTH","name":"Kent House"},"to":{"crs":"VIC","name":"Victoria"},"departure":"2026-09-26T18:00:00Z","arrival":"2026-09-26T18:25:00Z","live":{"status":"onTime","platform":"2"}},
            {"kind":"transfer","mode":"walk","from":{"crs":"VIC","name":"Victoria"},"to":{"crs":"VIC","name":"Victoria"},"departure":"2026-09-26T18:25:00Z","arrival":"2026-09-26T18:30:00Z"},
            {"kind":"vehicle","mode":"rail","from":{"crs":"VIC","name":"Victoria"},"to":{"crs":"BTN","name":"Brighton"},"departure":"2026-09-26T18:30:00Z","arrival":"2026-09-26T19:00:00Z","live":{"status":"cancelled"}}
          ]}],"live":{"status":"partial"}
        }}]}
        """#.utf8)
        let response = try JSONDecoder().decode(WatchBoardResponse.self, from: data)
        let journey = try #require(response.boards[0].presentation(at: Date()).departures.first)
        #expect(journey.changes == 1)
        #expect(journey.cancelled)
        #expect(journey.legs.count == 3)
        #expect(journey.legs[1].title.hasPrefix("Walk:"))
        #expect(journey.platformLabel == "2")
    }

    @Test func refreshFailureKeepsBoardAndShowsError() async {
        let client = StubBoardClient()
        let store = WatchBoardStore(client: client, defaults: defaults())
        await store.refresh(route: route, apiBase: "https://example.com/api/v2")
        let checked = store.board?.checkedAt
        client.fail = true
        await store.refresh(route: route, apiBase: "https://example.com/api/v2")
        #expect(store.board?.checkedAt == checked)
        #expect(store.errorMessage != nil)
        #expect(!store.isRefreshing)
    }

    @Test func cancelledFetchIsNotShownAsNetworkFailure() async {
        let client = StubBoardClient()
        client.cancel = true
        let store = WatchBoardStore(client: client, defaults: defaults())
        await store.refresh(route: route, apiBase: "https://example.com/api/v2")
        #expect(store.errorMessage == nil)
        #expect(!store.isRefreshing)
    }
}

@MainActor
private final class StubBoardClient: WatchBoardServing {
    var fail = false
    var cancel = false
    func fetch(route: WatchRoute, apiBase: String) async throws -> WatchBoard {
        if cancel { throw CancellationError() }
        if fail { throw URLError(.notConnectedToInternet) }
        return WatchBoard(departures: [], checkedAt: Date(), observedAt: nil, dataStatus: "live", pending: false, pollInterval: 20, message: nil)
    }
}
