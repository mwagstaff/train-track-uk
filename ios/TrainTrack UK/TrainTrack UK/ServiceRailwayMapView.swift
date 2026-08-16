import SwiftUI
import MapKit

enum RailwayRouteSegmentStatus: Equatable {
    case onTime
    case minorDelay
    case majorDelayOrCancellation

    static func between(_ start: CallingPoint, and end: CallingPoint) -> Self {
        if start.isCancelledAtStation || end.isCancelledAtStation
            || hasUnknownDelay(start) || hasUnknownDelay(end) {
            return .majorDelayOrCancellation
        }
        let delay = max(delayMinutes(start), delayMinutes(end))
        if delay >= 5 { return .majorDelayOrCancellation }
        if delay > 0 { return .minorDelay }
        return .onTime
    }

    private static func hasUnknownDelay(_ station: CallingPoint) -> Bool {
        let actual = station.at?.trimmingCharacters(in: .whitespacesAndNewlines)
        let estimate = station.et?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let effectiveTime = actual?.isEmpty == false ? actual : estimate else { return false }
        let normalized = effectiveTime.lowercased()
        return normalized == "delayed" || normalized == "cancelled"
    }

    private static func delayMinutes(_ station: CallingPoint) -> Int {
        let actual = station.at?.trimmingCharacters(in: .whitespacesAndNewlines)
        let estimate = station.et?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTime = actual?.isEmpty == false ? actual : estimate
        return departureDelayMinutes(estimated: effectiveTime, scheduled: station.st) ?? 0
    }

    var color: Color {
        switch self {
        case .onTime: Color.accentColor
        case .minorDelay: .yellow
        case .majorDelayOrCancellation: .red
        }
    }
}

enum RailwayStationAnnotationLabel {
    static func text(for station: CallingPoint) -> String {
        if station.isCancelledAtStation {
            return "\(station.locationName) (cancelled)"
        }

        let scheduledTime = railwayClockTime(station.st) ?? station.st
        let actual = railwayClockTime(station.at)
        let normalizedActual = station.at?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let actual {
            let punctuality = punctualityText(time: actual, scheduled: scheduledTime)
            return "\(station.locationName) (departed \(actual), \(punctuality))"
        }
        if normalizedActual == "on time" {
            return "\(station.locationName) (departed \(scheduledTime), on time)"
        }

        let estimate = railwayClockTime(station.et)
        if station.et?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("Delayed") == .orderedSame {
            return "\(station.locationName) (due time unavailable, delayed)"
        }

        let dueTime = estimate ?? scheduledTime
        let punctuality = punctualityText(time: dueTime, scheduled: scheduledTime)
        return "\(station.locationName) (due \(dueTime), \(punctuality))"
    }

    private static func punctualityText(time: String, scheduled: String) -> String {
        let delay = departureDelayMinutes(estimated: time, scheduled: scheduled) ?? 0
        return delay > 0 ? "\(minuteText(delay)) late" : "on time"
    }

    private static func minuteText(_ minutes: Int) -> String {
        "\(minutes) min\(minutes == 1 ? "" : "s")"
    }
}

struct RailwayStationInfoPresentation: Equatable {
    let timingText: String
    let platformText: String

    init(station: CallingPoint) {
        let scheduledTime = railwayClockTime(station.st) ?? station.st
        let expectedTime = railwayClockTime(station.et)
        let normalizedEstimate = station.et?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if station.isCancelledAtStation {
            timingText = "Call cancelled (originally scheduled \(scheduledTime))"
        } else if normalizedEstimate == "on time" || expectedTime == scheduledTime {
            timingText = "Expected \(scheduledTime) (on time)"
        } else if let expectedTime {
            timingText = "Expected \(expectedTime) (originally scheduled \(scheduledTime))"
        } else if normalizedEstimate == "delayed" {
            timingText = "Expected time unavailable (originally scheduled \(scheduledTime))"
        } else {
            timingText = "Expected \(scheduledTime) (no live estimate)"
        }

        let platform = station.platform?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let platform, !platform.isEmpty {
            platformText = "Expected platform: \(platform)"
        } else {
            platformText = "Expected platform: Not available"
        }
    }
}

enum RailwayEstimatedLocationLabel {
    static func text(delayMinutes: Int?) -> String {
        guard let delayMinutes, delayMinutes > 0 else {
            return "Estimated location"
        }
        return "Estimated location (\(delayMinutes) min\(delayMinutes == 1 ? "" : "s") late)"
    }
}

private func railwayClockTime(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = trimmed.split(separator: ":")
    guard components.count == 2,
          let hour = Int(components[0]),
          let minute = Int(components[1]),
          (0..<24).contains(hour),
          (0..<60).contains(minute) else {
        return nil
    }
    return String(format: "%02d:%02d", hour, minute)
}

private struct RailwayMapSegment: Identifiable {
    let id: Int
    let coordinates: [CLLocationCoordinate2D]
    let status: RailwayRouteSegmentStatus
}

private enum RailwayMapAnnotationIdentifier {
    static let estimatedTrain = "railway-estimated-train"

    static func station(_ index: Int) -> String {
        "railway-station-\(index)"
    }
}

private struct RailwayMapAnnotationZOrderConfigurator: UIViewRepresentable {
    func makeUIView(context: Context) -> RailwayMapAnnotationZOrderView {
        RailwayMapAnnotationZOrderView()
    }

    func updateUIView(_ uiView: RailwayMapAnnotationZOrderView, context: Context) {
        uiView.refreshAnnotationPriorities()
    }
}

private final class RailwayMapAnnotationZOrderView: UIView {
    private weak var mapView: MKMapView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshAnnotationPriorities()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        refreshAnnotationPriorities()
    }

    func refreshAnnotationPriorities() {
        NSObject.cancelPreviousPerformRequests(
            withTarget: self,
            selector: #selector(applyAnnotationPriorities),
            object: nil
        )
        perform(#selector(applyAnnotationPriorities), with: nil, afterDelay: 0)
        perform(#selector(applyAnnotationPriorities), with: nil, afterDelay: 0.1)
        perform(#selector(applyAnnotationPriorities), with: nil, afterDelay: 0.5)
    }

    @objc private func applyAnnotationPriorities() {
        guard let mapView = mapView ?? enclosingMapView() else { return }
        self.mapView = mapView

        for annotation in mapView.annotations {
            guard let identifier = annotation.title ?? nil,
                  let annotationView = mapView.view(for: annotation) else { continue }

            if identifier.hasPrefix("railway-station-") {
                annotationView.zPriority = .max
                annotationView.selectedZPriority = .max
            } else if identifier == RailwayMapAnnotationIdentifier.estimatedTrain {
                annotationView.zPriority = .min
                annotationView.selectedZPriority = .min
            }
        }
    }

    private func enclosingMapView() -> MKMapView? {
        var ancestor = superview
        while let current = ancestor {
            if let mapView = current.firstDescendant(of: MKMapView.self) {
                return mapView
            }
            ancestor = current.superview
        }
        return nil
    }
}

private extension UIView {
    func firstDescendant<ViewType: UIView>(of type: ViewType.Type) -> ViewType? {
        if let match = self as? ViewType {
            return match
        }
        for subview in subviews {
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}

struct ServiceRailwayMapView: View {
    let route: ServiceRailwayRoute
    let stations: [CallingPoint]
    let progress: ServiceProgressEstimate
    let estimatedTrainCoordinate: CLLocationCoordinate2D?
    let currentDelayMinutes: Int?
    let fromCRS: String
    let toCRS: String

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnTrain = false
    @State private var selectedStationIndex: Int?

    var body: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            MapPolyline(coordinates: route.coordinates)
                .stroke(.secondary.opacity(0.45), lineWidth: 8)

            ForEach(routeSegments) { segment in
                MapPolyline(coordinates: segment.coordinates)
                    .stroke(segment.status.color, lineWidth: 6)
            }

            if let trainCoordinate {
                Annotation(RailwayMapAnnotationIdentifier.estimatedTrain, coordinate: trainCoordinate) {
                    estimatedTrainMarker
                }
                .annotationTitles(.hidden)
                .tag("estimated-train")
            }

            ForEach(stations.indices, id: \.self) { index in
                if let coordinate = route.coordinate(atStation: index) {
                    Annotation(
                        RailwayMapAnnotationIdentifier.station(index),
                        coordinate: coordinate,
                        anchor: .bottom
                    ) {
                        stationAnnotation(for: index)
                    }
                    .annotationTitles(.hidden)
                    .tag("station-\(index)-\(stations[index].crs)")
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .background(RailwayMapAnnotationZOrderConfigurator())
        .overlay(alignment: .topTrailing) {
            Button {
                centerOnTrainOrFrameRoute()
            } label: {
                Label("Center on train", systemImage: "scope")
                    .labelStyle(.iconOnly)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .background(.regularMaterial, in: Circle())
            .padding(12)
            .accessibilityLabel("Center on estimated train location")
        }
        .overlay(alignment: .bottomTrailing) {
            Link(
                "Rail data © OpenStreetMap contributors",
                destination: URL(string: "https://www.openstreetmap.org/copyright")!
            )
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
            .accessibilityLabel("OpenStreetMap railway data attribution")
        }
        .onAppear {
            centerOnTrainOrFrameRoute()
        }
        .onChange(of: trainCoordinateKey) { _, _ in
            guard !hasCenteredOnTrain, trainCoordinate != nil else { return }
            centerOnTrainOrFrameRoute()
        }
        .onChange(of: routeKey) { _, _ in
            hasCenteredOnTrain = false
            centerOnTrainOrFrameRoute()
        }
    }

    private var routeSegments: [RailwayMapSegment] {
        guard stations.count >= 2, route.stationCount == stations.count else { return [] }
        return stations.indices.dropLast().compactMap { index in
            let coordinates = route.coordinates(fromStation: index, throughStation: index + 1)
            guard coordinates.count >= 2 else { return nil }
            return RailwayMapSegment(
                id: index,
                coordinates: coordinates,
                status: .between(stations[index], and: stations[index + 1])
            )
        }
    }

    private var trainCoordinate: CLLocationCoordinate2D? {
        if let estimatedTrainCoordinate {
            return estimatedTrainCoordinate
        }
        guard progress.isAvailable else { return nil }
        return route.coordinate(
            fromStation: progress.previousStationIndex,
            toStation: progress.nextStationIndex,
            progress: progress.fraction
        )
    }

    private var trainCoordinateKey: String {
        guard let trainCoordinate else { return "unavailable" }
        return "\(trainCoordinate.latitude),\(trainCoordinate.longitude)"
    }

    private var routeKey: String {
        "\(route.coordinates.count):\(route.totalLength)"
    }

    private var estimatedLocationText: String {
        RailwayEstimatedLocationLabel.text(delayMinutes: currentDelayMinutes)
    }

    private var estimatedTrainMarker: some View {
        Image(systemName: "train.side.front.car")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.accentColor, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(estimatedLocationText)
    }

    private func stationAnnotation(for index: Int) -> some View {
        Button {
            selectedStationIndex = index
        } label: {
            VStack(spacing: 3) {
                Text(stationLabel(for: index))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stations[index].isCancelledAtStation ? Color.red : Color.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 180)
                    .strikethrough(
                        stations[index].isCancelledAtStation,
                        color: stations[index].isCancelledAtStation ? .red : nil
                    )
                    .shadow(color: .black.opacity(0.9), radius: 2)

                stationDot(for: index)
            }
            .padding(4)
            .contentShape(Rectangle())
            .offset(y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stationAccessibilityLabel(for: index))
        .accessibilityHint("Shows expected time and platform")
        .popover(
            isPresented: stationPopoverBinding(for: index),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            stationInfoPopover(for: index)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func stationPopoverBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedStationIndex == index },
            set: { isPresented in
                if isPresented {
                    selectedStationIndex = index
                } else if selectedStationIndex == index {
                    selectedStationIndex = nil
                }
            }
        )
    }

    private func stationInfoPopover(for index: Int) -> some View {
        let station = stations[index]
        let presentation = RailwayStationInfoPresentation(station: station)
        return VStack(alignment: .leading, spacing: 10) {
            Text(station.locationName)
                .font(.headline)
                .strikethrough(
                    station.isCancelledAtStation,
                    color: station.isCancelledAtStation ? .red : nil
                )
            Text(presentation.timingText)
            Text(presentation.platformText)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func stationDot(for index: Int) -> some View {
        if index == selectedOriginStationIndex {
            Circle()
                .fill(.orange)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        } else {
            let state = stationState(for: index)
            Circle()
                .fill(state.fill)
                .frame(width: state.isCurrent ? 16 : 12, height: state.isCurrent ? 16 : 12)
                .overlay(Circle().stroke(.black, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        }
    }

    private var selectedOriginStationIndex: Int? {
        let normalizedFrom = fromCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return stations.firstIndex {
            $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedFrom
        }
    }

    private var selectedDestinationStationIndex: Int? {
        let normalizedTo = toCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return stations.indices.first {
            $0 >= (selectedOriginStationIndex ?? 0)
                && stations[$0].crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    == normalizedTo
        }
    }

    private func stationState(for index: Int) -> (fill: Color, isCurrent: Bool) {
        let isCurrent = progress.isAvailable
            && progress.previousStationIndex == progress.nextStationIndex
            && index == progress.previousStationIndex
        return (.white, isCurrent)
    }

    private func stationAccessibilityLabel(for index: Int) -> String {
        let label = stationLabel(for: index)
        if index == selectedOriginStationIndex {
            return "\(label), selected journey origin"
        }
        if index == selectedDestinationStationIndex {
            return "\(label), selected journey destination"
        }
        let status: String
        if progress.isAvailable,
           progress.previousStationIndex == progress.nextStationIndex,
           index == progress.previousStationIndex {
            status = "current station"
        } else if progress.isAvailable && index <= progress.previousStationIndex {
            status = "completed"
        } else {
            status = "upcoming"
        }
        return "\(label), \(status)"
    }

    private func stationLabel(for index: Int) -> String {
        RailwayStationAnnotationLabel.text(for: stations[index])
    }

    private func centerOnTrainOrFrameRoute() {
        guard let trainCoordinate else {
            frameRoute()
            return
        }
        cameraPosition = .region(MKCoordinateRegion(
            center: trainCoordinate,
            latitudinalMeters: 4_500,
            longitudinalMeters: 4_500
        ))
        hasCenteredOnTrain = true
    }

    private func frameRoute() {
        guard route.coordinates.count >= 2 else { return }
        let polyline = MKPolyline(coordinates: route.coordinates, count: route.coordinates.count)
        let rect = polyline.boundingMapRect
        let horizontalPadding = max(rect.size.width * 0.12, 800)
        let verticalPadding = max(rect.size.height * 0.12, 800)
        cameraPosition = .rect(rect.insetBy(dx: -horizontalPadding, dy: -verticalPadding))
    }
}
