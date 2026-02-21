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
    let ata: String? // actual arrival
    let std: String? // scheduled departure
    let etd: String? // estimated departure
    let atd: String? // actual departure
    let delayReason: String?
    let cancelReason: String?

    var allStations: [CallingPoint] {
        var stations: [CallingPoint] = []

        if let previous = previousCallingPoints {
            for list in previous { stations.append(contentsOf: list.callingPoint) }
        }

        let currentStation = CallingPoint(
            locationName: locationName,
            crs: crs,
            st: std ?? sta ?? "Unknown",
            et: etd,
            at: atd ?? ata,
            isCancelled: isCancelled,
            cancelReason: cancelReason,
            length: length,
            detachFront: detachFront,
            affectedByDiversion: false,
            rerouteDelay: 0
        )
        stations.append(currentStation)

        if let subsequent = subsequentCallingPoints {
            for list in subsequent { stations.append(contentsOf: list.callingPoint) }
        }

        return stations
    }
}
