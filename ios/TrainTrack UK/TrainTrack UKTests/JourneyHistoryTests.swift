import Foundation
import Testing
@testable import TrainTrack_UK

struct JourneyHistoryTests {
    @Test func delayRepayRequiresConfirmedActualArrival() {
        let scheduled = Date(timeIntervalSince1970: 1_000_000)

        #expect(JourneyHistoryDelayPolicy.confirmedDelayMinutes(
            scheduledArrival: scheduled,
            actualArrival: nil
        ) == nil)
        #expect(JourneyHistoryDelayPolicy.confirmedDelayMinutes(
            scheduledArrival: scheduled,
            actualArrival: scheduled.addingTimeInterval(14 * 60)
        ) == 14)
        #expect(JourneyHistoryDelayPolicy.confirmedDelayMinutes(
            scheduledArrival: scheduled,
            actualArrival: scheduled.addingTimeInterval(15 * 60)
        ) == JourneyHistoryDelayPolicy.delayRepayThresholdMinutes)
    }

    @Test func journeyTimesResolveAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let reference = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 17,
            hour: 23,
            minute: 58
        )))
        let arrival = try #require(JourneyHistoryTime.date(
            for: "00:07",
            near: reference,
            calendar: calendar
        ))

        #expect(calendar.component(.day, from: arrival) == 18)
        #expect(calendar.component(.hour, from: arrival) == 0)
        #expect(calendar.component(.minute, from: arrival) == 7)
    }

    @Test @MainActor func historyUsesABoundedLocalRecordCount() {
        #expect(JourneyHistoryStore.maximumRecordCount == 2_000)
    }

    @Test @MainActor func activeJourneyMonitoringHasASafetyExpiry() {
        #expect(JourneyTrackingCoordinator.maximumActiveJourneyDuration == 24 * 60 * 60)
    }

    @Test func boardingNotificationUsesScheduledTimeAndKnownDelay() {
        #expect(JourneyHistoryNotificationText.boarding(
            scheduledDeparture: "17:27",
            estimatedDeparture: "17:32",
            destinationName: "Kent House"
        ) == "You’re on the delayed 17:27 to Kent House, currently 5 minutes late. Enjoy your journey!")
        #expect(JourneyHistoryNotificationText.boarding(
            scheduledDeparture: "17:27",
            estimatedDeparture: "On time",
            destinationName: "Kent House"
        ) == "You’re on the 17:27 to Kent House. Enjoy your journey!")
        #expect(JourneyHistoryNotificationText.boarding(
            scheduledDeparture: "17:27",
            estimatedDeparture: "Delayed",
            destinationName: "Kent House"
        ) == "You’re on the delayed 17:27 to Kent House. Enjoy your journey!")
    }

    @Test func officialArrivalUsesDestinationInPreviousCallingPoints() throws {
        let kentHouse = CallingPoint(
            locationName: "Kent House",
            crs: "KTH",
            st: "17:47",
            et: "On time",
            at: "17:46",
            isCancelled: false,
            cancelReason: nil,
            platform: "2",
            length: 8,
            detachFront: false,
            affectedByDiversion: false,
            rerouteDelay: 0
        )
        let details = ServiceDetails(
            previousCallingPoints: [CallingPointList(
                callingPoint: [kentHouse],
                serviceType: "train",
                serviceChangeRequired: false,
                assocIsCancelled: false
            )],
            subsequentCallingPoints: nil,
            generatedAt: "2026-08-17T17:52:00Z",
            serviceType: "train",
            locationName: "Orpington",
            crs: "ORP",
            operator: "Southeastern",
            operatorCode: "SE",
            isCancelled: false,
            length: 8,
            detachFront: false,
            isReverseFormation: false,
            platform: "4",
            sta: "18:10",
            eta: "On time",
            ata: nil,
            std: nil,
            etd: nil,
            atd: nil,
            delayReason: nil,
            cancelReason: nil
        )

        let point = try #require(JourneyHistoryOfficialArrivalResolver.destinationCallingPoint(
            in: details,
            destinationCRS: "KTH"
        ))

        #expect(point.st == "17:47")
        #expect(point.at == "17:46")
    }

    @Test func historyArrivalStatusUsesConfirmedOfficialTiming() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let arrival = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 17,
            hour: 17,
            minute: 46
        )))

        #expect(JourneyHistoryArrivalStatusText.text(
            actualArrival: arrival,
            detectedArrival: nil,
            delayMinutes: 0,
            outcome: .completed,
            calendar: calendar
        ) == "Arrived on time, at 17:46")
        #expect(JourneyHistoryArrivalStatusText.text(
            actualArrival: arrival.addingTimeInterval(2 * 60),
            detectedArrival: nil,
            delayMinutes: 2,
            outcome: .completed,
            calendar: calendar
        ) == "Arrived 2 mins late, at 17:48")
        #expect(JourneyHistoryArrivalStatusText.text(
            actualArrival: arrival.addingTimeInterval(20 * 60),
            detectedArrival: nil,
            delayMinutes: 20,
            outcome: .completed,
            calendar: calendar
        ) == "Arrived 20 mins late, at 18:06")
    }

    @Test func historyArrivalStatusMarksOfficialTimingUnavailableAfterOneHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let detectedArrival = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 17,
            hour: 17,
            minute: 46
        )))

        #expect(JourneyHistoryArrivalStatusText.text(
            actualArrival: nil,
            detectedArrival: detectedArrival,
            delayMinutes: nil,
            outcome: .completed,
            now: detectedArrival.addingTimeInterval(59 * 60),
            calendar: calendar
        ) == "Official arrival pending, detected at 17:46")
        #expect(JourneyHistoryArrivalStatusText.text(
            actualArrival: nil,
            detectedArrival: detectedArrival,
            delayMinutes: nil,
            outcome: .completed,
            now: detectedArrival.addingTimeInterval(60 * 60),
            calendar: calendar
        ) == "Detected at 17:46 (official arrival unavailable)")
    }

    @Test func journeyHistoryCSVExcludesInternalIdentifiers() {
        let header = JourneyHistoryExporter.csv(records: [])
            .split(separator: "\n")
            .first

        #expect(header == "Source,Outcome,Planned origin,Planned destination,Recorded destination,Detected departure,Detected arrival,Scheduled arrival,Official arrival,Delay minutes,Leg,Operator,Service,Leg origin,Leg destination")
    }

    @Test func delayRepaySubmissionWindowIsTwentyEightDays() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(JourneyHistoryDelayPolicy.submissionDeadlineDays == 28)
        #expect(JourneyHistoryDelayPolicy.isWithinSubmissionWindow(
            completedAt: now.addingTimeInterval(-27 * 24 * 60 * 60),
            now: now
        ))
        #expect(!JourneyHistoryDelayPolicy.isWithinSubmissionWindow(
            completedAt: now.addingTimeInterval(-29 * 24 * 60 * 60),
            now: now
        ))
    }

    @Test func operatorSummaryDeduplicatesAndCountsUniqueOperators() {
        #expect(JourneyHistoryOperatorSummary.text(for: [
            "Southeastern",
            " Southeastern ",
            "Thameslink",
            "Elizabeth line",
            "thameslink"
        ]) == "Southeastern +2 more")
        #expect(JourneyHistoryOperatorSummary.text(for: [
            "ScotRail",
            "ScotRail",
            nil,
            "  "
        ]) == "ScotRail")
    }

    @Test func delayRepayUsesTheFirstLegWithAConfirmedQualifyingDelay() throws {
        let departure = Date(timeIntervalSince1970: 2_000_000_000)
        let kentHouse = station(crs: "KTH", name: "Kent House")
        let herneHill = station(crs: "HNH", name: "Herne Hill")
        let farringdon = station(crs: "ZFD", name: "Farringdon")
        let firstScheduledArrival = departure.addingTimeInterval(11 * 60)
        let secondDeparture = departure.addingTimeInterval(20 * 60)
        let secondScheduledArrival = secondDeparture.addingTimeInterval(17 * 60)
        let legs = [
            JourneyHistoryLeg(
                plannedLegIndex: 0,
                fromStation: kentHouse,
                toStation: herneHill,
                operatorName: "Southeastern",
                operatorCode: "SE",
                detectedDepartureAt: departure,
                detectedArrivalAt: firstScheduledArrival.addingTimeInterval(20 * 60),
                scheduledArrivalAt: firstScheduledArrival,
                actualArrivalAt: firstScheduledArrival.addingTimeInterval(20 * 60),
                outcome: .completed
            ),
            JourneyHistoryLeg(
                plannedLegIndex: 1,
                fromStation: herneHill,
                toStation: farringdon,
                operatorName: "Thameslink",
                operatorCode: "TL",
                detectedDepartureAt: secondDeparture.addingTimeInterval(20 * 60),
                detectedArrivalAt: secondScheduledArrival.addingTimeInterval(20 * 60),
                scheduledArrivalAt: secondScheduledArrival,
                actualArrivalAt: secondScheduledArrival.addingTimeInterval(20 * 60),
                outcome: .completed
            )
        ]
        let checkpoint = ActiveJourneyHistoryCheckpoint(
            id: UUID(),
            subscriptionId: "delay-repay-test",
            source: .scheduled,
            plannedStations: [kentHouse, herneHill, farringdon],
            createdAt: departure,
            phase: .arriving,
            plannedLegIndex: 1,
            originArrivedAt: departure,
            detectedDepartureAt: departure,
            detectedArrivalAt: legs.last?.detectedArrivalAt,
            lastConfirmedOnRouteStation: farringdon,
            nextExpectedCallingPointIndex: 1,
            legs: legs,
            stationEvents: [],
            approachNotificationSent: true,
            backendSessionID: nil,
            serviceMatchConfidence: 1,
            unexpectedStation: nil,
            unexpectedStationObservedAt: nil,
            serviceDepartedStationCRS: farringdon.crs,
            serviceDepartedStationAt: legs.last?.detectedArrivalAt,
            updatedAt: legs.last?.detectedArrivalAt ?? departure
        )
        let record = JourneyHistoryRecord(
            checkpoint: checkpoint,
            outcome: .completed,
            completedAt: legs.last?.detectedArrivalAt ?? departure
        )

        let responsibleLeg = try #require(JourneyHistoryDelayPolicy.responsibleOperatorLeg(in: record))
        #expect(responsibleLeg.operatorCode == "SE")
    }

    private func station(crs: String, name: String) -> Station {
        Station(crs: crs, name: name, longitude: "0", latitude: "0")
    }
}
