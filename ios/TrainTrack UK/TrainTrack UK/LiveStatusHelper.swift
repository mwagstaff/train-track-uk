import Foundation

struct LiveStatusInfo {
    let text: String
    let delayMinutes: Int
}

// Use the map's full-service progress, even when the passenger boards farther along
// the route. Unknown estimates are not evidence that the train has reached a stop.
func computeLiveStatus(
    from serviceDetails: ServiceDetails,
    within fromCRS: String? = nil,
    toCRS: String? = nil,
    at now: Date = Date()
) -> LiveStatusInfo? {
    guard serviceDetails.serviceType.lowercased() == "train" else { return nil }
    let stations = serviceDetails.stationBranches.first(where: { branch in
        toCRS.map { code in branch.contains { $0.crs.caseInsensitiveCompare(code) == .orderedSame } } ?? false
    }) ?? serviceDetails.allStations
    let valid = stations.indices.filter { !stations[$0].isCancelledAtStation }
    guard let first = valid.first, let last = valid.last else { return nil }

    func minutes(_ value: String?) -> Int? {
        guard let value else { return nil }
        let parts = value.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
              (0..<24).contains(h), (0..<60).contains(m) else { return nil }
        return h * 60 + m
    }
    func hasActual(_ station: CallingPoint) -> Bool {
        station.at?.caseInsensitiveCompare("On time") == .orderedSame || minutes(station.at) != nil
    }
    func delay(_ station: CallingPoint) -> Int {
        let time = hasActual(station) ? station.at : station.et
        if time?.caseInsensitiveCompare("Delayed") == .orderedSame { return 240 }
        guard let scheduled = minutes(station.st), let actual = minutes(time) else { return 0 }
        let difference = (actual - scheduled + 1440) % 1440
        return difference <= 720 ? difference : 0
    }
    func phrase(_ delay: Int) -> String {
        if delay >= 240 { return "delayed for an unknown period of time" }
        return delay == 0 ? "on time" : "\(delay) minute\(delay == 1 ? "" : "s") late"
    }
    let destination = toCRS.flatMap { code in
        valid.first { stations[$0].crs.caseInsensitiveCompare(code) == .orderedSame }
    } ?? last
    // Only a recorded actual at the passenger's destination confirms arrival.
    if hasActual(stations[destination]) {
        let d = delay(stations[destination])
        return LiveStatusInfo(text: "Arrived \(phrase(d)) at \(stations[destination].locationName)", delayMinutes: d)
    }
    guard valid.contains(where: { hasActual(stations[$0]) }) else {
        let d = delay(stations[first])
        let text = d >= 240
            ? "Departure from \(stations[first].locationName) delayed for an unknown period of time"
            : "Scheduled to depart \(stations[first].locationName) \(phrase(d))"
        return LiveStatusInfo(text: text, delayMinutes: d)
    }
    let progress = ServiceProgressEstimator.estimate(for: stations, at: now)
    guard progress.isAvailable else { return nil }
    let previous = stations[progress.previousStationIndex]
    let next = stations[progress.nextStationIndex]
    // When estimates ahead are unknown the map stays at the last known stop.
    let unknownAhead = valid.contains {
        $0 >= progress.previousStationIndex && $0 <= destination
            && !hasActual(stations[$0]) && stations[$0].et?.caseInsensitiveCompare("Delayed") == .orderedSame
    }
    let d = unknownAhead ? 240 : max(delay(previous), delay(next))
    let location = progress.previousStationIndex == progress.nextStationIndex
        ? "at \(previous.locationName)"
        : "between \(previous.locationName) and \(next.locationName)"
    return LiveStatusInfo(text: "Currently \(phrase(d)), \(location)", delayMinutes: d)
}
