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

    @Test func v4SwitchesBetweenDirectAndPlannedWithoutResurrectingThePreviousSource() async throws {
        let client = RouteBoardStub()
        client.apiVersion = 4
        client.source = "planned"
        client.result = try result()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])
        await store.refresh(groups: [route])
        #expect(store.state(for: route).result != nil)
        client.source = "direct"
        client.result = nil
        client.direct = JourneyDeparturesSnapshot(departures: [], dataStatus: .live, lastSuccessfulUpdate: now)
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).usesDirectDepartures)
        #expect(store.state(for: route).result == nil)
        client.failure = PlannerError(code: "NETWORK", message: "Offline")
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).usesDirectDepartures)
        #expect(store.state(for: route).directAvailability(at: now)?.status == .stale)
        client.failure = nil
        client.source = "planned"
        client.direct = nil
        client.status = "queued"
        await store.refresh(groups: [route], force: true)
        #expect(!store.state(for: route).usesDirectDepartures)
        #expect(store.state(for: route).result == nil)
        #expect(store.state(for: route).isPending)
    }

    @Test func directSnapshotsAcceptBothKeyStylesAndKeepOriginalObservationAge() throws {
        for (status, updated) in [("data_status", "last_successful_update"), ("dataStatus", "lastSuccessfulUpdate")] {
            let data = try JSONSerialization.data(withJSONObject: ["departures": [], status: "live", updated: PlannerTime.iso8601(now)])
            let direct = try PlannerTime.decoder().decode(JourneyDeparturesSnapshot.self, from: data)
            let board = SavedRouteBoard(id: "r", status: "ready", pollAfterMs: nil, result: nil,
                computedAt: now.addingTimeInterval(500), expiresAt: nil, error: nil, source: "direct", direct: direct)
            let state = SavedRouteBoardState(board: board)
            #expect(state.directAvailability(at: now)?.status == .live)
            #expect(state.directAvailability(at: now.addingTimeInterval(91))?.status == .stale)
            #expect(state.directAvailability(at: now.addingTimeInterval(91))?.lastSuccessfulUpdate == now)
        }
    }

    @Test func verifiedDirectServiceViaRequiredStopsPresentsOneTrainWithoutChangingSavedLegs() {
        let route = group(["KTH", "BMS", "VIC"])
        let presented = SavedRouteDirectPresentation.throughGroup(route)
        #expect(presented.id == route.id)
        #expect(presented.legs.count == 1)
        #expect(presented.legs[0].fromStation.crs == "KTH")
        #expect(presented.legs[0].toStation.crs == "VIC")
        #expect(presented.favorite == route.favorite)
        #expect(route.stationSequence.map(\.crs) == ["KTH", "BMS", "VIC"])
        #expect(route.legs.count == 2)
    }

    @Test func directScheduledOverrideChangesTimeAndOrderWhileKeepingDisruptionEvidence() {
        let observed = PlannerTime.dateOnly("2026-09-17")!.addingTimeInterval(12 * 3600)
        let delayed = DepartureV2(departureTime: .init(scheduled: "12:10", estimated: "12:30"), serviceType: "train", platform: "2",
            isCancelled: false, length: 8, destination: [], origin: nil, serviceID: "delayed", delayReason: "A delay", cancelReason: nil, timestamp: observed)
        let onTime = DepartureV2(departureTime: .init(scheduled: "12:20", estimated: "On time"), serviceType: "train", platform: "1",
            isCancelled: false, length: 8, destination: [], origin: nil, serviceID: "on-time", delayReason: nil, cancelReason: nil, timestamp: observed)
        #expect(SavedRouteDirectPresentation.upcoming([delayed, onTime], useLiveTimes: true, now: observed).map(\.id) == ["on-time", "delayed"])
        #expect(SavedRouteDirectPresentation.upcoming([delayed, onTime], useLiveTimes: false, now: observed).map(\.id) == ["delayed", "on-time"])
        #expect(SavedRouteDirectPresentation.time(delayed, useLiveTimes: false) == "12:10")
        #expect(delayed.departureTime.estimated == "12:30")
        #expect(delayed.delayReason == "A delay")
        #expect(SavedRouteDirectPresentation.upcoming([delayed, onTime], useLiveTimes: false, now: observed.addingTimeInterval(25 * 60)).isEmpty)
        #expect(SavedRouteDirectPresentation.upcoming([delayed, onTime], useLiveTimes: true, now: observed.addingTimeInterval(25 * 60)).map(\.id) == ["delayed"])
    }

    @Test func unknownDirectDelayStaysVisibleAndCachedClocksDoNotBecomeTomorrowsTrain() {
        let observed = PlannerTime.dateOnly("2026-09-17")!.addingTimeInterval(12 * 3600)
        let delayed = DepartureV2(departureTime: .init(scheduled: "11:55", estimated: "Delayed"), serviceType: "train", platform: nil,
            isCancelled: false, length: nil, destination: [], origin: nil, serviceID: "waiting", delayReason: "Awaiting an update", cancelReason: nil, timestamp: nil)
        #expect(SavedRouteDirectPresentation.upcoming([delayed], useLiveTimes: true, now: observed, observedAt: observed).map(\.id) == ["waiting"])
        #expect(SavedRouteDirectPresentation.upcoming([delayed], useLiveTimes: false, now: observed, observedAt: observed).isEmpty)
        #expect(SavedRouteDirectPresentation.upcoming([delayed], useLiveTimes: true,
            now: observed.addingTimeInterval(2 * 3600), observedAt: observed).isEmpty)
        let tomorrow = observed.addingTimeInterval(23 * 3600)
        #expect(SavedRouteDirectPresentation.upcoming([delayed], useLiveTimes: true, now: tomorrow, observedAt: observed).isEmpty)
        #expect(SavedRouteDirectPresentation.departureDate(delayed, useLiveTimes: true, now: tomorrow, observedAt: observed)
            == observed.addingTimeInterval(-5 * 60))
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
        #expect(store.state(for: route).message == nil)
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).message == nil)
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).message == "Offline")
        client.failure = nil
        client.status = "ready"
        client.result = try result()
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).message == nil)
        #expect(store.state(for: route).consecutiveFailures == 0)
        #expect(!store.state(for: route).usesLegacyDepartures)
    }

    @Test func onlyExplicitUnsupportedResponseEnablesLegacyDepartures() async {
        let client = RouteBoardStub()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])
        client.failure = PlannerError(code: "HTTP_503", message: "Unavailable")
        await store.refresh(groups: [route])
        #expect(!store.state(for: route).usesLegacyDepartures)
        #expect(store.state(for: route).isPending)
        client.failure = SavedRouteBoardError.unsupported
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).usesLegacyDepartures)
    }

    @Test func missingPlannedResultAllowsDepartureFallbackAndRetriesPromptly() async throws {
        let client = RouteBoardStub()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "STP"])
        #expect(!store.state(for: route).hasPlannedResult)

        client.failure = PlannerError(code: "NETWORK_TIMEOUT", message: "Timed out")
        await store.refresh(groups: [route])
        #expect(!store.state(for: route).hasPlannedResult)
        #expect(store.state(for: route).nextRefresh == now.addingTimeInterval(3))
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).nextRefresh == now.addingTimeInterval(6))

        client.failure = nil
        client.result = try result()
        await store.refresh(groups: [route], force: true)
        #expect(store.state(for: route).hasPlannedResult)
    }

    @Test func boardFailuresOnlyShowAfterRepeatedFailuresAndResetAfterRecovery() async throws {
        let client = RouteBoardStub()
        client.result = try result()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])
        await store.refresh(groups: [route])
        client.status = "error"
        client.boardError = PlannerError(code: "SEARCH_TIMEOUT", message: "Refresh failed")
        for attempt in 1...3 {
            await store.refresh(groups: [route], force: true)
            #expect(store.state(for: route).result != nil)
            #expect(store.state(for: route).message == (attempt == 3 ? "Refresh failed" : nil))
        }
        client.status = "ready"
        client.boardError = nil
        await store.refresh(groups: [route], force: true)
        #expect(!store.state(for: route).hasPersistentFailure)
        #expect(store.state(for: route).message == nil)
    }

    @Test func partialLiveRefreshWarningsWaitForRepeatedFailures() async throws {
        let client = RouteBoardStub()
        var option = try journey(live: nil)
        option.warnings = ["Live times could not be refreshed; scheduled times are shown."]
        client.result = try result(journeys: [option])
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])
        for attempt in 1...3 {
            await store.refresh(groups: [route], force: true)
            #expect(store.state(for: route).hasPersistentFailure == (attempt == 3))
            #expect(store.state(for: route).result?.journeys.count == 1)
        }
        option.warnings = ["A lift is unavailable."]
        client.result = try result(journeys: [option])
        await store.refresh(groups: [route], force: true)
        #expect(!store.state(for: route).hasPersistentFailure)
        #expect(!PlannerLivePresentation.isRefreshFailureWarning("A lift is unavailable."))
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
        var justRequested = SavedRouteBoardState()
        justRequested.requestedAt = now
        justRequested.waitingForCapacity = true
        #expect(justRequested.showsActivity)

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
        client.boardError = nil
        client.progress = SavedRouteBoardProgress(phase: "searching", queuedAt: now.addingTimeInterval(-70),
            startedAt: now.addingTimeInterval(-20), completedWindows: 3, totalWindows: 8)
        await store.refresh(groups: [route], force: true)
        client.status = "ready"
        client.result = try result()
        client.progress = nil
        await store.refresh(groups: [route], force: true)
        #expect(!store.state(for: route).isPending)
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
    }

    @Test func moreDeparturesSearchesTheFollowingSixHourWindowWithoutChangingSavedStops() async throws {
        let client = RouteBoardStub()
        client.result = try result()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC", "INV"])
        await store.searchLater(for: route)
        let query = try #require(client.requests.first?.first)
        #expect(query.realtime == "apply")
        #expect(query.time == PlannerTime.iso8601(now.addingTimeInterval(6 * 60 * 60)))
        #expect(query.via == ["VIC"])
        #expect(store.laterState(for: route)?.isPending == false)
        #expect(route.stationSequence.map(\.crs) == ["KTH", "VIC", "INV"])

        await store.searchLater(for: route)
        #expect(client.requests.count == 1)
        #expect(store.laterState(for: route)?.result != nil)
    }

    @Test func moreDeparturesStopsPollingOnceScheduledOptionsAreAvailable() async throws {
        let client = RouteBoardStub()
        client.status = "refreshing"
        client.result = try result()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])

        await store.searchLater(for: route)

        #expect(client.requests.count == 1)
        #expect(store.laterState(for: route)?.result != nil)
        #expect(store.laterState(for: route)?.isPending == true)
    }

    @Test func moreDeparturesReportsCapacityInsteadOfPollingAnUnadmittedSearch() async {
        let client = RouteBoardStub()
        client.source = "direct"
        client.status = "unavailable"
        client.boardError = PlannerError(code: "SEARCH_CAPACITY", message: "Journey options are busy. Try again shortly.")
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])

        await store.searchLater(for: route)
        #expect(client.requests.count == 1)
        #expect(store.laterState(for: route)?.message == "Journey options are busy. Try again shortly.")
    }

    @Test func plannedAndLaterBoardsMergeChronologicallyWithPrimaryCopyOfOverlap() throws {
        let first = try mergeJourney(
            id: "first",
            serviceID: "first-service",
            departure: now.addingTimeInterval(600)
        )
        let scheduledOverlap = now.addingTimeInterval(3600)
        let primaryOverlap = try mergeJourney(
            id: "primary-overlap",
            serviceID: "shared-service",
            departure: scheduledOverlap,
            scheduledDeparture: scheduledOverlap
        )
        let supplementalOverlap = try mergeJourney(
            id: "supplemental-overlap",
            serviceID: "shared-service",
            departure: scheduledOverlap.addingTimeInterval(120),
            scheduledDeparture: scheduledOverlap
        )
        let last = try mergeJourney(
            id: "last",
            serviceID: "last-service",
            departure: now.addingTimeInterval(7 * 3600)
        )
        let expired = try mergeJourney(
            id: "expired",
            serviceID: "expired-service",
            departure: now.addingTimeInterval(-60)
        )

        let merged = SavedRouteJourneyPresentation.merged(
            primary: try result(journeys: [primaryOverlap, expired, first]),
            supplemental: try result(journeys: [last, supplementalOverlap]),
            at: now
        )

        #expect(merged.map(\.journey.id) == ["first", "primary-overlap", "last"])
    }

    @Test func laterSearchRetriesAutomaticallyAndCanBeRetriedManually() async throws {
        let client = RouteBoardStub()
        let store = SavedRoutePlannerStore(client: client, now: { now })
        let route = group(["KTH", "VIC"])
        client.failure = PlannerError(code: "NETWORK", message: "Offline")

        await store.searchLater(for: route)
        #expect(client.requests.count == 3)
        #expect(store.laterState(for: route)?.message == "Offline")

        client.failure = nil
        client.result = try result()
        await store.retryLater(for: route)
        #expect(client.requests.count == 4)
        #expect(store.laterState(for: route)?.result != nil)
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

    @Test func dynamicV4TrainUsesItsCompleteLiveBranchForTrackingWithoutATimetableUID() throws {
        let observed = PlannerTime.dateOnly("2026-09-17")!.addingTimeInterval(12 * 3600)
        let place: (String) -> [String: String] = { ["crs": $0, "name": $0] }
        let dated: (Int) -> String = { PlannerTime.iso8601(observed.addingTimeInterval(Double($0) * 60)) }
        let raw: [String: Any] = ["kind": "vehicle", "mode": "rail", "operator": "SN", "serviceId": "live:ORG:new-provider-ID",
            "from": place("ORG"), "to": place("DST"), "departure": dated(5), "arrival": dated(25),
            "scheduledDeparture": dated(5), "scheduledArrival": dated(25),
            "callingPoints": [["station": place("ORG"), "departure": dated(5)], ["station": place("DST"), "arrival": dated(25)]],
            "serviceCallingPoints": [["station": place("BEF"), "arrival": dated(-15)],
                ["station": place("ORG"), "departure": dated(5)], ["station": place("DST"), "arrival": dated(25)],
                ["station": place("AFT"), "arrival": dated(45)]]]
        var leg = try PlannerTime.decoder().decode(PlannedJourney.Leg.self, from: JSONSerialization.data(withJSONObject: raw))
        let departure = DepartureV2(departureTime: .init(scheduled: "12:05", estimated: "On time"), serviceType: "train", platform: "2",
            isCancelled: false, length: nil, destination: [], origin: nil, serviceID: "new-provider-ID", delayReason: nil,
            cancelReason: nil, timestamp: observed, operatorCode: "SN")
        var detail: [String: Any] = ["generatedAt": dated(0), "serviceType": "train", "crs": "ORG", "locationName": "ORG",
            "operatorCode": "SN", "std": "12:05", "previousCallingPoints": [["callingPoint": [["crs": "BEF", "locationName": "BEF", "st": "11:45"]]]],
            "subsequentCallingPoints": [["callingPoint": [["crs": "DST", "locationName": "DST", "st": "12:25"],
                ["crs": "AFT", "locationName": "AFT", "st": "12:45"]]]]]
        func details() throws -> ServiceDetails { try PlannerTime.decoder().decode(ServiceDetails.self, from: JSONSerialization.data(withJSONObject: detail)) }
        #expect(leg.uid == nil && leg.originDate == nil && leg.tracking == nil)
        #expect(PlannerTrainTracking.canStart(departure, details: try details(), leg: leg, selectedServer: "A", currentServer: "A", now: observed))
        let wholePattern = leg.serviceCallingPoints
        leg.serviceCallingPoints = leg.callingPoints
        #expect(!PlannerTrainTracking.matches(departure, details: try details(), leg: leg, now: observed))
        leg.serviceCallingPoints = wholePattern
        detail["subsequentCallingPoints"] = [["callingPoint": [["crs": "DST", "locationName": "DST", "st": "12:25"],
            ["crs": "AFT", "locationName": "AFT", "st": "12:46"]]]]
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

    private func mergeJourney(
        id: String,
        serviceID: String,
        departure: Date,
        scheduledDeparture: Date? = nil
    ) throws -> PlannedJourney {
        let scheduled = scheduledDeparture ?? departure
        let arrival = departure.addingTimeInterval(1200)
        let scheduledArrival = scheduled.addingTimeInterval(1200)
        let station: (String) -> [String: String] = { ["crs": $0, "name": $0] }
        let leg: [String: Any] = [
            "kind": "vehicle",
            "mode": "rail",
            "operator": "SE",
            "serviceId": serviceID,
            "originDate": "2027-01-15",
            "from": station("KTH"),
            "to": station("VIC"),
            "departure": PlannerTime.iso8601(departure),
            "arrival": PlannerTime.iso8601(arrival),
            "scheduledDeparture": PlannerTime.iso8601(scheduled),
            "scheduledArrival": PlannerTime.iso8601(scheduledArrival),
            "callingPoints": [
                ["station": station("KTH"), "departure": PlannerTime.iso8601(scheduled)],
                ["station": station("VIC"), "arrival": PlannerTime.iso8601(scheduledArrival)]
            ]
        ]
        let raw: [String: Any] = [
            "id": id,
            "departure": PlannerTime.iso8601(departure),
            "arrival": PlannerTime.iso8601(arrival),
            "scheduledDeparture": PlannerTime.iso8601(scheduled),
            "scheduledArrival": PlannerTime.iso8601(scheduledArrival),
            "durationMinutes": 20,
            "changes": 0,
            "legs": [leg]
        ]
        return try PlannerTime.decoder().decode(
            PlannedJourney.self,
            from: JSONSerialization.data(withJSONObject: raw)
        )
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
    var apiVersion = 3
    var source: String?
    var direct: JourneyDeparturesSnapshot?
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    func routeBoards(_ routes: [SavedRouteQuery]) async throws -> SavedRouteBoardsResponse {
        requests.append(routes)
        if hold { await withCheckedContinuation { continuation = $0 } }
        if let failure { throw failure }
        return SavedRouteBoardsResponse(apiVersion: apiVersion, boards: routes.map {
            SavedRouteBoard(id: $0.id, status: status, pollAfterMs: 20000, result: result, computedAt: nil, expiresAt: nil, error: boardError,
                progress: progress, source: source, direct: direct)
        })
    }
}
