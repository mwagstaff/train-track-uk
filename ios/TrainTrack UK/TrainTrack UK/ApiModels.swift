import Foundation
import SwiftUI

// MARK: - V2 Departures Models
struct DepartureTimeV2: Codable, Hashable {
    let scheduled: String
    let estimated: String

    enum CodingKeys: String, CodingKey {
        case scheduled
        case estimated
    }
}

struct PlaceInfoV2: Codable, Hashable {
    let crs: String?
    let locationName: String
    let via: String?
}

struct DepartureV2: Codable, Identifiable, Hashable {
    let departureTime: DepartureTimeV2
    let serviceType: String
    let platform: String?
    let isCancelled: Bool
    let length: Int?
    let destination: [PlaceInfoV2]
    let origin: [PlaceInfoV2]?
    let serviceID: String
    let delayReason: String?
    let cancelReason: String?
    let timestamp: Date?

    var id: String { serviceID }

    enum CodingKeys: String, CodingKey {
        case departureTime = "departure_time"
        case serviceType, platform, isCancelled, length
        case destination, origin
        case serviceID, delayReason, cancelReason, timestamp
    }

    init(
        departureTime: DepartureTimeV2,
        serviceType: String,
        platform: String?,
        isCancelled: Bool,
        length: Int?,
        destination: [PlaceInfoV2],
        origin: [PlaceInfoV2]?,
        serviceID: String,
        delayReason: String?,
        cancelReason: String?,
        timestamp: Date?
    ) {
        self.departureTime = departureTime
        self.serviceType = serviceType
        self.platform = platform
        self.isCancelled = isCancelled
        self.length = length
        self.destination = destination
        self.origin = origin
        self.serviceID = serviceID
        self.delayReason = delayReason
        self.cancelReason = cancelReason
        self.timestamp = timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.departureTime = try c.decode(DepartureTimeV2.self, forKey: .departureTime)
        self.serviceType = (try? c.decode(String.self, forKey: .serviceType)) ?? ""
        self.platform = try? c.decode(String.self, forKey: .platform)
        self.isCancelled = (try? c.decode(Bool.self, forKey: .isCancelled)) ?? false
        self.length = try? c.decode(Int.self, forKey: .length)

        if let destArr = try? c.decode([PlaceInfoV2].self, forKey: .destination) {
            self.destination = destArr
        } else if let destOne = try? c.decode(PlaceInfoV2.self, forKey: .destination) {
            self.destination = [destOne]
        } else {
            self.destination = []
        }

        if c.contains(.origin) {
            if let orgArr = try? c.decode([PlaceInfoV2].self, forKey: .origin) {
                self.origin = orgArr
            } else if let orgOne = try? c.decode(PlaceInfoV2.self, forKey: .origin) {
                self.origin = [orgOne]
            } else {
                self.origin = nil
            }
        } else {
            self.origin = nil
        }

        self.serviceID = (try? c.decode(String.self, forKey: .serviceID)) ?? UUID().uuidString
        self.delayReason = try? c.decode(String.self, forKey: .delayReason)
        self.cancelReason = try? c.decode(String.self, forKey: .cancelReason)
        self.timestamp = try? c.decode(Date.self, forKey: .timestamp)
    }

    func withPlatform(_ platform: String?) -> DepartureV2 {
        DepartureV2(
            departureTime: departureTime,
            serviceType: serviceType,
            platform: platform,
            isCancelled: isCancelled,
            length: length,
            destination: destination,
            origin: origin,
            serviceID: serviceID,
            delayReason: delayReason,
            cancelReason: cancelReason,
            timestamp: timestamp
        )
    }
}

enum JourneyDataStatus: String, Codable, Hashable {
    case live
    case partial
    case stale
    case unavailable

    var severity: Int {
        switch self {
        case .live: return 0
        case .partial: return 1
        case .stale: return 2
        case .unavailable: return 3
        }
    }
}

struct JourneyDeparturesSnapshot: Decodable, Hashable {
    let departures: [DepartureV2]
    let dataStatus: JourneyDataStatus
    let lastSuccessfulUpdate: Date?

    enum CodingKeys: String, CodingKey {
        case departures
        case dataStatus = "data_status"
        case lastSuccessfulUpdate = "last_successful_update"
    }

    init(
        departures: [DepartureV2],
        dataStatus: JourneyDataStatus,
        lastSuccessfulUpdate: Date?
    ) {
        self.departures = departures
        self.dataStatus = dataStatus
        self.lastSuccessfulUpdate = lastSuccessfulUpdate
    }

    init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let legacyDepartures = try? singleValue.decode([DepartureV2].self) {
            departures = legacyDepartures
            dataStatus = .live
            lastSuccessfulUpdate = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        departures = try container.decode([DepartureV2].self, forKey: .departures)
        dataStatus = try container.decode(JourneyDataStatus.self, forKey: .dataStatus)
        if let value = try container.decodeIfPresent(String.self, forKey: .lastSuccessfulUpdate) {
            lastSuccessfulUpdate = Self.parseISO8601Date(value)
        } else {
            lastSuccessfulUpdate = nil
        }
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}

struct RecentDepartureV2: Codable, Identifiable, Hashable {
    let serviceID: String
    let serviceType: String
    let fromCRS: String
    let toCRS: String
    let scheduledDeparture: String
    let estimatedDeparture: String?
    let actualDeparture: String?
    let scheduledDepartureAt: Date
    let estimatedDepartureAt: Date?
    let actualDepartureAt: Date?
    let platform: String?
    let isCancelled: Bool
    let lastObservedAt: Date

    var id: String {
        "\(fromCRS.uppercased()):\(toCRS.uppercased()):\(serviceID):\(scheduledDepartureAt.timeIntervalSince1970)"
    }
}

struct JourneyDataAvailability: Hashable {
    let status: JourneyDataStatus
    let lastSuccessfulUpdate: Date?

    static let live = JourneyDataAvailability(status: .live, lastSuccessfulUpdate: nil)
}

// MARK: - Independent train-loading service
struct CoachLoadingV1: Codable, Identifiable, Hashable {
    let number: String
    let position: Int
    let percentage: Int?
    let band: String?
    let coachClass: String?

    var id: String { "\(position)-\(number)" }
}

struct SplitLocationV1: Codable, Hashable {
    let crs: String
    let locationName: String
}

struct SplitGuidanceV1: Codable, Hashable {
    let splitAt: SplitLocationV1
    let destinationCRS: String
    let position: String
    let coachCount: Int
    let confidence: String
}

struct ServiceLoadingV1: Codable, Hashable {
    let serviceID: String?
    let status: String
    let rid: String?
    let formationId: String?
    let observedAt: String?
    let ageSeconds: Int?
    let coaches: [CoachLoadingV1]?
    let splitGuidance: SplitGuidanceV1?
    let reason: String?
    let error: String?

    var freshCoaches: [CoachLoadingV1]? {
        guard status == "available", let coaches, coaches.contains(where: { $0.percentage != nil }) else {
            return nil
        }
        return coaches
    }
}

struct LoadingDetailsRequestV1: Encodable, Hashable {
    let serviceID: String
    let from: String
    let to: String
    let scheduledDeparture: String
    let destinationCRS: String?
    let length: Int?
}

struct LoadingDetailsBatchRequestV1: Encodable {
    let services: [LoadingDetailsRequestV1]
}

struct LoadingDetailsBatchResponseV1: Decodable {
    let services: [String: ServiceLoadingV1]
}

enum CarriageLoadingBand: Equatable {
    case green
    case amber
    case red
    case unknown

    static func value(for percentage: Int?) -> CarriageLoadingBand {
        guard let percentage else { return .unknown }
        if percentage <= 33 { return .green }
        if percentage <= 66 { return .amber }
        return .red
    }

    var accessibilityDescription: String {
        switch self {
        case .green: return "low loading"
        case .amber: return "moderate loading"
        case .red: return "high loading"
        case .unknown: return "loading unknown"
        }
    }
}

// MARK: - Service Details (shared shape with Watch)
struct CallingPoint: Codable, Identifiable, Equatable {
    let locationName: String
    let crs: String
    let st: String // scheduled time
    let et: String? // estimated time
    let at: String? // actual time
    let isCancelled: Bool?
    let cancelReason: String?
    let platform: String?
    let length: Int?
    let detachFront: Bool?
    let affectedByDiversion: Bool?
    let rerouteDelay: Int?

    var id: String { crs }

    var displayTime: String {
        if let at = at {
            return at == "On time" ? st : at
        }
        if let et = et {
            return et == "On time" ? st : et
        }
        return st
    }

    var isDelayed: Bool {
        guard let et = et, et != "On time", et != "Cancelled" else { return false }
        return et != st
    }

    var isCancelledAtStation: Bool {
        return isCancelled == true || at == "Cancelled" || et == "Cancelled"
    }

    var delayMinutes: Int {
        guard let et = et, et != "On time", et != "Cancelled",
              let scheduledTime = timeFromString(st),
              let estimatedTime = timeFromString(et) else { return 0 }

        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute], from: scheduledTime, to: estimatedTime)
        return max(0, components.minute ?? 0)
    }

    private func timeFromString(_ timeString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.date(from: timeString)
    }
}

struct CallingPointList: Codable, Equatable {
    let callingPoint: [CallingPoint]
    let serviceType: String?
    let serviceChangeRequired: Bool?
    let assocIsCancelled: Bool?
}

struct ServiceDetails: Codable, Equatable {
    let previousCallingPoints: [CallingPointList]?
    let subsequentCallingPoints: [CallingPointList]?
    let generatedAt: String
    let serviceType: String
    let locationName: String
    let crs: String
    let `operator`: String?
    let operatorCode: String?
    let isCancelled: Bool?
    let length: Int?
    let detachFront: Bool?
    let isReverseFormation: Bool?
    let platform: String?
    let sta: String? // scheduled arrival
    let eta: String? // estimated arrival
    let ata: String? // actual arrival
    let std: String? // scheduled departure
    let etd: String? // estimated departure
    let atd: String? // actual departure
    let delayReason: String?
    let cancelReason: String?

    var stationBranches: [[CallingPoint]] {
        let previousStations = previousCallingPoints?.first?.callingPoint ?? []
        let followingBranches = subsequentCallingPoints?
            .map(\.callingPoint)
            .filter { !$0.isEmpty } ?? []
        let currentIsFinalStation = followingBranches.isEmpty
        let currentStation = CallingPoint(
            locationName: locationName,
            crs: crs,
            st: currentIsFinalStation ? (sta ?? std ?? "Unknown") : (std ?? sta ?? "Unknown"),
            et: currentIsFinalStation ? eta : etd,
            at: currentIsFinalStation ? (ata ?? atd) : (atd ?? ata),
            isCancelled: isCancelled,
            cancelReason: cancelReason,
            platform: platform,
            length: length,
            detachFront: detachFront,
            affectedByDiversion: false,
            rerouteDelay: 0
        )
        let sharedStations = previousStations + [currentStation]
        guard !followingBranches.isEmpty else {
            return [sharedStations]
        }
        return followingBranches.map { sharedStations + $0 }
    }

    var allStations: [CallingPoint] {
        stationBranches.first ?? []
    }
}
