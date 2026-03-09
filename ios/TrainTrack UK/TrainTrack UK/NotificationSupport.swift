import Foundation
import UserNotifications
import UIKit
import ActivityKit
import JourneyActivityShared

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
        _ = LiveActivityManager.shared
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
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            let started = await ScheduledLiveActivityAutoStartManager.shared.handleRemoteNotification(userInfo: userInfo)
            completionHandler(started ? .newData : .noData)
        }
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

typealias ScheduledJourneyActivityAttributes = JourneyActivityShared.JourneyActivityAttributes

@MainActor
final class ScheduledLiveActivityAutoStartManager {
    static let shared = ScheduledLiveActivityAutoStartManager()

    private let suiteName = "group.dev.skynolimit.traintrack"
    private let recordsKey = "scheduled_live_activity_records"
    private let duplicateGuardInterval: TimeInterval = 30
    private let autoStartAlertType = "scheduled_live_activity_start"
    private var inFlightKeys: Set<String> = []

    private init() {}

    func handleRemoteNotification(userInfo: [AnyHashable: Any]) async -> Bool {
        guard let trigger = ScheduledLiveActivityTrigger(userInfo: userInfo),
              trigger.alertType == autoStartAlertType else {
            return false
        }
        return await startIfNeeded(for: trigger, overwriteExisting: true)
    }

    func startEligibleScheduledLiveActivities() async {
        let subscriptions = NotificationSubscriptionStore.shared.subscriptions
        let today = currentDayOfWeek()
        let now = Date()

        for subscription in subscriptions where subscription.daysOfWeek.contains(today) {
            for leg in subscription.legs where leg.enabled {
                guard isWithinWindow(now: now, start: leg.windowStart, end: leg.windowEnd) else { continue }
                guard let trigger = ScheduledLiveActivityTrigger(
                    subscriptionId: subscription.id,
                    routeKey: subscription.routeKey,
                    from: leg.from.uppercased(),
                    to: leg.to.uppercased(),
                    fromName: leg.fromName,
                    toName: leg.toName,
                    alertType: autoStartAlertType,
                    windowStart: leg.windowStart,
                    windowEnd: leg.windowEnd
                ) else {
                    continue
                }
                _ = await startIfNeeded(for: trigger, overwriteExisting: false)
            }
        }
    }

    func removeRecord(activityID: String) {
        var records = loadRecords()
        let originalCount = records.count
        records.removeAll { $0.activityID == activityID }
        guard records.count != originalCount else { return }
        saveRecords(records)
    }

    private func startIfNeeded(for trigger: ScheduledLiveActivityTrigger, overwriteExisting: Bool) async -> Bool {
        let scheduleKey = trigger.scheduleKey
        guard !scheduleKey.isEmpty else { return false }
        guard !inFlightKeys.contains(scheduleKey) else { return false }
        inFlightKeys.insert(scheduleKey)
        defer { inFlightKeys.remove(scheduleKey) }

        var records = pruneStaleRecords(loadRecords())
        if let existing = records.first(where: { $0.scheduleKey == scheduleKey }) {
            if hasActiveActivity(id: existing.activityID),
               Date().timeIntervalSince(existing.startedAt) < duplicateGuardInterval || !overwriteExisting {
                return true
            }
            if hasActiveActivity(id: existing.activityID) {
                return true
            }
            await stopExisting(record: existing)
            records.removeAll { $0.scheduleKey == scheduleKey }
            saveRecords(records)
        }

        guard let journey = await makeJourney(from: trigger.from, to: trigger.to) else {
            return false
        }

        if LiveActivityManager.shared.isActive(for: journey) {
            return true
        }

        await LiveActivityManager.shared.start(
            for: journey,
            depStore: DeparturesStore.shared,
            triggeredByUser: false,
            bypassSuppression: true,
            allowAutomaticStart: true
        )

        guard LiveActivityManager.shared.isActive(for: journey),
              let activityID = LiveActivityManager.shared.activityID(for: journey) else {
            return false
        }

        let liveSessionID = await registerLiveSession(trigger: trigger)
        var updatedRecords = loadRecords()
        updatedRecords.removeAll { $0.scheduleKey == scheduleKey }
        updatedRecords.append(ScheduledLiveActivityRecord(
            scheduleKey: scheduleKey,
            routeKey: trigger.routeKey,
            from: trigger.from,
            to: trigger.to,
            windowStart: trigger.windowStart,
            windowEnd: trigger.windowEnd,
            activityID: activityID,
            liveSessionID: liveSessionID,
            startedAt: Date()
        ))
        saveRecords(updatedRecords)
        return true
    }

    private func registerLiveSession(trigger: ScheduledLiveActivityTrigger) async -> String? {
        let pushToken: String?
        if let existingToken = NotificationPushTokenStore.token, !existingToken.isEmpty {
            pushToken = existingToken
        } else {
            pushToken = await NotificationPushTokenStore.waitForToken(timeoutSeconds: 1.0)
        }
        guard let pushToken,
              !pushToken.isEmpty else {
            return nil
        }

        #if DEBUG
        let useSandbox = true
        #else
        let useSandbox = false
        #endif

        let storedMinutes = UserDefaults.standard.integer(forKey: "liveActivityDurationMinutes")
        let durationMinutes = storedMinutes == 0 ? 60 : max(1, storedMinutes)
        let activeUntil = Date().addingTimeInterval(Double(durationMinutes * 60))
        let request = NotificationSubscriptionRequest(
            subscriptionId: nil,
            deviceId: DeviceIdentity.deviceToken,
            pushToken: pushToken,
            routeKey: "\(trigger.from)-\(trigger.to)",
            daysOfWeek: [currentDayOfWeek()],
            notificationTypes: NotificationPreferences.effectiveTypes(for: .liveSession),
            legs: [NotificationLeg(
                from: trigger.from,
                to: trigger.to,
                fromName: trigger.fromName,
                toName: trigger.toName,
                enabled: true,
                windowStart: trigger.windowStart,
                windowEnd: trigger.windowEnd
            )],
            windowStart: trigger.windowStart,
            windowEnd: trigger.windowEnd,
            from: trigger.from,
            to: trigger.to,
            fromName: trigger.fromName,
            toName: trigger.toName,
            useSandbox: useSandbox,
            muteOnArrival: (UserDefaults.standard.object(forKey: "autoMuteOnArrival") as? Bool) ?? true,
            activeUntil: activeUntil
        )

        do {
            let session = try await NotificationSubscriptionStore.shared.upsertLiveSession(request)
            return session.id
        } catch {
            print("⚠️ [ScheduledLiveActivity] Failed to upsert live session: \(error.localizedDescription)")
            return nil
        }
    }

    private func stopExisting(record: ScheduledLiveActivityRecord) async {
        if let liveSessionID = record.liveSessionID {
            do {
                try await NotificationSubscriptionStore.shared.deleteLiveSession(id: liveSessionID)
            } catch {
                print("⚠️ [ScheduledLiveActivity] Failed to delete existing live session \(liveSessionID): \(error.localizedDescription)")
            }
        }
        if hasActiveActivity(id: record.activityID) {
            await LiveActivityManager.shared.stopActivity(activityID: record.activityID)
        }
    }

    private func makeJourney(from: String, to: String) async -> Journey? {
        if StationsService.shared.stations.isEmpty {
            try? await StationsService.shared.loadStations()
        }

        guard let fromStation = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(from) == .orderedSame }),
              let toStation = StationsService.shared.stations.first(where: { $0.crs.caseInsensitiveCompare(to) == .orderedSame }) else {
            return nil
        }

        return Journey(fromStation: fromStation, toStation: toStation, favorite: false)
    }

    private func hasActiveActivity(id: String) -> Bool {
        Activity<ScheduledJourneyActivityAttributes>.activities.contains { $0.id == id }
    }

    private func isWithinWindow(now: Date, start: String, end: String) -> Bool {
        guard let startMinutes = minutes(from: start),
              let endMinutes = minutes(from: end) else {
            return false
        }
        let components = Calendar.current.dateComponents([.hour, .minute], from: now)
        let nowMinutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return nowMinutes >= startMinutes && nowMinutes <= endMinutes
    }

    private func minutes(from hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]) else {
            return nil
        }
        return (hour * 60) + minute
    }

    private func currentDayOfWeek() -> DayOfWeek {
        switch Calendar.current.component(.weekday, from: Date()) {
        case 1: return .sun
        case 2: return .mon
        case 3: return .tue
        case 4: return .wed
        case 5: return .thu
        case 6: return .fri
        default: return .sat
        }
    }

    private func loadRecords() -> [ScheduledLiveActivityRecord] {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: recordsKey),
              let decoded = try? JSONDecoder().decode([ScheduledLiveActivityRecord].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveRecords(_ records: [ScheduledLiveActivityRecord]) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = try? JSONEncoder().encode(records) else {
            return
        }
        defaults.set(data, forKey: recordsKey)
    }

    private func pruneStaleRecords(_ records: [ScheduledLiveActivityRecord]) -> [ScheduledLiveActivityRecord] {
        let todayKey = ScheduledLiveActivityTrigger.currentDateKey()
        let filtered = records.filter { record in
            let keyParts = record.scheduleKey.split(separator: "|")
            guard let datePart = keyParts.last else { return false }
            return String(datePart) == todayKey
        }
        if filtered.count != records.count {
            saveRecords(filtered)
        }
        return filtered
    }
}

private struct ScheduledLiveActivityTrigger {
    let subscriptionId: String?
    let routeKey: String
    let from: String
    let to: String
    let fromName: String?
    let toName: String?
    let alertType: String?
    let windowStart: String
    let windowEnd: String

    var scheduleKey: String {
        "\(from.uppercased())-\(to.uppercased())|\(windowStart)|\(windowEnd)|\(Self.currentDateKey())"
    }

    init?(
        subscriptionId: String?,
        routeKey: String?,
        from: String?,
        to: String?,
        fromName: String?,
        toName: String?,
        alertType: String?,
        windowStart: String?,
        windowEnd: String?
    ) {
        guard let routeKey, !routeKey.isEmpty,
              let from, !from.isEmpty,
              let to, !to.isEmpty,
              let windowStart, !windowStart.isEmpty,
              let windowEnd, !windowEnd.isEmpty else {
            return nil
        }
        self.subscriptionId = subscriptionId
        self.routeKey = routeKey
        self.from = from.uppercased()
        self.to = to.uppercased()
        self.fromName = fromName
        self.toName = toName
        self.alertType = alertType
        self.windowStart = windowStart
        self.windowEnd = windowEnd
    }

    init?(userInfo: [AnyHashable: Any]) {
        self.init(
            subscriptionId: Self.stringValue(NotificationPayloadKeys.subscriptionId, in: userInfo),
            routeKey: Self.stringValue(NotificationPayloadKeys.routeKey, in: userInfo),
            from: Self.stringValue(NotificationPayloadKeys.from, in: userInfo),
            to: Self.stringValue(NotificationPayloadKeys.to, in: userInfo),
            fromName: Self.stringValue(NotificationPayloadKeys.fromName, in: userInfo),
            toName: Self.stringValue(NotificationPayloadKeys.toName, in: userInfo),
            alertType: Self.stringValue(NotificationPayloadKeys.alertType, in: userInfo),
            windowStart: Self.stringValue(NotificationPayloadKeys.windowStart, in: userInfo),
            windowEnd: Self.stringValue(NotificationPayloadKeys.windowEnd, in: userInfo)
        )
    }

    private static func stringValue(_ key: String, in userInfo: [AnyHashable: Any]) -> String? {
        if let value = userInfo[key] as? String { return value }
        if let value = userInfo[key] as? NSString { return value as String }
        return nil
    }

    static func currentDateKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}

private struct ScheduledLiveActivityRecord: Codable {
    let scheduleKey: String
    let routeKey: String
    let from: String
    let to: String
    let windowStart: String
    let windowEnd: String
    let activityID: String
    let liveSessionID: String?
    let startedAt: Date
}
