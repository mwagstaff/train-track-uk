import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// JourneyActivityAttributes with built-in ActivityKit conformance
// This ensures proper type registration with the ActivityKit runtime
public struct JourneyActivityAttributes: Codable, Hashable {
    public struct UpcomingDeparture: Codable, Hashable {
        public var time: String
        public var delayMinutes: Int
        public var isCancelled: Bool
        public var platform: String?
        public var hasFasterLaterService: Bool

        public init(time: String, delayMinutes: Int, isCancelled: Bool, platform: String? = nil, hasFasterLaterService: Bool = false) {
            self.time = time
            self.delayMinutes = delayMinutes
            self.isCancelled = isCancelled
            self.platform = platform
            self.hasFasterLaterService = hasFasterLaterService
        }

        private enum CodingKeys: String, CodingKey {
            case time, delayMinutes, isCancelled, platform, hasFasterLaterService
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            time = try container.decode(String.self, forKey: .time)
            delayMinutes = try container.decode(Int.self, forKey: .delayMinutes)
            isCancelled = try container.decode(Bool.self, forKey: .isCancelled)
            platform = try container.decodeIfPresent(String.self, forKey: .platform)
            hasFasterLaterService = try container.decodeIfPresent(Bool.self, forKey: .hasFasterLaterService) ?? false
        }
    }

    public struct ContentState: Codable, Hashable {
        public var fromCRS: String
        public var toCRS: String
        public var destinationTitle: String
        public var arrivalLabel: String?
        public var length: Int?
        public var platform: String
        public var estimated: String
        public var statusText: String?
        public var delayMinutes: Int
        public var upcomingDepartures: [UpcomingDeparture]
        public var lastUpdated: Date
        public var activityID: String?
        public var revision: Int?

        public init(
            fromCRS: String,
            toCRS: String,
            destinationTitle: String,
            arrivalLabel: String?,
            length: Int?,
            platform: String,
            estimated: String,
            statusText: String?,
            delayMinutes: Int,
            upcomingDepartures: [UpcomingDeparture] = [],
            lastUpdated: Date = Date(),
            activityID: String? = nil,
            revision: Int? = nil
        ) {
            self.fromCRS = fromCRS
            self.toCRS = toCRS
            self.destinationTitle = destinationTitle
            self.arrivalLabel = arrivalLabel
            self.length = length
            self.platform = platform
            self.estimated = estimated
            self.statusText = statusText
            self.delayMinutes = delayMinutes
            self.upcomingDepartures = upcomingDepartures
            self.lastUpdated = lastUpdated
            self.activityID = activityID
            self.revision = revision
        }

        private enum CodingKeys: String, CodingKey {
            case fromCRS, toCRS, destinationTitle, arrivalLabel, length, platform, estimated, statusText, delayMinutes, upcomingDepartures, lastUpdated, activityID, revision
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fromCRS = try container.decode(String.self, forKey: .fromCRS)
            toCRS = try container.decode(String.self, forKey: .toCRS)
            destinationTitle = try container.decode(String.self, forKey: .destinationTitle)
            arrivalLabel = try container.decodeIfPresent(String.self, forKey: .arrivalLabel)
            length = try container.decodeIfPresent(Int.self, forKey: .length)
            platform = try container.decode(String.self, forKey: .platform)
            estimated = try container.decode(String.self, forKey: .estimated)
            statusText = try container.decodeIfPresent(String.self, forKey: .statusText)
            delayMinutes = try container.decode(Int.self, forKey: .delayMinutes)
            upcomingDepartures = try container.decodeIfPresent([UpcomingDeparture].self, forKey: .upcomingDepartures) ?? []
            activityID = try container.decodeIfPresent(String.self, forKey: .activityID)
            revision = try container.decodeIfPresent(Int.self, forKey: .revision)

            // Handle lastUpdated as Unix timestamp (server sends integer seconds since epoch)
            if let timestamp = try? container.decode(Double.self, forKey: .lastUpdated) {
                lastUpdated = Date(timeIntervalSince1970: timestamp)
            } else if let timestamp = try? container.decode(Int.self, forKey: .lastUpdated) {
                lastUpdated = Date(timeIntervalSince1970: Double(timestamp))
            } else {
                // Fallback to standard Date decoding or current date
                lastUpdated = (try? container.decode(Date.self, forKey: .lastUpdated)) ?? Date()
            }
        }
    }

    public var displayName: String
    public init(displayName: String) { self.displayName = displayName }
}

// Simple public symbols to help verify the package is visible from targets
public struct LAProbe: Sendable { public init() {} }
public func laProbeVersion() -> String { "1.0" }

// MARK: - ActivityKit Conformance
// Note: ActivityKit conformance is declared in ActivityKitBridge.swift
// to avoid duplicate conformance errors
