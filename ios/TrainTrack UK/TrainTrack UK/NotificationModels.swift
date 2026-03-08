import Foundation

enum NotificationSubscriptionSource: String, Codable {
    case scheduled
    case liveSession = "live_session"
}

enum NotificationType: String, CaseIterable, Codable, Identifiable {
    case summary
    case delays
    case platform

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .summary: return "Service status summary at start time"
        case .delays: return "Delays or cancellations"
        case .platform: return "Platform updates"
        }
    }
}

enum NotificationPreferences {
    static let store: UserDefaults = .standard
    static let summaryKey = "notificationPreferences.summary"
    static let delaysKey = "notificationPreferences.delays"
    static let platformKey = "notificationPreferences.platform"

    static func selectedTypes() -> [NotificationType] {
        let selected = NotificationType.allCases.filter { isEnabled($0) }
        return selected.isEmpty ? NotificationType.allCases : selected
    }

    static func effectiveTypes(for source: NotificationSubscriptionSource) -> [NotificationType] {
        selectedTypes().filter { type in
            switch (source, type) {
            case (.liveSession, .summary):
                return false
            default:
                return true
            }
        }
    }

    static func isEnabled(_ type: NotificationType) -> Bool {
        let key = storageKey(for: type)
        if store.object(forKey: key) == nil {
            return true
        }
        return store.bool(forKey: key)
    }

    static func storageKey(for type: NotificationType) -> String {
        switch type {
        case .summary:
            return summaryKey
        case .delays:
            return delaysKey
        case .platform:
            return platformKey
        }
    }
}

enum DayOfWeek: String, CaseIterable, Codable, Identifiable {
    case mon, tue, wed, thu, fri, sat, sun

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .mon: return "Mon"
        case .tue: return "Tue"
        case .wed: return "Wed"
        case .thu: return "Thu"
        case .fri: return "Fri"
        case .sat: return "Sat"
        case .sun: return "Sun"
        }
    }
}

struct NotificationLeg: Codable, Identifiable, Hashable {
    let from: String
    let to: String
    let fromName: String?
    let toName: String?
    var enabled: Bool
    var windowStart: String
    var windowEnd: String

    var id: String { "\(from)->\(to)" }

    enum CodingKeys: String, CodingKey {
        case from
        case to
        case fromName = "from_name"
        case toName = "to_name"
        case enabled
        case windowStart = "window_start"
        case windowEnd = "window_end"
    }
}

struct NotificationSubscription: Codable, Identifiable, Hashable {
    let id: String
    let deviceId: String
    let routeKey: String
    let daysOfWeek: [DayOfWeek]
    let notificationTypes: [NotificationType]
    let legs: [NotificationLeg]
    let muteOnArrival: Bool?
    let source: NotificationSubscriptionSource?
    let activeUntil: Date?
    let mutedByLegDay: [String: String]?
    let mutedAtByLegDay: [String: String]?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case routeKey = "route_key"
        case daysOfWeek = "days_of_week"
        case notificationTypes = "notification_types"
        case legs
        case muteOnArrival = "mute_on_arrival"
        case source
        case activeUntil = "active_until"
        case mutedByLegDay = "muted_by_leg_day"
        case mutedAtByLegDay = "muted_at_by_leg_day"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var routeTitle: String {
        guard let first = legs.first, let last = legs.last else { return routeKey }
        let from = first.fromName ?? first.from
        let to = last.toName ?? last.to
        if legs.count <= 1 {
            return "\(from) → \(to)"
        }
        let via = legs.dropLast().map { $0.toName ?? $0.to }
        return "\(from) → \(to) via \(via.joined(separator: ", "))"
    }

    var daysLabel: String {
        let labels = daysOfWeek.map { $0.shortLabel }
        return labels.joined(separator: ", ")
    }

    var windowLabel: String {
        let enabledLegs = legs.filter { $0.enabled }
        guard !enabledLegs.isEmpty else { return "No window" }
        if enabledLegs.count == 1, let leg = enabledLegs.first {
            return "\(leg.windowStart)–\(leg.windowEnd)"
        }
        let parts = enabledLegs.map { "\($0.windowStart)–\($0.windowEnd)" }
        return parts.joined(separator: " / ")
    }

    var typeLabel: String {
        guard !notificationTypes.isEmpty else { return "No active alerts" }
        let labels = notificationTypes.map { type in
            switch type {
            case .summary: return "Summary"
            case .delays: return "Delays"
            case .platform: return "Platform"
            }
        }
        return labels.joined(separator: ", ")
    }
}

struct NotificationSubscriptionRequest: Codable {
    let subscriptionId: String?
    let deviceId: String
    let pushToken: String
    let routeKey: String
    let daysOfWeek: [DayOfWeek]
    let notificationTypes: [NotificationType]
    let legs: [NotificationLeg]
    let windowStart: String?
    let windowEnd: String?
    let from: String?
    let to: String?
    let fromName: String?
    let toName: String?
    let useSandbox: Bool?
    let muteOnArrival: Bool?
    let activeUntil: Date?

    enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id"
        case deviceId = "device_id"
        case pushToken = "push_token"
        case routeKey = "route_key"
        case daysOfWeek = "days_of_week"
        case notificationTypes = "notification_types"
        case legs
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case from
        case to
        case fromName = "from_name"
        case toName = "to_name"
        case useSandbox = "use_sandbox"
        case muteOnArrival = "mute_on_arrival"
        case activeUntil = "active_until"
    }
}
