import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct JourneyBoardingEvidenceTests {
    @Test func replacementRetainsAnArrivalAndTheSnapshotThatFinishesAfterDisarm() throws {
        let arrivedAt = date("17:15")
        var removed = candidate(id: "scheduled", arrivedAt: arrivedAt)
        var replacement = candidate(id: "live-session")

        // The scheduled subscription disappears while its departure request is in flight.
        replacement.inheritBoardingEvidence(from: removed, now: arrivedAt)
        removed.candidateDepartures = [departure("17:27"), departure("17:42")]
        replacement.inheritBoardingEvidence(from: removed, now: arrivedAt.addingTimeInterval(1))

        let restored = try JSONDecoder().decode(
            ArmedJourneyHistoryCandidate.self,
            from: JSONEncoder().encode(replacement)
        )
        #expect(restored.subscriptionId == "live-session")
        #expect(restored.originArrivedAt == arrivedAt)
        #expect(restored.candidateDepartures.map(\.serviceID) == ["17:27", "17:42"])

        let match = JourneyServiceMatchingPolicy.match(
            departures: restored.candidateDepartures,
            recentDepartures: [],
            from: restored.stations[0], to: restored.stations[1],
            detectedAt: date("17:33").addingTimeInterval(37),
            originArrivedAt: restored.originArrivedAt
        )
        #expect(match.departure?.serviceID == "17:27")
    }

    @Test func repeatedTransfersKeepTheEarliestArrivalWithoutOverwritingKnownDepartures() {
        let old = candidate(arrivedAt: date("17:15"), departures: [departure("17:27"), departure("17:42")])
        var replacement = candidate(arrivedAt: date("17:16"), departures: [departure("17:42", estimated: "17:44")])
        replacement.inheritBoardingEvidence(from: old, now: date("17:17"))
        replacement.inheritBoardingEvidence(from: old, now: date("17:17"))

        #expect(replacement.originArrivedAt == date("17:15"))
        #expect(replacement.candidateDepartures.count == 2)
        #expect(replacement.candidateDepartures.first?.departureTime.estimated == "17:44")
    }

    @Test func unrelatedRoutesAndSourcesDoNotInheritBoardingEvidence() {
        let old = candidate(arrivedAt: date("17:15"), departures: [departure("17:27")])
        var reversed = candidate(stations: Array(old.stations.reversed()))
        var indirect = candidate(stations: [station("VIC"), station("BRX"), station("KTH")])
        var adHoc = candidate(source: .adhoc)
        reversed.inheritBoardingEvidence(from: old, now: date("17:17"))
        indirect.inheritBoardingEvidence(from: old, now: date("17:17"))
        adHoc.inheritBoardingEvidence(from: old, now: date("17:17"))

        for unrelated in [reversed, indirect, adHoc] {
            #expect(unrelated.originArrivedAt == nil)
            #expect(unrelated.candidateDepartures.isEmpty)
        }
    }

    @Test func expiredCandidatesAndOldOrFutureArrivalsAreNotTransferred() {
        let now = date("17:17")
        for old in [
            candidate(arrivedAt: date("17:15"), expiresAt: now),
            candidate(arrivedAt: now.addingTimeInterval(-24 * 60 * 60 - 1)),
            candidate(arrivedAt: now.addingTimeInterval(1))
        ] {
            var replacement = candidate()
            replacement.inheritBoardingEvidence(from: old, now: now)
            #expect(replacement.originArrivedAt == nil)
        }
        var expiredReplacement = candidate(expiresAt: now)
        expiredReplacement.inheritBoardingEvidence(from: candidate(arrivedAt: date("17:15")), now: now)
        #expect(expiredReplacement.originArrivedAt == nil)
    }

    private func candidate(
        id: String = UUID().uuidString,
        source: JourneyHistorySource = .scheduled,
        stations: [Station]? = nil,
        arrivedAt: Date? = nil,
        departures: [DepartureV2] = [],
        expiresAt: Date? = nil
    ) -> ArmedJourneyHistoryCandidate {
        ArmedJourneyHistoryCandidate(
            subscriptionId: id, source: source,
            stations: stations ?? [station("VIC"), station("KTH")],
            createdAt: date("17:00"), activeUntil: expiresAt,
            originArrivedAt: arrivedAt, candidateDepartures: departures
        )
    }

    private func station(_ crs: String) -> Station {
        Station(crs: crs, name: crs, longitude: "0", latitude: "0")
    }

    private func departure(_ scheduled: String, estimated: String? = nil) -> DepartureV2 {
        DepartureV2(
            departureTime: DepartureTimeV2(scheduled: scheduled, estimated: estimated ?? scheduled),
            serviceType: "train", platform: nil, isCancelled: false, length: nil,
            destination: [], origin: nil, serviceID: scheduled,
            delayReason: nil, cancelReason: nil, timestamp: nil
        )
    }

    private func date(_ time: String) -> Date {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 9, hour: parts[0], minute: parts[1]
        ))!
    }
}
