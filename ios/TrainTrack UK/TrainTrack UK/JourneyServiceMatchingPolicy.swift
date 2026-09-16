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
        let actualDepartureAt: Date?

        var hasUnresolvedDelay: Bool {
            actualDepartureAt == nil
                && departure.departureTime.estimated.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("Delayed") == .orderedSame
        }
    }

    /// Keep a caught train after it disappears from the board, while refreshing
    /// estimates for trains that are still present without overwriting newer evidence.
    static func mergedDepartures(
        originSnapshot: [DepartureV2],
        currentDepartures: [DepartureV2]
    ) -> [DepartureV2] {
        var byID: [String: DepartureV2] = [:]
        for departure in originSnapshot + currentDepartures {
            guard let previous = byID[departure.serviceID] else {
                byID[departure.serviceID] = departure
                continue
            }
            let previousIsNewer = previous.timestamp.map { previousAt in
                departure.timestamp.map { $0 < previousAt } ?? true
            } ?? false
            byID[departure.serviceID] = retainingActualDeparture(
                in: previousIsNewer ? previous : departure,
                from: previousIsNewer ? departure : previous
            )
        }
        return byID.values.sorted { $0.serviceID < $1.serviceID }
    }

    private static func retainingActualDeparture(in newer: DepartureV2, from older: DepartureV2) -> DepartureV2 {
        guard newer.departureTime.actual == nil, let actual = older.departureTime.actual else { return newer }
        if let newerAt = newer.timestamp, let olderAt = older.timestamp,
           newerAt.timeIntervalSince(olderAt) > 12 * 60 * 60 { return newer }
        return DepartureV2(
            departureTime: DepartureTimeV2(scheduled: newer.departureTime.scheduled,
                estimated: newer.departureTime.estimated, actual: actual),
            serviceType: newer.serviceType, platform: newer.platform, isCancelled: newer.isCancelled,
            length: newer.length, destination: newer.destination, origin: newer.origin,
            serviceID: newer.serviceID, delayReason: newer.delayReason, cancelReason: newer.cancelReason,
            timestamp: newer.timestamp, operator: newer.operator, operatorCode: newer.operatorCode,
            siri: newer.siri, hasProviderServiceID: newer.hasProviderServiceID
        )
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
        for departure in mergedDepartures(originSnapshot: [], currentDepartures: departures) {
            guard let scheduled = JourneyHistoryTime.date(
                for: departure.departureTime.scheduled, near: departure.timestamp ?? detectedAt
            ) else { continue }
            let estimated = JourneyHistoryTime.date(for: departure.departureTime.estimated, near: scheduled) ?? scheduled
            let actual = JourneyHistoryTime.date(for: departure.departureTime.actual, near: scheduled)
            candidatesByID[departure.serviceID] = Candidate(
                departure: departure, scheduledDepartureAt: scheduled,
                effectiveDepartureAt: actual ?? max(scheduled, estimated), actualDepartureAt: actual
            )
        }
        for recent in recentDepartures where
            recent.fromCRS.caseInsensitiveCompare(from.crs) == .orderedSame
                && recent.toCRS.caseInsensitiveCompare(to.crs) == .orderedSame {
            let existingCandidate = candidatesByID[recent.serviceID]
            let existing = existingCandidate?.departure
            // Reused service identifiers must not let a previous service day replace
            // a current board observation.
            if let existingCandidate,
               abs(existingCandidate.scheduledDepartureAt.timeIntervalSince(recent.scheduledDepartureAt)) > 12 * 60 * 60 {
                continue
            }
            let boardIsNewer = existing?.timestamp.map { $0 > recent.lastObservedAt } ?? false
            if recent.actualDepartureAt == nil, boardIsNewer { continue }
            let useBoardActual = existingCandidate?.actualDepartureAt != nil
                && (boardIsNewer || recent.actualDepartureAt == nil)
            let actualDepartureAt = useBoardActual ? existingCandidate?.actualDepartureAt : recent.actualDepartureAt
            let actualDeparture = useBoardActual ? existing?.departureTime.actual : recent.actualDeparture
            let departure = DepartureV2(
                departureTime: DepartureTimeV2(
                    scheduled: recent.scheduledDeparture,
                    estimated: actualDeparture ?? recent.estimatedDeparture ?? recent.scheduledDeparture,
                    actual: actualDeparture
                ),
                serviceType: recent.serviceType,
                platform: recent.platform ?? existing?.platform,
                isCancelled: boardIsNewer ? (existing?.isCancelled ?? recent.isCancelled) : recent.isCancelled,
                length: existing?.length,
                destination: existing?.destination ?? [PlaceInfoV2(crs: to.crs, locationName: to.name, via: nil)],
                origin: existing?.origin ?? [PlaceInfoV2(crs: from.crs, locationName: from.name, via: nil)],
                serviceID: recent.serviceID,
                delayReason: existing?.delayReason,
                cancelReason: existing?.cancelReason,
                timestamp: max(existing?.timestamp ?? .distantPast, recent.lastObservedAt),
                operator: existing?.operator,
                operatorCode: existing?.operatorCode,
                siri: existing?.siri,
                hasProviderServiceID: existing?.hasProviderServiceID ?? true
            )
            candidatesByID[recent.serviceID] = Candidate(
                departure: departure,
                scheduledDepartureAt: recent.scheduledDepartureAt,
                effectiveDepartureAt: actualDepartureAt
                    ?? max(recent.scheduledDepartureAt, recent.estimatedDepartureAt ?? recent.scheduledDepartureAt),
                actualDepartureAt: actualDepartureAt
            )
        }

        let earliestDeparture = max(
            detectedAt.addingTimeInterval(-departureDetectionLookback),
            originArrivedAt?.addingTimeInterval(-departureDetectionTolerance) ?? .distantPast
        )
        let eligible = candidatesByID.values.filter { candidate in
            guard !candidate.departure.isCancelled else { return false }
            if candidate.hasUnresolvedDelay {
                // "Delayed" gives no departure time. A recently observed train can
                // still be plausible even when its timetable precedes passenger arrival.
                return candidate.scheduledDepartureAt <= detectedAt
                    && (candidate.departure.timestamp.map {
                        $0 >= detectedAt.addingTimeInterval(-departureDetectionLookback)
                    } ?? true)
            }
            return candidate.effectiveDepartureAt >= earliestDeparture
                && candidate.effectiveDepartureAt <= detectedAt
        }
        // A region exit is an upper bound on departure, not an exact boarding time.
        // Nearest-time selection (including an automatic Live Activity preference)
        // would turn a delayed geofence observation into a confident later-train match.
        // Actual departure establishes that a train ran; it does not prove that
        // the passenger boarded it instead of another equally plausible train.
        guard eligible.count == 1, let selected = eligible.first,
              !selected.hasUnresolvedDelay else { return .unmatched }
        let difference = Int(abs(selected.effectiveDepartureAt.timeIntervalSince(detectedAt)) / 60)
        let confidence: Double
        switch difference {
        case 0...2: confidence = 0.9
        case 3...5: confidence = 0.75
        case 6...10: confidence = 0.55
        default: confidence = 0.35
        }
        return Match(
            departure: selected.departure,
            scheduledDepartureAt: selected.scheduledDepartureAt,
            timeDifferenceMinutes: difference,
            confidence: confidence
        )
    }
}
