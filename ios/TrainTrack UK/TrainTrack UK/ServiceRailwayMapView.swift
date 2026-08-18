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

nonisolated enum RailwayTravelHighlight {
    static func segmentIndices(for stationRange: ClosedRange<Int>?) -> Set<Int>? {
        stationRange.map { Set($0.lowerBound..<$0.upperBound) }
    }
}

struct RailwayHistoricalStationEvent: Equatable {
    enum Kind: Equatable {
        case departed
        case arrived
    }

    let kind: Kind
    let time: String
}

enum RailwayHistoricalStationSemantics {
    static func eventKind(
        stationIndex: Int,
        userDestinationIndex: Int,
        finalStationIndex: Int
    ) -> RailwayHistoricalStationEvent.Kind? {
        guard stationIndex >= userDestinationIndex else { return nil }
        if stationIndex == userDestinationIndex || stationIndex == finalStationIndex {
            return .arrived
        }
        return .departed
    }
}

enum RailwayStationAnnotationLabel {
    static func text(
        for station: CallingPoint,
        historicalEvent: RailwayHistoricalStationEvent? = nil
    ) -> String {
        if station.isCancelledAtStation {
            return "\(station.locationName) (cancelled)"
        }

        let scheduledTime = railwayClockTime(station.st) ?? station.st
        if let historicalEvent,
           let eventTime = railwayClockTime(historicalEvent.time) {
            let punctuality = punctualityText(time: eventTime, scheduled: scheduledTime)
            let verb = historicalEvent.kind == .arrived ? "arrived" : "departed"
            return "\(station.locationName) (\(verb) \(eventTime), \(punctuality))"
        }
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

    init(
        station: CallingPoint,
        historicalEvent: RailwayHistoricalStationEvent? = nil
    ) {
        let scheduledTime = railwayClockTime(station.st) ?? station.st
        let expectedTime = railwayClockTime(station.et)
        let normalizedEstimate = station.et?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let historicalEvent,
           let eventTime = railwayClockTime(historicalEvent.time) {
            let delay = departureDelayMinutes(estimated: eventTime, scheduled: scheduledTime) ?? 0
            let verb = historicalEvent.kind == .arrived ? "Arrived" : "Departed"
            timingText = delay > 0
                ? "\(verb) \(eventTime) (\(delay) min\(delay == 1 ? "" : "s") late)"
                : "\(verb) \(eventTime) (on time)"
        } else if station.isCancelledAtStation {
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
    let id: String
    let coordinates: [CLLocationCoordinate2D]
    let status: RailwayRouteSegmentStatus
}

struct ServiceRailwayMapBranch: Identifiable {
    let id: String
    let route: ServiceRailwayRoute
    let stations: [CallingPoint]
    let highlightedTravelRange: ClosedRange<Int>?
    let historicalArrivalTime: String?
    let omitsFirstStationAnnotation: Bool

    init(
        id: String,
        route: ServiceRailwayRoute,
        stations: [CallingPoint],
        highlightedTravelRange: ClosedRange<Int>? = nil,
        historicalArrivalTime: String? = nil,
        omitsFirstStationAnnotation: Bool = true
    ) {
        self.id = id
        self.route = route
        self.stations = stations
        self.highlightedTravelRange = highlightedTravelRange
        self.historicalArrivalTime = historicalArrivalTime
        self.omitsFirstStationAnnotation = omitsFirstStationAnnotation
    }
}

private struct RailwayMapStationItem: Identifiable {
    let id: String
    let station: CallingPoint
    let coordinate: CLLocationCoordinate2D
    let primaryIndex: Int?
    let stationIndex: Int
    let historicalTravelRange: ClosedRange<Int>?
    let historicalArrivalTime: String?
    let finalStationIndex: Int
}

private enum RailwayMapAnnotationIdentifier {
    static let estimatedTrain = "railway-estimated-train"

    static func station(_ identifier: String) -> String {
        "railway-station-\(identifier)"
    }
}

private struct RailwayMapAnnotationZOrderConfigurator: UIViewRepresentable {
    let onMapViewResolved: (MKMapView) -> Void

    func makeUIView(context: Context) -> RailwayMapAnnotationZOrderView {
        RailwayMapAnnotationZOrderView(onMapViewResolved: onMapViewResolved)
    }

    func updateUIView(_ uiView: RailwayMapAnnotationZOrderView, context: Context) {
        uiView.onMapViewResolved = onMapViewResolved
        uiView.refreshAnnotationPriorities()
    }
}

private final class RailwayMapAnnotationZOrderView: UIView {
    private weak var mapView: MKMapView?
    var onMapViewResolved: (MKMapView) -> Void

    init(onMapViewResolved: @escaping (MKMapView) -> Void) {
        self.onMapViewResolved = onMapViewResolved
        super.init(frame: .zero)
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
        if self.mapView !== mapView {
            self.mapView = mapView
            onMapViewResolved(mapView)
        }

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

enum RailwayMapShareRenderer {
    static let attributionFooterHeight: CGFloat = 28

    @MainActor
    static func image(for view: UIView) -> UIImage? {
        view.layoutIfNeeded()
        let viewSize = view.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return nil }

        let outputSize = CGSize(
            width: viewSize.width,
            height: viewSize.height + attributionFooterHeight
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)

        return renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))

            let mapRect = CGRect(origin: .zero, size: viewSize)
            if !view.drawHierarchy(in: mapRect, afterScreenUpdates: true) {
                view.layer.render(in: context.cgContext)
            }

            let footerRect = CGRect(
                x: 0,
                y: viewSize.height,
                width: outputSize.width,
                height: attributionFooterHeight
            )
            UIColor.secondarySystemBackground.setFill()
            context.fill(footerRect)

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byTruncatingTail
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: .caption2),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraph,
            ]
            let textRect = footerRect.insetBy(dx: 8, dy: 6)
            NSString(string: "Train Track UK • Rail data © OpenStreetMap contributors")
                .draw(in: textRect, withAttributes: attributes)
        }
    }
}

private struct RailwayMapShareItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

@MainActor
private final class RailwayMapViewReference {
    weak var value: MKMapView?
}

private struct RailwayMapShareSheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
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
    let additionalRoutes: [ServiceRailwayMapBranch]
    let progress: ServiceProgressEstimate
    let estimatedTrainCoordinate: CLLocationCoordinate2D?
    let currentDelayMinutes: Int?
    let fromCRS: String
    let toCRS: String
    let highlightedTravelRange: ClosedRange<Int>?
    let historicalArrivalTime: String?

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnTrain = false
    @State private var selectedStationID: String?
    @State private var mapViewReference = RailwayMapViewReference()
    @State private var isMapViewResolved = false
    @State private var isPreparingShare = false
    @State private var shareItem: RailwayMapShareItem?
    @State private var shareError: String?

    init(
        route: ServiceRailwayRoute,
        stations: [CallingPoint],
        additionalRoutes: [ServiceRailwayMapBranch] = [],
        progress: ServiceProgressEstimate,
        estimatedTrainCoordinate: CLLocationCoordinate2D?,
        currentDelayMinutes: Int?,
        fromCRS: String,
        toCRS: String,
        highlightedTravelRange: ClosedRange<Int>? = nil,
        historicalArrivalTime: String? = nil
    ) {
        self.route = route
        self.stations = stations
        self.additionalRoutes = additionalRoutes
        self.progress = progress
        self.estimatedTrainCoordinate = estimatedTrainCoordinate
        self.currentDelayMinutes = currentDelayMinutes
        self.fromCRS = fromCRS
        self.toCRS = toCRS
        self.highlightedTravelRange = highlightedTravelRange
        self.historicalArrivalTime = historicalArrivalTime
    }

    var body: some View {
        Map(position: $cameraPosition, interactionModes: .all) {
            MapPolyline(coordinates: route.coordinates)
                .stroke(.secondary.opacity(0.45), lineWidth: 8)

            ForEach(additionalRoutes) { branch in
                MapPolyline(coordinates: branch.route.coordinates)
                    .stroke(.secondary.opacity(0.45), lineWidth: 8)
            }

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

            ForEach(stationItems) { item in
                Annotation(
                    RailwayMapAnnotationIdentifier.station(item.id),
                    coordinate: item.coordinate,
                    anchor: .bottom
                ) {
                    stationAnnotation(for: item)
                }
                .annotationTitles(.hidden)
                .tag(item.id)
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
        .background(RailwayMapAnnotationZOrderConfigurator { mapView in
            if mapViewReference.value !== mapView {
                mapViewReference.value = mapView
                isMapViewResolved = true
            }
        })
        .overlay(alignment: .topTrailing) {
            Button {
                centerOnTrainOrFrameRoute()
            } label: {
                Label(trainCoordinate == nil ? "Frame route" : "Center on train", systemImage: "scope")
                    .labelStyle(.iconOnly)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .background(.regularMaterial, in: Circle())
            .padding(12)
            .accessibilityLabel(
                trainCoordinate == nil ? "Frame complete service route" : "Center on estimated train location"
            )
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    shareCurrentMapView()
                } label: {
                    if isPreparingShare {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Share route map", systemImage: "square.and.arrow.up")
                    }
                }
                .disabled(isPreparingShare || !isMapViewResolved)
                .accessibilityHint("Shares an image of the currently visible route map")
            }
        }
        .sheet(item: $shareItem) { item in
            RailwayMapShareSheet(image: item.image)
        }
        .alert("Unable to share route map", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "The route map image could not be created.")
        }
    }

    private func shareCurrentMapView() {
        guard !isPreparingShare else { return }
        guard let resolvedMapView = mapViewReference.value else {
            isMapViewResolved = false
            shareError = "The route map is still loading. Please try again."
            return
        }

        isPreparingShare = true
        defer { isPreparingShare = false }
        guard let image = RailwayMapShareRenderer.image(for: resolvedMapView) else {
            shareError = "The route map image could not be created."
            return
        }
        shareItem = RailwayMapShareItem(image: image)
    }

    private var routeSegments: [RailwayMapSegment] {
        let highlightedPrimaryIndices = RailwayTravelHighlight.segmentIndices(
            for: highlightedTravelRange
        )
        return segments(
            for: route,
            stations: stations,
            idPrefix: "primary",
            highlightedIndices: highlightedPrimaryIndices
        )
            + additionalRoutes.flatMap { branch in
                segments(
                    for: branch.route,
                    stations: branch.stations,
                    idPrefix: branch.id,
                    highlightedIndices: highlightedIndices(for: branch)
                )
            }
    }

    private func highlightedIndices(for branch: ServiceRailwayMapBranch) -> Set<Int>? {
        if let range = branch.highlightedTravelRange {
            return RailwayTravelHighlight.segmentIndices(for: range)
        }
        let hasHistoricalHighlight = highlightedTravelRange != nil
            || additionalRoutes.contains { $0.highlightedTravelRange != nil }
        return hasHistoricalHighlight ? [] : nil
    }

    private func segments(
        for route: ServiceRailwayRoute,
        stations: [CallingPoint],
        idPrefix: String,
        highlightedIndices: Set<Int>?
    ) -> [RailwayMapSegment] {
        guard stations.count >= 2, route.stationCount == stations.count else { return [] }
        return stations.indices.dropLast().compactMap { index in
            guard highlightedIndices?.contains(index) ?? true else { return nil }
            let coordinates = route.coordinates(fromStation: index, throughStation: index + 1)
            guard coordinates.count >= 2 else { return nil }
            return RailwayMapSegment(
                id: "\(idPrefix)-\(index)",
                coordinates: coordinates,
                status: .between(stations[index], and: stations[index + 1])
            )
        }
    }

    private var stationItems: [RailwayMapStationItem] {
        let primary = stations.indices.compactMap { index -> RailwayMapStationItem? in
            guard let coordinate = route.coordinate(atStation: index) else { return nil }
            return RailwayMapStationItem(
                id: "primary-\(index)-\(stations[index].crs)",
                station: stations[index],
                coordinate: coordinate,
                primaryIndex: index,
                stationIndex: index,
                historicalTravelRange: highlightedTravelRange,
                historicalArrivalTime: historicalArrivalTime,
                finalStationIndex: stations.count - 1
            )
        }
        let additional = additionalRoutes.flatMap { branch in
            branch.stations.indices.compactMap { index -> RailwayMapStationItem? in
                if branch.omitsFirstStationAnnotation && index == branch.stations.startIndex {
                    return nil
                }
                guard let coordinate = branch.route.coordinate(atStation: index) else { return nil }
                return RailwayMapStationItem(
                    id: "\(branch.id)-\(index)-\(branch.stations[index].crs)",
                    station: branch.stations[index],
                    coordinate: coordinate,
                    primaryIndex: nil,
                    stationIndex: index,
                    historicalTravelRange: branch.highlightedTravelRange,
                    historicalArrivalTime: branch.historicalArrivalTime,
                    finalStationIndex: branch.stations.count - 1
                )
            }
        }
        return primary + additional
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
        (["\(route.coordinates.count):\(route.totalLength)"] + additionalRoutes.map {
            "\($0.id):\($0.route.coordinates.count):\($0.route.totalLength)"
        }).joined(separator: "|")
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

    private func stationAnnotation(for item: RailwayMapStationItem) -> some View {
        Button {
            selectedStationID = item.id
        } label: {
            VStack(spacing: 3) {
                Text(stationLabel(for: item))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.station.isCancelledAtStation ? Color.red : Color.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 180)
                    .strikethrough(
                        item.station.isCancelledAtStation,
                        color: item.station.isCancelledAtStation ? .red : nil
                    )
                    .shadow(color: .black.opacity(0.9), radius: 2)

                stationDot(for: item)
            }
            .padding(4)
            .contentShape(Rectangle())
            .offset(y: 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(stationAccessibilityLabel(for: item))
        .accessibilityHint("Shows timing and platform")
        .popover(
            isPresented: stationPopoverBinding(for: item),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            stationInfoPopover(for: item)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func stationPopoverBinding(for item: RailwayMapStationItem) -> Binding<Bool> {
        Binding(
            get: { selectedStationID == item.id },
            set: { isPresented in
                if isPresented {
                    selectedStationID = item.id
                } else if selectedStationID == item.id {
                    selectedStationID = nil
                }
            }
        )
    }

    private func stationInfoPopover(for item: RailwayMapStationItem) -> some View {
        let station = item.station
        let presentation = RailwayStationInfoPresentation(
            station: station,
            historicalEvent: historicalEvent(for: item)
        )
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
    private func stationDot(for item: RailwayMapStationItem) -> some View {
        if normalizedCRS(item.station.crs) == normalizedCRS(fromCRS) {
            Circle()
                .fill(.orange)
                .frame(width: 18, height: 18)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        } else {
            let state = stationState(for: item)
            Circle()
                .fill(state.fill)
                .frame(width: state.isCurrent ? 16 : 12, height: state.isCurrent ? 16 : 12)
                .overlay(Circle().stroke(.black, lineWidth: 2))
                .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        }
    }

    private func stationState(for item: RailwayMapStationItem) -> (fill: Color, isCurrent: Bool) {
        let isCurrent = progress.isAvailable
            && progress.previousStationIndex == progress.nextStationIndex
            && item.primaryIndex == progress.previousStationIndex
        return (.white, isCurrent)
    }

    private func stationAccessibilityLabel(for item: RailwayMapStationItem) -> String {
        let label = stationLabel(for: item)
        if normalizedCRS(item.station.crs) == normalizedCRS(fromCRS) {
            return "\(label), selected journey origin"
        }
        if normalizedCRS(item.station.crs) == normalizedCRS(toCRS) {
            return "\(label), selected journey destination"
        }
        let status: String
        if let index = item.primaryIndex,
           progress.isAvailable,
           progress.previousStationIndex == progress.nextStationIndex,
           index == progress.previousStationIndex {
            status = "current station"
        } else if let index = item.primaryIndex,
                  progress.isAvailable && index <= progress.previousStationIndex {
            status = "completed"
        } else {
            status = "upcoming"
        }
        return "\(label), \(status)"
    }

    private func stationLabel(for item: RailwayMapStationItem) -> String {
        RailwayStationAnnotationLabel.text(
            for: item.station,
            historicalEvent: historicalEvent(for: item)
        )
    }

    private func historicalEvent(for item: RailwayMapStationItem) -> RailwayHistoricalStationEvent? {
        guard let highlightedTravelRange = item.historicalTravelRange,
              let kind = RailwayHistoricalStationSemantics.eventKind(
                stationIndex: item.stationIndex,
                userDestinationIndex: highlightedTravelRange.upperBound,
                finalStationIndex: item.finalStationIndex
              ) else {
            return nil
        }
        let time = item.stationIndex == highlightedTravelRange.upperBound
            ? item.historicalArrivalTime ?? historicalEventTime(for: item.station)
            : historicalEventTime(for: item.station)
        return RailwayHistoricalStationEvent(kind: kind, time: time)
    }

    private func historicalEventTime(for station: CallingPoint) -> String {
        if let actual = railwayClockTime(station.at) {
            return actual
        }
        if station.at?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("On time") == .orderedSame {
            return railwayClockTime(station.st) ?? station.st
        }
        if let estimate = railwayClockTime(station.et) {
            return estimate
        }
        return railwayClockTime(station.st) ?? station.st
    }

    private func normalizedCRS(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
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
        let coordinates = route.coordinates + additionalRoutes.flatMap(\.route.coordinates)
        guard coordinates.count >= 2 else { return }
        let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let rect = polyline.boundingMapRect
        let horizontalPadding = max(rect.size.width * 0.12, 800)
        let verticalPadding = max(rect.size.height * 0.12, 800)
        cameraPosition = .rect(rect.insetBy(dx: -horizontalPadding, dy: -verticalPadding))
    }
}
