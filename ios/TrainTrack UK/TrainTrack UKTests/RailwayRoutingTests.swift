import Foundation
import Testing
@testable import TrainTrack_UK

struct RailwayRoutingTests {
    @Test func kentHouseToVictoriaUsesTheMainlineAlignment() async throws {
        let route = try await RailwayRoutingService.shared.route(forStationCRSs: [
            "KTH", "PNE", "SYH", "WDU", "HNH", "BRX", "VIC"
        ])

        #expect(route.stationCount == 7)
        #expect((12_000...13_000).contains(route.totalLength))
        #expect(route.coordinates.count > 80)
        #expect(route.coordinate(atStation: 0) != nil)
        #expect(route.coordinate(atStation: 6) != nil)
    }

    @Test func reverseRouteKeepsContinuousOrientedGeometry() async throws {
        let outbound = try await RailwayRoutingService.shared.route(forStationCRSs: [
            "KTH", "PNE", "SYH", "WDU", "HNH", "BRX", "VIC"
        ])
        let reverse = try await RailwayRoutingService.shared.route(forStationCRSs: [
            "VIC", "BRX", "HNH", "WDU", "SYH", "PNE", "KTH"
        ])

        #expect(abs(outbound.totalLength - reverse.totalLength) < 1)
        #expect(reverse.stationCount == 7)
        #expect(reverse.coordinates.count == outbound.coordinates.count)
    }

    @Test func progressInterpolatesWithinTheCurrentCallingPointSegment() {
        let now = date(year: 2026, month: 8, day: 15, hour: 12, minute: 5)
        let estimate = ServiceProgressEstimator.estimate(
            for: [
                callingPoint(crs: "AAA", scheduled: "12:00", actual: "On time"),
                callingPoint(crs: "BBB", scheduled: "12:11")
            ],
            at: now,
            calendar: calendar
        )

        #expect(estimate.previousStationIndex == 0)
        #expect(estimate.nextStationIndex == 1)
        #expect((0.47...0.49).contains(estimate.fraction))
    }

    @Test func progressHandlesAServiceCrossingMidnight() {
        let now = date(year: 2026, month: 8, day: 16, hour: 0, minute: 3)
        let estimate = ServiceProgressEstimator.estimate(
            for: [
                callingPoint(crs: "AAA", scheduled: "23:58", actual: "On time"),
                callingPoint(crs: "BBB", scheduled: "00:08")
            ],
            at: now,
            calendar: calendar
        )

        #expect(estimate.previousStationIndex == 0)
        #expect(estimate.nextStationIndex == 1)
        #expect((0.52...0.54).contains(estimate.fraction))
    }

    @Test func unknownDelayHoldsTheEstimateAtTheLastActualStation() {
        let now = date(year: 2026, month: 8, day: 15, hour: 12, minute: 30)
        let estimate = ServiceProgressEstimator.estimate(
            for: [
                callingPoint(crs: "AAA", scheduled: "12:00", actual: "12:01"),
                callingPoint(crs: "BBB", scheduled: "12:10", estimated: "Delayed")
            ],
            at: now,
            calendar: calendar
        )

        #expect(estimate.previousStationIndex == 0)
        #expect(estimate.nextStationIndex == 0)
        #expect(estimate.fraction == 0)
    }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private func callingPoint(
        crs: String,
        scheduled: String,
        estimated: String? = "On time",
        actual: String? = nil
    ) -> CallingPoint {
        CallingPoint(
            locationName: crs,
            crs: crs,
            st: scheduled,
            et: estimated,
            at: actual,
            isCancelled: false,
            cancelReason: nil,
            length: nil,
            detachFront: nil,
            affectedByDiversion: false,
            rerouteDelay: 0
        )
    }
}
