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

    private var knownSubscriptionIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Self.knownIDsKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: Self.knownIDsKey) }
    }

    private var hasBootstrappedKnownIDs: Bool {
        get { UserDefaults.standard.bool(forKey: Self.knownIDsBootstrappedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.knownIDsBootstrappedKey) }
    }

    // MARK: - Init

    private init() {
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
            liveSessions = fetchedLive
            hasLoadedRemoteState = true
            hasLoadedOnce = true
            lastError = nil
            NotificationMuteRequestSender.shared.retryPendingMuteRequests(trigger: "subscription-refresh")
            await syncGeofences()
        } catch {
            lastError = error.localizedDescription
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
        await refresh()
        return subscriptions.first(where: { $0.id == subscription.id }) ?? subscription
    }

    func delete(id: String) async throws {
        try await service.deleteSubscription(id: id)
        subscriptions.removeAll { $0.id == id }
        var known = knownSubscriptionIDs
        known.remove(id)
        knownSubscriptionIDs = known
        hasLoadedRemoteState = true
        await syncGeofences()
    }

    func subscription(for routeKey: String) -> NotificationSubscription? {
        subscriptions.first { $0.routeKey == routeKey }
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
        await JourneyTrackingCoordinator.shared.arm(subscription: subscription, source: historySource)
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
            scheduled: subscriptions,
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

    var canCreateNew: Bool { subscriptions.count < ServerConfigStore.shared.maxSubscriptionsPerDevice }
    var canCreateNewLiveSession: Bool { liveSessions.count < ServerConfigStore.shared.maxLiveSessionsPerDevice }

    func syncGeofencesNow() async {
        guard hasLoadedRemoteState else { return }
        await syncGeofences()
    }

    func applyGlobalNotificationTypes() async throws {
        let scheduled = subscriptions
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
        let eligible = geofenceEligibleLiveSessions
        logGeofenceEligibility(eligible: eligible)
        await NotificationGeofenceManager.shared.sync(subscriptions: eligible)
    }

    private var geofenceEligibleLiveSessions: [NotificationSubscription] {
        return liveSessions.compactMap { session in
            guard session.muteOnArrival != false else { return nil }
            if let activeUntil = session.activeUntil, activeUntil <= Date() {
                return nil
            }

            let activeLegs = session.legs.filter(\.enabled)
            guard !activeLegs.isEmpty else { return nil }

            return NotificationSubscription(
                id: session.id,
                deviceId: session.deviceId,
                routeKey: session.routeKey,
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

    private func logGeofenceEligibility(eligible: [NotificationSubscription]) {
        let now = Date()
        let muteDisabledCount = liveSessions.filter { $0.muteOnArrival == false }.count
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
            Live sessions: \(liveSessions.count)
            Eligible: \(eligible.count)
            Skipped: muteOff=\(muteDisabledCount), expired=\(expiredCount), noEnabledLegs=\(noEnabledLegsCount)
            \(sessionSummaries.isEmpty ? "Sessions: none" : sessionSummaries)
            """,
            category: "Geofence"
        )
        ClientDiagnosticsLogger.log("geofence", "eligibility", metadata: [
            "live_session_count": liveSessions.count,
            "eligible_count": eligible.count,
            "skipped_mute_off": muteDisabledCount,
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
        if session.muteOnArrival == false {
            reasons.append("muteOff")
        }
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
