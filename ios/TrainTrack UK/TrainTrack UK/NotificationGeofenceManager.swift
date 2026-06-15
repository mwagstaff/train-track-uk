import Foundation
import CoreLocation
import UserNotifications
import UIKit

// MARK: - Shared Utilities

private func currentDateKey() -> String {
    NotificationMuteStorage.currentDateKey()
}

private struct StationArrivalTarget {
    let identifier: String
    let subscriptionId: String
    let from: String
    let to: String
    let station: Station

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
    var isFiring = false

    mutating func reset() {
        confirmationStartedAt = nil
        lastQualifiedAt = nil
        lastRegionHintAt = nil
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
        static let regionRadiusMeters: CLLocationDistance = 300
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
        static let fullAccuracyPurposeKey = "StationArrivalMonitoring"
    }

    private enum TrackingMode {
        case lowSensitivity
        case highSensitivity
    }

    private let manager = CLLocationManager()
    private nonisolated let regionPrefix = "tt_notify_mute"
    static let regionRadiusMeters: CLLocationDistance = ArrivalConfig.regionRadiusMeters
    private var monitoredTargets: [String: StationArrivalTarget] = [:]
    private var confirmationStates: [String: StationArrivalConfirmationState] = [:]
    private var trackingMode: TrackingMode?
    private var hasRequestedFullAccuracyThisSession = false

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
    //   5. App was NOT force-quit by the user — user swipe-close prevents re-launch.
    private var locationServiceSession: Any?
    private var locationServiceDiagnosticsTask: Task<Void, Never>?

    // CLBackgroundActivitySession (iOS 17+) — keeps the app process alive in background
    // while region monitoring is active. Without this, iOS suspends the app between
    // geofence events; when a region boundary is crossed the app gets only a brief
    // ~10–30 s wake window. The async Task in didEnterRegion and the subsequent HTTP
    // request must both complete within that window — if iOS re-suspends the process
    // before the Task runs, the mute request is silently dropped.
    //
    // Holding a CLBackgroundActivitySession ensures the app remains live whenever
    // geofences are registered, so didEnterRegion fires in an already-running process
    // with no race condition. This is the same approach used by My Boris Bikes
    // (DockArrivalMonitoringService.startBackgroundActivitySessionIfNeeded).
    //
    // The session is started in sync() when there are active geofences and stopped
    // when all geofences are removed. It shows the standard blue background-location
    // indicator, which is appropriate given the app requires Always authorisation.
    //
    // Stored as Any? to avoid @available spreading everywhere.
    private var backgroundActivitySession: Any?
    private var backgroundActivityDiagnosticsTask: Task<Void, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        configureLowSensitivityTrackingProfile()
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        print("📍 [GeofenceManager] init auth=\(manager.authorizationStatus.rawValue) monitored=\(manager.monitoredRegions.count)")
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
        ClientDiagnosticsLogger.log("geofence", event, metadata: enriched)
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

    @available(iOS 18.0, *)
    private func startBackgroundActivityDiagnostics(_ session: CLBackgroundActivitySession) {
        backgroundActivityDiagnosticsTask?.cancel()
        backgroundActivityDiagnosticsTask = Task { [diagnostics = session.diagnostics] in
            do {
                for try await diagnostic in diagnostics {
                    ClientDiagnosticsLogger.log("geofence", "background_activity_diagnostic", metadata: [
                        "authorization_denied": diagnostic.authorizationDenied,
                        "authorization_denied_globally": diagnostic.authorizationDeniedGlobally,
                        "authorization_request_in_progress": diagnostic.authorizationRequestInProgress,
                        "authorization_restricted": diagnostic.authorizationRestricted,
                        "insufficiently_in_use": diagnostic.insufficientlyInUse,
                        "service_session_required": diagnostic.serviceSessionRequired
                    ])
                }
            } catch is CancellationError {
                return
            } catch {
                ClientDiagnosticsLogger.log("geofence", "background_activity_diagnostics_failed", metadata: [
                    "error": error.localizedDescription
                ])
            }
        }
    }

    func requestAlwaysAuthorizationIfNeeded() {
        print("📍 [GeofenceManager] requestAlwaysAuthorizationIfNeeded auth=\(manager.authorizationStatus.rawValue)")
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
        let trackedRegions = manager.monitoredRegions.filter { $0.identifier.hasPrefix(regionPrefix) }
        guard trackedRegions.isEmpty else { return }
        print("📍 [GeofenceManager] stopLocationActivityIfIdle: no tracked regions, clearing background location state")
        stopLocationUpdatesIfNeeded(reason: "idle")
        updateBackgroundLocationState(hasActiveGeofences: false)
    }

    func sync(subscriptions: [NotificationSubscription]) async {
        guard CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self) else {
            logGeofenceDiagnostic("sync_skipped_monitoring_unavailable", metadata: [
                "subscription_count": subscriptions.count
            ])
            return
        }
        let existing = manager.monitoredRegions.filter { $0.identifier.hasPrefix(regionPrefix) }
        logGeofenceDiagnostic("sync_started", metadata: [
            "subscription_count": subscriptions.count,
            "existing_region_count": existing.count
        ])

        guard !subscriptions.isEmpty else {
            stopMonitoring(Array(existing))
            clearArrivalMonitoringState()
            stopLocationUpdatesIfNeeded(reason: "no subscriptions")
            updateBackgroundLocationState(hasActiveGeofences: false)
            let syncMsg = "Geofence sync: 0 desired, +0 added, -\(existing.count) removed"
            Task { @MainActor in
                DebugLogStore.shared.log(syncMsg, category: "Geofence")
            }
            print("📍 \(syncMsg)")
            logGeofenceDiagnostic("sync_completed", metadata: [
                "desired_region_count": 0,
                "added_region_count": 0,
                "removed_region_count": existing.count,
                "reason": "no_subscriptions"
            ])
            return
        }

        if #available(iOS 18.0, *) {
            ensureLocationServiceSessionIfNeeded()
        }
        requestAlwaysAuthorizationIfNeeded()

        guard canMonitorWithCurrentAuthorization else {
            stopMonitoring(Array(existing))
            clearArrivalMonitoringState()
            stopLocationUpdatesIfNeeded(reason: "missing location authorization")
            updateBackgroundLocationState(hasActiveGeofences: false)
            let syncMsg = "Geofence sync skipped: location authorization not granted"
            Task { @MainActor in
                DebugLogStore.shared.log(syncMsg, category: "Geofence")
            }
            print("📍 \(syncMsg)")
            logGeofenceDiagnostic("sync_skipped_missing_authorization", metadata: [
                "subscription_count": subscriptions.count,
                "removed_region_count": existing.count
            ])
            return
        }

        if StationsService.shared.stations.isEmpty {
            try? await StationsService.shared.loadStations()
        }
        let stationsByCrs = StationsService.shared.stations.reduce(into: [String: Station]()) { result, station in
            let key = station.crs.uppercased()
            if result[key] == nil {
                result[key] = station
            }
        }

        // Guard: if stations failed to load, stationsByCrs is empty which would make
        // `desired` empty and cause ALL existing geofences to be silently removed.
        // Bail out early to preserve the existing geofences.
        guard !stationsByCrs.isEmpty else {
            print("⚠️ [GeofenceManager] Stations not loaded — skipping geofence sync to preserve existing regions")
            Task { @MainActor in
                DebugLogStore.shared.log("Stations not loaded — skipping geofence sync to preserve existing regions", category: "Geofence")
            }
            logGeofenceDiagnostic("sync_skipped_stations_not_loaded", metadata: [
                "subscription_count": subscriptions.count,
                "existing_region_count": existing.count
            ])
            return
        }

        let desiredTargets = desiredTargets(subscriptions: subscriptions, stationsByCrs: stationsByCrs)
        let desired = desiredRegions(targets: desiredTargets)
        syncMonitoredTargets(desiredTargets)

        var removedCount = 0
        for region in existing where desired[region.identifier] == nil {
            manager.stopMonitoring(for: region)
            removedCount += 1
        }

        var addedCount = 0
        for (identifier, region) in desired {
            if !existing.contains(where: { $0.identifier == identifier }) {
                manager.startMonitoring(for: region)
                addedCount += 1
            }
        }

        // Request current state for ALL desired regions.
        // This is critical for the "already inside" case: if the user is already
        // within the geofence when monitoring starts, didEnterRegion will never fire.
        // didDetermineState(.inside) acts as a hint that seeds the normal arrival
        // heuristic rather than muting immediately.
        for (_, region) in desired {
            manager.requestState(for: region)
        }

        updateBackgroundLocationState(hasActiveGeofences: !desiredTargets.isEmpty)
        if !desiredTargets.isEmpty {
            startLowSensitivityTrackingIfNeeded(reason: "sync")
            if let currentLocation = currentUsableLocation(maxAge: ArrivalConfig.recentLocationForRegionHintSeconds) {
                evaluateArrival(using: currentLocation, source: "sync-current-location")
            }
        } else {
            stopLocationUpdatesIfNeeded(reason: "sync-empty")
        }

        let syncMsg = "Geofence sync: \(desired.count) desired, +\(addedCount) added, -\(removedCount) removed, tracking=\(desiredTargets.count)"
        Task { @MainActor in
            DebugLogStore.shared.log(syncMsg, category: "Geofence")
        }
        print("📍 \(syncMsg)")
        logGeofenceDiagnostic("sync_completed", metadata: [
            "subscription_count": subscriptions.count,
            "existing_region_count": existing.count,
            "desired_region_count": desired.count,
            "desired_target_count": desiredTargets.count,
            "added_region_count": addedCount,
            "removed_region_count": removedCount,
            "target_routes": desiredTargets.values.map { "\($0.from)-\($0.to)" }.sorted()
        ])
    }

    private func stopMonitoring(_ regions: [CLRegion]) {
        for region in regions {
            manager.stopMonitoring(for: region)
        }
    }

    private func ensureLocationServiceSessionIfNeeded() {
        guard #available(iOS 18.0, *) else { return }
        guard locationServiceSession == nil else { return }
        let session = CLServiceSession(authorization: .always)
        locationServiceSession = session
        startLocationServiceDiagnostics(session)
        logGeofenceDiagnostic("location_service_session_started")
        print("📍 [GeofenceManager] Started CLServiceSession(.always)")
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
        print("📍 \(msg)")
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
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
    }

    private func configureHighSensitivityTrackingProfile() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .otherNavigation
        manager.pausesLocationUpdatesAutomatically = false
    }

    private func startLowSensitivityTrackingIfNeeded(reason: String) {
        guard !monitoredTargets.isEmpty else { return }
        guard canMonitorWithCurrentAuthorization else { return }

        updateBackgroundLocationState(hasActiveGeofences: true)
        requestTemporaryFullAccuracyIfNeeded()

        guard trackingMode == nil else { return }
        configureLowSensitivityTrackingProfile()
        manager.startUpdatingLocation()
        manager.requestLocation()
        trackingMode = .lowSensitivity

        let msg = "Started low-sensitivity station-arrival tracking (\(reason))"
        DebugLogStore.shared.log(msg, category: "Geofence")
        logGeofenceDiagnostic("tracking_started", metadata: [
            "mode": "low",
            "reason": reason
        ])
        print("📍 \(msg)")
    }

    private func startHighSensitivityTracking(reason: String) {
        guard !monitoredTargets.isEmpty else { return }
        guard canMonitorWithCurrentAuthorization else { return }

        updateBackgroundLocationState(hasActiveGeofences: true)
        requestTemporaryFullAccuracyIfNeeded()

        if trackingMode != .highSensitivity {
            configureHighSensitivityTrackingProfile()
            manager.startUpdatingLocation()
            trackingMode = .highSensitivity

            let msg = "Started high-sensitivity station-arrival tracking (\(reason))"
            DebugLogStore.shared.log(msg, category: "Geofence")
            logGeofenceDiagnostic("tracking_started", metadata: [
                "mode": "high",
                "reason": reason
            ])
            print("📍 \(msg)")
        }

        manager.requestLocation()
    }

    private func stopLocationUpdatesIfNeeded(reason: String) {
        hasRequestedFullAccuracyThisSession = false
        guard trackingMode != nil else { return }

        manager.stopUpdatingLocation()
        configureLowSensitivityTrackingProfile()
        trackingMode = nil

        let msg = "Stopped station-arrival location updates (\(reason))"
        DebugLogStore.shared.log(msg, category: "Geofence")
        logGeofenceDiagnostic("tracking_stopped", metadata: [
            "reason": reason
        ])
        print("📍 \(msg)")
    }

    private func updateBackgroundLocationState(hasActiveGeofences: Bool) {
        manager.allowsBackgroundLocationUpdates = hasActiveGeofences
        manager.showsBackgroundLocationIndicator = hasActiveGeofences
        print("📍 [GeofenceManager] updateBackgroundLocationState active=\(hasActiveGeofences) allowsBackground=\(manager.allowsBackgroundLocationUpdates)")

        if #available(iOS 17.0, *) {
            if hasActiveGeofences {
                if backgroundActivitySession == nil {
                    let session = CLBackgroundActivitySession()
                    backgroundActivitySession = session
                    if #available(iOS 18.0, *) {
                        startBackgroundActivityDiagnostics(session)
                    }
                    logGeofenceDiagnostic("background_activity_started")
                    print("📍 [GeofenceManager] Started CLBackgroundActivitySession")
                }
            } else if let session = backgroundActivitySession as? CLBackgroundActivitySession {
                session.invalidate()
                backgroundActivityDiagnosticsTask?.cancel()
                backgroundActivityDiagnosticsTask = nil
                backgroundActivitySession = nil
                logGeofenceDiagnostic("background_activity_stopped")
                print("📍 [GeofenceManager] Stopped CLBackgroundActivitySession")
            } else {
                backgroundActivityDiagnosticsTask?.cancel()
                backgroundActivityDiagnosticsTask = nil
                backgroundActivitySession = nil
            }
        }

        if #available(iOS 18.0, *), !hasActiveGeofences {
            if let session = locationServiceSession as? CLServiceSession {
                session.invalidate()
                print("📍 [GeofenceManager] Invalidated CLServiceSession (no active geofences)")
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
                    station: station
                )
            }
        }
        return targets
    }

    private func desiredRegions(targets: [String: StationArrivalTarget]) -> [String: CLCircularRegion] {
        var regions: [String: CLCircularRegion] = [:]
        for (identifier, target) in targets {
            for (index, coordinate) in target.station.coordinates.enumerated() {
                if coordinate.latitude == 0 && coordinate.longitude == 0 { continue }
                let regionId = index == 0 ? identifier : regionIdentifier(
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
            }
        }
        return regions
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
    }

    private func clearArrivalMonitoringState() {
        monitoredTargets.removeAll()
        confirmationStates.removeAll()
        hasRequestedFullAccuracyThisSession = false
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

    private nonisolated func parseRegionIdentifier(_ identifier: String) -> (subscriptionId: String, from: String, to: String)? {
        let parts = identifier.split(separator: ":")
        guard parts.count >= 4, parts[0] == regionPrefix else { return nil }
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
        if let existing = monitoredTargets[identifier] {
            return existing
        }

        if StationsService.shared.stations.isEmpty {
            try? await StationsService.shared.loadStations()
        }
        guard let station = StationsService.shared.stations.first(where: {
            $0.crs.caseInsensitiveCompare(parsed.from) == .orderedSame
        }) else {
            let msg = "Unable to resolve station \(parsed.from) for region hint \(identifier)"
            DebugLogStore.shared.log(msg, category: "Error")
            print("❌ \(msg)")
            return nil
        }

        let target = StationArrivalTarget(
            identifier: identifier,
            subscriptionId: parsed.subscriptionId,
            from: parsed.from.uppercased(),
            to: parsed.to.uppercased(),
            station: station
        )
        monitoredTargets[identifier] = target
        if confirmationStates[identifier] == nil {
            confirmationStates[identifier] = StationArrivalConfirmationState()
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
        print("📍 \(msg)")

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
            print("📍 \(cachedMsg)")
            evaluateArrival(using: location, for: target, source: "region-\(source)-cached")
        } else if canMonitorWithCurrentAuthorization {
            let requestMsg = "Region hint [\(source)] has no recent usable location for \(target.from)→\(target.to); requesting current location"
            DebugLogStore.shared.log(requestMsg, category: "Geofence")
            print("📍 \(requestMsg)")
            manager.requestLocation()
        }
    }

    private func evaluateArrival(using location: CLLocation, source: String) {
        guard location.horizontalAccuracy >= 0 else { return }
        guard Date().timeIntervalSince(location.timestamp) <= ArrivalConfig.staleLocationCutoffSeconds else { return }

        for target in monitoredTargets.values.sorted(by: { $0.identifier < $1.identifier }) {
            evaluateArrival(using: location, for: target, source: source)
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
                print("📍 \(msg)")
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
                print("📍 \(msg)")
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
                print("📍 \(msg)")
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
                print("📍 \(msg)")
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
                print("✅ \(msg)")
                Task { @MainActor in
                    await self.triggerMuteFlow(
                        subscriptionId: target.subscriptionId,
                        from: target.from,
                        to: target.to
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
            print("📍 \(msg)")
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
                print("📍 \(msg)")
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
        guard let circular = region as? CLCircularRegion else { return }
        guard let parsed = parseRegionIdentifier(circular.identifier) else { return }

        // Always log boundary crossings to the server regardless of mute window,
        // so geofence health is visible in the admin even when the app is force-closed.
        GeofenceEventSender.shared.sendEvent(
            regionId: circular.identifier,
            from: parsed.from,
            to: parsed.to,
            eventType: "enter"
        )

        // Record that the user physically reached the origin station. If arrival is never
        // confirmed (background location suspended before the homing step finishes), this
        // marker lets us surface a "couldn't detect your arrival" notification on exit /
        // a later wake rather than failing silently. Cleared in triggerMuteFlow on success.
        NotificationMuteStorage.markArrivalDetectionPending(from: parsed.from, to: parsed.to)

        // Claim a background task synchronously BEFORE this method returns.
        // Without this, iOS can re-suspend the app immediately after didEnterRegion
        // returns — before the @MainActor task below has had a chance to run.
        // The token is released inside the task (via defer) once triggerMuteFlow
        // has been awaited and enqueueMute has been called.
        let muteFlowToken = AppBackgroundTaskToken(name: "geofence-entry-mute-flow")

        let message = "Entered region: \(circular.identifier)\nSub: \(parsed.subscriptionId)\nFrom: \(parsed.from.uppercased()) To: \(parsed.to.uppercased())"
        Task { @MainActor in
            defer { muteFlowToken.end() }
            DebugLogStore.shared.log(message, category: "Geofence")
            self.logGeofenceDiagnostic("region_entered", metadata: [
                "region_id": circular.identifier,
                "subscription_id": parsed.subscriptionId,
                "from": parsed.from.uppercased(),
                "to": parsed.to.uppercased()
            ])
            print("📍 \(message)")
            await self.handleRegionHint(identifier: circular.identifier, parsed: parsed, source: "enter")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let circular = region as? CLCircularRegion else { return }
        guard let parsed = parseRegionIdentifier(circular.identifier) else { return }

        GeofenceEventSender.shared.sendEvent(
            regionId: circular.identifier,
            from: parsed.from,
            to: parsed.to,
            eventType: "exit"
        )

        let message = "Exited region: \(circular.identifier)\nFrom: \(parsed.from.uppercased()) To: \(parsed.to.uppercased())"
        Task { @MainActor in
            DebugLogStore.shared.log(message, category: "Geofence")
            self.logGeofenceDiagnostic("region_exited", metadata: [
                "region_id": circular.identifier,
                "subscription_id": parsed.subscriptionId,
                "from": parsed.from.uppercased(),
                "to": parsed.to.uppercased()
            ])

            // The user entered and left the origin station. If arrival was never confirmed,
            // background detection failed silently — surface it so the user can re-arm it.
            await self.checkForMissedArrival(from: parsed.from, to: parsed.to, reason: "region-exit")

            let autoEndEnabled = (UserDefaults.standard.object(forKey: "autoEndLiveActivity") as? Bool) ?? true
            let hasPendingAutoEnd = NotificationMuteStorage.hasPendingLiveActivityAutoEndOnDeparture(from: parsed.from, to: parsed.to)

            guard autoEndEnabled else {
                if hasPendingAutoEnd {
                    NotificationMuteStorage.clearPendingLiveActivityAutoEndOnDeparture(from: parsed.from, to: parsed.to)
                    let skipMsg = "Geofence exit for \(parsed.from)→\(parsed.to) — auto-end disabled, clearing pending Live Activity departure end"
                    DebugLogStore.shared.log(skipMsg, category: "Geofence")
                    print("📍 \(skipMsg)")
                }
                return
            }

            guard NotificationMuteStorage.consumePendingLiveActivityAutoEndOnDeparture(from: parsed.from, to: parsed.to) else {
                return
            }

            let endMsg = "Geofence exit for \(parsed.from)→\(parsed.to) — sending departure event to end Live Activity"
            DebugLogStore.shared.log(endMsg, category: "Geofence")
            print("🏁 \(endMsg)")
            LiveActivityDepartureSender.shared.sendDeparture(from: parsed.from, to: parsed.to)
        }
        print("📍 \(message)")
    }

    // Exposed for the debug UI — shows which regions CLLocationManager is actually monitoring.
    var monitoredRegionIdentifiers: [String] {
        manager.monitoredRegions
            .filter { $0.identifier.hasPrefix(regionPrefix) }
            .map { $0.identifier }
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
        guard subscription.muteOnArrival != false else { return }
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
            station: station
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
        guard region.identifier.hasPrefix(regionPrefix) else { return }
        let msg = "Started monitoring: \(region.identifier)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("monitoring_started", metadata: [
                "region_id": region.identifier
            ])
        }
        print("📍 \(msg)")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let regionId = region?.identifier ?? "unknown"
        let msg = "Monitoring FAILED for \(regionId): \(error.localizedDescription)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Error")
            self.logGeofenceDiagnostic("monitoring_failed", metadata: [
                "region_id": regionId,
                "error": error.localizedDescription
            ])
        }
        print("❌ \(msg)")
    }

    // Called in response to requestState(for:) after sync, and also after startMonitoring.
    // Handles the critical "already inside" case: if the user is already within the
    // geofence boundary when monitoring starts, only didDetermineState(.inside) fires.
    nonisolated func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let circular = region as? CLCircularRegion,
              let parsed = parseRegionIdentifier(circular.identifier) else { return }

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
                "state": stateStr
            ])
        }
        print("📍 \(msg)")

        guard state == .inside else { return }

        let muteFlowToken = AppBackgroundTaskToken(name: "geofence-state-mute-flow")

        Task { @MainActor in
            defer { muteFlowToken.end() }
            await self.handleRegionHint(identifier: circular.identifier, parsed: parsed, source: "inside")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.evaluateArrival(using: location, source: "continuous")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
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
        print("❌ \(msg)")
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        let msg = "Location updates paused unexpectedly; restarting continuous arrival tracking"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("location_updates_paused")
            self.trackingMode = nil
            self.startLowSensitivityTrackingIfNeeded(reason: "pause-restart")
        }
        print("📍 \(msg)")
    }

    nonisolated func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        let msg = "Location updates resumed"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("location_updates_resumed")
        }
        print("📍 \(msg)")
    }

    /// Triggers the mute flow immediately once the arrival heuristic confirms station arrival.
    ///
    /// **Why async**: Some callers hold an `AppBackgroundTaskToken` during a background
    /// geofence wake. Making this function async (instead of wrapping in an internal
    /// Task) lets the caller await the point where the mute upload has been queued.
    ///
    /// **Why no client-side sleep**: iOS only grants ~30 s of background execution after a
    /// geofence wake, so `Task.sleep` is unreliable for delays > a few seconds. Instead,
    /// we pass `delay_minutes` to the server which applies the wait via `setTimeout`
    /// (always-on, never suspended). The server also sends the "muted" confirmation push
    /// after the delay, so no local notification is needed here.
    ///
    /// - Parameter simulate: When true the delay is zero (used by the debug simulate-arrival action).
    func triggerMuteFlow(subscriptionId: String, from: String, to: String,
                         sendNotification: Bool = true, simulate: Bool = false) async {
        // Guard against duplicate calls — both didEnterRegion and didDetermineState can fire
        // for the same region event. Since this function runs on @MainActor (via class
        // default isolation), the first call marks locally then any concurrent second call
        // hits this guard and returns cleanly.
        guard !NotificationMuteStorage.isMutedToday(from: from, to: to) else {
            let skipMsg = "triggerMuteFlow: already muted today for \(from)→\(to) — skipping duplicate"
            DebugLogStore.shared.log(skipMsg, category: "Mute")
            print("⏭ \(skipMsg)")
            return
        }

        // Mark locally immediately — prevents any concurrent triggerMuteFlow call (above guard)
        // from also sending a terminate request during the server-side delay window.
        markLegMutedLocally(from: from, to: to)

        // Arrival was detected — clear the pending marker so no missed-arrival
        // notification fires on the subsequent region exit.
        NotificationMuteStorage.clearArrivalDetectionPending(from: from, to: to)

        let delayMinutes = simulate ? 0 : ((UserDefaults.standard.object(forKey: "muteDelayMinutes") as? Int) ?? 3)
        let msg = delayMinutes > 0
            ? "Sending mute request with \(delayMinutes)-min server-side delay for \(from)→\(to)"
            : "Sending immediate mute request for \(from)→\(to)"
        DebugLogStore.shared.log(msg, category: "Mute")
        logGeofenceDiagnostic("mute_flow_started", metadata: [
            "subscription_id": subscriptionId,
            "from": from.uppercased(),
            "to": to.uppercased(),
            "delay_minutes": delayMinutes,
            "simulate": simulate
        ])
        print("⏳ \(msg)")

        // The terminate request is sent immediately via background URLSession (reliable
        // even after iOS suspends the app). The server delays the actual mute + push.
        NotificationMuteRequestSender.shared.enqueueMute(
            subscriptionId: subscriptionId,
            from: from,
            to: to,
            delayMinutes: delayMinutes
        )

        NotificationMuteStorage.markPendingLiveSessionPreserveOnArrival(from: from, to: to)
        NotificationMuteStorage.clearPendingLiveActivityAutoEndOnDeparture(from: from, to: to)

        let endMsg = "Ending journey updates immediately for arrival at \(from)→\(to)"
        DebugLogStore.shared.log(endMsg, category: "Mute")
        print("🏁 \(endMsg)")
        await LiveActivityManager.shared.stopMatching(
            fromCRS: from,
            toCRS: to,
            preserveNotificationLiveSession: true
        )
        // Remove the live session locally so UI/geofences stop immediately, but do not
        // DELETE it from the backend here. `/notifications/terminate` uses that server-side
        // record to send the welcome + muted-status pushes, and deleting it first can race
        // the terminate request and cause a 404/no confirmation notification.
        await NotificationSubscriptionStore.shared.removeLiveSessionsLocally(containingFrom: from, to: to)
    }

    func simulateArrival(subscriptionId: String, from: String, to: String, sendNotification: Bool = true) {
        let msg = "Simulated arrival for \(from.uppercased()) → \(to.uppercased())"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("arrival_simulated", metadata: [
                "subscription_id": subscriptionId,
                "from": from.uppercased(),
                "to": to.uppercased()
            ])
        }
        print("🧪 \(msg)")
        Task {
            await triggerMuteFlow(subscriptionId: subscriptionId, from: from, to: to,
                                  sendNotification: sendNotification, simulate: true)
        }
    }

    private func markLegMutedLocally(from: String, to: String) {
        let todayString = NotificationMuteStorage.markMuted(from: from, to: to)
        let legKey = NotificationMuteStorage.legKey(from: from, to: to)
        let msg = "Marked leg \(legKey) as muted locally for \(todayString)"
        Task { @MainActor in
            DebugLogStore.shared.log(msg, category: "Mute")
        }
        print("✅ \(msg)")
    }

    // MARK: - Background-wake arrival re-check & missed-arrival health

    /// Called when the app is woken by a background push (e.g. a Live Activity / journey
    /// update). Continuous background location after a geofence wake is not guaranteed to
    /// survive — especially once the app has been dormant for a while — so each push wake
    /// is used as a fresh chance to: re-sample location and complete an in-flight arrival
    /// confirmation, and surface a missed-arrival notification if detection silently failed.
    func refreshArrivalFromBackgroundWake(trigger: String) async {
        guard !monitoredTargets.isEmpty else { return }

        // Only run a sampling burst when an arrival is awaiting confirmation — i.e. the user
        // entered the origin geofence but we haven't confirmed yet. This targets the exact
        // failure case (post-enter suspension) and avoids spinning up GPS mid-journey when
        // the user has already left the origin behind.
        let hasPendingArrival = monitoredTargets.values.contains {
            NotificationMuteStorage.arrivalDetectionPendingSince(from: $0.from, to: $0.to) != nil
        }

        if hasPendingArrival, canMonitorWithCurrentAuthorization {
            logGeofenceDiagnostic("background_wake_arrival_refresh", metadata: ["trigger": trigger])
            // Keep the process alive for the brief sampling window below.
            let token = AppBackgroundTaskToken(name: "push-wake-arrival")
            updateBackgroundLocationState(hasActiveGeofences: true)
            startHighSensitivityTracking(reason: "\(trigger)-wake")
            // Give Core Location a short window to deliver several samples so the dwell-based
            // arrival confirmation in evaluateArrival can complete within this wake.
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            downgradeToLowSensitivityIfNoConfirmationInProgress()
            token.end()
        }

        await evaluateMissedArrivals(trigger: trigger)
    }

    /// After a background-wake sampling burst, drop back to the low-power profile unless an
    /// arrival confirmation is actively in progress (so we don't leave best-for-navigation
    /// updates running when the user isn't near a station).
    private func downgradeToLowSensitivityIfNoConfirmationInProgress() {
        guard trackingMode == .highSensitivity else { return }
        let confirming = confirmationStates.values.contains { $0.confirmationStartedAt != nil || $0.isFiring }
        guard !confirming else { return }
        trackingMode = nil
        startLowSensitivityTrackingIfNeeded(reason: "post-wake-downgrade")
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
        print("⚠️ \(msg)")
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            let msg = "Location authorization changed: status=\(self.authorizationStatusDescription(manager.authorizationStatus))"
            DebugLogStore.shared.log(msg, category: "Geofence")
            self.logGeofenceDiagnostic("authorization_changed", metadata: [
                "new_status": self.authorizationStatusDescription(manager.authorizationStatus)
            ])

            if self.canMonitorWithCurrentAuthorization {
                self.requestTemporaryFullAccuracyIfNeeded()
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

    func enqueueMute(subscriptionId: String, from: String, to: String, delayMinutes: Int = 0) {
        let baseURL = ApiHostPreference.currentBaseURL
        guard let url = URL(string: "\(baseURL)/notifications/terminate") else {
            let errorMsg = "Invalid URL for terminate endpoint: \(baseURL)"
            Task { @MainActor in DebugLogStore.shared.log(errorMsg, category: "Error") }
            print("❌ \(errorMsg)")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")

        let payload: [String: Any] = [
            "device_id": DeviceIdentity.deviceToken,
            "subscription_id": subscriptionId,
            "from": from.uppercased(),
            "to": to.uppercased(),
            "date": currentDateKey(),
            "delay_minutes": delayMinutes
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            let errorMsg = "Failed to encode mute request payload"
            Task { @MainActor in DebugLogStore.shared.log(errorMsg, category: "Error") }
            print("❌ \(errorMsg)")
            return
        }

        if let bodyString = String(data: body, encoding: .utf8) {
            let msg = "Sending mute request: \(bodyString)\nURL: \(url.absoluteString)"
            Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
            print("📤 \(msg)")
            Task { @MainActor in
                MuteRequestDebugStore.shared.record(payload: bodyString, url: url.absoluteString, status: "queued")
            }
        }

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
                dateKey: currentDateKey()
            )
        }
        task.resume()

        ClientDiagnosticsLogger.log("mute", "terminate_request_started", metadata: [
            "task_id": task.taskIdentifier,
            "url": url.absoluteString,
            "subscription_id": subscriptionId,
            "from": from.uppercased(),
            "to": to.uppercased(),
            "date": currentDateKey(),
            "delay_minutes": delayMinutes
        ])

        let msg = "Mute request task started for \(from.uppercased()) → \(to.uppercased())"
        Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
        print("✅ \(msg)")
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
            }
            ClientDiagnosticsLogger.log("mute", "terminate_request_failed", metadata: [
                "task_id": taskId,
                "error": error.localizedDescription,
                "url": context?.url,
                "subscription_id": context?.subscriptionId,
                "from": context?.from,
                "to": context?.to,
                "date": context?.dateKey,
                "delay_minutes": context?.delayMinutes
            ])
            let loggedMessage = msg
            Task { @MainActor in DebugLogStore.shared.log(loggedMessage, category: "Error") }
            print("❌ \(msg)")
            Task { @MainActor in
                MuteRequestDebugStore.shared.update(status: "error", response: error.localizedDescription)
            }
        } else if let response = task.response as? HTTPURLResponse {
            var msg = "Mute request completed with status: \(response.statusCode)"
            if let context {
                msg += "\nURL: \(context.url)"
                msg += "\nDevice: \(context.deviceId)"
                msg += "\nSubscription: \(context.subscriptionId)"
                msg += "\nLeg: \(context.from)→\(context.to)"
                msg += "\nDate: \(context.dateKey) Delay: \(context.delayMinutes)m"
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
            print(response.statusCode == 200 ? "✅ \(msg)" : "⚠️ \(msg)")
            Task { @MainActor in
                MuteRequestDebugStore.shared.update(status: "\(response.statusCode)", response: data.flatMap { String(data: $0, encoding: .utf8) })
            }

            if response.statusCode == 200, let context {
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
            }
        } else {
            let msg = "Mute request completed (no response details)"
            ClientDiagnosticsLogger.log("mute", "terminate_request_completed_without_response", metadata: [
                "task_id": taskId
            ])
            Task { @MainActor in DebugLogStore.shared.log(msg, category: "Mute") }
            print("✅ \(msg)")
            Task { @MainActor in
                MuteRequestDebugStore.shared.update(status: "ok", response: nil)
            }
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

private final class AppBackgroundTaskToken: @unchecked Sendable {
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
            print("❌ [GeofenceEvent] Invalid URL")
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
        print("📡 [GeofenceEvent] \(msg)")

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
            print("❌ [GeofenceEvent] Request failed: \(error.localizedDescription)")
        } else if let response = task.response as? HTTPURLResponse {
            ClientDiagnosticsLogger.log("geofence", "server_event_completed", metadata: [
                "task_id": taskId,
                "status": response.statusCode
            ])
            print("📡 [GeofenceEvent] Response: \(response.statusCode)")
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
            print("❌ [LiveActivityDeparture] Invalid URL")
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
            print("❌ [LiveActivityDeparture] Failed to encode payload")
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

        print("📡 [LiveActivityDeparture] Sent departure event \(from.uppercased())→\(to.uppercased())")
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
            print("❌ [LiveActivityDeparture] Request failed: \(error.localizedDescription)")
        } else if let response = task.response as? HTTPURLResponse {
            print("📡 [LiveActivityDeparture] Response: \(response.statusCode)")
        }
    }
}
