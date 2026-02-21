import Foundation

enum NotificationPayloadKeys {
    static let subscriptionId = "subscription_id"
    static let routeKey = "route_key"
    static let from = "from"
    static let to = "to"
    static let fromName = "from_name"
    static let toName = "to_name"
    static let legKey = "leg_key"
    static let alertType = "alert_type"
}

enum NotificationCategoryId {
    static let journeyLegAlert = "JOURNEY_LEG_ALERT"
    static let stationArrival = "STATION_ARRIVAL"
}

enum NotificationActionId {
    static let muteLegForToday = "MUTE_LEG_TODAY"
}
