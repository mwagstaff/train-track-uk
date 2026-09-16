import Combine
import Foundation

@MainActor
final class RecentServiceStore: ObservableObject {
    static let shared = RecentServiceStore()
    static let lookback: TimeInterval = 2 * 60 * 60
    static let upcomingAllowance: TimeInterval = 10 * 60

    @Published private(set) var departuresByPair: [String: [RecentDepartureV2]] = [:]
    @Published private(set) var isRefreshing = false

    private let defaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard
    private let storageKey = "recentServiceObservationsV1"
    private var activeRefreshCount = 0

    private init() {
        restore()
        prune()
    }

    func refresh(fromCRS: String, toCRS: String) async {
        activeRefreshCount += 1
        isRefreshing = true
        defer {
            activeRefreshCount -= 1
            isRefreshing = activeRefreshCount > 0
        }
        do {
            let result = try await NetworkServicePhone.shared.fetchRecentDepartures(
                pairs: [(from: fromCRS, to: toCRS)]
            )
            merge(result[pairKey(from: fromCRS, to: toCRS)] ?? [])
        } catch {
            prune()
        }
    }

    func observe(_ departures: [DepartureV2], fromCRS: String, toCRS: String, now: Date = Date()) {
        let observations = departures.compactMap { departure in
            Self.observation(departure, fromCRS: fromCRS, toCRS: toCRS, now: now)
        }
        merge(observations)
    }

    static func observation(_ departure: DepartureV2, fromCRS: String, toCRS: String, now: Date) -> RecentDepartureV2? {
        // Reading a cached board again does not make its estimates new observations.
        let observedAt = departure.timestamp ?? now
        guard let scheduled = JourneyHistoryTime.date(
            for: departure.departureTime.scheduled,
            near: observedAt
        ) else { return nil }
        let lower = now.addingTimeInterval(-lookback)
        let upper = now.addingTimeInterval(upcomingAllowance)
        guard (lower...upper).contains(scheduled) else { return nil }
        return RecentDepartureV2(
            serviceID: departure.serviceID,
            serviceType: departure.serviceType,
            fromCRS: fromCRS.uppercased(),
            toCRS: toCRS.uppercased(),
            scheduledDeparture: departure.departureTime.scheduled,
            estimatedDeparture: departure.departureTime.estimated,
            actualDeparture: departure.departureTime.actual,
            scheduledDepartureAt: scheduled,
            estimatedDepartureAt: JourneyHistoryTime.date(for: departure.departureTime.estimated, near: scheduled),
            actualDepartureAt: JourneyHistoryTime.date(for: departure.departureTime.actual, near: scheduled),
            platform: departure.platform,
            isCancelled: departure.isCancelled,
            lastObservedAt: observedAt
        )
    }

    func departures(fromCRS: String, toCRS: String, now: Date = Date()) -> [RecentDepartureV2] {
        let lower = now.addingTimeInterval(-Self.lookback)
        let upper = now.addingTimeInterval(Self.upcomingAllowance)
        return (departuresByPair[pairKey(from: fromCRS, to: toCRS)] ?? [])
            .filter { departure in
                let reference = departure.actualDepartureAt ?? departure.scheduledDepartureAt
                return (lower...upper).contains(reference)
            }
            .sorted { $0.scheduledDepartureAt > $1.scheduledDepartureAt }
    }

    private func merge(_ departures: [RecentDepartureV2]) {
        guard !departures.isEmpty else {
            prune()
            return
        }
        for departure in departures {
            let key = pairKey(from: departure.fromCRS, to: departure.toCRS)
            var current = departuresByPair[key] ?? []
            if let index = current.firstIndex(where: { $0.id == departure.id }) {
                current[index] = Self.preferred(current[index], departure)
            } else {
                current.append(departure)
            }
            departuresByPair[key] = current
        }
        prune(persistChanges: false)
        persist()
    }

    static func preferred(_ existing: RecentDepartureV2, _ incoming: RecentDepartureV2) -> RecentDepartureV2 {
        let newer = incoming.lastObservedAt >= existing.lastObservedAt ? incoming : existing
        let older = incoming.lastObservedAt >= existing.lastObservedAt ? existing : incoming
        let estimate = newer.estimatedDeparture != nil ? newer : older
        // An actual departure remains evidence even if a later board only supplies a forecast.
        let actual = newer.actualDepartureAt != nil ? newer : older
        return RecentDepartureV2(
            serviceID: newer.serviceID,
            serviceType: newer.serviceType,
            fromCRS: newer.fromCRS,
            toCRS: newer.toCRS,
            scheduledDeparture: newer.scheduledDeparture,
            estimatedDeparture: estimate.estimatedDeparture,
            actualDeparture: actual.actualDeparture,
            scheduledDepartureAt: newer.scheduledDepartureAt,
            estimatedDepartureAt: estimate.estimatedDepartureAt,
            actualDepartureAt: actual.actualDepartureAt,
            platform: normalized(newer.platform) ?? older.platform,
            isCancelled: newer.isCancelled,
            lastObservedAt: newer.lastObservedAt
        )
    }

    private func prune(now: Date = Date(), persistChanges: Bool = true) {
        let lower = now.addingTimeInterval(-Self.lookback)
        let upper = now.addingTimeInterval(Self.upcomingAllowance)
        departuresByPair = departuresByPair.compactMapValues { departures in
            let kept = departures.filter { departure in
                let reference = departure.actualDepartureAt ?? departure.scheduledDepartureAt
                return (lower...upper).contains(reference)
            }
            return kept.isEmpty ? nil : kept
        }
        if persistChanges { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(departuresByPair) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func restore() {
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode([String: [RecentDepartureV2]].self, from: data) else {
            return
        }
        departuresByPair = stored
    }

    private func pairKey(from: String, to: String) -> String {
        "\(from.uppercased())_\(to.uppercased())"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.caseInsensitiveCompare("TBC") != .orderedSame else {
            return nil
        }
        return value
    }
}
