import Foundation
import Observation
import Combine
import UserNotifications

enum DisruptionMonitoringError: Error {
    case deviceDeleted
    case rejected(String)
    case unavailable
}

enum DisruptionMonitoringClient {
    static func replace(_ snapshot: DisruptionMonitorSnapshot) async throws -> DisruptionMonitoringResponse {
        #if DEBUG
        // A hosted unit-test app can run its normal scene tasks. Tests inject their
        // own transport; never register simulator fixtures with the selected server.
        if NSClassFromString("XCTestCase") != nil { throw DisruptionMonitoringError.unavailable }
        #endif
        guard let url = URL(string: "\(ApiHostPreference.currentBaseURL)/disruptions/monitors") else {
            throw DisruptionMonitoringError.unavailable
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(snapshot.deviceID, forHTTPHeaderField: "X-Device-Token")
        request.httpBody = try JSONEncoder().encode(snapshot)
        let started = ContinuousClock.now
        ClientPerf.log("advance.http.start monitors=\(snapshot.monitors.count)")
        let (data, response): (Data, URLResponse)
        do {
            let metrics = ClientTaskMetricsDelegate()
            (data, response) = try await URLSession.shared.data(for: request, delegate: metrics)
            if let summary = metrics.summary() {
                ClientPerf.log("advance.http.metrics \(summary)")
            }
        } catch {
            ClientPerf.log("advance.http.failed elapsedMs=\(ClientPerf.elapsedMilliseconds(since: started)) \(ClientPerf.errorMetadata(error))")
            throw error
        }
        ClientPerf.log("advance.http.end elapsedMs=\(ClientPerf.elapsedMilliseconds(since: started)) status=\((response as? HTTPURLResponse)?.statusCode ?? 0) bytes=\(data.count)")
        guard let http = response as? HTTPURLResponse else { throw DisruptionMonitoringError.unavailable }
        if http.statusCode == 410 { throw DisruptionMonitoringError.deviceDeleted }
        if (400..<500).contains(http.statusCode),
           let error = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            throw DisruptionMonitoringError.rejected(error.error.message)
        }
        guard (200..<300).contains(http.statusCode) else { throw DisruptionMonitoringError.unavailable }
        return try DisruptionDate.decoder().decode(DisruptionMonitoringResponse.self, from: data)
    }

    private struct ErrorResponse: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}

@MainActor
@Observable
final class DisruptionMonitoringStore {
    static let shared = DisruptionMonitoringStore()

    private(set) var response: DisruptionMonitoringResponse?
    private(set) var lastError: String?
    private(set) var isRefreshing = false
    private(set) var isSuspended: Bool
    var presentedGroup: JourneyGroup?
    var presentedFutureGroup: JourneyGroup?

    private var preferences: [String: DisruptionMonitorSettings]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let replace: (DisruptionMonitorSnapshot) async throws -> DisruptionMonitoringResponse
    @ObservationIgnored private let groups: @MainActor () -> [JourneyGroup]
    @ObservationIgnored private let subscriptions: @MainActor () -> [NotificationSubscription]
    @ObservationIgnored private let schedulesLoaded: @MainActor () -> Bool
    @ObservationIgnored private let pushAuthorized: () async -> Bool
    @ObservationIgnored private var observations: [AnyCancellable] = []
    @ObservationIgnored private var needsSync = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var responseHost: String?

    private static let settingsKey = "disruption_monitor_settings_v1"
    private static let responseKey = "disruption_monitor_response_v1"
    private static let suspendedKey = "disruption_monitor_suspended_v1"
    private static let hostKey = "disruption_monitor_host_v1"

    init(
        defaults: UserDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard,
        replace: @escaping (DisruptionMonitorSnapshot) async throws -> DisruptionMonitoringResponse = DisruptionMonitoringClient.replace,
        groups: @escaping @MainActor () -> [JourneyGroup] = { JourneyStore.shared.journeyGroups() },
        subscriptions: @escaping @MainActor () -> [NotificationSubscription] = { NotificationSubscriptionStore.shared.subscriptions },
        schedulesLoaded: @escaping @MainActor () -> Bool = { NotificationSubscriptionStore.shared.hasLoadedOnce },
        pushAuthorized: @escaping () async -> Bool = {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        }
    ) {
        self.defaults = defaults
        self.replace = replace
        self.groups = groups
        self.subscriptions = subscriptions
        self.schedulesLoaded = schedulesLoaded
        self.pushAuthorized = pushAuthorized
        preferences = defaults.data(forKey: Self.settingsKey)
            .flatMap { try? JSONDecoder().decode([String: DisruptionMonitorSettings].self, from: $0) } ?? [:]
        isSuspended = defaults.bool(forKey: Self.suspendedKey)
        responseHost = defaults.string(forKey: Self.hostKey)
        if responseHost == ApiHostPreference.currentBaseURL, !isSuspended {
            response = defaults.data(forKey: Self.responseKey)
                .flatMap { try? JSONDecoder().decode(DisruptionMonitoringResponse.self, from: $0) }
        }
    }

    func start() {
        guard observations.isEmpty else { return }
        observations = [
            JourneyStore.shared.$journeys.dropFirst().sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            },
            NotificationSubscriptionStore.shared.$subscriptions.dropFirst().sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        ]
    }

    func settings(for group: JourneyGroup) -> DisruptionMonitorSettings {
        preferences[canonicalID(for: group).uuidString] ?? .seeded(for: group, subscriptions: subscriptions())
    }

    func save(_ settings: DisruptionMonitorSettings, for group: JourneyGroup) {
        preferences[canonicalID(for: group).uuidString] = settings
        persistPreferences()
        Task { await refresh() }
    }

    func refreshOnForeground() async {
        guard !isSuspended else { return }
        if groups().contains(where: { settings(for: $0).pushEnabled }) {
            // APNs tokens can change between launches. This checks existing permission
            // only; the permission prompt belongs to the explicit settings toggle.
            await NotificationAuthorizationManager.registerIfAuthorized()
        }
        await refresh()
    }

    /// Full replacement snapshots remove deleted routes, including after an offline
    /// deletion. Serialize requests so an older snapshot cannot recreate a deleted route.
    func refresh() async {
        guard !isSuspended else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["APP_STORE_SCREENSHOTS"] == "1" { return }
        #endif
        revision += 1
        needsSync = true
        guard !isRefreshing else {
            ClientPerf.log("advance.sync.coalesced revision=\(revision)")
            return
        }
        isRefreshing = true
        let started = ContinuousClock.now
        ClientPerf.log("advance.sync.start revision=\(revision)")
        defer {
            isRefreshing = false
            ClientPerf.log("advance.sync.end elapsedMs=\(ClientPerf.elapsedMilliseconds(since: started)) revision=\(revision)")
        }
        let authorized = await pushAuthorized()
        while needsSync && !isSuspended && !Task.isCancelled {
            guard !Task.isCancelled, !isSuspended else { return }
            // Revisions received while checking notification permission are already
            // represented in this snapshot and must not force a duplicate upload.
            needsSync = false
            let currentRevision = revision
            let currentHost = ApiHostPreference.currentBaseURL
            if responseHost != currentHost { response = nil }
            var routes = Set<[String]>()
            let saved = groups().sorted { $0.id.uuidString < $1.id.uuidString }.filter {
                routes.insert($0.stationSequence.map { $0.crs.uppercased() }).inserted
            }
            let savedIDs = Set(saved.map { $0.id.uuidString })
            preferences = preferences.filter { savedIDs.contains($0.key) }
            let monitors = saved.map { group in
                let settings = settings(for: group)
                if schedulesLoaded() || settings != DisruptionMonitorSettings() {
                    preferences[group.id.uuidString] = settings
                }
                return DisruptionMonitorRegistration(group: group, settings: settings, pushAuthorized: authorized)
            }
            persistPreferences()
            let snapshot = DisruptionMonitorSnapshot(
                deviceID: DeviceIdentity.deviceToken, monitors: monitors,
                pushToken: authorized ? NotificationPushTokenStore.token : nil,
                useSandbox: notificationAPNsSandboxEnabled()
            )
            do {
                let result = try await replace(snapshot)
                guard !Task.isCancelled, !isSuspended else { return }
                guard currentRevision == revision, currentHost == ApiHostPreference.currentBaseURL else {
                    needsSync = true
                    continue
                }
                response = result
                responseHost = currentHost
                lastError = nil
                ClientPerf.log("advance.sync.applied elapsedMs=\(ClientPerf.elapsedMilliseconds(since: started)) mode=\(result.mode) monitors=\(result.monitors.count)")
                defaults.set(try? JSONEncoder().encode(result), forKey: Self.responseKey)
                defaults.set(currentHost, forKey: Self.hostKey)
            } catch DisruptionMonitoringError.deviceDeleted {
                suspendAfterDataDeletion()
            } catch DisruptionMonitoringError.rejected(let message) {
                ClientPerf.log("advance.sync.rejected elapsedMs=\(ClientPerf.elapsedMilliseconds(since: started))")
                lastError = "Advance warning settings could not be saved. \(message)"
                needsSync = false
            } catch is CancellationError {
                return
            } catch {
                ClientPerf.log("advance.sync.failed elapsedMs=\(ClientPerf.elapsedMilliseconds(since: started)) errorType=\(type(of: error))")
                lastError = "Upcoming disruption checks could not be refreshed. We’ll try again when you next open the app."
                // Don't retry continuously while offline. Local settings/deletions remain
                // the source of truth and will be uploaded on the next foreground refresh.
                needsSync = false
            }
        }
    }

    func suspendAfterDataDeletion() {
        revision += 1
        needsSync = false
        isSuspended = true
        response = nil
        lastError = nil
        defaults.set(true, forKey: Self.suspendedKey)
        defaults.removeObject(forKey: Self.responseKey)
    }

    func advisories(for group: JourneyGroup, now: Date = Date()) -> [DisruptionAdvisory] {
        guard !isSuspended, settings(for: group).enabled else { return [] }
        return response?.visibleAdvisories(for: canonicalID(for: group), now: now) ?? []
    }

    func status(for group: JourneyGroup) -> DisruptionMonitorStatus? {
        response?.monitors.first { UUID(uuidString: $0.id) == canonicalID(for: group) }
    }

    func summary(for group: JourneyGroup, now: Date = Date()) -> String {
        if isSuspended { return "Advance checks paused after data deletion" }
        if !settings(for: group).enabled { return "Advance disruption checks off" }
        if let first = advisories(for: group, now: now).first { return first.title }
        if lastError != nil { return "Advance checks could not be refreshed" }
        if let response, response.mode != "active" { return "Advance checks are being prepared" }
        guard let status = status(for: group) else { return "Awaiting first disruption check" }
        if status.isStale(now: now) { return "Advance disruption checks need updating" }
        switch status.status {
        case "checked": return "No changes found in completed checks"
        case "disabled": return "Advance disruption checks off"
        case "unavailable": return "Upcoming journeys could not be verified"
        default: return "Awaiting upcoming journey checks"
        }
    }

    func openNotification(monitorID: String) {
        guard let id = UUID(uuidString: monitorID), let group = groups().first(where: { $0.id == id }) else {
            ToastStore.shared.show("This journey is no longer saved", icon: "info.circle")
            return
        }
        TabRouter.shared.selected = group.favorite ? .favourites : .myJourneys
        presentedGroup = group
        Task { await refresh() }
    }

    private func persistPreferences() {
        defaults.set(try? JSONEncoder().encode(preferences), forKey: Self.settingsKey)
    }

    private func canonicalID(for group: JourneyGroup) -> UUID {
        let route = group.stationSequence.map { $0.crs.uppercased() }
        return groups().filter { $0.stationSequence.map { $0.crs.uppercased() } == route }
            .map(\.id).min { $0.uuidString < $1.uuidString } ?? group.id
    }
}
