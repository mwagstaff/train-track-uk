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
    static let journeyHistory = "JOURNEY_HISTORY"
}

enum NotificationActionId {
    static let endJourney = "END_JOURNEY"
    static let muteLegForToday = "MUTE_LEG_TODAY"
}

enum NotificationAlertType {
    static let originWelcome = "origin_welcome"
    static let arrivalDetectionFailed = "arrival_detection_failed"
    static let journeyArrivalConfirmed = "journey_arrival_confirmed"
    static let journeyDelayRepay = "journey_delay_repay"
    static let journeyTrackingStopped = "journey_tracking_stopped"
}

/// The first greeting is independent of station-exit muting and the boarding alert.
enum OriginWelcomeNotification {
    static func body(stationName: String, departures: [DepartureV2], now: Date, calendar: Calendar = .current) -> String {
        let greeting = "Welcome to \(stationName)."
        let minuteStart = calendar.dateInterval(of: .minute, for: now)?.start ?? now
        let upcoming = departures.compactMap { departure -> (DepartureV2, Date)? in
            guard departure.serviceType.lowercased() == "train",
                  !departure.isCancelled, !departure.filterLocationCancelled,
                  departure.departureTime.actual?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
                  departure.departureTime.estimated.caseInsensitiveCompare("Cancelled") != .orderedSame,
                  let scheduled = JourneyHistoryTime.date(
                    for: departure.departureTime.scheduled, near: now, calendar: calendar
                  ) else { return nil }
            let effective = JourneyHistoryTime.date(
                for: departure.departureTime.estimated, near: scheduled, calendar: calendar
            ) ?? scheduled
            guard effective >= minuteStart else { return nil }
            return (departure, effective)
        }.min { $0.1 < $1.1 }?.0
        guard let upcoming else { return greeting + " Check the departure board for the next train." }
        var message = greeting + " Next train \(upcoming.departureTime.scheduled)"
        let estimate = upcoming.departureTime.estimated
        if estimate.caseInsensitiveCompare("Delayed") == .orderedSame {
            message += " (delayed)"
        } else if estimate != upcoming.departureTime.scheduled,
                  JourneyHistoryTime.date(for: estimate, near: now, calendar: calendar) != nil {
            message += " (expected \(estimate))"
        }
        if let platform = upcoming.platform?.trimmingCharacters(in: .whitespacesAndNewlines),
           !platform.isEmpty, !upcoming.platformIsHidden {
            message += " from platform \(platform)"
        }
        return message + "."
    }
}
