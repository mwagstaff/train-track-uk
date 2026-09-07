import CoreLocation
import MapKit
import Testing
@testable import TrainTrack_UK

struct RailReplacementBusMapTests {
    @Test func schematicSegmentsUseOnlyOctolinearAngles() {
        let layout = RailReplacementSchematicLayout(coordinates: [
            CLLocationCoordinate2D(latitude: 51.50, longitude: -0.20),
            CLLocationCoordinate2D(latitude: 51.53, longitude: -0.16),
            CLLocationCoordinate2D(latitude: 51.55, longitude: -0.11),
            CLLocationCoordinate2D(latitude: 51.52, longitude: -0.07)
        ])

        #expect(layout.mapPoints.count == 4)
        for index in layout.routePoints.indices.dropLast() {
            let deltaX = abs(layout.routePoints[index + 1].x - layout.routePoints[index].x)
            let deltaY = abs(layout.routePoints[index + 1].y - layout.routePoints[index].y)
            let isAxisAligned = deltaX < 0.001 || deltaY < 0.001
            let isDiagonal = abs(deltaX - deltaY) < 0.001
            #expect(isAxisAligned || isDiagonal)
        }
    }

    @Test func stationsRetainExactLocationsAndAppearOnTheRouteInOrder() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 51.50, longitude: -0.20),
            CLLocationCoordinate2D(latitude: 51.52, longitude: -0.19),
            CLLocationCoordinate2D(latitude: 51.53, longitude: 0.30)
        ]
        let layout = RailReplacementSchematicLayout(coordinates: coordinates)
        var previousRouteIndex = -1
        for index in coordinates.indices {
            let actual = layout.mapPoints[index].coordinate
            #expect(abs(actual.latitude - coordinates[index].latitude) < 0.0000001)
            #expect(abs(actual.longitude - coordinates[index].longitude) < 0.0000001)
            let routeIndex = layout.routePoints.firstIndex {
                $0.x == layout.mapPoints[index].x && $0.y == layout.mapPoints[index].y
            } ?? -1
            #expect(routeIndex > previousRouteIndex)
            previousRouteIndex = routeIndex
        }
    }

    @Test func missingCoordinatesNeverCreateInventedStationLocations() {
        let layout = RailReplacementSchematicLayout(coordinates: [
            nil, CLLocationCoordinate2D(latitude: 51.5, longitude: -0.2),
            CLLocationCoordinate2D(latitude: 0, longitude: 0), nil,
            CLLocationCoordinate2D(latitude: 51.6, longitude: -0.1)
        ])
        #expect(layout.stationIndices == [1, 4])
        #expect(layout.mapPoints.count == 2)
        #expect(RailReplacementSchematicLayout(coordinates: [nil, nil]).mapPoints.isEmpty)
    }

    @Test func busTimingLabelsMatchTrainDueDelayCancellationAndArrivalLabels() {
        func stop(_ estimate: String?, actual: String? = nil) -> CallingPoint {
            CallingPoint(locationName: "London Bridge", crs: "LBG", st: "10:00",
                et: estimate, at: actual, isCancelled: nil, cancelReason: nil,
                platform: nil, length: nil, detachFront: nil, affectedByDiversion: nil, rerouteDelay: nil)
        }
        for estimate in ["On time", "10:07", "Delayed", "Cancelled"] {
            let station = stop(estimate)
            #expect(RailReplacementStationLabel.text(at: 0, stations: [station], progress: .unavailable)
                == RailwayStationAnnotationLabel.text(for: station))
        }
        let station = stop("10:07", actual: "10:08")
        #expect(RailReplacementStationLabel.text(
            at: 0, stations: [station], progress: .unavailable,
            historicalTravelRange: 0...0, historicalArrivalTime: "10:09"
        ) == "London Bridge (arrived 10:09, 9 mins late)")
    }

    @Test func labelSelectionDoesNotReturnOverlappingFrames() {
        let names = ["Alpha", "Bravo Central", "Charlie", "Delta Parkway", "Echo", "Foxtrot"]
        let coordinates = names.indices.map { index in
            CLLocationCoordinate2D(latitude: 51.50, longitude: -0.20 + (Double(index) * 0.01))
        }
        let layout = RailReplacementSchematicLayout(coordinates: coordinates)
        let viewport = CGSize(width: 390, height: 760)
        let visible = layout.visibleLabelIndices(
            names: names,
            in: layout.framedMapRect,
            viewportSize: viewport,
            priorityIndices: [1, 4]
        )
        let frames = visible.map {
            layout.labelFrame(
                at: $0,
                name: names[$0],
                visibleMapRect: layout.framedMapRect,
                viewportSize: viewport
            )
        }

        for firstIndex in frames.indices {
            for secondIndex in frames.indices where secondIndex > firstIndex {
                #expect(!frames[firstIndex].insetBy(dx: -4, dy: -3).intersects(frames[secondIndex]))
            }
        }
    }
}
