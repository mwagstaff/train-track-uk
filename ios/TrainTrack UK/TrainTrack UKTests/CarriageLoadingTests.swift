import Foundation
import Testing
@testable import TrainTrack_UK

struct CarriageLoadingTests {
    @Test func loadingBandBoundariesMatchProductRules() {
        #expect(CarriageLoadingBand.value(for: 0) == .green)
        #expect(CarriageLoadingBand.value(for: 33) == .green)
        #expect(CarriageLoadingBand.value(for: 34) == .amber)
        #expect(CarriageLoadingBand.value(for: 66) == .amber)
        #expect(CarriageLoadingBand.value(for: 67) == .red)
        #expect(CarriageLoadingBand.value(for: 100) == .red)
        #expect(CarriageLoadingBand.value(for: nil) == .unknown)
    }

    @Test func onlyFreshLiveLoadingIsPresentedAsCarriageColour() {
        let coach = CoachLoadingV1(
            number: "A1",
            position: 1,
            percentage: 72,
            band: "red",
            coachClass: "Standard"
        )
        let available = ServiceLoadingV1(
            serviceID: "service",
            status: "available",
            rid: "rid",
            formationId: "fid",
            observedAt: nil,
            ageSeconds: 10,
            coaches: [coach],
            splitGuidance: nil,
            reason: nil,
            error: nil
        )
        let stale = ServiceLoadingV1(
            serviceID: "service",
            status: "stale",
            rid: "rid",
            formationId: "fid",
            observedAt: nil,
            ageSeconds: 900,
            coaches: [coach],
            splitGuidance: nil,
            reason: nil,
            error: nil
        )

        #expect(available.freshCoaches?.count == 1)
        #expect(stale.freshCoaches == nil)
    }

    @Test func splitGuidanceDecodesAndProducesPassengerCopy() throws {
        let data = Data(#"""
        {
          "serviceID": "service",
          "status": "waiting_for_update",
          "splitGuidance": {
            "splitAt": { "crs": "WRH", "locationName": "Worthing" },
            "destinationCRS": "LIT",
            "position": "rear",
            "coachCount": 8,
            "confidence": "validated_lengths"
          }
        }
        """#.utf8)

        let details = try JSONDecoder().decode(ServiceLoadingV1.self, from: data)
        let guidance = try #require(details.splitGuidance)
        #expect(JourneyCardPresentation.splitGuidanceLabel(
            guidance,
            destinationName: "Littlehampton"
        ) == "Train divides at Worthing. Travel in the rear 8 coaches for Littlehampton.")
    }
}
