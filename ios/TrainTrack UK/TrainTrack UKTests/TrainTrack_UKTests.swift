//
//  TrainTrack_UKTests.swift
//  TrainTrack UKTests
//
//  Created by Mike Wagstaff on 04/11/2025.
//

import Foundation
import Testing
@testable import TrainTrack_UK

struct TrainTrack_UKTests {

    @Test func departureRequiresAccuracyEnvelopeBeyondHysteresis() {
        #expect(!StationDetectionPolicy.isDefinitelyOutsideStation(
            rawDistance: 340,
            horizontalAccuracy: 45,
            radius: 250
        ))
        #expect(StationDetectionPolicy.isDefinitelyOutsideStation(
            rawDistance: 351,
            horizontalAccuracy: 50,
            radius: 250
        ))
    }

    @Test func invalidAccuracyCannotConfirmDeparture() {
        #expect(!StationDetectionPolicy.isDefinitelyOutsideStation(
            rawDistance: 1_000,
            horizontalAccuracy: -1,
            radius: 250
        ))
    }

    @Test func persistedDetectionStateSpansMidnightWithinLifetime() {
        let recordedAt = Date(timeIntervalSince1970: 86_390)
        let afterMidnight = Date(timeIntervalSince1970: 86_410)

        #expect(StationDetectionPolicy.isPersistedStateCurrent(
            recordedAt: recordedAt,
            now: afterMidnight
        ))
    }

    @Test func staleAndFutureDetectionStateAreRejected() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(!StationDetectionPolicy.isPersistedStateCurrent(
            recordedAt: now.addingTimeInterval(-(StationDetectionPolicy.persistedStateLifetime + 1)),
            now: now
        ))
        #expect(!StationDetectionPolicy.isPersistedStateCurrent(
            recordedAt: now.addingTimeInterval(1),
            now: now
        ))
    }

    @Test func conditionBudgetMatchesCoreLocationLimit() {
        #expect(StationDetectionPolicy.maximumMonitoredConditions == 20)
        #expect(StationDetectionPolicy.canAllocateStationCoordinate(currentConditionCount: 18))
        #expect(!StationDetectionPolicy.canAllocateStationCoordinate(currentConditionCount: 19))
        #expect(!StationDetectionPolicy.canAllocateStationCoordinate(currentConditionCount: 20))
    }

    @Test func journeyCardsShowFiveDeparturesOnlyForSingleJourneyScreens() {
        #expect(JourneyCardPresentation.defaultDepartureCount(journeyCount: 1) == 5)
        #expect(JourneyCardPresentation.defaultDepartureCount(journeyCount: 2) == 3)
        #expect(JourneyCardPresentation.defaultDepartureCount(journeyCount: 6) == 3)
    }

    @Test func journeyCardRelativeDepartureLabelsRoundUpToTheNextMinute() {
        let now = Date(timeIntervalSince1970: 1_000)

        #expect(JourneyCardPresentation.relativeDepartureLabel(departure: now, now: now) == "Due")
        #expect(JourneyCardPresentation.relativeDepartureLabel(
            departure: now.addingTimeInterval(1),
            now: now
        ) == "in 1 min")
        #expect(JourneyCardPresentation.relativeDepartureLabel(
            departure: now.addingTimeInterval(60 * 61),
            now: now
        ) == "in 1h 01m")
    }

    @Test func journeyCardArrivalLabelNamesTheDestination() {
        #expect(JourneyCardPresentation.arrivalLabel(
            time: "20:33",
            destinationName: "London Victoria"
        ) == "Arr 20:33 at London Victoria")
    }

    @Test func journeyCardArrivalLabelsHandleLateAndUnknownTimes() {
        #expect(JourneyCardPresentation.arrivalLabel(
            time: "20:49",
            destinationName: "Three Bridges",
            scheduledDeparture: "20:27"
        ) == "20:27 • Arr 20:49 at Three Bridges")
        #expect(JourneyCardPresentation.arrivalLabel(
            time: "Delayed",
            destinationName: "Three Bridges"
        ) == "Arr TBC (delayed) at Three Bridges")
    }

}
