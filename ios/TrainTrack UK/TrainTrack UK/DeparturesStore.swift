import Foundation
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif

struct JourneyLegSelection {
    let leg: Journey
    let departure: DepartureV2
}

struct PinnedDepartureMetadata: Hashable {
    let key: String
    let pinSetID: String?
    let journeyGroupID: UUID?
    let journeyLegIndex: Int?
    let pinSetLegCount: Int?
}

@MainActor
final class DeparturesStore: ObservableObject {
    private struct PinnedDeparture: Codable {
        enum CodingKeys: String, CodingKey {
            case key, fromCRS, toCRS, departure, pinnedAt, arrivedAt
            case pinSetID, journeyGroupID, journeyLegIndex, pinSetLegCount
        }

        let key: String
        let fromCRS: String
        let toCRS: String
        var departure: DepartureV2
        let pinnedAt: Date
        var arrivedAt: Date?
        let pinSetID: String?
        let journeyGroupID: UUID?
        let journeyLegIndex: Int?
        let pinSetLegCount: Int?

        init(
            key: String,
            fromCRS: String,
            toCRS: String,
            departure: DepartureV2,
            pinnedAt: Date,
            arrivedAt: Date?,
            pinSetID: String?,
            journeyGroupID: UUID?,
            journeyLegIndex: Int?,
            pinSetLegCount: Int?
        ) {
            self.key = key
            self.fromCRS = fromCRS
            self.toCRS = toCRS
            self.departure = departure
            self.pinnedAt = pinnedAt
            self.arrivedAt = arrivedAt
            self.pinSetID = pinSetID
            self.journeyGroupID = journeyGroupID
            self.journeyLegIndex = journeyLegIndex
            self.pinSetLegCount = pinSetLegCount
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            fromCRS = try c.decode(String.self, forKey: .fromCRS)
            toCRS = try c.decode(String.self, forKey: .toCRS)
            departure = try c.decode(DepartureV2.self, forKey: .departure)
            pinnedAt = (try? c.decode(Date.self, forKey: .pinnedAt)) ?? Date.distantPast
            arrivedAt = try? c.decode(Date.self, forKey: .arrivedAt)
            pinSetID = try? c.decode(String.self, forKey: .pinSetID)
            journeyGroupID = try? c.decode(UUID.self, forKey: .journeyGroupID)
            journeyLegIndex = try? c.decode(Int.self, forKey: .journeyLegIndex)
            pinSetLegCount = try? c.decode(Int.self, forKey: .pinSetLegCount)
        }
    }

    static let shared = DeparturesStore()

    @Published private(set) var departuresByPair: [String: [DepartureV2]] = [:]
    @Published private(set) var serviceDetailsById: [String: ServiceDetails] = [:]
    @Published private var pinnedDeparturesByKey: [String: PinnedDeparture] = [:]

    private var timerCancellable: AnyCancellable?
    private var journeysCancellable: AnyCancellable?
    private var pinnedCleanupCancellable: AnyCancellable?
    private var initialRefreshTask: Task<Void, Never>?
    private var lastWidgetReloadAt: Date? = nil
    private let pinnedStorageKey = "pinned_departures_v1"
    private let pinnedCleanupIntervalSeconds: TimeInterval = 60
    private let pinRetentionAfterArrivalSeconds: TimeInterval = 3600
    private let fallbackJourneyDurationSeconds: TimeInterval = 8 * 3600
    private let maxPinnedLifetimeWithoutFinalArrivalSeconds: TimeInterval = 24 * 3600
    private let pinnedStore: UserDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard

    private init() {
        loadPinnedDepartures()
        // Immediate local cleanup on app launch to avoid showing stale pins.
        reconcilePinnedDepartures()
    }

    func startPolling(journeyStore: JourneyStore) {
        if timerCancellable != nil || journeysCancellable != nil {
            // Already started, but still force an immediate cleanup pass.
            Task { await runPinnedCleanupNow() }
            return
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
            await self.refreshPrioritizingFavourites(for: journeyStore.journeys)
        }
        // Every 20 seconds
        timerCancellable = Timer.publish(every: 20, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.refresh(for: journeyStore.journeys) }
            }
        // Regular cleanup pass so stale pinned journeys are removed while app stays open.
        pinnedCleanupCancellable = Timer.publish(every: pinnedCleanupIntervalSeconds, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.runPinnedCleanupNow() }
            }
    }

    func stopPolling() {
        timerCancellable?.cancel()
        timerCancellable = nil
        journeysCancellable?.cancel()
        journeysCancellable = nil
        pinnedCleanupCancellable?.cancel()
        pinnedCleanupCancellable = nil
        initialRefreshTask?.cancel()
        initialRefreshTask = nil
    }

    func refreshNow(journeyStore: JourneyStore) {
        Task { await refresh(for: journeyStore.journeys) }
    }

    func runPinnedCleanupImmediately() {
        Task { await runPinnedCleanupNow() }
    }

    func refreshSpecificJourney(fromCRS: String, toCRS: String) async {
        let pairs = [(fromCRS, toCRS)]
        do {
            let map = try await NetworkServicePhone.shared.fetchDeparturesAggregated(pairs: pairs)
            // Merge the fresh data into our store
            for (key, value) in map {
                self.departuresByPair[key] = value
            }
            await runPinnedCleanupNow()
        } catch {
            // swallow errors for now
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
            }
            await runPinnedCleanupNow()
            return
        }
        do {
            let map = try await NetworkServicePhone.shared.fetchDeparturesAggregated(
                pairs: pairs,
                delayBeforeEachBatch: delayBeforeEachBatch
            )
            if replacingExistingDepartures {
                departuresByPair = map
            } else {
                for (key, value) in map {
                    departuresByPair[key] = value
                }
            }
            await runPinnedCleanupNow()
            reloadClosestFavouriteWidgetIfNeeded()
        } catch {
            // swallow errors for now
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

    func ensureServiceDetails(for ids: [String], force: Bool = false) async {
        let targets = force ? ids : ids.filter { serviceDetailsById[$0] == nil }
        guard !targets.isEmpty else { return }
        do {
            let map = try await NetworkServicePhone.shared.fetchServiceDetailsAggregatedChunked(ids: targets)
            for (k, v) in map { serviceDetailsById[k] = v }
            reconcilePinnedDepartures()
            objectWillChange.send()
        } catch {
            // swallow errors for now
        }
    }

    func departures(for journey: Journey) -> [DepartureV2] {
        let key = pairKey(from: journey.fromStation.crs, to: journey.toStation.crs)
        let list = departuresByPair[key] ?? []
        let pinned = pinnedDeparturesByKey.values
            .filter { pairKey(from: $0.fromCRS, to: $0.toCRS) == key }
            .map { $0.departure }

        var mergedByServiceID: [String: DepartureV2] = [:]
        for dep in list {
            mergedByServiceID[dep.serviceID] = dep
        }
        for dep in pinned where mergedByServiceID[dep.serviceID] == nil {
            mergedByServiceID[dep.serviceID] = dep
        }
        return sortDepartures(Array(mergedByServiceID.values))
    }

    func isPinned(_ dep: DepartureV2, fromCRS: String, toCRS: String) -> Bool {
        pinnedDeparturesByKey[pinKey(serviceID: dep.serviceID, fromCRS: fromCRS, toCRS: toCRS)] != nil
    }

    func pinnedMetadata(for dep: DepartureV2, fromCRS: String, toCRS: String) -> PinnedDepartureMetadata? {
        let key = pinKey(serviceID: dep.serviceID, fromCRS: fromCRS, toCRS: toCRS)
        guard let record = pinnedDeparturesByKey[key] else { return nil }
        return PinnedDepartureMetadata(
            key: key,
            pinSetID: record.pinSetID,
            journeyGroupID: record.journeyGroupID,
            journeyLegIndex: record.journeyLegIndex,
            pinSetLegCount: record.pinSetLegCount
        )
    }

    var hasPinnedItems: Bool {
        !pinnedDeparturesByKey.isEmpty
    }

    func hasPinnedDeparture(fromCRS: String, toCRS: String) -> Bool {
        let routeKey = pairKey(from: normalizeCRS(fromCRS), to: normalizeCRS(toCRS))
        return pinnedDeparturesByKey.values.contains {
            pairKey(from: $0.fromCRS, to: $0.toCRS) == routeKey
        }
    }

    func pin(_ dep: DepartureV2, fromCRS: String, toCRS: String) {
        let normalizedFrom = normalizeCRS(fromCRS)
        let normalizedTo = normalizeCRS(toCRS)
        let key = pinKey(serviceID: dep.serviceID, fromCRS: normalizedFrom, toCRS: normalizedTo)
        pinnedDeparturesByKey[key] = makePinnedRecord(
            key: key,
            fromCRS: normalizedFrom,
            toCRS: normalizedTo,
            departure: dep,
            pinnedAt: Date()
        )
        savePinnedDepartures()
    }

    func unpin(_ dep: DepartureV2, fromCRS: String, toCRS: String) {
        let key = pinKey(serviceID: dep.serviceID, fromCRS: fromCRS, toCRS: toCRS)
        guard let existing = pinnedDeparturesByKey[key] else { return }
        if let pinSetID = existing.pinSetID {
            unpinPinSet(pinSetID)
            return
        }
        pinnedDeparturesByKey.removeValue(forKey: key)
        savePinnedDepartures()
    }

    func pinJourneySelections(_ selections: [JourneyLegSelection], journeyGroupID: UUID) {
        guard !selections.isEmpty else { return }
        let now = Date()
        let pinSetID = UUID().uuidString
        var supersededPinSetIDs = Set<String>()

        for selection in selections {
            let normalizedFrom = normalizeCRS(selection.leg.fromStation.crs)
            let normalizedTo = normalizeCRS(selection.leg.toStation.crs)
            let key = pinKey(serviceID: selection.departure.serviceID, fromCRS: normalizedFrom, toCRS: normalizedTo)
            if let existing = pinnedDeparturesByKey[key], let existingSetID = existing.pinSetID {
                supersededPinSetIDs.insert(existingSetID)
            }
            pinnedDeparturesByKey[key] = makePinnedRecord(
                key: key,
                fromCRS: normalizedFrom,
                toCRS: normalizedTo,
                departure: selection.departure,
                pinnedAt: now,
                pinSetID: pinSetID,
                journeyGroupID: journeyGroupID,
                journeyLegIndex: selection.leg.legIndex,
                pinSetLegCount: selections.count
            )
        }

        for oldSetID in supersededPinSetIDs where oldSetID != pinSetID {
            pinnedDeparturesByKey = pinnedDeparturesByKey.filter { $0.value.pinSetID != oldSetID }
        }

        savePinnedDepartures()
    }

    func unpinJourneySelections(_ selections: [JourneyLegSelection]) {
        guard !selections.isEmpty else { return }
        var pinSetIDs = Set<String>()
        for selection in selections {
            let key = pinKey(
                serviceID: selection.departure.serviceID,
                fromCRS: selection.leg.fromStation.crs,
                toCRS: selection.leg.toStation.crs
            )
            if let existing = pinnedDeparturesByKey[key], let pinSetID = existing.pinSetID {
                pinSetIDs.insert(pinSetID)
            }
            pinnedDeparturesByKey.removeValue(forKey: key)
        }
        for pinSetID in pinSetIDs {
            pinnedDeparturesByKey = pinnedDeparturesByKey.filter { $0.value.pinSetID != pinSetID }
        }
        savePinnedDepartures()
    }

    func isJourneySelectionPinned(_ selections: [JourneyLegSelection]) -> Bool {
        guard !selections.isEmpty else { return false }
        let records: [PinnedDeparture] = selections.compactMap { selection in
            let key = pinKey(
                serviceID: selection.departure.serviceID,
                fromCRS: selection.leg.fromStation.crs,
                toCRS: selection.leg.toStation.crs
            )
            return pinnedDeparturesByKey[key]
        }
        guard records.count == selections.count else { return false }
        if selections.count == 1 {
            return true
        }
        let setIDs = Set(records.compactMap(\.pinSetID))
        guard setIDs.count == 1, let expectedSetID = setIDs.first else { return false }
        return records.allSatisfy { $0.pinSetID == expectedSetID }
    }

    func unpinPinSet(_ pinSetID: String) {
        let before = pinnedDeparturesByKey.count
        pinnedDeparturesByKey = pinnedDeparturesByKey.filter { $0.value.pinSetID != pinSetID }
        guard pinnedDeparturesByKey.count != before else { return }
        savePinnedDepartures()
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

    private func makePinnedRecord(
        key: String,
        fromCRS: String,
        toCRS: String,
        departure: DepartureV2,
        pinnedAt: Date,
        pinSetID: String? = nil,
        journeyGroupID: UUID? = nil,
        journeyLegIndex: Int? = nil,
        pinSetLegCount: Int? = nil
    ) -> PinnedDeparture {
        PinnedDeparture(
            key: key,
            fromCRS: fromCRS,
            toCRS: toCRS,
            departure: departure,
            pinnedAt: pinnedAt,
            arrivedAt: nil,
            pinSetID: pinSetID,
            journeyGroupID: journeyGroupID,
            journeyLegIndex: journeyLegIndex,
            pinSetLegCount: pinSetLegCount
        )
    }

    private func pinKey(serviceID: String, fromCRS: String, toCRS: String) -> String {
        "\(normalizeCRS(fromCRS))_\(normalizeCRS(toCRS))_\(serviceID)"
    }

    private func normalizeCRS(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private func missingServiceDetailIDsForPinnedDepartures() -> [String] {
        let ids = Set(pinnedDeparturesByKey.values.map { $0.departure.serviceID })
        return ids.filter { serviceDetailsById[$0] == nil }
            .sorted()
    }

    private func runPinnedCleanupNow() async {
        reconcilePinnedDepartures()
        let missingPinnedServiceIDs = missingServiceDetailIDsForPinnedDepartures()
        if !missingPinnedServiceIDs.isEmpty {
            await ensureServiceDetails(for: missingPinnedServiceIDs)
        }
        reconcilePinnedDepartures()
    }

    private func reconcilePinnedDepartures() {
        guard !pinnedDeparturesByKey.isEmpty else { return }
        let now = Date()
        var updated = pinnedDeparturesByKey
        var changed = false

        for (key, existing) in pinnedDeparturesByKey {
            var record = existing
            let routeKey = pairKey(from: record.fromCRS, to: record.toCRS)

            if let existingArrival = record.arrivedAt {
                let earliestReasonableArrival = record.pinnedAt.addingTimeInterval(-2 * 3600)
                let latestReasonableArrival = record.pinnedAt.addingTimeInterval(maxPinnedLifetimeWithoutFinalArrivalSeconds)
                if existingArrival < earliestReasonableArrival || existingArrival > latestReasonableArrival {
                    record.arrivedAt = nil
                    changed = true
                }
            }

            if let latest = departuresByPair[routeKey]?.first(where: { $0.serviceID == record.departure.serviceID }),
               latest != record.departure {
                record.departure = latest
                changed = true
            }

            if let finalArrival = finalArrivalDate(for: record) {
                if let existingArrival = record.arrivedAt {
                    if abs(existingArrival.timeIntervalSince(finalArrival)) > 60 {
                        record.arrivedAt = finalArrival
                        changed = true
                    }
                } else {
                    record.arrivedAt = finalArrival
                    changed = true
                }
            }

            updated[key] = record
        }

        let pinSets: [String: [PinnedDeparture]] = Dictionary(
            grouping: updated.values.compactMap { record -> PinnedDeparture? in
                guard record.pinSetID != nil else { return nil }
                return record
            },
            by: { $0.pinSetID! }
        )

        var expiredPinSetIDs = Set<String>()
        for (pinSetID, records) in pinSets {
            if let latestArrivedAt = records.compactMap(\.arrivedAt).max(),
               now.timeIntervalSince(latestArrivedAt) >= pinRetentionAfterArrivalSeconds {
                expiredPinSetIDs.insert(pinSetID)
                continue
            }

            if let latestPinnedAt = records.map(\.pinnedAt).max(),
               now.timeIntervalSince(latestPinnedAt) >= maxPinnedLifetimeWithoutFinalArrivalSeconds {
                expiredPinSetIDs.insert(pinSetID)
                continue
            }

            if let latestDepartureDate = records.compactMap({ pinnedDepartureDate($0) }).max() {
                let fallbackArrival = latestDepartureDate.addingTimeInterval(fallbackJourneyDurationSeconds)
                if now.timeIntervalSince(fallbackArrival) >= pinRetentionAfterArrivalSeconds {
                    expiredPinSetIDs.insert(pinSetID)
                }
            }
        }

        if !expiredPinSetIDs.isEmpty {
            updated = updated.filter { _, record in
                guard let pinSetID = record.pinSetID else { return true }
                return !expiredPinSetIDs.contains(pinSetID)
            }
            changed = true
        }

        for (key, record) in Array(updated) where record.pinSetID == nil {
            let isExpiredByArrival: Bool = {
                guard let arrivedAt = record.arrivedAt else { return false }
                return now.timeIntervalSince(arrivedAt) >= pinRetentionAfterArrivalSeconds
            }()
            let isExpiredByFallback = fallbackShouldExpire(record, now: now)

            if isExpiredByArrival || isExpiredByFallback {
                updated.removeValue(forKey: key)
                changed = true
            }
        }

        guard changed else { return }
        pinnedDeparturesByKey = updated
        savePinnedDepartures()
    }

    private func finalArrivalDate(for record: PinnedDeparture) -> Date? {
        guard let details = serviceDetailsById[record.departure.serviceID] else { return nil }
        guard let finalStop = details.allStations.last else { return nil }
        let finalTime = bestArrivalTime(actual: finalStop.at, estimated: finalStop.et, scheduled: finalStop.st)

        if let departureDate = pinnedDepartureDate(record) {
            return parseServiceTime(finalTime, anchoredToDeparture: departureDate)
        }

        return parseHHmm(finalTime, relativeTo: record.pinnedAt)
    }

    private func bestArrivalTime(actual: String?, estimated: String?, scheduled: String) -> String? {
        if let normalizedActual = normalizeServiceTime(actual, scheduledFallback: scheduled) {
            return normalizedActual
        }
        if let normalizedEstimated = normalizeServiceTime(estimated, scheduledFallback: scheduled) {
            return normalizedEstimated
        }
        return scheduled
    }

    private func normalizeServiceTime(_ value: String?, scheduledFallback: String) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let lower = trimmed.lowercased()
        if lower == "cancelled" || lower == "delayed" { return nil }
        if lower == "on time" { return scheduledFallback }
        return trimmed
    }

    private func fallbackShouldExpire(_ record: PinnedDeparture, now: Date) -> Bool {
        if now.timeIntervalSince(record.pinnedAt) >= maxPinnedLifetimeWithoutFinalArrivalSeconds {
            return true
        }
        guard let departureDate = pinnedDepartureDate(record) else { return false }
        let fallbackArrival = departureDate.addingTimeInterval(fallbackJourneyDurationSeconds)
        return now.timeIntervalSince(fallbackArrival) >= pinRetentionAfterArrivalSeconds
    }

    private func pinnedDepartureDate(_ record: PinnedDeparture) -> Date? {
        let normalizedEstimated = normalizeServiceTime(record.departure.departureTime.estimated, scheduledFallback: record.departure.departureTime.scheduled)
        return parseHHmmNearest(normalizedEstimated ?? record.departure.departureTime.scheduled, around: record.pinnedAt)
    }

    private func loadPinnedDepartures() {
        guard let data = pinnedStore.data(forKey: pinnedStorageKey) else { return }
        let decoder = JSONDecoder()
        do {
            let decoded = try decoder.decode([String: PinnedDeparture].self, from: data)
            pinnedDeparturesByKey = decoded
        } catch {
            pinnedDeparturesByKey = [:]
        }
    }

    private func savePinnedDepartures() {
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(pinnedDeparturesByKey)
            pinnedStore.set(data, forKey: pinnedStorageKey)
        } catch {
            // Ignore persistence errors for now.
        }
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

    private func parseHHmm(_ t: String?, relativeTo anchor: Date) -> Date? {
        parseHHmmNearest(t, around: anchor)
    }

    private func parseHHmmNearest(_ t: String?, around anchor: Date) -> Date? {
        guard let t = t else { return nil }
        let lower = t.lowercased()
        if lower == "delayed" || lower == "cancelled" || lower == "on time" { return nil }
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }

        var comps = Calendar.current.dateComponents([.year, .month, .day], from: anchor)
        comps.hour = h
        comps.minute = m
        guard let sameDay = Calendar.current.date(from: comps) else { return nil }
        let previousDay = Calendar.current.date(byAdding: .day, value: -1, to: sameDay) ?? sameDay
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: sameDay) ?? sameDay
        let candidates = [previousDay, sameDay, nextDay]
        return candidates.min { lhs, rhs in
            abs(lhs.timeIntervalSince(anchor)) < abs(rhs.timeIntervalSince(anchor))
        }
    }

    private func parseServiceTime(_ t: String?, anchoredToDeparture departure: Date) -> Date? {
        guard var candidate = parseHHmmNearest(t, around: departure) else { return nil }

        // Arrival should not resolve to a date significantly before departure.
        let earliestReasonableArrival = departure.addingTimeInterval(-30 * 60)
        while candidate < earliestReasonableArrival {
            guard let rolled = Calendar.current.date(byAdding: .day, value: 1, to: candidate) else { break }
            candidate = rolled
        }

        // Sanity guard against obviously unrelated dates.
        if candidate.timeIntervalSince(departure) > 30 * 3600 {
            return nil
        }

        return candidate
    }
}
