import Foundation
import CoreLocation
import MapKit
import SwiftUI
import Testing
@testable import TrainTrack_UK

struct RailwayRoutingTests {
    @Test func preparingTheRailwayGraphIsIdempotent() async throws {
        try await RailwayRoutingService.shared.prepare()
        try await RailwayRoutingService.shared.prepare()

        let route = try await RailwayRoutingService.shared.route(forStationCRSs: [
            "KTH", "PNE", "SYH", "WDU", "HNH", "BRX", "VIC"
        ])

        #expect(route.stationCount == 7)
        #expect((12_000...13_000).contains(route.totalLength))
    }

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

    @Test func historicalMapHighlightsOnlySegmentsWithinTheTravelledStationRange() {
        #expect(RailwayTravelHighlight.segmentIndices(for: 2...5) == Set([2, 3, 4]))
        #expect(RailwayTravelHighlight.segmentIndices(for: nil) == nil)
    }

    @Test func stationLabelCollisionDetectionUsesScreenGeometry() {
        let visibleBounds = CGRect(x: 0, y: 0, width: 390, height: 700)
        let denseLabels = [
            CGRect(x: 80, y: 100, width: 160, height: 40),
            CGRect(x: 150, y: 110, width: 160, height: 40),
        ]
        let slightlyOverlappingLabels = [
            CGRect(x: 80, y: 100, width: 160, height: 40),
            CGRect(x: 220, y: 100, width: 160, height: 40),
        ]
        let spacedLabels = [
            CGRect(x: 20, y: 100, width: 130, height: 40),
            CGRect(x: 240, y: 500, width: 130, height: 40),
        ]
        let offscreenStationLabels = [
            CGRect(x: -100, y: 100, width: 160, height: 40),
            CGRect(x: -80, y: 110, width: 160, height: 40),
        ]

        #expect(RailwayStationLabelCollisionDetector.hasOverlap(
            labelFrames: denseLabels,
            visibleBounds: visibleBounds
        ))
        #expect(!RailwayStationLabelCollisionDetector.hasOverlap(
            labelFrames: slightlyOverlappingLabels,
            visibleBounds: visibleBounds
        ))
        #expect(!RailwayStationLabelCollisionDetector.hasOverlap(
            labelFrames: spacedLabels,
            visibleBounds: visibleBounds
        ))
        #expect(!RailwayStationLabelCollisionDetector.hasOverlap(
            labelFrames: offscreenStationLabels,
            visibleBounds: visibleBounds
        ))
    }

    @Test func eachLegRetainsServiceEndpointsAndUserDepartureLabel() {
        #expect(RailwayStationLabelPriority.shouldRemainVisible(
            stationIndex: 0,
            finalStationIndex: 8,
            stationCRS: "VIC",
            userDepartureCRS: "KTH"
        ))
        #expect(RailwayStationLabelPriority.shouldRemainVisible(
            stationIndex: 3,
            finalStationIndex: 8,
            stationCRS: " kth ",
            userDepartureCRS: "KTH"
        ))
        #expect(RailwayStationLabelPriority.shouldRemainVisible(
            stationIndex: 8,
            finalStationIndex: 8,
            stationCRS: "ORP",
            userDepartureCRS: "KTH"
        ))
        #expect(!RailwayStationLabelPriority.shouldRemainVisible(
            stationIndex: 2,
            finalStationIndex: 8,
            stationCRS: "PNE",
            userDepartureCRS: "KTH"
        ))
    }

    @Test func journeyMapLegFindsItsTravelledRangeWithinTheFullService() {
        let leg = JourneyHistoryRouteMapLeg(
            id: UUID(),
            stations: [
                callingPoint(crs: "AAA", scheduled: "12:00"),
                callingPoint(crs: "BBB", scheduled: "12:10"),
                callingPoint(crs: "CCC", scheduled: "12:20"),
                callingPoint(crs: "DDD", scheduled: "12:30"),
            ],
            fromCRS: " bbb ",
            toCRS: "CCC",
            historicalDepartureTime: "12:10",
            historicalArrivalTime: "12:20"
        )

        #expect(leg.highlightedTravelRange == 1...2)
    }

    @Test @MainActor func routeMapShareRendererIncludesAttributionFooter() throws {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        view.backgroundColor = .systemBlue

        let image = try #require(RailwayMapShareRenderer.image(for: view))

        #expect(image.size.width == 320)
        #expect(image.size.height == 480 + RailwayMapShareRenderer.attributionFooterHeight)
        #expect(image.scale <= RailwayMapShareRenderer.maximumRenderScale)
    }

    @Test @MainActor func historicalMapUsesCompletedServiceSemanticsAfterTheUserDestination() {
        #expect(RailwayHistoricalStationSemantics.eventKind(
            stationIndex: 4,
            userDestinationIndex: 5,
            finalStationIndex: 9
        ) == nil)
        #expect(RailwayHistoricalStationSemantics.eventKind(
            stationIndex: 5,
            userDestinationIndex: 5,
            finalStationIndex: 9
        ) == .arrived)
        #expect(RailwayHistoricalStationSemantics.eventKind(
            stationIndex: 6,
            userDestinationIndex: 5,
            finalStationIndex: 9
        ) == .departed)
        #expect(RailwayHistoricalStationSemantics.eventKind(
            stationIndex: 9,
            userDestinationIndex: 5,
            finalStationIndex: 9
        ) == .arrived)
    }

    @Test @MainActor func mapLabelsKeepDueForUpcomingCallsAndOmitDepartedForPassedCalls() {
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
        let delayed = callingPoint(
            name: "London Victoria",
            crs: "VIC",
            scheduled: "08:12",
            estimated: "Delayed"
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
            RailwayStationAnnotationLabel.text(for: departedOnTime, hasDeparted: true)
                == "Orpington (08:20, on time)"
        )
        #expect(
            RailwayStationAnnotationLabel.text(for: departedLate, hasDeparted: true)
                == "Orpington (08:21, 1 min late)"
        )
        #expect(
            RailwayStationAnnotationLabel.text(for: departedOnTime)
                == "Orpington (due 08:20, on time)"
        )
        #expect(
            RailwayStationAnnotationLabel.text(for: delayed)
                == "London Victoria (due time unavailable, delayed)"
        )
        #expect(
            RailwayStationAnnotationLabel.text(for: delayed, hasDeparted: true)
                == "London Victoria (time unavailable, delayed)"
        )
        #expect(
            RailwayStationAnnotationLabel.text(
                for: onTime,
                historicalEvent: RailwayHistoricalStationEvent(kind: .arrived, time: "01:47")
            ) == "East Croydon (arrived 01:47, on time)"
        )
        #expect(
            RailwayStationAnnotationLabel.text(
                for: onTime,
                historicalEvent: RailwayHistoricalStationEvent(kind: .departed, time: "01:47")
            ) == "East Croydon (01:47, on time)"
        )
        #expect(
            RailwayEstimatedLocationLabel.text(delayMinutes: 26)
                == "Estimated location (26 mins late)"
        )
    }

    @Test func interchangeAnnotationCombinesArrivalChangeAndDeparture() {
        #expect(
            RailwayStationTransferLabel.text(
                stationName: "Herne Hill",
                arrivalTime: "02:21",
                departureTime: "02:27"
            ) == "Herne Hill (arrived 02:21, 6 minute change, departed 02:27)"
        )
        #expect(
            RailwayStationTransferLabel.text(
                stationName: "York",
                arrivalTime: "23:58",
                departureTime: "00:06"
            ) == "York (arrived 23:58, 8 minute change, departed 00:06)"
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

        let arrivalPresentation = RailwayStationInfoPresentation(
            station: onTime,
            historicalEvent: RailwayHistoricalStationEvent(kind: .arrived, time: "11:04")
        )
        #expect(arrivalPresentation.timingText == "Arrived 11:04 (on time)")
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
        #expect(
            trainView.zPriority.rawValue
                > RailwayMapAnnotationPriority.userLocation.rawValue
        )
    }

    @Test func onboardLocationOverridesAReasonablyDivergentAPIEstimate() throws {
        let now = Date()
        let userLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 51.4534, longitude: -0.1026),
            altitude: 0,
            horizontalAccuracy: 25,
            verticalAccuracy: -1,
            timestamp: now
        )
        let coordinate = try #require(RailwayOnboardLocationResolver.coordinate(
            apiCoordinate: CLLocationCoordinate2D(latitude: 51.4664, longitude: -0.1024),
            userLocation: userLocation,
            routeCoordinates: [
                CLLocationCoordinate2D(latitude: 51.4530, longitude: -0.1028),
                CLLocationCoordinate2D(latitude: 51.4668, longitude: -0.1023),
            ],
            now: now
        ))

        #expect(coordinate.latitude == userLocation.coordinate.latitude)
        #expect(coordinate.longitude == userLocation.coordinate.longitude)
    }

    @Test func onboardLocationDoesNotOverrideStronglyDivergentAPIData() throws {
        let now = Date()
        let apiCoordinate = CLLocationCoordinate2D(latitude: 51.60, longitude: -0.10)
        let userLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 51.4534, longitude: -0.1026),
            altitude: 0,
            horizontalAccuracy: 25,
            verticalAccuracy: -1,
            timestamp: now
        )
        let coordinate = try #require(RailwayOnboardLocationResolver.coordinate(
            apiCoordinate: apiCoordinate,
            userLocation: userLocation,
            routeCoordinates: [
                CLLocationCoordinate2D(latitude: 51.4530, longitude: -0.1028),
                CLLocationCoordinate2D(latitude: 51.6000, longitude: -0.1000),
            ],
            now: now
        ))

        #expect(coordinate.latitude == apiCoordinate.latitude)
        #expect(coordinate.longitude == apiCoordinate.longitude)
    }

    @Test @MainActor func denseMapCollapsesOnlySecondaryStationLabels() async throws {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 51.50, longitude: -0.20),
            CLLocationCoordinate2D(latitude: 51.50, longitude: -0.001),
            CLLocationCoordinate2D(latitude: 51.50, longitude: 0.001),
            CLLocationCoordinate2D(latitude: 51.50, longitude: 0.20),
        ]
        let route = ServiceRailwayRoute(
            coordinates: coordinates,
            cumulativeDistances: [0, 10_000, 10_100, 20_000],
            stationCoordinateIndices: [0, 1, 2, 3]
        )
        let map = ServiceRailwayMapView(
            route: route,
            stations: [
                callingPoint(name: "Service Starting Station", crs: "AAA", scheduled: "09:00"),
                callingPoint(name: "User Departure Station", crs: "BBB", scheduled: "09:10"),
                callingPoint(name: "Closely Spaced Intermediate", crs: "CCC", scheduled: "09:11"),
                callingPoint(name: "Service Final Destination", crs: "DDD", scheduled: "09:30"),
            ],
            progress: .unavailable,
            estimatedTrainCoordinate: nil,
            currentDelayMinutes: nil,
            fromCRS: "BBB",
            toCRS: "CCC"
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
        host.view.layoutIfNeeded()

        let mapView = try #require(firstDescendant(of: MKMapView.self, in: host.view))
        let departureAnnotation = try #require(mapView.annotations.first {
            ($0.title ?? nil) == "railway-station-primary-1-BBB"
        })
        let secondaryAnnotation = try #require(mapView.annotations.first {
            ($0.title ?? nil) == "railway-station-primary-2-CCC"
        })
        let departureView = try #require(mapView.view(for: departureAnnotation))
        let secondaryView = try #require(mapView.view(for: secondaryAnnotation))

        #expect(departureView.bounds.width > secondaryView.bounds.width)
        #expect(secondaryView.bounds.width < 60)
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

    @Test func liveStatusKeepsTrainAtStationUntilDepartureIsConfirmed() throws {
        let details = ServiceDetails(
            previousCallingPoints: [CallingPointList(
                callingPoint: [
                    callingPoint(
                        name: "Tulse Hill",
                        crs: "TUH",
                        scheduled: "20:20",
                        actual: "20:21"
                    )
                ],
                serviceType: nil,
                serviceChangeRequired: nil,
                assocIsCancelled: nil
            )],
            subsequentCallingPoints: [CallingPointList(
                callingPoint: [
                    callingPoint(
                        name: "Loughborough Junction",
                        crs: "LGJ",
                        scheduled: "20:31",
                        estimated: "20:33"
                    )
                ],
                serviceType: nil,
                serviceChangeRequired: nil,
                assocIsCancelled: nil
            )],
            generatedAt: "2026-08-23T19:28:00Z",
            serviceType: "train",
            locationName: "Herne Hill",
            crs: "HNH",
            operator: "Thameslink",
            operatorCode: "TL",
            isCancelled: false,
            length: 8,
            detachFront: false,
            isReverseFormation: false,
            platform: "1",
            sta: "20:26",
            eta: "20:28",
            ata: nil,
            std: "20:26",
            etd: "20:28",
            atd: nil,
            delayReason: nil,
            cancelReason: nil
        )
        let now = try #require(
            Calendar.current.date(bySettingHour: 20, minute: 28, second: 0, of: Date())
        )

        let status = try #require(
            computeLiveStatus(from: details, within: "HNH", toCRS: "LGJ", at: now)
        )

        #expect(status.text == "Currently 2 minutes late, at Herne Hill")
        #expect(status.delayMinutes == 2)
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
        #expect((0.42...0.44).contains(estimate.fraction))
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
        #expect((0.47...0.48).contains(estimate.fraction))
    }

    @Test func onTimeDepartureWaitsForTheTimetableSafetyInterval() {
        let stations = [
            callingPoint(crs: "HNH", scheduled: "17:37", actual: "On time"),
            callingPoint(crs: "WDU", scheduled: "17:39")
        ]
        let beforeSafetyInterval = ServiceProgressEstimator.estimate(
            for: stations,
            at: date(year: 2026, month: 8, day: 25, hour: 17, minute: 37, second: 29),
            calendar: calendar
        )
        let afterSafetyInterval = ServiceProgressEstimator.estimate(
            for: stations,
            at: date(year: 2026, month: 8, day: 25, hour: 17, minute: 37, second: 31),
            calendar: calendar
        )

        #expect(beforeSafetyInterval.previousStationIndex == 0)
        #expect(beforeSafetyInterval.nextStationIndex == 0)
        #expect(afterSafetyInterval.previousStationIndex == 0)
        #expect(afterSafetyInterval.nextStationIndex == 1)
        #expect(afterSafetyInterval.fraction > 0)
    }

    @Test func anEarlyPredictionCannotAdvanceTheMapAheadOfTheTimetable() {
        let estimate = ServiceProgressEstimator.estimate(
            for: [
                callingPoint(
                    crs: "HNH",
                    scheduled: "17:37",
                    estimated: "17:36",
                    actual: "On time"
                ),
                callingPoint(crs: "WDU", scheduled: "17:39")
            ],
            at: date(year: 2026, month: 8, day: 25, hour: 17, minute: 37, second: 20),
            calendar: calendar
        )

        #expect(estimate.previousStationIndex == 0)
        #expect(estimate.nextStationIndex == 0)
    }

    @Test func onboardGPSCannotPassAStationBeforeItsTimetableSafetyInterval() throws {
        let now = date(year: 2026, month: 8, day: 25, hour: 17, minute: 37, second: 20)
        let route = ServiceRailwayRoute(
            coordinates: [
                CLLocationCoordinate2D(latitude: 51.45, longitude: -0.11),
                CLLocationCoordinate2D(latitude: 51.45, longitude: -0.10),
                CLLocationCoordinate2D(latitude: 51.45, longitude: -0.09),
            ],
            cumulativeDistances: [0, 700, 1_400],
            stationCoordinateIndices: [0, 1, 2]
        )
        let userLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 51.45, longitude: -0.095),
            altitude: 0,
            horizontalAccuracy: 15,
            verticalAccuracy: -1,
            timestamp: now
        )
        let maximumIndex = ServiceProgressEstimator.maximumPermittedFloatingIndex(
            for: [
                callingPoint(crs: "BRX", scheduled: "17:34", actual: "On time"),
                callingPoint(crs: "HNH", scheduled: "17:37", actual: "On time"),
                callingPoint(crs: "WDU", scheduled: "17:39")
            ],
            at: now,
            calendar: calendar
        )
        let position = try #require(RailwayOnboardLocationResolver.position(
            apiCoordinate: route.coordinate(atStation: 1),
            userLocation: userLocation,
            route: route,
            maximumFloatingStationIndex: maximumIndex,
            now: now
        ))

        #expect(maximumIndex == 1)
        #expect(position.floatingStationIndex == 1)
        #expect(position.coordinate.longitude == route.coordinate(atStation: 1)?.longitude)
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

    @Test func unconfirmedDepartureDoesNotMoveTrainBeyondTheStation() {
        let now = date(year: 2026, month: 8, day: 15, hour: 20, minute: 28)
        let estimate = ServiceProgressEstimator.estimate(
            for: [
                callingPoint(crs: "HH", scheduled: "20:26", estimated: "20:28"),
                callingPoint(crs: "LJ", scheduled: "20:31", estimated: "20:33")
            ],
            at: now,
            calendar: calendar
        )

        #expect(estimate.previousStationIndex == 0)
        #expect(estimate.nextStationIndex == 0)
        #expect(estimate.fraction == 0)
    }

    @Test func stalePredictionsDoNotMoveTrainPastTheNextUnconfirmedStation() {
        let now = date(year: 2026, month: 8, day: 15, hour: 12, minute: 20)
        let estimate = ServiceProgressEstimator.estimate(
            for: [
                callingPoint(crs: "AAA", scheduled: "12:00", actual: "12:02"),
                callingPoint(crs: "BBB", scheduled: "12:10", estimated: "12:12"),
                callingPoint(crs: "CCC", scheduled: "12:18", estimated: "12:20")
            ],
            at: now,
            calendar: calendar
        )

        #expect(estimate.previousStationIndex == 1)
        #expect(estimate.nextStationIndex == 1)
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
        minute: Int,
        second: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
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
