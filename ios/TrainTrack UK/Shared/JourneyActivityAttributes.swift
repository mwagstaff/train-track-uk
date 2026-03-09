import Foundation
import ActivityKit

public struct JourneyActivityAttributes: ActivityAttributes {
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
        public var activityID: String?
        public var scheduleKey: String?
        public var windowStart: String?
        public var windowEnd: String?

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
            activityID: String? = nil,
            scheduleKey: String? = nil,
            windowStart: String? = nil,
            windowEnd: String? = nil
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
            self.activityID = activityID
            self.scheduleKey = scheduleKey
            self.windowStart = windowStart
            self.windowEnd = windowEnd
        }

        enum CodingKeys: String, CodingKey {
            case fromCRS, toCRS, destinationTitle, arrivalLabel, length, platform, estimated, statusText, delayMinutes, activityID, scheduleKey, windowStart, windowEnd
        }
    }

    public var displayName: String
    public init(displayName: String) { self.displayName = displayName }
}
