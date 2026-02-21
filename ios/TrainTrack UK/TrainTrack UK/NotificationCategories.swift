import Foundation
import UserNotifications

enum NotificationCategoryRegistrar {
    static func register() {
        let muteAction = UNNotificationAction(
            identifier: NotificationActionId.muteLegForToday,
            title: "Mute for today",
            options: [.foreground]
        )

        let journeyCategory = UNNotificationCategory(
            identifier: NotificationCategoryId.journeyLegAlert,
            actions: [muteAction],
            intentIdentifiers: [],
            options: []
        )

        let arrivalCategory = UNNotificationCategory(
            identifier: NotificationCategoryId.stationArrival,
            actions: [muteAction],
            intentIdentifiers: [],
            options: []
        )

        UNUserNotificationCenter.current().setNotificationCategories([journeyCategory, arrivalCategory])
    }
}
