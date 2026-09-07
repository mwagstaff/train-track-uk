import MapKit
import SwiftUI

enum RailReplacementOctolinearDirection: Int, CaseIterable {
    case east
    case southEast
    case south
    case southWest
    case west
    case northWest
    case north
    case northEast

    var unitVector: CGVector {
        let diagonal = 1 / sqrt(2.0)
        return switch self {
        case .east: CGVector(dx: 1, dy: 0)
        case .southEast: CGVector(dx: diagonal, dy: diagonal)
        case .south: CGVector(dx: 0, dy: 1)
        case .southWest: CGVector(dx: -diagonal, dy: diagonal)
        case .west: CGVector(dx: -1, dy: 0)
        case .northWest: CGVector(dx: -diagonal, dy: -diagonal)
        case .north: CGVector(dx: 0, dy: -1)
        case .northEast: CGVector(dx: diagonal, dy: -diagonal)
        }
    }

    static func nearest(deltaX: Double, deltaY: Double, fallback: Self = .east) -> Self {
        guard abs(deltaX) + abs(deltaY) > 0.000_001 else { return fallback }
        let octant = Int((atan2(deltaY, deltaX) / (.pi / 4)).rounded())
        let normalized = ((octant % allCases.count) + allCases.count) % allCases.count
        return allCases[normalized]
    }
}

struct RailReplacementSchematicLayout {
    private let stationCount: Int
    let stationIndices: [Int]
    let mapPoints: [MKMapPoint]
    let routePoints: [MKMapPoint]
    let segmentDirections: [RailReplacementOctolinearDirection]
    let labelOffsets: [CGSize]
    let framedMapRect: MKMapRect

    init(coordinates: [CLLocationCoordinate2D?]) {
        stationCount = coordinates.count
        let indices = coordinates.indices.filter { index in
            guard let coordinate = coordinates[index],
                  CLLocationCoordinate2DIsValid(coordinate),
                  coordinate.latitude != 0 || coordinate.longitude != 0 else {
                return false
            }
            return true
        }
        let points = indices.compactMap { coordinates[$0].map(MKMapPoint.init) }
        var route = Array(points.prefix(1))
        for index in points.indices.dropLast() {
            // A diagonal plus an axis-aligned leg keeps both station anchors exact.
            let start = points[index]
            let end = points[index + 1]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let diagonal = min(abs(dx), abs(dy))
            if diagonal > 0, abs(abs(dx) - abs(dy)) > 0.001 {
                route.append(MKMapPoint(
                    x: start.x + (dx < 0 ? -diagonal : diagonal),
                    y: start.y + (dy < 0 ? -diagonal : diagonal)
                ))
            }
            route.append(end)
        }
        stationIndices = indices
        mapPoints = points
        routePoints = route
        segmentDirections = route.indices.dropLast().map { index in
            .nearest(deltaX: route[index + 1].x - route[index].x,
                     deltaY: route[index + 1].y - route[index].y)
        }
        labelOffsets = points.indices.map { index in
            Self.labelOffset(at: index, points: points)
        }
        let distances = points.indices.dropLast().map { index in
            hypot(points[index + 1].x - points[index].x, points[index + 1].y - points[index].y)
        }.sorted()
        framedMapRect = Self.framedMapRect(
            for: points,
            baseStep: max(distances.isEmpty ? 2_000 : distances[distances.count / 2], 1_000)
        )
    }

    func visibleLabelIndices(
        names: [String],
        in visibleMapRect: MKMapRect,
        viewportSize: CGSize,
        priorityIndices: Set<Int>
    ) -> Set<Int> {
        guard mapPoints.count == names.count,
              labelOffsets.count == names.count,
              visibleMapRect.width > 0,
              visibleMapRect.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return []
        }

        let terminalIndices = Set(stationIndices.indices.filter {
            stationIndices[$0] == 0 || stationIndices[$0] == stationCount - 1
        })
        let candidates = Array(priorityIndices.subtracting(terminalIndices).sorted())
            + mapPoints.indices.filter {
                !priorityIndices.contains($0) && !terminalIndices.contains($0)
            }
        let viewport = CGRect(origin: .zero, size: viewportSize).insetBy(dx: 4, dy: 4)
        var acceptedFrames: [CGRect] = []
        var visible: Set<Int> = []

        for index in candidates {
            let frame = labelFrame(
                at: index,
                name: names[index],
                visibleMapRect: visibleMapRect,
                viewportSize: viewportSize
            )
            guard viewport.intersects(frame),
                  !acceptedFrames.contains(where: { $0.insetBy(dx: -4, dy: -3).intersects(frame) }) else {
                continue
            }
            visible.insert(index)
            acceptedFrames.append(frame)
        }
        return visible
    }

    func labelFrame(
        at index: Int,
        name: String,
        visibleMapRect: MKMapRect,
        viewportSize: CGSize
    ) -> CGRect {
        let mapPoint = mapPoints[index]
        let screenPoint = CGPoint(
            x: ((mapPoint.x - visibleMapRect.minX) / visibleMapRect.width) * viewportSize.width,
            y: ((mapPoint.y - visibleMapRect.minY) / visibleMapRect.height) * viewportSize.height
        )
        let width: CGFloat = 164
        let preferredFont = UIFont.preferredFont(forTextStyle: .caption2)
        let font = UIFont.systemFont(ofSize: preferredFont.pointSize, weight: .semibold)
        let measured = (name as NSString).boundingRect(
            with: CGSize(width: width - 12, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil
        )
        let height = ceil(measured.height) + 10
        let offset = labelOffset(at: index, visibleMapRect: visibleMapRect, viewportSize: viewportSize)
        let centre = CGPoint(x: screenPoint.x + offset.width, y: screenPoint.y + offset.height)
        return CGRect(
            x: centre.x - (width / 2),
            y: centre.y - (height / 2),
            width: width,
            height: height
        )
    }

    func labelOffset(at index: Int, visibleMapRect: MKMapRect, viewportSize: CGSize) -> CGSize {
        guard visibleMapRect.width > 0 else { return labelOffsets[index] }
        let screenX = ((mapPoints[index].x - visibleMapRect.minX) / visibleMapRect.width) * viewportSize.width
        let margin: CGFloat = 86
        let labelX = min(max(screenX + labelOffsets[index].width, margin), max(margin, viewportSize.width - margin))
        return CGSize(width: labelX - screenX, height: labelOffsets[index].height)
    }

    var identifierCoordinates: [CLLocationCoordinate2D] {
        let segmentIndices: [Int]
        switch mapPoints.count {
        case 18...:
            segmentIndices = [mapPoints.count / 3, (mapPoints.count * 2) / 3]
        case 9...:
            segmentIndices = [mapPoints.count / 2]
        default:
            segmentIndices = []
        }
        return segmentIndices.compactMap { upperIndex in
            guard mapPoints.indices.contains(upperIndex), upperIndex > 0 else { return nil }
            let lower = mapPoints[upperIndex - 1]
            let upper = mapPoints[upperIndex]
            let diagonal = min(abs(upper.x - lower.x), abs(upper.y - lower.y))
            let corner = MKMapPoint(
                x: lower.x + (upper.x < lower.x ? -diagonal : diagonal),
                y: lower.y + (upper.y < lower.y ? -diagonal : diagonal)
            )
            let diagonalLength = hypot(corner.x - lower.x, corner.y - lower.y)
            let axisLength = hypot(upper.x - corner.x, upper.y - corner.y)
            let start = diagonalLength > axisLength ? lower : corner
            let end = diagonalLength > axisLength ? corner : upper
            return MKMapPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2).coordinate
        }
    }

    func terminusBadgeOffset(isStart: Bool, visibleMapRect: MKMapRect, viewportSize: CGSize) -> CGSize {
        guard let direction = isStart ? segmentDirections.first : segmentDirections.last else {
            return CGSize(width: 0, height: isStart ? -52 : 52)
        }
        let vector = direction.unitVector
        let sign: CGFloat = isStart ? -1 : 1
        let horizontalDistance: CGFloat = abs(vector.dx) > 0.1 ? 86 : 0
        let verticalDistance: CGFloat = abs(vector.dy) > 0.1 ? 58 : 0
        let point = isStart ? mapPoints[0] : mapPoints[mapPoints.count - 1]
        let screenX = ((point.x - visibleMapRect.minX) / max(visibleMapRect.width, 1)) * viewportSize.width
        let margin: CGFloat = 112
        let badgeX = min(max(screenX + vector.dx * horizontalDistance * sign, margin),
                         max(margin, viewportSize.width - margin))
        return CGSize(
            width: badgeX - screenX,
            height: vector.dy * verticalDistance * sign
        )
    }

    private static func labelOffset(at index: Int, points: [MKMapPoint]) -> CGSize {
        guard points.count >= 2 else { return CGSize(width: 0, height: -36) }
        let previous = points[max(index - 1, 0)]
        let next = points[min(index + 1, points.count - 1)]
        let deltaX = next.x - previous.x
        let deltaY = next.y - previous.y
        let length = max(hypot(deltaX, deltaY), 1)
        let normalX = -deltaY / length
        let normalY = deltaX / length
        let side: Double = index.isMultiple(of: 2) ? 1 : -1
        let distance = 42 + (abs(normalX) * 58)
        return CGSize(
            width: normalX * distance * side,
            height: normalY * distance * side
        )
    }

    private static func framedMapRect(for points: [MKMapPoint], baseStep: Double) -> MKMapRect {
        var rect = MKMapRect.null
        for point in points {
            rect = rect.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        guard !rect.isNull else {
            return MKMapRect(x: 0, y: 0, width: 1, height: 1)
        }
        let horizontalPadding = max(rect.width * 0.18, baseStep * 1.7)
        let verticalPadding = max(rect.height * 0.18, baseStep * 1.7)
        return rect.insetBy(dx: -horizontalPadding, dy: -verticalPadding)
    }
}

enum RailReplacementStationLabel {
    static func text(
        at index: Int,
        stations: [CallingPoint],
        progress: ServiceProgressEstimate,
        historicalTravelRange: ClosedRange<Int>? = nil,
        historicalArrivalTime: String? = nil
    ) -> String {
        let station = stations[index]
        var historicalEvent: RailwayHistoricalStationEvent?
        if let range = historicalTravelRange,
           let kind = RailwayHistoricalStationSemantics.eventKind(
               stationIndex: index, userDestinationIndex: range.upperBound,
               finalStationIndex: stations.count - 1
           ) {
            let recordedTime = railwayClockTime(station.at)
                ?? (station.at?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("On time") == .orderedSame ? station.st : nil)
                ?? railwayClockTime(station.et) ?? station.st
            historicalEvent = RailwayHistoricalStationEvent(
                kind: kind,
                time: index == range.upperBound ? historicalArrivalTime ?? recordedTime : recordedTime
            )
        }
        let actual = station.at?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasActual = actual?.isEmpty == false
            && actual?.caseInsensitiveCompare("Cancelled") != .orderedSame
        let hasDeparted = historicalTravelRange == nil
            && (hasActual || (progress.isAvailable && progress.floatingIndex > Double(index) + 0.001))
            && ServiceProgressEstimator.isDeparturePermitted(at: index, in: stations)
        return RailwayStationAnnotationLabel.text(
            for: station, historicalEvent: historicalEvent, hasDeparted: hasDeparted
        )
    }
}

private struct RailReplacementStopMarker: View {
    let timingLabel: String
    let stopNumber: Int
    let stopCount: Int
    let routeColor: Color
    let labelOffset: CGSize
    let showsLabel: Bool
    let isSelectedJourneyStop: Bool

    var body: some View {
        Circle()
            .fill(Color(.systemBackground))
            .frame(width: isSelectedJourneyStop ? 19 : 15, height: isSelectedJourneyStop ? 19 : 15)
            .overlay {
                Circle().stroke(routeColor, lineWidth: isSelectedJourneyStop ? 4 : 3)
            }
            .overlay {
                if isSelectedJourneyStop {
                    Circle()
                        .fill(routeColor)
                        .frame(width: 7, height: 7)
                }
            }
            .overlay {
                if showsLabel {
                    Text(timingLabel)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 152)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(routeColor.opacity(0.3), lineWidth: 1)
                        }
                        .offset(labelOffset)
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 2, y: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(timingLabel), replacement bus stop \(stopNumber) of \(stopCount)")
    }
}

private struct RailReplacementTerminusBadge: View {
    let serviceIdentifier: String
    let terminusName: String
    let timingLabel: String
    let destination: String
    let isDestination: Bool
    let routeColor: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(serviceIdentifier)
                .font(.caption.weight(.heavy))
                .fixedSize()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(routeColor, in: RoundedRectangle(cornerRadius: 3))

            VStack(alignment: .leading, spacing: 0) {
                Text(isDestination ? "destination" : "from \(terminusName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(timingLabel)
                    .font(.caption2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 152, alignment: .leading)
                if !isDestination {
                    Text("towards \(destination)")
                        .font(.caption2)
                }
            }
        }
        .padding(5)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 5))
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .stroke(routeColor, lineWidth: 1.5)
        }
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityHidden(true)
    }
}

private struct RailReplacementIdentifierBadge: View {
    let serviceIdentifier: String
    let routeColor: Color

    var body: some View {
        Text(serviceIdentifier)
            .font(.caption2.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(routeColor, in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(.white, lineWidth: 1.5)
            }
            .accessibilityHidden(true)
    }
}

struct RailReplacementBusMapView: View {
    private let stations: [CallingPoint]
    private let layout: RailReplacementSchematicLayout
    private let serviceIdentifier: String
    private let destinationName: String
    private let fromCRS: String
    private let toCRS: String
    private let showsChrome: Bool
    private let progress: ServiceProgressEstimate
    private let historicalTravelRange: ClosedRange<Int>?
    private let historicalArrivalTime: String?
    private let routeColor = Color(red: 0.88, green: 0.29, blue: 0.08)

    @State private var cameraPosition: MapCameraPosition
    @State private var visibleMapRect: MKMapRect?

    init(
        stations: [CallingPoint],
        stationCoordinates: [CLLocationCoordinate2D?],
        serviceIdentifier: String,
        destinationName: String,
        fromCRS: String,
        toCRS: String,
        showsChrome: Bool,
        progress: ServiceProgressEstimate = .unavailable,
        historicalTravelRange: ClosedRange<Int>? = nil,
        historicalArrivalTime: String? = nil
    ) {
        let layout = RailReplacementSchematicLayout(coordinates: stationCoordinates)
        self.stations = stations
        self.layout = layout
        self.serviceIdentifier = serviceIdentifier
        self.destinationName = destinationName
        self.fromCRS = fromCRS
        self.toCRS = toCRS
        self.showsChrome = showsChrome
        self.progress = progress
        self.historicalTravelRange = historicalTravelRange
        self.historicalArrivalTime = historicalArrivalTime
        _cameraPosition = State(initialValue: .rect(layout.framedMapRect))
    }

    var body: some View {
        GeometryReader { proxy in
            let labels = layout.stationIndices.map { stationLabel(at: $0) }
            let labelIndices = layout.visibleLabelIndices(
                names: labels,
                in: visibleMapRect ?? layout.framedMapRect,
                viewportSize: proxy.size,
                priorityIndices: selectedJourneyStopIndices
            )

            Map(
                position: $cameraPosition,
                interactionModes: showsChrome ? [.pan, .zoom] : []
            ) {
                if layout.routePoints.count >= 2 {
                    MapPolyline(points: layout.routePoints)
                        .stroke(
                            Color(.systemBackground).opacity(0.92),
                            style: StrokeStyle(lineWidth: 13, lineCap: .round, lineJoin: .round)
                        )
                    MapPolyline(points: layout.routePoints)
                        .stroke(
                            routeColor,
                            style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round)
                        )
                }

                ForEach(Array(layout.stationIndices.enumerated()), id: \.offset) { index, stationIndex in
                    Annotation(
                        stations[stationIndex].locationName,
                        coordinate: layout.mapPoints[index].coordinate,
                        anchor: .center
                    ) {
                        RailReplacementStopMarker(
                            timingLabel: labels[index],
                            stopNumber: stationIndex + 1,
                            stopCount: stations.count,
                            routeColor: routeColor,
                            labelOffset: layout.labelOffset(
                                at: index, visibleMapRect: visibleMapRect ?? layout.framedMapRect,
                                viewportSize: proxy.size
                            ),
                            showsLabel: labelIndices.contains(index),
                            isSelectedJourneyStop: isSelectedJourneyStop(stations[stationIndex])
                        )
                    }
                    .annotationTitles(.hidden)
                }

                ForEach(Array(layout.identifierCoordinates.enumerated()), id: \.offset) { _, coordinate in
                    Annotation(serviceIdentifier, coordinate: coordinate, anchor: .center) {
                        RailReplacementIdentifierBadge(
                            serviceIdentifier: serviceIdentifier,
                            routeColor: routeColor
                        )
                        .offset(y: -18)
                    }
                    .annotationTitles(.hidden)
                }

                if let firstPoint = layout.mapPoints.first, layout.stationIndices.first == 0 {
                    Annotation("Replacement bus origin", coordinate: firstPoint.coordinate, anchor: .center) {
                        RailReplacementTerminusBadge(
                            serviceIdentifier: serviceIdentifier,
                            terminusName: stations.first?.locationName ?? "Origin",
                            timingLabel: stationLabel(at: 0),
                            destination: destinationName,
                            isDestination: false,
                            routeColor: routeColor
                        )
                        .offset(layout.terminusBadgeOffset(
                            isStart: true, visibleMapRect: visibleMapRect ?? layout.framedMapRect,
                            viewportSize: proxy.size
                        ))
                    }
                    .annotationTitles(.hidden)
                }

                if let lastPoint = layout.mapPoints.last, layout.mapPoints.count > 1,
                   layout.stationIndices.last == stations.count - 1 {
                    Annotation("Replacement bus destination", coordinate: lastPoint.coordinate, anchor: .center) {
                        RailReplacementTerminusBadge(
                            serviceIdentifier: serviceIdentifier,
                            terminusName: stations.last?.locationName ?? destinationName,
                            timingLabel: stationLabel(at: stations.count - 1),
                            destination: destinationName,
                            isDestination: true,
                            routeColor: routeColor
                        )
                        .offset(layout.terminusBadgeOffset(
                            isStart: false, visibleMapRect: visibleMapRect ?? layout.framedMapRect,
                            viewportSize: proxy.size
                        ))
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(
                elevation: .flat,
                emphasis: .muted,
                pointsOfInterest: .excludingAll,
                showsTraffic: false
            ))
            .onMapCameraChange(frequency: .onEnd) { context in
                visibleMapRect = context.rect
            }
            .onChange(of: layout.mapPoints.map { "\($0.x),\($0.y)" }) { _, _ in
                cameraPosition = .rect(layout.framedMapRect)
            }
            .overlay {
                if layout.mapPoints.isEmpty {
                    ContentUnavailableView("Station locations unavailable", systemImage: "mappin.slash",
                        description: Text("Station coordinates are needed to display this bus route."))
                        .background(Color(.systemBackground))
                }
            }
            .overlay(alignment: .topLeading) {
                Text("Rail replacement bus - unable to show live location")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topTrailing) {
                if showsChrome {
                    Button {
                        cameraPosition = .rect(layout.framedMapRect)
                    } label: {
                        Label("Frame replacement bus route", systemImage: "scope")
                            .labelStyle(.iconOnly)
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .background(.regularMaterial, in: Circle())
                    .padding(12)
                    .accessibilityLabel("Frame complete replacement bus route")
                }
            }
        }
    }

    private var selectedJourneyStopIndices: Set<Int> {
        Set(layout.stationIndices.indices.filter { isSelectedJourneyStop(stations[layout.stationIndices[$0]]) })
    }

    private func stationLabel(at index: Int) -> String {
        RailReplacementStationLabel.text(
            at: index, stations: stations, progress: progress,
            historicalTravelRange: historicalTravelRange, historicalArrivalTime: historicalArrivalTime
        )
    }

    private func isSelectedJourneyStop(_ station: CallingPoint) -> Bool {
        let crs = station.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return crs == fromCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            || crs == toCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}
