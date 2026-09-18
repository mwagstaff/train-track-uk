//
//  TrainTrack_UKTests.swift
//  TrainTrack UKTests
//
//  Created by Mike Wagstaff on 04/11/2025.
//

import Foundation
import CoreLocation
import Testing
import JourneyActivityShared
@testable import TrainTrack_UK

struct TrainTrack_UKTests {

    @Test func journeyCompletionCanReplaceAPendingBoardingMuteRequest() {
        let subscriptionID = "test-\(UUID().uuidString)"
        let dateKey = NotificationMuteStorage.currentDateKey()
        NotificationMuteStorage.upsertPendingMuteRequest(
            subscriptionId: subscriptionID,
            from: "KTH",
            to: "VIC",
            dateKey: dateKey,
            delayMinutes: 0,
            reason: "station_exit"
        )

        NotificationMuteStorage.removePendingMuteRequests(
            subscriptionId: subscriptionID,
            from: "KTH",
            to: "VIC",
            dateKey: dateKey
        )

        #expect(NotificationMuteStorage.pendingMuteRequests().contains {
            $0.subscriptionId == subscriptionID
        } == false)
    }

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

    @Test func journeyUpdatesPresentationDistinguishesLoadingStaleAndEmptyStates() {
        #expect(ProfileJourneyUpdatesState.resolve(
            isLoading: false,
            hasLoadedOnce: false,
            hasError: false,
            hasContent: false
        ) == .initialLoading)
        #expect(ProfileJourneyUpdatesState.resolve(
            isLoading: true,
            hasLoadedOnce: true,
            hasError: false,
            hasContent: true
        ) == .refreshing)
        #expect(ProfileJourneyUpdatesState.resolve(
            isLoading: false,
            hasLoadedOnce: true,
            hasError: false,
            hasContent: true
        ) == .loaded)
        #expect(ProfileJourneyUpdatesState.resolve(
            isLoading: false,
            hasLoadedOnce: true,
            hasError: true,
            hasContent: true
        ) == .stale)
        #expect(ProfileJourneyUpdatesState.resolve(
            isLoading: false,
            hasLoadedOnce: true,
            hasError: true,
            hasContent: false
        ) == .unavailable)
        #expect(ProfileJourneyUpdatesState.resolve(
            isLoading: false,
            hasLoadedOnce: true,
            hasError: false,
            hasContent: false
        ) == .empty)
    }

    @Test func journeyUpdatesRetryBackoffIsBounded() {
        let second: UInt64 = 1_000_000_000

        #expect(ProfileJourneyUpdatesRetryPolicy.delayNanoseconds(afterFailedAttempt: 0) == 2 * second)
        #expect(ProfileJourneyUpdatesRetryPolicy.delayNanoseconds(afterFailedAttempt: 1) == 4 * second)
        #expect(ProfileJourneyUpdatesRetryPolicy.delayNanoseconds(afterFailedAttempt: 2) == 8 * second)
        #expect(ProfileJourneyUpdatesRetryPolicy.delayNanoseconds(afterFailedAttempt: 3) == 15 * second)
        #expect(ProfileJourneyUpdatesRetryPolicy.delayNanoseconds(afterFailedAttempt: 20) == 30 * second)
    }

    @Test func oneOffScheduleDecodesTravelDates() throws {
        let data = Data("""
        {
          "id": "one-off",
          "device_id": "device-1",
          "route_key": "KTH-VIC",
          "schedule_type": "one_off",
          "days_of_week": [],
          "notification_types": ["delays"],
          "legs": [{
            "from": "KTH",
            "to": "VIC",
            "enabled": true,
            "window_start": "07:00",
            "window_end": "09:00",
            "travel_date": "2026-08-21"
          }]
        }
        """.utf8)

        let subscription = try JSONDecoder().decode(NotificationSubscription.self, from: data)

        #expect(subscription.scheduleKind == .oneOff)
        #expect(subscription.daysOfWeek.isEmpty)
        #expect(subscription.legs.first?.travelDate == "2026-08-21")
    }

    @Test func journeyUpdatesSortByTheirNextTravelWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = ISO8601DateFormatter().date(from: "2026-08-21T18:40:00Z")!
        let morning = scheduledJourneyUpdate(
            id: "morning",
            days: [.fri],
            windows: [("07:00", "09:00"), ("16:00", "18:00")]
        )
        let alreadyPassed = scheduledJourneyUpdate(
            id: "already-passed",
            days: [.fri],
            windows: [("18:50", "18:52"), ("18:55", "19:00")]
        )
        let next = scheduledJourneyUpdate(
            id: "next",
            days: [.fri],
            windows: [("19:41", "19:43"), ("19:45", "19:47")]
        )
        let oneOffTomorrow = scheduledJourneyUpdate(
            id: "one-off-tomorrow",
            days: [],
            windows: [("06:00", "06:30"), ("17:00", "17:30")],
            scheduleKind: .oneOff,
            travelDates: ["2026-08-22", "2026-08-22"]
        )

        let sorted = JourneyUpdateOrdering.sorted(
            [morning, alreadyPassed, next, oneOffTomorrow],
            scheduledIDs: [morning.id, alreadyPassed.id, next.id, oneOffTomorrow.id],
            now: now,
            calendar: calendar
        )

        #expect(sorted.map(\.id) == ["next", "one-off-tomorrow", "morning", "already-passed"])
        #expect(sorted.first?.legs.map(\.windowStart) == ["19:41", "19:45"])
    }

    @Test func datedJourneyUpdatesSortBeforeTheNextWeekdaySchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = ISO8601DateFormatter().date(from: "2026-08-21T19:02:00Z")!
        let weekdays = scheduledJourneyUpdate(
            id: "weekdays",
            days: [.mon, .tue, .wed, .thu, .fri],
            windows: [("07:00", "09:00"), ("16:00", "18:00")]
        )
        let tomorrow = scheduledJourneyUpdate(
            id: "tomorrow",
            days: [],
            windows: [("08:45", "10:45"), ("18:00", "20:00")],
            scheduleKind: nil,
            travelDates: ["2026-08-22", "2026-08-22"]
        )

        let sorted = JourneyUpdateOrdering.sorted(
            [weekdays, tomorrow],
            scheduledIDs: [weekdays.id, tomorrow.id],
            now: now,
            calendar: calendar
        )

        #expect(sorted.map(\.id) == ["tomorrow", "weekdays"])
    }

    @Test func journeyUpdateScheduleDetailsUseHumanFriendlyDaysAndDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let now = ISO8601DateFormatter().date(from: "2026-08-21T19:02:00Z")!
        let weekdays = scheduledJourneyUpdate(
            id: "weekdays",
            days: [.mon, .tue, .wed, .thu, .fri],
            windows: [("07:00", "09:00")]
        )
        let tomorrow = scheduledJourneyUpdate(
            id: "tomorrow",
            days: [],
            windows: [("08:45", "10:45")],
            scheduleKind: .oneOff,
            travelDates: ["2026-08-22"]
        )

        #expect(JourneyUpdateSchedulePresentation.detail(
            for: weekdays.legs[0],
            subscription: weekdays,
            scheduled: true,
            now: now,
            calendar: calendar
        ) == "• 07:00 - 09:00 weekdays")
        #expect(JourneyUpdateSchedulePresentation.detail(
            for: tomorrow.legs[0],
            subscription: tomorrow,
            scheduled: true,
            now: now,
            calendar: calendar
        ) == "• 08:45 - 10:45 tomorrow")
    }

    @Test func oneOffScheduleExpiresAfterItsFinalReturnWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        let schedule = scheduledJourneyUpdate(
            id: "one-off",
            days: [],
            windows: [("19:41", "19:43"), ("19:45", "19:47")],
            scheduleKind: .oneOff,
            travelDates: ["2026-08-21", "2026-08-21"]
        )
        let finalWindowEnd = ISO8601DateFormatter().date(from: "2026-08-21T18:47:00Z")!
        let minuteAfter = ISO8601DateFormatter().date(from: "2026-08-21T18:48:00Z")!

        #expect(!NotificationScheduleExpiry.isExpired(schedule, now: finalWindowEnd, calendar: calendar))
        #expect(NotificationScheduleExpiry.isExpired(schedule, now: minuteAfter, calendar: calendar))
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

    @Test @MainActor func recentDepartureDecodesAbsoluteServerTimes() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let departure = try decoder.decode(RecentDepartureV2.self, from: Data(#"""
        {
          "serviceID":"service-1",
          "serviceType":"train",
          "fromCRS":"KTH",
          "toCRS":"VIC",
          "scheduledDeparture":"10:42",
          "estimatedDeparture":"10:44",
          "actualDeparture":"10:45",
          "scheduledDepartureAt":"2026-08-23T09:42:00.000Z",
          "estimatedDepartureAt":"2026-08-23T09:44:00.000Z",
          "actualDepartureAt":"2026-08-23T09:45:00.000Z",
          "platform":"2",
          "isCancelled":false,
          "lastObservedAt":"2026-08-23T09:45:30.000Z"
        }
        """#.utf8))

        #expect(departure.actualDeparture == "10:45")
        #expect(departure.platform == "2")
        let actualDeparture = try #require(departure.actualDepartureAt)
        #expect(departure.serviceDetailsMayBeAvailable(
            at: actualDeparture.addingTimeInterval(119)
        ))
        #expect(!departure.serviceDetailsMayBeAvailable(
            at: actualDeparture.addingTimeInterval(121)
        ))
    }

    @Test @MainActor func serviceDetailsPolicyKeepsUnknownAndFutureDeparturesEligible() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(ServiceDetailsRequestPolicy.mayRequest(departureAt: nil, at: now))
        #expect(ServiceDetailsRequestPolicy.mayRequest(
            departureAt: now.addingTimeInterval(60),
            at: now
        ))

        let delayedDeparture = RecentDepartureV2(
            serviceID: "delayed-service",
            serviceType: "train",
            fromCRS: "SLO",
            toCRS: "PAD",
            scheduledDeparture: "10:00",
            estimatedDeparture: "Delayed",
            actualDeparture: nil,
            scheduledDepartureAt: now.addingTimeInterval(-600),
            estimatedDepartureAt: nil,
            actualDepartureAt: nil,
            platform: nil,
            isCancelled: false,
            lastObservedAt: now
        )
        #expect(delayedDeparture.serviceDetailsMayBeAvailable(at: now))
    }

    @Test @MainActor func tabsHaveAStablePagingOrderAndPresentation() {
        #expect(Tab.allCases == [.favourites, .myJourneys, .inProgress, .addJourney, .history, .profile])
        #expect(Tab.allCases.map(\.title) == ["Favourites", "My Journeys", "In Progress", "Add Journey", "History", "Profile"])
        #expect(Tab.allCases.map(\.systemImage) == ["heart.fill", "list.bullet", "location.fill", "plus.circle", "clock.arrow.circlepath", "person.circle"])
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

    @Test @MainActor func inProgressDeepLinkSelectsTheInProgressRoot() throws {
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
        let url = try #require(URL(string: "traintrack://in-progress"))

        deepLinkRouter.handle(url: url)

        #expect(tabRouter.selected == .inProgress)
        #expect(tabRouter.navigationResetTrigger == resetTrigger + 1)
        #expect(deepLinkRouter.routeMapDestination == nil)
    }

    @Test @MainActor func journeyHistoryNavigationTargetsTheRequestedRecord() {
        let tabRouter = TabRouter.shared
        let previousTab = tabRouter.selected
        let previousTarget = tabRouter.historyTarget
        defer {
            tabRouter.selected = previousTab
            tabRouter.historyTarget = previousTarget
        }

        let recordID = UUID()
        tabRouter.openHistoryRecord(id: recordID)

        #expect(tabRouter.selected == .history)
        #expect(tabRouter.historyTarget?.recordID == recordID)
    }

    @Test func journeyStopPlacementPreservesTheCurrentDestination() {
        #expect(JourneyStopPlacement.intermediate.insertionIndex(existingStopCount: 1) == 0)
        #expect(JourneyStopPlacement.intermediate.insertionIndex(existingStopCount: 3) == 2)
    }

    @Test func journeyStopPlacementCanExtendBeyondTheCurrentDestination() {
        #expect(JourneyStopPlacement.destination.insertionIndex(existingStopCount: 1) == 1)
        #expect(JourneyStopPlacement.destination.insertionIndex(existingStopCount: 3) == 3)
    }

    @Test func oneOffJourneyRequiresImmediateUpdatesAndCannotBeScheduled() {
        var options = AddJourneyOptions()

        options.setOneOff(true)
        #expect(options.oneOff == false)

        options.setSchedule(true)
        options.setStartNow(true)
        options.setOneOff(true)
        #expect(options.oneOff)
        #expect(options.schedule == false)

        options.setStartNow(false)
        #expect(options.oneOff == false)
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

    @Test func nearbyStationSuggestionsAreDeduplicatedAndSortedNearestFirst() {
        let currentLocation = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)
        let stations = [
            Station(crs: "FAR", name: "Far", longitude: "-0.1", latitude: "51.6"),
            Station(crs: "NBR", name: "Nearby", longitude: "-0.1", latitude: "51.501"),
            Station(crs: "MID", name: "Middle", longitude: "-0.1", latitude: "51.52"),
            Station(crs: "nbr", name: "Nearby duplicate", longitude: "-0.1", latitude: "51.502"),
            Station(crs: "BAD", name: "Missing coordinate", longitude: "0", latitude: "0")
        ]

        let nearby = StationSuggestionPolicy.nearbyStations(
            in: stations,
            from: currentLocation
        )

        #expect(nearby.map(\.station.crs) == ["NBR", "MID", "FAR"])
        #expect(nearby.map(\.distance) == nearby.map(\.distance).sorted())
        #expect(StationSuggestionPolicy.defaultNearbyCount == 3)
        #expect(StationSuggestionPolicy.expandedNearbyCount == 20)
    }

    @Test func recentStationSuggestionsPreserveJourneyRecencyAndRemoveDuplicates() {
        let victoria = station(crs: "VIC", name: "London Victoria")
        let kentHouse = station(crs: "KTH", name: "Kent House")
        let bromleySouth = station(crs: "BMS", name: "Bromley South")

        let recent = StationSuggestionPolicy.recentStations(from: [
            [victoria, kentHouse],
            [Station(crs: "vic", name: "Victoria duplicate", longitude: "0", latitude: "0"), bromleySouth]
        ])

        #expect(recent.map(\.crs) == ["VIC", "KTH", "BMS"])
        #expect(StationSuggestionPolicy.defaultRecentCount == 10)
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

    @Test func delayedConditionEventsCanDriveTransitionsWithinRecoveryLifetime() {
        let now = Date(timeIntervalSince1970: 100_000)

        #expect(StationDetectionPolicy.isConditionEventActionable(
            recordedAt: now.addingTimeInterval(-4 * 60),
            now: now
        ))
        #expect(!StationDetectionPolicy.isConditionEventActionable(
            recordedAt: now.addingTimeInterval(-(StationDetectionPolicy.conditionEventActionLifetime + 1)),
            now: now
        ))
        #expect(!StationDetectionPolicy.isConditionEventActionable(
            recordedAt: now.addingTimeInterval(1),
            now: now
        ))
    }

    @Test @MainActor func explicitJourneySuppressesAnOverlappingScheduleAtTheSameOrigin() {
        let scheduled = arrivalTarget(id: "scheduled", from: "KTH", to: "VIC", scheduled: true)
        let explicit = arrivalTarget(id: "explicit", from: "KTH", to: "BFR", scheduled: false)
        let reverseSchedule = arrivalTarget(id: "reverse", from: "VIC", to: "KTH", scheduled: true)

        let selected = NotificationGeofenceManager.targetsByPrioritizingExplicitJourneys([
            scheduled.identifier: scheduled,
            explicit.identifier: explicit,
            reverseSchedule.identifier: reverseSchedule
        ])

        #expect(Set(selected.keys) == ["explicit", "reverse"])
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

    @Test func inProgressMapUsesTheNextServiceThatHasNotDeparted() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 27,
            hour: 16,
            minute: 14
        )))
        let departed = departure(at: "16:12", serviceID: "departed")
        let next = departure(at: "16:27", serviceID: "next")

        let selected = InProgressJourneyPresentation.nextServiceDeparture(
            from: [departed, next],
            now: now
        )

        #expect(selected?.serviceID == "next")
    }

    @Test func inProgressFinalDestinationETAShowsArrivalDelay() {
        #expect(InProgressJourneyPresentation.finalDestinationETAText(
            time: "08:05",
            delayMinutes: 2
        ) == "ETA 08:05, 2 minutes late")
        #expect(InProgressJourneyPresentation.finalDestinationETAText(
            time: "08:03",
            delayMinutes: 0
        ) == "ETA 08:03, on time")
    }

    @Test func inProgressFinalDestinationOnlyShowsOriginalArrivalWhenLate() {
        #expect(InProgressJourneyPresentation.originalArrivalText(
            time: "08:03",
            delayMinutes: 2
        ) == "Originally due to arrive at 08:03")
        #expect(InProgressJourneyPresentation.originalArrivalText(
            time: "08:03",
            delayMinutes: 0
        ) == nil)
    }

    @Test func itineraryRetainsFinalArrivalDelay() {
        let serviceID = "delayed-final-arrival"
        let groupID = UUID()
        let directJourney = journey(
            groupID: groupID,
            index: 0,
            from: station(crs: "KTH", name: "Kent House"),
            to: station(crs: "VIC", name: "London Victoria")
        )
        let selectedDeparture = departure(at: "07:42", serviceID: serviceID)
        let details = serviceDetails(callingPoints: [
            callingPoint(
                name: "London Victoria",
                crs: "VIC",
                time: "08:03",
                estimatedTime: "08:05"
            )
        ])

        let itinerary = JourneyItineraryBuilder.build(
            group: JourneyGroup(id: groupID, legs: [directJourney]),
            firstDeparture: selectedDeparture,
            departuresForJourney: { _ in [selectedDeparture] },
            serviceDetailsByID: [serviceID: details]
        )

        #expect(itinerary.finalArrivalTime == "08:05")
        #expect(itinerary.finalArrivalDelayMinutes == 2)
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

    @Test func journeyCardArrivalLabelUsesTheTimeWithoutRepeatingTheDestination() {
        #expect(JourneyCardPresentation.arrivalTimeLabel("20:33") == "20:33")
    }

    @Test func journeyCardArrivalLabelsHandleLateAndUnknownTimes() {
        #expect(JourneyCardPresentation.arrivalTimeLabel("20:49") == "20:49")
        #expect(JourneyCardPresentation.arrivalTimeLabel("Delayed") == "TBC (delayed)")
        #expect(JourneyCardPresentation.arrivalTimeLabel(nil) == "TBC")
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

    private func arrivalTarget(
        id: String,
        from: String,
        to: String,
        scheduled: Bool
    ) -> StationArrivalTarget {
        StationArrivalTarget(
            identifier: id,
            subscriptionId: id,
            from: from,
            to: to,
            station: station(crs: from, name: from),
            activeUntil: nil,
            muteOnArrival: true,
            isScheduledActivation: scheduled,
            scheduleKind: nil,
            daysOfWeek: nil,
            windowStart: nil,
            windowEnd: nil,
            travelDate: nil
        )
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
        estimatedTime: String? = nil,
        isCancelled: Bool = false
    ) -> CallingPoint {
        CallingPoint(
            locationName: name,
            crs: crs,
            st: time,
            et: isCancelled ? "Cancelled" : (estimatedTime ?? "On time"),
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

private func scheduledJourneyUpdate(
    id: String,
    days: [DayOfWeek],
    windows: [(start: String, end: String)],
    scheduleKind: NotificationScheduleKind? = .regular,
    travelDates: [String?] = []
) -> NotificationSubscription {
    let routes = [("KTH", "VIC"), ("VIC", "KTH")]
    let legs = windows.enumerated().map { index, window in
        let route = routes[index]
        return NotificationLeg(
            from: route.0,
            to: route.1,
            fromName: route.0,
            toName: route.1,
            enabled: true,
            windowStart: window.start,
            windowEnd: window.end,
            travelDate: travelDates.indices.contains(index) ? travelDates[index] : nil
        )
    }
    return NotificationSubscription(
        id: id,
        deviceId: "device-1",
        routeKey: "KTH-VIC",
        scheduleKind: scheduleKind,
        daysOfWeek: days,
        notificationTypes: [.delays],
        legs: legs,
        muteOnArrival: true,
        source: .scheduled,
        liveSessionOrigin: nil,
        activeUntil: nil,
        mutedByLegDay: nil,
        mutedAtByLegDay: nil,
        createdAt: nil,
        updatedAt: nil
    )
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
