import CoreLocation
import Foundation

nonisolated enum StationDetectionPolicy {
    static let maximumMonitoredConditions = 20
    static let conditionsPerStationCoordinate = 2
    static let departureAccuracyMarginMeters: CLLocationDistance = 50
    static let departureConfirmationSeconds: TimeInterval = 6
    static let recoveryLifetime: TimeInterval = 60 * 60
    static let conditionEventActionLifetime = recoveryLifetime
    static let maximumDwellObservationGap: TimeInterval = 30
    static let persistedStateLifetime: TimeInterval = 4 * 60 * 60

    static func isRecoverableObservation(recordedAt: Date, now: Date = Date()) -> Bool {
        isPersistedStateCurrent(recordedAt: recordedAt, now: now, lifetime: recoveryLifetime)
    }

    static func shouldProcessObservation(recordedAt: Date, after previous: Date?, now: Date = Date()) -> Bool {
        isRecoverableObservation(recordedAt: recordedAt, now: now)
            && (previous.map { recordedAt > $0 } ?? true)
    }

    static func shouldProcessRegionObservation(recordedAt: Date, lastObservedAt: Date?, lastHandledAt: Date?, now: Date = Date()) -> Bool {
        shouldProcessObservation(recordedAt: recordedAt, after: lastHandledAt, now: now)
            && (lastObservedAt.map { recordedAt >= $0 } ?? true)
    }

    static func canContinueDwell(previous: Date?, observedAt: Date) -> Bool {
        guard let previous else { return false }
        let gap = observedAt.timeIntervalSince(previous)
        return gap > 0 && gap <= maximumDwellObservationGap
    }

    static func isExitAfterArrival(_ observation: StationRegionObservation, arrivedAt: Date, now: Date = Date()) -> Bool {
        !observation.isInside && observation.observedAt >= arrivedAt
            && isRecoverableObservation(recordedAt: observation.observedAt, now: now)
    }

    static func orderedLocations(_ locations: [CLLocation], after previous: Date? = nil, now: Date = Date()) -> [CLLocation] {
        var last = previous
        return locations.sorted { $0.timestamp < $1.timestamp }.filter { location in
            guard location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0,
                  CLLocationCoordinate2DIsValid(location.coordinate),
                  shouldProcessObservation(recordedAt: location.timestamp, after: last, now: now) else { return false }
            last = location.timestamp
            return true
        }
    }

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

    static func isConditionEventActionable(recordedAt: Date, now: Date = Date()) -> Bool {
        isPersistedStateCurrent(
            recordedAt: recordedAt,
            now: now,
            lifetime: conditionEventActionLifetime
        )
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

/// The last observation is evidence about that time, not a fresh location query.
nonisolated struct StationRegionObservation: Codable, Equatable {
    let isInside: Bool
    let observedAt: Date
    let insideSince: Date?
    var lastEntryAt: Date? = nil

    func updating(isInside: Bool, at date: Date) -> Self {
        Self(isInside: isInside, observedAt: date,
             insideSince: isInside ? (self.isInside ? insideSince ?? date : date) : nil,
             lastEntryAt: isInside ? (self.isInside ? insideSince ?? lastEntryAt ?? date : date) : insideSince ?? lastEntryAt)
    }
}
