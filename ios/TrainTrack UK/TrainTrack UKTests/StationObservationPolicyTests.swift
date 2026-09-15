import CoreLocation
import Foundation
import Testing
@testable import TrainTrack_UK

struct StationObservationPolicyTests {
    private let deliveredAt = Date(timeIntervalSince1970: 18 * 60 * 60)

    @Test func delayedStationObservationRemainsRecoverableAtDelivery() {
        let observedAt = deliveredAt.addingTimeInterval(-4 * 60)

        #expect(StationDetectionPolicy.isRecoverableObservation(
            recordedAt: observedAt,
            now: deliveredAt
        ))
        #expect(StationDetectionPolicy.shouldProcessObservation(
            recordedAt: observedAt,
            after: nil,
            now: deliveredAt
        ))
    }

    @Test func recoveryRejectsFutureAndExpiredObservations() {
        #expect(StationDetectionPolicy.isRecoverableObservation(
            recordedAt: deliveredAt.addingTimeInterval(-60 * 60),
            now: deliveredAt
        ))
        for recordedAt in [
            deliveredAt.addingTimeInterval(-60 * 60 - 1),
            deliveredAt.addingTimeInterval(1)
        ] {
            #expect(!StationDetectionPolicy.isRecoverableObservation(
                recordedAt: recordedAt,
                now: deliveredAt
            ))
        }
    }

    @Test func replayedAndOutOfOrderObservationsCannotMoveStateBackwards() {
        let lastProcessed = deliveredAt.addingTimeInterval(-4 * 60)

        for recordedAt in [lastProcessed, lastProcessed.addingTimeInterval(-1)] {
            #expect(!StationDetectionPolicy.shouldProcessObservation(
                recordedAt: recordedAt,
                after: lastProcessed,
                now: deliveredAt
            ))
        }
        #expect(StationDetectionPolicy.shouldProcessObservation(
            recordedAt: lastProcessed.addingTimeInterval(1),
            after: lastProcessed,
            now: deliveredAt
        ))
    }

    @Test func interruptedRegionHandlingCanReplayItsPersistedObservation() {
        let observationTime = deliveredAt.addingTimeInterval(-240)

        #expect(StationDetectionPolicy.shouldProcessRegionObservation(
            recordedAt: observationTime,
            lastObservedAt: observationTime,
            lastHandledAt: nil,
            now: deliveredAt
        ))
        #expect(!StationDetectionPolicy.shouldProcessRegionObservation(
            recordedAt: observationTime,
            lastObservedAt: observationTime,
            lastHandledAt: observationTime,
            now: deliveredAt
        ))
    }

    @Test func replayCannotOverwriteANewerPersistedRegionObservation() {
        let oldObservation = deliveredAt.addingTimeInterval(-240)

        #expect(!StationDetectionPolicy.shouldProcessRegionObservation(
            recordedAt: oldObservation,
            lastObservedAt: oldObservation.addingTimeInterval(10),
            lastHandledAt: nil,
            now: deliveredAt
        ))
    }

    @Test func deliveredBatchPreservesAnEarlierArrivalBeforeDeparture() {
        let arrival = location(secondsBeforeDelivery: 240, latitude: 51.5)
        let departure = location(secondsBeforeDelivery: 180, latitude: 51.51)
        let ordered = StationDetectionPolicy.orderedLocations(
            [departure, arrival, arrival],
            after: nil,
            now: deliveredAt
        )

        #expect(ordered.map(\.timestamp) == [arrival.timestamp, departure.timestamp])
        #expect(ordered.map(\.coordinate.latitude) == [51.5, 51.51])
    }

    @Test func deliveredBatchRejectsProcessedInvalidAndExpiredFixes() {
        let previous = deliveredAt.addingTimeInterval(-300)
        let valid = location(secondsBeforeDelivery: 240)
        let fixes = [
            location(secondsBeforeDelivery: 301),
            location(secondsBeforeDelivery: 300),
            location(secondsBeforeDelivery: 3601),
            location(secondsBeforeDelivery: -1),
            location(secondsBeforeDelivery: 200, accuracy: -1),
            location(secondsBeforeDelivery: 190, accuracy: .infinity),
            location(secondsBeforeDelivery: 180, accuracy: .nan),
            valid
        ]

        let ordered = StationDetectionPolicy.orderedLocations(
            fixes,
            after: previous,
            now: deliveredAt
        )

        #expect(ordered.map(\.timestamp) == [valid.timestamp])
    }

    @Test func deliveryDelayDoesNotCreateDwellAcrossAnObservationGap() {
        let first = deliveredAt.addingTimeInterval(-240)

        #expect(StationDetectionPolicy.canContinueDwell(
            previous: first,
            observedAt: first.addingTimeInterval(8)
        ))
        #expect(StationDetectionPolicy.canContinueDwell(
            previous: first,
            observedAt: first.addingTimeInterval(30)
        ))
        for observedAt in [first.addingTimeInterval(-1), first, first.addingTimeInterval(31)] {
            #expect(!StationDetectionPolicy.canContinueDwell(
                previous: first,
                observedAt: observedAt
            ))
        }
        #expect(!StationDetectionPolicy.canContinueDwell(previous: nil, observedAt: first))
    }

    @Test @MainActor func repeatedInsideObservationsPreserveTheOriginalEntry() throws {
        let outside = StationRegionObservation(
            isInside: false,
            observedAt: deliveredAt.addingTimeInterval(-300),
            insideSince: nil
        )
        let enteredAt = deliveredAt.addingTimeInterval(-240)
        let entered = outside.updating(isInside: true, at: enteredAt)
        let stillInside = entered.updating(isInside: true, at: enteredAt.addingTimeInterval(10))

        #expect(stillInside.isInside)
        #expect(stillInside.insideSince == enteredAt)
        #expect(stillInside.observedAt == enteredAt.addingTimeInterval(10))
        let restored = try JSONDecoder().decode(
            StationRegionObservation.self,
            from: JSONEncoder().encode(stillInside)
        )
        #expect(restored == stillInside)
    }

    @Test @MainActor func exitClearsPriorEntryBeforeTheNextVisit() {
        let firstEntry = deliveredAt.addingTimeInterval(-240)
        let inside = StationRegionObservation(
            isInside: true,
            observedAt: firstEntry,
            insideSince: firstEntry
        )
        let exited = inside.updating(isInside: false, at: firstEntry.addingTimeInterval(30))
        let nextEntry = firstEntry.addingTimeInterval(60)
        let returned = exited.updating(isInside: true, at: nextEntry)

        #expect(!exited.isInside)
        #expect(exited.insideSince == nil)
        #expect(exited.lastEntryAt == firstEntry)
        #expect(returned.isInside)
        #expect(returned.insideSince == nextEntry)
        #expect(returned.lastEntryAt == nextEntry)
    }

    @Test @MainActor func presenceBeforeTheWindowCanEstablishArrivalAtItsStart() throws {
        let entry = try localDate(hour: 15, minute: 55)
        let target = scheduledTarget()
        let observation = StationRegionObservation(isInside: true, observedAt: entry, insideSince: entry)

        #expect(target.arrivalDate(from: observation, before: try localDate(hour: 16, minute: 10))
            == (try localDate(hour: 16, minute: 0)))
    }

    @Test @MainActor func aVisitCompletedBeforeTheWindowDoesNotCreateAnArrival() throws {
        let entry = try localDate(hour: 15, minute: 50)
        let innerExit = try localDate(hour: 15, minute: 55)
        let observation = StationRegionObservation(isInside: true, observedAt: entry, insideSince: entry)
            .updating(isInside: false, at: innerExit)

        #expect(scheduledTarget().arrivalDate(
            from: observation, before: try localDate(hour: 16, minute: 10)
        ) == nil)
    }

    @Test @MainActor func exitAfterWindowEndKeepsTheInWindowArrivalTime() throws {
        let entry = try localDate(hour: 17, minute: 56)
        let observation = StationRegionObservation(isInside: true, observedAt: entry, insideSince: entry)

        #expect(scheduledTarget().arrivalDate(
            from: observation, before: try localDate(hour: 18, minute: 4)
        ) == entry)
    }

    @Test @MainActor func overnightPresenceUsesThePreviousDaysWindowStart() throws {
        let entry = try localDate(hour: 23, minute: 20)
        let observation = StationRegionObservation(isInside: true, observedAt: entry, insideSince: entry)

        #expect(scheduledTarget(start: "23:30", end: "01:00").arrivalDate(
            from: observation, before: try localDate(day: 16, hour: 0, minute: 10)
        ) == (try localDate(hour: 23, minute: 30)))
    }

    @Test @MainActor func oldPresenceCannotProveAVisitDuringTheNextWindow() throws {
        let entry = try localDate(hour: 15, minute: 0)
        let observation = StationRegionObservation(isInside: true, observedAt: entry, insideSince: entry)

        #expect(scheduledTarget().arrivalDate(
            from: observation, before: try localDate(hour: 16, minute: 10)
        ) == nil)
    }

    @Test @MainActor func futurePresenceCannotChangeAnEarlierExit() throws {
        let entry = try localDate(hour: 16, minute: 20)
        let observation = StationRegionObservation(isInside: true, observedAt: entry, insideSince: entry)

        #expect(scheduledTarget().arrivalDate(
            from: observation, before: try localDate(hour: 16, minute: 10)
        ) == nil)
    }

    @MainActor private func scheduledTarget(start: String = "16:00", end: String = "18:00") -> StationArrivalTarget {
        StationArrivalTarget(
            identifier: "scheduled-presence",
            subscriptionId: "schedule-1",
            from: "VIC",
            to: "KTH",
            station: Station(crs: "VIC", name: "London Victoria", longitude: "-0.14", latitude: "51.5"),
            activeUntil: nil,
            muteOnArrival: true,
            isScheduledActivation: true,
            scheduleKind: .regular,
            daysOfWeek: [.tue],
            windowStart: start,
            windowEnd: end,
            travelDate: nil
        )
    }

    private func localDate(day: Int = 15, hour: Int, minute: Int) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: hour, minute: minute
        )))
    }

    private func location(
        secondsBeforeDelivery: TimeInterval,
        latitude: CLLocationDegrees = 51.5,
        accuracy: CLLocationAccuracy = 20
    ) -> CLLocation {
        CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: -0.14),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: 20,
            timestamp: deliveredAt.addingTimeInterval(-secondsBeforeDelivery)
        )
    }
}


extension StationObservationPolicyTests {
    @Test func aSavedExitCanFollowALaterDeliveredArrivalWithoutReplayingAnOldVisit() {
        let arrival = Date(timeIntervalSince1970: 100_000)
        let exit = StationRegionObservation(isInside: false,
            observedAt: arrival.addingTimeInterval(120), insideSince: nil)
        let receipt = arrival.addingTimeInterval(240)
        #expect(StationDetectionPolicy.isExitAfterArrival(exit, arrivedAt: arrival, now: receipt))
        #expect(!StationDetectionPolicy.isExitAfterArrival(exit,
            arrivedAt: arrival.addingTimeInterval(180), now: receipt))
        #expect(!StationDetectionPolicy.isExitAfterArrival(exit,
            arrivedAt: arrival, now: receipt.addingTimeInterval(3600)))
        let inside = exit.updating(isInside: true, at: receipt)
        #expect(!StationDetectionPolicy.isExitAfterArrival(inside, arrivedAt: arrival, now: receipt))
    }
}
