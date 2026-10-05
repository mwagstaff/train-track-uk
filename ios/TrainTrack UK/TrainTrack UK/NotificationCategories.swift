import Foundation
import UserNotifications

enum NotificationCategoryRegistrar {
    static func register() {
        let endAction = UNNotificationAction(
            identifier: NotificationActionId.endJourney,
            title: "End journey",
            options: [.destructive]
        )

        let journeyCategory = UNNotificationCategory(
            identifier: NotificationCategoryId.journeyLegAlert,
            actions: [endAction],
            intentIdentifiers: [],
            options: []
        )

        let arrivalCategory = UNNotificationCategory(
            identifier: NotificationCategoryId.stationArrival,
            actions: [endAction],
            intentIdentifiers: [],
            options: []
        )

        let activationCategory = UNNotificationCategory(
            identifier: NotificationCategoryId.journeyUpdatesActivation,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        // Health alert shown when background arrival detection silently failed. No
        // actions — tapping it simply reopens the app, which re-arms monitoring via the
        // foreground subscription/geofence sync.
        let arrivalHealthCategory = UNNotificationCategory(
            identifier: NotificationCategoryId.arrivalDetectionHealth,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        let journeyHistoryCategory = UNNotificationCategory(
            identifier: NotificationCategoryId.journeyHistory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([
            journeyCategory,
            arrivalCategory,
            activationCategory,
            arrivalHealthCategory,
            journeyHistoryCategory
        ])
    }
}
