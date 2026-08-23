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

enum RailwayStationTransferLabel {
    static func text(
        stationName: String,
        arrivalTime: String?,
        departureTime: String?
    ) -> String? {
        guard let arrivalTime = railwayClockTime(arrivalTime),
              let departureTime = railwayClockTime(departureTime),
              let arrivalMinutes = minutesSinceMidnight(arrivalTime),
              let departureMinutes = minutesSinceMidnight(departureTime) else {
            return nil
        }
        let changeMinutes = (departureMinutes - arrivalMinutes + 24 * 60) % (24 * 60)
        return "\(stationName) (arrived \(arrivalTime), \(changeMinutes) minute change, departed \(departureTime))"
    }

    private static func minutesSinceMidnight(_ time: String) -> Int? {
        let components = time.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]) else {
            return nil
        }
        return hour * 60 + minute
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
    let userDepartureCRS: String?
    let highlightedTravelRange: ClosedRange<Int>?
    let historicalDepartureTime: String?
    let historicalArrivalTime: String?
    let omitsFirstStationAnnotation: Bool

    init(
        id: String,
        route: ServiceRailwayRoute,
        stations: [CallingPoint],
        userDepartureCRS: String? = nil,
        highlightedTravelRange: ClosedRange<Int>? = nil,
        historicalDepartureTime: String? = nil,
        historicalArrivalTime: String? = nil,
        omitsFirstStationAnnotation: Bool = true
    ) {
        self.id = id
        self.route = route
        self.stations = stations
        self.userDepartureCRS = userDepartureCRS
        self.highlightedTravelRange = highlightedTravelRange
        self.historicalDepartureTime = historicalDepartureTime
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
    let userDepartureCRS: String?
    let historicalTravelRange: ClosedRange<Int>?
    let historicalArrivalTime: String?
    let finalStationIndex: Int
    let labelOverride: String?
    let isTransferStation: Bool
}

private struct RailwayMapAnnotationSource {
    let idPrefix: String
    let stations: [CallingPoint]
    let highlightedTravelRange: ClosedRange<Int>?
    let historicalDepartureTime: String?
    let historicalArrivalTime: String?
}

private struct RailwayMapTransferAnnotationPlan {
    var labelsByStationID: [String: String] = [:]
    var suppressedStationIDs: Set<String> = []
    var transferStationIDs: Set<String> = []
}

enum RailwayStationLabelPriority {
    static func shouldRemainVisible(
        stationIndex: Int,
        finalStationIndex: Int,
        stationCRS: String,
        userDepartureCRS: String?
    ) -> Bool {
        if stationIndex == 0 || stationIndex == finalStationIndex {
            return true
        }
        guard let userDepartureCRS else { return false }
        return normalizedCRS(stationCRS) == normalizedCRS(userDepartureCRS)
    }

    private static func normalizedCRS(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
}

enum RailwayStationLabelCollisionDetector {
    static let maximumLabelWidth: CGFloat = 180
    static let maximumLineCount: CGFloat = 3
    static let labelAnchorGap: CGFloat = 20
    static let minimumOverlapRatio: CGFloat = 0.20

    @MainActor
    static func frame(
        for text: String,
        coordinate: CLLocationCoordinate2D,
        in mapView: MKMapView
    ) -> CGRect {
        let preferredFont = UIFont.preferredFont(forTextStyle: .caption2)
        let font = UIFont.systemFont(ofSize: preferredFont.pointSize, weight: .semibold)
        return frame(
            for: text,
            anchor: mapView.convert(coordinate, toPointTo: mapView),
            font: font
        )
    }

    static func frame(for text: String, anchor: CGPoint, font: UIFont) -> CGRect {
        let measuredBounds = NSString(string: text).boundingRect(
            with: CGSize(width: maximumLabelWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let textWidth = min(maximumLabelWidth, max(1, ceil(measuredBounds.width)))
        let maximumHeight = ceil(font.lineHeight * maximumLineCount)
        let textHeight = min(
            maximumHeight,
            max(ceil(font.lineHeight), ceil(measuredBounds.height))
        )
        let labelSize = CGSize(width: textWidth + 8, height: textHeight + 4)

        // The annotation is bottom-anchored, with its label above the station dot.
        return CGRect(
            x: anchor.x - (labelSize.width / 2),
            y: anchor.y - labelSize.height - labelAnchorGap,
            width: labelSize.width,
            height: labelSize.height
        )
    }

    static func hasOverlap(labelFrames: [CGRect], visibleBounds: CGRect) -> Bool {
        guard !visibleBounds.isEmpty else { return false }
        let visibleFrames = labelFrames
            .filter { frame in
                let stationAnchor = CGPoint(
                    x: frame.midX,
                    y: frame.maxY + labelAnchorGap
                )
                return visibleBounds.contains(stationAnchor)
            }

        guard visibleFrames.count >= 2 else { return false }
        for index in visibleFrames.indices.dropLast() {
            for otherIndex in visibleFrames.indices where otherIndex > index {
                if hasMeaningfulOverlap(
                    visibleFrames[index],
                    visibleFrames[otherIndex]
                ) {
                    return true
                }
            }
        }
        return false
    }

    private static func hasMeaningfulOverlap(_ first: CGRect, _ second: CGRect) -> Bool {
        let intersection = first.intersection(second)
        guard !intersection.isNull, !intersection.isEmpty else { return false }
        let smallerArea = min(first.width * first.height, second.width * second.height)
        guard smallerArea > 0 else { return false }
        let overlapArea = intersection.width * intersection.height
        return overlapArea / smallerArea >= minimumOverlapRatio
    }
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
    static let maximumRenderScale: CGFloat = 2

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
        format.scale = min(format.scale, maximumRenderScale)
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)

        return renderer.image { context in
            UIColor.systemBackground.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))

            let mapRect = CGRect(origin: .zero, size: viewSize)
            if !view.drawHierarchy(in: mapRect, afterScreenUpdates: false) {
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
    let followsTrain: Bool
    let showsChrome: Bool

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var hasCenteredOnTrain = false
    @State private var selectedStationID: String?
    @State private var mapViewReference = RailwayMapViewReference()
    @State private var isMapViewResolved = false
    @State private var isMapContentReady = false
    @State private var hidesSecondaryStationLabels = false
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
        historicalArrivalTime: String? = nil,
        followsTrain: Bool = false,
        showsChrome: Bool = true
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
        self.followsTrain = followsTrain
        self.showsChrome = showsChrome
    }

    var body: some View {
        Map(position: $cameraPosition, interactionModes: showsChrome ? .all : []) {
            if isMapContentReady {
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

                UserAnnotation()

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
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .task {
            // Commit the cold MapKit view before adding its route geometry and annotations.
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled else { return }
            isMapContentReady = true
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
            refreshStationLabelVisibility(in: mapView)
        })
        .overlay(alignment: .topTrailing) {
            if showsChrome {
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
            guard (followsTrain || !hasCenteredOnTrain), trainCoordinate != nil else { return }
            centerOnTrainOrFrameRoute()
        }
        .onChange(of: routeKey) { _, _ in
            hasCenteredOnTrain = false
            centerOnTrainOrFrameRoute()
        }
        .onMapCameraChange(frequency: .onEnd) { _ in
            refreshStationLabelVisibility()
        }
        .toolbar {
            if showsChrome {
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
        Task { @MainActor in
            // Let the share-button gesture finish before synchronously drawing the map.
            await Task.yield()
            defer { isPreparingShare = false }

            guard let image = RailwayMapShareRenderer.image(for: resolvedMapView) else {
                shareError = "The route map image could not be created."
                return
            }
            shareItem = RailwayMapShareItem(image: image)
        }
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
        let transferPlan = transferAnnotationPlan
        let primary = stations.indices.compactMap { index -> RailwayMapStationItem? in
            let id = stationItemID(prefix: "primary", index: index, station: stations[index])
            guard !transferPlan.suppressedStationIDs.contains(id) else { return nil }
            guard let coordinate = route.coordinate(atStation: index) else { return nil }
            return RailwayMapStationItem(
                id: id,
                station: stations[index],
                coordinate: coordinate,
                primaryIndex: index,
                stationIndex: index,
                userDepartureCRS: fromCRS,
                historicalTravelRange: highlightedTravelRange,
                historicalArrivalTime: historicalArrivalTime,
                finalStationIndex: stations.count - 1,
                labelOverride: transferPlan.labelsByStationID[id],
                isTransferStation: transferPlan.transferStationIDs.contains(id)
            )
        }
        let additional = additionalRoutes.flatMap { branch in
            branch.stations.indices.compactMap { index -> RailwayMapStationItem? in
                if branch.omitsFirstStationAnnotation && index == branch.stations.startIndex {
                    return nil
                }
                let id = stationItemID(prefix: branch.id, index: index, station: branch.stations[index])
                guard !transferPlan.suppressedStationIDs.contains(id) else { return nil }
                guard let coordinate = branch.route.coordinate(atStation: index) else { return nil }
                return RailwayMapStationItem(
                    id: id,
                    station: branch.stations[index],
                    coordinate: coordinate,
                    primaryIndex: nil,
                    stationIndex: index,
                    userDepartureCRS: branch.userDepartureCRS,
                    historicalTravelRange: branch.highlightedTravelRange,
                    historicalArrivalTime: branch.historicalArrivalTime,
                    finalStationIndex: branch.stations.count - 1,
                    labelOverride: transferPlan.labelsByStationID[id],
                    isTransferStation: transferPlan.transferStationIDs.contains(id)
                )
            }
        }
        return primary + additional
    }

    private var transferAnnotationPlan: RailwayMapTransferAnnotationPlan {
        let sources = [
            RailwayMapAnnotationSource(
                idPrefix: "primary",
                stations: stations,
                highlightedTravelRange: highlightedTravelRange,
                historicalDepartureTime: nil,
                historicalArrivalTime: historicalArrivalTime
            )
        ] + additionalRoutes.map { branch in
            RailwayMapAnnotationSource(
                idPrefix: branch.id,
                stations: branch.stations,
                highlightedTravelRange: branch.highlightedTravelRange,
                historicalDepartureTime: branch.historicalDepartureTime,
                historicalArrivalTime: branch.historicalArrivalTime
            )
        }

        var plan = RailwayMapTransferAnnotationPlan()
        for sourceIndex in sources.indices.dropLast() {
            let arrivingSource = sources[sourceIndex]
            let departingSource = sources[sourceIndex + 1]
            guard let arrivingIndex = arrivingSource.highlightedTravelRange?.upperBound,
                  let departingIndex = departingSource.highlightedTravelRange?.lowerBound,
                  arrivingSource.stations.indices.contains(arrivingIndex),
                  departingSource.stations.indices.contains(departingIndex) else {
                continue
            }

            let arrivingStation = arrivingSource.stations[arrivingIndex]
            let departingStation = departingSource.stations[departingIndex]
            guard normalizedCRS(arrivingStation.crs) == normalizedCRS(departingStation.crs) else {
                continue
            }

            let arrivingID = stationItemID(
                prefix: arrivingSource.idPrefix,
                index: arrivingIndex,
                station: arrivingStation
            )
            let departingID = stationItemID(
                prefix: departingSource.idPrefix,
                index: departingIndex,
                station: departingStation
            )
            plan.suppressedStationIDs.insert(departingID)
            plan.transferStationIDs.insert(arrivingID)
            plan.labelsByStationID[arrivingID] = RailwayStationTransferLabel.text(
                stationName: arrivingStation.locationName,
                arrivalTime: arrivingSource.historicalArrivalTime,
                departureTime: departingSource.historicalDepartureTime
            )
        }
        return plan
    }

    private func stationItemID(prefix: String, index: Int, station: CallingPoint) -> String {
        "\(prefix)-\(index)-\(station.crs)"
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
                if shouldShowLabel(for: item) {
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
                }

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
        if !showsChrome {
            return item.station.locationName
        }
        if let labelOverride = item.labelOverride {
            return labelOverride
        }
        return RailwayStationAnnotationLabel.text(
            for: item.station,
            historicalEvent: historicalEvent(for: item)
        )
    }

    private func shouldShowLabel(for item: RailwayMapStationItem) -> Bool {
        item.isTransferStation
            || !hidesSecondaryStationLabels
            || RailwayStationLabelPriority.shouldRemainVisible(
                stationIndex: item.stationIndex,
                finalStationIndex: item.finalStationIndex,
                stationCRS: item.station.crs,
                userDepartureCRS: item.userDepartureCRS
            )
    }

    private func refreshStationLabelVisibility(in resolvedMapView: MKMapView? = nil) {
        guard let mapView = resolvedMapView ?? mapViewReference.value else { return }
        let frames = stationItems.map { item in
            RailwayStationLabelCollisionDetector.frame(
                for: stationLabel(for: item),
                coordinate: item.coordinate,
                in: mapView
            )
        }
        let shouldHideSecondaryLabels = RailwayStationLabelCollisionDetector.hasOverlap(
            labelFrames: frames,
            visibleBounds: mapView.bounds
        )
        guard hidesSecondaryStationLabels != shouldHideSecondaryLabels else { return }
        hidesSecondaryStationLabels = shouldHideSecondaryLabels
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
            latitudinalMeters: showsChrome ? 4_500 : 3_000,
            longitudinalMeters: showsChrome ? 4_500 : 3_000
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
