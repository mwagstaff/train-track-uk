//
//  TrainTrack_UKTests.swift
//  TrainTrack UKTests
//
//  Created by Mike Wagstaff on 04/11/2025.
//

import Foundation
import Testing
import JourneyActivityShared
@testable import TrainTrack_UK

struct TrainTrack_UKTests {

    @Test func journeyStatusMessagesCoverEachTrackingPhase() {
        let phases = JourneyActivityAttributes.JourneyPhase.self

        #expect(phases.pendingStart.statusMessage(
            startStation: "Kent House",
            destinationStation: "London Victoria"
        ) == "Watching for arrival at Kent House")
        #expect(phases.atStart.statusMessage(
            startStation: "Kent House",
            destinationStation: "London Victoria"
        ) == "At Kent House")
        #expect(phases.enRoute.statusMessage(
            startStation: "Kent House",
            destinationStation: "London Victoria"
        ) == "Tracking train journey")
        #expect(phases.arrived.statusMessage(
            startStation: "Kent House",
            destinationStation: "London Victoria"
        ) == "Arrived at London Victoria")
    }

    @Test func arrivedJourneyOnlyOffersDelayRepayAtTheFifteenMinuteThreshold() {
        let baseState = JourneyActivityAttributes.ContentState(
            fromCRS: "BTN",
            toCRS: "ECR",
            destinationTitle: "East Croydon",
            arrivalLabel: "Departed 10:59",
            length: 12,
            platform: "5",
            estimated: "11:51",
            statusText: nil,
            delayMinutes: 0,
            journeyPhase: .arrived
        )
        var fourteenMinutesLate = baseState
        fourteenMinutesLate.arrivalDelayMinutes = 14
        var fifteenMinutesLate = baseState
        fifteenMinutesLate.arrivalDelayMinutes = 15

        #expect(fourteenMinutesLate.delayRepayMessage == nil)
        #expect(fifteenMinutesLate.delayRepayMessage == "Eligible for a Delay Repay claim — 15 min late")
    }

    @Test @MainActor func scheduledLiveSessionsAreNotShownAsAdHocJourneyUpdates() throws {
        let scheduled = try notificationSubscription(id: "schedule", origin: nil, source: "scheduled")
        let scheduledLiveSession = try notificationSubscription(id: "scheduled-live", origin: "scheduled")
        let manualLiveSession = try notificationSubscription(id: "manual-live", origin: "manual")

        let visible = NotificationSubscriptionStore.subscriptionsForJourneyUpdates(
            scheduled: [scheduled],
            liveSessions: [scheduledLiveSession, manualLiveSession]
        )

        #expect(visible.map(\.id) == ["schedule", "manual-live"])
    }

    @Test func legacyLiveSessionsStillDecodeAsVisibleManualSessions() throws {
        let legacyLiveSession = try notificationSubscription(id: "legacy-live", origin: nil)

        #expect(legacyLiveSession.liveSessionOrigin == nil)
    }

    @Test @MainActor func journeyDepartureSnapshotDecodesFreshnessMetadata() throws {
        let data = Data("""
        {
          "departures": [],
          "data_status": "stale",
          "last_successful_update": "2026-08-16T15:53:37.123Z"
        }
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(JourneyDeparturesSnapshot.self, from: data)

        #expect(snapshot.departures.isEmpty)
        #expect(snapshot.dataStatus == .stale)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        #expect(snapshot.lastSuccessfulUpdate == formatter.date(from: "2026-08-16T15:53:37.123Z"))
    }

    @Test @MainActor func journeyDepartureSnapshotStillDecodesTheLegacyArray() throws {
        let snapshot = try JSONDecoder().decode(
            JourneyDeparturesSnapshot.self,
            from: Data("[]".utf8)
        )

        #expect(snapshot.departures.isEmpty)
        #expect(snapshot.dataStatus == .live)
        #expect(snapshot.lastSuccessfulUpdate == nil)
    }

    @Test func tabsHaveAStablePagingOrderAndPresentation() {
        #expect(Tab.allCases == [.favourites, .myJourneys, .addJourney, .history, .profile])
        #expect(Tab.allCases.map(\.title) == ["Favourites", "My Journeys", "Add Journey", "History", "Profile"])
        #expect(Tab.allCases.map(\.systemImage) == ["heart.fill", "list.bullet", "plus.circle", "clock.arrow.circlepath", "person.circle"])
    }

    @Test @MainActor func historyDeepLinkSelectsTheHistoryRoot() throws {
        let tabRouter = TabRouter.shared
        let deepLinkRouter = DeepLinkRouter.shared
        let previousTab = tabRouter.selected
        let previousResetTrigger = tabRouter.navigationResetTrigger
        let previousRouteMapDestination = deepLinkRouter.routeMapDestination
        defer {
            tabRouter.selected = previousTab
            tabRouter.navigationResetTrigger = previousResetTrigger
            deepLinkRouter.routeMapDestination = previousRouteMapDestination
        }

        tabRouter.selected = .myJourneys
        let resetTrigger = tabRouter.navigationResetTrigger
        let url = try #require(URL(string: "traintrack://history"))

        deepLinkRouter.handle(url: url)

        #expect(tabRouter.selected == .history)
        #expect(tabRouter.navigationResetTrigger == resetTrigger + 1)
        #expect(deepLinkRouter.routeMapDestination == nil)
    }

    @Test func journeyStopPlacementPreservesTheCurrentDestination() {
        #expect(JourneyStopPlacement.intermediate.insertionIndex(existingStopCount: 1) == 0)
        #expect(JourneyStopPlacement.intermediate.insertionIndex(existingStopCount: 3) == 2)
    }

    @Test func journeyStopPlacementCanExtendBeyondTheCurrentDestination() {
        #expect(JourneyStopPlacement.destination.insertionIndex(existingStopCount: 1) == 1)
        #expect(JourneyStopPlacement.destination.insertionIndex(existingStopCount: 3) == 3)
    }

    @Test func stationCatalogueIncludesCambridgeSouthUntilTheAPIIsUpdated() throws {
        let stations = StationsService.includingSupplementalStations(in: [
            station(crs: "CBG", name: "Cambridge")
        ])
        let cambridgeSouth = try #require(stations.first { $0.crs == "CMS" })

        #expect(cambridgeSouth.name == "Cambridge South")
        #expect(cambridgeSouth.latitude == "52.1740325")
        #expect(cambridgeSouth.longitude == "0.1312738")
    }

    @Test func stationCatalogueDoesNotDuplicateCambridgeSouthFromTheAPI() {
        let apiStation = station(crs: "CMS", name: "Cambridge South")
        let stations = StationsService.includingSupplementalStations(in: [apiStation])

        #expect(stations == [apiStation])
    }

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

    @Test func journeyCardShowsCancellationReasonWhenAvailable() {
        #expect(JourneyCardPresentation.cancellationStatusText(
            "This service has been cancelled because of damage to the overhead electric wires"
        ) == "This service has been cancelled because of damage to the overhead electric wires")
    }

    @Test func journeyCardFallsBackToCancelledWhenCancellationReasonIsMissing() {
        #expect(JourneyCardPresentation.cancellationStatusText(nil) == "Cancelled")
        #expect(JourneyCardPresentation.cancellationStatusText("  \n") == "Cancelled")
    }

    @Test func journeyCardTreatsACancelledDestinationAsAPartialCancellation() throws {
        let serviceID = "cambridge-east-croydon"
        let runningDeparture = departure(
            at: "19:23",
            serviceID: serviceID,
            isCancelled: true,
            cancelReason: "This service has been cancelled because of damage to the overhead electric wires"
        )
        let details = serviceDetails(
            callingPoints: [
                callingPoint(name: "Finsbury Park", crs: "FPK", time: "20:23"),
                callingPoint(
                    name: "London St Pancras International",
                    crs: "STP",
                    time: "20:31",
                    isCancelled: true
                ),
                callingPoint(name: "Farringdon", crs: "ZFD", time: "20:36", isCancelled: true),
                callingPoint(name: "London Blackfriars", crs: "BFR", time: "20:41", isCancelled: true),
                callingPoint(name: "East Croydon", crs: "ECR", time: "21:10", isCancelled: true)
            ]
        )

        let cancellation = try #require(JourneyItineraryBuilder.cancellation(
            for: runningDeparture,
            at: "ECR",
            serviceDetailsByID: [serviceID: details]
        ))

        #expect(JourneyCardPresentation.cancellationStatusText(cancellation) ==
            "Partial cancellation · Not running from London St Pancras International to East Croydon")

        let groupID = UUID()
        let directJourney = journey(
            groupID: groupID,
            index: 0,
            from: station(crs: "CBG", name: "Cambridge"),
            to: station(crs: "ECR", name: "East Croydon")
        )
        let itinerary = JourneyItineraryBuilder.build(
            group: JourneyGroup(id: groupID, legs: [directJourney]),
            firstDeparture: runningDeparture,
            departuresForJourney: { _ in [runningDeparture] },
            serviceDetailsByID: [serviceID: details]
        )

        #expect(itinerary.finalArrivalTime == nil)
    }

    @Test func journeyCardDoesNotCancelTheStillRunningPartOfAPartiallyCancelledService() {
        let serviceID = "cambridge-east-croydon"
        let runningDeparture = departure(at: "19:23", serviceID: serviceID)
        let details = serviceDetails(
            callingPoints: [
                callingPoint(name: "Finsbury Park", crs: "FPK", time: "20:23"),
                callingPoint(name: "East Croydon", crs: "ECR", time: "21:10", isCancelled: true)
            ]
        )

        #expect(JourneyItineraryBuilder.cancellation(
            for: runningDeparture,
            at: "FPK",
            serviceDetailsByID: [serviceID: details]
        ) == nil)
    }

    @Test func journeyCardKeepsTheDefaultReasonWhenEveryStopIsCancelled() throws {
        let serviceID = "fully-cancelled-service"
        let reason = "This service has been cancelled because of damage to the overhead electric wires"
        let cancelledDeparture = departure(
            at: "19:23",
            serviceID: serviceID,
            isCancelled: true,
            cancelReason: reason
        )
        let details = serviceDetails(
            currentIsCancelled: true,
            callingPoints: [
                callingPoint(name: "Finsbury Park", crs: "FPK", time: "20:23", isCancelled: true),
                callingPoint(name: "East Croydon", crs: "ECR", time: "21:10", isCancelled: true)
            ]
        )

        let cancellation = try #require(JourneyItineraryBuilder.cancellation(
            for: cancelledDeparture,
            at: "ECR",
            serviceDetailsByID: [serviceID: details]
        ))

        #expect(!cancellation.isPartial)
        #expect(JourneyCardPresentation.cancellationStatusText(cancellation) == reason)
    }

    @Test func journeyCardExplainsWhenAnIntermediateDestinationStopIsCancelled() throws {
        let serviceID = "cambridge-brighton-skipping-east-croydon"
        let runningDeparture = departure(
            at: "19:23",
            serviceID: serviceID,
            isCancelled: true,
            cancelReason: "This service has been cancelled because of congestion"
        )
        let details = serviceDetails(
            callingPoints: [
                callingPoint(name: "Finsbury Park", crs: "FPK", time: "20:23"),
                callingPoint(name: "East Croydon", crs: "ECR", time: "21:10", isCancelled: true),
                callingPoint(name: "Gatwick Airport", crs: "GTW", time: "21:25"),
                callingPoint(name: "Brighton", crs: "BTN", time: "22:02")
            ]
        )

        let cancellation = try #require(JourneyItineraryBuilder.cancellation(
            for: runningDeparture,
            at: "ECR",
            serviceDetailsByID: [serviceID: details]
        ))

        #expect(JourneyCardPresentation.cancellationStatusText(cancellation) ==
            "Service no longer stopping at East Croydon")
        #expect(cancellation.serviceContinuesBeyondDestination)
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
        isCancelled: Bool = false,
        cancelReason: String? = nil
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
            cancelReason: cancelReason,
            timestamp: nil
        )
    }

    private func station(crs: String, name: String) -> Station {
        Station(crs: crs, name: name, longitude: "0", latitude: "0")
    }

    private func serviceDetails(
        currentIsCancelled: Bool = false,
        callingPoints: [CallingPoint]
    ) -> ServiceDetails {
        ServiceDetails(
            previousCallingPoints: nil,
            subsequentCallingPoints: [CallingPointList(
                callingPoint: callingPoints,
                serviceType: "train",
                serviceChangeRequired: false,
                assocIsCancelled: false
            )],
            generatedAt: "2026-08-16T18:34:00Z",
            serviceType: "train",
            locationName: "Cambridge",
            crs: "CBG",
            operator: "Thameslink",
            operatorCode: "TL",
            isCancelled: currentIsCancelled,
            length: 8,
            detachFront: false,
            isReverseFormation: false,
            platform: "7",
            sta: nil,
            eta: nil,
            ata: nil,
            std: "19:23",
            etd: "On time",
            atd: nil,
            delayReason: nil,
            cancelReason: nil
        )
    }

    private func callingPoint(
        name: String,
        crs: String,
        time: String,
        isCancelled: Bool = false
    ) -> CallingPoint {
        CallingPoint(
            locationName: name,
            crs: crs,
            st: time,
            et: isCancelled ? "Cancelled" : "On time",
            at: nil,
            isCancelled: isCancelled,
            cancelReason: nil,
            platform: nil,
            length: 8,
            detachFront: false,
            affectedByDiversion: false,
            rerouteDelay: 0
        )
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

private func notificationSubscription(
    id: String,
    origin: String?,
    source: String = "live_session"
) throws -> NotificationSubscription {
    let originProperty = origin.map { ", \"live_session_origin\": \"\($0)\"" } ?? ""
    let data = Data("""
    {
      "id": "\(id)",
      "device_id": "device-1",
      "route_key": "KTH-VIC",
      "days_of_week": ["mon"],
      "notification_types": ["delays", "platform"],
      "source": "\(source)"\(originProperty),
      "legs": [{
        "from": "KTH",
        "to": "VIC",
        "from_name": "Kent House",
        "to_name": "London Victoria",
        "enabled": true,
        "window_start": "00:00",
        "window_end": "23:59"
      }]
    }
    """.utf8)
    return try JSONDecoder().decode(NotificationSubscription.self, from: data)
}
