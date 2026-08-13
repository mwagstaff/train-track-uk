import CoreLocation
import Foundation

enum StationDetectionPolicy {
    static let maximumMonitoredConditions = 20
    static let conditionsPerStationCoordinate = 2
    static let departureAccuracyMarginMeters: CLLocationDistance = 50
    static let departureConfirmationSeconds: TimeInterval = 6
    static let persistedStateLifetime: TimeInterval = 4 * 60 * 60

    static func isDefinitelyOutsideStation(
        rawDistance: CLLocationDistance,
        horizontalAccuracy: CLLocationAccuracy,
        radius: CLLocationDistance
    ) -> Bool {
        guard rawDistance.isFinite,
              horizontalAccuracy.isFinite,
              horizontalAccuracy >= 0 else {
            return false
        }
        return rawDistance - horizontalAccuracy > radius + departureAccuracyMarginMeters
    }

    static func canAllocateStationCoordinate(currentConditionCount: Int) -> Bool {
        guard currentConditionCount >= 0 else { return false }
        return currentConditionCount + conditionsPerStationCoordinate <= maximumMonitoredConditions
    }

    static func isPersistedStateCurrent(
        recordedAt: Date,
        now: Date = Date(),
        lifetime: TimeInterval = persistedStateLifetime
    ) -> Bool {
        let age = now.timeIntervalSince(recordedAt)
        return age >= 0 && age <= lifetime
    }
}
