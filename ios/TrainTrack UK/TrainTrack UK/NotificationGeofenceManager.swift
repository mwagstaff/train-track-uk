import Foundation
import CoreLocation
import UserNotifications
import UIKit

// MARK: - Shared Utilities

private func currentDateKey() -> String {
    NotificationMuteStorage.currentDateKey()
}

private struct StationArrivalTarget: Codable {
    let identifier: String
    let subscriptionId: String
    let from: String
    let to: String
    let station: Station
    let activeUntil: Date?
    let muteOnArrival: Bool?
    let isScheduledActivation: Bool?
    let scheduleKind: NotificationScheduleKind?
    let daysOfWeek: [DayOfWeek]?
    let windowStart: String?
    let windowEnd: String?
    let travelDate: String?

    func distance(from location: CLLocation) -> CLLocationDistance {
        station.distance(from: location)
    }
}

private struct StationArrivalConfirmationState {
    var confirmationStartedAt: Date?
    var lastQualifiedAt: Date?
    var lastLocationTimestamp: Date?
    var lastRawDistance: CLLocationDistance?
    var lastCompensatedDistance: CLLocationDistance?
    var lastHorizontalAccuracy: CLLocationAccuracy?
    var lastRegionHintAt: Date?
    var departureConfirmationStartedAt: Date?
    var isFiring = false

    mutating func reset() {
        confirmationStartedAt = nil
        lastQualifiedAt = nil
        lastRegionHintAt = nil
        departureConfirmationStartedAt = nil
        isFiring = false
    }
}

struct NotificationGeofenceDebugSnapshot {
    let monitoredRegionIdentifiers: [String]
    let monitoredTargetCount: Int
    let trackingMode: String
    let authorizationStatus: String
    let backgroundLocationEnabled: Bool
    let backgroundActivityActive: Bool
    let locationServiceSessionActive: Bool
}

// MARK: - Geofence Manager

@MainActor
final class NotificationGeofenceManager: NSObject, CLLocationManagerDelegate {
    static let shared = NotificationGeofenceManager()

    private enum ArrivalConfig {
        static let regionRadiusMeters: CLLocationDistance = 250
        // Tight inner geofence. Entering it is treated as arrival directly, without relying
        // on continuous background location surviving the approach. Kept at the upper end of
        // CLCircularRegion's reliable range (~100–150m) so the OS triggers it dependably,
        // even when the app was suspended/terminated. See STATION_ARRIVAL_DETECTION.md.
        static let arrivalRegionRadiusMeters: CLLocationDistance = 150
        static let arrivalThresholdMeters: CLLocationDistance = 125
        static let activationDistanceMeters: CLLocationDistance = 450
        static let maxActivationAccuracyExpansionMeters: CLLocationDistance = 120
        static let acceptableAccuracyBufferMeters: CLLocationDistance = 50
        static let acceptableAccuracyMinMeters: CLLocationAccuracy = 60
        static let acceptableAccuracyMaxMeters: CLLocationAccuracy = 140
        static let thresholdExpansionFactor = 0.6
        static let maxThresholdExpansionMeters: CLLocationDistance = 45
        static let confirmationDwellSeconds: TimeInterval = 8
        static let regionHintDwellSeconds: TimeInterval = 4
        static let confirmationTimeoutSeconds: TimeInterval = 150
        static let confirmationResetHysteresisMeters: CLLocationDistance = 20
        static let staleLocationCutoffSeconds: TimeInterval = 45
        static let recentRegionHintSeconds: TimeInterval = 30
        static let recentLocationForRegionHintSeconds: TimeInterval = 60
        static let recentLocationForExitCheckSeconds: TimeInterval = 10
        static let precisionSamplingBurstSeconds: TimeInterval = 20
        static let fullAccuracyPurposeKey = "StationArrivalMonitoring"
    }

    private enum TrackingMode {
        case lowSensitivity
        case highSensitivity
    }

    private let manager = CLLocationManager()
    private let persistedTargetsKey = "stationArrivalMonitoredTargets"
    private let conditionMonitorName = "TrainTrackStationDetection"
    private nonisolated let regionPrefix = "tt_notify_mute"
    private nonisolated let arrivalRegionPrefix = "tt_notify_arrival"
    private nonisolated let historyRegionPrefix = "tt_history_"
    static let regionRadiusMeters: CLLocationDistance = ArrivalConfig.regionRadiusMeters
    static let arrivalRegionRadiusMeters: CLLocationDistance = ArrivalConfig.arrivalRegionRadiusMeters

    private nonisolated enum RegionTier {
        case outer  // wide "approach" ring — wakes the app and starts homing
        case inner  // tight "arrival" ring — entering it confirms arrival directly
    }

    // Core Location background sessions aren't available to iOS apps running on macOS.
    private nonisolated var isGeofencingSupported: Bool {
        !ProcessInfo.processInfo.isiOSAppOnMac
    }
    private var monitoredTargets: [String: StationArrivalTarget] = [:]
    private var confirmationStates: [String: StationArrivalConfirmationState] = [:]
    private var outerRegionInsideStates: [String: Bool] = [:]
    private var trackingMode: TrackingMode?
    private var hasRequestedFullAccuracyThisSession = false
    private var precisionSamplingTask: Task<Void, Never>?
    private var conditionMonitor: CLMonitor?
    private var conditionEventsTask: Task<Void, Never>?
    private var monitoredConditionIdentifiers: [String] = []

    private var hasLocationTrackingWork: Bool {
        !monitoredTargets.isEmpty || JourneyTrackingCoordinator.shared.hasActiveJourney
    }

    // iOS 18+ uses CLServiceSession to express the app's "Always" authorization need
    // for this geofencing workflow. Stored as Any? to avoid @available spreading
    // everywhere — we simply cast when needed.
    //
    // On iOS 17 and below, requestAlwaysAuthorization() handles auth instead.
    //
    // Requirements for region monitoring to cold-launch a terminated app:
    //   1. CLServiceSession (iOS 18+) or requestAlwaysAuthorization (iOS <18) ✓
    //   2. authorizedAlways granted by user ✓
    //   3. UIBackgroundModes includes "location" in Info.plist ✓
    //   4. Background App Refresh enabled on device (Settings > General > Background App Refresh)
    //      — this is a user-facing setting; the app cannot enable it programmatically.
    //   5. Delivery remains under system control; the app must recover idempotently whenever
    //      iOS next launches or wakes it rather than assuming a particular trigger fired.
    private var locationServiceSession: Any?
    private var locationServiceDiagnosticsTask: Task<Void, Never>?

    // CLBackgroundActivitySession (iOS 17+) keeps a bounded precision-sampling burst alive
    // after a monitoring event. Always-authorized CLMonitor conditions do not need one held
    // for the whole journey; doing that would keep the blue indicator visible and waste
    // battery. A longer-lived session is retained only for the degraded When In Use case.
    //
    // Stored as Any? to avoid @available spreading everywhere.
    private var backgroundActivitySession: Any?

    private override init() {
        super.init()
        manager.delegate = self
        if isGeofencingSupported {
            restorePersistedTargets()
        }
        configureLowSensitivityTrackingProfile()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        debugLog("📍 [GeofenceManager] init auth=\(manager.authorizationStatus.rawValue) monitored=\(manager.monitoredRegions.count)")
    }

    private func logGeofenceDiagnostic(_ event: String, metadata: [String: Any?] = [:]) {
        var enriched = metadata
        enriched["authorization"] = authorizationStatusDescription(manager.authorizationStatus)
        enriched["accuracy_authorization"] = accuracyAuthorizationDescription
        enriched["tracking_mode"] = trackingModeDescription
        enriched["monitored_region_count"] = monitoredRegionIdentifiers.count
        enriched["monitored_target_count"] = monitoredTargets.count
        enriched["background_location_enabled"] = manager.allowsBackgroundLocationUpdates
        enriched["background_activity_active"] = backgroundActivitySession != nil
        enriched["location_service_session_active"] = locationServiceSession != nil
        enriched["background_refresh_status"] = backgroundRefreshStatusDescription
        enriched["application_state"] = UIApplication.shared.applicationState.rawValue
        ClientDiagnosticsLogger.log("geofence", event, metadata: enriched)
    }

    private var backgroundRefreshStatusDescription: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return "available"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    @available(iOS 18.0, *)
    private func startLocationServiceDiagnostics(_ session: CLServiceSession) {
        locationServiceDiagnosticsTask?.cancel()
        locationServiceDiagnosticsTask = Task { [diagnostics = session.diagnostics] in
            do {
                for try await diagnostic in diagnostics {
                    ClientDiagnosticsLogger.log("geofence", "location_service_session_diagnostic", metadata: [
                        "authorization_denied": diagnostic.authorizationDenied,
                        "always_authorization_denied": diagnostic.alwaysAuthorizationDenied,
                        "authorization_denied_globally": diagnostic.authorizationDeniedGlobally,
                        "authorization_request_in_progress": diagnostic.authorizationRequestInProgress,
                        "authorization_restricted": diagnostic.authorizationRestricted,
                        "full_accuracy_denied": diagnostic.fullAccuracyDenied,
                        "insufficiently_in_use": diagnostic.insufficientlyInUse,
                        "service_session_required": diagnostic.serviceSessionRequired
                    ])
                }
            } catch is CancellationError {
                return
            } catch {
                ClientDiagnosticsLogger.log("geofence", "location_service_session_diagnostics_failed", metadata: [
                    "error": error.localizedDescription
                ])
            }
        }
    }

    func requestAlwaysAuthorizationIfNeeded() {
        guard isGeofencingSupported else { return }
        debugLog("📍 [GeofenceManager] requestAlwaysAuthorizationIfNeeded auth=\(manager.authorizationStatus.rawValue)")
        logGeofenceDiagnostic("request_always_authorization_if_needed")
        if #available(iOS 18.0, *) {
            ensureLocationServiceSessionIfNeeded()
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestAlwaysAuthorization()
        case .authorizedWhenInUse:
            manager.requestAlwaysAuthorization()
        case .authorizedAlways:
            break
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    func stopLocationActivityIfIdle() {
        guard isGeofencingSupported else { return }
        let trackedRegions = manager.monitoredRegions.filter { self.isManagedRegion($0.identifier) }
        guard trackedRegions.isEmpty, monitoredConditionIdentifiers.isEmpty else { return }
        debugLog("📍 [GeofenceManager] stopLocationActivityIfIdle: no tracked regions, clearing background location state")
        stopLocationUpdatesIfNeeded(reason: "idle")
        updateBackgroundLocationState(hasActiveGeofences: false)
    }

    /// Re-establishes the authorization goal and low-power recovery path immediately after
    /// launch. Persisted region targets make this independent of the stations API, which is
    /// essential when Core Location cold-launches the app with weak connectivity.
    func restoreAfterLaunch(trigger: String) async {
        guard isGeofencingSupported else { return }
        await JourneyTrackingCoordinator.shared.restoreAfterLaunch()
        if hasLocationTrackingWork {
            ensureLocationServiceSessionIfNeeded()
        }
        await reconcilePersistedMonitoring(trigger: trigger)
        guard hasLocationTrackingWork || !monitoredConditionIdentifiers.isEmpty else { return }
        ensureLocationServiceSessionIfNeeded()
        updateBackgroundLocationState(hasActiveGeofences: true)
        if hasLocationTrackingWork {
            startLowSensitivityTrackingIfNeeded(reason: "launch-\(trigger)")
        }
        NotificationMuteRequestSender.shared.retryPendingMuteRequests(trigger: "launch-\(trigger)")
        logGeofenceDiagnostic("monitoring_restored_after_launch", metadata: [
            "trigger": trigger,
            "restored_target_count": monitoredTargets.count
        ])
    }

    func sync(subscriptions: [NotificationSubscription]) async {
        guard isGeofencingSupported else {
            logGeofenceDiagnostic("sync_skipped_ios_app_on_mac", metadata: [
                "subscription_count": subscriptions.count
            ])
            return
        }
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            logGeofenceDiagnostic("sync_skipped_monitoring_unavailable", metadata: [
                "subscription_count": subscriptions.count
            ])
            return
        }
        let monitor = await startConditionMonitorIfNeeded()
        let existingConditionIdentifiers = await monitor.identifiers.filter(isManagedRegion)
        let legacyRegions = manager.monitoredRegions.filter { self.isManagedRegion($0.identifier) }
        let existingIdentifiers = Set(existingConditionIdentifiers).union(legacyRegions.map(\.identifier))
        logGeofenceDiagnostic("sync_started", metadata: [
            "subscription_count": subscriptions.count,
            "existing_region_count": existingIdentifiers.count
        ])

        guard !subscriptions.isEmpty || JourneyTrackingCoordinator.shared.hasActiveJourney else {
            await stopMonitoring(existingConditionIdentifiers, with: monitor)
            stopMonitoring(Array(legacyRegions))
            clearArrivalMonitoringState()
            stopLocationUpdatesIfNeeded(reason: "no subscriptions")
            updateBackgroundLocationState(hasActiveGeofences: false)
            let syncMsg = "Geofence sync: 0 desired, +0 added, -\(existingIdentifiers.count) removed"
            Task { @MainActor in
                DebugLogStore.shared.log(syncMsg, category: "Geofence")
            }
            debugLog("📍 \(syncMsg)")
            logGeofenceDiagnostic("sync_completed", metadata: [
                "desired_region_count": 0,
                "added_region_count": 0,
                "removed_region_count": existingIdentifiers.count,
                "reason": "no_subscriptions"
            ])
            return
        }

        if #available(iOS 18.0, *) {
            ensureLocationServiceSessionIfNeeded()
        }
        requestAlwaysAuthorizationIfNeeded()

        guard canMonitorWithCurrentAuthorization else {
            await stopMonitoring(existingConditionIdentifiers, with: monitor)
            stopMonitoring(Array(legacyRegions))
            stopLocationUpdatesIfNeeded(reason: "missing location authorization")
            updateBackgroundLocationState(hasActiveGeofences: false)
            let syncMsg = "Geofence sync skipped: location authorization not granted"
            Task { @MainActor in
                DebugLogStore.shared.log(syncMsg, category: "Geofence")
            }
            debugLog("📍 \(syncMsg)")
            logGeofenceDiagnostic("sync_skipped_missing_authorization", metadata: [
                "subscription_count": subscriptions.count,
                "removed_region_count": existingIdentifiers.count
            ])
            return
        }

        if StationsService.shared.stations.isEmpty
            && NotificationSubscriptionStore.shared.locallyCachedScheduledStations.isEmpty {
            try? await StationsService.shared.loadStations()
        }
        var stationsByCrs = NotificationSubscriptionStore.shared.locallyCachedScheduledStations
        for station in StationsService.shared.stations {
            let key = station.crs.uppercased()
            if stationsByCrs[key] == nil {
                stationsByCrs[key] = station
            }
        }

        // Guard: if stations failed to load, stationsByCrs is empty which would make
        // `desired` empty and cause ALL existing geofences to be silently removed.
        // Bail out early to preserve the existing geofences.
        guard subscriptions.isEmpty || !stationsByCrs.isEmpty else {
            debugLog("⚠️ [GeofenceManager] Stations not loaded — skipping geofence sync to preserve existing regions")
            Task { @MainActor in
                DebugLogStore.shared.log("Stations not loaded — skipping geofence sync to preserve existing regions", category: "Geofence")
            }
            logGeofenceDiagnostic("sync_skipped_stations_not_loaded", metadata: [
                "subscription_count": subscriptions.count,
                "existing_region_count": existingIdentifiers.count
            ])
            return
        }

        let journeyConditions = JourneyTrackingCoordinator.shared.locationConditions()
        var journeyRegions: [String: CLCircularRegion] = [:]
        for condition in journeyConditions {
            let region = CLCircularRegion(
                center: condition.station.coordinate,
                radius: condition.radius,
                identifier: condition.identifier
            )
            region.notifyOnEntry = true
            region.notifyOnExit = condition.kind == .station
            journeyRegions[condition.identifier] = region
        }

        let candidateTargets = desiredTargets(subscriptions: subscriptions, stationsByCrs: stationsByCrs)
        let regionPlan = desiredRegions(
            targets: candidateTargets,
            conditionLimit: max(0, StationDetectionPolicy.maximumMonitoredConditions - journeyRegions.count)
        )
        var desired = journeyRegions
        for (identifier, region) in regionPlan.regions {
            desired[identifier] = region
        }
        let desiredTargets = regionPlan.selectedTargets
        syncMonitoredTargets(desiredTargets)
        outerRegionInsideStates = outerRegionInsideStates.filter { identifier, _ in
            desired[identifier] != nil && regionTier(for: identifier) == .outer
        }

        // Migrate any conditions left by earlier builds to CLMonitor. Its records persist
        // state across launches and expose explicit diagnostics when monitoring is limited.
        stopMonitoring(Array(legacyRegions))

        var removedCount = legacyRegions.count
        for identifier in existingConditionIdentifiers where desired[identifier] == nil {
            await monitor.remove(identifier)
            removedCount += 1
        }

        var addedCount = 0
        for (identifier, region) in desired {
            if !existingConditionIdentifiers.contains(identifier) {
                let condition = CLMonitor.CircularGeographicCondition(
                    center: region.center,
                    radius: region.radius
                )
                await monitor.add(condition, identifier: identifier, assuming: .unsatisfied)
                addedCount += 1
                logGeofenceDiagnostic("monitoring_started", metadata: ["region_id": identifier])
            }
        }
        monitoredConditionIdentifiers = await monitor.identifiers.filter(isManagedRegion)

        updateBackgroundLocationState(hasActiveGeofences: !desired.isEmpty)
        if !desired.isEmpty {
            startLowSensitivityTrackingIfNeeded(reason: "sync")
            if let currentLocation = currentUsableLocation(maxAge: ArrivalConfig.recentLocationForRegionHintSeconds) {
                evaluateArrival(using: currentLocation, source: "sync-current-location")
                await JourneyTrackingCoordinator.shared.evaluateLocation(currentLocation)
            }
        } else {
            stopLocationUpdatesIfNeeded(reason: "sync-empty")
        }

        let syncMsg = "Geofence sync: \(desired.count) desired, +\(addedCount) added, -\(removedCount) removed, tracking=\(desiredTargets.count)"
        Task { @MainActor in
            DebugLogStore.shared.log(syncMsg, category: "Geofence")
        }
        debugLog("📍 \(syncMsg)")
        logGeofenceDiagnostic("sync_completed", metadata: [
            "subscription_count": subscriptions.count,
            "existing_region_count": existingIdentifiers.count,
            "desired_region_count": desired.count,
            "desired_target_count": desiredTargets.count,
            "omitted_target_count": regionPlan.omittedTargetCount,
            "added_region_count": addedCount,
            "removed_region_count": removedCount,
            "target_routes": desiredTargets.values.map { "\($0.from)-\($0.to)" }.sorted()
        ])
    }

    func refreshJourneyConditions() async {
        await reconcilePersistedMonitoring(trigger: "journey-conditions")
    }

    func reconcileAfterBackgroundWake(trigger: String) async {
        await reconcilePersistedMonitoring(trigger: trigger)
    }

    /// Repairs the durable Core Location state from locally persisted targets and the
    /// active journey checkpoint. This is safe to run on every launch, wake, or phase change.
    private func reconcilePersistedMonitoring(trigger: String) async {
        guard isGeofencingSupported,
              CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else { return }

        restoreExpectedTargetsFromScheduleCache()
        let monitor = await startConditionMonitorIfNeeded()
        let existing = Set(await monitor.identifiers.filter(isManagedRegion))
        let journeyConditions = JourneyTrackingCoordinator.shared.locationConditions()
        var desired: [String: CLCircularRegion] = [:]
        for condition in journeyConditions {
            let region = CLCircularRegion(
                center: condition.station.coordinate,
                radius: condition.radius,
                identifier: condition.identifier
            )
            region.notifyOnEntry = true
            region.notifyOnExit = condition.kind == .station
            desired[condition.identifier] = region
        }

        let arrivalPlan = desiredRegions(
            targets: monitoredTargets,
            conditionLimit: max(0, StationDetectionPolicy.maximumMonitoredConditions - desired.count)
        )
        for (identifier, region) in arrivalPlan.regions {
            desired[identifier] = region
        }

        var added = 0
        var removed = 0
        var replaced = 0
        var identifiersToReplace = Set<String>()
        for (identifier, region) in desired where existing.contains(identifier) {
            guard let condition = await monitor.record(for: identifier)?.condition
                    as? CLMonitor.CircularGeographicCondition else {
                identifiersToReplace.insert(identifier)
                continue
            }
            let coordinatesMatch = abs(condition.center.latitude - region.center.latitude) < 0.000_001
                && abs(condition.center.longitude - region.center.longitude) < 0.000_001
            let radiusMatches = abs(condition.radius - region.radius) < 0.5
            if !coordinatesMatch || !radiusMatches {
                identifiersToReplace.insert(identifier)
            }
        }
        for identifier in existing where desired[identifier] == nil {
            await monitor.remove(identifier)
            removed += 1
        }
        for identifier in identifiersToReplace {
            await monitor.remove(identifier)
            replaced += 1
        }
        for (identifier, region) in desired
            where !existing.contains(identifier) || identifiersToReplace.contains(identifier) {
            await monitor.add(
                CLMonitor.CircularGeographicCondition(center: region.center, radius: region.radius),
                identifier: identifier,
                assuming: .unsatisfied
            )
            added += 1
        }
        monitoredConditionIdentifiers = await monitor.identifiers.filter(isManagedRegion)

        // CLMonitor records persist across process death. Re-evaluate satisfied records so
        // arming while already inside a station does not depend on a future boundary event.
        for identifier in desired.keys {
            guard let event = await monitor.record(for: identifier)?.lastEvent else { continue }
            if case .satisfied = event.state {
                handleConditionMonitorEvent(event)
            }
        }

        stopMonitoring(Array(manager.monitoredRegions.filter { isManagedRegion($0.identifier) }))
        updateBackgroundLocationState(hasActiveGeofences: !desired.isEmpty)
        if !desired.isEmpty {
            startLowSensitivityTrackingIfNeeded(reason: "reconcile-\(trigger)")
            manager.requestLocation()
        }
        logGeofenceDiagnostic("monitoring_reconciled", metadata: [
            "trigger": trigger,
            "expected_region_count": desired.count,
            "actual_region_count": monitoredConditionIdentifiers.count,
            "added_region_count": added,
            "removed_region_count": removed,
            "replaced_region_count": replaced,
            "target_count": monitoredTargets.count,
            "journey_condition_count": journeyConditions.count
        ])
    }

    private func restoreExpectedTargetsFromScheduleCache() {
        let store = NotificationSubscriptionStore.shared
        let subscriptions = store.locallyCachedMonitoringSubscriptions
        let stations = store.locallyCachedScheduledStations
        let scheduledTargets = desiredTargets(subscriptions: subscriptions, stationsByCrs: stations)

        // Keep active live-session targets and a scheduled target that is already waiting
        // for station exit. Otherwise the durable schedule cache is authoritative.
        monitoredTargets = monitoredTargets.filter { _, target in
            !store.hasAuthoritativeScheduledActivationCache
                || target.isScheduledActivation != true
                || NotificationMuteStorage.hasPendingStationDepartureCleanup(from: target.from, to: target.to)
        }
        for (identifier, target) in scheduledTargets {
            monitoredTargets[identifier] = target
            if confirmationStates[identifier] == nil {
                confirmationStates[identifier] = StationArrivalConfirmationState()
            }
        }
        confirmationStates = confirmationStates.filter { monitoredTargets[$0.key] != nil }
        persistMonitoredTargets()
    }

    private func stopMonitoring(_ regions: [CLRegion]) {
        for region in regions {
            manager.stopMonitoring(for: region)
        }
    }

    private func stopMonitoring(_ identifiers: [String], with monitor: CLMonitor) async {
        for identifier in identifiers {
            await monitor.remove(identifier)
        }
        monitoredConditionIdentifiers.removeAll()
    }

    private func startConditionMonitorIfNeeded() async -> CLMonitor {
        if let conditionMonitor { return conditionMonitor }

        let monitor = await CLMonitor(conditionMonitorName)
        conditionMonitor = monitor
        monitoredConditionIdentifiers = await monitor.identifiers.filter(isManagedRegion)
        conditionEventsTask?.cancel()
        conditionEventsTask = Task { @MainActor [weak self, monitor] in
            do {
                for try await event in await monitor.events {
                    guard !Task.isCancelled else { return }
                    self?.handleConditionMonitorEvent(event)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.logGeofenceDiagnostic("condition_monitor_failed", metadata: [
                    "error": error.localizedDescription
                ])
            }
        }
        logGeofenceDiagnostic("condition_monitor_started", metadata: [
            "condition_count": monitoredConditionIdentifiers.count
        ])
        return monitor
    }

    private func handleConditionMonitorEvent(_ event: CLMonitor.Event) {
        guard isManagedRegion(event.identifier) else { return }
        let stateDescription: String
        switch event.state {
        case .satisfied: stateDescription = "satisfied"
        case .unsatisfied: stateDescription = "unsatisfied"
        case .unknown: stateDescription = "unknown"
        case .unmonitored: stateDescription = "unmonitored"
        @unknown default: stateDescription = "unknown"
        }
        logGeofenceDiagnostic("condition_monitor_event", metadata: [
            "region_id": event.identifier,
            "state": stateDescription,
            "accuracy_limited": event.accuracyLimited,
            "authorization_denied": event.authorizationDenied,
            "condition_limit_exceeded": event.conditionLimitExceeded,
            "condition_unsupported": event.conditionUnsupported,
            "persistence_unavailable": event.persistenceUnavailable,
            "service_session_required": event.serviceSessionRequired
        ])

        let compatibilityRegion = CLCircularRegion(
            center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            radius: 1,
            identifier: event.identifier
        )
        switch event.state {
        case .satisfied:
            locationManager(manager, didEnterRegion: compatibilityRegion)
        case .unsatisfied:
            locationManager(manager, didExitRegion: compatibilityRegion)
        case .unknown:
            break
        case .unmonitored:
            break
        @unknown default:
            break
        }
    }

    private func ensureLocationServiceSessionIfNeeded() {
        guard isGeofencingSupported else { return }
        guard #available(iOS 18.0, *) else { return }
        guard locationServiceSession == nil else { return }
        let session = CLServiceSession(authorization: .always)
        locationServiceSession = session
        startLocationServiceDiagnostics(session)
        logGeofenceDiagnostic("location_service_session_started")
        debugLog("📍 [GeofenceManager] Started CLServiceSession(.always)")
    }

    private func requestTemporaryFullAccuracyIfNeeded() {
        guard #available(iOS 14.0, *) else { return }
        guard canMonitorWithCurrentAuthorization else { return }
        guard manager.accuracyAuthorization == .reducedAccuracy else { return }
        guard UIApplication.shared.applicationState == .active else { return }
        guard !hasRequestedFullAccuracyThisSession else { return }

        hasRequestedFullAccuracyThisSession = true
        let msg = "Requesting temporary full accuracy for station arrival monitoring"
        DebugLogStore.shared.log(msg, category: "Geofence")
        logGeofenceDiagnostic("request_temporary_full_accuracy")
        debugLog("📍 \(msg)")
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: ArrivalConfig.fullAccuracyPurposeKey)
    }

    private var canMonitorWithCurrentAuthorization: Bool {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        case .notDetermined, .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func configureLowSensitivityTrackingProfile() {
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = true
    }

    private func configureHighSensitivityTrackingProfile() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    private func startLowSensitivityTrackingIfNeeded(reason: String) {
        guard isGeofencingSupported else { return }
        guard hasLocationTrackingWork else { return }
        guard canMonitorWithCurrentAuthorization else { return }

        updateBackgroundLocationState(hasActiveGeofences: true)
        requestTemporaryFullAccuracyIfNeeded()

        guard trackingMode == nil else { return }
        configureLowSensitivityTrackingProfile()
        manager.startMonitoringSignificantLocationChanges()
        manager.requestLocation()
        trackingMode = .lowSensitivity

        let msg = "Started low-sensitivity station-arrival tracking (\(reason))"
        DebugLogStore.shared.log(msg, category: "Geofence")
        logGeofenceDiagnostic("tracking_started", metadata: [
            "mode": "low",
            "reason": reason
        ])
        debugLog("📍 \(msg)")
    }

    private func startHighSensitivityTracking(reason: String) {
        guard isGeofencingSupported else { return }
        guard hasLocationTrackingWork else { return }
        guard canMonitorWithCurrentAuthorization else { return }

        updateBackgroundLocationState(hasActiveGeofences: true)
        requestTemporaryFullAccuracyIfNeeded()

        if trackingMode != .highSensitivity {
            precisionSamplingTask?.cancel()
            manager.stopMonitoringSignificantLocationChanges()
            configureHighSensitivityTrackingProfile()
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
            ensureBackgroundActivitySessionIfNeeded()
            manager.startUpdatingLocation()
            trackingMode = .highSensitivity

            precisionSamplingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(ArrivalConfig.precisionSamplingBurstSeconds * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                self?.finishPrecisionSamplingBurst(reason: "burst-timeout")
            }

            let msg = "Started high-sensitivity station-arrival tracking (\(reason))"
            DebugLogStore.shared.log(msg, category: "Geofence")
            logGeofenceDiagnostic("tracking_started", metadata: [
                "mode": "high",
                "reason": reason
            ])
            debugLog("📍 \(msg)")
        }

        manager.requestLocation()
    }

    private func stopLocationUpdatesIfNeeded(reason: String) {
        hasRequestedFullAccuracyThisSession = false
        precisionSamplingTask?.cancel()
        precisionSamplingTask = nil
        guard trackingMode != nil else { return }

        manager.stopUpdatingLocation()
        manager.stopMonitoringSignificantLocationChanges()
        configureLowSensitivityTrackingProfile()
        trackingMode = nil
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        stopBackgroundActivitySessionIfPossible()

        let msg = "Stopped station-arrival location updates (\(reason))"
        DebugLogStore.shared.log(msg, category: "Geofence")
        logGeofenceDiagnostic("tracking_stopped", metadata: [
            "reason": reason
        ])
        debugLog("📍 \(msg)")
    }

    private func updateBackgroundLocationState(hasActiveGeofences: Bool) {
        guard isGeofencingSupported else {
            manager.allowsBackgroundLocationUpdates = false
            manager.showsBackgroundLocationIndicator = false
            return
        }
        let needsWhenInUseBackgroundSession = hasActiveGeofences
            && manager.authorizationStatus == .authorizedWhenInUse
        if trackingMode != .highSensitivity {
            manager.allowsBackgroundLocationUpdates = false
            manager.showsBackgroundLocationIndicator = needsWhenInUseBackgroundSession
        }
        debugLog("📍 [GeofenceManager] updateBackgroundLocationState active=\(hasActiveGeofences) allowsBackground=\(manager.allowsBackgroundLocationUpdates)")

        if #available(iOS 17.0, *) {
            if needsWhenInUseBackgroundSession || trackingMode == .highSensitivity {
                ensureBackgroundActivitySessionIfNeeded()
            } else {
                stopBackgroundActivitySessionIfPossible(force: !hasActiveGeofences)
            }
        }

        if #available(iOS 18.0, *), !hasActiveGeofences {
            if let session = locationServiceSession as? CLServiceSession {
                session.invalidate()
                debugLog("📍 [GeofenceManager] Invalidated CLServiceSession (no active geofences)")
            }
            locationServiceDiagnosticsTask?.cancel()
            locationServiceDiagnosticsTask = nil
            locationServiceSession = nil
            logGeofenceDiagnostic("location_service_session_stopped")
        }

        logGeofenceDiagnostic("background_location_state_updated", metadata: [
            "has_active_geofences": hasActiveGeofences
        ])
    }

    private func ensureBackgroundActivitySessionIfNeeded() {
        guard isGeofencingSupported else { return }
        guard #available(iOS 17.0, *), backgroundActivitySession == nil else { return }
        let session = CLBackgroundActivitySession()
        backgroundActivitySession = session
        logGeofenceDiagnostic("background_activity_started")
        debugLog("📍 [GeofenceManager] Started CLBackgroundActivitySession")
    }

    private func stopBackgroundActivitySessionIfPossible(force: Bool = false) {
        guard isGeofencingSupported else {
            backgroundActivitySession = nil
            return
        }
        guard #available(iOS 17.0, *) else { return }
        let keepForWhenInUse = !force
            && (hasLocationTrackingWork || !monitoredConditionIdentifiers.isEmpty)
            && manager.authorizationStatus == .authorizedWhenInUse
        guard !keepForWhenInUse else { return }

        if let session = backgroundActivitySession as? CLBackgroundActivitySession {
            session.invalidate()
        }
        backgroundActivitySession = nil
        logGeofenceDiagnostic("background_activity_stopped")
        debugLog("📍 [GeofenceManager] Stopped CLBackgroundActivitySession")
    }

    private func finishPrecisionSamplingBurst(reason: String) {
        guard trackingMode == .highSensitivity else { return }
        precisionSamplingTask?.cancel()
        precisionSamplingTask = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = manager.authorizationStatus == .authorizedWhenInUse
        configureLowSensitivityTrackingProfile()
        manager.startMonitoringSignificantLocationChanges()
        trackingMode = .lowSensitivity
        stopBackgroundActivitySessionIfPossible()
        logGeofenceDiagnostic("tracking_downgraded", metadata: ["reason": reason])
        debugLog("📍 Downgraded station tracking after precision burst (\(reason))")
    }

    private func desiredTargets(
        subscriptions: [NotificationSubscription],
        stationsByCrs: [String: Station]
    ) -> [String: StationArrivalTarget] {
        var targets: [String: StationArrivalTarget] = [:]
        for subscription in subscriptions {
            for leg in subscription.legs where leg.enabled {
                guard let station = stationsByCrs[leg.from.uppercased()] else { continue }
                guard station.hasUsableCoordinate else { continue }
                let identifier = regionIdentifier(subscriptionId: subscription.id, from: leg.from, to: leg.to)
                if targets[identifier] != nil { continue }
                targets[identifier] = StationArrivalTarget(
                    identifier: identifier,
                    subscriptionId: subscription.id,
                    from: leg.from.uppercased(),
                    to: leg.to.uppercased(),
                    station: station,
                    activeUntil: subscription.activeUntil,
                    muteOnArrival: subscription.muteOnArrival,
                    isScheduledActivation: subscription.source == .scheduled
                        || (subscription.liveSessionOrigin == nil && subscription.activeUntil == nil),
                    scheduleKind: subscription.scheduleKind,
                    daysOfWeek: subscription.daysOfWeek,
                    windowStart: leg.windowStart,
                    windowEnd: leg.windowEnd,
                    travelDate: leg.travelDate
                )
            }
        }
        return targets
    }

    private func desiredRegions(
        targets: [String: StationArrivalTarget],
        conditionLimit: Int
    ) -> (regions: [String: CLCircularRegion], selectedTargets: [String: StationArrivalTarget], omittedTargetCount: Int) {
        var regions: [String: CLCircularRegion] = [:]
        var selectedTargets: [String: StationArrivalTarget] = [:]
        let currentLocation = currentUsableLocation(maxAge: ArrivalConfig.recentLocationForRegionHintSeconds)
        let prioritized = targets.values.sorted { lhs, rhs in
            let lhsAwaitingExit = NotificationMuteStorage.hasPendingStationDepartureCleanup(from: lhs.from, to: lhs.to)
            let rhsAwaitingExit = NotificationMuteStorage.hasPendingStationDepartureCleanup(from: rhs.from, to: rhs.to)
            if lhsAwaitingExit != rhsAwaitingExit { return lhsAwaitingExit }

            let lhsActive = isTargetActiveNow(lhs)
            let rhsActive = isTargetActiveNow(rhs)
            if lhsActive != rhsActive { return lhsActive }

            if let currentLocation {
                let lhsDistance = lhs.distance(from: currentLocation)
                let rhsDistance = rhs.distance(from: currentLocation)
                if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            }

            let lhsExpiry = lhs.activeUntil ?? .distantFuture
            let rhsExpiry = rhs.activeUntil ?? .distantFuture
            if lhsExpiry != rhsExpiry { return lhsExpiry < rhsExpiry }
            return lhs.identifier < rhs.identifier
        }

        func addRegionPair(for target: StationArrivalTarget, coordinateIndex index: Int) {
            guard regions.count + StationDetectionPolicy.conditionsPerStationCoordinate <= conditionLimit else { return }
            let coordinate = target.station.coordinates[index]
            guard coordinate.latitude != 0 || coordinate.longitude != 0 else { return }

            // Outer "approach" ring (wide). Wakes the app and starts the homing heuristic,
            // and its exit drives departure detection.
            let regionId = index == 0 ? target.identifier : regionIdentifier(
                subscriptionId: target.subscriptionId,
                from: target.from,
                to: target.to,
                coordinateIndex: index
            )
            let region = CLCircularRegion(
                center: coordinate,
                radius: Self.regionRadiusMeters,
                identifier: regionId
            )
            region.notifyOnEntry = true
            region.notifyOnExit = true
            regions[regionId] = region

            // Inner "arrival" ring (tight). Entering it is treated as arrival directly —
            // a region boundary crossing reliably wakes even a suspended/terminated app,
            // so this does not depend on continuous background updates surviving the
            // approach (the failure mode the homing heuristic alone could not cover).
            let arrivalRegionId = arrivalRegionIdentifier(
                subscriptionId: target.subscriptionId,
                from: target.from,
                to: target.to,
                coordinateIndex: index
            )
            let arrivalRegion = CLCircularRegion(
                center: coordinate,
                radius: Self.arrivalRegionRadiusMeters,
                identifier: arrivalRegionId
            )
            arrivalRegion.notifyOnEntry = true
            arrivalRegion.notifyOnExit = false
            regions[arrivalRegionId] = arrivalRegion
            selectedTargets[target.identifier] = target
        }

        // Reserve one inner/outer pair for each highest-priority leg before spending the
        // remaining condition budget on secondary coordinates at large stations.
        for target in prioritized {
            guard regions.count + StationDetectionPolicy.conditionsPerStationCoordinate <= conditionLimit else { break }
            guard !target.station.coordinates.isEmpty else { continue }
            addRegionPair(for: target, coordinateIndex: 0)
        }

        for target in prioritized where selectedTargets[target.identifier] != nil {
            guard target.station.coordinates.count > 1 else { continue }
            for index in target.station.coordinates.indices.dropFirst() {
                guard regions.count + StationDetectionPolicy.conditionsPerStationCoordinate <= conditionLimit else { break }
                addRegionPair(for: target, coordinateIndex: index)
            }
        }

        return (regions, selectedTargets, max(0, targets.count - selectedTargets.count))
    }

    private func isTargetActiveNow(_ target: StationArrivalTarget, now: Date = Date()) -> Bool {
        guard target.isScheduledActivation == true else { return true }
        guard let windowStart = target.windowStart, let windowEnd = target.windowEnd else { return false }
        return NotificationScheduleActivationPolicy.isActive(
            scheduleKind: target.scheduleKind,
            daysOfWeek: target.daysOfWeek ?? [],
            windowStart: windowStart,
            windowEnd: windowEnd,
            travelDate: target.travelDate,
            now: now
        )
    }

    private func syncMonitoredTargets(_ desired: [String: StationArrivalTarget]) {
        monitoredTargets = desired
        confirmationStates = confirmationStates.filter { desired[$0.key] != nil }
        for identifier in desired.keys where confirmationStates[identifier] == nil {
            confirmationStates[identifier] = StationArrivalConfirmationState()
        }
        if desired.isEmpty {
            hasRequestedFullAccuracyThisSession = false
        }
        persistMonitoredTargets()
    }

    private func clearArrivalMonitoringState() {
        monitoredTargets.removeAll()
        confirmationStates.removeAll()
        outerRegionInsideStates.removeAll()
        hasRequestedFullAccuracyThisSession = false
        persistMonitoredTargets()
    }

    private func persistMonitoredTargets() {
        guard let defaults = UserDefaults(suiteName: NotificationMuteStorage.suiteName) else { return }
        let targets = monitoredTargets.values.sorted { $0.identifier < $1.identifier }
        guard let data = try? JSONEncoder().encode(targets) else { return }
        defaults.set(data, forKey: persistedTargetsKey)
    }

    private func restorePersistedTargets(now: Date = Date()) {
        guard let defaults = UserDefaults(suiteName: NotificationMuteStorage.suiteName),
              let data = defaults.data(forKey: persistedTargetsKey),
              let stored = try? JSONDecoder().decode([StationArrivalTarget].self, from: data) else {
            return
        }

        let current = stored.filter { target in
            guard let activeUntil = target.activeUntil else { return true }
            return activeUntil > now
        }
        monitoredTargets = Dictionary(uniqueKeysWithValues: current.map { ($0.identifier, $0) })
        confirmationStates = Dictionary(uniqueKeysWithValues: current.map {
            ($0.identifier, StationArrivalConfirmationState())
        })
    }

    private func currentUsableLocation(maxAge: TimeInterval) -> CLLocation? {
        guard let location = manager.location else { return nil }
        guard location.horizontalAccuracy >= 0 else { return nil }
        guard Date().timeIntervalSince(location.timestamp) <= maxAge else { return nil }
        return location
    }

    private func regionIdentifier(subscriptionId: String, from: String, to: String, coordinateIndex: Int? = nil) -> String {
        let base = "\(regionPrefix):\(subscriptionId):\(from.uppercased()):\(to.uppercased())"
        guard let coordinateIndex, coordinateIndex > 0 else { return base }
        return "\(base):p\(coordinateIndex)"
    }

    private func arrivalRegionIdentifier(subscriptionId: String, from: String, to: String, coordinateIndex: Int? = nil) -> String {
        let base = "\(arrivalRegionPrefix):\(subscriptionId):\(from.uppercased()):\(to.uppercased())"
        guard let coordinateIndex, coordinateIndex > 0 else { return base }
        return "\(base):p\(coordinateIndex)"
    }

    private nonisolated func isManagedRegion(_ identifier: String) -> Bool {
        identifier.hasPrefix(regionPrefix)
            || identifier.hasPrefix(arrivalRegionPrefix)
            || identifier.hasPrefix(historyRegionPrefix)
    }

    private nonisolated func regionTier(for identifier: String) -> RegionTier {
        identifier.hasPrefix(arrivalRegionPrefix) ? .inner : .outer
    }

    private nonisolated func parseRegionIdentifier(_ identifier: String) -> (subscriptionId: String, from: String, to: String)? {
        let parts = identifier.split(separator: ":")
        guard parts.count >= 4, parts[0] == regionPrefix || parts[0] == arrivalRegionPrefix else { return nil }
        return (String(parts[1]), String(parts[2]), String(parts[3]))
    }

    private func acceptableHorizontalAccuracy() -> CLLocationAccuracy {
        let baseline = ArrivalConfig.arrivalThresholdMeters + ArrivalConfig.acceptableAccuracyBufferMeters
        return min(
            ArrivalConfig.acceptableAccuracyMaxMeters,
            max(ArrivalConfig.acceptableAccuracyMinMeters, baseline)
        )
    }

    private func effectiveArrivalThreshold(horizontalAccuracy: CLLocationAccuracy) -> CLLocationDistance {
        let excessAccuracy = max(0, horizontalAccuracy - ArrivalConfig.arrivalThresholdMeters)
        let expansion = min(
            ArrivalConfig.maxThresholdExpansionMeters,
            excessAccuracy * ArrivalConfig.thresholdExpansionFactor
        )
        return ArrivalConfig.arrivalThresholdMeters + expansion
    }

    private func effectiveActivationDistance(horizontalAccuracy: CLLocationAccuracy) -> CLLocationDistance {
        guard horizontalAccuracy > 0 else { return ArrivalConfig.activationDistanceMeters }
        return ArrivalConfig.activationDistanceMeters + min(
            horizontalAccuracy,
            ArrivalConfig.maxActivationAccuracyExpansionMeters
        )
    }

    private func confirmationDwell(for state: StationArrivalConfirmationState, now: Date) -> TimeInterval {
        if let regionHintAt = state.lastRegionHintAt,
           now.timeIntervalSince(regionHintAt) <= ArrivalConfig.recentRegionHintSeconds {
            return ArrivalConfig.regionHintDwellSeconds
        }
        return ArrivalConfig.confirmationDwellSeconds
    }

    private func ensureTargetExists(
        identifier: String,
        parsed: (subscriptionId: String, from: String, to: String)
    ) async -> StationArrivalTarget? {
        guard let target = monitoredTargets[identifier],
              target.subscriptionId == parsed.subscriptionId,
              target.from.caseInsensitiveCompare(parsed.from) == .orderedSame,
              target.to.caseInsensitiveCompare(parsed.to) == .orderedSame else {
            // Persisted expected targets are authoritative. Reconstructing a missing target
            // from a callback identifier could let a stale condition advance the wrong leg.
            logGeofenceDiagnostic("stale_condition_ignored", metadata: [
                "region_id": identifier,
                "subscription_id": parsed.subscriptionId,
                "from": parsed.from,
                "to": parsed.to
            ])
            return nil
        }

        let now = Date()
        if let activeUntil = target.activeUntil, activeUntil <= now {
            logGeofenceDiagnostic("expired_condition_ignored", metadata: ["region_id": identifier])
            return nil
        }

        let isAwaitingDeparture = NotificationMuteStorage.hasPendingStationDepartureCleanup(
            from: target.from,
            to: target.to
        )
        if target.isScheduledActivation == true, !isAwaitingDeparture {
            guard let windowStart = target.windowStart,
                  let windowEnd = target.windowEnd,
                  NotificationScheduleActivationPolicy.isActive(
                    scheduleKind: target.scheduleKind,
                    daysOfWeek: target.daysOfWeek ?? [],
                    windowStart: windowStart,
                    windowEnd: windowEnd,
                    travelDate: target.travelDate,
                    now: now
                  ) else {
                logGeofenceDiagnostic("scheduled_condition_outside_window", metadata: [
                    "region_id": identifier,
                    "subscription_id": target.subscriptionId
                ])
                return nil
            }

            let armed = await NotificationSubscriptionStore.shared.armScheduledJourneyFromCache(
                subscriptionID: target.subscriptionId,
                from: target.from,
                to: target.to,
                now: now
            )
            let matchesActiveJourney = JourneyTrackingCoordinator.shared.activeJourney?.subscriptionId
                == target.subscriptionId
            guard armed || matchesActiveJourney else {
                logGeofenceDiagnostic("scheduled_condition_arm_failed", metadata: [
                    "region_id": identifier,
                    "subscription_id": target.subscriptionId
                ])
                return nil
            }
        }

        return target
    }

    private func handleRegionHint(
        identifier: String,
        parsed: (subscriptionId: String, from: String, to: String),
        source: String
    ) async {
        let targetIdentifier = regionIdentifier(subscriptionId: parsed.subscriptionId, from: parsed.from, to: parsed.to)
        guard let target = await ensureTargetExists(identifier: targetIdentifier, parsed: parsed) else { return }

        var state = confirmationStates[targetIdentifier] ?? StationArrivalConfirmationState()
        state.lastRegionHintAt = Date()
        confirmationStates[targetIdentifier] = state

        startHighSensitivityTracking(reason: "region-\(source)")

        let stationCoordinate = target.station.coordinate
        let msg = String(
            format: "Region hint [%@] for %@→%@ at %@ (target %.5f, %.5f, points %d)",
            source,
            target.from,
            target.to,
            target.station.name,
            stationCoordinate.latitude,
            stationCoordinate.longitude,
            target.station.coordinates.count
        )
        DebugLogStore.shared.log(msg, category: "Geofence")
        logGeofenceDiagnostic("region_hint", metadata: [
            "region_id": identifier,
            "subscription_id": target.subscriptionId,
            "from": target.from,
            "to": target.to,
            "station": target.station.name,
            "source": source,
            "target_latitude": stationCoordinate.latitude,
            "target_longitude": stationCoordinate.longitude,
            "coordinate_count": target.station.coordinates.count
        ])
        debugLog("📍 \(msg)")

        if let location = currentUsableLocation(maxAge: ArrivalConfig.recentLocationForRegionHintSeconds) {
            let rawDistance = target.distance(from: location)
            let cachedMsg = String(
                format: "Region hint [%@] using cached location for %@→%@ (age %.0fs, raw %.0fm, accuracy %.0fm)",
                source,
                target.from,
                target.to,
                Date().timeIntervalSince(location.timestamp),
                rawDistance,
                location.horizontalAccuracy
            )
            DebugLogStore.shared.log(cachedMsg, category: "Geofence")
            debugLog("📍 \(cachedMsg)")
            evaluateArrival(using: location, for: target, source: "region-\(source)-cached")
        } else if canMonitorWithCurrentAuthorization {
            let requestMsg = "Region hint [\(source)] has no recent usable location for \(target.from)→\(target.to); requesting current location"
            DebugLogStore.shared.log(requestMsg, category: "Geofence")
            debugLog("📍 \(requestMsg)")
            manager.requestLocation()
        }
    }

    private func evaluateArrival(using location: CLLocation, source: String) {
        guard location.horizontalAccuracy >= 0 else { return }
        guard Date().timeIntervalSince(location.timestamp) <= ArrivalConfig.staleLocationCutoffSeconds else { return }

        for target in monitoredTargets.values.sorted(by: { $0.identifier < $1.identifier }) {
            if NotificationMuteStorage.hasPendingStationDepartureCleanup(from: target.from, to: target.to) {
                evaluateDeparture(using: location, for: target, source: source)
            } else if target.isScheduledActivation == true,
                      let windowStart = target.windowStart,
                      let windowEnd = target.windowEnd,
                      !NotificationScheduleActivationPolicy.isActive(
                        scheduleKind: target.scheduleKind,
                        daysOfWeek: target.daysOfWeek ?? [],
                        windowStart: windowStart,
                        windowEnd: windowEnd,
                        travelDate: target.travelDate,
                        now: Date()
                      ) {
                continue
            } else {
                evaluateArrival(using: location, for: target, source: source)
            }
        }
    }

    private func evaluateDeparture(using location: CLLocation, for target: StationArrivalTarget, source: String) {
        guard !NotificationMuteStorage.isMutedToday(from: target.from, to: target.to) else { return }

        let rawDistance = target.distance(from: location)
        let definitelyOutside = StationDetectionPolicy.isDefinitelyOutsideStation(
            rawDistance: rawDistance,
            horizontalAccuracy: location.horizontalAccuracy,
            radius: Self.regionRadiusMeters
        )
        var state = confirmationStates[target.identifier] ?? StationArrivalConfirmationState()

        guard definitelyOutside else {
            state.departureConfirmationStartedAt = nil
            confirmationStates[target.identifier] = state
            return
        }

        startHighSensitivityTracking(reason: "departure-fallback-candidate")
        let now = Date()
        if state.departureConfirmationStartedAt == nil {
            state.departureConfirmationStartedAt = now
            confirmationStates[target.identifier] = state
            logGeofenceDiagnostic("departure_confirmation_started", metadata: [
                "subscription_id": target.subscriptionId,
                "from": target.from,
                "to": target.to,
                "raw_distance_m": rawDistance,
                "horizontal_accuracy_m": location.horizontalAccuracy,
                "source": source
            ])
            return
        }

        let dwell = now.timeIntervalSince(state.departureConfirmationStartedAt ?? now)
        confirmationStates[target.identifier] = state
        guard dwell >= StationDetectionPolicy.departureConfirmationSeconds else { return }
        guard NotificationMuteStorage.consumePendingStationDepartureCleanup(from: target.from, to: target.to) else { return }

        finishPrecisionSamplingBurst(reason: "departure-confirmed")
        logGeofenceDiagnostic("departure_confirmed_from_location", metadata: [
            "subscription_id": target.subscriptionId,
            "from": target.from,
            "to": target.to,
            "raw_distance_m": rawDistance,
            "horizontal_accuracy_m": location.horizontalAccuracy,
            "dwell_seconds": dwell,
            "source": source
        ])
        Task { @MainActor in
            await JourneyTrackingCoordinator.shared.handleOriginDeparture(
                subscriptionID: target.subscriptionId,
                from: target.from,
                to: target.to,
                detectedAt: Date()
            )
            if target.muteOnArrival != false {
                await self.triggerMuteFlow(
                    subscriptionId: target.subscriptionId,
                    from: target.from,
                    to: target.to,
                    simulate: false,
                    endLiveActivity: false,
                    detectionSource: "location_fallback",
                    journeyNotificationBody: JourneyTrackingCoordinator.shared.boardingNotificationBody(
                        from: target.from,
                        to: target.to
                    )
                )
            }
        }
    }

    private func evaluateArrival(using location: CLLocation, for target: StationArrivalTarget, source: String) {
        guard !NotificationMuteStorage.isMutedToday(from: target.from, to: target.to) else {
            confirmationStates[target.identifier]?.reset()
            return
        }
        guard !confirmationStates[target.identifier, default: StationArrivalConfirmationState()].isFiring else {
            return
        }

        let rawDistance = target.distance(from: location)
        let horizontalAccuracy = location.horizontalAccuracy
        let now = Date()
        let acceptableAccuracy = acceptableHorizontalAccuracy()
        let compensatedDistance = max(0, rawDistance - max(horizontalAccuracy, 0))

        var state = confirmationStates[target.identifier] ?? StationArrivalConfirmationState()
        state.lastLocationTimestamp = location.timestamp
        state.lastRawDistance = rawDistance
        state.lastCompensatedDistance = compensatedDistance
        state.lastHorizontalAccuracy = horizontalAccuracy

        let activationDistance = effectiveActivationDistance(horizontalAccuracy: horizontalAccuracy)
        let candidateDistance = min(rawDistance, compensatedDistance)
        let hasRecentRegionHint = state.lastRegionHintAt.map {
            now.timeIntervalSince($0) <= ArrivalConfig.confirmationTimeoutSeconds
        } ?? false

        if candidateDistance <= activationDistance {
            startHighSensitivityTracking(reason: "within-activation-distance")
        }

        if candidateDistance > activationDistance, state.confirmationStartedAt == nil {
            if hasRecentRegionHint {
                let msg = String(
                    format: "Arrival evaluation outside activation for %@→%@ (raw %.0fm, compensated %.0fm, accuracy %.0fm, activation %.0fm, source %@)",
                    target.from,
                    target.to,
                    rawDistance,
                    compensatedDistance,
                    horizontalAccuracy,
                    activationDistance,
                    source
                )
                DebugLogStore.shared.log(msg, category: "Geofence")
                debugLog("📍 \(msg)")
            }
            confirmationStates[target.identifier] = state
            return
        }

        guard horizontalAccuracy <= acceptableAccuracy else {
            if hasRecentRegionHint || state.confirmationStartedAt != nil {
                let msg = String(
                    format: "Arrival evaluation waiting for better accuracy for %@→%@ (raw %.0fm, compensated %.0fm, accuracy %.0fm, acceptable %.0fm, source %@)",
                    target.from,
                    target.to,
                    rawDistance,
                    compensatedDistance,
                    horizontalAccuracy,
                    acceptableAccuracy,
                    source
                )
                DebugLogStore.shared.log(msg, category: "Geofence")
                debugLog("📍 \(msg)")
            }
            if let startedAt = state.confirmationStartedAt,
               now.timeIntervalSince(startedAt) > ArrivalConfig.confirmationTimeoutSeconds {
                let msg = String(
                    format: "Arrival confirmation timed out for %@→%@ while accuracy stayed poor (raw %.0fm, accuracy %.0fm)",
                    target.from,
                    target.to,
                    rawDistance,
                    horizontalAccuracy
                )
                DebugLogStore.shared.log(msg, category: "Geofence")
                debugLog("📍 \(msg)")
                logGeofenceDiagnostic("arrival_confirmation_timed_out", metadata: [
                    "from": target.from,
                    "to": target.to,
                    "station": target.station.name,
                    "raw_distance_m": rawDistance,
                    "horizontal_accuracy_m": horizontalAccuracy,
                    "reason": "poor_accuracy"
                ])
                state.reset()
            }
            confirmationStates[target.identifier] = state
            return
        }

        let effectiveThreshold = effectiveArrivalThreshold(horizontalAccuracy: horizontalAccuracy)
        let isCandidate = candidateDistance <= effectiveThreshold

        if isCandidate {
            if state.confirmationStartedAt == nil {
                state.confirmationStartedAt = now
                let msg = String(
                    format: "Arrival confirmation started for %@→%@ at %@ (raw %.0fm, compensated %.0fm, accuracy %.0fm, threshold %.0fm, source %@)",
                    target.from,
                    target.to,
                    target.station.name,
                    rawDistance,
                    compensatedDistance,
                    horizontalAccuracy,
                    effectiveThreshold,
                    source
                )
                DebugLogStore.shared.log(msg, category: "Geofence")
                logGeofenceDiagnostic("arrival_confirmation_started", metadata: [
                    "from": target.from,
                    "to": target.to,
                    "station": target.station.name,
                    "raw_distance_m": rawDistance,
                    "compensated_distance_m": compensatedDistance,
                    "horizontal_accuracy_m": horizontalAccuracy,
                    "threshold_m": effectiveThreshold,
                    "source": source
                ])
                debugLog("📍 \(msg)")
            }

            state.lastQualifiedAt = now
            let requiredDwell = confirmationDwell(for: state, now: now)
            let dwell = now.timeIntervalSince(state.confirmationStartedAt ?? now)
            confirmationStates[target.identifier] = state

            if dwell >= requiredDwell {
                state.isFiring = true
                confirmationStates[target.identifier] = state
                let msg = String(
                    format: "Arrival confirmed for %@→%@ at %@ (raw %.0fm, compensated %.0fm, accuracy %.0fm, threshold %.0fm, dwell %.0fs)",
                    target.from,
                    target.to,
                    target.station.name,
                    rawDistance,
                    compensatedDistance,
                    horizontalAccuracy,
                    effectiveThreshold,
                    dwell
                )
                DebugLogStore.shared.log(msg, category: "Mute")
                logGeofenceDiagnostic("arrival_confirmed", metadata: [
                    "subscription_id": target.subscriptionId,
                    "from": target.from,
                    "to": target.to,
                    "station": target.station.name,
                    "raw_distance_m": rawDistance,
                    "compensated_distance_m": compensatedDistance,
                    "horizontal_accuracy_m": horizontalAccuracy,
                    "threshold_m": effectiveThreshold,
                    "dwell_seconds": dwell
                ])
                debugLog("✅ \(msg)")
                Task { @MainActor in
                    await self.armDepartureCleanupAfterArrival(
                        subscriptionId: target.subscriptionId,
                        from: target.from,
                        to: target.to,
                        source: source
                    )
                }
            }
            return
        }

        if hasRecentRegionHint || state.confirmationStartedAt != nil {
            let msg = String(
                format: "Arrival evaluation outside threshold for %@→%@ (raw %.0fm, compensated %.0fm, accuracy %.0fm, threshold %.0fm, source %@)",
                target.from,
                target.to,
                rawDistance,
                compensatedDistance,
                horizontalAccuracy,
                effectiveThreshold,
                source
            )
            DebugLogStore.shared.log(msg, category: "Geofence")
            debugLog("📍 \(msg)")
        }

        if let startedAt = state.confirmationStartedAt {
            let elapsed = now.timeIntervalSince(startedAt)
            let resetBoundary = effectiveThreshold + ArrivalConfig.confirmationResetHysteresisMeters
            let clearlyMovedAway = rawDistance > resetBoundary && compensatedDistance > resetBoundary

            if elapsed > ArrivalConfig.confirmationTimeoutSeconds || clearlyMovedAway {
                let msg = String(
                    format: "Arrival confirmation reset for %@→%@ (raw %.0fm, compensated %.0fm, accuracy %.0fm, threshold %.0fm)",
                    target.from,
                    target.to,
                    rawDistance,
                    compensatedDistance,
                    horizontalAccuracy,
                    effectiveThreshold
                )
                DebugLogStore.shared.log(msg, category: "Geofence")
                debugLog("📍 \(msg)")
                logGeofenceDiagnostic("arrival_confirmation_reset", metadata: [
                    "from": target.from,
                    "to": target.to,
                    "station": target.station.name,
                    "raw_distance_m": rawDistance,
                    "compensated_distance_m": compensatedDistance,
                    "horizontal_accuracy_m": horizontalAccuracy,
                    "threshold_m": effectiveThreshold,
                    "elapsed_seconds": elapsed,
                    "reason": elapsed > ArrivalConfig.confirmationTimeoutSeconds ? "timeout" : "moved_away"
                ])
                state.reset()
            }
        }

        confirmationStates[target.identifier] = state
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard isGeofencingSupported else { return }
        guard let circular = region as? CLCircularRegion else { return }
        if circular.identifier.hasPrefix(historyRegionPrefix) {
            let token = AppBackgroundTaskToken(name: "journey-history-entry")
            Task { @MainActor in
                defer { token.end() }
                DebugLogStore.shared.log("Entered journey history condition: \(circular.identifier)", category: "JourneyHistory")
                self.logGeofenceDiagnostic("journey_history_condition_entered", metadata: [
                    "region_id": circular.identifier
                ])
                if let location = manager.location {
                    await JourneyTrackingCoordinator.shared.evaluateLocation(location)
                }
                _ = await JourneyTrackingCoordinator.shared.handleConditionEntry(identifier: circular.identifier)
            }
            return
        }
        guard let parsed = parseRegionIdentifier(circular.identifier) else { return }
        let tier = regionTier(for: circular.identifier)

        // Always log boundary crossings to the server regardless of mute window,
        // so geofence health is visible in the admin even when the app is force-closed.
        GeofenceEventSender.shared.sendEvent(
            regionId: circular.identifier,
            from: parsed.from,
            to: parsed.to,
            eventType: tier == .inner ? "arrival_enter" : "enter"
        )

        // Claim a background task synchronously BEFORE this method returns.
        // Without this, iOS can re-suspend the app immediately after didEnterRegion
        // returns — before the @MainActor task below has had a chance to run.
        // The token is released inside the task (via defer) once the work has been awaited.
        let muteFlowToken = AppBackgroundTaskToken(name: "geofence-entry-mute-flow")

        if tier == .inner {
            // Entering the tight arrival ring IS the arrival. Confirm directly — no dependency
            // on continuous background updates surviving the approach (the root cause of
            // silent misses). The arrival confirmation is idempotent, so this coexists safely
            // with the homing path that the outer ring may also have started.
            let message = "Entered ARRIVAL region: \(circular.identifier)\nSub: \(parsed.subscriptionId)\nFrom: \(parsed.from.uppercased()) To: \(parsed.to.uppercased())"
            Task { @MainActor in
                defer { muteFlowToken.end() }
                DebugLogStore.shared.log(message, category: "Geofence")
                self.logGeofenceDiagnostic("arrival_region_entered", metadata: [
                    "region_id": circular.identifier,
                    "subscription_id": parsed.subscriptionId,
                    "from": parsed.from.uppercased(),
                    "to": parsed.to.uppercased()
                ])
                debugLog("📍 \(message)")
                await self.confirmArrivalFromRegion(parsed: parsed, source: "arrival-region-enter")
            }
            return
        }

        let message = "Entered region: \(circular.identifier)\nSub: \(parsed.subscriptionId)\nFrom: \(parsed.from.uppercased()) To: \(parsed.to.uppercased())"
        Task { @MainActor in
            defer { muteFlowToken.end() }
            let targetIdentifier = self.regionIdentifier(
                subscriptionId: parsed.subscriptionId,
                from: parsed.from,
                to: parsed.to
            )
            guard await self.ensureTargetExists(identifier: targetIdentifier, parsed: parsed) != nil else { return }
            // Record that the user physically reached the origin station only after the
            // persisted target and schedule window have been validated.
            NotificationMuteStorage.markArrivalDetectionPending(from: parsed.from, to: parsed.to)
            self.outerRegionInsideStates[circular.identifier] = true
            DebugLogStore.shared.log(message, category: "Geofence")
            self.logGeofenceDiagnostic("region_entered", metadata: [
                "region_id": circular.identifier,
                "subscription_id": parsed.subscriptionId,
                "from": parsed.from.uppercased(),
                "to": parsed.to.uppercased()
            ])
            debugLog("📍 \(message)")
            await self.handleRegionHint(identifier: circular.identifier, parsed: parsed, source: "enter")
        }
    }

    /// Confirms arrival from a tight inner-ring crossing and arms station-exit cleanup.
    /// Distinct from the homing heuristic: a region crossing is itself the confirmation, so
    /// there is no distance/dwell evaluation here.
    private func confirmArrivalFromRegion(parsed: (subscriptionId: String, from: String, to: String), source: String) async {
        let targetIdentifier = regionIdentifier(
            subscriptionId: parsed.subscriptionId,
            from: parsed.from,
            to: parsed.to
        )
        guard await ensureTargetExists(identifier: targetIdentifier, parsed: parsed) != nil else { return }
        guard !NotificationMuteStorage.isMutedToday(from: parsed.from, to: parsed.to) else { return }

        let msg = "Arrival confirmed via tight geofence for \(parsed.from)→\(parsed.to)"
        DebugLogStore.shared.log(msg, category: "Mute")
        logGeofenceDiagnostic("arrival_confirmed_region", metadata: [
            "subscription_id": parsed.subscriptionId,
            "from": parsed.from.uppercased(),
            "to": parsed.to.uppercased(),
            "source": source
        ])
        debugLog("✅ \(msg)")

        await armDepartureCleanupAfterArrival(
            subscriptionId: parsed.subscriptionId,
            from: parsed.from,
            to: parsed.to,
            source: source
        )
    }

    private func armDepartureCleanupAfterArrival(
        subscriptionId: String,
        from: String,
        to: String,
        source: String
    ) async {
        let fromCode = from.uppercased()
        let toCode = to.uppercased()
        guard !NotificationMuteStorage.isMutedToday(from: fromCode, to: toCode) else { return }

        NotificationMuteStorage.clearArrivalDetectionPending(from: fromCode, to: toCode)
        let alreadyAwaitingDeparture = NotificationMuteStorage.hasPendingStationDepartureCleanup(
            from: fromCode,
            to: toCode
        )
        if !alreadyAwaitingDeparture {
            // Persist the transition before any departure-board request. A background wake
            // may end while the optional snapshot is still in flight.
            _ = NotificationMuteStorage.markPendingStationDepartureCleanup(from: fromCode, to: toCode)
        }
        await JourneyTrackingCoordinator.shared.handleOriginArrival(
            subscriptionID: subscriptionId,
            detectedAt: Date()
        )

        let targetIdentifier = regionIdentifier(subscriptionId: subscriptionId, from: fromCode, to: toCode)
        if var state = confirmationStates[targetIdentifier] {
            state.isFiring = true
            confirmationStates[targetIdentifier] = state
        }
        finishPrecisionSamplingBurst(reason: "arrival-confirmed")

        if alreadyAwaitingDeparture {
            let duplicateMsg = "Station arrival already confirmed for \(fromCode)→\(toCode); waiting for station exit"
            DebugLogStore.shared.log(duplicateMsg, category: "Geofence")
            logGeofenceDiagnostic("station_departure_cleanup_already_armed", metadata: [
                "subscription_id": subscriptionId,
                "from": fromCode,
                "to": toCode,
                "source": source
            ])
            debugLog("⏭ \(duplicateMsg)")
            return
        }

        let dateKey = currentDateKey()
        let msg = "Station arrival confirmed for \(fromCode)→\(toCode); journey updates continue until leaving the \(Int(Self.regionRadiusMeters))m station area"
        DebugLogStore.shared.log(msg, category: "Geofence")
        logGeofenceDiagnostic("station_departure_cleanup_armed", metadata: [
            "subscription_id": subscriptionId,
            "from": fromCode,
            "to": toCode,
            "date": dateKey,
            "source": source,
            "exit_radius_m": Self.regionRadiusMeters
        ])
        debugLog("✅ \(msg)")
    }

    private func hasOtherKnownOuterRegionInside(
        subscriptionId: String,
        from: String,
        to: String,
        excluding excludedIdentifier: String
    ) -> Bool {
        outerRegionInsideStates.contains { identifier, isInside in
            guard isInside, identifier != excludedIdentifier else { return false }
            guard regionTier(for: identifier) == .outer else { return false }
            guard let parsed = parseRegionIdentifier(identifier) else { return false }
            return parsed.subscriptionId == subscriptionId
                && parsed.from.caseInsensitiveCompare(from) == .orderedSame
                && parsed.to.caseInsensitiveCompare(to) == .orderedSame
        }
    }

    private func isStillInsideStationArea(
        parsed: (subscriptionId: String, from: String, to: String),
        exitingRegionId: String
    ) async -> Bool {
        if hasOtherKnownOuterRegionInside(
            subscriptionId: parsed.subscriptionId,
            from: parsed.from,
            to: parsed.to,
            excluding: exitingRegionId
        ) {
            return true
        }

        let targetIdentifier = regionIdentifier(subscriptionId: parsed.subscriptionId, from: parsed.from, to: parsed.to)
        guard let target = await ensureTargetExists(identifier: targetIdentifier, parsed: parsed),
              target.station.coordinates.count > 1,
              let location = currentUsableLocation(maxAge: ArrivalConfig.recentLocationForExitCheckSeconds) else {
            return false
        }

        return target.distance(from: location) <= Self.regionRadiusMeters
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard isGeofencingSupported else { return }
        guard let circular = region as? CLCircularRegion else { return }
        if circular.identifier.hasPrefix(historyRegionPrefix) {
            let token = AppBackgroundTaskToken(name: "journey-history-exit")
            Task { @MainActor in
                defer { token.end() }
                DebugLogStore.shared.log("Exited journey history condition: \(circular.identifier)", category: "JourneyHistory")
                self.logGeofenceDiagnostic("journey_history_condition_exited", metadata: [
                    "region_id": circular.identifier
                ])
                _ = await JourneyTrackingCoordinator.shared.handleConditionExit(identifier: circular.identifier)
            }
            return
        }
        guard let parsed = parseRegionIdentifier(circular.identifier) else { return }
        let tier = regionTier(for: circular.identifier)

        GeofenceEventSender.shared.sendEvent(
            regionId: circular.identifier,
            from: parsed.from,
            to: parsed.to,
            eventType: tier == .inner ? "arrival_exit" : "exit"
        )

        let exitFlowToken = AppBackgroundTaskToken(name: "geofence-exit-cleanup")
        let message = "Exited region: \(circular.identifier)\nFrom: \(parsed.from.uppercased()) To: \(parsed.to.uppercased())"
        Task { @MainActor in
            defer { exitFlowToken.end() }
            DebugLogStore.shared.log(message, category: "Geofence")
            self.logGeofenceDiagnostic("region_exited", metadata: [
                "region_id": circular.identifier,
                "subscription_id": parsed.subscriptionId,
                "from": parsed.from.uppercased(),
                "to": parsed.to.uppercased(),
                "tier": tier == .inner ? "inner" : "outer"
            ])

            guard tier == .outer else { return }
            let targetIdentifier = self.regionIdentifier(
                subscriptionId: parsed.subscriptionId,
                from: parsed.from,
                to: parsed.to
            )
            guard let target = await self.ensureTargetExists(identifier: targetIdentifier, parsed: parsed) else { return }
            self.outerRegionInsideStates[circular.identifier] = false

            if await self.isStillInsideStationArea(parsed: parsed, exitingRegionId: circular.identifier) {
                let insideMsg = "Geofence exit for \(parsed.from)→\(parsed.to) ignored; still inside another \(Int(Self.regionRadiusMeters))m station area"
                DebugLogStore.shared.log(insideMsg, category: "Geofence")
                self.logGeofenceDiagnostic("station_exit_ignored_still_inside", metadata: [
                    "region_id": circular.identifier,
                    "subscription_id": parsed.subscriptionId,
                    "from": parsed.from.uppercased(),
                    "to": parsed.to.uppercased(),
                    "exit_radius_m": Self.regionRadiusMeters
                ])
                debugLog("📍 \(insideMsg)")
                return
            }

            guard NotificationMuteStorage.consumePendingStationDepartureCleanup(from: parsed.from, to: parsed.to) else {
                // The user entered and left the origin station. If arrival was never confirmed,
                // background detection failed silently — surface it so the user can re-arm it.
                await self.checkForMissedArrival(from: parsed.from, to: parsed.to, reason: "region-exit")
                return
            }
            NotificationMuteStorage.clearArrivalDetectionPending(from: parsed.from, to: parsed.to)

            await JourneyTrackingCoordinator.shared.handleOriginDeparture(
                subscriptionID: parsed.subscriptionId,
                from: parsed.from,
                to: parsed.to,
                detectedAt: Date()
            )
            let journeyNotificationBody = JourneyTrackingCoordinator.shared.boardingNotificationBody(
                from: parsed.from,
                to: parsed.to
            )

            let endMsg = target.muteOnArrival == false
                ? "Geofence exit for \(parsed.from)→\(parsed.to) — tracking the train journey"
                : "Geofence exit for \(parsed.from)→\(parsed.to) — muting notifications and tracking the train journey"
            DebugLogStore.shared.log(endMsg, category: "Geofence")
            debugLog("🏁 \(endMsg)")
            if target.muteOnArrival != false {
                await self.triggerMuteFlow(
                    subscriptionId: parsed.subscriptionId,
                    from: parsed.from,
                    to: parsed.to,
                    simulate: false,
                    endLiveActivity: false,
                    detectionSource: "geofence",
                    journeyNotificationBody: journeyNotificationBody
                )
            }
        }
        debugLog("📍 \(message)")
    }

    // Exposed for the debug UI — shows which regions CLLocationManager is actually monitoring.
    var monitoredRegionIdentifiers: [String] {
        Array(Set(monitoredConditionIdentifiers).union(manager.monitoredRegions
            .filter { isManagedRegion($0.identifier) }
            .map { $0.identifier }))
            .sorted()
    }

    var debugSnapshot: NotificationGeofenceDebugSnapshot {
        NotificationGeofenceDebugSnapshot(
            monitoredRegionIdentifiers: monitoredRegionIdentifiers,
            monitoredTargetCount: monitoredTargets.count,
            trackingMode: trackingModeDescription,
            authorizationStatus: authorizationStatusDescription(manager.authorizationStatus),
            backgroundLocationEnabled: manager.allowsBackgroundLocationUpdates,
            backgroundActivityActive: backgroundActivitySession != nil,
            locationServiceSessionActive: locationServiceSession != nil
        )
    }

    private var trackingModeDescription: String {
        switch trackingMode {
        case .lowSensitivity:
            return "low"
        case .highSensitivity:
            return "high"
        case nil:
            return "off"
        }
    }

    func evaluateForegroundArrival(
        subscription: NotificationSubscription,
        leg: NotificationLeg,
        station: Station,
        location: CLLocation,
        source: String = "foreground-proximity"
    ) {
        guard isGeofencingSupported else { return }
        if let activeUntil = subscription.activeUntil, activeUntil <= Date() {
            return
        }

        let from = leg.from.uppercased()
        let to = leg.to.uppercased()
        guard from == station.crs.uppercased() else { return }

        let identifier = regionIdentifier(subscriptionId: subscription.id, from: from, to: to)
        let target = StationArrivalTarget(
            identifier: identifier,
            subscriptionId: subscription.id,
            from: from,
            to: to,
            station: station,
            activeUntil: subscription.activeUntil,
            muteOnArrival: subscription.muteOnArrival,
            isScheduledActivation: subscription.source == .scheduled
                || (subscription.liveSessionOrigin == nil && subscription.activeUntil == nil),
            scheduleKind: subscription.scheduleKind,
            daysOfWeek: subscription.daysOfWeek,
            windowStart: leg.windowStart,
            windowEnd: leg.windowEnd,
            travelDate: leg.travelDate
        )

        monitoredTargets[identifier] = target
        if confirmationStates[identifier] == nil {
            confirmationStates[identifier] = StationArrivalConfirmationState()
        }
        startHighSensitivityTracking(reason: source)
        logGeofenceDiagnostic("foreground_arrival_evaluation", metadata: [
            "subscription_id": subscription.id,
            "from": from,
            "to": to,
            "station": station.name,
            "source": source,
            "raw_distance_m": station.distance(from: location),
            "horizontal_accuracy_m": location.horizontalAccuracy
        ])
        evaluateArrival(using: location, for: target, source: source)
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        guard isGeofencingSupported else { return }
        guard isManagedRegion(region.identifier) else { return }
        let msg = "Started monitoring: \(region.identifier)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("monitoring_started", metadata: [
                "region_id": region.identifier
            ])
        }
        debugLog("📍 \(msg)")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        guard isGeofencingSupported else { return }
        let regionId = region?.identifier ?? "unknown"
        let msg = "Monitoring FAILED for \(regionId): \(error.localizedDescription)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Error")
            self.logGeofenceDiagnostic("monitoring_failed", metadata: [
                "region_id": regionId,
                "error": error.localizedDescription
            ])
        }
        debugLog("❌ \(msg)")
    }

    // Called in response to requestState(for:) after sync, and also after startMonitoring.
    // Handles the critical "already inside" case: if the user is already within the
    // geofence boundary when monitoring starts, only didDetermineState(.inside) fires.
    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard isGeofencingSupported else { return }
        guard let circular = region as? CLCircularRegion else { return }
        if circular.identifier.hasPrefix(historyRegionPrefix) {
            guard state == .inside else { return }
            let token = AppBackgroundTaskToken(name: "journey-history-state")
            Task { @MainActor in
                defer { token.end() }
                DebugLogStore.shared.log("Journey history condition already inside: \(circular.identifier)", category: "JourneyHistory")
                self.logGeofenceDiagnostic("journey_history_condition_state_inside", metadata: [
                    "region_id": circular.identifier
                ])
                if let location = manager.location {
                    await JourneyTrackingCoordinator.shared.evaluateLocation(location)
                }
                _ = await JourneyTrackingCoordinator.shared.handleConditionEntry(identifier: circular.identifier)
            }
            return
        }
        guard let parsed = parseRegionIdentifier(circular.identifier) else { return }
        let tier = regionTier(for: circular.identifier)

        let stateStr: String
        switch state {
        case .inside:  stateStr = "inside"
        case .outside: stateStr = "outside"
        case .unknown: stateStr = "unknown"
        @unknown default: stateStr = "unknown"
        }

        let msg = "Region state [\(stateStr)]: \(circular.identifier)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("region_state_determined", metadata: [
                "region_id": circular.identifier,
                "subscription_id": parsed.subscriptionId,
                "from": parsed.from.uppercased(),
                "to": parsed.to.uppercased(),
                "state": stateStr,
                "tier": tier == .inner ? "inner" : "outer"
            ])
            if tier == .outer {
                self.outerRegionInsideStates[circular.identifier] = state == .inside
            }
        }
        debugLog("📍 \(msg)")

        guard state == .inside else { return }

        let muteFlowToken = AppBackgroundTaskToken(name: "geofence-state-mute-flow")

        Task { @MainActor in
            defer { muteFlowToken.end() }
            if tier == .inner {
                await self.confirmArrivalFromRegion(parsed: parsed, source: "arrival-region-inside")
            } else {
                let targetIdentifier = self.regionIdentifier(
                    subscriptionId: parsed.subscriptionId,
                    from: parsed.from,
                    to: parsed.to
                )
                guard await self.ensureTargetExists(identifier: targetIdentifier, parsed: parsed) != nil else { return }
                NotificationMuteStorage.markArrivalDetectionPending(from: parsed.from, to: parsed.to)
                await self.handleRegionHint(identifier: circular.identifier, parsed: parsed, source: "inside")
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isGeofencingSupported else { return }
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.evaluateArrival(using: location, source: "continuous")
            await JourneyTrackingCoordinator.shared.evaluateLocation(location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isGeofencingSupported else { return }
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain, nsError.code == CLError.locationUnknown.rawValue {
            return
        }
        let msg = "Location updates failed: \(error.localizedDescription)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Error")
            self.logGeofenceDiagnostic("location_updates_failed", metadata: [
                "error": error.localizedDescription
            ])
        }
        debugLog("❌ \(msg)")
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard isGeofencingSupported else { return }
        let msg = "Location updates paused unexpectedly; restarting continuous arrival tracking"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("location_updates_paused")
            self.trackingMode = nil
            self.startLowSensitivityTrackingIfNeeded(reason: "pause-restart")
        }
        debugLog("📍 \(msg)")
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        guard isGeofencingSupported else { return }
        let msg = "Location updates resumed"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("location_updates_resumed")
        }
        debugLog("📍 \(msg)")
    }

    /// Triggers the mute flow once the user has left the station area after confirmed arrival.
    ///
    /// **Why async**: Some callers hold an `AppBackgroundTaskToken` during a background
    /// geofence wake. Making this function async (instead of wrapping in an internal
    /// Task) lets the caller await the point where the mute upload has been queued.
    ///
    /// The request is sent immediately on exit. The old "mute after X minutes at station"
    /// delay does not apply here because updates must continue until the user is at least
    /// outside the configured station radius.
    func triggerMuteFlow(subscriptionId: String, from: String, to: String,
                         sendNotification _: Bool = true,
                         simulate: Bool = false,
                         endLiveActivity: Bool = false,
                         detectionSource: String = "geofence",
                         journeyNotificationBody: String? = nil) async {
        // Guard against duplicate calls — both didEnterRegion and didDetermineState can fire
        // for the same region event. Since this function runs on @MainActor (via class
        // default isolation), the first call marks locally then any concurrent second call
        // hits this guard and returns cleanly.
        guard !NotificationMuteStorage.isMutedToday(from: from, to: to) else {
            let skipMsg = "triggerMuteFlow: already muted today for \(from)→\(to) — skipping duplicate"
            DebugLogStore.shared.log(skipMsg, category: "Mute")
            debugLog("⏭ \(skipMsg)")
            return
        }

        // Mark locally immediately — prevents any concurrent triggerMuteFlow call (above guard)
        // from also sending a duplicate terminate request.
        markLegMutedLocally(from: from, to: to)

        // Station exit has been handled — clear pending arrival/departure markers.
        NotificationMuteStorage.clearArrivalDetectionPending(from: from, to: to)
        NotificationMuteStorage.clearPendingStationDepartureCleanup(from: from, to: to)

        let delayMinutes = 0
        let msg = "Sending station-exit mute request for \(from)→\(to)"
        DebugLogStore.shared.log(msg, category: "Mute")
        logGeofenceDiagnostic("mute_flow_started", metadata: [
            "subscription_id": subscriptionId,
            "from": from.uppercased(),
            "to": to.uppercased(),
            "delay_minutes": delayMinutes,
            "simulate": simulate,
            "end_live_activity": endLiveActivity,
            "transition": "station_exit",
            "detection_source": detectionSource
        ])
        debugLog("⏳ \(msg)")

        NotificationMuteRequestSender.shared.enqueueMute(
            subscriptionId: subscriptionId,
            from: from,
            to: to,
            delayMinutes: delayMinutes,
            reason: "station_exit",
            transition: "station_exit",
            detectionSource: detectionSource,
            journeyNotificationBody: journeyNotificationBody
        )

        if endLiveActivity {
            NotificationMuteStorage.markPendingLiveSessionPreserveOnArrival(from: from, to: to)
            let endMsg = "Ending Live Activity after leaving station for \(from)→\(to)"
            DebugLogStore.shared.log(endMsg, category: "Mute")
            debugLog("🏁 \(endMsg)")
            await LiveActivityManager.shared.stopMatching(
                fromCRS: from,
                toCRS: to,
                preserveNotificationLiveSession: true
            )
        } else {
            let keepMsg = "Leaving Live Activity active after station exit for \(from)→\(to) because auto-end is disabled"
            DebugLogStore.shared.log(keepMsg, category: "Mute")
            debugLog("📍 \(keepMsg)")
        }
        // Remove the live session locally so UI/geofences stop immediately, but do not
        // DELETE it from the backend here. `/notifications/terminate` uses that server-side
        // record to send the muted-status pushes, and deleting it first can race
        // the terminate request and cause a 404/no confirmation notification.
        await NotificationSubscriptionStore.shared.removeLiveSessionsLocally(containingFrom: from, to: to)
    }

    func simulateArrival(subscriptionId: String, from: String, to: String, sendNotification _: Bool = true) {
        let msg = "Simulated arrival for \(from.uppercased()) → \(to.uppercased())"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("arrival_simulated", metadata: [
                "subscription_id": subscriptionId,
                "from": from.uppercased(),
                "to": to.uppercased()
            ])
        }
        debugLog("🧪 \(msg)")
        Task {
            await armDepartureCleanupAfterArrival(
                subscriptionId: subscriptionId,
                from: from,
                to: to,
                source: "debug-simulate-arrival"
            )
        }
    }

    private func markLegMutedLocally(from: String, to: String) {
        let todayString = NotificationMuteStorage.markMuted(from: from, to: to)
        let legKey = NotificationMuteStorage.legKey(from: from, to: to)
        let msg = "Marked leg \(legKey) as muted locally for \(todayString)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Mute")
        }
        debugLog("✅ \(msg)")
    }

    // MARK: - Background-wake arrival re-check & missed-arrival health

    /// Called when the app is woken by a background push (e.g. a Live Activity / journey
    /// update). Continuous background location after a geofence wake is not guaranteed to
    /// survive — especially once the app has been dormant for a while — so each push wake
    /// is used as a fresh chance to: re-sample location and complete an in-flight arrival
    /// confirmation, and surface a missed-arrival notification if detection silently failed.
    func refreshArrivalFromBackgroundWake(trigger: String) async {
        NotificationMuteRequestSender.shared.retryPendingMuteRequests(trigger: "background-wake-\(trigger)")
        guard isGeofencingSupported else { return }
        guard hasLocationTrackingWork else { return }

        // A push is independent evidence: sample even if the entry callback was completely
        // missed, and continue checking after arrival so a missed outer exit can recover.
        // The baseline uses significant-change monitoring; precision only starts if the
        // sample is close to an arrival/departure decision.
        let hasPendingArrival = monitoredTargets.values.contains {
            NotificationMuteStorage.arrivalDetectionPendingSince(from: $0.from, to: $0.to) != nil
        }
        let hasPendingDeparture = monitoredTargets.values.contains {
            NotificationMuteStorage.hasPendingStationDepartureCleanup(from: $0.from, to: $0.to)
        }
        let hasUndetectedArrival = monitoredTargets.values.contains {
            !NotificationMuteStorage.isMutedToday(from: $0.from, to: $0.to)
                && !NotificationMuteStorage.hasPendingStationDepartureCleanup(from: $0.from, to: $0.to)
        }

        if (hasPendingArrival || hasPendingDeparture || hasUndetectedArrival || JourneyTrackingCoordinator.shared.hasActiveJourney),
           canMonitorWithCurrentAuthorization {
            logGeofenceDiagnostic("background_wake_arrival_refresh", metadata: ["trigger": trigger])
            let token = AppBackgroundTaskToken(name: "push-wake-arrival")
            updateBackgroundLocationState(hasActiveGeofences: true)
            startLowSensitivityTrackingIfNeeded(reason: "\(trigger)-wake")
            manager.requestLocation()
            // A one-shot request normally completes quickly. Keep a short background token
            // so the callback has time to arrive; evaluateArrival escalates to a bounded
            // precision burst only when the result is near a station decision.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                token.end()
            }
        }

        await evaluateMissedArrivals(trigger: trigger)
    }

    /// Checks each monitored leg whose arrival detection has been pending past a grace
    /// period and surfaces a missed-arrival notification. Used as a backstop in case the
    /// region-exit wake doesn't fire promptly.
    private func evaluateMissedArrivals(trigger: String) async {
        let gracePeriod: TimeInterval = 300 // 5 min since entering the station geofence
        for target in monitoredTargets.values {
            guard let since = NotificationMuteStorage.arrivalDetectionPendingSince(from: target.from, to: target.to) else { continue }
            guard Date().timeIntervalSince(since) >= gracePeriod else { continue }
            await checkForMissedArrival(from: target.from, to: target.to, reason: "\(trigger)-timeout")
        }
    }

    /// Consumes the pending-arrival marker and, if the leg was reached but never muted,
    /// posts the missed-arrival notification (once — the marker is cleared atomically).
    private func checkForMissedArrival(from: String, to: String, reason: String) async {
        guard NotificationMuteStorage.consumeArrivalDetectionPending(from: from, to: to) else { return }
        guard !NotificationMuteStorage.isMutedToday(from: from, to: to) else { return }
        await postMissedArrivalNotification(from: from, to: to, reason: reason)
    }

    private func stationDisplayName(crs: String) -> String? {
        if let target = monitoredTargets.values.first(where: { $0.from == crs.uppercased() }) {
            return target.station.name
        }
        return StationsService.shared.stations.first(where: {
            $0.crs.caseInsensitiveCompare(crs) == .orderedSame
        })?.name
    }

    private func postMissedArrivalNotification(from: String, to: String, reason: String) async {
        let fromName = stationDisplayName(crs: from) ?? from.uppercased()
        let toName = stationDisplayName(crs: to) ?? to.uppercased()

        let content = UNMutableNotificationContent()
        content.title = "Couldn’t detect your arrival"
        content.body = "TrainTrack didn’t see you arrive at \(fromName), so it couldn’t mute your \(fromName) → \(toName) alerts automatically. Background location monitoring may have paused — tap to reopen TrainTrack and switch arrival detection back on."
        content.sound = .default
        content.categoryIdentifier = NotificationCategoryId.arrivalDetectionHealth
        content.userInfo = [
            NotificationPayloadKeys.from: from.uppercased(),
            NotificationPayloadKeys.to: to.uppercased(),
            NotificationPayloadKeys.fromName: fromName,
            NotificationPayloadKeys.toName: toName,
            NotificationPayloadKeys.alertType: NotificationAlertType.arrivalDetectionFailed
        ]

        // Identifier keyed by leg + day so it can't stack duplicates within a single day.
        let identifier = "arrival_detection_failed_\(NotificationMuteStorage.legKey(from: from, to: to))_\(NotificationMuteStorage.currentDateKey())"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            DebugLogStore.shared.log("Failed to post missed-arrival notification for \(from)→\(to): \(error.localizedDescription)", category: "Error")
        }

        let msg = "Posted missed-arrival notification for \(from)→\(to) (\(reason))"
        DebugLogStore.shared.log(msg, category: "Geofence")
        logGeofenceDiagnostic("missed_arrival_notified", metadata: [
            "from": from.uppercased(),
            "to": to.uppercased(),
            "station": fromName,
            "reason": reason
        ])
        debugLog("⚠️ \(msg)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard isGeofencingSupported else { return }
        Task { @MainActor in
            let msg = "Location authorization changed: status=\(self.authorizationStatusDescription(manager.authorizationStatus))"
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("authorization_changed", metadata: [
                "new_status": self.authorizationStatusDescription(manager.authorizationStatus)
            ])

            if self.canMonitorWithCurrentAuthorization {
                self.requestTemporaryFullAccuracyIfNeeded()
                await self.reconcileAfterBackgroundWake(trigger: "authorization-changed")
                await NotificationSubscriptionStore.shared.refresh()
            } else if !self.monitoredTargets.isEmpty {
                self.stopLocationUpdatesIfNeeded(reason: "authorization-changed")
                self.updateBackgroundLocationState(hasActiveGeofences: false)
            }
        }
    }

    private func authorizationStatusDescription(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorizedAlways:
            return "authorizedAlways"
        case .authorizedWhenInUse:
            return "authorizedWhenInUse"
        @unknown default:
            return "unknown"
        }
    }

    private var accuracyAuthorizationDescription: String {
        if #available(iOS 14.0, *) {
            switch manager.accuracyAuthorization {
            case .fullAccuracy:
                return "fullAccuracy"
            case .reducedAccuracy:
                return "reducedAccuracy"
            @unknown default:
                return "unknown"
            }
        }
        return "fullAccuracy"
    }
}

final class NotificationMuteRequestSender: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDataDelegate {
    static let shared = NotificationMuteRequestSender()

    private struct RequestContext {
        let url: String
        let deviceId: String
        let subscriptionId: String
        let from: String
        let to: String
        let delayMinutes: Int
        let dateKey: String
        let reason: String
        let transition: String?
        let detectionSource: String?
        let journeyNotificationBody: String?
        let pendingRequestId: String?
    }

    private lazy var session: URLSession = {
        // Ephemeral session (NOT background) — the mute request is a small, time-sensitive
        // JSON POST that must complete within the ~30s geofence background execution window.
        // Background URLSessions hand transfers to nsurlsessiond which defers them when
        // started from a background-woken app (even with isDiscretionary = false), causing
        // delivery delays of 10+ minutes until the app is foregrounded. An ephemeral session
        // sends immediately; the AppBackgroundTaskToken in backgroundTasks (below) keeps the
        // app alive until the response arrives (typically <2 s on a mobile network).
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private var responseData: [Int: Data] = [:]
    private var requestContexts: [Int: RequestContext] = [:]
    private var backgroundTasks: [Int: AppBackgroundTaskToken] = [:]
    private var deferredLiveActivityUnregistrations: [String: Set<String>] = [:]
    private var inFlightPendingRequestIDs: Set<String> = []
    private var retryScheduled = false
    private let syncQueue = DispatchQueue(label: "dev.skynolimit.traintrack.notifications.mute.sync")

    private func legKey(from: String, to: String) -> String {
        "\(from.uppercased())-\(to.uppercased())"
    }

    func deferLiveActivityUnregistration(activityID: String, from: String, to: String) {
        let key = legKey(from: from, to: to)
        syncQueue.async {
            var pending = self.deferredLiveActivityUnregistrations[key] ?? []
            pending.insert(activityID)
            self.deferredLiveActivityUnregistrations[key] = pending
        }
    }

    private func consumeDeferredLiveActivityUnregistrations(from: String, to: String) -> [String] {
        let key = legKey(from: from, to: to)
        return syncQueue.sync {
            let pending = Array(self.deferredLiveActivityUnregistrations.removeValue(forKey: key) ?? [])
            return pending
        }
    }

    func enqueueMute(
        subscriptionId: String,
        from: String,
        to: String,
        delayMinutes: Int = 0,
        reason: String = "manual",
        transition: String? = nil,
        detectionSource: String? = nil,
        journeyNotificationBody: String? = nil
    ) {
        let dateKey = currentDateKey()
        let pending = NotificationMuteStorage.upsertPendingMuteRequest(
            subscriptionId: subscriptionId,
            from: from,
            to: to,
            dateKey: dateKey,
            delayMinutes: delayMinutes,
            reason: reason,
            transition: transition,
            detectionSource: detectionSource,
            journeyNotificationBody: journeyNotificationBody
        )
        startMuteRequest(
            subscriptionId: subscriptionId,
            from: from,
            to: to,
            dateKey: dateKey,
            delayMinutes: delayMinutes,
            reason: reason,
            transition: transition,
            detectionSource: detectionSource,
            journeyNotificationBody: journeyNotificationBody,
            pendingRequestId: pending?.id
        )
    }

    func retryPendingMuteRequests(trigger: String) {
        let pending = NotificationMuteStorage.pendingMuteRequests()
        guard !pending.isEmpty else { return }

        let msg = "Retrying \(pending.count) pending mute request(s) (\(trigger))"
        Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
        ClientDiagnosticsLogger.log("mute", "terminate_retry_scan", metadata: [
            "trigger": trigger,
            "pending_count": pending.count
        ])

        for request in pending {
            startMuteRequest(
                subscriptionId: request.subscriptionId,
                from: request.from,
                to: request.to,
                dateKey: request.dateKey,
                delayMinutes: request.delayMinutes,
                reason: request.reason,
                transition: request.transition,
                detectionSource: request.detectionSource,
                journeyNotificationBody: request.journeyNotificationBody,
                pendingRequestId: request.id
            )
        }
    }

    private func startMuteRequest(
        subscriptionId: String,
        from: String,
        to: String,
        dateKey: String,
        delayMinutes: Int,
        reason: String,
        transition: String?,
        detectionSource: String?,
        journeyNotificationBody: String?,
        pendingRequestId: String?
    ) {
        if let pendingRequestId {
            let shouldStart = syncQueue.sync { () -> Bool in
                guard !self.inFlightPendingRequestIDs.contains(pendingRequestId) else { return false }
                self.inFlightPendingRequestIDs.insert(pendingRequestId)
                return true
            }
            guard shouldStart else {
                let msg = "Pending mute request already in flight for \(from.uppercased())→\(to.uppercased())"
                Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
                return
            }
        }

        let baseURL = ApiHostPreference.currentBaseURL
        guard let url = URL(string: "\(baseURL)/notifications/terminate") else {
            let errorMsg = "Invalid URL for terminate endpoint: \(baseURL)"
            Task { @MainActor in DebugLogStore.shared.log(errorMsg, category: "Error") }
            debugLog("❌ \(errorMsg)")
            finishPendingRequest(id: pendingRequestId)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")

        var payload: [String: Any] = [
            "device_id": DeviceIdentity.deviceToken,
            "subscription_id": subscriptionId,
            "from": from.uppercased(),
            "to": to.uppercased(),
            "date": dateKey,
            "delay_minutes": delayMinutes,
            "reason": reason
        ]
        if let transition {
            payload["transition"] = transition
        }
        if let detectionSource {
            payload["detection_source"] = detectionSource
        }
        if let journeyNotificationBody, !journeyNotificationBody.isEmpty {
            payload["journey_notification_body"] = journeyNotificationBody
        }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            let errorMsg = "Failed to encode mute request payload"
            Task { @MainActor in DebugLogStore.shared.log(errorMsg, category: "Error") }
            debugLog("❌ \(errorMsg)")
            finishPendingRequest(id: pendingRequestId)
            return
        }

        #if DEBUG
        if let bodyString = String(data: body, encoding: .utf8) {
            let msg = "Sending mute request: \(bodyString)\nURL: \(url.absoluteString)"
            Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
            debugLog("📤 \(msg)")
            Task { @MainActor in
                MuteRequestDebugStore.shared.record(payload: bodyString, url: url.absoluteString, status: "queued")
            }
        }
        #endif

        let task = session.uploadTask(with: request, from: body)

        // Register a background task token BEFORE task.resume() so the system cannot
        // suspend the app between task creation and the response being received.
        // This token is released in urlSession(_:task:didCompleteWithError:) once the
        // transfer completes. enqueueMute is called from @MainActor so this init runs
        // on the main thread (no DispatchQueue.main.sync deadlock risk).
        let token = AppBackgroundTaskToken(name: "mute-upload")
        syncQueue.sync {
            self.backgroundTasks[task.taskIdentifier] = token
            self.requestContexts[task.taskIdentifier] = RequestContext(
                url: url.absoluteString,
                deviceId: DeviceIdentity.deviceToken,
                subscriptionId: subscriptionId,
                from: from.uppercased(),
                to: to.uppercased(),
                delayMinutes: delayMinutes,
                dateKey: dateKey,
                reason: reason,
                transition: transition,
                detectionSource: detectionSource,
                journeyNotificationBody: journeyNotificationBody,
                pendingRequestId: pendingRequestId
            )
        }
        if let pendingRequestId {
            NotificationMuteStorage.markPendingMuteRequestAttempt(id: pendingRequestId)
        }
        task.resume()

        ClientDiagnosticsLogger.log("mute", "terminate_request_started", metadata: [
            "task_id": task.taskIdentifier,
            "url": url.absoluteString,
            "subscription_id": subscriptionId,
            "from": from.uppercased(),
            "to": to.uppercased(),
            "date": dateKey,
            "delay_minutes": delayMinutes,
            "reason": reason,
            "transition": transition,
            "detection_source": detectionSource,
            "journey_notification_body": journeyNotificationBody,
            "pending_request_id": pendingRequestId
        ])

        let msg = "Mute request task started for \(from.uppercased()) → \(to.uppercased())"
        Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
        debugLog("✅ \(msg)")
    }

    private func finishPendingRequest(id: String?) {
        guard let id else { return }
        syncQueue.async {
            self.inFlightPendingRequestIDs.remove(id)
        }
    }

    private func schedulePendingRetry(after seconds: TimeInterval = 20, reason: String) {
        let shouldSchedule = syncQueue.sync { () -> Bool in
            guard !self.retryScheduled else { return false }
            self.retryScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            syncQueue.async {
                self.retryScheduled = false
            }
            self.retryPendingMuteRequests(trigger: reason)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let taskId = dataTask.taskIdentifier
        syncQueue.async {
            if self.responseData[taskId] == nil {
                self.responseData[taskId] = data
            } else {
                self.responseData[taskId]?.append(data)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        let (data, context): (Data?, RequestContext?) = syncQueue.sync {
            let data = self.responseData[taskId]
            self.responseData.removeValue(forKey: taskId)
            let context = self.requestContexts.removeValue(forKey: taskId)
            // Release the background task token now that the transfer is complete.
            self.backgroundTasks.removeValue(forKey: taskId)?.end()
            if let pendingRequestId = context?.pendingRequestId {
                self.inFlightPendingRequestIDs.remove(pendingRequestId)
            }
            return (data, context)
        }

        if let error = error {
            var msg = "Mute request failed: \(error.localizedDescription)"
            if let context {
                msg += "\nURL: \(context.url)"
                msg += "\nDevice: \(context.deviceId)"
                msg += "\nSubscription: \(context.subscriptionId)"
                msg += "\nLeg: \(context.from)→\(context.to)"
                msg += "\nDate: \(context.dateKey) Delay: \(context.delayMinutes)m"
                msg += "\nReason: \(context.reason)"
                msg += "\nTransition: \(context.transition ?? "legacy") Source: \(context.detectionSource ?? "unspecified")"
            }
            ClientDiagnosticsLogger.log("mute", "terminate_request_failed", metadata: [
                "task_id": taskId,
                "error": error.localizedDescription,
                "url": context?.url,
                "subscription_id": context?.subscriptionId,
                "from": context?.from,
                "to": context?.to,
                "date": context?.dateKey,
                "delay_minutes": context?.delayMinutes,
                "reason": context?.reason,
                "transition": context?.transition,
                "detection_source": context?.detectionSource,
                "pending_request_id": context?.pendingRequestId
            ])
            if let pendingRequestId = context?.pendingRequestId {
                NotificationMuteStorage.markPendingMuteRequestFailure(id: pendingRequestId, error: error.localizedDescription)
                schedulePendingRetry(reason: "terminate-failure")
            }
            let loggedMessage = msg
            Task { @MainActor in DebugLogStore.shared.log(loggedMessage, category: "Error") }
            debugLog("❌ \(msg)")
            #if DEBUG
            Task { @MainActor in
                MuteRequestDebugStore.shared.update(status: "error", response: error.localizedDescription)
            }
            #endif
        } else if let response = task.response as? HTTPURLResponse {
            var msg = "Mute request completed with status: \(response.statusCode)"
            if let context {
                msg += "\nURL: \(context.url)"
                msg += "\nDevice: \(context.deviceId)"
                msg += "\nSubscription: \(context.subscriptionId)"
                msg += "\nLeg: \(context.from)→\(context.to)"
                msg += "\nDate: \(context.dateKey) Delay: \(context.delayMinutes)m"
                msg += "\nReason: \(context.reason)"
                msg += "\nTransition: \(context.transition ?? "legacy") Source: \(context.detectionSource ?? "unspecified")"
            }

            if let data = data, !data.isEmpty, let responseString = String(data: data, encoding: .utf8) {
                msg += "\nResponse: \(responseString)"
            }
            ClientDiagnosticsLogger.log("mute", "terminate_request_completed", metadata: [
                "task_id": taskId,
                "status": response.statusCode,
                "url": context?.url,
                "subscription_id": context?.subscriptionId,
                "from": context?.from,
                "to": context?.to,
                "date": context?.dateKey,
                "delay_minutes": context?.delayMinutes,
                "reason": context?.reason,
                "transition": context?.transition,
                "detection_source": context?.detectionSource,
                "pending_request_id": context?.pendingRequestId,
                "response": data.flatMap { String(data: $0, encoding: .utf8) }
            ])

            let category: String
            if response.statusCode == 404 {
                msg += "\nBackend returned 404 - subscription or leg not found. This may indicate a mismatch in subscription ID or station codes"
                category = "Error"
            } else if response.statusCode == 400 {
                msg += "\nBackend returned 400 - invalid request parameters"
                category = "Error"
            } else if response.statusCode == 200 {
                category = "Mute"
            } else {
                msg += "\nUnexpected response code: \(response.statusCode)"
                category = "Error"
            }

            let loggedMessage = msg
            let loggedCategory = category
            Task { @MainActor in DebugLogStore.shared.log(loggedMessage, category: loggedCategory) }
            debugLog(response.statusCode == 200 ? "✅ \(msg)" : "⚠️ \(msg)")
            #if DEBUG
            Task { @MainActor in
                MuteRequestDebugStore.shared.update(status: "\(response.statusCode)", response: data.flatMap { String(data: $0, encoding: .utf8) })
            }
            #endif

            if response.statusCode == 200, let context {
                if let pendingRequestId = context.pendingRequestId {
                    NotificationMuteStorage.removePendingMuteRequest(id: pendingRequestId)
                }
                let pendingActivityIDs = consumeDeferredLiveActivityUnregistrations(from: context.from, to: context.to)
                for activityID in pendingActivityIDs {
                    Task { @MainActor in
                        await LiveActivityManager.shared.finalizeArrivalTriggeredActivityUnregistration(
                            activityID: activityID,
                            fromCRS: context.from,
                            toCRS: context.to
                        )
                    }
                }
            } else if let pendingRequestId = context?.pendingRequestId {
                if response.statusCode == 400 {
                    NotificationMuteStorage.removePendingMuteRequest(id: pendingRequestId)
                } else {
                    NotificationMuteStorage.markPendingMuteRequestFailure(
                        id: pendingRequestId,
                        error: "HTTP \(response.statusCode)"
                    )
                    schedulePendingRetry(reason: "terminate-http-\(response.statusCode)")
                }
            }
        } else {
            let msg = "Mute request completed (no response details)"
            ClientDiagnosticsLogger.log("mute", "terminate_request_completed_without_response", metadata: [
                "task_id": taskId
            ])
            if let pendingRequestId = context?.pendingRequestId {
                NotificationMuteStorage.markPendingMuteRequestFailure(id: pendingRequestId, error: "No HTTP response")
                schedulePendingRetry(reason: "terminate-no-response")
            }
            Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
            debugLog("✅ \(msg)")
            #if DEBUG
            Task { @MainActor in
                MuteRequestDebugStore.shared.update(status: "ok", response: nil)
            }
            #endif
        }
    }

}


final class BackgroundSessionCoordinator {
    static let shared = BackgroundSessionCoordinator()
    private var completions: [String: () -> Void] = [:]

    private init() {}

    func register(identifier: String, completion: @escaping () -> Void) {
        completions[identifier] = completion
    }

    func complete(identifier: String?) {
        guard let identifier else { return }
        let completion = completions.removeValue(forKey: identifier)
        completion?()
    }
}

final class AppBackgroundTaskToken: @unchecked Sendable {
    nonisolated(unsafe) private var identifier: UIBackgroundTaskIdentifier = .invalid

    nonisolated init(name: String) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                    self?.end()
                }
            }
        } else {
            DispatchQueue.main.sync {
                self.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                    self?.end()
                }
            }
        }
    }

    nonisolated func end() {
        let current = identifier
        guard current != .invalid else { return }
        identifier = .invalid
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                UIApplication.shared.endBackgroundTask(current)
            }
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.endBackgroundTask(current)
            }
        }
    }
}

// MARK: - Geofence Event Sender
// Sends a diagnostic event to the server whenever a CLRegion boundary is crossed.
// Uses an immediate URLSession request wrapped in a short background task so the
// upload is not deferred by iOS transfer scheduling after a geofence wake.

final class GeofenceEventSender: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = GeofenceEventSender()
    static let sessionIdentifier = "dev.skynolimit.traintrack.notifications.geofence"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let syncQueue = DispatchQueue(label: "dev.skynolimit.traintrack.geofence.sync")
    private var uploadFiles: [Int: URL] = [:]
    private var backgroundTasks: [Int: AppBackgroundTaskToken] = [:]

    private override init() { super.init() }

    func sendEvent(regionId: String, from: String, to: String, eventType: String) {
        let baseURL = ApiHostPreference.currentBaseURL
        guard let url = URL(string: "\(baseURL)/notifications/geofence-event") else {
            debugLog("❌ [GeofenceEvent] Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")

        let payload: [String: Any] = [
            "device_id": DeviceIdentity.deviceToken,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "event": eventType,
            "region_id": regionId,
            "from": from,
            "to": to
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let msg = "Sending geofence event: \(eventType) \(from)→\(to)"
        Task { @MainActor in DebugLogStore.shared.log(msg, category: "Geofence") }
        ClientDiagnosticsLogger.log("geofence", "server_event_started", metadata: [
            "event_type": eventType,
            "region_id": regionId,
            "from": from.uppercased(),
            "to": to.uppercased()
        ])
        debugLog("📡 [GeofenceEvent] \(msg)")

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("geofence_event_\(UUID().uuidString).json")
        if (try? body.write(to: fileURL, options: .atomic)) != nil {
            let task = session.uploadTask(with: request, fromFile: fileURL)
            syncQueue.async {
                self.uploadFiles[task.taskIdentifier] = fileURL
                self.backgroundTasks[task.taskIdentifier] = AppBackgroundTaskToken(name: "geofence-event-upload")
            }
            task.resume()
        } else {
            let task = session.uploadTask(with: request, from: body)
            syncQueue.async {
                self.backgroundTasks[task.taskIdentifier] = AppBackgroundTaskToken(name: "geofence-event-upload")
            }
            task.resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        syncQueue.async {
            if let temp = self.uploadFiles.removeValue(forKey: taskId) {
                try? FileManager.default.removeItem(at: temp)
            }
            self.backgroundTasks.removeValue(forKey: taskId)?.end()
        }
        if let error = error {
            ClientDiagnosticsLogger.log("geofence", "server_event_failed", metadata: [
                "task_id": taskId,
                "error": error.localizedDescription
            ])
            debugLog("❌ [GeofenceEvent] Request failed: \(error.localizedDescription)")
        } else if let response = task.response as? HTTPURLResponse {
            ClientDiagnosticsLogger.log("geofence", "server_event_completed", metadata: [
                "task_id": taskId,
                "status": response.statusCode
            ])
            debugLog("📡 [GeofenceEvent] Response: \(response.statusCode)")
        }
    }
}

// MARK: - Live Activity Departure Sender
// Notifies the server when the user has left the departure station geofence so the server
// can end the Live Activity push (if autoEndOnDeparture is enabled for that subscription).
// Uses a background URLSession so the request completes even from a background geofence wake.

final class LiveActivityDepartureSender: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    static let shared = LiveActivityDepartureSender()
    static let sessionIdentifier = "dev.skynolimit.traintrack.liveactivity.depart"

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private let syncQueue = DispatchQueue(label: "dev.skynolimit.traintrack.liveactivity.depart.sync")
    private var uploadFiles: [Int: URL] = [:]
    private var backgroundTasks: [Int: AppBackgroundTaskToken] = [:]

    private override init() { super.init() }

    func sendDeparture(from: String, to: String) {
        let baseURL = ApiHostPreference.currentBaseURL
        guard let url = URL(string: "\(baseURL)/live_activities/depart") else {
            debugLog("❌ [LiveActivityDeparture] Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")

        let payload: [String: String] = [
            "device_id": DeviceIdentity.deviceToken,
            "from": from.uppercased(),
            "to": to.uppercased()
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            debugLog("❌ [LiveActivityDeparture] Failed to encode payload")
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("la_depart_\(UUID().uuidString).json")
        if (try? body.write(to: fileURL, options: .atomic)) != nil {
            let task = session.uploadTask(with: request, fromFile: fileURL)
            syncQueue.async {
                self.uploadFiles[task.taskIdentifier] = fileURL
                self.backgroundTasks[task.taskIdentifier] = AppBackgroundTaskToken(name: "live-activity-depart")
            }
            task.resume()
        } else {
            let task = session.uploadTask(with: request, from: body)
            syncQueue.async {
                self.backgroundTasks[task.taskIdentifier] = AppBackgroundTaskToken(name: "live-activity-depart")
            }
            task.resume()
        }

        debugLog("📡 [LiveActivityDeparture] Sent departure event \(from.uppercased())→\(to.uppercased())")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskId = task.taskIdentifier
        syncQueue.async {
            if let temp = self.uploadFiles.removeValue(forKey: taskId) {
                try? FileManager.default.removeItem(at: temp)
            }
            self.backgroundTasks.removeValue(forKey: taskId)?.end()
        }
        if let error = error {
            debugLog("❌ [LiveActivityDeparture] Request failed: \(error.localizedDescription)")
        } else if let response = task.response as? HTTPURLResponse {
            debugLog("📡 [LiveActivityDeparture] Response: \(response.statusCode)")
        }
    }
}
