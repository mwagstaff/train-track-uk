import SwiftUI
import Combine
import CoreLocation

private enum ServiceMapPresentation: String, CaseIterable, Identifiable {
    case map = "Map"
    case callingPoints = "Calling points"

    var id: Self { self }
}

struct ServiceMapView: View {
    let serviceID: String
    let fromCRS: String
    let toCRS: String
    let departureTime: String
    let destinationName: String

    @EnvironmentObject var depStore: DeparturesStore
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4
    @AppStorage("railwayMapSource") private var railwayMapSourceRaw = RailwayMapSource.ordnanceSurvey.rawValue

    @State private var timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var retryClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var progressClock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var currentProgress: ServiceProgressEstimate = .unavailable
    @State private var railwayRoute: ServiceRailwayRoute?
    @State private var railwayRouteStationRange: ClosedRange<Int>?
    @State private var railwayRouteError: String?
    @State private var isLoadingRailwayRoute = false
    @State private var selectedPresentation: ServiceMapPresentation = .map
    @State private var hasFinishedInitialLoad = false
    @State private var isRetrying = false
    @State private var retryAttempt = 0
    @State private var nextRetryAt: Date?
    @State private var currentTime = Date()
    @State private var loadRequestID = UUID()
    @State private var hasCenteredOnCurrentPosition = false

    private var hasCallingPoints: Bool {
        !stations().isEmpty
    }

    private var currentIndex: Double {
        currentProgress.floatingIndex
    }

    private var routeRequestKey: String {
        let normalizedFrom = fromCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedTo = toCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ([railwayMapSource.rawValue, normalizedFrom, normalizedTo] + stations().map(\.crs))
            .joined(separator: "|")
    }

    private var railwayMapSource: RailwayMapSource {
        RailwayMapSource(rawValue: railwayMapSourceRaw) ?? .ordnanceSurvey
    }

    private var railwayRouteStations: [CallingPoint] {
        guard let range = railwayRouteStationRange else { return [] }
        return Array(stations()[range])
    }

    private var railwayMapProgress: ServiceProgressEstimate {
        guard let range = railwayRouteStationRange,
              currentProgress.isAvailable else {
            return .unavailable
        }
        if currentProgress.nextStationIndex < range.lowerBound {
            return .unavailable
        }
        if currentProgress.previousStationIndex > range.upperBound {
            let lastIndex = range.count - 1
            return ServiceProgressEstimate(
                previousStationIndex: lastIndex,
                nextStationIndex: lastIndex,
                fraction: 0
            )
        }
        let previous = min(max(currentProgress.previousStationIndex, range.lowerBound), range.upperBound)
        let next = min(max(currentProgress.nextStationIndex, range.lowerBound), range.upperBound)
        return ServiceProgressEstimate(
            previousStationIndex: previous - range.lowerBound,
            nextStationIndex: next - range.lowerBound,
            fraction: currentProgress.fraction
        )
    }

    private var estimatedTrainCoordinateOutsideRailwayRoute: CLLocationCoordinate2D? {
        guard let range = railwayRouteStationRange,
              currentProgress.isAvailable,
              currentProgress.previousStationIndex < range.lowerBound
                || currentProgress.nextStationIndex < range.lowerBound
                || currentProgress.previousStationIndex > range.upperBound
                || currentProgress.nextStationIndex > range.upperBound else {
            return nil
        }

        let callingPoints = stations()
        guard callingPoints.indices.contains(currentProgress.previousStationIndex),
              callingPoints.indices.contains(currentProgress.nextStationIndex),
              let previous = stationCoordinate(for: callingPoints[currentProgress.previousStationIndex].crs),
              let next = stationCoordinate(for: callingPoints[currentProgress.nextStationIndex].crs) else {
            return nil
        }

        let fraction = min(max(currentProgress.fraction, 0), 1)
        return CLLocationCoordinate2D(
            latitude: previous.latitude + ((next.latitude - previous.latitude) * fraction),
            longitude: previous.longitude + ((next.longitude - previous.longitude) * fraction)
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if hasCallingPoints {
                    VStack(spacing: 0) {
                        headerView
                            .background(.ultraThinMaterial)
                        Divider()

                        if !isBusService {
                            railwaySourcePicker
                        }

                        if let railwayRouteError {
                            Label(railwayRouteError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.top, 6)
                        }

                        if let railwayRoute {
                            Picker("Service view", selection: $selectedPresentation) {
                                ForEach(ServiceMapPresentation.allCases) { presentation in
                                    Text(presentation.rawValue).tag(presentation)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.horizontal)
                            .padding(.vertical, 8)

                            if selectedPresentation == .map {
                                ServiceRailwayMapView(
                                    route: railwayRoute,
                                    stations: railwayRouteStations,
                                    progress: railwayMapProgress,
                                    estimatedTrainCoordinate: estimatedTrainCoordinateOutsideRailwayRoute,
                                    fromCRS: fromCRS,
                                    toCRS: toCRS,
                                    dataSource: railwayMapSource
                                )
                            } else {
                                callingPointsView(using: proxy)
                            }
                        } else {
                            callingPointsView(using: proxy)
                                .overlay(alignment: .topTrailing) {
                                    if isLoadingRailwayRoute {
                                        ProgressView()
                                            .padding(12)
                                            .accessibilityLabel("Loading geographic railway map")
                                    }
                                }
                        }
                    }
                } else if !hasFinishedInitialLoad {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading service information…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("Service information unavailable", systemImage: "tram.fill")
                    } description: {
                        VStack(spacing: 8) {
                            Text("National Rail calling-point data can't be found for this train.")
                            if isRetrying {
                                HStack(spacing: 6) {
                                    ProgressView()
                                    Text(retryStatusText)
                                }
                            }
                        }
                    } actions: {
                        Button("Try again now") {
                            loadRequestID = UUID()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("\(departureTime) to \(destinationName)")
            .onReceive(timer) { _ in
                guard hasCallingPoints else { return }
                Task {
                    await depStore.ensureServiceDetails(for: [serviceID], force: true)
                    recalcCurrentIndex()
                }
            }
            .onReceive(retryClock) { now in
                guard isRetrying else { return }
                currentTime = now
            }
            .onReceive(progressClock) { now in
                guard hasCallingPoints else { return }
                recalcCurrentIndex(at: now)
            }
            .task(id: loadRequestID) {
                await loadServiceDetails()
            }
            .task(id: serviceID) {
                guard StationsService.shared.stations.isEmpty else { return }
                try? await StationsService.shared.loadStations()
                recalcCurrentIndex()
            }
            .task(id: routeRequestKey) {
                await loadRailwayRoute()
            }
        }
    }

    private func callingPointsView(using proxy: ScrollViewProxy) -> some View {
        ScrollView {
            stationsList
                .padding(.vertical, 12)
        }
        .task(id: currentIndex >= 0) {
            await centerOnCurrentPosition(using: proxy)
        }
    }

    private func loadRailwayRoute() async {
        let callingPoints = stations()
        guard !isBusService, callingPoints.count >= 2 else {
            railwayRoute = nil
            railwayRouteStationRange = nil
            railwayRouteError = nil
            return
        }

        let requestedSource = railwayMapSource
        let routingService = RailwayRoutingService.service(for: requestedSource)
        let fullRange = 0...(callingPoints.count - 1)
        let selectedRange = selectedCallingPointRange(in: callingPoints)
        railwayRoute = nil
        railwayRouteStationRange = nil
        railwayRouteError = nil
        isLoadingRailwayRoute = true
        defer { isLoadingRailwayRoute = false }
        do {
            let route = try await routingService.route(
                forStationCRSs: callingPoints.map(\.crs)
            )
            guard !Task.isCancelled else { return }
            railwayRoute = route
            railwayRouteStationRange = fullRange
            selectedPresentation = .map
        } catch let fullRouteError {
            guard !Task.isCancelled else { return }
            guard let selectedRange,
                  selectedRange.count >= 2,
                  selectedRange != fullRange else {
                handleRailwayRouteFailure(fullRouteError, source: requestedSource)
                return
            }
            do {
                let selectedCallingPoints = Array(callingPoints[selectedRange])
                let route = try await routingService.route(
                    forStationCRSs: selectedCallingPoints.map(\.crs)
                )
                guard !Task.isCancelled else { return }
                railwayRoute = route
                railwayRouteStationRange = selectedRange
                selectedPresentation = .map
            } catch {
                guard !Task.isCancelled else { return }
                handleRailwayRouteFailure(error, source: requestedSource)
            }
        }
    }

    private func selectedCallingPointRange(in callingPoints: [CallingPoint]) -> ClosedRange<Int>? {
        let normalizedFrom = fromCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedTo = toCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let start = callingPoints.firstIndex(where: {
            $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedFrom
        }), let end = callingPoints.indices.first(where: { index in
            index >= start
                && callingPoints[index].crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedTo
        }) else {
            return nil
        }
        return start...end
    }

    private func handleRailwayRouteFailure(_ error: Error, source: RailwayMapSource) {
        railwayRoute = nil
        railwayRouteStationRange = nil
        railwayRouteError = "\(source.shortName) map unavailable: \(error.localizedDescription)"
        selectedPresentation = .callingPoints
        #if DEBUG
        print(
            "🗺️ [ServiceMapView] \(source.shortName) railway route unavailable: "
            + error.localizedDescription
        )
        #endif
    }

    private var railwaySourcePicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Railway map data")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Railway map data", selection: $railwayMapSourceRaw) {
                ForEach(RailwayMapSource.allCases) { source in
                    Text(source.shortName)
                        .tag(source.rawValue)
                        .accessibilityLabel(source.displayName)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: railwayMapSourceRaw) { _, _ in
                selectedPresentation = .map
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func loadServiceDetails() async {
        var attempt = 0
        repeat {
            attempt += 1
            retryAttempt = attempt
            nextRetryAt = nil
            let receivedCallingPoints = await depStore.ensureServiceDetails(for: [serviceID], force: true)
            recalcCurrentIndex()
            hasFinishedInitialLoad = true

            if receivedCallingPoints && hasCallingPoints {
                isRetrying = false
                nextRetryAt = nil
                return
            }

            isRetrying = true
            let delay = retryDelay(for: attempt)
            nextRetryAt = Date().addingTimeInterval(delay)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        } while !Task.isCancelled
    }

    private func retryDelay(for attempt: Int) -> TimeInterval {
        switch attempt {
        case 1: return 5
        case 2: return 10
        default: return 20
        }
    }

    private var retryStatusText: String {
        guard let nextRetryAt else {
            return "Checking National Rail for service information…"
        }
        let seconds = max(1, Int(ceil(nextRetryAt.timeIntervalSince(currentTime))))
        return "National Rail data unavailable — retry \(retryAttempt + 1) in \(seconds)s"
    }

    // MARK: - Header
    private var headerView: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title is also used in the nav bar, but include here for context on scroll
            Text(routeTitle())
                .font(.title2).bold()

            if isBusService {
                HStack(spacing: 6) {
                    Image(systemName: "bus")
                    Text("Bus service")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            } else if let length = serviceLength(), length > 0 {
                TrainLengthIndicator(
                    cars: length,
                    warningThreshold: minShortTrainCars,
                    carriageLoading: depStore.loadingDetailsByServiceId[serviceID]?.freshCoaches
                )
            } else {
                HStack(spacing: 6) {
                    Text("Train length unknown")
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let platform = platformInfo() {
                Text(platform)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let arrival = arrivalInfo() {
                Text(arrival)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let op = serviceOperator() {
                Text("Operator: \(op)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let status = serviceStatus()
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Circle()
                    .fill(status.color)
                    .frame(width: 8, height: 8)
                Text(status.text)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let info = delayOrCancelInfo() {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text(info)
                        .font(.caption)
                }
                .padding(8)
                .background(Color(.systemYellow).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Divider().padding(.top, 4)
        }
        .padding(.horizontal)
        .padding(.top, 4)
    }

    private var stationsList: some View {
        let list = stations()
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<max(0, list.count), id: \.self) { index in
                let s = list[index]
                let frac = currentIndex - floor(currentIndex)
                // Use a small window around each station to render the dot on the station itself
                let epsilon = 0.02
                let atPrev = (index == Int(floor(currentIndex)) && frac >= 0 && frac <= epsilon)
                let atNext = (index == Int(ceil(currentIndex)) && frac >= (1 - epsilon) && frac <= 1)
                let isAtThisStation = atPrev || atNext || abs(currentIndex - Double(index)) < 0.0001
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().stroke(Color.gray.opacity(0.6), lineWidth: 2))
                        if isAtThisStation {
                            PulsingDot().transition(.opacity)
                        }
                    }
                    .id("station-\(index)")

                    VStack(alignment: .leading, spacing: 2) {
                        let delayMins = delayMinutes(for: s)
                        let futureColor: Color = {
                            if let et = s.et?.lowercased(), et == "delayed" { return .red }
                            return colorForDelayMinutes(delayMins)
                        }()
                        let floorIdx = Int(floor(currentIndex))
                        // A station is future only if it is strictly after the current
                        // segment's starting station. When traveling between A (floorIdx)
                        // and B (ceilIdx), A should not be highlighted as future.
                        let isFuture = index > floorIdx
                        let nameColor: Color = {
                            if s.isCancelledAtStation { return .red }
                            if isAtThisStation { return .primary }
                            if isFuture { return futureColor }
                            return .secondary
                        }()
                        let timeColor: Color = {
                            if s.isCancelledAtStation { return .red }
                            if isAtThisStation { return .secondary }
                            if isFuture { return futureColor }
                            return .secondary
                        }()
                        Text(s.locationName)
                            .font(.body)
                            .foregroundStyle(nameColor)
                            .strikethrough(s.isCancelledAtStation, color: nameColor)
                        if !s.isCancelledAtStation {
                            Text(timeLabel(for: s, isFinal: index == list.count - 1))
                                .font(.caption)
                                .foregroundStyle(timeColor)
                        }
                    }
                }
                .padding(.vertical, 9)
                .padding(.leading, 6)

                // Connector segment (except after last)
                if index < list.count - 1 {
                    let progress = CGFloat(max(0, min(1, currentIndex - floor(currentIndex))))
                    let showDot = floor(currentIndex) == Double(index) &&
                                  progress > CGFloat(epsilon) && progress < CGFloat(1 - epsilon)
                    ConnectorSegment(height: 36, showDot: showDot, progress: progress)
                        .id("seg-\(index)")
                }
            }
        }
        .background(
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 2)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
    }

    // Build stations list using the combined previous/current/subsequent points
    private func stations() -> [CallingPoint] {
        guard let details = depStore.serviceDetailsById[serviceID] else { return [] }
        return details.allStations
    }

    private func stationCoordinate(for crs: String) -> CLLocationCoordinate2D? {
        let normalizedCRS = crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let station = StationsService.shared.stations.first(where: {
            $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedCRS
        }), station.hasUsableCoordinate else {
            return nil
        }
        return station.coordinate
    }

    private func recalcCurrentIndex(at now: Date = Date()) {
        currentProgress = ServiceProgressEstimator.estimate(for: stations(), at: now)
    }

    // MARK: - Helpers for header
    private func routeTitle() -> String {
        let list = stations()
        guard let first = list.first?.locationName, let last = list.last?.locationName else { return "Service map" }
        return "\(first) → \(last)"
    }

    private func serviceOperator() -> String? {
        guard let d = depStore.serviceDetailsById[serviceID] else { return nil }
        return d.operator
    }

    private func serviceLength() -> Int? {
        guard let d = depStore.serviceDetailsById[serviceID] else { return nil }
        return d.length
    }

    private var isBusService: Bool {
        depStore.serviceDetailsById[serviceID]?.serviceType.lowercased() == "bus"
    }

    private func serviceStatus() -> (text: String, color: Color) {
        guard let details = depStore.serviceDetailsById[serviceID] else {
            return ("Live status unavailable", .secondary)
        }
        if details.isCancelled == true || stations().allSatisfy(\.isCancelledAtStation) {
            return ("Service cancelled", .red)
        }
        if let live = computeLiveStatus(from: details) {
            let color: Color = live.delayMinutes >= 5 ? .red : (live.delayMinutes > 0 ? .yellow : .green)
            return (live.text, color)
        }
        return ("Live status unavailable", .secondary)
    }

    private func platformInfo() -> String? {
        guard !isBusService, let details = depStore.serviceDetailsById[serviceID] else { return nil }
        let platform = details.platform?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayedPlatform = platform?.isEmpty == false ? platform ?? "TBC" : "TBC"
        let estimatedDeparture = details.etd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let departureTime: String
        if let estimatedDeparture, !estimatedDeparture.isEmpty, estimatedDeparture != "On time" {
            departureTime = JourneyCardPresentation.arrivalTimeLabel(estimatedDeparture)
        } else {
            departureTime = details.std ?? "TBC"
        }
        return "Expected to depart \(details.locationName) at \(departureTime) (platform \(displayedPlatform))"
    }

    private func arrivalInfo() -> String? {
        let normalizedDestination = toCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let destination = stations().first {
            $0.crs.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == normalizedDestination
        } ?? stations().last
        guard let destination else { return nil }
        if destination.isCancelledAtStation {
            return "Arrival at \(destination.locationName) cancelled"
        }
        return "Expected to arrive \(displayTime(for: destination)) at \(destination.locationName)"
    }

    private func displayTime(for station: CallingPoint) -> String {
        if let actual = station.at, actual != "Cancelled" {
            return actual == "On time" ? station.st : actual
        }
        if let estimated = station.et, estimated != "Cancelled" {
            return estimated == "On time" ? station.st : JourneyCardPresentation.arrivalTimeLabel(estimated)
        }
        return station.st
    }

    private func delayOrCancelInfo() -> String? {
        guard let d = depStore.serviceDetailsById[serviceID] else { return nil }
        if let reason = d.delayReason, !reason.isEmpty { return reason }
        if let reason = d.cancelReason, !reason.isEmpty { return reason }
        return nil
    }

    private func anchorIDForScroll() -> String? {
        guard currentIndex >= 0 else { return nil }
        let frac = currentIndex - floor(currentIndex)
        if frac < 0.5 { return "station-\(Int(floor(currentIndex)))" }
        return "seg-\(Int(floor(currentIndex)))"
    }

    @MainActor
    private func centerOnCurrentPosition(using proxy: ScrollViewProxy) async {
        guard !hasCenteredOnCurrentPosition, let anchor = anchorIDForScroll() else { return }
        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(anchor, anchor: .center)
        }
        hasCenteredOnCurrentPosition = true
    }

    private func timeLabel(for s: CallingPoint, isFinal: Bool) -> String {
        // Prefer at (actual) then et, else st; then append delay minutes if any
        let base: String
        if let at = s.at, at != "Cancelled" { base = (at == "On time" ? s.st : at) }
        else if let et = s.et, et != "Cancelled" { base = (et == "On time" ? s.st : et) }
        else { base = s.st }

        let mins = delayMinutes(for: s)
        if mins > 0 { return "\(base) (\(mins) minute\(mins == 1 ? "" : "s") late)" }
        return base
    }

    private func delayMinutes(for s: CallingPoint) -> Int {
        // Same logic used elsewhere (LiveStatus/StatusColoring)
        if let at = s.at, at != "Cancelled" {
            if at == "On time" { return 0 }
            if let a = parseHHmm(at), let sch = parseHHmm(s.st) { return max(0, Int(a.timeIntervalSince(sch) / 60)) }
        }
        if let et = s.et, et != "On time", et != "Cancelled" {
            if let e = parseHHmm(et), let sch = parseHHmm(s.st) { return max(0, Int(e.timeIntervalSince(sch) / 60)) }
        }
        return 0
    }

    private func parseHHmm(_ t: String?) -> Date? {
        guard let t = t else { return nil }
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        var dc = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        dc.hour = h; dc.minute = m
        return Calendar.current.date(from: dc)
    }
}

private struct ConnectorSegment: View {
    let height: CGFloat
    let showDot: Bool
    let progress: CGFloat // 0..1 from previous to next

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 2)
                .padding(.leading, 10)
            if showDot {
                PulsingDot()
                    .offset(x: 5, y: height * progress - height / 2)
                    .animation(.easeInOut(duration: 1.8), value: progress)
            }
        }
        .frame(height: height)
    }
}

private struct PulsingDot: View {
    @State private var pulse = false
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 12, height: 12)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
            Circle()
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
                .frame(width: 12, height: 12)
                .scaleEffect(pulse ? 1.8 : 1.0)
                .opacity(pulse ? 0.0 : 0.7)
                .onAppear {
                    withAnimation(Animation.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                        pulse = true
                    }
                }
        }
    }
}
