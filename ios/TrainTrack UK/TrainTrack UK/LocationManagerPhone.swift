import Foundation
import CoreLocation
import Combine
import UIKit

@MainActor
final class LocationManagerPhone: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D? = nil
    @Published private(set) var coordinateTimestamp: Date? = nil
    @Published private(set) var lastLocation: CLLocation? = nil

    private let manager = CLLocationManager()
    private var isRequestingLocation = false
    private var timeoutTask: Task<Void, Never>?
    private var backgroundObserver: AnyCancellable?
    private let sharedDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack")
    private let bootstrapLocationCacheMaxAge: TimeInterval = 6 * 60 * 60
    private let freshLocationMaxAge: TimeInterval = 2 * 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.showsBackgroundLocationIndicator = false
        debugLog("📍 [LocationManagerPhone] init auth=\(manager.authorizationStatus.rawValue)")
        loadCachedLocationIfAvailable()
        backgroundObserver = NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.cancel()
                }
            }
        #if DEBUG
        if ProcessInfo.processInfo.environment["APP_STORE_SCREENSHOTS"] == "1" {
            let fixture = CLLocation(latitude: 51.412659, longitude: -0.045786)
            lastLocation = fixture
            coordinate = fixture.coordinate
            coordinateTimestamp = fixture.timestamp
        }
        #endif
    }

    func request(forceFresh: Bool = false) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["APP_STORE_SCREENSHOTS"] == "1" {
            return
        }
        #endif
        if !forceFresh, hasFreshCachedLocation(maxAge: freshLocationMaxAge) {
            debugLog("📍 [LocationManagerPhone] request skipped; using cached location")
            return
        }
        debugLog("📍 [LocationManagerPhone] request auth=\(manager.authorizationStatus.rawValue)")
        switch manager.authorizationStatus {
        case .notDetermined:
            debugLog("📍 [LocationManagerPhone] requesting WhenInUse authorization")
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestOneShotLocation()
        case .denied, .restricted:
            debugLog("📍 [LocationManagerPhone] request ignored; authorization unavailable")
            break
        @unknown default:
            break
        }
    }

    func cancel() {
        if isRequestingLocation {
            debugLog("📍 [LocationManagerPhone] cancel active request")
        }
        isRequestingLocation = false
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        debugLog("📍 [LocationManagerPhone] authorization changed -> \(manager.authorizationStatus.rawValue)")
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            requestOneShotLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            debugLog("📍 [LocationManagerPhone] didUpdateLocations lat=\(loc.coordinate.latitude) lng=\(loc.coordinate.longitude)")
            cancel()
            lastLocation = loc
            coordinate = loc.coordinate
            coordinateTimestamp = loc.timestamp
            // Persist last known location for the widget to consume via App Group
            if let ud = sharedDefaults {
                ud.set(loc.coordinate.latitude, forKey: "widget_last_lat")
                ud.set(loc.coordinate.longitude, forKey: "widget_last_lng")
                ud.set(loc.timestamp.timeIntervalSince1970, forKey: "widget_last_loc_ts")
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        debugLog("📍 [LocationManagerPhone] didFailWithError \(error.localizedDescription)")
        cancel()
        // Ignore errors; coordinate remains nil
    }

    private func requestOneShotLocation() {
        guard !isRequestingLocation else { return }
        isRequestingLocation = true
        debugLog("📍 [LocationManagerPhone] requestLocation()")
        manager.requestLocation()
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.cancel()
            }
        }
    }

    var freshCoordinate: CLLocationCoordinate2D? {
        guard let coordinate, let coordinateTimestamp else { return nil }
        guard Date().timeIntervalSince(coordinateTimestamp) <= freshLocationMaxAge else { return nil }
        return coordinate
    }

    var lastKnownCoordinate: CLLocationCoordinate2D? {
        guard let coordinate else { return nil }
        guard let coordinateTimestamp else { return coordinate }
        guard Date().timeIntervalSince(coordinateTimestamp) <= bootstrapLocationCacheMaxAge else { return nil }
        return coordinate
    }

    private func hasFreshCachedLocation(maxAge: TimeInterval) -> Bool {
        loadCachedLocationIfAvailable(maxAge: maxAge)
        return freshCoordinate != nil
    }

    private func loadCachedLocationIfAvailable(maxAge: TimeInterval? = nil) {
        guard let ud = sharedDefaults else { return }
        guard let lat = ud.object(forKey: "widget_last_lat") as? Double,
              let lng = ud.object(forKey: "widget_last_lng") as? Double else {
            return
        }
        let timestamp = ud.double(forKey: "widget_last_loc_ts")
        let cachedAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        let allowedAge = maxAge ?? bootstrapLocationCacheMaxAge
        if let cachedAt, Date().timeIntervalSince(cachedAt) > allowedAge {
            return
        }
        let cachedCoordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        coordinate = cachedCoordinate
        coordinateTimestamp = cachedAt
        if let cachedAt {
            lastLocation = CLLocation(
                coordinate: cachedCoordinate,
                altitude: 0,
                horizontalAccuracy: kCLLocationAccuracyHundredMeters,
                verticalAccuracy: -1,
                timestamp: cachedAt
            )
        }
    }

    deinit {
        debugLog("📍 [LocationManagerPhone] deinit")
        timeoutTask?.cancel()
        backgroundObserver?.cancel()
        manager.stopUpdatingLocation()
    }
}
