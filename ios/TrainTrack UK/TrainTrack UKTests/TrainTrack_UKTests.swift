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

    @Test func singleLegJourneyCardsKeepCancelledDeparturesVisible() {
        let groupID = UUID()
        let directJourney = journey(
            groupID: groupID,
            index: 0,
            from: station(crs: "KTH", name: "Kent House"),
            to: station(crs: "VIC", name: "London Victoria")
        )
        let cancelledDeparture = departure(
            at: "20:42",
            serviceID: "cancelled-direct-service",
            isCancelled: true
        )
        let itinerary = JourneyItineraryBuilder.build(
            group: JourneyGroup(id: groupID, legs: [directJourney]),
            firstDeparture: cancelledDeparture,
            departuresForJourney: { _ in [cancelledDeparture] },
            serviceDetailsByID: [:]
        )

        #expect(!itinerary.hasServicesForAllLegs)
        #expect(JourneyCardPresentation.shouldDisplaySummary(
            legCount: 1,
            hasServicesForAllLegs: itinerary.hasServicesForAllLegs
        ))
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

    @Test func multiLegItinerarySelectsTheFirstServiceAfterArrival() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 10
        ))!
        let arrival = JourneyItineraryBuilder.date(for: "10:15", now: now)!
        let missedConnection = departure(at: "10:12", serviceID: "missed")
        let validConnection = departure(at: "10:20", serviceID: "valid")

        let selected = JourneyItineraryBuilder.selectDeparture(
            from: [missedConnection, validConnection],
            noEarlierThan: arrival,
            now: now
        )

        #expect(selected?.serviceID == "valid")
        #expect(JourneyItineraryBuilder.selectDeparture(
            from: [missedConnection],
            noEarlierThan: arrival,
            now: now
        ) == nil)
    }

    @Test func multiLegItinerarySkipsCancelledConnectionAndExplainsWhy() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 10
        ))!
        let arrival = JourneyItineraryBuilder.date(for: "10:15", now: now)!
        let cancelledConnection = departure(
            at: "10:18",
            serviceID: "cancelled",
            isCancelled: true
        )
        let laterConnection = departure(at: "10:25", serviceID: "later")

        let selected = JourneyItineraryBuilder.selectConnection(
            from: [cancelledConnection, laterConnection],
            noEarlierThan: arrival,
            destinationName: "London Blackfriars",
            now: now
        )

        #expect(selected.departure?.serviceID == "later")
        #expect(selected.disruptionNotes == [
            "10:18 to London Blackfriars would have been faster, but was cancelled"
        ])
    }

    @Test func multiLegItinerarySkipsDelayedConnectionWhenLaterTrainDepartsFirst() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 10
        ))!
        let arrival = JourneyItineraryBuilder.date(for: "10:15", now: now)!
        let delayedConnection = departure(
            at: "10:18",
            estimated: "10:30",
            serviceID: "delayed"
        )
        let laterConnection = departure(at: "10:25", serviceID: "later")

        let selected = JourneyItineraryBuilder.selectConnection(
            from: [delayedConnection, laterConnection],
            noEarlierThan: arrival,
            destinationName: "London Blackfriars",
            now: now
        )

        #expect(selected.departure?.serviceID == "later")
        #expect(selected.disruptionNotes == [
            "10:18 to London Blackfriars would have been faster, but is now delayed until 10:30"
        ])
    }

    @Test func multiLegItineraryExplainsConnectionMissedByDelayedArrival() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 10
        ))!
        let scheduledArrival = JourneyItineraryBuilder.date(for: "10:15", now: now)!
        let delayedArrival = JourneyItineraryBuilder.date(for: "10:20", now: now)!
        let missedConnection = departure(at: "10:18", serviceID: "missed")
        let usableConnection = departure(at: "10:25", serviceID: "usable")

        let selected = JourneyItineraryBuilder.selectConnection(
            from: [missedConnection, usableConnection],
            noEarlierThan: delayedArrival,
            scheduledNoEarlierThan: scheduledArrival,
            destinationName: "London Blackfriars",
            changeStationName: "Herne Hill",
            now: now
        )

        #expect(selected.departure?.serviceID == "usable")
        #expect(selected.disruptionNotes == [
            "10:18 to London Blackfriars would have been faster, but the delayed arrival at Herne Hill means this connection will be missed"
        ])
    }

    @Test func multiLegItineraryRequiresAServiceForEveryLeg() {
        let groupID = UUID()
        let kentHouse = station(crs: "KTH", name: "Kent House")
        let herneHill = station(crs: "HNH", name: "Herne Hill")
        let blackfriars = station(crs: "BFR", name: "London Blackfriars")
        let firstLeg = journey(
            groupID: groupID,
            index: 0,
            from: kentHouse,
            to: herneHill
        )
        let secondLeg = journey(
            groupID: groupID,
            index: 1,
            from: herneHill,
            to: blackfriars
        )
        let group = JourneyGroup(id: groupID, legs: [firstLeg, secondLeg])
        let firstService = departure(at: "04:57", serviceID: "first")

        let incomplete = JourneyItinerary(group: group, legs: [
            JourneyItineraryLeg(
                journey: firstLeg,
                departure: firstService,
                departureDate: nil,
                arrivalTime: "05:07",
                arrivalDate: nil,
                disruptionNotes: []
            ),
            JourneyItineraryLeg(
                journey: secondLeg,
                departure: nil,
                departureDate: nil,
                arrivalTime: nil,
                arrivalDate: nil,
                disruptionNotes: []
            )
        ])

        #expect(!incomplete.hasServicesForAllLegs)

        let completeWithCancelledConnection = JourneyItinerary(group: group, legs: [
            incomplete.legs[0],
            JourneyItineraryLeg(
                journey: secondLeg,
                departure: departure(
                    at: "05:12",
                    serviceID: "cancelled-connection",
                    isCancelled: true
                ),
                departureDate: nil,
                arrivalTime: nil,
                arrivalDate: nil,
                disruptionNotes: []
            )
        ])

        #expect(!completeWithCancelledConnection.hasServicesForAllLegs)
    }

    @Test func multiLegItineraryCalculatesConnectionTimeAcrossMidnight() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 14,
            hour: 23,
            minute: 30
        ))!
        let arrival = JourneyItineraryBuilder.date(for: "23:58", now: now)
        let departure = JourneyItineraryBuilder.date(for: "00:06", now: now)

        #expect(JourneyItineraryBuilder.connectionMinutes(
            arrivingAt: arrival,
            departingAt: departure
        ) == 8)
    }

    private func departure(
        at time: String,
        estimated: String = "On time",
        serviceID: String,
        isCancelled: Bool = false
    ) -> DepartureV2 {
        DepartureV2(
            departureTime: DepartureTimeV2(scheduled: time, estimated: estimated),
            serviceType: "train",
            platform: "1",
            isCancelled: isCancelled,
            length: nil,
            destination: [],
            origin: nil,
            serviceID: serviceID,
            delayReason: nil,
            cancelReason: nil,
            timestamp: nil
        )
    }

    private func station(crs: String, name: String) -> Station {
        Station(crs: crs, name: name, longitude: "0", latitude: "0")
    }

    private func journey(
        groupID: UUID,
        index: Int,
        from: Station,
        to: Station
    ) -> Journey {
        Journey(
            id: UUID(),
            groupId: groupID,
            legIndex: index,
            fromStation: from,
            toStation: to,
            createdAt: Date(timeIntervalSince1970: 0),
            favorite: false
        )
    }

}
