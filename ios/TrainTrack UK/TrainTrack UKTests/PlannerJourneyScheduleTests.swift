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
}
