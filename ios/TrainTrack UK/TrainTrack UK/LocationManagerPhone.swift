import Foundation
import CoreLocation
import Combine
import UIKit

@MainActor
final class LocationManagerPhone: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D? = nil

    private let manager = CLLocationManager()
    private var isRequestingLocation = false
    private var timeoutTask: Task<Void, Never>?
    private var backgroundObserver: AnyCancellable?
    private let sharedDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack")
    private let locationCacheMaxAge: TimeInterval = 6 * 60 * 60

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.showsBackgroundLocationIndicator = false
        print("📍 [LocationManagerPhone] init auth=\(manager.authorizationStatus.rawValue)")
        loadCachedLocationIfAvailable()
        backgroundObserver = NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.cancel()
                }
            }
    }

    func request() {
        if hasFreshCachedLocation {
            print("📍 [LocationManagerPhone] request skipped; using cached location")
            return
        }
        print("📍 [LocationManagerPhone] request auth=\(manager.authorizationStatus.rawValue)")
        switch manager.authorizationStatus {
        case .notDetermined:
            print("📍 [LocationManagerPhone] requesting WhenInUse authorization")
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            requestOneShotLocation()
        case .denied, .restricted:
            print("📍 [LocationManagerPhone] request ignored; authorization unavailable")
            break
        @unknown default:
            break
        }
    }

    func cancel() {
        if isRequestingLocation {
            print("📍 [LocationManagerPhone] cancel active request")
        }
        isRequestingLocation = false
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.stopUpdatingLocation()
    }

    // MARK: - CLLocationManagerDelegate
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        print("📍 [LocationManagerPhone] authorization changed -> \(manager.authorizationStatus.rawValue)")
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            requestOneShotLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            print("📍 [LocationManagerPhone] didUpdateLocations lat=\(loc.coordinate.latitude) lng=\(loc.coordinate.longitude)")
            cancel()
            coordinate = loc.coordinate
            // Persist last known location for the widget to consume via App Group
            if let ud = sharedDefaults {
                ud.set(loc.coordinate.latitude, forKey: "widget_last_lat")
                ud.set(loc.coordinate.longitude, forKey: "widget_last_lng")
                ud.set(Date().timeIntervalSince1970, forKey: "widget_last_loc_ts")
                ud.synchronize()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("📍 [LocationManagerPhone] didFailWithError \(error.localizedDescription)")
        cancel()
        // Ignore errors; coordinate remains nil
    }

    private func requestOneShotLocation() {
        guard !isRequestingLocation else { return }
        isRequestingLocation = true
        print("📍 [LocationManagerPhone] requestLocation()")
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

    private var hasFreshCachedLocation: Bool {
        loadCachedLocationIfAvailable()
        return coordinate != nil
    }

    private func loadCachedLocationIfAvailable() {
        guard let ud = sharedDefaults else { return }
        guard let lat = ud.object(forKey: "widget_last_lat") as? Double,
              let lng = ud.object(forKey: "widget_last_lng") as? Double else {
            return
        }
        let timestamp = ud.double(forKey: "widget_last_loc_ts")
        if timestamp > 0, Date().timeIntervalSince(Date(timeIntervalSince1970: timestamp)) > locationCacheMaxAge {
            return
        }
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    deinit {
        print("📍 [LocationManagerPhone] deinit")
        timeoutTask?.cancel()
        backgroundObserver?.cancel()
        manager.stopUpdatingLocation()
    }
}
