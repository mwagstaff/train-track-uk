import Foundation

struct PlannerStation: Codable, Hashable, Identifiable {
    let crs: String
    let name: String
    var aliases: [String] = []
    var latitude: Double?
    var longitude: Double?
    var id: String { crs }
}

struct PlannerDataset: Codable, Equatable {
    let version: String
    let sourceGenerationDate: String
    let importedAt: Date
    let coverage: Coverage
    let freshness: String
    let scheduledOnly: Bool
    var warnings: [String]? = nil

    struct Coverage: Codable, Equatable {
        let from: String
        let to: String

        var dateRange: ClosedRange<Date>? {
            guard let first = PlannerTime.dateOnly(from),
                  let last = PlannerTime.dateOnly(to),
                  let end = PlannerTime.calendar.date(byAdding: .day, value: 1, to: last),
                  first < end else { return nil }
            return first...end.addingTimeInterval(-1)
        }
    }
}

struct PlannerStatus: Decodable {
    let available: Bool
    let apiVersion: Int
    let capabilities: Capabilities
    let dataset: PlannerDataset?
    let reason: String?

    struct Capabilities: Decodable {
        let timeTypes: [String]
        let maxChanges: Int
    }
}

struct PlannedJourney: Codable, Identifiable, Equatable {
    let id: String
    let departure: Date
    let arrival: Date
    let durationMinutes: Double
    let changes: Int
    let legs: [Leg]
    var scheduledDeparture: Date? = nil
    var scheduledArrival: Date? = nil
    var warnings: [String]? = nil

    struct Leg: Codable, Equatable {
        let kind: String
        let mode: String
        let from: Place
        let to: Place
        let departure: Date
        let arrival: Date
        let `operator`: String?
        let serviceId: String?
        let originDate: String?
        let callingPoints: [CallingPoint]?
        var serviceCallingPoints: [CallingPoint]? = nil
        let transfer: Transfer?
        let warnings: [String]?
        var scheduledDeparture: Date? = nil
        var scheduledArrival: Date? = nil
        var scheduledServiceId: String? = nil
        var live: PlannerLiveAnnotation? = nil

        var isTubeTransfer: Bool { mode == "tubeTransfer" || mode == "tube" }
        var isTrainChange: Bool { kind == "transfer" && mode == "interchange" }

        var heading: String {
            if isTrainChange { return "Change trains at \(from.name)" }
            let transport: String
            if isTubeTransfer { transport = "Tube" }
            else if mode == "walk" { transport = "Walk" }
            else if mode == "replacementBus" { transport = "Replacement bus" }
            else if mode == "bus" { transport = "Bus" }
            else if kind == "vehicle" { transport = "Train" }
            else { transport = "Transfer" }
            return "\(transport) from \(from.name) to \(to.name)"
        }

        var mapCallingPoints: [CallingPoint] {
            let points = callingPoints ?? []
            let start = points.firstIndex { $0.station.crs == from.crs }
            let end = points.lastIndex { $0.station.crs == to.crs }
            if let start, let end, start <= end { return Array(points[start...end]) }
            return [CallingPoint(station: from, arrival: nil, departure: departure)]
                + points.filter { $0.station.crs != from.crs && $0.station.crs != to.crs }
                + [CallingPoint(station: to, arrival: arrival, departure: nil)]
        }
    }

    struct Place: Codable, Equatable {
        let crs: String
        let name: String
    }

    struct CallingPoint: Codable, Equatable {
        let station: Place
        let arrival: Date?
        let departure: Date?
        var scheduledArrival: Date? = nil
        var scheduledDeparture: Date? = nil
        var live: PlannerLiveAnnotation? = nil
    }

    struct Transfer: Codable, Equatable {
        let exitMinutes: Double?
        let travelMinutes: Double?
        let entryMinutes: Double?
        let extraMinutes: Double?
        let interchangeMinutes: Double?
        let waitingMinutes: Double?
    }
}

struct PlannerSearchResponse: Decodable {
    let journeys: [PlannedJourney]
    let dataset: PlannerDataset
    let search: Search
    let warnings: [String]
    let pagination: Pagination
    var live: PlannerLiveContext? = nil
    var disruptedJourneys: [PlannedJourney]? = nil

    struct Search: Decodable {
        let origin: String
        let destination: String
        let time: Date
        let timeType: String
        let window: Window
        let searchTruncated: Bool
        var maxChanges: Int? = nil
        var realtime: String? = nil
    }

    struct Window: Decodable {
        let from: Date
        let to: Date
    }

    struct Pagination: Decodable {
        let earlier: String?
        let later: String?
        let more: String?
    }
}

struct PlannerLiveContext: Codable, Equatable {
    let mode: String
    let status: String
    var updatedAt: Date? = nil
    var expiresAt: Date? = nil
    var windowHours: Int? = nil
    var warnings: [String]? = nil
}

struct PlannerLiveAnnotation: Codable, Equatable {
    let status: String
    var updatedAt: Date? = nil
    var departure: Date? = nil
    var arrival: Date? = nil
    var departureDelayMinutes: Double? = nil
    var arrivalDelayMinutes: Double? = nil
    var cancelled: Bool? = nil
    var partCancelled: Bool? = nil
    var warnings: [String]? = nil

    // Cancellation elsewhere on a splitting train must not cancel the selected section.
    var isCancelled: Bool { cancelled ?? (status == "cancelled") }
    var isDelayed: Bool {
        status == "delayed" || (departureDelayMinutes ?? 0) > 0 || (arrivalDelayMinutes ?? 0) > 0
    }
}

enum PlannerSearchProgress: Equatable {
    case queued(position: Int?)
    case running

    var title: String {
        switch self {
        case .queued: "Waiting to search…"
        case .running: "Finding journeys…"
        }
    }
}

struct PlannerSearchJob: Decodable {
    enum Status: String, Decodable { case queued, running, completed, failed, cancelled }
    let id: String
    let status: Status
    let queuePosition: Int?
    let pollAfterMs: Double?
    let result: PlannerSearchResponse?
    let error: PlannerError?
}

struct PlannerJourneyResponse: Decodable {
    let journey: PlannedJourney
    let dataset: PlannerDataset
    var live: PlannerLiveContext? = nil
}

struct PlannerSearchRequest: Encodable, Equatable {
    let origin: String
    let destination: String
    let time: String
    let timeType: String
    var maxChanges: Int? = nil
    var extraConnectionMinutes = 0
    var allowedModes = ["rail", "replacementBus", "walk", "tubeTransfer"]
    var limit = 5
    var cursor: String?
    var realtime: String? = nil
}

enum PlannerTimeMode: String, Codable, CaseIterable, Identifiable {
    case now, departAt, arriveBy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .now: "Depart now"
        case .departAt: "Depart at"
        case .arriveBy: "Arrive by"
        }
    }
    var apiValue: String { self == .arriveBy ? "arriveBy" : "departAfter" }
}

struct PlannerSearchIntent: Codable, Equatable {
    let origin: PlannerStation
    let destination: PlannerStation
    let timeMode: PlannerTimeMode
    let explicitTime: Date?
    var realtime: String? = nil

    func request(now: Date) throws -> PlannerSearchRequest {
        let time: Date
        if timeMode == .now {
            time = now
        } else {
            guard let explicitTime, explicitTime >= now else {
                throw PlannerError(code: "PAST_TIME", message: "Choose a new date and time, or switch to Depart now.")
            }
            time = explicitTime
        }
        return PlannerSearchRequest(
            origin: origin.crs, destination: destination.crs,
            time: PlannerTime.iso8601(time), timeType: timeMode.apiValue, realtime: realtime ?? "apply"
        )
    }

    func matches(_ other: Self) -> Bool {
        origin.crs == other.origin.crs && destination.crs == other.destination.crs
            && timeMode == other.timeMode
            && (timeMode == .now || explicitTime == other.explicitTime)
    }
}

struct PlannerRecentSearch: Codable, Identifiable {
    let id: UUID
    let intent: PlannerSearchIntent
    let searchedAt: Date
}

enum PlannerTime {
    static let zone = TimeZone(identifier: "Europe/London")!
    static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = zone
        return value
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    static func dateOnly(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: text)
    }

    static func display(_ date: Date, includeDate: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = zone
        formatter.dateFormat = includeDate ? "EEE d MMM, HH:mm" : "HH:mm"
        return formatter.string(from: date)
    }

    static func minutes(_ value: Double) -> String {
        let total = Int(value.rounded(.up))
        return total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total) min"
    }

    static func displayRange(from departure: Date, to arrival: Date, separator: String = " → ") -> String {
        let includeDate = !calendar.isDate(departure, inSameDayAs: arrival)
        return display(departure, includeDate: includeDate) + separator + display(arrival, includeDate: includeDate)
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
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an offset-aware timetable timestamp")
            }
            return date
        }
        return decoder
    }
}
