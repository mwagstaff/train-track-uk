import Foundation

enum JourneyServiceMatchingPolicy {
    static let departureDetectionLookback: TimeInterval = 30 * 60
    static let departureDetectionTolerance: TimeInterval = 2 * 60

    /// Bound fallback lookups to trains around the original departure observation.
    static func detailRecoveryServiceIDs(
        departures: [DepartureV2], recentDepartures: [RecentDepartureV2], detectedAt: Date
    ) -> [String] {
        let lower = detectedAt.addingTimeInterval(-departureDetectionLookback)
        let board = departures.compactMap { departure -> (String, Date)? in
            guard !departure.isCancelled, departure.hasProviderServiceID,
                  let scheduled = JourneyHistoryTime.date(for: departure.departureTime.scheduled,
                    near: departure.evidenceObservedAt ?? detectedAt),
                  (lower...detectedAt).contains(scheduled) else { return nil }
            return (departure.serviceID, scheduled)
        }
        let recent = recentDepartures.filter {
            !$0.isCancelled && (lower...detectedAt).contains($0.scheduledDepartureAt)
        }.map { ($0.serviceID, $0.scheduledDepartureAt) }
        var seen = Set<String>()
        return (board + recent).sorted { $0.1 > $1.1 }
            .compactMap { seen.insert($0.0).inserted ? $0.0 : nil }.prefix(4).map { $0 }
    }

    /// Only an actual departure at the boarding station can resolve a stale forecast.
    /// Generated-at anchors the service day so reused identifiers cannot select yesterday's train.
    static func departureEvidence(
        serviceID: String, details: ServiceDetails, from: Station, to: Station, detectedAt: Date
    ) -> RecentDepartureV2? {
        guard details.crs.caseInsensitiveCompare(from.crs) == .orderedSame,
              details.isCancelled != true,
              details.subsequentCallingPoints?.contains(where: { branch in
                  branch.callingPoint.contains {
                      $0.crs.caseInsensitiveCompare(to.crs) == .orderedSame && $0.isCancelled != true
                  }
              }) == true,
              let observedAt = SiriRailTime.parseISO(details.generatedAt),
              let scheduledText = details.std,
              let scheduled = JourneyHistoryTime.date(for: scheduledText, near: observedAt),
              let actualText = details.atd,
              let actual = JourneyHistoryTime.date(
                  for: actualText.caseInsensitiveCompare("On time") == .orderedSame ? details.std : actualText,
                  near: scheduled
              ),
              abs(scheduled.timeIntervalSince(detectedAt)) <= departureDetectionLookback,
              actual <= detectedAt else { return nil }
        return RecentDepartureV2(
            serviceID: serviceID, serviceType: details.serviceType, fromCRS: from.crs, toCRS: to.crs,
            scheduledDeparture: scheduledText, estimatedDeparture: details.etd,
            actualDeparture: actualText.caseInsensitiveCompare("On time") == .orderedSame ? details.std : actualText,
            scheduledDepartureAt: scheduled,
            estimatedDepartureAt: JourneyHistoryTime.date(for: details.etd, near: scheduled),
            actualDepartureAt: actual, platform: details.platform, isCancelled: false,
            lastObservedAt: observedAt, providerObservedAt: observedAt
        )
    }

    struct Match {
        let departure: DepartureV2?
        let scheduledDepartureAt: Date?
        let timeDifferenceMinutes: Int?
        let confidence: Double
        var eligibleServiceIDs: [String] = []

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

    /// The staff and public feeds use different IDs for the same departure.
    /// Collapse only a one-to-one pair with a matching dated timetable/platform,
    /// backed by a newer actual departure. Same-feed or conflicting records remain ambiguous.
    private static func coalescingFeedAliases(_ candidates: [Candidate], fromCRS: String) -> [Candidate] {
        Dictionary(grouping: candidates, by: \.scheduledDepartureAt).values.flatMap { group -> [Candidate] in
            guard group.count == 2,
                  let staff = group.first(where: {
                      $0.departure.serviceID.range(of: "^staff_[0-9]{15}_[A-Z]{3}_[0-9]{8}T[0-9]{6}_P$",
                          options: .regularExpression) != nil
                  }),
                  staff.departure.serviceID.split(separator: "_")[2].uppercased() == fromCRS.uppercased(),
                  let other = group.first(where: { $0.departure.serviceID != staff.departure.serviceID }),
                  other.departure.serviceID.range(of: "^[0-9]+[A-Z_]+$", options: .regularExpression) != nil,
                  staff.departure.serviceType == "train", other.departure.serviceType == "train",
                  staff.departure.isCancelled == other.departure.isCancelled,
                  let platform = staff.departure.platform?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !platform.isEmpty, platform.caseInsensitiveCompare("TBC") != .orderedSame,
                  platform == other.departure.platform?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let actual = staff.actualDepartureAt,
                  other.actualDepartureAt == nil || other.actualDepartureAt == actual,
                  let staffObserved = staff.departure.evidenceObservedAt,
                  let otherObserved = other.departure.evidenceObservedAt,
                  staffObserved >= otherObserved else { return group }
            return [staff]
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
            let previousIsNewer = previous.evidenceObservedAt.map { previousAt in
                departure.evidenceObservedAt.map { $0 < previousAt } ?? true
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
        if let newerAt = newer.evidenceObservedAt, let olderAt = older.evidenceObservedAt,
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
                for: departure.departureTime.scheduled, near: departure.evidenceObservedAt ?? detectedAt
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
            // A history receipt time cannot make an older provider forecast newer.
            let boardIsNewer = existing?.evidenceObservedAt.map { boardAt in
                recent.providerObservedAt.map { boardAt > $0 } ?? true
            } ?? false
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
                timestamp: boardIsNewer ? existing?.evidenceObservedAt : recent.evidenceObservedAt,
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
        let eligible = coalescingFeedAliases(Array(candidatesByID.values), fromCRS: from.crs).filter { candidate in
            guard !candidate.departure.isCancelled else { return false }
            if candidate.hasUnresolvedDelay {
                // "Delayed" gives no departure time. A recently observed train can
                // still be plausible even when its timetable precedes passenger arrival.
                return candidate.scheduledDepartureAt <= detectedAt
                    && (candidate.departure.evidenceObservedAt.map {
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
              !selected.hasUnresolvedDelay else {
            var unmatched = Match.unmatched
            unmatched.eligibleServiceIDs = eligible.map(\.departure.serviceID).sorted()
            return unmatched
        }
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
            confidence: confidence,
            eligibleServiceIDs: [selected.departure.serviceID]
        )
    }
}
