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
    static let windowStart = "window_start"
    static let windowEnd = "window_end"
    static let diagnosticMarker = "diagnostic_marker"
    static let diagnosticChannel = "diagnostic_channel"
    static let diagnosticEvent = "diagnostic_event"
}

enum NotificationCategoryId {
    static let journeyLegAlert = "JOURNEY_LEG_ALERT"
    static let stationArrival = "STATION_ARRIVAL"
    static let journeyUpdatesActivation = "JOURNEY_UPDATES_ACTIVATION"
    static let arrivalDetectionHealth = "ARRIVAL_DETECTION_HEALTH"
}

enum NotificationActionId {
    static let muteLegForToday = "MUTE_LEG_TODAY"
}

enum NotificationAlertType {
    static let arrivalDetectionFailed = "arrival_detection_failed"
}
