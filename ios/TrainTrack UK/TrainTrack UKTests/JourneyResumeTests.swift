import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct JourneyResumeTests {
    private let departure = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func resumingPreservesTheOriginalJourneyAndDiscardsStaleDetectionState() throws {
        let original = checkpoint()
        let now = departure.addingTimeInterval(10 * 60)
        let saved = completion(original)
        let restored = try JSONDecoder().decode(
            RecentlyCompletedJourneyCheckpoint.self,
            from: JSONEncoder().encode(saved)
        )
        let resumed = try #require(restored.resumableCheckpoint(at: now))

        #expect(resumed.id == original.id)
        #expect(resumed.subscriptionId == original.subscriptionId)
        #expect(resumed.source == .scheduled)
        #expect(resumed.createdAt == original.createdAt)
        #expect(resumed.detectedDepartureAt == departure)
        #expect(resumed.originArrivedAt == original.originArrivedAt)
        #expect(resumed.plannedStations == original.plannedStations)
        #expect(resumed.plannedLegIndex == original.plannedLegIndex)
        #expect(resumed.lastConfirmedOnRouteStation == original.lastConfirmedOnRouteStation)
        #expect(resumed.nextExpectedCallingPointIndex == original.nextExpectedCallingPointIndex)
        #expect(resumed.legs == original.legs)
        #expect(resumed.stationEvents == original.stationEvents)
        #expect(resumed.serviceMatchConfidence == original.serviceMatchConfidence)
        #expect(resumed.phase == .inTransit)
        #expect(resumed.updatedAt == now)
        #expect(resumed.detectedArrivalAt == nil)
        #expect(resumed.deviceBasedArrivalAt == nil)
        #expect(resumed.backendSessionID == nil)
        #expect(resumed.unexpectedStation == nil)
        #expect(resumed.unexpectedStationObservedAt == nil)
        #expect(resumed.serviceDepartedStationCRS == nil)
        #expect(resumed.serviceDepartedStationAt == nil)
    }

    @Test func resumingAtAnInterchangeKeepsTheNextLegAwaitingBoarding() throws {
        var original = checkpoint()
        let interchange = original.lastConfirmedOnRouteStation
        original.plannedStations.insert(interchange, at: 1)
        original.legs = [JourneyHistoryLeg(
            plannedLegIndex: 0,
            fromStation: original.plannedOrigin,
            toStation: interchange,
            serviceID: "first-leg",
            detectedDepartureAt: departure,
            detectedArrivalAt: departure.addingTimeInterval(8 * 60),
            outcome: .completed
        )]
        original.phase = .atInterchange

        let resumed = try #require(completion(original).resumableCheckpoint(
            at: departure.addingTimeInterval(10 * 60)
        ))

        #expect(resumed.phase == .atInterchange)
        #expect(resumed.plannedLegIndex == 0)
        #expect(resumed.legs == original.legs)
        #expect(resumed.currentPlannedLegDestination == interchange)
    }

    @Test(arguments: [JourneyHistoryOutcome.completed, .offCourse, .uncertain])
    func onlyEndedEarlyJourneysCanResume(outcome: JourneyHistoryOutcome) {
        #expect(completion(checkpoint(), outcome: outcome).resumableCheckpoint(
            at: departure.addingTimeInterval(10 * 60)
        ) == nil)
    }

    @Test(arguments: [-1.0, 86_400.0, 86_401.0])
    func resumeRejectsFutureOrExpiredOriginalDeparture(age: TimeInterval) {
        #expect(completion(checkpoint()).resumableCheckpoint(
            at: departure.addingTimeInterval(age)
        ) == nil)
    }

    @Test func resumeLifetimeUsesOriginalDepartureRatherThanWhenRecordingStopped() {
        let saved = completion(checkpoint())
        #expect(saved.resumableCheckpoint(at: departure.addingTimeInterval(86_399)) != nil)
        #expect(saved.resumableCheckpoint(at: departure.addingTimeInterval(86_400)) == nil)
    }

    @Test func incompleteItinerariesCannotResume() {
        let original = checkpoint()
        var tooFewStations = original
        tooFewStations.plannedStations = [original.plannedOrigin]
        var negativeLegIndex = original
        negativeLegIndex.plannedLegIndex = -1
        var pastLastLeg = original
        pastLastLeg.plannedLegIndex = original.plannedStations.count - 1
        var missingLeg = original
        missingLeg.legs = []

        for invalid in [tooFewStations, negativeLegIndex, pastLastLeg, missingLeg] {
            #expect(completion(invalid).resumableCheckpoint(
                at: departure.addingTimeInterval(10 * 60)
            ) == nil)
        }
    }

    @Test func historyRecordStoresAResumableSnapshotWithTheOriginalIdentityAndItinerary() throws {
        let original = checkpoint()
        let record = JourneyHistoryRecord(
            checkpoint: original,
            outcome: .endedEarly,
            completedAt: departure.addingTimeInterval(8 * 60)
        )
        let stored = try JSONDecoder().decode(
            ActiveJourneyHistoryCheckpoint.self,
            from: #require(record.resumeCheckpointData)
        )
        let resumableJourney = try #require(record.resumableJourney)
        let resumed = try #require(resumableJourney.resumableCheckpoint(
            at: departure.addingTimeInterval(10 * 60)
        ))

        #expect(stored == original)
        #expect(resumed.id == record.id)
        #expect(resumed.plannedStations == original.plannedStations)
        #expect(resumed.detectedDepartureAt == record.detectedDepartureAt)
        #expect(resumed.legs == record.legs)
        #expect(resumed.stationEvents == record.stationEvents)
        #expect(record.plannedOriginCRS == "KTH")
        #expect(record.plannedDestinationCRS == "VIC")
        #expect(record.recordedDestinationCRS == "SYH")
        #expect(record.outcome == .endedEarly)
    }

    @Test func olderHistoryWithoutAResumeSnapshotRemainsReadable() {
        let record = JourneyHistoryRecord(
            checkpoint: checkpoint(),
            outcome: .endedEarly,
            completedAt: departure.addingTimeInterval(8 * 60)
        )
        record.resumeCheckpointData = nil

        #expect(record.resumableJourney == nil)
        #expect(record.plannedDestinationCRS == "VIC")
        #expect(record.recordedDestinationCRS == "SYH")
        #expect(record.legs.count == 1)
        #expect(record.stationEvents.count == 3)
    }

    @Test func completedHistoryCannotResumeEvenWithAnEncodedCheckpoint() throws {
        let original = checkpoint()
        let record = JourneyHistoryRecord(
            checkpoint: original,
            outcome: .completed,
            completedAt: departure.addingTimeInterval(20 * 60)
        )
        #expect(record.resumeCheckpointData == nil)
        record.resumeCheckpointData = try JSONEncoder().encode(original)
        #expect(record.resumableJourney == nil)
    }

    @Test func corruptOrDifferentJourneySnapshotCannotResume() throws {
        let record = JourneyHistoryRecord(
            checkpoint: checkpoint(),
            outcome: .endedEarly,
            completedAt: departure.addingTimeInterval(8 * 60)
        )
        record.resumeCheckpointData = Data("invalid checkpoint".utf8)
        #expect(record.resumableJourney == nil)
        record.resumeCheckpointData = try JSONEncoder().encode(checkpoint())
        #expect(record.resumableJourney == nil)
    }

    private func completion(
        _ checkpoint: ActiveJourneyHistoryCheckpoint,
        outcome: JourneyHistoryOutcome = .endedEarly
    ) -> RecentlyCompletedJourneyCheckpoint {
        RecentlyCompletedJourneyCheckpoint(
            checkpoint: checkpoint,
            outcome: outcome,
            completedAt: departure.addingTimeInterval(8 * 60),
            autoDismissAt: departure.addingTimeInterval(18 * 60)
        )
    }

    private func checkpoint() -> ActiveJourneyHistoryCheckpoint {
        let origin = Station(crs: "KTH", name: "Kent House", longitude: "0", latitude: "0")
        let destination = Station(crs: "VIC", name: "London Victoria", longitude: "0", latitude: "0")
        let intermediate = Station(crs: "SYH", name: "Sydenham Hill", longitude: "0", latitude: "0")
        let stoppedAt = departure.addingTimeInterval(8 * 60)
        let leg = JourneyHistoryLeg(
            plannedLegIndex: 0,
            fromStation: origin,
            toStation: destination,
            serviceID: "original-kth-vic-service",
            operatorName: "Southeastern",
            detectedDepartureAt: departure,
            scheduledDepartureAt: departure,
            actualDepartureAt: departure,
            scheduledArrivalAt: departure.addingTimeInterval(21 * 60)
        )
        return ActiveJourneyHistoryCheckpoint(
            id: UUID(),
            subscriptionId: "scheduled-kth-vic",
            source: .scheduled,
            plannedStations: [origin, destination],
            createdAt: departure.addingTimeInterval(-5 * 60),
            phase: .inTransit,
            plannedLegIndex: 0,
            originArrivedAt: departure.addingTimeInterval(-60),
            detectedDepartureAt: departure,
            detectedArrivalAt: stoppedAt,
            deviceBasedArrivalAt: stoppedAt,
            lastConfirmedOnRouteStation: intermediate,
            nextExpectedCallingPointIndex: 4,
            legs: [leg],
            stationEvents: [
                JourneyHistoryStationEvent(station: origin, kind: .arrival, detectedAt: departure.addingTimeInterval(-60)),
                JourneyHistoryStationEvent(station: origin, kind: .departure, detectedAt: departure),
                JourneyHistoryStationEvent(station: intermediate, kind: .arrival, detectedAt: stoppedAt)
            ],
            approachNotificationSent: false,
            backendSessionID: "stopped-backend-session",
            serviceMatchConfidence: 0.98,
            unexpectedStation: intermediate,
            unexpectedStationObservedAt: stoppedAt,
            serviceDepartedStationCRS: intermediate.crs,
            serviceDepartedStationAt: stoppedAt.addingTimeInterval(-139),
            updatedAt: stoppedAt
        )
    }
}
