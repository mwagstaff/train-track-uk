import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

public struct DebugActivityAttributes: Codable, Hashable {
    public struct ContentState: Codable, Hashable {
        public var status: String
        public var updatedAt: Date

        public init(status: String, updatedAt: Date) {
            self.status = status
            self.updatedAt = updatedAt
        }

        enum CodingKeys: String, CodingKey {
            case status, updatedAt
        }
    }

    public var displayText: String

    public init(displayText: String) {
        self.displayText = displayText
    }
}

#if canImport(ActivityKit)
extension DebugActivityAttributes: ActivityAttributes {}
#endif
