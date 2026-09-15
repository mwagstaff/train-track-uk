import Foundation

// Additive metadata on the existing departures response. Missing fields mean unknown,
// including when talking to a server version that predates Siri support.
nonisolated struct SiriBoardProvenance: Codable, Hashable, Sendable {
    var providerObservedAt: String?
    var fetchedAt: String?
    var requestedOffsetsMinutes: [Int]?
    var searchWindowMinutes: Int?
    var complete: Bool?
    var failureReason: String?
}

nonisolated struct SiriDepartureProvenance: Codable, Hashable, Sendable {
    var providerObservedAt: String?
    var platformSource: String?
    var platformObservedAt: String?
    var requestedOffsetMinutes: Int?
}

nonisolated enum SiriLookupOutcome: String, Sendable {
    case live, partial, noDepartures, unavailable, invalidRoute, noTrackedTrain, needsSetup
}

nonisolated struct SiriLookupResult: Sendable, Equatable {
    let dialog: String
    let routeLabel: String
    let departures: [SiriDeparture]
    let freshnessLabel: String
    var outcome: SiriLookupOutcome = .live

    static func unavailable(routeLabel: String = "Train departures") -> Self {
        Self(dialog: "Live train information is unavailable right now. Please try again shortly.",
             routeLabel: routeLabel, departures: [], freshnessLabel: "Live information unavailable", outcome: .unavailable)
    }
}

nonisolated struct SiriDeparture: Sendable, Hashable {
    let id: String
    let originCRS: String
    let originName: String
    let destinationCRS: String
    let destinationName: String
    let serviceID: String
    let operatingDate: String?
    let scheduledDeparture: Date
    let expectedDeparture: Date?
    let platform: String?
    let statusLabel: String
    let transportLabel: String
    let freshnessLabel: String
    var timingUncertain: Bool = false
    var providerObservedAt: Date? = nil
    var backendSnapshotAt: Date? = nil
    var clientFetchedAt: Date? = nil
}

// Versioned service reference. The boarding date is a resolved calendar date, not
// a claimed railway operating date. Never include a nickname in persistent identity.
nonisolated struct SiriDepartureReference: Codable, Hashable, Sendable {
    let serviceID: String
    let originCRS: String
    let destinationCRS: String
    let scheduledDeparture: Date

    var id: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return "v1:" + data.base64EncodedString()
    }

    init(serviceID: String, originCRS: String, destinationCRS: String, scheduledDeparture: Date) {
        self.serviceID = serviceID
        self.originCRS = originCRS
        self.destinationCRS = destinationCRS
        self.scheduledDeparture = scheduledDeparture
    }

    init?(id: String) {
        guard id.count <= 2_048, id.hasPrefix("v1:"),
              let data = Data(base64Encoded: String(id.dropFirst(3))),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              !value.serviceID.isEmpty,
              value.originCRS != value.destinationCRS else { return nil }
        self = value
    }
}

nonisolated enum SiriDisplayTime {
    static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

nonisolated enum SiriRailTime {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London") ?? .gmt
        return calendar
    }

    static func parseISO(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func isFresh(_ date: Date?, now: Date, maximumAge: TimeInterval = 60) -> Bool {
        guard let date else { return false }
        let age = now.timeIntervalSince(date)
        return age >= -5 && age <= maximumAge
    }

    // Enumerate real wall-clock instants, including both occurrences of a repeated
    // autumn hour. Strict matching rejects the missing spring hour. Ambiguity is
    // returned to the caller instead of choosing a timezone offset silently.
    static func candidates(_ clock: String?, near reference: Date) -> [Date] {
        guard let clock else { return [] }
        let parts = clock.split(separator: ":")
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return [] }
        let cal = calendar
        let midnight = cal.startOfDay(for: reference)
        var dates = Set<Date>()
        for dayOffset in -1...1 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: midnight) else { continue }
            var components = cal.dateComponents([.year, .month, .day], from: day)
            components.hour = hour
            components.minute = minute
            components.second = 0
            for repeated: Calendar.RepeatedTimePolicy in [.first, .last] {
                if let date = cal.nextDate(after: day.addingTimeInterval(-1), matching: components,
                                           matchingPolicy: .strict, repeatedTimePolicy: repeated),
                   cal.isDate(date, inSameDayAs: day) {
                    dates.insert(date)
                }
            }
        }
        return dates.sorted()
    }

    static func uniqueDate(_ clock: String?, near reference: Date,
                           from lower: TimeInterval, through upper: TimeInterval) -> Date? {
        let dates = candidates(clock, near: reference).filter {
            let offset = $0.timeIntervalSince(reference)
            return offset >= lower && offset <= upper
        }
        return dates.count == 1 ? dates.first : nil
    }
}
