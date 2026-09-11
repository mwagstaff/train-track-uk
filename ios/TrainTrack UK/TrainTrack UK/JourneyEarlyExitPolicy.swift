import Foundation

/// Requires repeated device observations after a service departs; elapsed wall time
/// alone must never turn a cached station location into evidence of an early exit.
nonisolated struct JourneyEarlyExitPolicy {
    static let maximumLocationAge: TimeInterval = 15
    static let maximumHorizontalAccuracy: Double = 65
    static let maximumObservationGap: TimeInterval = 45
    static let requiredDwellSeconds: TimeInterval = 90
    static let maximumDwellSpeed: Double = 3

    private struct Evidence {
        let stationCRS: String
        let serviceDepartedAt: Date
        let firstObservedAt: Date
        var lastObservedAt: Date
    }

    private var evidence: Evidence?
    private var lastLocationTimestamp: Date?

    var observedDwellSeconds: TimeInterval {
        guard let evidence else { return 0 }
        return evidence.lastObservedAt.timeIntervalSince(evidence.firstObservedAt)
    }

    mutating func reset() {
        evidence = nil
        lastLocationTimestamp = nil
    }

    mutating func shouldEndJourney(
        stationCRS: String?,
        departedStationCRS: String?,
        departedAt: Date?,
        locationTimestamp: Date,
        evaluatedAt: Date,
        horizontalAccuracy: Double,
        speed: Double
    ) -> Bool {
        guard let departedStationCRS, !departedStationCRS.isEmpty, let departedAt else {
            reset()
            return false
        }

        let locationAge = evaluatedAt.timeIntervalSince(locationTimestamp)
        guard locationAge.isFinite, locationAge >= 0, locationAge <= Self.maximumLocationAge,
              horizontalAccuracy.isFinite, horizontalAccuracy >= 0,
              horizontalAccuracy <= Self.maximumHorizontalAccuracy else {
            return false
        }
        if let lastLocationTimestamp, locationTimestamp <= lastLocationTimestamp {
            return false
        }
        lastLocationTimestamp = locationTimestamp

        guard let stationCRS,
              stationCRS.caseInsensitiveCompare(departedStationCRS) == .orderedSame,
              locationTimestamp >= departedAt,
              speed.isFinite, speed >= 0, speed < Self.maximumDwellSpeed else {
            evidence = nil
            return false
        }

        let stationCode = stationCRS.uppercased()
        if var current = evidence,
           current.stationCRS == stationCode,
           current.serviceDepartedAt == departedAt,
           locationTimestamp.timeIntervalSince(current.lastObservedAt) <= Self.maximumObservationGap {
            current.lastObservedAt = locationTimestamp
            evidence = current
        } else {
            evidence = Evidence(
                stationCRS: stationCode,
                serviceDepartedAt: departedAt,
                firstObservedAt: locationTimestamp,
                lastObservedAt: locationTimestamp
            )
        }

        return observedDwellSeconds >= Self.requiredDwellSeconds
    }
}
