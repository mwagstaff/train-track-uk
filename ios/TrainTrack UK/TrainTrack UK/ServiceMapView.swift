import SwiftUI
import Combine
import CoreLocation

@MainActor
private enum RailwayMapPresentationGate {
    private static var hasPresentedMap = false

    static func waitForFirstMap(reduceMotion: Bool) async {
        guard !hasPresentedMap else { return }
        do {
            if reduceMotion {
                await Task.yield()
            } else {
                // Avoid constructing the first MapKit view during the navigation push.
                try await Task.sleep(for: .milliseconds(450))
            }
        } catch {
            return
        }
    }

    static func markMapPresented() {
        hasPresentedMap = true
    }
}

struct ServiceMapView: View {
    private static let trainLocationEstimateMessage = "Train locations are estimates only"
    private static let initialServiceDetailsFreshness: TimeInterval = 15

    let serviceID: String
    let fromCRS: String
    let toCRS: String
    let departureTime: String
    let destinationName: String
    let isHistorical: Bool
    let fallbackCallingPoints: [CallingPoint]
    let historicalArrivalTime: String?

    @EnvironmentObject var depStore: DeparturesStore
    @EnvironmentObject private var notificationStore: NotificationSubscriptionStore
    @EnvironmentObject private var holidayMode: HolidayModeStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("minShortTrainCars") private var minShortTrainCars: Int = 4

    @State private var timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
    @State private var retryClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var progressClock = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    @State private var currentProgress: ServiceProgressEstimate = .unavailable
    @State private var railwayRoute: ServiceRailwayRoute?
    @State private var additionalRailwayRoutes: [ServiceRailwayMapBranch] = []
    @State private var railwayRouteStationRange: ClosedRange<Int>?
    @State private var railwayRouteError: String?
    @State private var isLoadingRailwayRoute = false
    @State private var isMapPresentationReady = false
    @State private var isShowingTrainInfo = false
    @State private var isShowingEstimateNotice = true
    @State private var hasFinishedInitialLoad = false
    @State private var isRetrying = false
    @State private var retryAttempt = 0
    @State private var nextRetryAt: Date?
    @State private var currentTime = Date()
    @State private var loadRequestID = UUID()

    init(
        serviceID: String,
        fromCRS: String,
        toCRS: String,
        departureTime: String,
        destinationName: String,
        isHistorical: Bool = false,
        fallbackCallingPoints: [CallingPoint] = [],
        historicalArrivalTime: String? = nil
    ) {
        self.serviceID = serviceID
        self.fromCRS = fromCRS
        self.toCRS = toCRS
        self.departureTime = departureTime
        self.destinationName = destinationName
        self.isHistorical = isHistorical
        self.fallbackCallingPoints = fallbackCallingPoints
        self.historicalArrivalTime = historicalArrivalTime
    }

    private var hasCallingPoints: Bool {
        !stations().isEmpty
    }

    private var isMapLoading: Bool {
        !isMapPresentationReady
            || !hasFinishedInitialLoad
            || isLoadingRailwayRoute
            || (
                hasCallingPoints
                    && !isBusService
                    && railwayRoute == nil
                    && railwayRouteError == nil
            )
    }

    private var estimateNoticeBottomPadding: CGFloat {
        let visibleBottomBannerCount = (notificationStore.liveSessions.isEmpty ? 0 : 1)
            + (holidayMode.isEnabled ? 1 : 0)
        guard visibleBottomBannerCount > 0 else { return 32 }
        return 120 + (CGFloat(visibleBottomBannerCount - 1) * 68)
    }

    private var routeRequestKey: String {
        let normalizedFrom = fromCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let normalizedTo = toCRS.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let branches = stationBranches().map { branch in
            branch.map(\.crs).joined(separator: ",")
        }
        return ([normalizedFrom, normalizedTo] + branches)
            .joined(separator: "|")
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

    private var highlightedTravelRange: ClosedRange<Int>? {
        guard isHistorical else { return nil }
        return selectedCallingPointRange(in: railwayRouteStations)
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
        Group {
            if isMapLoading {
                mapLoadingView
                    .transition(.opacity)
            } else if let railwayRoute {
                ServiceRailwayMapView(
                    route: railwayRoute,
                    stations: railwayRouteStations,
                    additionalRoutes: additionalRailwayRoutes,
                    progress: railwayMapProgress,
                    estimatedTrainCoordinate: estimatedTrainCoordinateOutsideRailwayRoute,
                    currentDelayMinutes: currentDelayMinutes,
                    fromCRS: fromCRS,
                    toCRS: toCRS,
                    highlightedTravelRange: highlightedTravelRange,
                    historicalArrivalTime: historicalArrivalTime
                )
                .onAppear {
                    RailwayMapPresentationGate.markMapPresented()
                }
                .transition(.opacity)
            } else {
                ContentUnavailableView {
                    Label(
                        isBusService ? "Railway map unavailable" : "Service map unavailable",
                        systemImage: isBusService ? "bus.fill" : "tram.fill"
                    )
                } description: {
                    VStack(spacing: 8) {
                        Text(mapUnavailableDescription)
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
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .disablesHorizontalTabSwipe()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !isMapLoading {
                    Button {
                        isShowingTrainInfo = true
                    } label: {
                        Label("Train info", systemImage: "info.circle")
                    }
                    .accessibilityHint("Shows service times, train length and live status")
                }
            }
        }
        .sheet(isPresented: $isShowingTrainInfo) {
            trainInfoView
                .presentationDetents([.height(360)])
                .presentationContentInteraction(.scrolls)
                .presentationDragIndicator(.visible)
        }
        .overlay(alignment: .bottom) {
            if isShowingEstimateNotice && !isHistorical {
                estimateNoticeBanner
                    .transition(.opacity)
            }
        }
        .onReceive(timer) { _ in
            guard hasCallingPoints, !isHistorical else { return }
            Task {
                await depStore.ensureServiceDetails(
                    for: [serviceID],
                    force: true,
                    context: serviceDetailsLookupContext
                )
                recalcCurrentIndex()
            }
        }
        .onReceive(retryClock) { now in
            guard isRetrying else { return }
            currentTime = now
        }
        .onReceive(progressClock) { now in
            guard hasCallingPoints, !isHistorical else { return }
            recalcCurrentIndex(at: now)
        }
        .task {
            await RailwayMapPresentationGate.waitForFirstMap(reduceMotion: reduceMotion)
            guard !Task.isCancelled else { return }
            isMapPresentationReady = true
        }
        .task(id: loadRequestID) {
            await loadServiceDetails()
        }
        .task(id: serviceID) {
            await displayEstimateNotice()
        }
        .task(id: routeRequestKey) {
            let requestKey = routeRequestKey
            await loadRailwayRoute(requestKey: requestKey)
        }
    }

    private var mapLoadingView: some View {
        ZStack {
            Color(.systemBackground)
            VStack(spacing: 12) {
                ProgressView()
                Text(hasFinishedInitialLoad ? "Loading route map…" : "Loading service information…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var estimateNoticeBanner: some View {
        Label(Self.trainLocationEstimateMessage, systemImage: "info.circle")
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
            .padding(.horizontal, 16)
            .padding(.bottom, estimateNoticeBottomPadding)
            .accessibilityElement(children: .combine)
    }

    @MainActor
    private func displayEstimateNotice() async {
        guard !isHistorical else {
            isShowingEstimateNotice = false
            return
        }
        isShowingEstimateNotice = true
        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            return
        }

        if reduceMotion {
            isShowingEstimateNotice = false
        } else {
            withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.3)) {
                isShowingEstimateNotice = false
            }
        }
    }

    private func loadRailwayRoute(requestKey: String) async {
        guard requestKey == routeRequestKey else { return }
        let callingPoints = stations()
        guard !isBusService, callingPoints.count >= 2 else {
            railwayRoute = nil
            additionalRailwayRoutes = []
            railwayRouteStationRange = nil
            railwayRouteError = nil
            return
        }

        let routingService = RailwayRoutingService.shared
        let fullRange = 0...(callingPoints.count - 1)
        let selectedRange = selectedCallingPointRange(in: callingPoints)
        railwayRoute = nil
        additionalRailwayRoutes = []
        railwayRouteStationRange = nil
        railwayRouteError = nil
        isLoadingRailwayRoute = true
        defer {
            if requestKey == routeRequestKey {
                isLoadingRailwayRoute = false
            }
        }
        do {
            let route = try await routingService.route(
                forStationCRSs: callingPoints.map(\.crs)
            )
            guard !Task.isCancelled, requestKey == routeRequestKey else { return }
            railwayRoute = route
            railwayRouteStationRange = fullRange
            isLoadingRailwayRoute = false
            let branches = await loadAdditionalRailwayRoutes(
                routingService: routingService,
                primaryCallingPoints: callingPoints
            )
            guard !Task.isCancelled, requestKey == routeRequestKey else { return }
            additionalRailwayRoutes = branches
        } catch let fullRouteError {
            guard !Task.isCancelled, requestKey == routeRequestKey else { return }
            guard let selectedRange,
                  selectedRange.count >= 2,
                  selectedRange != fullRange else {
                handleRailwayRouteFailure(fullRouteError)
                return
            }
            do {
                let selectedCallingPoints = Array(callingPoints[selectedRange])
                let route = try await routingService.route(
                    forStationCRSs: selectedCallingPoints.map(\.crs)
                )
                guard !Task.isCancelled, requestKey == routeRequestKey else { return }
                railwayRoute = route
                railwayRouteStationRange = selectedRange
                isLoadingRailwayRoute = false
                let branches = await loadAdditionalRailwayRoutes(
                    routingService: routingService,
                    primaryCallingPoints: callingPoints
                )
                guard !Task.isCancelled, requestKey == routeRequestKey else { return }
                additionalRailwayRoutes = branches
            } catch {
                guard !Task.isCancelled, requestKey == routeRequestKey else { return }
                handleRailwayRouteFailure(error)
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

    private func loadAdditionalRailwayRoutes(
        routingService: RailwayRoutingService,
        primaryCallingPoints: [CallingPoint]
    ) async -> [ServiceRailwayMapBranch] {
        var routes: [ServiceRailwayMapBranch] = []

        for (index, branch) in stationBranches().dropFirst().enumerated() {
            guard !Task.isCancelled else { return routes }
            let divergentCallingPoints = divergentSuffix(
                of: branch,
                comparedWith: primaryCallingPoints
            )
            guard divergentCallingPoints.count >= 2 else { continue }

            do {
                let route = try await routingService.route(
                    forStationCRSs: divergentCallingPoints.map(\.crs)
                )
                guard !Task.isCancelled else { return routes }
                routes.append(ServiceRailwayMapBranch(
                    id: "branch-\(index)-\(divergentCallingPoints.last?.crs ?? "unknown")",
                    route: route,
                    stations: divergentCallingPoints
                ))
            } catch {
                #if DEBUG
                print(
                    "🗺️ [ServiceMapView] additional branch route unavailable: "
                    + error.localizedDescription
                )
                #endif
            }
        }

        return routes
    }

    private func divergentSuffix(
        of branch: [CallingPoint],
        comparedWith primary: [CallingPoint]
    ) -> [CallingPoint] {
        var sharedCount = 0
        while sharedCount < branch.count,
              sharedCount < primary.count,
              normalizedCRS(branch[sharedCount].crs) == normalizedCRS(primary[sharedCount].crs) {
            sharedCount += 1
        }

        let splitStationIndex = max(0, sharedCount - 1)
        guard branch.indices.contains(splitStationIndex) else { return [] }
        return Array(branch[splitStationIndex...])
    }

    private func handleRailwayRouteFailure(_ error: Error) {
        railwayRoute = nil
        additionalRailwayRoutes = []
        railwayRouteStationRange = nil
        railwayRouteError = error.localizedDescription
        #if DEBUG
        print(
            "🗺️ [ServiceMapView] railway route unavailable: "
            + error.localizedDescription
        )
        #endif
    }

    private func loadServiceDetails() async {
        if hasCallingPoints {
            recalcCurrentIndex()
            hasFinishedInitialLoad = true
            isRetrying = false
        }

        var attempt = 0
        repeat {
            attempt += 1
            retryAttempt = attempt
            nextRetryAt = nil
            let receivedCallingPoints = await depStore.ensureServiceDetails(
                for: [serviceID],
                freshFor: attempt == 1 ? Self.initialServiceDetailsFreshness : 0,
                context: serviceDetailsLookupContext
            )
            recalcCurrentIndex()
            hasFinishedInitialLoad = true

            if isHistorical {
                isRetrying = false
                nextRetryAt = nil
                return
            }

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

    private var trainInfoView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isBusService {
                        Text("Service type: Bus")
                            .foregroundStyle(.orange)
                    } else if let length = serviceLength(), length > 0 {
                        Text("Train length: \(length) car\(length == 1 ? "" : "s")")
                            .foregroundStyle(length < minShortTrainCars ? .yellow : .primary)
                    } else {
                        Text("Train length: Unknown")
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        if let platform = platformInfo() {
                            Text(platform)
                        }
                        if let arrival = arrivalInfo() {
                            Text(arrival)
                        }
                        if let op = serviceOperator() {
                            Text("Operator: \(op)")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                    let status = serviceStatus()
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(status.color)
                            .frame(width: 8, height: 8)
                        Text(status.text)
                    }
                    .font(.subheadline)

                    if let info = delayOrCancelInfo() {
                        Label(info, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.systemYellow).opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }

                    Divider()

                    if !isHistorical {
                        Label(Self.trainLocationEstimateMessage, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .navigationTitle("\(departureTime) to \(destinationName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingTrainInfo = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
    }

    // Build stations list using the combined previous/current/subsequent points
    private func stations() -> [CallingPoint] {
        stationBranches().first ?? fallbackCallingPoints
    }

    private func stationBranches() -> [[CallingPoint]] {
        guard let branches = depStore.serviceDetailsById[serviceID]?.stationBranches else {
            return fallbackCallingPoints.isEmpty ? [] : [fallbackCallingPoints]
        }
        let reordered: [[CallingPoint]]
        if let selectedIndex = branches.firstIndex(where: branchContainsSelectedJourney) {
            reordered = [branches[selectedIndex]] + branches.enumerated().compactMap { index, branch in
                index == selectedIndex ? nil : branch
            }
        } else {
            reordered = branches
        }
        guard isHistorical,
              !fallbackCallingPoints.isEmpty,
              let fetchedPrimary = reordered.first,
              fallbackCallingPoints.count >= fetchedPrimary.count else {
            return reordered
        }
        return [fallbackCallingPoints] + reordered.dropFirst()
    }

    private func branchContainsSelectedJourney(_ branch: [CallingPoint]) -> Bool {
        guard let start = branch.firstIndex(where: {
            normalizedCRS($0.crs) == normalizedCRS(fromCRS)
        }) else {
            return false
        }
        return branch.indices.contains { index in
            index >= start && normalizedCRS(branch[index].crs) == normalizedCRS(toCRS)
        }
    }

    private var serviceDetailsLookupContext: ServiceDetailsLookupContext? {
        guard let departure = depStore.departure(
            serviceID: serviceID,
            fromCRS: fromCRS,
            toCRS: toCRS
        ) else {
            return ServiceDetailsLookupContext(
                fromCRS: fromCRS,
                toCRS: toCRS,
                originCRS: nil,
                operator: nil,
                destinationCRSs: [toCRS],
                length: nil
            )
        }
        return ServiceDetailsLookupContext(
            fromCRS: fromCRS,
            toCRS: toCRS,
            originCRS: departure.origin?.first?.crs,
            operator: nil,
            destinationCRSs: departure.destination.compactMap(\.crs),
            length: departure.length
        )
    }

    private func stationCoordinate(for crs: String) -> CLLocationCoordinate2D? {
        let targetCRS = normalizedCRS(crs)
        guard let station = StationsService.shared.stations.first(where: {
            normalizedCRS($0.crs) == targetCRS
        }), station.hasUsableCoordinate else {
            return nil
        }
        return station.coordinate
    }

    private func normalizedCRS(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func recalcCurrentIndex(at now: Date = Date()) {
        currentProgress = isHistorical
            ? .unavailable
            : ServiceProgressEstimator.estimate(for: stations(), at: now)
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

    private var currentDelayMinutes: Int? {
        guard let details = depStore.serviceDetailsById[serviceID],
              let live = computeLiveStatus(from: details),
              live.delayMinutes > 0 else {
            return nil
        }
        return live.delayMinutes
    }

    private var mapUnavailableDescription: String {
        if isBusService {
            return "Bus replacement services don't have a railway route to display."
        }
        if let railwayRouteError {
            return railwayRouteError
        }
        return "Sorry, National Rail route data can't be found for this train right now. Please try again later."
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

}
