import Foundation

struct DisruptionTimeWindow: Codable, Equatable {
    var start = "00:00"
    var end = "24:00"

    var isAllDay: Bool { start == "00:00" && end == "24:00" }
}

struct DisruptionMonitorSettings: Codable, Equatable {
    var enabled = true
    var days = Array(1...7)
    var window = DisruptionTimeWindow()
    var dayWindows: [String: DisruptionTimeWindow]? = nil
    var travelDate: String? = nil
    var pushEnabled = false

    func window(on day: Int) -> DisruptionTimeWindow {
        dayWindows?[String(day)] ?? window
    }

    /// Only seed from an unambiguous schedule for this complete direction. A schedule
    /// for a different connection or the return leg must not narrow this route's coverage.
    static func seeded(for group: JourneyGroup, subscriptions: [NotificationSubscription]) -> Self {
        let route = group.stationSequence.map { $0.crs.uppercased() }
        let matches: [(NotificationSubscription, NotificationLeg)] = subscriptions.compactMap { subscription in
            guard subscription.source != .liveSession else { return nil }
            let legs = subscription.legs
            guard legs.count >= route.count - 1 else { return nil }
            for index in 0...(legs.count - (route.count - 1)) {
                let slice = Array(legs[index..<(index + route.count - 1)])
                guard slice.allSatisfy(\.enabled),
                      zip(slice, zip(route, route.dropFirst())).allSatisfy({ leg, stations in
                          leg.from.uppercased() == stations.0 && leg.to.uppercased() == stations.1
                      }), let first = slice.first else { continue }
                return (subscription, first)
            }
            return nil
        }
        guard matches.count == 1, let (subscription, leg) = matches.first else { return Self() }
        var result = Self()
        result.window = DisruptionTimeWindow(start: leg.windowStart, end: leg.windowEnd)
        if subscription.scheduleKind == .oneOff {
            guard let date = leg.travelDate, date >= DisruptionDate.travelDate(Date()) else { return Self() }
            result.travelDate = date
        } else {
            guard !subscription.daysOfWeek.isEmpty else { return Self() }
            result.days = subscription.daysOfWeek.compactMap { day in
                DayOfWeek.allCases.firstIndex(of: day).map { $0 + 1 }
            }.sorted()
            if let windows = leg.dayWindows, !windows.isEmpty {
                result.dayWindows = Dictionary(uniqueKeysWithValues: windows.compactMap { key, value in
                    guard let day = DayOfWeek(rawValue: key),
                          let index = DayOfWeek.allCases.firstIndex(of: day) else { return nil }
                    return (String(index + 1), DisruptionTimeWindow(start: value.windowStart, end: value.windowEnd))
                })
            }
        }
        return result
    }
}

struct DisruptionMonitorRegistration: Encodable, Equatable {
    let id: String
    let stations: [String]
    let name: String
    let enabled: Bool
    let days: [Int]
    let windowStart: String
    let windowEnd: String
    let dayWindows: [String: DisruptionTimeWindow]?
    let travelDate: String?
    let pushEnabled: Bool

    init(group: JourneyGroup, settings: DisruptionMonitorSettings, pushAuthorized: Bool) {
        id = group.id.uuidString
        stations = group.stationSequence.map { $0.crs.uppercased() }
        name = String(group.displayTitle.prefix(200))
        enabled = settings.enabled
        days = settings.days.isEmpty ? Array(1...7) : settings.days.sorted()
        // Disabled monitors still need a valid wire schedule. Per-day overrides can
        // also make an unfinished common-hours draft irrelevant to actual coverage.
        let common = !settings.enabled || (settings.dayWindows != nil && settings.window.start == settings.window.end)
            ? DisruptionTimeWindow() : settings.window
        windowStart = common.start
        windowEnd = common.end
        dayWindows = settings.enabled ? settings.dayWindows?.filter { key, _ in
            settings.days.contains(Int(key) ?? 0)
        } : nil
        travelDate = settings.travelDate
        pushEnabled = settings.pushEnabled && pushAuthorized
    }

    enum CodingKeys: String, CodingKey {
        case id, stations, name, enabled, days
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case dayWindows = "day_windows"
        case travelDate = "travel_date"
        case pushEnabled = "push_enabled"
    }
}

struct DisruptionMonitorSnapshot: Encodable {
    let deviceID: String
    let monitors: [DisruptionMonitorRegistration]
    let pushToken: String?
    let useSandbox: Bool

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case monitors
        case pushToken = "push_token"
        case useSandbox = "use_sandbox"
    }
}

struct DisruptionMonitorStatus: Codable, Identifiable {
    let id: String
    let status: String
    let lastCheckedAt: Date?
    let reason: String?

    func isStale(now: Date = Date()) -> Bool {
        guard let lastCheckedAt else { return false }
        return now.timeIntervalSince(lastCheckedAt) > 18 * 60 * 60
    }

    var explanation: String? {
        guard let reason, !reason.isEmpty else { return nil }
        switch reason {
        case "timetable_stale", "ingestion_check_stale":
            return "Waiting for an up-to-date published timetable."
        case "timetable_update_gap":
            return "Some timetable updates are missing, so upcoming journeys cannot yet be verified."
        case "ingestion_in_progress":
            return "Timetable updates are being applied."
        case "publication_unknown", "timetable_not_validated", "timetable_version_mismatch":
            return "The published timetable cannot yet be verified."
        case "timetable_unavailable", "ingestion_unavailable", "invalid_readiness_policy":
            return "Timetable checks are temporarily unavailable."
        default:
            return reason.contains("_") ? "Some journey times could not be verified." : reason
        }
    }
}

struct DisruptionAffectedWindow: Codable, Hashable {
    let startAt: Date
    let endAt: Date
}

struct DisruptionAdvisory: Codable, Identifiable {
    let id: String
    let monitorId: String
    let kind: String
    let title: String
    let body: String
    let startAt: Date
    let endAt: Date
    let sourceURL: URL?
    let confidence: String
    let checkedAt: Date
    let extraMinutes: Double?
    var affectedWindows: [DisruptionAffectedWindow]? = nil

    var affectedPeriods: [DisruptionAffectedWindow] {
        guard let affectedWindows, !affectedWindows.isEmpty else {
            return [DisruptionAffectedWindow(startAt: startAt, endAt: endAt)]
        }
        return affectedWindows.sorted { $0.startAt < $1.startAt }
    }

    func nextAffectedPeriod(at now: Date = Date()) -> DisruptionAffectedWindow? {
        affectedPeriods.first { $0.endAt > now }
    }

    var safeSourceURL: URL? {
        guard let sourceURL, ["https", "http"].contains(sourceURL.scheme?.lowercased() ?? "") else { return nil }
        return sourceURL
    }
}

struct DisruptionMonitoringResponse: Codable {
    let mode: String
    let horizonDays: Int
    let monitors: [DisruptionMonitorStatus]
    let advisories: [DisruptionAdvisory]

    func visibleAdvisories(for id: UUID, now: Date = Date()) -> [DisruptionAdvisory] {
        guard mode == "active" else { return [] }
        return advisories.filter { UUID(uuidString: $0.monitorId) == id && $0.endAt > now }
            .sorted { $0.startAt < $1.startAt }
    }
}

enum DisruptionDate {
    static func travelDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid disruption date")
        }
        return decoder
    }
}
