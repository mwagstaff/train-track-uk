import Foundation
import Testing
@testable import TrainTrack_UK

struct LiveStatusRegressionTests {
    private func details(actualAtDestination: String? = nil, delayed: Bool = true) throws -> ServiceDetails {
        var destination: [String: Any] = ["locationName": "Brighton", "crs": "BTN", "st": "00:50", "et": delayed ? "Delayed" : "On time"]
        if let actualAtDestination { destination["at"] = actualAtDestination }
        let json: [String: Any] = [
            "previousCallingPoints": [["callingPoint": [["locationName": "Harlington", "crs": "HLN", "st": "23:20", "at": "23:24"]]]],
            "subsequentCallingPoints": [["callingPoint": [destination]]],
            "locationName": "East Croydon", "crs": "ECR", "std": "23:52", "etd": delayed ? "Delayed" : "On time",
            "generatedAt": "2026-09-26T23:04:00Z", "serviceType": "train"
        ]
        return try JSONDecoder().decode(ServiceDetails.self, from: JSONSerialization.data(withJSONObject: json))
    }

    @Test func unknownDelayBeforePassengerOriginDoesNotClaimArrival() throws {
        let details = try details()
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-26T23:04:00Z"))
        let status = try #require(computeLiveStatus(from: details, within: "ECR", toCRS: "BTN", at: now))
        #expect(status.text == "Currently delayed for an unknown period of time, at Harlington")
        #expect(status.delayMinutes == 240)
        let progress = ServiceProgressEstimator.estimate(for: details.allStations, at: now)
        #expect(details.allStations[progress.previousStationIndex].crs == "HLN")
    }

    @Test func passingScheduledArrivalWithoutActualDoesNotConfirmArrival() throws {
        let details = try details(delayed: false)
        let now = try #require(ISO8601DateFormatter().date(from: "2026-09-27T01:04:00Z"))
        let status = try #require(computeLiveStatus(from: details, within: "ECR", toCRS: "BTN", at: now))
        #expect(!status.text.hasPrefix("Arrived"))
    }

    @Test func confirmedArrivalReportsActualDelay() throws {
        let status = try #require(computeLiveStatus(from: details(actualAtDestination: "01:05"), toCRS: "BTN"))
        #expect(status.text == "Arrived 15 minutes late at Brighton")
    }

    @Test func actualDelayAcrossMidnightUsesForwardDifference() throws {
        let raw: [String: Any] = ["locationName": "Brighton", "crs": "BTN", "sta": "23:58", "ata": "00:07",
                                  "generatedAt": "2026-09-26T23:07:00Z", "serviceType": "train"]
        let details = try JSONDecoder().decode(ServiceDetails.self, from: JSONSerialization.data(withJSONObject: raw))
        #expect(computeLiveStatus(from: details)?.delayMinutes == 9)
    }
}
