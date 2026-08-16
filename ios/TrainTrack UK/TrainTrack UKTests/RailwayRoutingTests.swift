import Foundation
import CoreLocation
import MapKit
import SwiftUI
import Testing
@testable import TrainTrack_UK

struct RailwayRoutingTests {
    @Test func kentHouseToVictoriaUsesTheMainlineAlignment() async throws {
        let route = try await RailwayRoutingService.shared.route(forStationCRSs: [
            "KTH", "PNE", "SYH", "WDU", "HNH", "BRX", "VIC"
        ])

        #expect(route.stationCount == 7)
        #expect((12_000...13_000).contains(route.totalLength))
        #expect(route.coordinates.count > 100)
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
            let route = try await RailwayRoutingService.shared.route(
                forStationCRSs: fixture.callingPoints
            )
            #expect(route.stationCount == fixture.callingPoints.count)
            #expect(fixture.expectedKilometres.contains(route.totalLength / 1_000))
            #expect(route.coordinates.count > route.stationCount)
        }
    }

    @Test func openStreetMapSouthernRouteUsesClaphamBrightonMainLinePlatforms() async throws {
        let route = try await RailwayRoutingService.shared.route(forStationCRSs: [
            "VIC", "CLJ", "SRS", "ECR", "PUR", "HOR", "GTW", "TBD", "HHE", "BTN"
        ])

        #expect((80_000...83_000).contains(route.totalLength))
        #expect(segmentLength(route, fromStation: 0, toStation: 1) < 4_600)
        #expect(segmentLength(route, fromStation: 1, toStation: 2) < 11_500)
    }

    @Test func openStreetMapThameslinkRouteUsesStPancrasLowLevelPlatforms() async throws {
        let route = try await RailwayRoutingService.shared.route(forStationCRSs: [
            "BDM", "FLT", "HLN", "LEA", "LUT", "LTN", "HPD", "SAC", "RDT", "ELS",
            "MIL", "HEN", "BCZ", "CRI", "WHP", "KTN", "STP", "BFR", "ECR", "PUR",
            "HOR", "GTW", "TBD", "HHE", "BTN"
        ])

        #expect((163_000...167_000).contains(route.totalLength))
        #expect(segmentLength(route, fromStation: 15, toStation: 16) < 2_500)
        #expect(segmentLength(route, fromStation: 16, toStation: 17) < 4_000)
    }

    @Test func openStreetMapCambridgeBrightonRouteIncludesCambridgeSouth() async throws {
        let callingPoints = [
            "CBG", "CMS", "RYS", "AWM", "BDK", "LET", "HIT", "SVG", "FPK", "STP",
            "ZFD", "BFR", "ECR", "GTW", "TBD", "HHE", "BUG", "BTN",
        ]
        let route = try await RailwayRoutingService.shared.route(
            forStationCRSs: callingPoints
        )

        #expect(route.stationCount == callingPoints.count)
        #expect((165_000...190_000).contains(route.totalLength))
        #expect(route.coordinate(atStation: 1) != nil)
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

    @Test @MainActor func mapLabelsIncludeDueOrDepartedTimesAndPunctuality() {
        let onTime = callingPoint(
            name: "East Croydon",
            crs: "ECR",
            scheduled: "01:47"
        )
        let oneMinuteLate = callingPoint(
            name: "East Croydon",
            crs: "ECR",
            scheduled: "01:47",
            estimated: "01:48"
        )
        let departedOnTime = callingPoint(
            name: "Orpington",
            crs: "ORP",
            scheduled: "08:20",
            actual: "On time"
        )
        let departedLate = callingPoint(
            name: "Orpington",
            crs: "ORP",
            scheduled: "08:20",
            actual: "08:21"
        )

        #expect(
            RailwayStationAnnotationLabel.text(for: onTime)
                == "East Croydon (due 01:47, on time)"
        )
        #expect(
            RailwayStationAnnotationLabel.text(for: oneMinuteLate)
                == "East Croydon (due 01:48, 1 min late)"
        )
        #expect(
            RailwayStationAnnotationLabel.text(for: departedOnTime)
                == "Orpington (departed 08:20, on time)"
        )
        #expect(
            RailwayStationAnnotationLabel.text(for: departedLate)
                == "Orpington (departed 08:21, 1 min late)"
        )
        #expect(
            RailwayEstimatedLocationLabel.text(delayMinutes: 26)
                == "Estimated location (26 mins late)"
        )
    }

    @Test @MainActor func stationPopoverShowsExpectedTimeAndPlatform() {
        let onTime = callingPoint(
            name: "East Croydon",
            crs: "ECR",
            scheduled: "11:04",
            estimated: "On time",
            platform: "3"
        )
        let delayed = callingPoint(
            name: "East Croydon",
            crs: "ECR",
            scheduled: "11:04",
            estimated: "11:06"
        )

        let onTimePresentation = RailwayStationInfoPresentation(station: onTime)
        #expect(onTimePresentation.timingText == "Expected 11:04 (on time)")
        #expect(onTimePresentation.platformText == "Expected platform: 3")

        let delayedPresentation = RailwayStationInfoPresentation(station: delayed)
        #expect(
            delayedPresentation.timingText
                == "Expected 11:06 (originally scheduled 11:04)"
        )
        #expect(delayedPresentation.platformText == "Expected platform: Not available")
    }

    @Test @MainActor func stationAnnotationsRenderAboveEstimatedTrain() async throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 51.375, longitude: 0.099),
            CLLocationCoordinate2D(latitude: 51.366, longitude: 0.089),
        ]
        let route = ServiceRailwayRoute(
            coordinates: coordinates,
            cumulativeDistances: [0, 1_000],
            stationCoordinateIndices: [0, 1]
        )
        let map = ServiceRailwayMapView(
            route: route,
            stations: [
                callingPoint(name: "Orpington", crs: "ORP", scheduled: "09:23"),
                callingPoint(name: "Petts Wood", crs: "PET", scheduled: "09:27"),
            ],
            progress: .unavailable,
            estimatedTrainCoordinate: coordinates[0],
            currentDelayMinutes: 3,
            fromCRS: "ORP",
            toCRS: "PET"
        )
        let host = UIHostingController(rootView: map)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(1))

        let mapView = try #require(firstDescendant(of: MKMapView.self, in: host.view))
        let trainAnnotation = try #require(mapView.annotations.first {
            ($0.title ?? nil) == "railway-estimated-train"
        })
        let stationAnnotation = try #require(mapView.annotations.first {
            ($0.title ?? nil)?.hasPrefix("railway-station-") == true
        })
        let trainView = try #require(mapView.view(for: trainAnnotation))
        let stationView = try #require(mapView.view(for: stationAnnotation))

        #expect(stationView.zPriority.rawValue > trainView.zPriority.rawValue)
        #expect(
            stationView.selectedZPriority.rawValue > trainView.selectedZPriority.rawValue
        )
    }

    @Test func finalCurrentStationUsesArrivalFields() throws {
        let details = ServiceDetails(
            previousCallingPoints: nil,
            subsequentCallingPoints: nil,
            generatedAt: "2026-08-16T01:00:00Z",
            serviceType: "train",
            locationName: "Brighton",
            crs: "BTN",
            operator: "Thameslink",
            operatorCode: "TL",
            isCancelled: false,
            length: 12,
            detachFront: false,
            isReverseFormation: false,
            platform: "3",
            sta: "11:04",
            eta: "11:06",
            ata: nil,
            std: nil,
            etd: nil,
            atd: nil,
            delayReason: nil,
            cancelReason: nil
        )

        let station = try #require(details.allStations.last)
        #expect(station.st == "11:04")
        #expect(station.et == "11:06")
        #expect(station.platform == "3")
    }

    @Test func dividingServiceKeepsEachDestinationAsAnIndependentBranch() {
        let details = ServiceDetails(
            previousCallingPoints: [CallingPointList(
                callingPoint: [
                    callingPoint(name: "London Victoria", crs: "VIC", scheduled: "13:15"),
                    callingPoint(name: "East Croydon", crs: "ECR", scheduled: "13:32"),
                ],
                serviceType: nil,
                serviceChangeRequired: nil,
                assocIsCancelled: nil
            )],
            subsequentCallingPoints: [
                CallingPointList(
                    callingPoint: [
                        callingPoint(name: "Ford", crs: "FOD", scheduled: "15:04"),
                        callingPoint(name: "Portsmouth Harbour", crs: "PMH", scheduled: "15:47"),
                    ],
                    serviceType: nil,
                    serviceChangeRequired: nil,
                    assocIsCancelled: nil
                ),
                CallingPointList(
                    callingPoint: [
                        callingPoint(name: "West Worthing", crs: "WWO", scheduled: "14:55"),
                        callingPoint(name: "Littlehampton", crs: "LIT", scheduled: "15:13"),
                    ],
                    serviceType: nil,
                    serviceChangeRequired: nil,
                    assocIsCancelled: nil
                ),
            ],
            generatedAt: "2026-08-16T13:00:00Z",
            serviceType: "train",
            locationName: "Worthing",
            crs: "WRH",
            operator: "Southern",
            operatorCode: "SN",
            isCancelled: false,
            length: 12,
            detachFront: false,
            isReverseFormation: false,
            platform: "3",
            sta: "14:46",
            eta: "14:46",
            ata: nil,
            std: "14:47",
            etd: "14:47",
            atd: nil,
            delayReason: nil,
            cancelReason: nil
        )

        #expect(details.stationBranches.map { $0.map(\.crs) } == [
            ["VIC", "ECR", "WRH", "FOD", "PMH"],
            ["VIC", "ECR", "WRH", "WWO", "LIT"],
        ])
        #expect(details.allStations.map(\.crs) == ["VIC", "ECR", "WRH", "FOD", "PMH"])
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
        name: String? = nil,
        crs: String,
        scheduled: String,
        estimated: String? = "On time",
        actual: String? = nil,
        platform: String? = nil
    ) -> CallingPoint {
        CallingPoint(
            locationName: name ?? crs,
            crs: crs,
            st: scheduled,
            et: estimated,
            at: actual,
            isCancelled: false,
            cancelReason: nil,
            platform: platform,
            length: nil,
            detachFront: nil,
            affectedByDiversion: false,
            rerouteDelay: 0
        )
    }

    private func firstDescendant<ViewType: UIView>(
        of type: ViewType.Type,
        in view: UIView
    ) -> ViewType? {
        if let match = view as? ViewType {
            return match
        }
        for subview in view.subviews {
            if let match = firstDescendant(of: type, in: subview) {
                return match
            }
        }
        return nil
    }
}
