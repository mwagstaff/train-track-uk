import Foundation
import UserNotifications
import UIKit

enum NotificationPushTokenStore {
    private static let storageKey = "notification_push_token"
    private static let store: UserDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard

    static var token: String? {
        store.string(forKey: storageKey)
    }

    static func set(token: String) {
        store.set(token, forKey: storageKey)
    }

    static func waitForToken(timeoutSeconds: Double = 4.0) async -> String? {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let token = token, !token.isEmpty {
                return token
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return token
    }
}

enum NotificationAuthorizationManager {
    static func ensureAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            await registerForRemoteNotifications()
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                if granted {
                    await registerForRemoteNotifications()
                }
                return granted
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    static func registerIfAuthorized() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            await registerForRemoteNotifications()
        default:
            break
        }
    }

    @MainActor
    private static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

final class NotificationAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationCategoryRegistrar.register()
        // If relaunched in background to deliver a region event, ensure the
        // geofence manager's CLLocationManager is initialised before iOS
        // delivers the queued CLLocationManagerDelegate callbacks.
        if launchOptions?[.location] != nil {
            _ = NotificationGeofenceManager.shared
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationPushTokenStore.set(token: token)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("⚠️ [Notifications] Failed to register for remote notifications: \(error.localizedDescription)")
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundSessionCoordinator.shared.register(identifier: identifier, completion: completionHandler)
        // Ensure the relevant background session delegate is instantiated so iOS
        // can deliver its completion events.
        switch identifier {
        case NotificationMuteRequestSender.sessionIdentifier:
            _ = NotificationMuteRequestSender.shared
        case GeofenceEventSender.sessionIdentifier:
            _ = GeofenceEventSender.shared
        default:
            break
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NotificationAlertHandler.shared.handle(response: response)
        }
        completionHandler()
    }
}
