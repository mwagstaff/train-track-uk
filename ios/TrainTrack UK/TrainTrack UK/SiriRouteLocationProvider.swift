import CoreLocation
import Foundation

/// A single, permission-preserving location attempt for choosing a route direction.
@MainActor
final class SiriRouteLocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocation?, Error>?
    private var timeoutTask: Task<Void, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.showsBackgroundLocationIndicator = false
    }

    static func currentLocation() async throws -> CLLocation? {
        try Task.checkCancellation()
        // Each invocation owns its manager and cancellation; concurrent Siri requests
        // cannot stop an existing screen's location request or each other's work.
        let provider = SiriRouteLocationProvider()
        let location = try await provider.readLocation()
        try Task.checkCancellation()
        return location
    }

    nonisolated static func isUsable(_ location: CLLocation, now: Date) -> Bool {
        let coordinate = location.coordinate
        let age = now.timeIntervalSince(location.timestamp)
        return coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && CLLocationCoordinate2DIsValid(coordinate)
            && (coordinate.latitude != 0 || coordinate.longitude != 0)
            && location.horizontalAccuracy.isFinite
            && (0...1_000).contains(location.horizontalAccuracy)
            && age.isFinite && (-5...60).contains(age)
    }

    nonisolated static func cachedLocation(in defaults: UserDefaults, now: Date) -> CLLocation? {
        guard let latitude = defaults.object(forKey: "widget_last_lat") as? Double,
              let longitude = defaults.object(forKey: "widget_last_lng") as? Double,
              let timestamp = defaults.object(forKey: "widget_last_loc_ts") as? Double,
              let accuracy = defaults.object(forKey: "widget_last_horizontal_accuracy") as? Double else { return nil }
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            altitude: 0,
            horizontalAccuracy: accuracy,
            verticalAccuracy: -1,
            timestamp: Date(timeIntervalSince1970: timestamp)
        )
        return isUsable(location, now: now) ? location : nil
    }

    private var hasAuthorization: Bool {
        manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse
    }

    private func readLocation() async throws -> CLLocation? {
        try Task.checkCancellation()
        // Check authorization before consulting either cache, including after revocation.
        guard hasAuthorization else { return nil }
        let now = Date()
        let sharedDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack")
        let cached = [manager.location, sharedDefaults.flatMap { Self.cachedLocation(in: $0, now: now) }]
            .compactMap { $0 }
            .filter { Self.isUsable($0, now: now) }
            .max { $0.timestamp < $1.timestamp }
        if let cached { return cached }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 2_000_000_000)
                        self?.finish(.success(nil))
                    } catch {
                        // Completion or caller cancellation already stopped this timer.
                    }
                }
                // No authorization/session request: background delivery remains best effort.
                manager.requestLocation()
            }
        } onCancel: {
            Task { @MainActor in
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func finish(_ result: Result<CLLocation?, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
        continuation.resume(with: result)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if !hasAuthorization { finish(.success(nil)) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard hasAuthorization else {
            finish(.success(nil))
            return
        }
        let now = Date()
        finish(.success(locations.filter { Self.isUsable($0, now: now) }.max { $0.timestamp < $1.timestamp }))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.success(nil))
    }
}
