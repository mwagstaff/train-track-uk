import Foundation
import Testing
@testable import TrainTrack_UK

struct JourneyServiceRecoveryTests {
    @Test @MainActor func interruptedMatchingRetainsItsOriginalBoardAcrossCheckpointReload() throws {
        let suite = "JourneyServiceRecoveryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var active = checkpoint()
        active.serviceMatchRecovery?.departures = [departure("17:27")]
        active.serviceMatchRecovery?.lastAttemptAt = date("17:30")
        try JourneyTrackingCheckpointStore.save(
            JourneyHistoryCheckpointEnvelope(armedCandidates: [], activeJourney: active), to: defaults
        )

        let restored = try #require(JourneyTrackingCheckpointStore.load(from: defaults)?.activeJourney)
        let recovery = try #require(restored.serviceMatchRecovery)
        #expect(restored.phase == .matchingService)
        #expect(restored.legs.isEmpty)
        #expect(recovery.detectedAt == date("17:30"))
        #expect(recovery.departures.map(\.serviceID) == ["17:27"])
        #expect(recovery.shouldRetry(in: restored, at: date("17:31")))
        #expect(match(recovery, in: restored).departure?.serviceID == "17:27")
    }

    @Test func initiallyEmptyMatchRecoversWithoutAddingAnotherLegOrLosingStationEvidence() throws {
        var active = checkpoint()
        let initial = try #require(active.serviceMatchRecovery)
        #expect(match(initial, in: active).departure == nil)
        let uncertainLeg = leg(detectedAt: initial.detectedAt)
        active = try #require(initial.applying(uncertainLeg, to: active))
        active.phase = .inTransit
        let brixton = Station(crs: "BRX", name: "Brixton", longitude: "-0.11", latitude: "51.46")
        active.stationEvents.append(JourneyHistoryStationEvent(station: brixton, kind: .arrival, detectedAt: date("17:32")))
        active.lastConfirmedOnRouteStation = brixton
        active.nextExpectedCallingPointIndex = 2
        active.serviceMatchRecovery?.departures = [departure("17:27"), departure("17:42")]
        let recovery = try #require(active.serviceMatchRecovery)
        let selected = try #require(match(recovery, in: active).departure)
        var matchedLeg = uncertainLeg
        matchedLeg.serviceID = selected.serviceID
        matchedLeg.outcome = .active

        let recovered = try #require(recovery.applying(matchedLeg, to: active))
        #expect(recovered.legs.count == 1)
        #expect(recovered.currentLeg?.id == uncertainLeg.id)
        #expect(recovered.currentLeg?.serviceID == "17:27")
        #expect(recovered.currentLeg?.detectedDepartureAt == date("17:30"))
        #expect(recovered.stationEvents == active.stationEvents)
        #expect(recovered.lastConfirmedOnRouteStation == brixton)
        #expect(recovered.nextExpectedCallingPointIndex == 2)
    }

    @Test func expiredInterruptedMatchBecomesAnUncertainLegThatCanBeCorrected() throws {
        let original = checkpoint()
        let restored = try JSONDecoder().decode(ActiveJourneyHistoryCheckpoint.self, from: JSONEncoder().encode(original))
        let recovery = try #require(restored.serviceMatchRecovery)
        #expect(recovery.interruptedFallback(in: restored, at: date("17:45")) == nil)
        let resumed = try #require(recovery.interruptedFallback(in: restored, at: date("17:50")))
        #expect(resumed.phase == .inTransit)
        #expect(resumed.legs.count == 1)
        #expect(resumed.currentLeg?.detectedDepartureAt == date("17:30"))
        #expect(resumed.currentLeg?.outcome == .uncertain)
        #expect(resumed.currentLeg?.serviceID == nil)
        #expect(resumed.currentLeg?.fromStation == original.plannedOrigin)
        #expect(resumed.currentLeg?.toStation == original.plannedDestination)
        #expect(resumed.stationEvents == original.stationEvents)
        #expect(resumed.serviceMatchRecovery == nil)
        #expect(recovery.interruptedFallback(in: resumed, at: date("17:51")) == nil)
        #expect(recovery.applying(leg(detectedAt: recovery.detectedAt), to: resumed) == nil)
    }

    @Test func laterRefreshNeverMovesTheOriginalDepartureWindow() throws {
        var active = checkpoint(detectedAt: date("17:25"))
        active.serviceMatchRecovery?.departures = [departure("17:27")]
        let recovery = try #require(active.serviceMatchRecovery)
        #expect(recovery.shouldRetry(in: active, at: date("17:32")))
        #expect(match(recovery, in: active).departure == nil)
        // Substituting refresh time would incorrectly turn this future service into a match.
        #expect(JourneyServiceMatchingPolicy.match(
            departures: recovery.departures, recentDepartures: [],
            from: active.plannedOrigin, to: active.plannedDestination,
            detectedAt: date("17:32"), originArrivedAt: active.originArrivedAt
        ).departure?.serviceID == "17:27")
    }

    @Test func ambiguityRemainsUnmatchedOnRetry() throws {
        var active = checkpoint()
        active.originArrivedAt = date("17:10")
        active.serviceMatchRecovery?.departures = [departure("17:12"), departure("17:27")]
        let recovery = try #require(active.serviceMatchRecovery)
        #expect(recovery.shouldRetry(in: active, at: date("17:33")))
        #expect(match(recovery, in: active).departure == nil)
    }

    @Test func retryKeepsTheOriginalArrivalBoundEvenWithAnExplicitOriginOverride() throws {
        var active = checkpoint()
        active.originArrivedAt = date("17:15")
        active.serviceMatchRecovery?.departures = [departure("17:12"), departure("17:27")]
        let recovery = try #require(active.serviceMatchRecovery)
        #expect(active.stationEvents.allSatisfy { $0.kind == .departure })
        #expect(active.originArrivalForServiceMatching(from: recovery.fromStation) == date("17:15"))
        #expect(match(recovery, in: active).departure?.serviceID == "17:27")
    }

    @Test func explicitUnlistedChoiceSurvivesReloadAndRejectsAnInFlightAutomaticResult() throws {
        var active = checkpoint()
        let initial = try #require(active.serviceMatchRecovery)
        active = try #require(initial.applying(leg(detectedAt: initial.detectedAt), to: active))
        active.phase = .inTransit
        let pending = try #require(active.serviceMatchRecovery)
        active.serviceMatchRecovery = nil
        let restored = try JSONDecoder().decode(ActiveJourneyHistoryCheckpoint.self, from: JSONEncoder().encode(active))
        #expect(restored.serviceMatchRecovery == nil)
        #expect(!pending.shouldRetry(in: restored, at: date("17:31")))
        var result = try #require(restored.currentLeg)
        result.serviceID = "automatic-late-result"
        #expect(pending.applying(result, to: restored) == nil)
    }

    @Test func retryCannotOverwriteCorrectionCompletionOrAnotherLeg() throws {
        var active = checkpoint()
        let initial = try #require(active.serviceMatchRecovery)
        active = try #require(initial.applying(leg(detectedAt: initial.detectedAt), to: active))
        active.phase = .inTransit
        let pending = try #require(active.serviceMatchRecovery)
        var result = try #require(active.currentLeg)
        result.serviceID = "automatic-late-result"
        var corrected = active
        corrected.legs[0].serviceID = "manual-choice"
        corrected.serviceMatchRecovery = nil
        #expect(pending.applying(result, to: corrected) == nil)
        for phase in [JourneyTrackingPhase.arriving, .atInterchange] {
            var ended = active
            ended.phase = phase
            #expect(pending.applying(result, to: ended) == nil)
        }
        var replaced = active
        replaced.legs = [leg(detectedAt: pending.detectedAt)]
        #expect(pending.applying(result, to: replaced) == nil)
    }

    @Test func manualServiceResponseCannotUpdateAnArrivingOrChangedSelection() {
        var active = checkpoint()
        active.phase = .inTransit
        active.serviceMatchRecovery = nil
        active.legs = [leg(detectedAt: active.detectedDepartureAt)]
        let legID = active.legs[0].id
        #expect(active.matchesInTransitService(journeyID: active.id, legID: legID, serviceID: nil))
        active.legs[0].serviceID = "confirmed-choice"
        #expect(!active.matchesInTransitService(journeyID: active.id, legID: legID, serviceID: nil))
        #expect(active.matchesInTransitService(journeyID: active.id, legID: legID, serviceID: "confirmed-choice"))
        #expect(!active.matchesInTransitService(journeyID: UUID(), legID: legID, serviceID: "confirmed-choice"))
        #expect(!active.matchesInTransitService(journeyID: active.id, legID: UUID(), serviceID: "confirmed-choice"))
        active.phase = .arriving
        #expect(!active.matchesInTransitService(journeyID: active.id, legID: legID, serviceID: "confirmed-choice"))
    }

    @Test func retriesAreThrottledAndExpireWithoutChangingObservationTime() throws {
        var active = checkpoint()
        active.serviceMatchRecovery?.lastAttemptAt = date("17:30")
        let recovery = try #require(active.serviceMatchRecovery)
        #expect(!recovery.shouldRetry(in: active, at: date("17:30").addingTimeInterval(29)))
        #expect(recovery.shouldRetry(in: active, at: date("17:30").addingTimeInterval(30)))
        #expect(recovery.shouldRetry(in: active, at: date("17:45")))
        #expect(!recovery.shouldRetry(in: active, at: date("17:45").addingTimeInterval(1)))
        #expect(!recovery.shouldRetry(in: active, at: date("17:29")))
    }

    @Test func detailsRecoveryRequiresACompleteCallingPatternBeforeEnablingOffRouteDetection() throws {
        var active = checkpoint()
        let initial = try #require(active.serviceMatchRecovery)
        var matched = leg(detectedAt: initial.detectedAt)
        matched.serviceID = "17:27"
        active = try #require(initial.applying(matched, to: active))
        active.phase = .inTransit
        let recovery = try #require(active.serviceMatchRecovery)
        #expect(recovery.shouldRetry(in: active, at: date("17:31")))
        #expect(!matched.hasKnownCallingPattern)
        matched.callingPoints = [point("KTH")]
        #expect(!matched.hasKnownCallingPattern)
        matched.callingPoints = [point("VIC"), point("BRX"), point("KTH")]
        #expect(matched.hasKnownCallingPattern)
        active.legs[0] = matched
        #expect(!recovery.shouldRetry(in: active, at: date("17:31")))
    }

    private func match(_ recovery: JourneyServiceMatchRecoveryContext, in active: ActiveJourneyHistoryCheckpoint) -> JourneyServiceMatchingPolicy.Match {
        JourneyServiceMatchingPolicy.match(
            departures: recovery.departures, recentDepartures: [], from: recovery.fromStation,
            to: active.currentPlannedLegDestination, detectedAt: recovery.detectedAt,
            originArrivedAt: active.originArrivalForServiceMatching(from: recovery.fromStation)
        )
    }

    private func checkpoint(detectedAt: Date? = nil) -> ActiveJourneyHistoryCheckpoint {
        let detectedAt = detectedAt ?? date("17:30")
        let origin = Station(crs: "VIC", name: "London Victoria", longitude: "-0.14", latitude: "51.50")
        let destination = Station(crs: "KTH", name: "Kent House", longitude: "-0.04", latitude: "51.41")
        return ActiveJourneyHistoryCheckpoint(
            id: UUID(), subscriptionId: "scheduled-test", source: .scheduled,
            plannedStations: [origin, destination], createdAt: date("17:00"),
            phase: .matchingService, plannedLegIndex: 0, originArrivedAt: date("17:20"),
            detectedDepartureAt: detectedAt, detectedArrivalAt: nil,
            lastConfirmedOnRouteStation: origin, nextExpectedCallingPointIndex: 1,
            legs: [], stationEvents: [JourneyHistoryStationEvent(station: origin, kind: .departure, detectedAt: detectedAt)],
            approachNotificationSent: false, backendSessionID: nil, serviceMatchConfidence: 0,
            unexpectedStation: nil, unexpectedStationObservedAt: nil,
            serviceDepartedStationCRS: nil, serviceDepartedStationAt: nil, updatedAt: detectedAt,
            serviceMatchRecovery: JourneyServiceMatchRecoveryContext(
                plannedLegIndex: 0, fromStation: origin, detectedAt: detectedAt, departures: []
            )
        )
    }

    private func leg(detectedAt: Date) -> JourneyHistoryLeg {
        let active = checkpoint(detectedAt: detectedAt)
        return JourneyHistoryLeg(
            plannedLegIndex: 0, fromStation: active.plannedOrigin, toStation: active.plannedDestination,
            detectedDepartureAt: detectedAt, outcome: .uncertain
        )
    }

    private func point(_ crs: String) -> JourneyHistoryCallingPoint {
        JourneyHistoryCallingPoint(locationName: crs, crs: crs, scheduledTime: "17:30", estimatedTime: nil, actualTime: nil)
    }

    private func departure(_ scheduled: String) -> DepartureV2 {
        DepartureV2(
            departureTime: DepartureTimeV2(scheduled: scheduled, estimated: scheduled),
            serviceType: "train", platform: nil, isCancelled: false, length: nil,
            destination: [PlaceInfoV2(crs: "KTH", locationName: "Kent House", via: nil)],
            origin: [PlaceInfoV2(crs: "VIC", locationName: "London Victoria", via: nil)],
            serviceID: scheduled, delayReason: nil, cancelReason: nil, timestamp: date("17:29")
        )
    }

    private func date(_ clock: String) -> Date {
        let values = clock.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: values[0], minute: values[1]))!
    }
}
