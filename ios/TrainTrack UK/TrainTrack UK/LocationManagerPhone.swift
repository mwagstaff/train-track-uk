import Foundation
import CoreLocation
import Combine

@MainActor
final class LocationManagerPhone: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: CLLocationCoordinate2D? = nil

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func request() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            break
        @unknown default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            coordinate = loc.coordinate
            // Persist last known location for the widget to consume via App Group
            if let ud = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") {
                ud.set(loc.coordinate.latitude, forKey: "widget_last_lat")
                ud.set(loc.coordinate.longitude, forKey: "widget_last_lng")
                ud.set(Date().timeIntervalSince1970, forKey: "widget_last_loc_ts")
                ud.synchronize()
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore errors; coordinate remains nil
    }
}
