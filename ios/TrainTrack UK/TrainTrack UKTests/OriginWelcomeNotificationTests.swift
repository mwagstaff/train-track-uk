import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct OriginWelcomeNotificationTests {
    private var now: Date { ISO8601DateFormatter().date(from: "2026-09-29T06:36:24Z")! }
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    @Test func kentHouseWelcomeSelectsNextUsableTrainInDepartureOrder() {
        let departures = [train("07:57"), train("07:27"), train("07:40", cancelled: true), train("07:42")]
        #expect(body(departures) == "Welcome to Kent House. Next train 07:42 from platform 2.")
    }

    @Test func delayedTrainsAreOrderedByExpectedTime() {
        #expect(body([train("07:42", estimated: "08:00"), train("07:57")])
            == "Welcome to Kent House. Next train 07:57 from platform 2.")
        #expect(body([train("07:27", estimated: "07:43")])
            == "Welcome to Kent House. Next train 07:27 (expected 07:43) from platform 2.")
    }

    @Test func departedTrainsAndCancelledDestinationCallsAreExcluded() {
        #expect(body([train("07:42", actual: "07:35"), train("07:43", destinationCancelled: true), train("07:57")])
            == "Welcome to Kent House. Next train 07:57 from platform 2.")
    }

    @Test func missingOrHiddenPlatformsAreNotInvented() {
        for train in [train("07:42", platform: nil), train("07:42", platform: " "), train("07:42", hidden: true)] {
            #expect(body([train]) == "Welcome to Kent House. Next train 07:42.")
        }
    }

    @Test func unavailableBoardStillProducesWelcomeAndDoesNotInventATrain() {
        #expect(body([]) == "Welcome to Kent House. Check the departure board for the next train.")
        #expect(body([train("Unknown")]) == body([]))
    }

    @Test func midnightAndUnknownDelayRemainExplicit() {
        let late = ISO8601DateFormatter().date(from: "2026-09-29T22:58:00Z")!
        #expect(OriginWelcomeNotification.body(stationName: "Kent House", departures: [train("00:05")], now: late, calendar: calendar)
            == "Welcome to Kent House. Next train 00:05 from platform 2.")
        #expect(body([train("07:42", estimated: "Delayed")])
            == "Welcome to Kent House. Next train 07:42 (delayed) from platform 2.")
    }

    @Test func shortTrainWarningUsesInclusiveUserThreshold() {
        #expect(body([train("07:42", length: 4)])
            == "Welcome to Kent House. Next train 07:42 from platform 2. It's short - only 4 cars long.")
        #expect(body([train("07:42", length: 8)], shortTrainThreshold: 8)
            == "Welcome to Kent House. Next train 07:42 from platform 2. It's short - only 8 cars long.")
        #expect(body([train("07:42", length: 4)], shortTrainThreshold: 3)
            == "Welcome to Kent House. Next train 07:42 from platform 2.")
    }

    @Test func longUnknownAndInvalidLengthsDoNotWarn() {
        for length: Int? in [nil, 0, -1, 5, 8] {
            #expect(body([train("07:42", length: length)])
                == "Welcome to Kent House. Next train 07:42 from platform 2.")
        }
    }

    @Test func warningUsesSelectedTrainOnly() {
        #expect(body([train("07:40", cancelled: true, length: 4), train("07:42", length: 8), train("07:57", length: 4)])
            == "Welcome to Kent House. Next train 07:42 from platform 2.")
        #expect(body([train("07:42", estimated: "08:00", length: 8), train("07:57", length: 4)])
            == "Welcome to Kent House. Next train 07:57 from platform 2. It's short - only 4 cars long.")
    }

    @Test func singleCarWarningPreservesDelayAndHiddenPlatform() {
        #expect(body([train("07:42", estimated: "07:45", hidden: true, length: 1)])
            == "Welcome to Kent House. Next train 07:42 (expected 07:45). It's short - only 1 car long.")
    }

    private func body(_ departures: [DepartureV2], shortTrainThreshold: Int = 4) -> String {
        OriginWelcomeNotification.body(stationName: "Kent House", departures: departures, now: now,
                                       shortTrainThreshold: shortTrainThreshold, calendar: calendar)
    }

    private func train(_ scheduled: String, estimated: String? = nil, actual: String? = nil,
                       platform: String? = "2", cancelled: Bool = false, destinationCancelled: Bool = false,
                       hidden: Bool = false, length: Int? = nil) -> DepartureV2 {
        DepartureV2(departureTime: DepartureTimeV2(scheduled: scheduled, estimated: estimated ?? scheduled, actual: actual),
                    serviceType: "train", platform: platform, isCancelled: cancelled, length: length,
                    destination: [], origin: nil, serviceID: scheduled, delayReason: nil, cancelReason: nil,
                    timestamp: nil, filterLocationCancelled: destinationCancelled, platformIsHidden: hidden)
    }
}
