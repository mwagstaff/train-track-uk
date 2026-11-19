import Foundation
import Testing
@testable import TrainTrack_UK

struct PlannerJourneyScheduleTests {
    private func journey() throws -> PlannedJourney {
        try PlannerTime.decoder().decode(PlannedJourney.self, from: Data(#"""
        {"id":"result-that-will-expire","departure":"2030-10-20T00:35:00+01:00","arrival":"2030-10-20T01:05:00+01:00",
         "scheduledDeparture":"2030-10-20T00:25:00+01:00","durationMinutes":30,"changes":0,
         "legs":[{"kind":"vehicle","mode":"rail","from":{"crs":"KTH","name":"Kent House"},"to":{"crs":"VIC","name":"London Victoria"},
          "departure":"2030-10-20T00:35:00+01:00","arrival":"2030-10-20T01:05:00+01:00",
          "scheduledDeparture":"2030-10-20T00:25:00+01:00","scheduledArrival":"2030-10-20T00:55:00+01:00",
          "operator":"SE","uid":"A12345","originDate":"2030-10-19","serviceId":"temporary-provider-id",
          "serviceCallingPoints":[{"station":{"crs":"KTH","name":"Kent House"},"departure":"2030-10-20T00:25:00+01:00"},
           {"station":{"crs":"VIC","name":"London Victoria"},"arrival":"2030-10-20T00:55:00+01:00"}]}]}
        """#.utf8))
    }

    @Test func savedBoardGetsTrackingIdentityWithoutReplacingLiveTimes() throws {
        let details = try journey()
        var board = details
        board.legs[0].uid = nil
        board.legs[0].serviceCallingPoints = nil
        #expect(!ScheduledPlannerJourney(journey: board).canSchedule)
        let enriched = board.addingTrackingDetails(from: details)
        #expect(ScheduledPlannerJourney(journey: enriched).canSchedule)
        #expect(enriched.legs[0].departure == board.legs[0].departure)
        #expect(enriched.legs[0].serviceCallingPoints == details.legs[0].serviceCallingPoints)
        var different = details
        different.legs[0].scheduledDeparture = details.legs[0].scheduledDeparture?.addingTimeInterval(86400)
        #expect(!ScheduledPlannerJourney(journey: board.addingTrackingDetails(from: different)).canSchedule)
    }

    @Test func liveBoardReceivesDatedIdentityThroughItsOpaqueServiceReference() throws {
        var board = try journey()
        board.legs[0].uid = nil
        board.legs[0].originDate = nil
        var detail = try journey()
        detail.legs[0].scheduledServiceId = "resolved-timetable-service"
        let enriched = board.addingTrackingDetails(from: detail)
        #expect(ScheduledPlannerJourney(journey: enriched).canSchedule)
        #expect(enriched.legs[0].originDate == detail.legs[0].originDate)
        #expect(enriched.legs[0].scheduledServiceId == "resolved-timetable-service")
        #expect(enriched.legs[0].departure == board.legs[0].departure)
    }

    @Test func schedulingUsesScheduledTimesAndDefaultsToOneHour() throws {
        let selected = try journey()
        let plan = ScheduledPlannerJourney(journey: selected)
        #expect(plan.canSchedule)
        #expect(plan.leadMinutes == 60)
        #expect(!plan.showAllDepartures)
        #expect(plan.departure == selected.scheduledDeparture)
        #expect(plan.startsAt == plan.departure.addingTimeInterval(-3600))
        #expect(plan.legs[0].uid == "A12345")
        #expect(plan.legs[0].originDate == "2030-10-19")
        #expect(plan.legs[0].calls.count == 2)
    }

    @Test func leadTimeChangesDoNotChangeTheSelectedTrainOrActivityDuration() throws {
        let original = ScheduledPlannerJourney(journey: try journey())
        var edited = original
        edited.leadMinutes = 120
        #expect(edited.matches(original))
        #expect(edited.startsAt == original.startsAt.addingTimeInterval(-3600))
        #expect(edited.expiresAt == original.expiresAt)
        #expect(ScheduledPlannerJourney.leadTimeChoices == [15, 30, 45, 60, 90, 120])
    }

    @Test func itineraryRoundTripsWithoutTheSearchCacheOrProviderID() throws {
        let original = ScheduledPlannerJourney(journey: try journey())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(ScheduledPlannerJourney.self, from: data) == original)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("result-that-will-expire"))
        #expect(!text.contains("temporary-provider-id"))
    }

    @Test func oldSchedulesDefaultToSelectedServiceAndDisplayModePreservesTiming() throws {
        let original = ScheduledPlannerJourney(journey: try journey())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        json.removeValue(forKey: "showAllDepartures")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var restored = try decoder.decode(ScheduledPlannerJourney.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!restored.showAllDepartures)
        restored.showAllDepartures = true
        #expect(restored.matches(original))
        #expect(restored.startsAt == original.startsAt)
        #expect(restored.expiresAt == original.expiresAt)
        #expect(try decoder.decode(ScheduledPlannerJourney.self, from: encoder.encode(restored)).showAllDepartures)
    }
    @Test func individualServiceUsesTheSameDatedSchedule() throws {
        let selected = try journey()
        let single = ScheduledPlannerJourney(leg: selected.legs[0])
        #expect(single == ScheduledPlannerJourney(journey: selected))
        #expect(single.legs[0].plannerLeg.uid == selected.legs[0].uid)
        #expect(single.trackingWindow.start == single.startsAt)
        #expect(single.trackingLegs[0].travelDate == "2030-10-19")
    }

    @Test func datedReplacementBlocksOnlyItsOccurrenceIncludingCachedRecovery() throws {
        let leg = NotificationLeg(from: "KTH", to: "VIC", fromName: nil, toName: nil, enabled: true,
                                  windowStart: "07:00", windowEnd: "09:00")
        let start = Date(timeIntervalSince1970: 1921302000) // 2030-11-19 07:00 UTC
        let replacement = PlannerScheduleReplacement(subscriptionId: "regular", legIndex: 0, legKey: "KTH-VIC",
            start: start, end: start.addingTimeInterval(7200), title: "Kent House → London Victoria", revision: nil)
        var subscription = NotificationSubscription(id: "regular", deviceId: "test", routeKey: "KTH-VIC",
            daysOfWeek: DayOfWeek.allCases, notificationTypes: [.summary], legs: [leg], muteOnArrival: true,
            source: .scheduled, liveSessionOrigin: nil, activeUntil: nil, mutedByLegDay: nil,
            mutedAtByLegDay: nil, createdAt: nil, updatedAt: nil, replacedOccurrences: [replacement])
        let during = start.addingTimeInterval(3600)
        #expect(NotificationScheduleActivationPolicy.activeWindow(for: subscription, leg: leg,
            now: during, calendar: PlannerTime.calendar) == nil)
        #expect(NotificationScheduleActivationPolicy.windowForRouteRecovery(for: subscription, leg: leg,
            observedAt: during, receivedAt: during, calendar: PlannerTime.calendar) == nil)
        #expect(ScheduledJourneyActivationResolver.legs(for: subscription, matchingFrom: "KTH", to: "VIC", now: during).isEmpty)
        subscription.replacedOccurrences = []
        #expect(NotificationScheduleActivationPolicy.activeWindow(for: subscription, leg: leg,
            now: during, calendar: PlannerTime.calendar) != nil)
        #expect(!replacement.suppresses(from: "VIC", to: "KTH", at: during))
        #expect(!replacement.suppresses(leg, at: during.addingTimeInterval(86400)))
    }

    @Test func plannedTrackingUsesAbsoluteWindowAcrossMidnight() throws {
        let plan = ScheduledPlannerJourney(journey: try journey())
        let subscription = NotificationSubscription(id: "planned", deviceId: "test", routeKey: "KTH-VIC",
            scheduleKind: .oneOff, daysOfWeek: [], notificationTypes: [.summary], legs: plan.notificationLegs,
            muteOnArrival: false, source: .scheduled, liveSessionOrigin: nil, activeUntil: nil,
            mutedByLegDay: nil, mutedAtByLegDay: nil, createdAt: nil, updatedAt: nil, plannerJourney: plan)
        let leg = try #require(plan.trackingLegs.first)
        #expect(NotificationScheduleActivationPolicy.activeWindow(for: subscription, leg: leg,
            now: plan.startsAt.addingTimeInterval(-1)) == nil)
        #expect(NotificationScheduleActivationPolicy.activeWindow(for: subscription, leg: leg,
            now: plan.startsAt) == plan.trackingWindow)
        #expect(ScheduledJourneyActivationResolver.legs(for: subscription, matchingFrom: "KTH", to: "VIC",
            now: plan.startsAt) == plan.trackingLegs)
    }

}
