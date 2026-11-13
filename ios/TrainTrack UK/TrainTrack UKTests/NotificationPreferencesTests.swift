import Foundation
import Testing
@testable import TrainTrack_UK

struct NotificationPreferencesTests {
    @Test func boardingFirstLegKeepsOnwardMonitoringUntilLastLegIsMuted() throws {
        let json = """
        {"id":"session","device_id":"device","route_key":"KTH-HNH-BFR","days_of_week":[],"notification_types":[],
         "source":"live_session","legs":[
          {"from":"KTH","to":"HNH","enabled":true,"window_start":"00:00","window_end":"23:59"},
          {"from":"HNH","to":"BFR","enabled":true,"window_start":"00:00","window_end":"23:59"}]}
        """
        let session = try JSONDecoder().decode(NotificationSubscription.self, from: Data(json.utf8))
        #expect(session.hasRemainingLegs(afterMutingFrom: "kth", to: "hnh", isMuted: { _, _ in false }))
        #expect(!session.hasRemainingLegs(afterMutingFrom: "HNH", to: "BFR", isMuted: { from, to in
            from == "KTH" && to == "HNH"
        }))
        #expect(!session.hasRemainingLegs(afterMutingFrom: "KTH", to: "HNH", isMuted: { _, _ in true }))
    }

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
