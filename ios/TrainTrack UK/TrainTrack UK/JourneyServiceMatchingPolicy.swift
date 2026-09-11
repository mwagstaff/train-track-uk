import Foundation

enum JourneyServiceMatchingPolicy {
    static let departureDetectionLookback: TimeInterval = 30 * 60
    static let departureDetectionTolerance: TimeInterval = 2 * 60

    struct Match {
        let departure: DepartureV2?
        let scheduledDepartureAt: Date?
        let timeDifferenceMinutes: Int?
        let confidence: Double

        static let unmatched = Match(
            departure: nil, scheduledDepartureAt: nil, timeDifferenceMinutes: nil, confidence: 0
        )
    }

    private struct Candidate {
        let departure: DepartureV2
        let scheduledDepartureAt: Date
        let effectiveDepartureAt: Date
    }

    static func match(
        departures: [DepartureV2],
        recentDepartures: [RecentDepartureV2],
        from: Station,
        to: Station,
        detectedAt: Date,
        originArrivedAt: Date?,
        preferredServiceID: String? = nil,
        preferredDeparture: DepartureV2? = nil
    ) -> Match {
        // A user's explicit correction remains authoritative, including when
        // they select a service just before it departs.
        if let preferredDeparture, !preferredDeparture.isCancelled {
            let scheduled = JourneyHistoryTime.date(for: preferredDeparture.departureTime.scheduled, near: detectedAt)
            return Match(
                departure: preferredDeparture,
                scheduledDepartureAt: scheduled,
                timeDifferenceMinutes: JourneyHistoryTime.circularMinuteDifference(
                    JourneyItineraryBuilder.departureDisplayTime(preferredDeparture), from: detectedAt
                ),
                confidence: 1
            )
        }

        var candidatesByID: [String: Candidate] = [:]
        for departure in departures {
            guard let scheduled = JourneyHistoryTime.date(for: departure.departureTime.scheduled, near: detectedAt),
                  let effective = JourneyHistoryTime.date(
                      for: JourneyItineraryBuilder.departureDisplayTime(departure), near: scheduled
                  ) else { continue }
            candidatesByID[departure.serviceID] = Candidate(
                departure: departure, scheduledDepartureAt: scheduled, effectiveDepartureAt: effective
            )
        }
        for recent in recentDepartures where
            recent.fromCRS.caseInsensitiveCompare(from.crs) == .orderedSame
                && recent.toCRS.caseInsensitiveCompare(to.crs) == .orderedSame {
            let existing = candidatesByID[recent.serviceID]?.departure
            if recent.actualDepartureAt == nil,
               let observedAt = existing?.timestamp, observedAt > recent.lastObservedAt {
                continue
            }
            let departure = DepartureV2(
                departureTime: DepartureTimeV2(
                    scheduled: recent.scheduledDeparture,
                    estimated: recent.actualDeparture ?? recent.estimatedDeparture ?? recent.scheduledDeparture
                ),
                serviceType: recent.serviceType,
                platform: recent.platform ?? existing?.platform,
                isCancelled: recent.isCancelled,
                length: existing?.length,
                destination: existing?.destination ?? [PlaceInfoV2(crs: to.crs, locationName: to.name, via: nil)],
                origin: existing?.origin ?? [PlaceInfoV2(crs: from.crs, locationName: from.name, via: nil)],
                serviceID: recent.serviceID,
                delayReason: existing?.delayReason,
                cancelReason: existing?.cancelReason,
                timestamp: recent.lastObservedAt,
                operator: existing?.operator,
                operatorCode: existing?.operatorCode
            )
            candidatesByID[recent.serviceID] = Candidate(
                departure: departure,
                scheduledDepartureAt: recent.scheduledDepartureAt,
                effectiveDepartureAt: recent.actualDepartureAt ?? recent.estimatedDepartureAt ?? recent.scheduledDepartureAt
            )
        }

        let earliestDeparture = max(
            detectedAt.addingTimeInterval(-departureDetectionLookback),
            originArrivedAt?.addingTimeInterval(-departureDetectionTolerance) ?? .distantPast
        )
        let latestDeparture = detectedAt.addingTimeInterval(departureDetectionTolerance)
        let eligible = candidatesByID.values.filter {
            !$0.departure.isCancelled
                && $0.effectiveDepartureAt >= earliestDeparture
                && $0.effectiveDepartureAt <= latestDeparture
        }
        let preferred = preferredServiceID.flatMap { serviceID in
            eligible.first { $0.departure.serviceID == serviceID }
        }
        let selected = preferred ?? eligible.min { left, right in
            let leftDifference = abs(left.effectiveDepartureAt.timeIntervalSince(detectedAt))
            let rightDifference = abs(right.effectiveDepartureAt.timeIntervalSince(detectedAt))
            if leftDifference != rightDifference { return leftDifference < rightDifference }
            return left.effectiveDepartureAt < right.effectiveDepartureAt
        }
        guard let selected else { return .unmatched }
        let difference = Int(abs(selected.effectiveDepartureAt.timeIntervalSince(detectedAt)) / 60)
        let confidence: Double
        if preferred != nil {
            confidence = 0.98
        } else {
            switch difference {
            case 0...2: confidence = 0.9
            case 3...5: confidence = 0.75
            case 6...10: confidence = 0.55
            default: confidence = 0.35
            }
        }
        return Match(
            departure: selected.departure,
            scheduledDepartureAt: selected.scheduledDepartureAt,
            timeDifferenceMinutes: difference,
            confidence: confidence
        )
    }
}
