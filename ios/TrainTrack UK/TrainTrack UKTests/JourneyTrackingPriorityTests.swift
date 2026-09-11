import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct JourneyTrackingPriorityTests {
    @Test func activeAdHocJourneyBlocksScheduledActivation() {
        #expect(JourneyTrackingCoordinator.hasInProgressAdHocJourney(
            activeSource: .adhoc, candidates: []
        ))
        #expect(!JourneyTrackingCoordinator.hasInProgressAdHocJourney(
            activeSource: .scheduled, candidates: []
        ))
        #expect(!JourneyTrackingCoordinator.hasInProgressAdHocJourney(
            activeSource: nil, candidates: []
        ))
    }

    @Test func adHocJourneyIsProtectedBeforeBoardingButNotAfterExpiry() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let candidate = candidate(id: "manual", source: .adhoc, expiresAt: now.addingTimeInterval(60))

        #expect(JourneyTrackingCoordinator.hasInProgressAdHocJourney(
            activeSource: nil, candidates: [candidate], now: now
        ))
        #expect(!JourneyTrackingCoordinator.hasInProgressAdHocJourney(
            activeSource: nil, candidates: [candidate], now: now.addingTimeInterval(60)
        ))
    }

    @Test func scheduledCallbackForSameRouteKeepsAdHocCandidate() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let candidates = [
            candidate(id: "scheduled", source: .scheduled, expiresAt: now.addingTimeInterval(60)),
            candidate(id: "manual", source: .adhoc, expiresAt: now.addingTimeInterval(60))
        ]

        #expect(JourneyTrackingCoordinator.candidateIndexForRouteEvent(
            in: candidates, subscriptionID: "scheduled", from: "vic", to: "kth", now: now
        ) == 1)
        #expect(JourneyTrackingCoordinator.candidateIndexForRouteEvent(
            in: candidates, subscriptionID: "scheduled", now: now
        ) == nil)
    }

    @Test func scheduledCallbackForDifferentRouteCannotReplaceAdHocCandidate() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let candidates = [
            candidate(id: "scheduled", source: .scheduled, expiresAt: now.addingTimeInterval(60), from: "KTH", to: "VIC"),
            candidate(id: "manual", source: .adhoc, expiresAt: now.addingTimeInterval(60))
        ]

        #expect(JourneyTrackingCoordinator.candidateIndexForRouteEvent(
            in: candidates, subscriptionID: "scheduled", from: "KTH", to: "VIC", now: now
        ) == nil)
        #expect(JourneyTrackingCoordinator.candidateIndexForRouteEvent(
            in: candidates, subscriptionID: "manual", from: "VIC", to: "KTH", now: now
        ) == 1)
    }

    @Test func expiredAdHocCandidateDoesNotBlockScheduledBoarding() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let candidates = [
            candidate(id: "scheduled", source: .scheduled, expiresAt: now.addingTimeInterval(60)),
            candidate(id: "manual", source: .adhoc, expiresAt: now)
        ]

        #expect(JourneyTrackingCoordinator.candidateIndexForRouteEvent(
            in: candidates, subscriptionID: "scheduled", from: "VIC", to: "KTH", now: now
        ) == 0)
    }

    @Test func backendSkipNoticeBlocksCachedJourneyWithoutRoutePayload() async throws {
        let suiteName = "JourneyTrackingPriorityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let manager = ScheduledLiveActivityAutoStartManager(skipDefaults: defaults)
        let now = Date()
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let scheduleKey = "VIC-KTH|16:00|16:30|\(formatter.string(from: now))"
        let handled = await manager.handleRemoteNotification(userInfo: [
            "alert_type": "scheduled_journey_skipped",
            "schedule_key": scheduleKey
        ])
        #expect(handled)

        let leg = NotificationLeg(
            from: "vic", to: "kth", fromName: nil, toName: nil,
            enabled: true, windowStart: "08:00", windowEnd: "08:30",
            dayWindows: Dictionary(uniqueKeysWithValues: DayOfWeek.allCases.map {
                ($0.rawValue, NotificationTimeWindow(windowStart: "16:00", windowEnd: "16:30"))
            })
        )
        #expect(manager.shouldSkipForAdHocJourney(leg: leg, now: now))
        #expect(defaults.stringArray(forKey: "scheduled_live_activity_adhoc_reported_keys") == [scheduleKey])

        let restored = ScheduledLiveActivityAutoStartManager(skipDefaults: defaults)
        #expect(restored.shouldSkipForAdHocJourney(leg: leg, now: now))
    }

    private func candidate(
        id: String,
        source: JourneyHistorySource,
        expiresAt: Date,
        from: String = "VIC",
        to: String = "KTH"
    ) -> ArmedJourneyHistoryCandidate {
        ArmedJourneyHistoryCandidate(
            subscriptionId: id,
            source: source,
            stations: [from, to].map { Station(crs: $0, name: $0, longitude: "0", latitude: "0") },
            createdAt: expiresAt.addingTimeInterval(-60),
            activeUntil: expiresAt,
            originArrivedAt: nil,
            candidateDepartures: []
        )
    }
}
