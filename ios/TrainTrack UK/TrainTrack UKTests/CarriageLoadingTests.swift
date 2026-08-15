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
            reason: nil,
            error: nil
        )

        #expect(available.freshCoaches?.count == 1)
        #expect(stale.freshCoaches == nil)
    }
}
