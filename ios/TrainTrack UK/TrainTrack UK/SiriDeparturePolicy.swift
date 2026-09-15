import Foundation

// This adapter consumes the existing app models, which share the app's main-actor
// isolation. Calendar arithmetic and response formatting are pure value operations.
@MainActor
enum SiriDeparturePolicy {
    static func result(snapshot: JourneyDeparturesSnapshot, from: Station, to: Station,
                       now: Date, details: [String: ServiceDetails] = [:], requireDetails: Bool = false) -> SiriLookupResult {
        let route = "\(from.name) to \(to.name)"
        guard from.crs.caseInsensitiveCompare(to.crs) != .orderedSame else {
            return SiriLookupResult(dialog: "Choose two different stations.", routeLabel: route,
                                    departures: [], freshnessLabel: "Invalid route", outcome: .invalidRoute)
        }
        guard snapshot.dataStatus == .live || snapshot.dataStatus == .partial,
              let provenance = snapshot.siri,
              provenance.failureReason == nil,
              SiriRailTime.isFresh(SiriRailTime.parseISO(provenance.providerObservedAt), now: now),
              SiriRailTime.isFresh(SiriRailTime.parseISO(provenance.fetchedAt), now: now) else {
            return .unavailable(routeLabel: route)
        }

        var options: [SiriDeparture] = []
        var cancellations: [Date] = []
        var unresolvable = false
        var seen = Set<String>()
        for departure in snapshot.departures {
            guard departure.hasProviderServiceID, seen.insert(departure.serviceID).inserted else {
                unresolvable = true
                continue
            }
            guard let row = departure.siri,
                  let boardObserved = SiriRailTime.parseISO(row.providerObservedAt),
                  SiriRailTime.isFresh(boardObserved, now: now) else {
                unresolvable = true
                continue
            }
            // These rows are already known to be unavailable and need no detail
            // request. In particular, cancelled rows are excluded from that batch.
            if departure.isCancelled || departure.departureTime.estimated == "Cancelled" {
                if let date = SiriRailTime.uniqueDate(departure.departureTime.scheduled, near: boardObserved,
                                                      from: -12 * 3600, through: 12 * 3600) {
                    cancellations.append(date)
                }
                continue
            }
            if hasActual(departure.departureTime.actual) { continue }
            let detail = details[departure.serviceID]
            if let detail {
                guard SiriRailTime.isFresh(SiriRailTime.parseISO(detail.generatedAt), now: now),
                      detail.std != nil, detail.etd != nil else {
                    unresolvable = true
                    continue
                }
            } else if requireDetails {
                unresolvable = true
                continue
            }
            let detailObserved = detail.flatMap { SiriRailTime.parseISO($0.generatedAt) }
            let useDetail = detailObserved.map { $0 >= boardObserved } ?? false
            let observed = useDetail ? (detailObserved ?? boardObserved) : boardObserved
            let scheduledClock = useDetail ? (detail?.std ?? departure.departureTime.scheduled) : departure.departureTime.scheduled
            let estimate = useDetail ? (detail?.etd ?? departure.departureTime.estimated) : departure.departureTime.estimated
            let cancelled = detail?.isCancelled == true || detail?.etd == "Cancelled"
            if cancelled {
                if let date = SiriRailTime.uniqueDate(scheduledClock, near: observed,
                                                      from: -12 * 3600, through: 12 * 3600) {
                    cancellations.append(date)
                }
                continue
            }
            if hasActual(detail?.atd) { continue }
            if let detail {
                guard detail.subsequentCallingPoints != nil else {
                    unresolvable = true
                    continue
                }
                guard validJourney(details: detail, from: from.crs, to: to.crs, now: now) else { continue }
            }

            let uncertain = estimate.caseInsensitiveCompare("Delayed") == .orderedSame
            let onTime = estimate == "On time" || estimate == scheduledClock
            let expected: Date?
            let scheduled: Date?
            if uncertain {
                expected = nil
                scheduled = SiriRailTime.uniqueDate(scheduledClock, near: observed,
                                                    from: -12 * 3600, through: 12 * 3600)
            } else {
                // A live departure board supplies upcoming services. Keep its observed
                // date as the anchor, never the phone's current calendar or timezone.
                expected = SiriRailTime.uniqueDate(onTime ? scheduledClock : estimate,
                                                   near: observed, from: -60, through: 6 * 3600)
                scheduled = expected.flatMap { date in
                    onTime ? date : SiriRailTime.uniqueDate(scheduledClock, near: date,
                                                           from: -12 * 3600, through: 60 * 60)
                }
            }
            guard let scheduled, uncertain || expected != nil else {
                unresolvable = true
                continue
            }
            // A passed estimate does not prove a departure occurred. It also cannot
            // justify a confident next-train answer, so expose uncertainty instead.
            let passedEstimate = expected.map { $0 < now } ?? false
            // Prefer the newer observation, including withdrawn/retained platforms.
            // Fetch order alone does not establish which upstream snapshot is newer.
            let platform: String?
            if useDetail, let detail {
                platform = confirmedPlatform(detail.platform)
            } else {
                platform = row.platformSource == "reported"
                    && SiriRailTime.isFresh(SiriRailTime.parseISO(row.platformObservedAt), now: now)
                    ? confirmedPlatform(departure.platform) : nil
            }
            let minutesLate = expected.map { Int(($0.timeIntervalSince(scheduled) / 60).rounded()) }
            let status: String
            if uncertain { status = "Delayed · No new time yet" }
            else if passedEstimate { status = "Departure not yet confirmed" }
            else if let minutesLate, minutesLate > 0 { status = "\(minutesLate) minutes late" }
            else if onTime { status = "On time" }
            else { status = "Expected \(SiriDisplayTime.format(expected ?? scheduled))" }
            let transport: String
            switch departure.serviceType.lowercased() {
            case "bus": transport = "Replacement bus"
            case "train": transport = "Train"
            default: transport = "Service"
            }
            let reference = SiriDepartureReference(serviceID: departure.serviceID, originCRS: from.crs,
                                                  destinationCRS: to.crs, scheduledDeparture: scheduled)
            options.append(SiriDeparture(
                id: reference.id, originCRS: from.crs, originName: from.name,
                destinationCRS: to.crs, destinationName: to.name, serviceID: departure.serviceID,
                operatingDate: nil, scheduledDeparture: scheduled, expectedDeparture: expected,
                platform: platform?.isEmpty == false ? platform : nil,
                statusLabel: status, transportLabel: transport,
                freshnessLabel: "Live snapshot at \(SiriDisplayTime.format(observed)) London time",
                timingUncertain: uncertain || passedEstimate,
                providerObservedAt: observed,
                backendSnapshotAt: SiriRailTime.parseISO(provenance.fetchedAt),
                clientFetchedAt: now
            ))
        }

        let timed = options.filter { !$0.timingUncertain }.sorted {
            ($0.expectedDeparture ?? $0.scheduledDeparture) < ($1.expectedDeparture ?? $1.scheduledDeparture)
        }
        let uncertain = options.filter(\.timingUncertain).sorted { $0.scheduledDeparture < $1.scheduledDeparture }
        let partial = snapshot.dataStatus == .partial || unresolvable
        let freshness = partial ? "Partial live snapshot · London time" : "Live snapshot · London time"
        guard !timed.isEmpty || !uncertain.isEmpty else {
            if unresolvable { return .unavailable(routeLabel: route) }
            let message = snapshot.dataStatus == .partial
                ? "The departure board is incomplete. I couldn't confirm a direct departure from \(from.name) to \(to.name)."
                : "I couldn't find an available direct departure from \(from.name) to \(to.name) in the returned departure board."
            return SiriLookupResult(dialog: message, routeLabel: route, departures: [], freshnessLabel: freshness,
                                    outcome: snapshot.dataStatus == .partial ? .partial : .noDepartures)
        }

        let selected: [SiriDeparture]
        var dialog: String
        let firstTimedDate = timed.first.map { $0.expectedDeparture ?? $0.scheduledDeparture }
        if let unknown = uncertain.first(where: { departure in
            firstTimedDate.map { departure.scheduledDeparture <= $0 } ?? true
        }) {
            selected = Array(([unknown] + timed).prefix(3))
            let service = "\(SiriDisplayTime.format(unknown.scheduledDeparture)) \(unknown.transportLabel.lowercased()) from \(from.name) to \(to.name)"
            if unknown.expectedDeparture != nil {
                dialog = "I can't confirm whether the \(service) has left."
            } else {
                dialog = "The \(service) is delayed, with no new departure time yet."
            }
            if let first = timed.first {
                dialog += " Another \(first.transportLabel.lowercased()) is expected at \(SiriDisplayTime.format(first.expectedDeparture ?? first.scheduledDeparture))\(spokenPlatform(first.platform))."
            }
        } else {
            selected = Array((timed + uncertain).prefix(3))
            guard let first = selected.first else { return .unavailable(routeLabel: route) }
            dialog = SiriResponseFormatter.departure(first, now: now, complete: !partial)
            if let cancelled = cancellations.filter({ $0 >= now.addingTimeInterval(-60) && $0 < first.scheduledDeparture }).min() {
                dialog = "The \(SiriDisplayTime.format(cancelled)) service is cancelled. " + dialog
            }
        }
        if partial { dialog += " Some departure information is unavailable." }
        return SiriLookupResult(dialog: dialog, routeLabel: route, departures: selected, freshnessLabel: freshness,
                                outcome: partial ? .partial : .live)
    }

    static func hasActual(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        return value == "On time" || value == "Cancelled"
            || !SiriRailTime.candidates(value, near: Date(timeIntervalSince1970: 0)).isEmpty
    }

    static func confirmedPlatform(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = ["", "-", "unknown", "tbc", "tba", "n/a", "not available", "not announced", "suppressed"]
        return placeholders.contains(trimmed.lowercased()) ? nil : trimmed
    }

    static func validJourney(details: ServiceDetails, from: String, to: String, now: Date) -> Bool {
        guard details.isCancelled != true,
              SiriRailTime.isFresh(SiriRailTime.parseISO(details.generatedAt), now: now) else { return false }
        // A service-detail ID identifies its boarding board call. A different current
        // location, repeated origin, departed call or cancelled association is unsafe.
        guard details.crs == from, !hasActual(details.atd),
              !(details.previousCallingPoints ?? []).flatMap(\.callingPoint).contains(where: { $0.crs == from }) else { return false }
        return (details.subsequentCallingPoints ?? []).contains { branch in
            branch.serviceChangeRequired != true && branch.assocIsCancelled != true
                && branch.callingPoint.contains { $0.crs == to && !$0.isCancelledAtStation }
        }
    }

    static func trackedCalls(details: ServiceDetails, from: String, to: String) -> (boarding: CallingPoint, destination: CallingPoint)? {
        guard let firstBranch = details.stationBranches.first else { return nil }
        let previousCount = details.previousCallingPoints?.first?.callingPoint.count ?? 0
        let prefix = Array(firstBranch.prefix(previousCount + 1))
        let following = (details.subsequentCallingPoints ?? []).filter { !$0.callingPoint.isEmpty }
        let branches = following.isEmpty ? [prefix] : following.filter {
            $0.assocIsCancelled != true && $0.serviceChangeRequired != true
        }.map { prefix + $0.callingPoint }
        for branch in branches {
            let origins = branch.indices.filter { branch[$0].crs == from }
            guard origins.count == 1, let origin = origins.first,
                  !branch[origin].isCancelledAtStation else { continue }
            if let destination = branch.dropFirst(origin + 1).first(where: { $0.crs == to }) {
                return (branch[origin], destination)
            }
        }
        return nil
    }

    private static func spokenPlatform(_ platform: String?) -> String {
        platform.map { ", from platform \(SiriResponseFormatter.platform($0))" } ?? "; the platform is not confirmed"
    }
}

nonisolated enum SiriResponseFormatter {
    static func platform(_ value: String) -> String {
        guard let number = Int(value) else { return value }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.numberStyle = .spellOut
        return formatter.string(from: NSNumber(value: number)) ?? value
    }

    static func departure(_ departure: SiriDeparture, now: Date, complete: Bool = true) -> String {
        let expected = departure.expectedDeparture ?? departure.scheduledDeparture
        let minutes = max(0, Int(ceil(expected.timeIntervalSince(now) / 60)))
        let countdown = minutes == 0 ? "due now" : "in \(minutes) minute\(minutes == 1 ? "" : "s")"
        let platform = departure.platform.map { ", from platform \(Self.platform($0))" } ?? ""
        let delay = Int((expected.timeIntervalSince(departure.scheduledDeparture) / 60).rounded())
        let status = delay > 0 ? " It's \(delay) minutes late."
            : departure.statusLabel == "On time" ? " It's running on time." : ""
        let missingPlatform = departure.platform == nil ? " The platform is not confirmed." : ""
        let introduction = complete ? "Your next" : "A confirmed"
        return "\(introduction) \(departure.transportLabel.lowercased()) from \(departure.originName) to \(departure.destinationName) is expected at \(SiriDisplayTime.format(expected)), \(countdown)\(platform).\(status)\(missingPlatform)"
    }
}
