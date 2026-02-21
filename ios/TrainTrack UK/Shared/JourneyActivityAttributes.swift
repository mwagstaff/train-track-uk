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
            activityID: String? = nil
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
        }

        enum CodingKeys: String, CodingKey {
            case fromCRS, toCRS, destinationTitle, arrivalLabel, length, platform, estimated, statusText, delayMinutes, activityID
        }
    }

    public var displayName: String
    public init(displayName: String) { self.displayName = displayName }
}
