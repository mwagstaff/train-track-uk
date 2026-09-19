import MapKit
import SwiftUI

struct PlannerJourneyRouteMapView: View {
    let journey: PlannedJourney
    let selectedLegIndex: Int
    @State private var routeMap: PlannerJourneyRouteMap?
    @State private var error: String?
    @State private var retry = UUID()
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var showsWholeJourney = false
    @StateObject private var location = LocationManagerPhone()
    @State private var liveService: PlannerMapLiveService?
    @State private var currentTime = Date()
    @State private var mapViewReference = RailwayMapViewReference()
    @State private var hidesSecondaryStationLabels = false

    var body: some View {
        Group {
            if let routeMap {
                Map(position: $cameraPosition) {
                    UserAnnotation()
                    ForEach(routeMap.legs.filter { $0.id != selectedLegIndex }) { leg in
                        MapPolyline(coordinates: leg.coordinates)
                            .stroke(Color.gray.opacity(0.5), style: StrokeStyle(lineWidth: 5, dash: leg.isConnection ? [6, 4] : []))
                    }
                    ForEach(routeMap.legs.filter { $0.id == selectedLegIndex }) { leg in
                        MapPolyline(coordinates: leg.coordinates)
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 7, dash: leg.isConnection ? [6, 4] : []))
                    }
                    ForEach(routeMap.stops) { stop in
                        Annotation(RailwayMapAnnotationIdentifier.station(stop.id), coordinate: stop.coordinate, anchor: .bottom) {
                            stationAnnotation(for: stop)
                        }
                        .annotationTitles(.hidden)
                    }
                    if let coordinate = liveService?.trainCoordinate(at: currentTime) {
                        Annotation(RailwayMapAnnotationIdentifier.estimatedTrain, coordinate: coordinate) {
                            RailwayEstimatedTrainMarker(label: "Estimated train location")
                                .accessibilityIdentifier("planner.map.train")
                        }
                        .annotationTitles(.hidden)
                    }
                }
                .background(RailwayMapAnnotationZOrderConfigurator { mapView in
                    mapViewReference.value = mapView
                    refreshStationLabelVisibility(in: mapView)
                })
                .onMapCameraChange(frequency: .onEnd) { _ in
                    refreshStationLabelVisibility()
                }
                .task {
                    location.request()
                    var tick = 0
                    while !Task.isCancelled {
                        currentTime = Date()
                        if tick % 6 == 0 {
                            do {
                                let service = try await PlannerMapLiveService.load(for: journey.legs[selectedLegIndex], previous: liveService)
                                try Task.checkCancellation()
                                let hasNewRoute = liveService?.stations.map(\.crs) != service?.stations.map(\.crs)
                                liveService = service
                                if let service {
                                    let updatedMap = routeMap.including(service, journey: journey)
                                    self.routeMap = updatedMap
                                    refreshStationLabelVisibility()
                                    if showsWholeJourney && hasNewRoute { cameraPosition = .region(updatedMap.wholeRegion) }
                                }
                            } catch { if Task.isCancelled { return } }
                        }
                        tick += 1
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    }
                }
                .mapStyle(.standard(elevation: .flat, emphasis: .muted))
                .mapControls { MapCompass(); MapScaleView() }
                .accessibilityIdentifier("planner.journey-route-map")
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(journey.legs[selectedLegIndex].heading).font(.headline)
                        Text("Selected section in blue · Other sections in grey").font(.caption)
                        if routeMap.legs.contains(where: \.isConnection) {
                            Text("Dashed lines show station connections, not the exact route.").font(.caption)
                        }
                        if routeMap.hasMissingLegs {
                            Text("Some sections could not be mapped.").font(.caption)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial)
                }
            } else if let error {
                ContentUnavailableView {
                    Label("Route map unavailable", systemImage: "map")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { retry = UUID() }
                }
            } else {
                ProgressView("Loading journey route map…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Route map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let routeMap {
                    Button {
                        showsWholeJourney.toggle()
                        cameraPosition = .region(showsWholeJourney ? routeMap.wholeRegion : routeMap.selectedRegion)
                    } label: {
                        Image(systemName: showsWholeJourney ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityLabel(showsWholeJourney ? "Show selected section" : "Show whole journey")
                }
            }
        }
        .disablesHorizontalTabSwipe()
        .hidesRailwayBackgroundChrome()
        .onDisappear { location.cancel() }
        .task(id: retry) {
            routeMap = nil
            error = nil
            showsWholeJourney = false
            do {
                let result = try await PlannerJourneyRouteMap.load(journey: journey, selectedLegIndex: selectedLegIndex)
                try Task.checkCancellation()
                routeMap = result
                cameraPosition = .region(result.selectedRegion)
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private func stationAnnotation(for stop: PlannerJourneyRouteMap.Stop) -> some View {
        let leg = journey.legs[selectedLegIndex]
        let isOrigin = stop.id == leg.from.crs
        let isDestination = stop.id == leg.to.crs
        let isEndpoint = stop.role != .stop
        let label = liveService?.stationLabel(crs: stop.id, at: currentTime) ?? stop.label
        return VStack(spacing: 3) {
            if isEndpoint || !hidesSecondaryStationLabels {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stop.isSelected || isEndpoint ? Color.white : Color.gray)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 180)
                    .shadow(color: .black.opacity(0.9), radius: 2)
            }
            Circle()
                .fill(stop.role == .origin ? Color.orange : stop.role == .change ? Color.orange : stop.role == .destination ? Color.blue : Color.white)
                .frame(width: isEndpoint ? 18 : 12, height: isEndpoint ? 18 : 12)
                .overlay(Circle().stroke(isEndpoint ? Color.white : stop.isSelected ? Color.black : Color.gray, lineWidth: 2))
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .padding(4)
        .offset(y: isEndpoint ? 13 : 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label + ", journey \(stop.role.rawValue)" + (isOrigin ? ", selected section origin" : isDestination ? ", selected section destination" : stop.isSelected ? ", selected section stop" : ", other section stop"))
        .accessibilityIdentifier("planner.map.station.\(stop.id)")
    }

    private func refreshStationLabelVisibility(in resolvedMapView: MKMapView? = nil) {
        guard let mapView = resolvedMapView ?? mapViewReference.value, let routeMap else { return }
        let frames = routeMap.stops.map { stop in
            RailwayStationLabelCollisionDetector.frame(for: liveService?.stationLabel(crs: stop.id, at: currentTime) ?? stop.label,
                                                       coordinate: stop.coordinate, in: mapView)
        }
        let shouldHide = RailwayStationLabelCollisionDetector.hasOverlap(labelFrames: frames, visibleBounds: mapView.bounds)
        if hidesSecondaryStationLabels != shouldHide { hidesSecondaryStationLabels = shouldHide }
    }
}

@MainActor
struct PlannerMapLiveService {
    let serviceID: String
    let stations: [CallingPoint]
    let route: ServiceRailwayRoute
    let generatedAt: Date

    func trainCoordinate(at now: Date) -> CLLocationCoordinate2D? {
        guard now.timeIntervalSince(generatedAt) < 120 else { return nil }
        let progress = ServiceProgressEstimator.estimate(for: stations, at: now, calendar: PlannerTime.calendar)
        guard progress.isAvailable else { return nil }
        return route.coordinate(atFloatingStationIndex: progress.floatingIndex)
    }

    func stationLabel(crs: String, at now: Date) -> String? {
        guard now.timeIntervalSince(generatedAt) < 120,
              let index = stations.firstIndex(where: { $0.crs == crs }) else { return nil }
        let progress = ServiceProgressEstimator.estimate(for: stations, at: now, calendar: PlannerTime.calendar)
        let actual = stations[index].at?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDeparted = ((actual?.isEmpty == false && actual?.lowercased() != "cancelled") || progress.floatingIndex > Double(index))
            && ServiceProgressEstimator.isDeparturePermitted(at: index, in: stations, now: now, calendar: PlannerTime.calendar)
        return RailwayStationAnnotationLabel.text(for: stations[index], hasDeparted: hasDeparted)
    }

    static func matches(_ departure: DepartureV2, leg: PlannedJourney.Leg, at now: Date) -> Bool {
        guard departure.hasProviderServiceID, departure.serviceType == "train",
              let date = JourneyHistoryTime.date(for: departure.departureTime.scheduled, near: departure.timestamp ?? now),
              abs(date.timeIntervalSince(leg.scheduledDeparture ?? leg.departure)) < 30 else { return false }
        return operatorMatches(name: departure.operator, code: departure.operatorCode, leg: leg)
    }

    private static func operatorMatches(name: String?, code: String?, leg: PlannedJourney.Leg) -> Bool {
        guard let expected = leg.operator else { return true }
        let branding = ServerConfigStore.shared.operatorBranding
        let planned = OperatorBrandingResolver.resolve(name: expected, code: expected, in: branding)
        let live = OperatorBrandingResolver.resolve(name: name, code: code, in: branding)
        return planned != nil && planned?.id == live?.id
            || expected.caseInsensitiveCompare(code ?? name ?? "") == .orderedSame
    }

    static func load(for leg: PlannedJourney.Leg, previous: Self? = nil) async throws -> Self? {
        let now = Date()
        guard leg.kind == "vehicle", leg.mode == "rail",
              now >= leg.departure.addingTimeInterval(-2 * 3600), now <= leg.arrival.addingTimeInterval(3600) else { return nil }
        let network = NetworkServicePhone.shared
        let key = "\(leg.from.crs)_\(leg.to.crs)"
        var serviceID = previous?.serviceID
        if serviceID == nil {
            let boards = try await network.fetchDeparturesAggregated(pairs: [(leg.from.crs, leg.to.crs)], delayBeforeEachBatch: false, timeout: 8)
            try Task.checkCancellation()
            let matchingDepartures = (boards[key]?.departures ?? []).filter { matches($0, leg: leg, at: now) }
            if matchingDepartures.count == 1 { serviceID = matchingDepartures[0].serviceID }
            else if matchingDepartures.isEmpty {
                let recent = try await network.fetchRecentDepartures(pairs: [(leg.from.crs, leg.to.crs)])
                let candidates = (recent[key] ?? []).filter { abs($0.scheduledDepartureAt.timeIntervalSince(leg.scheduledDeparture ?? leg.departure)) < 30 && $0.serviceType == "train" }
                if candidates.count == 1 { serviceID = candidates[0].serviceID }
            }
        }
        guard let serviceID else { return nil }
        let context = ServiceDetailsLookupContext(fromCRS: leg.from.crs, toCRS: leg.to.crs, originCRS: nil,
            operator: leg.operator, destinationCRSs: [leg.to.crs], length: nil)
        let response = try await network.fetchServiceDetailsAggregated(ids: [serviceID], context: context, timeout: 8)
        try Task.checkCancellation()
        guard let details = response[serviceID], !((details.isCancelled) ?? false),
              operatorMatches(name: details.operator, code: details.operatorCode, leg: leg),
              let stations = details.stationBranches.first(where: { branch in
                  guard let start = branch.firstIndex(where: { $0.crs == leg.from.crs }),
                        let end = branch.lastIndex(where: { $0.crs == leg.to.crs }) else { return false }
                  return start < end && branch[start].st == PlannerTime.display(
                    leg.scheduledDeparture ?? leg.departure,
                    includeDate: false,
                    timeZone: PlannerTime.zone
                  )
              }), stations.count >= 2 else { return nil }
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: details.generatedAt)
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let generatedAt = date ?? formatter.date(from: details.generatedAt), abs(now.timeIntervalSince(generatedAt)) < 120 else { return nil }
        let route: ServiceRailwayRoute
        if let previous, previous.stations.map(\.crs) == stations.map(\.crs) { route = previous.route }
        else { route = try await RailwayRoutingService.shared.route(forStationCRSs: stations.map(\.crs)) }
        try Task.checkCancellation()
        return Self(serviceID: serviceID, stations: stations, route: route, generatedAt: generatedAt)
    }
}

struct PlannerJourneyRouteMap {
    enum StationRole: String { case origin, change, destination, stop }

    static func stationRole(crs: String, journey: PlannedJourney) -> StationRole {
        if crs == journey.legs.first?.from.crs { return .origin }
        if crs == journey.legs.last?.to.crs { return .destination }
        if journey.legs.contains(where: { $0.from.crs == crs || $0.to.crs == crs }) { return .change }
        return .stop
    }

    struct Leg: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let isConnection: Bool
    }

    struct Stop: Identifiable {
        let id: String
        let label: String
        let coordinate: CLLocationCoordinate2D
        let isSelected: Bool
        let role: StationRole
    }

    let legs: [Leg]
    let stops: [Stop]
    let hasMissingLegs: Bool
    let selectedRegion: MKCoordinateRegion
    let wholeRegion: MKCoordinateRegion

    @MainActor
    func including(_ service: PlannerMapLiveService, journey: PlannedJourney) -> Self {
        // The live service can include stops outside the planner's boarding/alighting slice.
        // Draw its complete route first, so the selected blue section stays on top.
        let background = Leg(id: Int.min, coordinates: service.route.coordinates, isConnection: false)
        let updatedLegs = [background] + legs.filter { $0.id != background.id }
        let existingCRSs = Set(stops.map(\.id))
        let additionalStops = service.stations.enumerated().compactMap { index, station -> Stop? in
            guard !existingCRSs.contains(station.crs), let coordinate = service.route.coordinate(atStation: index) else { return nil }
            return Stop(id: station.crs, label: RailwayStationAnnotationLabel.text(for: station, hasDeparted: false),
                        coordinate: coordinate, isSelected: false,
                        role: Self.stationRole(crs: station.crs, journey: journey))
        }
        return Self(legs: updatedLegs, stops: stops + additionalStops, hasMissingLegs: hasMissingLegs,
                    selectedRegion: selectedRegion, wholeRegion: Self.region(for: updatedLegs.flatMap(\.coordinates)))
    }

    @MainActor
    static func load(journey: PlannedJourney, selectedLegIndex: Int) async throws -> Self {
        try? await StationsService.shared.loadStations(timeout: 5)
        try Task.checkCancellation()
        var coordinatesByCRS = [String: CLLocationCoordinate2D]()
        for station in StationsService.shared.stations where station.hasUsableCoordinate {
            coordinatesByCRS[station.crs] = station.coordinate
        }
        var legs: [Leg] = []
        var connections: [Int] = []
        let travelLegs = journey.legs.indices.filter { !journey.legs[$0].isTrainChange }
        for index in travelLegs {
            try Task.checkCancellation()
            let leg = journey.legs[index]
            if leg.kind == "vehicle" && leg.mode == "rail" {
                do {
                    let points = leg.mapCallingPoints
                    let fullPoints = leg.serviceCallingPoints ?? points
                    let start = fullPoints.firstIndex { $0.station.crs == leg.from.crs }
                    let end = fullPoints.lastIndex { $0.station.crs == leg.to.crs }
                    let canUseFullRoute = start != nil && end != nil && start! <= end!
                    let routePoints = canUseFullRoute ? fullPoints : points
                    let route = try await RailwayRoutingService.shared.route(forStationCRSs: routePoints.map(\.station.crs))
                    let lower = canUseFullRoute ? start! : 0
                    let upper = canUseFullRoute ? end! : points.count - 1
                    legs.append(Leg(id: index, coordinates: route.coordinates(fromStation: lower, throughStation: upper), isConnection: false))
                    if lower > 0 { legs.append(Leg(id: -index * 2 - 1, coordinates: route.coordinates(fromStation: 0, throughStation: lower), isConnection: false)) }
                    if upper < routePoints.count - 1 { legs.append(Leg(id: -index * 2 - 2, coordinates: route.coordinates(fromStation: upper, throughStation: routePoints.count - 1), isConnection: false)) }
                    for (pointIndex, point) in routePoints.enumerated() {
                        coordinatesByCRS[point.station.crs] = route.coordinate(atStation: pointIndex)
                    }
                    continue
                } catch {
                    try Task.checkCancellation()
                }
            }
            connections.append(index)
        }
        for index in connections {
            let points = journey.legs[index].mapCallingPoints
            let coordinates = points.compactMap { coordinatesByCRS[$0.station.crs] }
            if coordinates.count == points.count && coordinates.count >= 2 {
                legs.append(Leg(id: index, coordinates: coordinates, isConnection: true))
            }
        }
        guard let selectedLeg = legs.first(where: { $0.id == selectedLegIndex }) else {
            throw PlannerError(code: "MAP_UNAVAILABLE", message: "The selected section could not be mapped. Please try again later.")
        }
        let selectedCRSs = Set(journey.legs[selectedLegIndex].mapCallingPoints.map(\.station.crs))
        var stopsByCRS = [String: Stop]()
        for index in travelLegs {
            let leg = journey.legs[index]
            for point in leg.serviceCallingPoints ?? leg.mapCallingPoints {
                guard let coordinate = coordinatesByCRS[point.station.crs] else { continue }
                let isSelected = selectedCRSs.contains(point.station.crs)
                let time = point.station.crs == leg.to.crs ? point.arrival ?? point.departure : point.departure ?? point.arrival
                let label = point.station.name + (time.map { " (due " + PlannerTime.display($0, includeDate: false) + ")" } ?? "")
                if stopsByCRS[point.station.crs] == nil || index == selectedLegIndex {
                    stopsByCRS[point.station.crs] = Stop(id: point.station.crs, label: label, coordinate: coordinate, isSelected: isSelected,
                        role: stationRole(crs: point.station.crs, journey: journey))
                }
            }
        }
        return Self(legs: legs.sorted { $0.id < $1.id }, stops: stopsByCRS.values.sorted { $0.id < $1.id },
                    hasMissingLegs: legs.filter { $0.id >= 0 }.count < travelLegs.count,
                    selectedRegion: region(for: selectedLeg.coordinates), wholeRegion: region(for: legs.flatMap(\.coordinates)))
    }

    private static func region(for coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
        let latitudes = coordinates.map(\.latitude)
        let longitudes = coordinates.map(\.longitude)
        let minLatitude = latitudes.min()!
        let maxLatitude = latitudes.max()!
        let minLongitude = longitudes.min()!
        let maxLongitude = longitudes.max()!
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.02, (maxLatitude - minLatitude) * 1.6),
                                   longitudeDelta: max(0.02, (maxLongitude - minLongitude) * 2))
        )
    }
}
