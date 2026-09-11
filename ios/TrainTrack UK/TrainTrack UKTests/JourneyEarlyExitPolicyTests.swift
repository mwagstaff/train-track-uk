import Foundation
import Testing
@testable import TrainTrack_UK

struct JourneyEarlyExitPolicyTests {
    private let departedAt = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func sydenhamHillCachedFixCannotTurnFortyOneSecondsIntoNinetySecondsOfDwell() {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 40.805, speed: 2.7436))

        // The incident replayed the same fix 98.208 seconds later, when the
        // backend departure was 139.013 seconds old and the train had moved on.
        #expect(!observe(&policy, at: 40.805, evaluatedAt: 139.013, speed: 2.7436))
        #expect(policy.observedDwellSeconds == 0)
    }

    @Test func repeatedAndOutOfOrderFixesCannotExtendDwell() {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 10))
        #expect(!observe(&policy, at: 40))
        #expect(!observe(&policy, at: 70))
        #expect(!observe(&policy, at: 70, evaluatedAt: 85))
        #expect(!observe(&policy, at: 65, evaluatedAt: 75))
        #expect(policy.observedDwellSeconds == 60)
    }

    @Test func freshStationObservationsConfirmAnActualNinetySecondDwell() {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 10))
        #expect(!observe(&policy, at: 40))
        #expect(!observe(&policy, at: 70))
        #expect(!observe(&policy, at: 99))
        #expect(observe(&policy, at: 100, stationCRS: "syh"))
        #expect(policy.observedDwellSeconds == 90)
    }

    @Test func oldDepartureAloneDoesNotEstablishDeviceDwell() {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 180))
        #expect(policy.observedDwellSeconds == 0)
    }

    @Test func observationsBeforeTheServiceDepartsCannotContribute() {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: -60))
        #expect(!observe(&policy, at: -30))
        #expect(!observe(&policy, at: 0))
        #expect(!observe(&policy, at: 30))
        #expect(policy.observedDwellSeconds == 30)
    }

    @Test func locationGapRestartsDwellEvidence() {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 10))
        #expect(!observe(&policy, at: 40))
        #expect(!observe(&policy, at: 100))
        #expect(policy.observedDwellSeconds == 0)
        #expect(!observe(&policy, at: 145))
        #expect(observe(&policy, at: 190))
    }

    @Test(arguments: [Optional("WDU"), nil])
    func leavingTheStationClearsEvidence(stationCRS: String?) {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 10))
        #expect(!observe(&policy, at: 40))
        #expect(!observe(&policy, at: 70, stationCRS: stationCRS))
        #expect(!observe(&policy, at: 100))
        #expect(policy.observedDwellSeconds == 0)
    }

    @Test(arguments: [-1.0, Double.nan, Double.infinity, 3.0, 12.0])
    func unknownOrMovingSpeedCannotProveAStationDwell(speed: Double) {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 10))
        #expect(!observe(&policy, at: 40))
        #expect(!observe(&policy, at: 70, speed: speed))
        #expect(!observe(&policy, at: 100))
        #expect(policy.observedDwellSeconds == 0)
    }

    @Test(arguments: [-1.0, 65.01, Double.nan, Double.infinity])
    func unreliableAccuracyCannotAdvanceDwell(horizontalAccuracy: Double) {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 10))
        #expect(!observe(&policy, at: 40))
        #expect(!observe(&policy, at: 70, horizontalAccuracy: horizontalAccuracy))
        #expect(policy.observedDwellSeconds == 30)
        #expect(!observe(&policy, at: 100))
        #expect(policy.observedDwellSeconds == 0)
    }

    @Test func staleOrFutureFixesCannotAdvanceDwell() {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 10))
        #expect(!observe(&policy, at: 40))
        #expect(!observe(&policy, at: 70, evaluatedAt: 85.001))
        #expect(!observe(&policy, at: 70, evaluatedAt: 69))
        #expect(policy.observedDwellSeconds == 30)
    }

    @Test func newDepartureStartsNewEvidence() {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 10))
        #expect(!observe(&policy, at: 40))
        #expect(!observe(&policy, at: 70))
        #expect(!observe(&policy, at: 100, serviceDepartedAt: departedAt.addingTimeInterval(80)))
        #expect(policy.observedDwellSeconds == 0)
    }

    @Test func resettingForAnotherJourneyDiscardsThePreviousDwell() {
        var policy = JourneyEarlyExitPolicy()
        #expect(!observe(&policy, at: 10))
        #expect(!observe(&policy, at: 40))
        #expect(!observe(&policy, at: 70))
        policy.reset()
        #expect(!observe(&policy, at: 100))
        #expect(policy.observedDwellSeconds == 0)
    }

    private func observe(
        _ policy: inout JourneyEarlyExitPolicy,
        at seconds: TimeInterval,
        evaluatedAt evaluatedSeconds: TimeInterval? = nil,
        stationCRS: String? = "SYH",
        serviceDepartedAt: Date? = nil,
        horizontalAccuracy: Double = 17.47,
        speed: Double = 0.5
    ) -> Bool {
        policy.shouldEndJourney(
            stationCRS: stationCRS,
            departedStationCRS: "SYH",
            departedAt: serviceDepartedAt ?? departedAt,
            locationTimestamp: departedAt.addingTimeInterval(seconds),
            evaluatedAt: departedAt.addingTimeInterval(evaluatedSeconds ?? seconds),
            horizontalAccuracy: horizontalAccuracy,
            speed: speed
        )
    }
}
