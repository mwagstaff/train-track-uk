import Foundation
import MapKit
import Testing
@testable import TrainTrack_UK

@Suite(.serialized)
@MainActor
struct JourneyPlannerTests {
    private let origin = PlannerStation(crs: "KTH", name: "Kent House")
    private let destination = PlannerStation(crs: "VIC", name: "London Victoria")
    private let now = Date(timeIntervalSince1970: 1_799_999_000)

    @Test func savedRouteBoardsUseAdditiveEndpointAndOnly404EnablesFallback() async throws {
        let session = stubSession()
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.com/api/v2" }, clientID: "installation")
        let station = Station(crs: "KTH", name: "Kent House", longitude: "0", latitude: "51")
        let destination = Station(crs: "VIC", name: "Victoria", longitude: "0", latitude: "51")
        let leg = Journey(fromStation: station, toStation: destination)
        let query = SavedRouteQuery(group: JourneyGroup(id: leg.groupId, legs: [leg]))
        PlannerStubProtocol.handler = { request in
            #expect(request.url?.path == "/api/v3/journey-planner/route-boards")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "X-Planner-Client") == "installation")
            let body = try #require(JSONSerialization.jsonObject(with: PlannerStubProtocol.body(request)) as? [String: Any])
            let routes = try #require(body["routes"] as? [[String: Any]])
            #expect(routes[0]["via"] as? [String] == [])
            return (404, Data("Not found".utf8))
        }
        await #expect(throws: SavedRouteBoardError.self) { try await client.routeBoards([query]) }
        PlannerStubProtocol.handler = { _ in (503, Data(#"{"error":{"code":"SEARCH_BUSY","message":"Please wait"}}"#.utf8)) }
        do {
            _ = try await client.routeBoards([query])
            Issue.record("Expected the structured server failure")
        } catch let error as PlannerError { #expect(error.code == "SEARCH_BUSY") }
        session.invalidateAndCancel()
    }

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

    @Test func departureMetadataDecodesWhenAvailableAndRemainsOptionalForOlderServers() throws {
        let current = try PlannerTime.decoder().decode(PlannerLiveAnnotation.self, from: Data(
            #"{"status":"onTime","platform":"2","length":10}"#.utf8
        ))
        #expect(current.platform == "2")
        #expect(current.length == 10)
        let old = try PlannerTime.decoder().decode(PlannerLiveAnnotation.self, from: Data(
            #"{"status":"onTime"}"#.utf8
        ))
        #expect(old.platform == nil)
        #expect(old.length == nil)
    }

    @Test func liveModeDefaultsToApplyForOldRecentsAndPreservesManualOverride() throws {
        let original = intent(mode: .now)
        let saved = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(PlannerSearchIntent.self, from: saved)
        #expect(try restored.request(now: now).realtime == "apply")
        var scheduled = original
        scheduled.realtime = "ignore"
        #expect(try scheduled.request(now: now).realtime == "ignore")
        #expect(original.matches(scheduled))
        let recents = PlannerRecentSearchStore(defaults: isolatedDefaults())
        recents.record(original, at: now)
        recents.record(scheduled, at: now.addingTimeInterval(30))
        #expect(recents.searches.count == 1)
        #expect(recents.searches[0].intent.realtime == "ignore")
        let store = makeStore()
        store.restore(recents.searches[0])
        #expect(!store.useLiveTimes)
    }

    @Test func changingLiveModeRepeatsOriginalInstantWithoutUsingPageCursor() async throws {
        let service = PlannerStubService()
        service.results = [try result(ids: ["original"]), try result(ids: ["scheduled"]), try result(ids: ["page"])]
        let store = makeStore(client: service)
        store.origin = origin
        store.destination = destination
        await store.search(now: now)
        store.useLiveTimes = false
        await store.search(repeatingLastSearch: true, now: now.addingTimeInterval(90))
        #expect(service.requests.map(\.realtime) == ["apply", "ignore"])
        #expect(service.requests.map(\.time) == [PlannerTime.iso8601(now), PlannerTime.iso8601(now)])
        #expect(service.requests.allSatisfy { $0.cursor == nil })
        #expect(store.response?.journeys.map(\.id) == ["scheduled"])
        #expect(store.recents.searches.count == 1)
        #expect(store.recents.searches[0].intent.timeMode == .now)
        #expect(store.recents.searches[0].intent.realtime == "ignore")
        await store.search(cursor: "later", now: now.addingTimeInterval(180))
        #expect(service.requests.last?.realtime == "ignore")
        #expect(service.requests.last?.cursor == "later")
    }

    @Test func changingLiveModeKeepsTheDisplayedAdjacentWindowAndOriginalRecentIntent() async throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(Self.emptyResult.utf8)) as? [String: Any])
        let shifted = now.addingTimeInterval(6 * 3600)
        var search = try #require(json["search"] as? [String: Any])
        search["time"] = PlannerTime.iso8601(shifted)
        json["search"] = search
        let later = try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: JSONSerialization.data(withJSONObject: json))
        let service = PlannerStubService()
        service.results = [try result(ids: ["original"]), later, later]
        let store = makeStore(client: service)
        store.origin = origin
        store.destination = destination
        await store.search(now: now)
        await store.search(cursor: "later", now: now)
        store.useLiveTimes = false
        await store.search(repeatingLastSearch: true, now: now.addingTimeInterval(60))
        #expect(service.requests.last?.time == PlannerTime.iso8601(shifted))
        #expect(service.requests.last?.cursor == nil)
        #expect(service.requests.last?.realtime == "ignore")
        #expect(store.recents.searches.count == 1)
        #expect(store.recents.searches[0].intent.timeMode == .now)
        #expect(store.recents.searches[0].intent.explicitTime == nil)
    }

    @Test func liveModeRerunKeepsPreviousResultsVisibleAndIgnoresCancelledCompletion() async throws {
        let service = PlannerStubService()
        service.results = [try result(ids: ["original"])]
        let store = makeStore(client: service)
        store.origin = origin
        store.destination = destination
        await store.search(now: now)
        service.holdSearches = true
        store.useLiveTimes = false
        let task = Task { await store.search(repeatingLastSearch: true, now: now) }
        while service.pending.isEmpty { await Task.yield() }
        #expect(store.isSearching)
        #expect(store.response?.journeys.map(\.id) == ["original"])
        task.cancel()
        store.cancelSearch()
        service.pending[0].resume(returning: try result(ids: ["late"]))
        await task.value
        #expect(store.response?.journeys.map(\.id) == ["original"])
        #expect(store.recents.searches[0].intent.realtime == "apply")
        #expect(store.useLiveTimes)
        #expect(store.searchError == nil)
    }

    @Test func liveContextAndDisruptedOptionsPersistAcrossMorePages() async throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(Self.emptyResult.utf8)) as? [String: Any])
        json["live"] = ["mode": "apply", "status": "partial", "windowHours": 4,
                        "warnings": ["Some live times are unavailable."]]
        json["disruptedJourneys"] = [["id": "cancelled", "departure": "2026-09-15T12:00:00Z",
                                     "arrival": "2026-09-15T12:21:00Z", "durationMinutes": 21,
                                     "changes": 0, "legs": [], "warnings": ["The connection can no longer be made."]]]
        json["pagination"] = ["more": "more"]
        let first = try PlannerTime.decoder().decode(PlannerSearchResponse.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(first.live?.mode == "apply")
        #expect(first.live?.status == "partial")
        #expect(first.live?.windowHours == 4)
        let disrupted = try #require(first.disruptedJourneys?.first)
        #expect(PlannerLivePresentation.warnings(for: disrupted) == ["The connection can no longer be made."])
        let service = PlannerStubService()
        var second = try result(ids: ["next"])
        second.disruptedJourneys = [disrupted, try #require(result(ids: ["another-cancelled"]).journeys.first)]
        service.results = [first, second, try result(ids: ["later-window"])]
        let store = makeStore(client: service)
        store.origin = origin
        store.destination = destination
        await store.search(now: now)
        await store.search(cursor: "more", now: now)
        #expect(store.response?.disruptedJourneys?.map(\.id) == ["cancelled", "another-cancelled"])
        await store.search(cursor: "later", now: now)
        #expect(store.response?.disruptedJourneys == nil)
    }

    @Test func liveAnnotationsPreserveScheduledIdentityAndSelectedPortionMeaning() throws {
        let text = #"{"id":"live-journey","departure":"2026-09-16T13:10:00Z","arrival":"2026-09-16T13:31:00Z","durationMinutes":21,"changes":0,"legs":[{"kind":"vehicle","mode":"rail","from":{"crs":"KTH","name":"Kent House"},"to":{"crs":"VIC","name":"London Victoria"},"departure":"2026-09-16T13:10:00Z","arrival":"2026-09-16T13:31:00Z","scheduledDeparture":"2026-09-16T13:00:00Z","scheduledArrival":"2026-09-16T13:21:00Z","scheduledServiceId":"scheduled-original","live":{"status":"partCancelled","cancelled":false,"partCancelled":true,"departure":"2026-09-16T13:10:00Z","arrival":"2026-09-16T13:31:00Z","departureDelayMinutes":10,"warnings":["Another section of this train is cancelled."]},"callingPoints":[{"station":{"crs":"PNE","name":"Penge East"},"departure":"2026-09-16T13:12:00Z","scheduledDeparture":"2026-09-16T13:02:00Z","live":{"status":"cancelled","cancelled":true,"partCancelled":true,"warnings":["This stop is cancelled."]}}]}]}"#
        let journey = try PlannerTime.decoder().decode(PlannedJourney.self, from: Data(text.utf8))
        let leg = try #require(journey.legs.first)
        let live = try #require(leg.live)
        #expect(!live.isCancelled)
        #expect(live.isDelayed)
        #expect(leg.scheduledDeparture?.timeIntervalSince(leg.departure) == -600)
        #expect(leg.scheduledServiceId == "scheduled-original")
        #expect(leg.callingPoints?.first?.live?.isCancelled == true)
        #expect(PlannerLivePresentation.warnings(for: journey) == ["Another section of this train is cancelled."])
        #expect(PlannerLivePresentation.title(for: PlannerLiveAnnotation(status: "unknown")) == "Live status unknown")
        #expect(PlannerLivePresentation.title(for: PlannerLiveAnnotation(status: "partCancelled", cancelled: false, partCancelled: true)) == "Part cancelled")
    }

    @Test func journeyOnTimeSummaryRequiresCompleteCoverageAndIgnoresTubeAllowances() {
        let place = PlannedJourney.Place(crs: "KTH", name: "Kent House")
        let onTime = PlannerLiveAnnotation(status: "onTime", departure: now, arrival: now.addingTimeInterval(600))
        func rail(_ live: PlannerLiveAnnotation?) -> PlannedJourney.Leg {
            PlannedJourney.Leg(kind: "vehicle", mode: "rail", from: place, to: place,
                departure: now, arrival: now.addingTimeInterval(600), operator: nil,
                serviceId: nil, originDate: nil, callingPoints: nil, transfer: nil, warnings: nil, live: live)
        }
        let tube = PlannedJourney.Leg(kind: "transfer", mode: "tubeTransfer", from: place, to: place,
            departure: now, arrival: now.addingTimeInterval(600), operator: nil,
            serviceId: nil, originDate: nil, callingPoints: nil, transfer: nil, warnings: nil)
        func summary(_ legs: [PlannedJourney.Leg]) -> String? {
            PlannerLivePresentation.onTimeSummary(for: PlannedJourney(id: "coverage", departure: now,
                arrival: now.addingTimeInterval(3600), durationMinutes: 60, changes: 1, legs: legs))
        }
        #expect(summary([rail(onTime), tube, rail(nil)]) == "1 of 2 trains confirmed on time")
        #expect(summary([rail(onTime), tube, rail(onTime)]) == "All trains on time")
        #expect(summary([rail(onTime), rail(PlannerLiveAnnotation(status: "unknown"))]) == "1 of 2 trains confirmed on time")
        #expect(summary([rail(onTime), rail(PlannerLiveAnnotation(status: "delayed", departureDelayMinutes: 5))]) == "1 of 2 trains confirmed on time")
        var partCancelled = onTime
        partCancelled.partCancelled = true
        #expect(summary([rail(onTime), rail(partCancelled)]) == "1 of 2 trains confirmed on time")
        var incomplete = onTime
        incomplete.arrival = nil
        #expect(summary([rail(incomplete)]) == nil)
        #expect(summary([tube]) == nil)
        #expect(summary([rail(onTime)]) == "Train on time")
    }

    @Test func genericTransferInformationDoesNotHideActualTravelWarnings() {
        let generic = "This is a supplied generic transfer; detailed local departures and stops are not available."
        let place = PlannedJourney.Place(crs: "VIC", name: "London Victoria")
        let tube = PlannedJourney.Leg(kind: "transfer", mode: "tubeTransfer", from: place, to: place,
            departure: now, arrival: now.addingTimeInterval(600), operator: nil,
            serviceId: nil, originDate: nil, callingPoints: nil, transfer: nil,
            warnings: [generic, "The Tube station is closed."])
        let journey = PlannedJourney(id: "warning", departure: now, arrival: now.addingTimeInterval(600),
            durationMinutes: 10, changes: 0, legs: [tube], warnings: [generic, "A connection may be missed."])
        #expect(PlannerLivePresentation.warnings(for: journey) == ["A connection may be missed.", "The Tube station is closed."])
        #expect(PlannerLivePresentation.visibleWarnings([generic, "Some live rail updates could not be retrieved."])
            == ["Some live rail updates could not be retrieved."])
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

    @Test func journeyTimeRangesOnlyIncludeDatesWhenCrossingLondonMidnight() throws {
        let formatter = ISO8601DateFormatter()
        let departure = try #require(formatter.date(from: "2026-09-16T10:57:00+01:00"))
        let arrival = try #require(formatter.date(from: "2026-09-16T20:08:00+01:00"))
        #expect(PlannerTime.displayRange(from: departure, to: arrival) == "10:57 → 20:08")
        #expect(PlannerTime.displayRange(from: departure, to: arrival, separator: " – ") == "10:57 – 20:08")
        let lateDeparture = try #require(formatter.date(from: "2026-09-16T22:55:00Z"))
        let nextDayArrival = try #require(formatter.date(from: "2026-09-16T23:30:00Z"))
        #expect(PlannerTime.displayRange(from: lateDeparture, to: nextDayArrival) == "Wed 16 Sep, 23:55 → Thu 17 Sep, 00:30")
    }

    @Test func legHeadingsDescribeTransportAndStationChangesAndMapPointsIncludeEndpoints() throws {
        let from = PlannedJourney.Place(crs: "KTH", name: "Kent House")
        let to = PlannedJourney.Place(crs: "VIC", name: "London Victoria")
        let intermediate = PlannedJourney.CallingPoint(station: .init(crs: "PNE", name: "Penge East"), arrival: now, departure: now)
        func leg(_ kind: String, _ mode: String, destination: PlannedJourney.Place? = nil,
                 points: [PlannedJourney.CallingPoint]? = nil) -> PlannedJourney.Leg {
            .init(kind: kind, mode: mode, from: from, to: destination ?? to, departure: now,
                  arrival: now.addingTimeInterval(300), operator: nil, serviceId: nil, originDate: nil,
                  callingPoints: points, transfer: nil, warnings: nil)
        }
        let train = leg("vehicle", "rail", points: [intermediate])
        #expect(train.heading == "Train from Kent House to London Victoria")
        #expect(train.mapCallingPoints.map(\.station.crs) == ["KTH", "PNE", "VIC"])
        #expect(leg("transfer", "tubeTransfer").heading == "Tube from Kent House to London Victoria")
        #expect(leg("vehicle", "replacementBus").heading == "Replacement bus from Kent House to London Victoria")
        let change = leg("transfer", "interchange", destination: from)
        #expect(change.isTrainChange)
        #expect(change.heading == "Change trains at Kent House")
        let fullPoints = [PlannedJourney.CallingPoint(station: from, arrival: nil, departure: now), intermediate,
                          PlannedJourney.CallingPoint(station: to, arrival: now, departure: nil)]
        #expect(leg("vehicle", "rail", points: fullPoints).mapCallingPoints == fullPoints)
    }

    @Test func plannerMapHighlightsJourneyEndpointsAndEveryConnection() throws {
        let kth = PlannedJourney.Place(crs: "KTH", name: "Kent House")
        let vic = PlannedJourney.Place(crs: "VIC", name: "London Victoria")
        let eus = PlannedJourney.Place(crs: "EUS", name: "London Euston")
        let inv = PlannedJourney.Place(crs: "INV", name: "Inverness")
        func leg(_ from: PlannedJourney.Place, _ to: PlannedJourney.Place, mode: String = "rail") -> PlannedJourney.Leg {
            .init(kind: mode == "rail" ? "vehicle" : "transfer", mode: mode, from: from, to: to,
                  departure: now, arrival: now.addingTimeInterval(300), operator: "SE", serviceId: nil,
                  originDate: nil, callingPoints: nil, transfer: nil, warnings: nil)
        }
        let journey = PlannedJourney(id: "test", departure: now, arrival: now.addingTimeInterval(900), durationMinutes: 15,
            changes: 2, legs: [leg(kth, vic), leg(vic, eus, mode: "tubeTransfer"), leg(eus, inv)])
        #expect(PlannerJourneyRouteMap.stationRole(crs: "KTH", journey: journey) == .origin)
        #expect(PlannerJourneyRouteMap.stationRole(crs: "VIC", journey: journey) == .change)
        #expect(PlannerJourneyRouteMap.stationRole(crs: "EUS", journey: journey) == .change)
        #expect(PlannerJourneyRouteMap.stationRole(crs: "INV", journey: journey) == .destination)
        #expect(PlannerJourneyRouteMap.stationRole(crs: "PNE", journey: journey) == .stop)
        let train = journey.legs[0]
        func departure(at date: Date, code: String = "SE") -> DepartureV2 {
            .init(departureTime: .init(scheduled: PlannerTime.display(train.departure, includeDate: false), estimated: "On time"),
                  serviceType: "train", platform: nil, isCancelled: false, length: nil, destination: [], origin: nil,
                  serviceID: "live", delayReason: nil, cancelReason: nil, timestamp: date, operatorCode: code)
        }
        #expect(PlannerMapLiveService.matches(departure(at: now), leg: train, at: now))
        #expect(!PlannerMapLiveService.matches(departure(at: now.addingTimeInterval(86400)), leg: train, at: now))
        #expect(!PlannerMapLiveService.matches(departure(at: now, code: "GR"), leg: train, at: now))
    }

    @Test func liveRouteAddsPreBoardingTrackWhenPlannerOnlyContainsTravelledStops() throws {
        let from = PlannedJourney.Place(crs: "KTH", name: "Kent House")
        let to = PlannedJourney.Place(crs: "VIC", name: "London Victoria")
        let leg = PlannedJourney.Leg(kind: "vehicle", mode: "rail", from: from, to: to, departure: now,
            arrival: now.addingTimeInterval(1260), operator: "SE", serviceId: nil, originDate: nil,
            callingPoints: nil, transfer: nil, warnings: nil)
        let journey = PlannedJourney(id: "test", departure: now, arrival: leg.arrival, durationMinutes: 21, changes: 0, legs: [leg])
        #expect(leg.serviceCallingPoints == nil)
        let coordinates = [CLLocationCoordinate2D(latitude: 51.3735, longitude: 0.0891),
                           CLLocationCoordinate2D(latitude: 51.4123, longitude: -0.0452),
                           CLLocationCoordinate2D(latitude: 51.4952, longitude: -0.1441)]
        let route = ServiceRailwayRoute(coordinates: coordinates, cumulativeDistances: [0, 10000, 20000], stationCoordinateIndices: [0, 1, 2])
        let stations = try JSONDecoder().decode([CallingPoint].self, from: Data(#"[{"crs":"ORP","locationName":"Orpington","st":"12:37"},{"crs":"KTH","locationName":"Kent House","st":"12:57"},{"crs":"VIC","locationName":"London Victoria","st":"13:18"}]"#.utf8))
        let live = PlannerMapLiveService(serviceID: "live", stations: stations, route: route, generatedAt: now)
        let region = MKCoordinateRegion(center: coordinates[1], span: .init(latitudeDelta: 0.1, longitudeDelta: 0.1))
        let map = PlannerJourneyRouteMap(legs: [.init(id: 0, coordinates: Array(coordinates[1...]), isConnection: false)],
            stops: [.init(id: "KTH", label: "Kent House", coordinate: coordinates[1], isSelected: true, role: .origin),
                    .init(id: "VIC", label: "London Victoria", coordinate: coordinates[2], isSelected: true, role: .destination)],
            hasMissingLegs: false, selectedRegion: region, wholeRegion: region)
        let updated = map.including(live, journey: journey)
        let background = try #require(updated.legs.first)
        #expect(background.id != 0)
        #expect(background.coordinates.first?.longitude == coordinates[0].longitude)
        #expect(updated.legs.first(where: { $0.id == 0 })?.coordinates.count == 2)
        #expect(updated.stops.first(where: { $0.id == "ORP" })?.isSelected == false)
        #expect(updated.stops.first(where: { $0.id == "KTH" })?.role == .origin)
        #expect(updated.wholeRegion.center.longitude + updated.wholeRegion.span.longitudeDelta / 2 >= coordinates[0].longitude)
        #expect(updated.selectedRegion.span.longitudeDelta == region.span.longitudeDelta)
        let refreshed = updated.including(live, journey: journey)
        #expect(refreshed.legs.count == updated.legs.count)
        #expect(refreshed.stops.count == updated.stops.count)
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
        PlannerStubProtocol.handler = PlannerStubProtocol.legacy { request in
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
        PlannerStubProtocol.handler = PlannerStubProtocol.legacy { _ in
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
            PlannerStubProtocol.handler = PlannerStubProtocol.legacy { request in
                #expect(request.timeoutInterval == 30)
                return (504, Data(body.utf8))
            }
            await #expect(throws: PlannerError(code: "HTTP_504", message: "This search took too long. Try again, or choose a different time.")) {
                try await client.search(request)
            }
        }
        PlannerStubProtocol.handler = PlannerStubProtocol.legacy { _ in (502, Data("Bad Gateway".utf8)) }
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
        PlannerStubProtocol.handler = PlannerStubProtocol.legacy { _ in
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
        PlannerStubProtocol.handler = PlannerStubProtocol.legacy { _ in throw URLError(.timedOut) }
        await #expect(throws: PlannerError(code: "NETWORK_TIMEOUT", message: "This search took too long. Try again, or choose a different time.")) {
            try await client.search(request)
        }
        await #expect(throws: PlannerError(code: "NETWORK_TIMEOUT", message: "The journey planner took too long to respond. Please try again.")) {
            try await client.status()
        }
        PlannerStubProtocol.handler = PlannerStubProtocol.legacy { _ in throw URLError(.cancelled) }
        do {
            _ = try await client.search(request)
            Issue.record("Expected the transport cancellation to be preserved.")
        } catch {
            #expect((error as? URLError)?.code == .cancelled)
        }
    }

    @Test func queuedSearchPinsHostReportsProgressAndKeepsCursorOnlyBody() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
        let clock = PlannerTestClock()
        var selected = "https://first.test/prefix/api/v2"
        let log = PlannerRequestLog()
        PlannerStubProtocol.handler = { request in
            let number = log.append(request)
            switch number {
            case 1: return (202, Self.job("queued", position: 2, pollAfterMs: 1))
            case 2: return (200, Self.job("running", pollAfterMs: 99_000))
            default: return (200, Self.job("completed"))
            }
        }
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { selected }, clientID: "installation", timing: clock.timing)
        var request = try intent(mode: .now).request(now: now)
        request.cursor = "opaque-page"
        var progress: [PlannerSearchProgress] = []
        let result = try await client.search(request) { state in
            progress.append(state)
            selected = "https://second.test/api/v2"
        }
        #expect(result.journeys.isEmpty)
        #expect(progress == [.queued(position: nil), .queued(position: 2), .running])
        #expect(clock.sleeps == [0.5, 5])
        let requests = log.requests
        #expect(requests.map(\.httpMethod) == ["POST", "GET", "GET"])
        #expect(requests.allSatisfy { $0.url?.host == "first.test" && $0.url?.path.hasPrefix("/prefix/api/v3/journey-planner/search-jobs") == true })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Planner-Client") == "installation" })
        #expect(UUID(uuidString: requests[0].value(forHTTPHeaderField: "Idempotency-Key") ?? "") != nil)
        #expect(requests[1].value(forHTTPHeaderField: "Idempotency-Key") == nil)
        #expect(log.bodies.first.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } == ["cursor": "opaque-page"])
    }

    @Test func queuedSearchRetriesSubmissionIdempotentlyAndNeverResubmitsAcceptedJob() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
        let clock = PlannerTestClock()
        let log = PlannerRequestLog()
        PlannerStubProtocol.handler = { request in
            switch log.append(request) {
            case 1: throw URLError(.networkConnectionLost)
            case 2: return (503, Data("Unavailable".utf8))
            case 3: return (202, Self.job("running"))
            case 4: return (504, Data("Gateway timeout".utf8))
            case 5: return (429, Data("Busy".utf8))
            default: return (200, Self.job("completed"))
            }
        }
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.test/api/v2" }, timing: clock.timing)
        _ = try await client.search(intent(mode: .now).request(now: now))
        let requests = log.requests
        #expect(requests.map(\.httpMethod) == ["POST", "POST", "POST", "GET", "GET", "GET"])
        #expect(Set(requests.prefix(3).compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }).count == 1)
        #expect(Set(log.bodies.prefix(3)).count == 1)
        #expect(requests.suffix(3).allSatisfy { $0.url?.path.hasSuffix("/search-jobs/job-1") == true })
        #expect(clock.sleeps == [1, 2, 1, 1, 2])
    }

    @Test func queuedSearchCancelsLeaseAndStoreWithoutRecordingHistory() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
        let log = PlannerRequestLog()
        PlannerStubProtocol.handler = { request in
            _ = log.append(request)
            return request.httpMethod == "DELETE" ? (204, Data()) : (202, Self.job("queued", position: 1))
        }
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.test/prefix/api/v2" }, clientID: "cancel-installation")
        let store = JourneyPlannerStore(client: client, recents: PlannerRecentSearchStore(defaults: isolatedDefaults()))
        store.origin = origin
        store.destination = destination
        let task = Task { await store.search(now: now) }
        for _ in 0..<100 where store.searchProgress != .queued(position: 1) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.isSearching)
        #expect(store.searchProgress == .queued(position: 1))
        task.cancel()
        store.cancelSearch()
        await task.value
        for _ in 0..<100 where !log.requests.contains(where: { $0.httpMethod == "DELETE" }) { try await Task.sleep(for: .milliseconds(10)) }
        let deletion = try #require(log.requests.first { $0.httpMethod == "DELETE" })
        #expect(deletion.url?.absoluteString == "https://example.test/prefix/api/v3/journey-planner/search-jobs/job-1")
        #expect(deletion.value(forHTTPHeaderField: "X-Planner-Client") == "cancel-installation")
        #expect(!store.isSearching)
        #expect(store.response == nil)
        #expect(store.searchError == nil)
        #expect(store.recents.searches.isEmpty)
        #expect(log.requests.filter { $0.httpMethod == "POST" }.count == 1)
    }

    @Test func expiredOrMissingAcceptedJobsDoNotFallBackToSynchronousSearch() async throws {
        for status in [410, 404] {
            let session = stubSession()
            defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
            let log = PlannerRequestLog()
            let clock = PlannerTestClock()
            PlannerStubProtocol.handler = { request in
                _ = log.append(request)
                if request.httpMethod == "DELETE" { return (204, Data()) }
                if request.httpMethod == "POST" { return (202, Self.job("running")) }
                return (status, Data())
            }
            let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.test/api/v2" }, timing: clock.timing)
            do {
                _ = try await client.search(intent(mode: .now).request(now: now))
                Issue.record("Expected an expired or missing job error.")
            } catch let error as PlannerError {
                #expect(error.code == (status == 410 ? "SEARCH_EXPIRED" : "HTTP_404"))
                if status == 410 { #expect(error.message == "This search has expired. Please search again.") }
            }
            for _ in 0..<100 where !log.requests.contains(where: { $0.httpMethod == "DELETE" }) { try await Task.sleep(for: .milliseconds(10)) }
            #expect(log.requests.filter { $0.httpMethod == "POST" }.count == 1)
            #expect(log.requests.allSatisfy { $0.url?.path.contains("/search-jobs") == true })
        }
    }

    @Test func failedQueuedSearchPreservesServerErrorAndDoesNotRetryOrDelete() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
        let log = PlannerRequestLog()
        PlannerStubProtocol.handler = { request in
            _ = log.append(request)
            return (202, Data(#"{"id":"job-1","status":"failed","error":{"code":"UNSUPPORTED_DATE","message":"Choose a date in the timetable."}}"#.utf8))
        }
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.test/api/v2" })
        let request = try intent(mode: .now).request(now: now)
        await #expect(throws: PlannerError(code: "UNSUPPORTED_DATE", message: "Choose a date in the timetable.")) {
            try await client.search(request)
        }
        #expect(log.requests.count == 1)
    }

    @Test func queuedSearchTransientOutageStopsAfterOneMinuteWithoutChangingSubmissionKey() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
        let clock = PlannerTestClock()
        let log = PlannerRequestLog()
        PlannerStubProtocol.handler = { request in
            _ = log.append(request)
            return (503, Data(#"{"error":{"code":"SEARCH_BUSY","message":"Please try again shortly."}}"#.utf8))
        }
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.test/api/v2" }, timing: clock.timing)
        let request = try intent(mode: .now).request(now: now)
        await #expect(throws: PlannerError(code: "SEARCH_BUSY", message: "Please try again shortly.")) { try await client.search(request) }
        #expect(clock.time == 60)
        #expect(log.requests.count > 1 && log.requests.count < 20)
        #expect(Set(log.requests.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }).count == 1)
    }

    @Test func queuedSearchOverallDeadlineReleasesLease() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel(); PlannerStubProtocol.handler = nil }
        let clock = PlannerTestClock()
        clock.advancePerSleep = 600
        let log = PlannerRequestLog()
        PlannerStubProtocol.handler = { request in
            _ = log.append(request)
            return request.httpMethod == "DELETE" ? (204, Data()) : (202, Self.job("running"))
        }
        let client = JourneyPlannerClient(session: session, selectedBaseURL: { "https://example.test/api/v2" }, timing: clock.timing)
        do {
            _ = try await client.search(intent(mode: .now).request(now: now))
            Issue.record("Expected the overall search deadline.")
        } catch let error as PlannerError { #expect(error.code == "SEARCH_TIMEOUT") }
        for _ in 0..<100 where !log.requests.contains(where: { $0.httpMethod == "DELETE" }) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(clock.time == 1200)
        #expect(log.requests.map(\.httpMethod) == ["POST", "GET", "DELETE"])
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlannerStubProtocol.self]
        return URLSession(configuration: config)
    }

    nonisolated private static func job(_ status: String, position: Int? = nil, pollAfterMs: Double = 1000) -> Data {
        var envelope: [String: Any] = ["id": "job-1", "status": status, "pollAfterMs": pollAfterMs]
        envelope["queuePosition"] = position
        if status == "completed" { envelope["result"] = try! JSONSerialization.jsonObject(with: Data(emptyResult.utf8)) }
        return try! JSONSerialization.data(withJSONObject: envelope)
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
    static func legacy(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> (URLRequest) throws -> (Int, Data) {
        { request in
            if request.url?.path.hasSuffix("/search-jobs") == true { return (404, Data()) }
            return try handler(request)
        }
    }
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

@MainActor
private final class PlannerTestClock {
    var time: TimeInterval = 0
    var sleeps: [TimeInterval] = []
    var advancePerSleep: TimeInterval?
    var timing: JourneyPlannerClient.SearchTiming {
        .init(now: { self.time }, sleep: { duration in
            try Task.checkCancellation()
            self.sleeps.append(duration)
            self.time += self.advancePerSleep ?? duration
            await Task.yield()
        })
    }
}

private final class PlannerRequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    private var storedBodies: [Data] = []
    var requests: [URLRequest] { lock.withLock { stored } }
    var bodies: [Data] { lock.withLock { storedBodies } }
    func append(_ request: URLRequest) -> Int {
        lock.withLock {
            stored.append(request)
            storedBodies.append(PlannerStubProtocol.body(request))
            return stored.count
        }
    }
}
