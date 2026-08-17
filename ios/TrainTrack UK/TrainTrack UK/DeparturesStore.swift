import Foundation
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class DeparturesStore: ObservableObject {
    static let shared = DeparturesStore()

    @Published private(set) var departuresByPair: [String: [DepartureV2]] = [:]
    @Published private(set) var dataAvailabilityByPair: [String: JourneyDataAvailability] = [:]
    @Published private(set) var serviceDetailsById: [String: ServiceDetails] = [:]
    @Published private(set) var loadingDetailsByServiceId: [String: ServiceLoadingV1] = [:]
    @Published private(set) var isInitialLoadInProgress = true

    private var timerCancellable: AnyCancellable?
    private var journeysCancellable: AnyCancellable?
    private var initialRefreshTask: Task<Void, Never>?
    private var lastWidgetReloadAt: Date? = nil
    private var loadingRefreshInProgress = false
    private var serviceDetailsFetchedAt: [String: Date] = [:]
    private var serviceDetailsRequestsByID: [String: ServiceDetailsRequest] = [:]

    private struct ServiceDetailsRequest {
        let token: UUID
        let task: Task<Void, Never>
    }

    private init() {
        // Remove data created by the retired pinned-journey feature.
        UserDefaults(suiteName: "group.dev.skynolimit.traintrack")?
            .removeObject(forKey: "pinned_departures_v1")
    }

    func startPolling(journeyStore: JourneyStore) {
        if timerCancellable != nil || journeysCancellable != nil {
            return
        }
        if departuresByPair.isEmpty {
            isInitialLoadInProgress = true
        }
        // React to journey changes after the explicit startup refresh path has run.
        journeysCancellable = journeyStore.$journeys
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] journeys in
                guard let self else { return }
                Task { await self.refresh(for: journeys) }
            }
        initialRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isInitialLoadInProgress = false }
            await self.refreshPrioritizingFavourites(for: journeyStore.journeys)
        }
        // Every 20 seconds
        timerCancellable = Timer.publish(every: 20, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.refresh(for: journeyStore.journeys) }
            }
    }

    func stopPolling() {
        timerCancellable?.cancel()
        timerCancellable = nil
        journeysCancellable?.cancel()
        journeysCancellable = nil
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
    }

    func refreshNow(journeyStore: JourneyStore) {
        Task { await refresh(for: journeyStore.journeys) }
    }


    func refreshSpecificJourney(fromCRS: String, toCRS: String) async {
        let pairs = [(fromCRS, toCRS)]
        do {
            let snapshots = try await NetworkServicePhone.shared.fetchDeparturesAggregated(pairs: pairs)
            let departures = applyDepartureSnapshots(snapshots, replacingExistingDepartures: false)
            await refreshLoading(for: departures)
        } catch {
            markDepartureRefreshFailed(for: pairs)
        }
    }

    private func pairKey(from: String, to: String) -> String { "\(from)_\(to)" }

    private func journeyPairs(from journeys: [Journey]) -> [(String, String)] {
        journeys.map { ($0.fromStation.crs, $0.toStation.crs) }
    }

    private func uniquePairs(_ pairs: [(String, String)]) -> [(String, String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for p in pairs {
            let k = pairKey(from: p.0, to: p.1)
            if !seen.contains(k) {
                seen.insert(k)
                result.append(p)
            }
        }
        return result
    }

    private func refresh(for journeys: [Journey]) async {
        await refresh(
            for: journeys,
            replacingExistingDepartures: true,
            delayBeforeEachBatch: true
        )
    }

    private func refreshPrioritizingFavourites(for journeys: [Journey]) async {
        let favouriteJourneys = journeys.filter(\.favorite)
        guard !favouriteJourneys.isEmpty else {
            await refresh(for: journeys)
            return
        }

        await refresh(
            for: favouriteJourneys,
            replacingExistingDepartures: false,
            delayBeforeEachBatch: false
        )
        guard !Task.isCancelled else { return }

        let remainingJourneys = journeys.filter { !$0.favorite }
        if remainingJourneys.isEmpty {
            return
        }

        await refresh(
            for: remainingJourneys,
            replacingExistingDepartures: false,
            delayBeforeEachBatch: false
        )
    }

    private func refresh(
        for journeys: [Journey],
        replacingExistingDepartures: Bool,
        delayBeforeEachBatch: Bool
    ) async {
        let pairs = uniquePairs(journeyPairs(from: journeys))
        if pairs.isEmpty {
            if replacingExistingDepartures {
                departuresByPair = [:]
                dataAvailabilityByPair = [:]
                loadingDetailsByServiceId = [:]
            }
            return
        }
        do {
            let snapshots = try await NetworkServicePhone.shared.fetchDeparturesAggregated(
                pairs: pairs,
                delayBeforeEachBatch: delayBeforeEachBatch
            )
            let departures = applyDepartureSnapshots(
                snapshots,
                replacingExistingDepartures: replacingExistingDepartures
            )
            reloadClosestFavouriteWidgetIfNeeded()
            await refreshLoading(for: departures)
        } catch {
            markDepartureRefreshFailed(for: pairs)
        }
    }

    private func reloadClosestFavouriteWidgetIfNeeded() {
        // Nudge widgets to refresh, throttled to about once per minute while app is active.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let now = Date()
            if self.lastWidgetReloadAt == nil || now.timeIntervalSince(self.lastWidgetReloadAt!) > 60 {
                self.lastWidgetReloadAt = now
                WidgetCenter.shared.reloadTimelines(ofKind: "ClosestFavouriteWidget")
            }
        }
    }

    private func applyDepartureSnapshots(
        _ snapshots: [String: JourneyDeparturesSnapshot],
        replacingExistingDepartures: Bool
    ) -> [String: [DepartureV2]] {
        var nextDepartures = replacingExistingDepartures ? [:] : departuresByPair
        var nextAvailability = replacingExistingDepartures ? [:] : dataAvailabilityByPair

        for (key, snapshot) in snapshots {
            let existingDepartures = departuresByPair[key] ?? []
            let fetchedDepartures = snapshot.dataStatus == .unavailable && snapshot.departures.isEmpty
                ? existingDepartures
                : snapshot.departures
            nextDepartures[key] = departuresRetainingLastKnownPlatforms(
                fetchedDepartures,
                existing: existingDepartures
            )
            nextAvailability[key] = JourneyDataAvailability(
                status: snapshot.dataStatus,
                lastSuccessfulUpdate: snapshot.lastSuccessfulUpdate
                    ?? successfulResponseFallbackDate(for: snapshot)
                    ?? dataAvailabilityByPair[key]?.lastSuccessfulUpdate
            )
        }

        departuresByPair = nextDepartures
        dataAvailabilityByPair = nextAvailability
        return nextDepartures
    }

    private func successfulResponseFallbackDate(for snapshot: JourneyDeparturesSnapshot) -> Date? {
        switch snapshot.dataStatus {
        case .live, .partial:
            return Date()
        case .stale, .unavailable:
            return nil
        }
    }

    private func markDepartureRefreshFailed(for pairs: [(String, String)]) {
        for pair in pairs {
            let key = pairKey(from: pair.0, to: pair.1)
            let previous = dataAvailabilityByPair[key]
            let hasLastKnownData = !(departuresByPair[key] ?? []).isEmpty
                || previous?.lastSuccessfulUpdate != nil
            dataAvailabilityByPair[key] = JourneyDataAvailability(
                status: hasLastKnownData ? .stale : .unavailable,
                lastSuccessfulUpdate: previous?.lastSuccessfulUpdate
            )
        }
    }

    private func departuresRetainingLastKnownPlatforms(
        _ departures: [DepartureV2],
        existing: [DepartureV2]
    ) -> [DepartureV2] {
        let previousPlatformsByServiceID: [String: String] = Dictionary(
            uniqueKeysWithValues: existing.compactMap { departure in
                guard let platform = normalizedPlatform(departure.platform) else {
                    return nil
                }
                return (departure.serviceID, platform)
            }
        )

        return departures.map { departure in
            guard normalizedPlatform(departure.platform) == nil,
                  let platform = previousPlatformsByServiceID[departure.serviceID] else {
                return departure
            }
            return departure.withPlatform(platform)
        }
    }

    private func normalizedPlatform(_ platform: String?) -> String? {
        guard let trimmed = platform?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    @discardableResult
    func ensureServiceDetails(
        for ids: [String],
        force: Bool = false,
        freshFor freshnessInterval: TimeInterval? = nil,
        context: ServiceDetailsLookupContext? = nil
    ) async -> Bool {
        let requestedIDs = Array(Set(ids.filter { !$0.isEmpty }))
        let now = Date()
        let targets = requestedIDs.filter { id in
            if force { return true }
            guard serviceDetailsById[id] != nil else { return true }
            guard let freshnessInterval else { return false }
            guard let fetchedAt = serviceDetailsFetchedAt[id] else { return true }
            return now.timeIntervalSince(fetchedAt) >= freshnessInterval
        }
        guard !targets.isEmpty else { return true }

        var pendingRequests: [UUID: Task<Void, Never>] = [:]
        var newTargets: [String] = []
        for id in targets {
            if let request = serviceDetailsRequestsByID[id] {
                pendingRequests[request.token] = request.task
            } else {
                newTargets.append(id)
            }
        }

        if !newTargets.isEmpty {
            let token = UUID()
            let task = Task { [weak self, newTargets, context] in
                let details: [String: ServiceDetails]
                do {
                    details = try await NetworkServicePhone.shared.fetchServiceDetailsAggregatedChunked(
                        ids: newTargets,
                        context: context
                    )
                } catch {
                    details = [:]
                }
                self?.finishServiceDetailsRequest(
                    token: token,
                    requestedIDs: newTargets,
                    details: details
                )
            }
            let request = ServiceDetailsRequest(token: token, task: task)
            for id in newTargets {
                serviceDetailsRequestsByID[id] = request
            }
            pendingRequests[token] = task
        }

        for task in pendingRequests.values {
            await task.value
        }
        return requestedIDs.allSatisfy { serviceDetailsById[$0] != nil }
    }

    private func finishServiceDetailsRequest(
        token: UUID,
        requestedIDs: [String],
        details: [String: ServiceDetails]
    ) {
        let ownedIDs = requestedIDs.filter {
            serviceDetailsRequestsByID[$0]?.token == token
        }
        guard !ownedIDs.isEmpty else { return }

        let fetchedAt = Date()
        var updatedDetails = serviceDetailsById
        var didUpdateDetails = false
        for id in ownedIDs {
            if let detail = details[id] {
                updatedDetails[id] = detail
                serviceDetailsFetchedAt[id] = fetchedAt
                didUpdateDetails = true
            }
            serviceDetailsRequestsByID[id] = nil
        }
        if didUpdateDetails {
            serviceDetailsById = updatedDetails
        }
    }

    func departures(for journey: Journey) -> [DepartureV2] {
        let key = pairKey(from: journey.fromStation.crs, to: journey.toStation.crs)
        return sortDepartures(departuresByPair[key] ?? [])
    }

    func dataAvailability(for journey: Journey) -> JourneyDataAvailability {
        let key = pairKey(from: journey.fromStation.crs, to: journey.toStation.crs)
        return dataAvailabilityByPair[key] ?? .live
    }

    func departure(serviceID: String, fromCRS: String, toCRS: String) -> DepartureV2? {
        departuresByPair[pairKey(from: fromCRS, to: toCRS)]?
            .first { $0.serviceID == serviceID }
    }

    private func sortDepartures(_ list: [DepartureV2]) -> [DepartureV2] {
        list.sorted(by: { lhs, rhs in
            // Sort by estimated time (HH:mm). If unavailable, fall back to scheduled.
            let l = bestComparableTime(lhs)
            let r = bestComparableTime(rhs)
            switch (l, r) {
            case let (li?, ri?):
                if li == ri { return lhs.serviceID < rhs.serviceID }
                return li < ri
            case (nil, nil): return lhs.serviceID < rhs.serviceID
            case (nil, _): return false
            case (_, nil): return true
            }
        })
    }

    private func bestComparableTime(_ d: DepartureV2) -> Date? {
        // Prefer estimated time if parseable, else scheduled
        if let t = parseHHmm(d.departureTime.estimated) { return t }
        return parseHHmm(d.departureTime.scheduled)
    }

    private func parseHHmm(_ t: String?) -> Date? {
        guard let t = t else { return nil }
        // Guard against non-time values
        let lower = t.lowercased()
        if lower == "delayed" || lower == "cancelled" || lower == "on time" { return nil }
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let now = Date()
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.hour = h; comps.minute = m
        guard var candidate = Calendar.current.date(from: comps) else { return nil }
        // If parsed time is more than 6 hours in the past, treat as next day (overnight services)
        if candidate < now && now.timeIntervalSince(candidate) > 6 * 3600 {
            candidate = Calendar.current.date(byAdding: .day, value: 1, to: candidate) ?? candidate
        }
        return candidate
    }

    private func refreshLoading(for departures: [String: [DepartureV2]]) async {
        guard !loadingRefreshInProgress else { return }
        let requests = loadingRequests(for: departures)
        pruneLoadingDetailsToCurrentDepartures()
        guard !requests.isEmpty else { return }
        loadingRefreshInProgress = true
        defer { loadingRefreshInProgress = false }
        do {
            let response = try await NetworkServicePhone.shared.fetchLoadingDetails(requests: requests)
            for (serviceID, details) in response {
                loadingDetailsByServiceId[serviceID] = details
            }
            pruneLoadingDetailsToCurrentDepartures()
        } catch {
            // Loading is an optional enhancement. Existing departure data remains usable.
        }
    }

    private func loadingRequests(for departures: [String: [DepartureV2]]) -> [LoadingDetailsRequestV1] {
        var seenServiceIDs = Set<String>()
        var requests: [LoadingDetailsRequestV1] = []
        for (key, services) in departures {
            let stations = key.split(separator: "_", maxSplits: 1).map(String.init)
            guard stations.count == 2 else { continue }
            for departure in services.prefix(8) where departure.serviceType.lowercased() != "bus" {
                guard seenServiceIDs.insert(departure.serviceID).inserted else { continue }
                requests.append(LoadingDetailsRequestV1(
                    serviceID: departure.serviceID,
                    from: stations[0],
                    to: stations[1],
                    scheduledDeparture: scheduledDepartureISO(for: departure),
                    destinationCRS: departure.destination.first?.crs,
                    length: departure.length
                ))
            }
        }
        return Array(requests.prefix(50))
    }

    private func scheduledDepartureISO(for departure: DepartureV2) -> String {
        guard let date = parseHHmm(departure.departureTime.scheduled) else {
            return departure.departureTime.scheduled
        }
        return ISO8601DateFormatter().string(from: date)
    }

    private func pruneLoadingDetailsToCurrentDepartures() {
        let activeServiceIDs = Set(departuresByPair.values.flatMap { $0.map(\.serviceID) })
        loadingDetailsByServiceId = loadingDetailsByServiceId.filter { activeServiceIDs.contains($0.key) }
    }

}
