import Foundation
import ActivityKit

public struct JourneyActivityAttributes: ActivityAttributes {
    public struct UpcomingDeparture: Codable, Hashable {
        public var time: String
        public var arrivalTime: String?
        public var delayMinutes: Int
        public var isCancelled: Bool
        public var platform: String?
        public var hasFasterLaterService: Bool

        public init(time: String, arrivalTime: String? = nil, delayMinutes: Int, isCancelled: Bool, platform: String? = nil, hasFasterLaterService: Bool = false) {
            self.time = time
            self.arrivalTime = arrivalTime
            self.delayMinutes = delayMinutes
            self.isCancelled = isCancelled
            self.platform = platform
            self.hasFasterLaterService = hasFasterLaterService
        }
    }

    public struct ContentState: Codable, Hashable {
        public var fromCRS: String
        public var toCRS: String
        public var routeTitle: String?
        public var deepLinkFromCRS: String?
        public var deepLinkToCRS: String?
        public var destinationTitle: String
        public var arrivalLabel: String?
        public var scheduledDeparture: String?
        public var length: Int?
        public var platform: String
        public var estimated: String
        public var isCancelled: Bool
        public var statusText: String?
        public var delayMinutes: Int
        public var upcomingDepartures: [UpcomingDeparture]
        public var lastUpdated: Date
        public var activityID: String?
        public var revision: Int?
        public var appIsActive: Bool
        public var journeyUpdatesEnabled: Bool
        public var scheduleKey: String?
        public var windowStart: String?
        public var windowEnd: String?

        public init(
            fromCRS: String,
            toCRS: String,
            routeTitle: String? = nil,
            deepLinkFromCRS: String? = nil,
            deepLinkToCRS: String? = nil,
            destinationTitle: String,
            arrivalLabel: String?,
            scheduledDeparture: String? = nil,
            length: Int?,
            platform: String,
            estimated: String,
            isCancelled: Bool = false,
            statusText: String?,
            delayMinutes: Int,
            upcomingDepartures: [UpcomingDeparture] = [],
            lastUpdated: Date = Date(),
            activityID: String? = nil,
            revision: Int? = nil,
            appIsActive: Bool = false,
            journeyUpdatesEnabled: Bool = true,
            scheduleKey: String? = nil,
            windowStart: String? = nil,
            windowEnd: String? = nil
        ) {
            self.fromCRS = fromCRS
            self.toCRS = toCRS
            self.routeTitle = routeTitle
            self.deepLinkFromCRS = deepLinkFromCRS
            self.deepLinkToCRS = deepLinkToCRS
            self.destinationTitle = destinationTitle
            self.arrivalLabel = arrivalLabel
            self.scheduledDeparture = scheduledDeparture
            self.length = length
            self.platform = platform
            self.estimated = estimated
            self.isCancelled = isCancelled
            self.statusText = statusText
            self.delayMinutes = delayMinutes
            self.upcomingDepartures = upcomingDepartures
            self.lastUpdated = lastUpdated
            self.activityID = activityID
            self.revision = revision
            self.appIsActive = appIsActive
            self.journeyUpdatesEnabled = journeyUpdatesEnabled
            self.scheduleKey = scheduleKey
            self.windowStart = windowStart
            self.windowEnd = windowEnd
        }

        enum CodingKeys: String, CodingKey {
            case fromCRS, toCRS, routeTitle, deepLinkFromCRS, deepLinkToCRS, destinationTitle, arrivalLabel, scheduledDeparture, length, platform, estimated, isCancelled, statusText, delayMinutes, upcomingDepartures, lastUpdated, activityID, revision, appIsActive, journeyUpdatesEnabled, scheduleKey, windowStart, windowEnd
        }
    }

    public var displayName: String
    public init(displayName: String) { self.displayName = displayName }
}
