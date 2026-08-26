import Foundation
import Testing
@testable import TrainTrack_UK

struct JourneyHistoryTests {
    @Test @MainActor func historyRowPrefersPostedArrivalAndRetainsLocationFallbacks() throws {
        let detected = Date(timeIntervalSince1970: 1_000)
        let deviceBased = Date(timeIntervalSince1970: 2_000)
        let posted = Date(timeIntervalSince1970: 3_000)

        #expect(JourneyHistoryRowArrivalPolicy.resolve(
            postedArrival: posted,
            deviceBasedArrival: deviceBased,
            detectedArrival: detected
        ) == JourneyHistoryRowArrival(date: posted, qualifier: "posted arrival time"))
        #expect(JourneyHistoryRowArrivalPolicy.resolve(
            postedArrival: nil,
            deviceBasedArrival: deviceBased,
            detectedArrival: detected
        ) == JourneyHistoryRowArrival(date: deviceBased, qualifier: "based on device location"))
        #expect(JourneyHistoryRowArrivalPolicy.resolve(
            postedArrival: nil,
            deviceBasedArrival: nil,
            detectedArrival: detected
        ) == JourneyHistoryRowArrival(date: detected, qualifier: nil))
    }

    @Test @MainActor func historyClockTimesUseTwentyFourHourFormatWithLeadingZero() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let time = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 25,
            hour: 8,
            minute: 3
        )))

        #expect(JourneyHistoryClockTime.text(time, calendar: calendar) == "08:03")
    }

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

    @Test func immediatelyPrecedingCancelledServiceIsCapturedWithoutAnOriginArrivalTime() throws {
        let caughtAt = Date(timeIntervalSince1970: 2_000_000_000)
        let departures = [
            recentDeparture(id: "cancelled-1712", minutesBeforeCaught: 30, isCancelled: true, caughtAt: caughtAt),
            recentDeparture(id: "cancelled-1727", minutesBeforeCaught: 15, isCancelled: true, caughtAt: caughtAt)
        ]

        let cancellation = try #require(
            JourneyHistoryCancellationPolicy.immediatelyPrecedingCancellation(
                caughtServiceID: "caught-1742",
                caughtScheduledDepartureAt: caughtAt,
                departures: departures
            )
        )

        #expect(cancellation.serviceID == "cancelled-1727")
        #expect(cancellation.scheduledDepartureTime == "17:27")
        #expect(cancellation.minutesBeforeCaughtService == 15)
    }

    @Test func anOlderCancellationDoesNotApplyWhenTheImmediatelyPrecedingServiceRan() {
        let caughtAt = Date(timeIntervalSince1970: 2_000_000_000)
        let departures = [
            recentDeparture(id: "cancelled", minutesBeforeCaught: 30, isCancelled: true, caughtAt: caughtAt),
            recentDeparture(id: "ran", minutesBeforeCaught: 15, isCancelled: false, caughtAt: caughtAt)
        ]

        #expect(JourneyHistoryCancellationPolicy.immediatelyPrecedingCancellation(
            caughtServiceID: "caught",
            caughtScheduledDepartureAt: caughtAt,
            departures: departures
        ) == nil)
    }

    @Test func cancellationStillAppliesWhenTheInterveningServiceWasNotDueBeforeTheCaughtTrain() throws {
        let caughtAt = Date(timeIntervalSince1970: 2_000_000_000)
        let departures = [
            recentDeparture(id: "cancelled-1712", minutesBeforeCaught: 30, isCancelled: true, caughtAt: caughtAt),
            recentDeparture(
                id: "delayed-1727",
                minutesBeforeCaught: 15,
                isCancelled: false,
                caughtAt: caughtAt,
                effectiveMinutesBeforeCaught: 0
            )
        ]

        let cancellation = try #require(
            JourneyHistoryCancellationPolicy.immediatelyPrecedingCancellation(
                caughtServiceID: "caught-1742",
                caughtScheduledDepartureAt: caughtAt,
                departures: departures
            )
        )

        #expect(cancellation.serviceID == "cancelled-1712")
        #expect(cancellation.scheduledDepartureTime == "17:12")
        #expect(cancellation.minutesBeforeCaughtService == 30)
    }

    @Test func precedingCancellationContributesToDelayRepayEligibility() {
        let cancellation = JourneyHistoryPrecedingCancellation(
            serviceID: "cancelled",
            scheduledDepartureAt: Date(timeIntervalSince1970: 1_000),
            scheduledDepartureTime: "17:27",
            minutesBeforeCaughtService: 15
        )

        #expect(JourneyHistoryCancellationPolicy.eligibleDelayMinutes(
            arrivalDelayMinutes: 0,
            precedingCancellations: [cancellation]
        ) == 15)
        #expect(JourneyHistoryCancellationPolicy.eligibleDelayMinutes(
            arrivalDelayMinutes: nil,
            precedingCancellations: [cancellation]
        ) == 15)
        #expect(JourneyHistoryCancellationPolicy.eligibleDelayMinutes(
            arrivalDelayMinutes: 14,
            precedingCancellations: []
        ) == 14)
    }

    @Test func historyRecordEnablesDelayRepayForAnOnTimeCaughtServiceAfterACancellation() throws {
        let caughtAt = Date(timeIntervalSince1970: 2_000_000_000)
        let arrivalAt = caughtAt.addingTimeInterval(20 * 60)
        let victoria = station(crs: "VIC", name: "London Victoria")
        let kentHouse = station(crs: "KTH", name: "Kent House")
        let cancellation = JourneyHistoryPrecedingCancellation(
            serviceID: "cancelled-1727",
            scheduledDepartureAt: caughtAt.addingTimeInterval(-15 * 60),
            scheduledDepartureTime: "17:27",
            minutesBeforeCaughtService: 15
        )
        let leg = JourneyHistoryLeg(
            plannedLegIndex: 0,
            fromStation: victoria,
            toStation: kentHouse,
            serviceID: "caught-1742",
            operatorName: "Southeastern",
            operatorCode: "SE",
            detectedDepartureAt: caughtAt,
            scheduledDepartureAt: caughtAt,
            scheduledArrivalAt: arrivalAt,
            actualArrivalAt: arrivalAt,
            precedingCancellation: cancellation,
            outcome: .completed
        )
        let checkpoint = ActiveJourneyHistoryCheckpoint(
            id: UUID(),
            subscriptionId: "cancellation-delay-repay",
            source: .scheduled,
            plannedStations: [victoria, kentHouse],
            createdAt: caughtAt.addingTimeInterval(-60 * 60),
            phase: .arriving,
            plannedLegIndex: 0,
            originArrivedAt: nil,
            detectedDepartureAt: caughtAt,
            detectedArrivalAt: arrivalAt,
            deviceBasedArrivalAt: nil,
            lastConfirmedOnRouteStation: kentHouse,
            nextExpectedCallingPointIndex: 1,
            legs: [leg],
            stationEvents: [],
            approachNotificationSent: true,
            backendSessionID: nil,
            serviceMatchConfidence: 1,
            unexpectedStation: nil,
            unexpectedStationObservedAt: nil,
            serviceDepartedStationCRS: nil,
            serviceDepartedStationAt: nil,
            updatedAt: arrivalAt
        )
        let record = JourneyHistoryRecord(
            checkpoint: checkpoint,
            outcome: .completed,
            completedAt: arrivalAt
        )

        #expect(record.delayMinutes == 0)
        #expect(record.delayRepayEligibleDelayMinutes == 15)
        #expect(record.isDelayRepay15Plus)
        #expect(JourneyHistoryDelayPolicy.responsibleOperatorLeg(in: record)?.operatorCode == "SE")
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
        #expect(JourneyTrackingCoordinator.completedJourneyDisplayDuration == 60 * 60)
        #expect(
            JourneyTrackingCoordinator.destinationApproachRadiusMeters
                > JourneyTrackingCoordinator.destinationArrivalRadiusMeters
        )
    }

    @Test func finalArrivalCompensatesForAValidCoarseLocationFix() {
        let evaluation = JourneyArrivalLocationPolicy.evaluate(
            rawDistance: 210,
            horizontalAccuracy: 80,
            locationAge: 4,
            arrivalRadius: 150,
            maximumHorizontalAccuracy: 200,
            maximumLocationAge: 120
        )

        #expect(evaluation.rawDistance == 210)
        #expect(evaluation.compensatedDistance == 130)
        #expect(evaluation.isAccepted)
        #expect(evaluation.rejectionReason == nil)
    }

    @Test func finalArrivalRejectsStaleOrUnreliableLocations() {
        let poorAccuracy = JourneyArrivalLocationPolicy.evaluate(
            rawDistance: 100,
            horizontalAccuracy: 250,
            locationAge: 4,
            arrivalRadius: 150,
            maximumHorizontalAccuracy: 200,
            maximumLocationAge: 120
        )
        let stale = JourneyArrivalLocationPolicy.evaluate(
            rawDistance: 100,
            horizontalAccuracy: 20,
            locationAge: 121,
            arrivalRadius: 150,
            maximumHorizontalAccuracy: 200,
            maximumLocationAge: 120
        )

        #expect(!poorAccuracy.isAccepted)
        #expect(poorAccuracy.rejectionReason == "poor_accuracy")
        #expect(!stale.isAccepted)
        #expect(stale.rejectionReason == "stale_location")
    }

    @Test @MainActor func confirmedBackendCompletionEndsOnlyTheFinalMatchingLeg() {
        #expect(JourneyTrackingCoordinator.shouldCompleteJourneyFromRemoteUpdate(
            event: "service_completed",
            destinationMatches: true,
            isFinalLeg: true,
            hasConfirmedArrival: true
        ))
        #expect(!JourneyTrackingCoordinator.shouldCompleteJourneyFromRemoteUpdate(
            event: "station_departed",
            destinationMatches: true,
            isFinalLeg: true,
            hasConfirmedArrival: true
        ))
        #expect(!JourneyTrackingCoordinator.shouldCompleteJourneyFromRemoteUpdate(
            event: "service_completed",
            destinationMatches: false,
            isFinalLeg: true,
            hasConfirmedArrival: true
        ))
        #expect(!JourneyTrackingCoordinator.shouldCompleteJourneyFromRemoteUpdate(
            event: "service_completed",
            destinationMatches: true,
            isFinalLeg: false,
            hasConfirmedArrival: true
        ))
        #expect(!JourneyTrackingCoordinator.shouldCompleteJourneyFromRemoteUpdate(
            event: "service_completed",
            destinationMatches: true,
            isFinalLeg: true,
            hasConfirmedArrival: false
        ))
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
            deviceBasedArrivalAt: legs.last?.detectedArrivalAt,
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

        #expect(record.deviceBasedArrivalAt == checkpoint.deviceBasedArrivalAt)
        let responsibleLeg = try #require(JourneyHistoryDelayPolicy.responsibleOperatorLeg(in: record))
        #expect(responsibleLeg.operatorCode == "SE")
    }

    @Test func delayRepayOperatorChoicesAreDeduplicatedAndOrderedByFirstLeg() throws {
        let start = Date(timeIntervalSince1970: 2_100_000_000)
        let kentHouse = station(crs: "KTH", name: "Kent House")
        let herneHill = station(crs: "HNH", name: "Herne Hill")
        let farringdon = station(crs: "ZFD", name: "Farringdon")
        let stPancras = station(crs: "STP", name: "London St Pancras International")
        let legs = [
            JourneyHistoryLeg(
                plannedLegIndex: 0,
                fromStation: kentHouse,
                toStation: herneHill,
                operatorName: "Southeastern",
                operatorCode: "SE",
                detectedDepartureAt: start,
                scheduledDepartureAt: start,
                scheduledArrivalAt: start.addingTimeInterval(10 * 60),
                actualArrivalAt: start.addingTimeInterval(15 * 60),
                outcome: .completed
            ),
            JourneyHistoryLeg(
                plannedLegIndex: 1,
                fromStation: herneHill,
                toStation: farringdon,
                operatorName: "Thameslink",
                operatorCode: "TL",
                detectedDepartureAt: start.addingTimeInterval(40 * 60),
                scheduledDepartureAt: start.addingTimeInterval(20 * 60),
                scheduledArrivalAt: start.addingTimeInterval(40 * 60),
                actualArrivalAt: start.addingTimeInterval(65 * 60),
                outcome: .completed
            ),
            JourneyHistoryLeg(
                plannedLegIndex: 2,
                fromStation: farringdon,
                toStation: stPancras,
                operatorName: " southeastern ",
                operatorCode: "SE",
                detectedDepartureAt: start.addingTimeInterval(95 * 60),
                scheduledDepartureAt: start.addingTimeInterval(70 * 60),
                scheduledArrivalAt: start.addingTimeInterval(80 * 60),
                actualArrivalAt: start.addingTimeInterval(105 * 60),
                outcome: .completed
            )
        ]

        let options = JourneyHistoryDelayPolicy.operatorOptions(for: legs)

        #expect(options.map(\.operatorName) == ["Southeastern", "Thameslink"])
        #expect(options[0].legAssessments.map(\.legNumber) == [1, 3])
        #expect(options[1].legAssessments.map(\.arrivalDelayMinutes) == [25])
        #expect(options[1].isRecommended)
    }

    @Test func delayRepayRecommendationAttributesAClearlyMissedConnectionToThePreviousLeg() throws {
        let start = Date(timeIntervalSince1970: 2_200_000_000)
        let kentHouse = station(crs: "KTH", name: "Kent House")
        let herneHill = station(crs: "HNH", name: "Herne Hill")
        let farringdon = station(crs: "ZFD", name: "Farringdon")
        let legs = [
            JourneyHistoryLeg(
                plannedLegIndex: 0,
                fromStation: kentHouse,
                toStation: herneHill,
                operatorName: "Southeastern",
                operatorCode: "SE",
                detectedDepartureAt: start,
                scheduledDepartureAt: start,
                scheduledArrivalAt: start.addingTimeInterval(10 * 60),
                actualArrivalAt: start.addingTimeInterval(20 * 60),
                outcome: .completed
            ),
            JourneyHistoryLeg(
                plannedLegIndex: 1,
                fromStation: herneHill,
                toStation: farringdon,
                operatorName: "Thameslink",
                operatorCode: "TL",
                detectedDepartureAt: start.addingTimeInterval(40 * 60),
                scheduledDepartureAt: start.addingTimeInterval(15 * 60),
                scheduledArrivalAt: start.addingTimeInterval(35 * 60),
                actualArrivalAt: start.addingTimeInterval(60 * 60),
                outcome: .completed
            )
        ]

        let options = JourneyHistoryDelayPolicy.operatorOptions(for: legs)
        let recommendedOption = options.first(where: \.isRecommended)
        let recommended = try #require(recommendedOption)

        #expect(recommended.operatorName == "Southeastern")
        #expect(recommended.recommendationReason?.contains("after Leg 2") == true)
    }

    private func station(crs: String, name: String) -> Station {
        Station(crs: crs, name: name, longitude: "0", latitude: "0")
    }

    private func recentDeparture(
        id: String,
        minutesBeforeCaught: Int,
        isCancelled: Bool,
        caughtAt: Date,
        effectiveMinutesBeforeCaught: Int? = nil
    ) -> RecentDepartureV2 {
        let scheduledAt = caughtAt.addingTimeInterval(-Double(minutesBeforeCaught) * 60)
        let effectiveDepartureAt = effectiveMinutesBeforeCaught.map {
            caughtAt.addingTimeInterval(-Double($0) * 60)
        }
        let hour = 17
        let minute = 42 - minutesBeforeCaught
        return RecentDepartureV2(
            serviceID: id,
            serviceType: "train",
            fromCRS: "VIC",
            toCRS: "KTH",
            scheduledDeparture: String(format: "%02d:%02d", hour, minute),
            estimatedDeparture: isCancelled ? "Cancelled" : effectiveDepartureAt.map { _ in "17:42" },
            actualDeparture: nil,
            scheduledDepartureAt: scheduledAt,
            estimatedDepartureAt: effectiveDepartureAt,
            actualDepartureAt: nil,
            platform: "2",
            isCancelled: isCancelled,
            lastObservedAt: caughtAt
        )
    }
}
