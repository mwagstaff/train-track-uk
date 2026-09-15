import CoreLocation
import Foundation
import Testing
@testable import TrainTrack_UK

struct SiriRouteLocationProviderTests {
    private let now = Date(timeIntervalSince1970: 1_789_458_120)

    @Test func usableLocationsRespectFreshnessAndAccuracyBoundaries() {
        #expect(SiriRouteLocationProvider.isUsable(location(age: 60, accuracy: 1_000), now: now))
        #expect(SiriRouteLocationProvider.isUsable(location(age: -5, accuracy: 0), now: now))
        #expect(!SiriRouteLocationProvider.isUsable(location(age: 60.1), now: now))
        #expect(!SiriRouteLocationProvider.isUsable(location(age: -5.1), now: now))
        #expect(!SiriRouteLocationProvider.isUsable(location(accuracy: -1), now: now))
        #expect(!SiriRouteLocationProvider.isUsable(location(accuracy: 1_001), now: now))
        #expect(!SiriRouteLocationProvider.isUsable(location(accuracy: .infinity), now: now))
    }

    @Test func invalidAndPlaceholderCoordinatesCannotChooseDirection() {
        #expect(!SiriRouteLocationProvider.isUsable(location(latitude: 91), now: now))
        #expect(!SiriRouteLocationProvider.isUsable(location(longitude: 181), now: now))
        #expect(!SiriRouteLocationProvider.isUsable(location(latitude: 0, longitude: 0), now: now))
        #expect(!SiriRouteLocationProvider.isUsable(location(latitude: .nan), now: now))
        #expect(SiriRouteLocationProvider.isUsable(location(longitude: 0), now: now))
    }

    @Test func legacyCacheNeedsRealAccuracyAndRetainsOriginalTimestamp() throws {
        let suite = "SiriRouteLocationProviderTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(51.4, forKey: "widget_last_lat")
        defaults.set(-0.04, forKey: "widget_last_lng")
        defaults.set(now.addingTimeInterval(-30).timeIntervalSince1970, forKey: "widget_last_loc_ts")

        #expect(SiriRouteLocationProvider.cachedLocation(in: defaults, now: now) == nil)
        defaults.set(42.0, forKey: "widget_last_horizontal_accuracy")
        let cached = try #require(SiriRouteLocationProvider.cachedLocation(in: defaults, now: now))
        #expect(cached.horizontalAccuracy == 42)
        #expect(cached.timestamp == now.addingTimeInterval(-30))
        #expect(SiriRouteLocationProvider.cachedLocation(in: defaults, now: now.addingTimeInterval(31)) == nil)
    }

    private func location(age: TimeInterval = 0, accuracy: Double = 100,
                          latitude: Double = 51.4, longitude: Double = -0.04) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                   altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                   timestamp: now.addingTimeInterval(-age))
    }
}
