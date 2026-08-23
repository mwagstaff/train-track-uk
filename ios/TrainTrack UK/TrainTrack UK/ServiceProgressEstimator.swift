import Foundation

struct ServiceProgressEstimate: Equatable, Sendable {
    let previousStationIndex: Int
    let nextStationIndex: Int
    let fraction: Double

    static let unavailable = ServiceProgressEstimate(
        previousStationIndex: -1,
        nextStationIndex: -1,
        fraction: 0
    )

    var isAvailable: Bool {
        previousStationIndex >= 0 && nextStationIndex >= 0
    }

    var floatingIndex: Double {
        guard isAvailable else { return -1 }
        return Double(previousStationIndex)
            + (Double(nextStationIndex - previousStationIndex) * min(max(fraction, 0), 1))
    }
}

enum ServiceProgressEstimator {
    static func estimate(
        for stations: [CallingPoint],
        at now: Date = Date(),
        calendar: Calendar = .current
    ) -> ServiceProgressEstimate {
        guard !stations.isEmpty else { return .unavailable }
        let effectiveDates = resolvedEffectiveDates(for: stations, near: now, calendar: calendar)
        let validIndices = stations.indices.filter { !stations[$0].isCancelledAtStation }
        guard let firstValidIndex = validIndices.first,
              let lastValidIndex = validIndices.last else {
            return .unavailable
        }

        guard let lastActualIndex = validIndices.last(where: { hasActualTime(stations[$0].at) }) else {
            return atStation(firstValidIndex)
        }
        guard let nextIndex = validIndices.first(where: { $0 > lastActualIndex }) else {
            return atStation(lastValidIndex)
        }
        guard let arrivalTime = effectiveDates[nextIndex] else {
            return atStation(lastActualIndex)
        }
        let departureTime = departureDate(
            for: stations[lastActualIndex],
            expectedDate: effectiveDates[lastActualIndex],
            calendar: calendar
        )
        guard let departureTime, now > departureTime else {
            return atStation(lastActualIndex)
        }
        let duration = arrivalTime.timeIntervalSince(departureTime)
        guard duration > 0 else { return atStation(lastActualIndex) }
        guard now < arrivalTime else { return atStation(nextIndex) }
        return ServiceProgressEstimate(
            previousStationIndex: lastActualIndex,
            nextStationIndex: nextIndex,
            fraction: min(max(now.timeIntervalSince(departureTime) / duration, 0), 1)
        )
    }

    private static func atStation(_ index: Int) -> ServiceProgressEstimate {
        ServiceProgressEstimate(
            previousStationIndex: index,
            nextStationIndex: index,
            fraction: 0
        )
    }

    private static func hasActualTime(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value.caseInsensitiveCompare("Cancelled") != .orderedSame
    }

    private static func resolvedEffectiveDates(
        for stations: [CallingPoint],
        near now: Date,
        calendar: Calendar
    ) -> [Date?] {
        var absoluteMinutes = Array<Int?>(repeating: nil, count: stations.count)
        var dayOffset = 0
        var previousMinutes: Int?

        for (index, station) in stations.enumerated() {
            guard let minutes = effectiveMinutes(for: station) else { continue }
            var candidate = minutes + (dayOffset * 24 * 60)
            if let previousMinutes, candidate < previousMinutes - (12 * 60) {
                dayOffset += 1
                candidate += 24 * 60
            }
            absoluteMinutes[index] = candidate
            previousMinutes = candidate
        }

        let knownMinutes = absoluteMinutes.compactMap { $0 }
        guard let firstMinutes = knownMinutes.first, let lastMinutes = knownMinutes.last else {
            return Array(repeating: nil, count: stations.count)
        }

        let today = calendar.startOfDay(for: now)
        let baseDay = (-1...1).map { dayDelta in
            calendar.date(byAdding: .day, value: dayDelta, to: today)!
        }.min { first, second in
            distanceFromTimeline(now, first: first, firstMinutes: firstMinutes, lastMinutes: lastMinutes)
                < distanceFromTimeline(now, first: second, firstMinutes: firstMinutes, lastMinutes: lastMinutes)
        } ?? today

        return absoluteMinutes.map { minutes in
            minutes.map { baseDay.addingTimeInterval(TimeInterval($0 * 60)) }
        }
    }

    private static func distanceFromTimeline(
        _ now: Date,
        first baseDay: Date,
        firstMinutes: Int,
        lastMinutes: Int
    ) -> TimeInterval {
        let start = baseDay.addingTimeInterval(TimeInterval(firstMinutes * 60))
        let end = baseDay.addingTimeInterval(TimeInterval(lastMinutes * 60))
        if now < start { return start.timeIntervalSince(now) }
        if now > end { return now.timeIntervalSince(end) }
        return 0
    }

    private static func effectiveMinutes(for station: CallingPoint) -> Int? {
        if let estimated = station.et,
           estimated.caseInsensitiveCompare("On time") != .orderedSame,
           estimated.caseInsensitiveCompare("Cancelled") != .orderedSame {
            return clockMinutes(estimated)
        }
        return clockMinutes(station.st)
    }

    private static func clockMinutes(_ value: String) -> Int? {
        let components = value.split(separator: ":")
        guard components.count == 2,
              let hour = Int(components[0]),
              let minute = Int(components[1]),
              (0..<24).contains(hour),
              (0..<60).contains(minute) else {
            return nil
        }
        return (hour * 60) + minute
    }

    private static func departureDate(
        for station: CallingPoint,
        expectedDate: Date?,
        calendar: Calendar
    ) -> Date? {
        guard let expectedDate else { return nil }
        guard let actual = station.at,
              actual.caseInsensitiveCompare("On time") != .orderedSame,
              actual.caseInsensitiveCompare("Cancelled") != .orderedSame,
              let actualMinutes = clockMinutes(actual) else {
            return expectedDate
        }

        let expectedDay = calendar.startOfDay(for: expectedDate)
        return (-1...1).compactMap { dayDelta -> Date? in
            calendar.date(byAdding: .day, value: dayDelta, to: expectedDay)?
                .addingTimeInterval(TimeInterval(actualMinutes * 60))
        }.min(by: {
            abs($0.timeIntervalSince(expectedDate)) < abs($1.timeIntervalSince(expectedDate))
        })
    }
}
