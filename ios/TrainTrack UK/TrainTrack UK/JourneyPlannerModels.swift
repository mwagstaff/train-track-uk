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
        let transfer: Transfer?
        let warnings: [String]?
    }

    struct Place: Codable, Equatable {
        let crs: String
        let name: String
    }

    struct CallingPoint: Codable, Equatable {
        let station: Place
        let arrival: Date?
        let departure: Date?
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

    struct Search: Decodable {
        let origin: String
        let destination: String
        let time: Date
        let timeType: String
        let window: Window
        let searchTruncated: Bool
        var maxChanges: Int? = nil
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
            time: PlannerTime.iso8601(time), timeType: timeMode.apiValue
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
