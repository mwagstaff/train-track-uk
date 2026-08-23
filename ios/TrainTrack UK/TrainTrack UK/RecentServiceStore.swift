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
        let observations = departures.compactMap { departure -> RecentDepartureV2? in
            guard let scheduled = JourneyHistoryTime.date(
                for: departure.departureTime.scheduled,
                near: now
            ) else { return nil }
            let lower = now.addingTimeInterval(-Self.lookback)
            let upper = now.addingTimeInterval(Self.upcomingAllowance)
            guard (lower...upper).contains(scheduled) else { return nil }
            let estimated = JourneyHistoryTime.date(
                for: departure.departureTime.estimated,
                near: scheduled
            )
            return RecentDepartureV2(
                serviceID: departure.serviceID,
                serviceType: departure.serviceType,
                fromCRS: fromCRS.uppercased(),
                toCRS: toCRS.uppercased(),
                scheduledDeparture: departure.departureTime.scheduled,
                estimatedDeparture: departure.departureTime.estimated,
                actualDeparture: nil,
                scheduledDepartureAt: scheduled,
                estimatedDepartureAt: estimated,
                actualDepartureAt: nil,
                platform: departure.platform,
                isCancelled: departure.isCancelled,
                lastObservedAt: now
            )
        }
        merge(observations)
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
                current[index] = preferred(current[index], departure)
            } else {
                current.append(departure)
            }
            departuresByPair[key] = current
        }
        prune(persistChanges: false)
        persist()
    }

    private func preferred(_ existing: RecentDepartureV2, _ incoming: RecentDepartureV2) -> RecentDepartureV2 {
        RecentDepartureV2(
            serviceID: incoming.serviceID,
            serviceType: incoming.serviceType,
            fromCRS: incoming.fromCRS,
            toCRS: incoming.toCRS,
            scheduledDeparture: incoming.scheduledDeparture,
            estimatedDeparture: incoming.estimatedDeparture ?? existing.estimatedDeparture,
            actualDeparture: incoming.actualDeparture ?? existing.actualDeparture,
            scheduledDepartureAt: incoming.scheduledDepartureAt,
            estimatedDepartureAt: incoming.estimatedDepartureAt ?? existing.estimatedDepartureAt,
            actualDepartureAt: incoming.actualDepartureAt ?? existing.actualDepartureAt,
            platform: normalized(incoming.platform) ?? existing.platform,
            isCancelled: incoming.isCancelled,
            lastObservedAt: max(existing.lastObservedAt, incoming.lastObservedAt)
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

    private func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
