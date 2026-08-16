import Foundation
import CoreLocation
import Testing
@testable import TrainTrack_UK

struct RailwayRoutingTests {
    @Test func kentHouseToVictoriaUsesTheMainlineAlignment() async throws {
        let route = try await RailwayRoutingService.ordnanceSurvey.route(forStationCRSs: [
            "KTH", "PNE", "SYH", "WDU", "HNH", "BRX", "VIC"
        ])

        #expect(route.stationCount == 7)
        #expect((12_000...13_000).contains(route.totalLength))
        #expect(route.coordinates.count > 80)
        #expect(route.coordinate(atStation: 0) != nil)
        #expect(route.coordinate(atStation: 6) != nil)
    }

    @Test func openStreetMapRouteUsesTheMainlineAlignment() async throws {
        let route = try await RailwayRoutingService.openStreetMap.route(forStationCRSs: [
            "KTH", "PNE", "SYH", "WDU", "HNH", "BRX", "VIC"
        ])

        #expect(route.stationCount == 7)
        #expect((12_000...13_000).contains(route.totalLength))
        #expect(route.coordinates.count > 100)
    }

    @Test func mapSourcesProduceComparableRoutes() async throws {
        let callingPattern = ["KTH", "PNE", "SYH", "WDU", "HNH", "BRX", "VIC"]
        let osRoute = try await RailwayRoutingService.ordnanceSurvey.route(
            forStationCRSs: callingPattern
        )
        let osmRoute = try await RailwayRoutingService.openStreetMap.route(
            forStationCRSs: callingPattern
        )

        #expect(abs(osRoute.totalLength - osmRoute.totalLength) < 500)
        for stationIndex in callingPattern.indices {
            let osCoordinate = try #require(osRoute.coordinate(atStation: stationIndex))
            let osmCoordinate = try #require(osmRoute.coordinate(atStation: stationIndex))
            let separation = CLLocation(
                latitude: osCoordinate.latitude,
                longitude: osCoordinate.longitude
            ).distance(from: CLLocation(
                latitude: osmCoordinate.latitude,
                longitude: osmCoordinate.longitude
            ))
            #expect(separation < 150)
        }
    }

    @Test func reverseRouteKeepsContinuousOrientedGeometry() async throws {
        let outbound = try await RailwayRoutingService.ordnanceSurvey.route(forStationCRSs: [
            "KTH", "PNE", "SYH", "WDU", "HNH", "BRX", "VIC"
        ])
        let reverse = try await RailwayRoutingService.ordnanceSurvey.route(forStationCRSs: [
            "VIC", "BRX", "HNH", "WDU", "SYH", "PNE", "KTH"
        ])

        #expect(abs(outbound.totalLength - reverse.totalLength) < 1)
        #expect(reverse.stationCount == 7)
        #expect(reverse.coordinates.count == outbound.coordinates.count)
    }

    @Test func reverseOpenStreetMapRouteIsAvailable() async throws {
        let route = try await RailwayRoutingService.openStreetMap.route(forStationCRSs: [
            "VIC", "BRX", "HNH", "WDU", "SYH", "PNE", "KTH"
        ])

        #expect(route.stationCount == 7)
        #expect((12_000...13_000).contains(route.totalLength))
        #expect(route.coordinates.count > 100)
    }

    @Test func openStreetMapCoversRepresentativeGreatBritainRoutes() async throws {
        let fixtures: [(callingPoints: [String], expectedKilometres: ClosedRange<Double>)] = [
            (["PNZ", "SER", "CBN", "RED", "TRU", "SAU", "PAR", "BOD", "LSK", "PLY"], 120...135),
            (["CDF", "BGN", "PTA", "NTH", "SWA"], 65...80),
            (["CRE", "CTR", "RHL", "CWB", "LLJ", "BNG", "HHD"], 160...180),
            (["KGX", "SVG", "PBO", "GRA", "NNG", "DON", "YRK", "DAR", "DHM", "NCL", "BWK", "EDB"], 600...670),
            (["EDB", "HYM", "STG", "PTH", "PIT", "KIN", "AVM", "INV"], 280...320),
            (["INV", "DIN", "TAI", "GOL", "HMS", "KIL", "FRS", "GGJ", "THS", "WCK"], 260...300),
            (["BHM", "SGB", "WVH", "TFC", "SHR", "WLP", "NWT", "MCN", "BRH", "AYW"], 180...220),
            (["BDM", "LTN", "SAC", "STP", "ZFD", "CTK", "BFR", "LBG", "ECR", "GTW", "HHE", "BTN"], 155...180),
        ]

        for fixture in fixtures {
            let route = try await RailwayRoutingService.openStreetMap.route(
                forStationCRSs: fixture.callingPoints
            )
            #expect(route.stationCount == fixture.callingPoints.count)
            #expect(fixture.expectedKilometres.contains(route.totalLength / 1_000))
            #expect(route.coordinates.count > route.stationCount)
        }
    }

    @Test func openStreetMapSouthernRouteUsesClaphamBrightonMainLinePlatforms() async throws {
        let route = try await RailwayRoutingService.openStreetMap.route(forStationCRSs: [
            "VIC", "CLJ", "SRS", "ECR", "PUR", "HOR", "GTW", "TBD", "HHE", "BTN"
        ])

        #expect((80_000...83_000).contains(route.totalLength))
        #expect(segmentLength(route, fromStation: 0, toStation: 1) < 4_600)
        #expect(segmentLength(route, fromStation: 1, toStation: 2) < 11_500)
    }

    @Test func openStreetMapThameslinkRouteUsesStPancrasLowLevelPlatforms() async throws {
        let route = try await RailwayRoutingService.openStreetMap.route(forStationCRSs: [
            "BDM", "FLT", "HLN", "LEA", "LUT", "LTN", "HPD", "SAC", "RDT", "ELS",
            "MIL", "HEN", "BCZ", "CRI", "WHP", "KTN", "STP", "BFR", "ECR", "PUR",
            "HOR", "GTW", "TBD", "HHE", "BTN"
        ])

        #expect((163_000...167_000).contains(route.totalLength))
        #expect(segmentLength(route, fromStation: 15, toStation: 16) < 2_500)
        #expect(segmentLength(route, fromStation: 16, toStation: 17) < 4_000)
    }

    @Test @MainActor func railwayRouteSegmentsUseExistingDelayThresholds() {
        let onTime = callingPoint(crs: "AAA", scheduled: "12:00")
        let minorDelay = callingPoint(crs: "BBB", scheduled: "12:10", estimated: "12:13")
        let majorDelay = callingPoint(crs: "CCC", scheduled: "12:20", estimated: "12:25")
        let cancelled = callingPoint(crs: "DDD", scheduled: "12:30", estimated: "Cancelled")

        #expect(RailwayRouteSegmentStatus.between(onTime, and: onTime) == .onTime)
        #expect(RailwayRouteSegmentStatus.between(onTime, and: minorDelay) == .minorDelay)
        #expect(
            RailwayRouteSegmentStatus.between(minorDelay, and: majorDelay)
                == .majorDelayOrCancellation
        )
        #expect(
            RailwayRouteSegmentStatus.between(onTime, and: cancelled)
                == .majorDelayOrCancellation
        )
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

    private func segmentLength(
        _ route: ServiceRailwayRoute,
        fromStation start: Int,
        toStation end: Int
    ) -> CLLocationDistance {
        let startIndex = route.stationCoordinateIndices[start]
        let endIndex = route.stationCoordinateIndices[end]
        return route.cumulativeDistances[endIndex] - route.cumulativeDistances[startIndex]
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
