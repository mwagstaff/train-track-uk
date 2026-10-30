import Foundation
import Testing
@testable import TrainTrack_UK

struct NotificationPreferencesTests {
    @Test func newNotificationPreferencesDefaultOnAndPersistOptOuts() {
        let suite = "NotificationPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for key in [NotificationPreferences.platformOnlyNearStationKey,
                    NotificationPreferences.connectionAlertsKey,
                    NotificationPreferences.connectionUnknownDelayKey] {
            #expect(NotificationPreferences.enabledByDefault(key, defaults: defaults))
            defaults.set(false, forKey: key)
            #expect(!NotificationPreferences.enabledByDefault(key, defaults: defaults))
        }
        #expect(NotificationPreferences.connectionDelayMinutes(defaults: defaults) == 5)
        for (value, expected) in [(0, 1), (1, 1), (15, 15), (30, 30), (31, 30)] {
            defaults.set(value, forKey: NotificationPreferences.connectionDelayMinutesKey)
            #expect(NotificationPreferences.connectionDelayMinutes(defaults: defaults) == expected)
        }
    }
}
