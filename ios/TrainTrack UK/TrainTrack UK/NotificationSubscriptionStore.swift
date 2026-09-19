import Foundation
import Combine

final class NotificationSubscriptionService {
    static let shared = NotificationSubscriptionService()
    private init() {}

    private var base: String { ApiHostPreference.currentBaseURL }
    private var deviceId: String { DeviceIdentity.deviceToken }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    func fetchSubscriptions() async throws -> [NotificationSubscription] {
        try await fetchSubscriptions(path: "subscriptions")
    }

    func fetchLiveSessions() async throws -> [NotificationSubscription] {
        try await fetchSubscriptions(path: "live_sessions")
    }

    func upsertSubscription(_ requestBody: NotificationSubscriptionRequest) async throws -> NotificationSubscription {
        try await upsert(requestBody, path: "subscriptions")
    }

    func upsertLiveSession(_ requestBody: NotificationSubscriptionRequest) async throws -> NotificationSubscription {
        try await upsert(requestBody, path: "live_sessions")
    }

    func deleteSubscription(id: String) async throws {
        try await delete(id: id, path: "subscriptions")
    }

    func deleteLiveSession(id: String) async throws {
        try await delete(id: id, path: "live_sessions")
    }

    func setHolidayMode(enabled: Bool) async throws {
        guard let url = URL(string: "\(base)/notifications/holiday-mode") else {
            throw PhoneNetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Token")
        request.httpBody = try encoder.encode(HolidayModeRequest(deviceId: deviceId, enabled: enabled))
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
    }

    private func fetchSubscriptions(path: String) async throws -> [NotificationSubscription] {
        guard let url = URL(string: "\(base)/notifications/\(path)?device_id=\(deviceId)") else {
            throw PhoneNetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Token")
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        try validateResponse(urlResponse, data: data)
        if data.isEmpty {
            throw NotificationServiceError(message: "Empty response from server.")
        }
        let payload = try decoder.decode(NotificationSubscriptionListResponse.self, from: data)
        return payload.subscriptions
    }

    private func upsert(_ requestBody: NotificationSubscriptionRequest, path: String) async throws -> NotificationSubscription {
        guard let url = URL(string: "\(base)/notifications/\(path)") else {
            throw PhoneNetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Token")
        request.httpBody = try encoder.encode(requestBody)
        let (data, urlResponse) = try await URLSession.shared.data(for: request)
        try validateResponse(urlResponse, data: data)
        if data.isEmpty {
            throw NotificationServiceError(message: "Empty response from server.")
        }
        let payload = try decoder.decode(NotificationSubscriptionResponse.self, from: data)
        return payload.subscription
    }

    private func delete(id: String, path: String) async throws {
        guard let url = URL(string: "\(base)/notifications/\(path)") else {
            throw PhoneNetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceId, forHTTPHeaderField: "X-Device-Token")
        let body = NotificationSubscriptionDeleteRequest(deviceId: deviceId, subscriptionId: id)
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validateResponse(response, data: data)
    }

    private func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if let message = decodeErrorMessage(data) {
                throw NotificationServiceError(message: message)
            }
            throw NotificationServiceError(message: "Request failed with status \(http.statusCode).")
        }
    }

    private func decodeErrorMessage(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let errorResponse = try? decoder.decode(NotificationAPIErrorResponse.self, from: data) {
            return errorResponse.error
        }
        return nil
    }
}

private struct PersistedScheduledJourneyActivation: Codable {
    let subscription: NotificationSubscription
    let stations: [Station]
    var recoveryGeometries: [PersistedScheduledRecoveryGeometry]? = nil
}

enum PendingLiveSessionDeletionPolicy {
    static func reconcile(
        serverIDs: Set<String>,
        pendingDeletionIDs: Set<String>
    ) -> (visibleIDs: Set<String>, pendingDeletionIDs: Set<String>) {
        (
            visibleIDs: serverIDs.subtracting(pendingDeletionIDs),
            pendingDeletionIDs: pendingDeletionIDs.intersection(serverIDs)
        )
    }
}

@MainActor
enum JourneyEndPolicy {
    static func matches(_ subscription: NotificationSubscription, subscriptionID: String, group: JourneyGroup) -> Bool {
        if subscription.id == subscriptionID { return true }
        let legs = subscription.legs.filter(\.enabled)
        return legs.first?.from.caseInsensitiveCompare(group.startStation.crs) == .orderedSame
            && legs.last?.to.caseInsensitiveCompare(group.endStation.crs) == .orderedSame
    }

    static func scheduleKeys(for subscription: NotificationSubscription, group: JourneyGroup, now: Date) -> Set<String> {
        Set(subscription.legs.filter { leg in
            leg.enabled && group.legs.contains {
                $0.fromStation.crs.caseInsensitiveCompare(leg.from) == .orderedSame
                    && $0.toStation.crs.caseInsensitiveCompare(leg.to) == .orderedSame
            }
        }.compactMap { leg -> String? in
            guard let window = NotificationScheduleActivationPolicy.activeWindow(for: subscription, leg: leg, now: now) else { return nil }
            return ScheduledLiveActivityAutoStartManager.shared.scheduleKey(for: leg, now: window.start)
        })
    }
}

private struct PersistedScheduledRecoveryGeometry: Codable {
    let from: String
    let to: String
    let stations: [Station]
    let attemptedAt: Date
}

@MainActor
final class NotificationSubscriptionStore: ObservableObject {
    static let shared = NotificationSubscriptionStore()

    @Published private(set) var subscriptions: [NotificationSubscription] = []
    @Published private(set) var liveSessions: [NotificationSubscription] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false
    @Published var lastError: String? = nil
    private var hasLoadedRemoteState = false

    private let service = NotificationSubscriptionService.shared
    private var oneOffExpirationTask: Task<Void, Never>?
    private let activationDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard
    private let scheduledActivationsKey = "scheduledJourneyActivationsV1"
    private var cachedScheduledActivations: [PersistedScheduledJourneyActivation] = []
    private(set) var hasAuthoritativeScheduledActivationCache = false
    private var isRefreshingRecoveryGeometry = false

    // Forward ServerConfigStore changes through this store so that computed
    // properties like canCreateNew (which read from ServerConfigStore) cause
    // SwiftUI views to re-render when the server config is updated.
    private var configCancellable: AnyCancellable?

    // MARK: - Local subscription ID registry
    // Tracks the IDs of subscriptions this device has intentionally created.
    // On each refresh the server list is reconciled against this registry so
    // any orphaned server-side entries (e.g. from a failed delete or a
    // previous save that generated a new ID) are automatically pruned.

    private static let knownIDsKey = "knownSubscriptionIDs"
    private static let knownIDsBootstrappedKey = "knownSubscriptionIDsBootstrapped"
    private static let pendingLiveSessionDeletionIDsKey = "pendingLiveSessionDeletionIDs"

    private var knownSubscriptionIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.knownIDsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.knownIDsKey) }
    }

    private var hasBootstrappedKnownIDs: Bool {
        get { UserDefaults.standard.bool(forKey: Self.knownIDsBootstrappedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.knownIDsBootstrappedKey) }
    }

    private var pendingLiveSessionDeletionIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.pendingLiveSessionDeletionIDsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.pendingLiveSessionDeletionIDsKey) }
    }

    // MARK: - Init

    private init() {
        loadScheduledActivations()
        // When the server config updates (e.g. limit changes), forward the
        // change through this store so that computed properties like
        // canCreateNew cause SwiftUI views to re-render automatically.
        configCancellable = ServerConfigStore.shared.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let scheduledTask = service.fetchSubscriptions()
            async let liveSessionsTask = service.fetchLiveSessions()
            let fetched = try await scheduledTask
            let fetchedLive = try await liveSessionsTask
            subscriptions = await reconcileSubscriptions(fetched)
            await refreshScheduledActivationCache()
            rescheduleOneOffExpiration()
            let pendingDeletionIDs = pendingLiveSessionDeletionIDs
            let reconciliation = PendingLiveSessionDeletionPolicy.reconcile(
                serverIDs: Set(fetchedLive.map(\.id)),
                pendingDeletionIDs: pendingDeletionIDs
            )
            pendingLiveSessionDeletionIDs = reconciliation.pendingDeletionIDs
            liveSessions = fetchedLive.filter { reconciliation.visibleIDs.contains($0.id) }
            for id in reconciliation.pendingDeletionIDs {
                try? await service.deleteLiveSession(id: id)
            }
            hasLoadedRemoteState = true
            hasLoadedOnce = true
            lastError = nil
            NotificationMuteRequestSender.shared.retryPendingMuteRequests(trigger: "subscription-refresh")
            await syncGeofences()
            await refreshScheduledRecoveryGeometry()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func rescheduleOneOffExpiration() {
        oneOffExpirationTask?.cancel()

        let now = Date()
        let expiredIDs = Set(subscriptions.compactMap { subscription in
            NotificationScheduleExpiry.isExpired(subscription, now: now) ? subscription.id : nil
        })
        if !expiredIDs.isEmpty {
            subscriptions.removeAll { expiredIDs.contains($0.id) }
            var known = knownSubscriptionIDs
            known.subtract(expiredIDs)
            knownSubscriptionIDs = known
            Task { [weak self] in
                guard let self else { return }
                for id in expiredIDs {
                    try? await self.service.deleteSubscription(id: id)
                }
            }
        }

        let nextExpiration = subscriptions.compactMap {
            NotificationScheduleExpiry.expirationDate(for: $0)
        }.filter { $0 > now }.min()
        guard let nextExpiration else {
            oneOffExpirationTask = nil
            return
        }

        let delay = min(nextExpiration.timeIntervalSince(now), 24 * 60 * 60)
        oneOffExpirationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.rescheduleOneOffExpiration()
        }
    }

    /// Compares the server-returned subscriptions against the device's local registry.
    /// First call bootstraps the registry from the server list. Subsequent calls delete
    /// any IDs the server has that this device never registered, then return only the
    /// known subscriptions.
    private func reconcileSubscriptions(_ serverSubscriptions: [NotificationSubscription]) async -> [NotificationSubscription] {
        guard hasBootstrappedKnownIDs else {
            let ids = Set(serverSubscriptions.map(\.id))
            knownSubscriptionIDs = ids
            hasBootstrappedKnownIDs = true
            debugLog("🔑 [Store] Bootstrapped \(ids.count) known subscription ID(s)")
            return serverSubscriptions
        }

        let known = knownSubscriptionIDs
        let orphans = serverSubscriptions.filter { !known.contains($0.id) }

        if !orphans.isEmpty {
            debugLog("🧹 [Store] Pruning \(orphans.count) orphaned server subscription(s): \(orphans.map(\.id))")
            for orphan in orphans {
                try? await service.deleteSubscription(id: orphan.id)
            }
        }

        return serverSubscriptions.filter { known.contains($0.id) }
    }

    // MARK: - Mutations

    func upsert(_ requestBody: NotificationSubscriptionRequest) async throws -> NotificationSubscription {
        let subscription = try await service.upsertSubscription(requestBody)
        var known = knownSubscriptionIDs
        known.insert(subscription.id)
        knownSubscriptionIDs = known
        hasLoadedRemoteState = true
        subscriptions.removeAll { $0.id == subscription.id }
        subscriptions.append(subscription)
        await refreshScheduledActivationCache()
        await syncGeofences()
        await refreshScheduledRecoveryGeometry()
        await refresh()
        return subscriptions.first(where: { $0.id == subscription.id }) ?? subscription
    }

    func delete(id: String) async throws {
        try await service.deleteSubscription(id: id)
        subscriptions.removeAll { $0.id == id }
        cachedScheduledActivations.removeAll { $0.subscription.id == id }
        JourneyTrackingCoordinator.shared.disarm(subscriptionID: id)
        await refreshScheduledActivationCache()
        rescheduleOneOffExpiration()
        var known = knownSubscriptionIDs
        known.remove(id)
        knownSubscriptionIDs = known
        hasLoadedRemoteState = true
        await syncGeofences()
    }

    func subscription(for routeKey: String) -> NotificationSubscription? {
        subscriptions(for: routeKey).first
    }

    func subscriptions(for routeKey: String) -> [NotificationSubscription] {
        subscriptions.filter {
            $0.routeKey == routeKey && !NotificationScheduleExpiry.isExpired($0)
        }
    }

    func upsertLiveSession(
        _ requestBody: NotificationSubscriptionRequest,
        historySource: JourneyHistorySource = .adhoc
    ) async throws -> NotificationSubscription {
        let requestURL = "\(ApiHostPreference.currentBaseURL)/notifications/live_sessions"
        let legSummary = requestBody.legs.map { "\($0.from.uppercased())→\($0.to.uppercased())[\($0.enabled ? "on" : "off")]" }.joined(separator: ", ")
        DebugLogStore.shared.log(
            """
            Registering notification live session
            URL: \(requestURL)
            Device: \(DeviceIdentity.deviceToken)
            Existing subscription: \(requestBody.subscriptionId ?? "nil")
            Route: \(requestBody.routeKey)
            Legs: \(legSummary.isEmpty ? "none" : legSummary)
            """,
            category: "Mute"
        )
        let subscription = try await service.upsertLiveSession(requestBody)
        if let index = liveSessions.firstIndex(where: { $0.id == subscription.id }) {
            liveSessions[index] = subscription
        } else {
            liveSessions.append(subscription)
        }
        let returnedLegSummary = subscription.legs.map { "\($0.from.uppercased())→\($0.to.uppercased())[\($0.enabled ? "on" : "off")]" }.joined(separator: ", ")
        DebugLogStore.shared.log(
            """
            Registered notification live session
            URL: \(requestURL)
            Device: \(DeviceIdentity.deviceToken)
            Existing subscription: \(requestBody.subscriptionId ?? "nil")
            Returned subscription: \(subscription.id)
            Route: \(subscription.routeKey)
            Legs: \(returnedLegSummary.isEmpty ? "none" : returnedLegSummary)
            Local live sessions: \(liveSessions.map(\.id).joined(separator: ", "))
            """,
            category: "Mute"
        )
        hasLoadedRemoteState = true
        let enabledLegs = subscription.legs.filter(\.enabled)
        JourneyTrackingCoordinator.shared.pruneCompletedScheduledCandidates()
        let alreadyArmedFromSchedule = historySource == .scheduled
            && JourneyTrackingCoordinator.shared.armedCandidates.contains { candidate in
                guard candidate.source == .scheduled else { return false }
                return enabledLegs.contains { leg in
                    zip(candidate.stations, candidate.stations.dropFirst()).contains { from, to in
                        from.crs.caseInsensitiveCompare(leg.from) == .orderedSame
                            && to.crs.caseInsensitiveCompare(leg.to) == .orderedSame
                    }
                }
            }
        if !alreadyArmedFromSchedule {
            await JourneyTrackingCoordinator.shared.arm(subscription: subscription, source: historySource)
        }
        await syncGeofences()
        return subscription
    }

    func deleteLiveSession(id: String) async throws {
        try await service.deleteLiveSession(id: id)
        liveSessions.removeAll { $0.id == id }
        JourneyTrackingCoordinator.shared.disarm(subscriptionID: id)
        hasLoadedRemoteState = true
        await syncGeofences()
    }

    func endJourneyUpdates(subscriptionID: String, group: JourneyGroup) async {
        let coordinator = JourneyTrackingCoordinator.shared
        let reference = coordinator.armedCandidates.first { $0.subscriptionId == subscriptionID }?.activeFrom
            ?? coordinator.activeJourney?.scheduleOccurrenceStart ?? Date()
        let schedules = subscriptions + cachedScheduledActivations.map(\.subscription)
        let scheduleKeys = schedules.reduce(into: Set<String>()) { keys, subscription in
            keys.formUnion(JourneyEndPolicy.scheduleKeys(for: subscription, group: group, now: reference))
        }
        let sessionIDs = Set(liveSessions.filter {
            JourneyEndPolicy.matches($0, subscriptionID: subscriptionID, group: group)
        }.map(\.id))
        // Persist suppression before any suspension can let geofences re-arm this occurrence.
        for key in scheduleKeys {
            ScheduledLiveActivityAutoStartManager.shared.suppressScheduledJourney(scheduleKey: key)
        }
        pendingLiveSessionDeletionIDs.formUnion(sessionIDs)
        liveSessions.removeAll { sessionIDs.contains($0.id) }
        let candidateIDs = coordinator.armedCandidates.filter {
            $0.subscriptionId == subscriptionID || $0.stations.map { $0.crs.uppercased() } == group.stationSequence.map { $0.crs.uppercased() }
        }.map(\.subscriptionId)
        for id in candidateIDs { coordinator.disarm(subscriptionID: id) }
        hasLoadedRemoteState = true

        if coordinator.activeJourney?.subscriptionId == subscriptionID {
            await coordinator.endActiveJourney()
            coordinator.clearRecentlyCompletedJourney()
        }
        await LiveActivityManager.shared.stopJourneyActivities(
            deepLinkFromCRS: group.startStation.crs, deepLinkToCRS: group.endStation.crs
        )
        for key in scheduleKeys {
            _ = await ScheduledLiveActivityAutoStartManager.shared.dismissScheduledJourney(scheduleKey: key)
        }
        for id in sessionIDs {
            do { try await service.deleteLiveSession(id: id) }
            catch { debugLog("⚠️ [Store] Ended journey session \(id); server deletion will retry: \(error.localizedDescription)") }
        }
        await syncGeofences()
    }

    func deleteLiveSessions(containingFrom from: String, to: String) async {
        let fromCode = from.uppercased()
        let toCode = to.uppercased()
        let matchingIDs = liveSessions.compactMap { session -> String? in
            session.legs.contains(where: { $0.from.uppercased() == fromCode && $0.to.uppercased() == toCode })
                ? session.id
                : nil
        }
        guard !matchingIDs.isEmpty else { return }
        for id in matchingIDs {
            do {
                try await deleteLiveSession(id: id)
            } catch {
                continue
            }
        }
    }

    func removeLiveSessionsLocally(containingFrom from: String, to: String) async {
        let fromCode = from.uppercased()
        let toCode = to.uppercased()
        let originalCount = liveSessions.count
        liveSessions.removeAll { session in
            session.legs.contains(where: { $0.from.uppercased() == fromCode && $0.to.uppercased() == toCode })
        }
        guard liveSessions.count != originalCount else { return }
        hasLoadedRemoteState = true
        await syncGeofences()
    }

    func deleteAllLiveSessions() async {
        let ids = liveSessions.map(\.id)
        for id in ids {
            do {
                try await deleteLiveSession(id: id)
            } catch {
                continue
            }
        }
    }

    func liveSession(for routeKey: String) -> NotificationSubscription? {
        liveSessions.first { $0.routeKey == routeKey }
    }

    var combinedSubscriptions: [NotificationSubscription] {
        Self.subscriptionsForJourneyUpdates(
            scheduled: subscriptions.filter { !NotificationScheduleExpiry.isExpired($0) },
            liveSessions: liveSessions
        )
    }

    static func subscriptionsForJourneyUpdates(
        scheduled: [NotificationSubscription],
        liveSessions: [NotificationSubscription]
    ) -> [NotificationSubscription] {
        scheduled + liveSessions.filter { $0.liveSessionOrigin != .scheduled }
    }

    var hasAuthoritativeRemoteState: Bool {
        hasLoadedOnce && lastError == nil
    }

    var canCreateNew: Bool {
        subscriptions.lazy.filter { !NotificationScheduleExpiry.isExpired($0) }.count
            < ServerConfigStore.shared.maxSubscriptionsPerDevice
    }
    var canCreateNewLiveSession: Bool { liveSessions.count < ServerConfigStore.shared.maxLiveSessionsPerDevice }

    func syncGeofencesNow() async {
        guard hasLoadedRemoteState else { return }
        await syncGeofences()
    }

    var locallyCachedMonitoringSubscriptions: [NotificationSubscription] {
        monitoringSubscriptions()
    }

    var locallyCachedScheduledStations: [String: Station] {
        cachedScheduledActivations.reduce(into: [String: Station]()) { result, activation in
            let recoveryStations = activation.recoveryGeometries?.flatMap(\.stations) ?? []
            for station in activation.stations + recoveryStations where station.hasUsableCoordinate {
                result[station.crs.uppercased()] = station
            }
        }
    }

    /// Available before any window starts or any origin departure is detected.
    func locallyCachedScheduledRecoveryStations(from: String, to: String) -> [Station] {
        let from = from.uppercased()
        let to = to.uppercased()
        let geometry = cachedScheduledActivations.flatMap { $0.recoveryGeometries ?? [] }
            .filter { $0.from == from && $0.to == to }
            .max { $0.attemptedAt < $1.attemptedAt }
        var stations = Array((geometry?.stations ?? []).prefix(2))
        if let destination = locallyCachedScheduledStations[to] {
            stations.append(destination)
        }
        var seen = Set([from])
        return stations.filter { $0.hasUsableCoordinate && seen.insert($0.crs.uppercased()).inserted }
    }

    @discardableResult
    func armScheduledJourneyForRecoveryFromCache(
        subscriptionID: String,
        from: String,
        to: String,
        observedAt: Date
    ) async -> Bool {
        let receivedAt = Date()
        guard let activation = cachedScheduledActivations.first(where: { $0.subscription.id == subscriptionID }) else { return false }
        let windows = activation.subscription.legs.filter {
            $0.enabled && $0.from.caseInsensitiveCompare(from) == .orderedSame
                && $0.to.caseInsensitiveCompare(to) == .orderedSame
        }.compactMap {
            NotificationScheduleActivationPolicy.windowForRouteRecovery(
                for: activation.subscription, leg: $0, observedAt: observedAt, receivedAt: receivedAt
            )
        }
        guard let window = windows.max(by: { $0.start < $1.start }) else { return false }
        // The reference selects the candidate's original window only. The actual
        // downstream observation is recorded separately by JourneyTrackingCoordinator.
        let occurrenceReference = min(observedAt, window.end.addingTimeInterval(-0.001))
        return await armScheduledJourneyFromCache(
            subscriptionID: subscriptionID, from: from, to: to, now: occurrenceReference
        )
    }

    @discardableResult
    func armScheduledJourneyFromCache(
        subscriptionID: String? = nil,
        from: String,
        to: String,
        now: Date = Date()
    ) async -> Bool {
        let receivedAt = Date()
        var resolvedActivation: (activation: PersistedScheduledJourneyActivation, legs: [NotificationLeg])?
        for activation in cachedScheduledActivations {
            if let subscriptionID, activation.subscription.id != subscriptionID {
                continue
            }
            let legs = ScheduledJourneyActivationResolver.legs(
                for: activation.subscription,
                matchingFrom: from,
                to: to,
                now: now
            )
            if let first = legs.first,
               NotificationScheduleActivationPolicy.recoverableWindow(
                   for: activation.subscription, leg: first, observedAt: now, receivedAt: receivedAt
               ) != nil {
                resolvedActivation = (activation, legs)
                break
            }
        }
        guard let resolvedActivation else {
            return false
        }

        let activation = resolvedActivation.activation
        let activeSubscription = subscription(activation.subscription, replacingLegsWith: resolvedActivation.legs)
        let expectedRoute = [resolvedActivation.legs[0].from.uppercased()]
            + resolvedActivation.legs.map { $0.to.uppercased() }

        let coordinator = JourneyTrackingCoordinator.shared
        coordinator.pruneCompletedScheduledCandidates()
        guard !ScheduledLiveActivityAutoStartManager.shared.shouldSkipForAdHocJourney(
            leg: resolvedActivation.legs[0], now: now
        ) else { return false }
        if !JourneyTrackingCoordinator.shouldArmCandidate(
            subscriptionID: activation.subscription.id,
            activeSubscriptionID: coordinator.activeJourney?.subscriptionId
        ) {
            return true
        }
        if coordinator.armedCandidates.contains(where: {
            $0.subscriptionId == activation.subscription.id
                && $0.activeUntil != nil
                && $0.isCurrent(at: now)
                && $0.stations.map { $0.crs.uppercased() } == expectedRoute
        }) {
            return true
        }

        let stationsByCRS = Dictionary(uniqueKeysWithValues: activation.stations.map {
            ($0.crs.uppercased(), $0)
        })
        await coordinator.arm(
            subscription: activeSubscription,
            source: .scheduled,
            cachedStationsByCRS: stationsByCRS,
            now: now
        )
        await syncGeofences()
        return coordinator.armedCandidates.contains {
            $0.subscriptionId == activation.subscription.id
                && $0.stations.map { $0.crs.uppercased() } == expectedRoute
        }
    }

    private func subscription(
        _ subscription: NotificationSubscription,
        replacingLegsWith legs: [NotificationLeg]
    ) -> NotificationSubscription {
        NotificationSubscription(
            id: subscription.id,
            deviceId: subscription.deviceId,
            routeKey: subscription.routeKey,
            scheduleKind: subscription.scheduleKind,
            daysOfWeek: subscription.daysOfWeek,
            notificationTypes: subscription.notificationTypes,
            legs: legs,
            muteOnArrival: subscription.muteOnArrival,
            source: subscription.source,
            liveSessionOrigin: subscription.liveSessionOrigin,
            activeUntil: subscription.activeUntil,
            mutedByLegDay: subscription.mutedByLegDay,
            mutedAtByLegDay: subscription.mutedAtByLegDay,
            createdAt: subscription.createdAt,
            updatedAt: subscription.updatedAt
        )
    }

    func applyGlobalNotificationTypes() async throws {
        let scheduled = subscriptions.filter { !NotificationScheduleExpiry.isExpired($0) }
        let live = liveSessions
        guard !(scheduled.isEmpty && live.isEmpty) else { return }

        await NotificationAuthorizationManager.registerIfAuthorized()
        guard let pushToken = await NotificationPushTokenStore.waitForToken(timeoutSeconds: 6.0),
              !pushToken.isEmpty else {
            throw NotificationServiceError(message: "Waiting for a push token. Try again in a moment.")
        }

        #if DEBUG
        let useSandbox = true
        #else
        let useSandbox = false
        #endif

        let scheduledTypes = NotificationPreferences.effectiveTypes(for: .scheduled)
        let liveTypes = NotificationPreferences.effectiveTypes(for: .liveSession)

        for subscription in scheduled {
            let request = NotificationSubscriptionRequest(
                subscriptionId: subscription.id,
                deviceId: DeviceIdentity.deviceToken,
                pushToken: pushToken,
                routeKey: subscription.routeKey,
                scheduleKind: subscription.scheduleKind ?? .regular,
                daysOfWeek: subscription.daysOfWeek,
                notificationTypes: scheduledTypes,
                legs: subscription.legs,
                windowStart: subscription.legs.first?.windowStart,
                windowEnd: subscription.legs.first?.windowEnd,
                from: subscription.legs.first?.from,
                to: subscription.legs.last?.to,
                fromName: subscription.legs.first?.fromName,
                toName: subscription.legs.last?.toName,
                useSandbox: useSandbox,
                muteOnArrival: subscription.muteOnArrival,
                liveSessionOrigin: nil,
                activeUntil: nil
            )
            _ = try await service.upsertSubscription(request)
        }

        for session in live {
            let request = NotificationSubscriptionRequest(
                subscriptionId: session.id,
                deviceId: DeviceIdentity.deviceToken,
                pushToken: pushToken,
                routeKey: session.routeKey,
                daysOfWeek: session.daysOfWeek,
                notificationTypes: liveTypes,
                legs: session.legs,
                windowStart: session.legs.first?.windowStart,
                windowEnd: session.legs.first?.windowEnd,
                from: session.legs.first?.from,
                to: session.legs.last?.to,
                fromName: session.legs.first?.fromName,
                toName: session.legs.last?.toName,
                useSandbox: useSandbox,
                muteOnArrival: session.muteOnArrival,
                liveSessionOrigin: session.liveSessionOrigin ?? .manual,
                activeUntil: session.activeUntil
            )
            _ = try await service.upsertLiveSession(request)
        }

        await refresh()
    }

    private func syncGeofences() async {
        let eligible = monitoringSubscriptions()
        logGeofenceEligibility(eligible: eligible)
        await NotificationGeofenceManager.shared.sync(subscriptions: eligible)
    }

    private func monitoringSubscriptions() -> [NotificationSubscription] {
        var byID: [String: NotificationSubscription] = [:]
        for subscription in cachedScheduledActivations.map(\.subscription)
            where Self.retainsScheduleForRecovery(subscription) {
            byID[subscription.id] = subscription
        }
        for subscription in subscriptions where !NotificationScheduleExpiry.isExpired(subscription) {
            byID[subscription.id] = subscription
        }
        for subscription in geofenceEligibleLiveSessions {
            if subscription.liveSessionOrigin == .scheduled,
               hasCachedScheduledRoute(matching: subscription) {
                continue
            }
            byID[subscription.id] = subscription
        }
        return byID.values.sorted { lhs, rhs in
            nextMonitoringStart(for: lhs) < nextMonitoringStart(for: rhs)
        }
    }

    private func nextMonitoringStart(for subscription: NotificationSubscription) -> Date {
        subscription.legs
            .filter(\.enabled)
            .compactMap { NotificationScheduleActivationPolicy.nextStart(for: subscription, leg: $0) }
            .min() ?? .distantFuture
    }

    private func hasCachedScheduledRoute(matching session: NotificationSubscription) -> Bool {
        let sessionLegs = session.legs.filter(\.enabled)
        return cachedScheduledActivations.contains { activation in
            activation.subscription.legs.filter(\.enabled).contains { scheduledLeg in
                sessionLegs.contains {
                    $0.from.caseInsensitiveCompare(scheduledLeg.from) == .orderedSame
                        && $0.to.caseInsensitiveCompare(scheduledLeg.to) == .orderedSame
                }
            }
        }
    }

    private var geofenceEligibleLiveSessions: [NotificationSubscription] {
        return liveSessions.compactMap { session in
            if let activeUntil = session.activeUntil, activeUntil <= Date() {
                return nil
            }

            let activeLegs = session.legs.filter(\.enabled)
            guard !activeLegs.isEmpty else { return nil }

            return NotificationSubscription(
                id: session.id,
                deviceId: session.deviceId,
                routeKey: session.routeKey,
                scheduleKind: session.scheduleKind,
                daysOfWeek: session.daysOfWeek,
                notificationTypes: session.notificationTypes,
                legs: activeLegs,
                muteOnArrival: session.muteOnArrival,
                source: session.source,
                liveSessionOrigin: session.liveSessionOrigin,
                activeUntil: session.activeUntil,
                mutedByLegDay: session.mutedByLegDay,
                mutedAtByLegDay: session.mutedAtByLegDay,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt
            )
        }
    }

    private func loadScheduledActivations() {
        guard let data = activationDefaults.data(forKey: scheduledActivationsKey),
              let decoded = try? JSONDecoder().decode([PersistedScheduledJourneyActivation].self, from: data) else {
            return
        }
        hasAuthoritativeScheduledActivationCache = true
        cachedScheduledActivations = decoded.filter {
            Self.retainsScheduleForRecovery($0.subscription)
        }
    }

    private func refreshScheduledActivationCache() async {
        if StationsService.shared.stations.isEmpty {
            try? await StationsService.shared.loadStations()
        }

        let currentStations = StationsService.shared.stations.reduce(into: [String: Station]()) { result, station in
            if result[station.crs.uppercased()] == nil {
                result[station.crs.uppercased()] = station
            }
        }
        let previousByID = Dictionary(uniqueKeysWithValues: cachedScheduledActivations.map {
            ($0.subscription.id, $0)
        })
        let retainedExpired = cachedScheduledActivations.map(\.subscription).filter { cached in
            NotificationScheduleExpiry.isExpired(cached) && Self.retainsScheduleForRecovery(cached)
                && !subscriptions.contains(where: { $0.id == cached.id })
        }
        cachedScheduledActivations = (subscriptions + retainedExpired)
            .filter { Self.retainsScheduleForRecovery($0) }
            .map { subscription in
                let previousStations = Dictionary(uniqueKeysWithValues: (previousByID[subscription.id]?.stations ?? []).map {
                    ($0.crs.uppercased(), $0)
                })
                let requiredCodes = Set(subscription.legs.flatMap {
                    [$0.from.uppercased(), $0.to.uppercased()]
                })
                let stations = requiredCodes.compactMap { currentStations[$0] ?? previousStations[$0] }
                    .filter(\.hasUsableCoordinate)
                return PersistedScheduledJourneyActivation(
                    subscription: subscription,
                    stations: stations,
                    recoveryGeometries: previousByID[subscription.id]?.recoveryGeometries?.filter { geometry in
                        subscription.legs.contains {
                            $0.enabled && $0.from.uppercased() == geometry.from && $0.to.uppercased() == geometry.to
                        }
                    }
                )
            }

        persistScheduledActivations()
    }

    private static func retainsScheduleForRecovery(_ subscription: NotificationSubscription, now: Date = Date()) -> Bool {
        guard let expiration = NotificationScheduleExpiry.expirationDate(for: subscription) else { return true }
        return now < expiration.addingTimeInterval(StationDetectionPolicy.recoveryLifetime)
    }

    private func persistScheduledActivations() {
        guard let data = try? JSONEncoder().encode(cachedScheduledActivations) else { return }
        activationDefaults.set(data, forKey: scheduledActivationsKey)
        hasAuthoritativeScheduledActivationCache = true
    }

    private func refreshScheduledRecoveryGeometry() async {
        guard !isRefreshingRecoveryGeometry, !Task.isCancelled else { return }
        let now = Date()
        var routes: [String: (from: String, to: String)] = [:]
        for activation in cachedScheduledActivations where !NotificationScheduleExpiry.isExpired(activation.subscription) {
            for leg in activation.subscription.legs where leg.enabled {
                let from = leg.from.uppercased()
                let to = leg.to.uppercased()
                let previous = activation.recoveryGeometries?.first { $0.from == from && $0.to == to }
                if let previous, now.timeIntervalSince(previous.attemptedAt) < 24 * 60 * 60 { continue }
                routes["\(from)_\(to)"] = (from, to)
            }
        }
        guard !routes.isEmpty else { return }
        isRefreshingRecoveryGeometry = true
        defer { isRefreshingRecoveryGeometry = false }
        let stations = StationsService.shared.stations.reduce(into: locallyCachedScheduledStations) { result, station in
            if station.hasUsableCoordinate { result[station.crs.uppercased()] = station }
        }

        // Origin and destination conditions are already installed. Bound this optional
        // enrichment so saving a schedule never depends on a lengthy network response.
        let work = Task { @MainActor () -> [String: [Station]] in
            var boards = DeparturesStore.shared.departuresByPair
            let missingRoutes = routes.filter { (boards[$0.key] ?? []).isEmpty }.map(\.value)
            if !missingRoutes.isEmpty,
               let snapshots = try? await NetworkServicePhone.shared.fetchDeparturesAggregated(
                   pairs: missingRoutes, delayBeforeEachBatch: false
               ) {
                for (key, snapshot) in snapshots { boards[key] = snapshot.departures }
            }
            guard !Task.isCancelled else { return [:] }
            let idsByRoute = routes.mapValues { route in
                Array((boards["\(route.from)_\(route.to)"] ?? []).filter { !$0.isCancelled }.prefix(3).map(\.serviceID))
            }
            var details = DeparturesStore.shared.serviceDetailsById
            let missingIDs = Set(idsByRoute.values.flatMap { $0 }).filter { details[$0] == nil }
            if !missingIDs.isEmpty,
               let fetched = try? await NetworkServicePhone.shared.fetchServiceDetailsAggregatedChunked(ids: Array(missingIDs)) {
                details.merge(fetched) { _, new in new }
            }
            guard !Task.isCancelled else { return [:] }
            var result: [String: [Station]] = [:]
            for (key, route) in routes {
                for id in idsByRoute[key] ?? [] {
                    guard let detail = details[id],
                          let codes = ScheduledJourneyRecoveryGeometryPolicy.intermediateStationCodes(
                              in: detail.stationBranches.map { $0.map(\.crs) }, from: route.from, to: route.to
                          ) else { continue }
                    result[key] = codes.compactMap { stations[$0] }
                    break
                }
            }
            return result
        }
        let timeout = Task {
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            work.cancel()
        }
        defer { timeout.cancel() }
        let refreshed = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled else { return }
        for index in cachedScheduledActivations.indices {
            var geometries = cachedScheduledActivations[index].recoveryGeometries ?? []
            for leg in cachedScheduledActivations[index].subscription.legs where leg.enabled {
                let from = leg.from.uppercased()
                let to = leg.to.uppercased()
                let key = "\(from)_\(to)"
                guard routes[key] != nil else { continue }
                let previous = geometries.first { $0.from == from && $0.to == to }
                geometries.removeAll { $0.from == from && $0.to == to }
                geometries.append(PersistedScheduledRecoveryGeometry(
                    from: from, to: to, stations: refreshed[key] ?? previous?.stations ?? [], attemptedAt: now
                ))
            }
            cachedScheduledActivations[index].recoveryGeometries = geometries
        }
        persistScheduledActivations()
        await syncGeofences()
    }

    private func logGeofenceEligibility(eligible: [NotificationSubscription]) {
        let now = Date()
        let expiredCount = liveSessions.filter { session in
            guard let activeUntil = session.activeUntil else { return false }
            return activeUntil <= now
        }.count
        let noEnabledLegsCount = liveSessions.filter { $0.legs.filter(\.enabled).isEmpty }.count

        let sessionSummaries = liveSessions.prefix(6).map { session -> String in
            let enabledLegs = session.legs.filter(\.enabled)
            let reasons = geofenceSkipReasons(for: session, now: now, enabledLegs: enabledLegs)
            if reasons.isEmpty {
                let activeUntil = session.activeUntil.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
                let legs = enabledLegs.map { "\($0.from.uppercased())→\($0.to.uppercased())" }.joined(separator: ",")
                return "\(session.routeKey)#\(String(session.id.prefix(8))):eligible legs=\(legs.isEmpty ? "none" : legs) until=\(activeUntil)"
            }
            let activeUntil = session.activeUntil.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
            let legs = enabledLegs.map { "\($0.from.uppercased())→\($0.to.uppercased())" }.joined(separator: ",")
            return "\(session.routeKey)#\(String(session.id.prefix(8))):\(reasons.joined(separator: "+")) legs=\(legs.isEmpty ? "none" : legs) until=\(activeUntil)"
        }.joined(separator: "\n")

        DebugLogStore.shared.log(
            """
            Geofence eligibility
            Scheduled: \(cachedScheduledActivations.count)
            Live sessions: \(liveSessions.count)
            Eligible: \(eligible.count)
            Skipped: expired=\(expiredCount), noEnabledLegs=\(noEnabledLegsCount)
            \(sessionSummaries.isEmpty ? "Sessions: none" : sessionSummaries)
            """,
            category: "Geofence"
        )
        ClientDiagnosticsLogger.log("geofence", "eligibility", metadata: [
            "scheduled_count": cachedScheduledActivations.count,
            "live_session_count": liveSessions.count,
            "eligible_count": eligible.count,
            "skipped_expired": expiredCount,
            "skipped_no_enabled_legs": noEnabledLegsCount,
            "sessions": liveSessions.prefix(6).map { session in
                let enabledLegs = session.legs.filter(\.enabled)
                let reasons = geofenceSkipReasons(for: session, now: now, enabledLegs: enabledLegs)
                return [
                    "id": session.id,
                    "route_key": session.routeKey,
                    "source": session.source ?? "nil",
                    "active_until": session.activeUntil.map { ISO8601DateFormatter().string(from: $0) } ?? "nil",
                    "enabled_legs": enabledLegs.map { "\($0.from.uppercased())-\($0.to.uppercased())" },
                    "skip_reasons": reasons
                ] as [String: Any]
            }
        ])
    }

    private func geofenceSkipReasons(
        for session: NotificationSubscription,
        now: Date,
        enabledLegs: [NotificationLeg]
    ) -> [String] {
        var reasons: [String] = []
        if let activeUntil = session.activeUntil, activeUntil <= now {
            reasons.append("expired")
        }
        if enabledLegs.isEmpty {
            reasons.append("noEnabledLegs")
        }
        return reasons
    }
}

private struct NotificationSubscriptionResponse: Codable {
    let subscription: NotificationSubscription
}

private struct NotificationSubscriptionListResponse: Codable {
    let subscriptions: [NotificationSubscription]
}

private struct NotificationSubscriptionDeleteRequest: Codable {
    let deviceId: String
    let subscriptionId: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case subscriptionId = "subscription_id"
    }
}

private struct HolidayModeRequest: Encodable {
    let deviceId: String
    let enabled: Bool

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case enabled
    }
}

private struct NotificationAPIErrorResponse: Codable {
    let error: String
}

private struct NotificationServiceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
