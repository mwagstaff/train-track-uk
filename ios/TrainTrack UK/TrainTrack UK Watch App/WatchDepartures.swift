import Foundation

nonisolated enum WatchRailTime {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func clock(_ value: String, near reference: Date) -> Date? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        guard let today = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: reference) else { return nil }
        return [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
            .min { abs($0.timeIntervalSince(reference)) < abs($1.timeIntervalSince(reference)) }
    }

    static func display(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

nonisolated struct WatchDeparture: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let departure: Date
    let arrival: Date?
    let scheduled: Date?
    let platform: String?
    let length: Int?
    let status: String
    let cancelled: Bool
    let changes: Int
    let legs: [Leg]
    let notice: String?

    nonisolated struct Leg: Codable, Equatable, Sendable {
        let title: String
        let departure: Date
        let arrival: Date
        let platform: String?
        let status: String?
    }

    var platformLabel: String {
        let value = platform?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "TBC" : value
    }
}

nonisolated struct WatchBoard: Codable, Sendable {
    let departures: [WatchDeparture]
    let checkedAt: Date
    let observedAt: Date?
    let dataStatus: String
    let pending: Bool
    let pollInterval: Double
    let message: String?

    func upcoming(at now: Date) -> [WatchDeparture] {
        departures.filter { $0.departure >= now.addingTimeInterval($0.status == "Delayed" ? -7200 : -60) }
            .sorted { $0.departure < $1.departure }
    }

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(observedAt ?? checkedAt) > 120 || ["stale", "unavailable"].contains(dataStatus)
    }
}

/// Decode only the fields needed on the wrist from the existing saved-route API.
nonisolated struct WatchBoardResponse: Decodable {
    let apiVersion: Int
    let boards: [Board]

    nonisolated struct Board: Decodable {
        let id: String
        let status: String
        let pollAfterMs: Double?
        let source: String?
        let direct: Direct?
        let result: Result?
        let error: Failure?

        func presentation(at now: Date) throws -> WatchBoard {
            let pending = ["queued", "refreshing"].contains(status)
            guard direct != nil || result != nil || pending || error != nil else { throw URLError(.cannotParseResponse) }
            let services: [WatchDeparture]
            if let direct, source == "direct" {
                services = direct.departures.compactMap { $0.presentation(near: WatchRailTime.parse(direct.lastSuccessfulUpdate) ?? now) }
            } else {
                services = try ((result?.journeys ?? []) + (result?.disruptedJourneys ?? [])).map { try $0.presentation() }
            }
            var seen = Set<String>()
            return WatchBoard(departures: services.filter { seen.insert($0.id).inserted }, checkedAt: now,
                observedAt: WatchRailTime.parse(direct?.lastSuccessfulUpdate ?? result?.live?.updatedAt),
                dataStatus: direct?.dataStatus ?? result?.live?.status ?? "scheduled",
                pending: pending, pollInterval: max(5, min(60, (pollAfterMs ?? 20000) / 1000)), message: error?.message)
        }
    }
    nonisolated struct Failure: Decodable { let message: String }
    nonisolated struct Direct: Decodable {
        let departures: [DirectDeparture]
        let dataStatus: String?
        let lastSuccessfulUpdate: String?
        enum CodingKeys: String, CodingKey {
            case departures, dataStatus = "data_status", lastSuccessfulUpdate = "last_successful_update"
            case camelDataStatus = "dataStatus", camelLastSuccessfulUpdate = "lastSuccessfulUpdate"
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            departures = try container.decode([DirectDeparture].self, forKey: .departures)
            dataStatus = try container.decodeIfPresent(String.self, forKey: .dataStatus)
                ?? container.decodeIfPresent(String.self, forKey: .camelDataStatus)
            lastSuccessfulUpdate = try container.decodeIfPresent(String.self, forKey: .lastSuccessfulUpdate)
                ?? container.decodeIfPresent(String.self, forKey: .camelLastSuccessfulUpdate)
        }
    }
    nonisolated struct DirectDeparture: Decodable {
        let serviceID: String
        let departureTime: Times
        let platform: String?
        let length: Int?
        let isCancelled: Bool?
        let delayReason: String?
        let cancelReason: String?
        let timestamp: String?
        enum CodingKeys: String, CodingKey {
            case serviceID, platform, length, isCancelled, delayReason, cancelReason, timestamp
            case departureTime = "departure_time"
        }
        nonisolated struct Times: Decodable { let scheduled: String; let estimated: String; let actual: String? }

        func presentation(near reference: Date) -> WatchDeparture? {
            guard departureTime.actual?.isEmpty != false else { return nil }
            let reference = WatchRailTime.parse(timestamp) ?? reference
            let cancelled = isCancelled == true || departureTime.estimated.lowercased() == "cancelled"
            let scheduled = WatchRailTime.clock(departureTime.scheduled, near: reference)
            let expected = WatchRailTime.clock(departureTime.estimated, near: scheduled ?? reference)
            guard let time = cancelled ? scheduled : expected ?? scheduled else { return nil }
            let status: String
            if cancelled { status = "Cancelled" }
            else if departureTime.estimated.lowercased() == "delayed" { status = "Delayed" }
            else if let scheduled, let expected, expected.timeIntervalSince(scheduled) >= 60 {
                status = "\(Int(expected.timeIntervalSince(scheduled) / 60)) min late"
            } else if departureTime.estimated.lowercased() == "on time" || expected != nil { status = "On time" }
            else { status = "Scheduled" }
            return WatchDeparture(id: serviceID, departure: time, arrival: nil, scheduled: scheduled,
                platform: platform, length: length, status: status, cancelled: cancelled,
                changes: 0, legs: [], notice: cancelled ? cancelReason : delayReason)
        }
    }
    nonisolated struct Result: Decodable {
        let journeys: [Planned]
        let disruptedJourneys: [Planned]?
        let live: Live?
    }
    nonisolated struct Live: Decodable {
        let status: String?
        let updatedAt: String?
        let platform: String?
        let length: Int?
        let cancelled: Bool?
        let partCancelled: Bool?
        let departureDelayMinutes: Double?
    }
    nonisolated struct Planned: Decodable {
        let id: String
        let departure: String
        let arrival: String
        let scheduledDeparture: String?
        let changes: Int
        let legs: [Leg]
        let warnings: [String]?
        nonisolated struct Leg: Decodable {
            let kind: String
            let mode: String
            let from: WatchStation
            let to: WatchStation
            let departure: String
            let arrival: String
            let live: Live?
        }
        func presentation() throws -> WatchDeparture {
            guard let departure = WatchRailTime.parse(departure), let arrival = WatchRailTime.parse(arrival) else {
                throw URLError(.cannotParseResponse)
            }
            let cancelled = legs.contains { $0.live?.cancelled ?? ($0.live?.status == "cancelled") }
            let delayed = legs.contains { ($0.live?.departureDelayMinutes ?? 0) > 0 || $0.live?.status == "delayed" }
            let partial = legs.contains { $0.live?.partCancelled == true || $0.live?.status == "partCancelled" }
            let vehicles = legs.filter { $0.kind == "vehicle" }
            let onTime = !vehicles.isEmpty && vehicles.allSatisfy { $0.live?.status == "onTime" }
            let status = cancelled ? "Cancelled" : partial ? "Part cancelled" : delayed ? "Delayed" : onTime ? "On time" : "Scheduled"
            let details = try legs.map { leg -> WatchDeparture.Leg in
                guard let start = WatchRailTime.parse(leg.departure), let end = WatchRailTime.parse(leg.arrival) else {
                    throw URLError(.cannotParseResponse)
                }
                let mode = leg.kind == "vehicle" ? (leg.mode == "replacementBus" ? "Bus" : "Train")
                    : leg.mode == "walk" ? "Walk" : "Transfer"
                return .init(title: "\(mode): \(leg.from.name) → \(leg.to.name)", departure: start, arrival: end,
                             platform: leg.live?.platform, status: (leg.live?.cancelled ?? (leg.live?.status == "cancelled")) ? "Cancelled" : nil)
            }
            let first = legs.first?.kind == "vehicle" ? legs.first?.live : nil
            return WatchDeparture(id: id, departure: departure, arrival: arrival,
                scheduled: WatchRailTime.parse(scheduledDeparture), platform: first?.platform, length: first?.length,
                status: status, cancelled: cancelled, changes: changes, legs: details,
                notice: warnings?.joined(separator: "\n"))
        }
    }
}
