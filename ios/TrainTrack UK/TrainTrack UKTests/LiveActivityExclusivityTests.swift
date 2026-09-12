import Foundation
import Testing
import JourneyActivityShared
@testable import TrainTrack_UK

struct LiveActivityExclusivityTests {
    private typealias Candidate = LiveActivityExclusivityPolicy.Candidate

    @Test
    func adHocActivitySurvivesScheduledPushEvenBeforeTrackingRestores() {
        let activities = [
            Candidate(id: "scheduled", isScheduled: true, hasArrived: false),
            Candidate(id: "adhoc", isScheduled: false, hasArrived: false)
        ]

        #expect(LiveActivityExclusivityPolicy.activityIDToKeep(
            activities,
            preferredID: "scheduled",
            hasInProgressAdHocJourney: false
        ) == "adhoc")
    }

    @Test
    func scheduledPushIsDiscardedWhileAdHocTrackingHasNoWidget() {
        #expect(LiveActivityExclusivityPolicy.activityIDToKeep(
            [Candidate(id: "scheduled", isScheduled: true, hasArrived: false)],
            preferredID: nil,
            hasInProgressAdHocJourney: true
        ) == nil)
    }

    @Test
    func deviceKeepsOnlyTheExistingActivityAcrossDifferentSchedules() {
        let activities = [
            Candidate(id: "morning", isScheduled: true, hasArrived: false),
            Candidate(id: "evening", isScheduled: true, hasArrived: false)
        ]

        #expect(LiveActivityExclusivityPolicy.activityIDToKeep(
            activities,
            preferredID: "morning",
            hasInProgressAdHocJourney: false
        ) == "morning")
    }

    @Test
    func recoveryWinnerDoesNotDependOnActivityKitEnumerationOrder() {
        let activities = [
            Candidate(id: "b", isScheduled: false, hasArrived: false),
            Candidate(id: "a", isScheduled: false, hasArrived: false)
        ]

        #expect(LiveActivityExclusivityPolicy.activityIDToKeep(
            activities,
            preferredID: nil,
            hasInProgressAdHocJourney: false
        ) == "a")
        #expect(LiveActivityExclusivityPolicy.activityIDToKeep(
            Array(activities.reversed()),
            preferredID: nil,
            hasInProgressAdHocJourney: false
        ) == "a")
    }

    @Test
    func completedAdHocJourneyDoesNotDisplaceNewScheduledActivity() {
        #expect(LiveActivityExclusivityPolicy.activityIDToKeep(
            [
                Candidate(id: "adhoc", isScheduled: false, hasArrived: true),
                Candidate(id: "scheduled", isScheduled: true, hasArrived: false)
            ],
            preferredID: "adhoc",
            hasInProgressAdHocJourney: false
        ) == "scheduled")
    }
}

struct LiveActivityDismissalPolicyTests {
    @Test
    func dismissalBeforeOriginArrivalEndsJourney() {
        #expect(LiveActivityDismissalPolicy.shouldEndJourney(in: .pendingStart))
        #expect(!LiveActivityDismissalPolicy.shouldPreserveJourneyTracking(in: .pendingStart))
    }

    @Test
    func dismissalAtOriginOrOnTrainPreservesJourneyTracking() {
        #expect(LiveActivityDismissalPolicy.shouldPreserveJourneyTracking(in: .atStart))
        #expect(LiveActivityDismissalPolicy.shouldPreserveJourneyTracking(in: .enRoute))
        #expect(!LiveActivityDismissalPolicy.shouldEndJourney(in: .atStart))
        #expect(!LiveActivityDismissalPolicy.shouldEndJourney(in: .enRoute))
    }

    @Test
    func dismissalAfterFinalArrivalDoesNotPreserveJourneyTracking() {
        #expect(!LiveActivityDismissalPolicy.shouldPreserveJourneyTracking(in: .arrived))
        #expect(!LiveActivityDismissalPolicy.shouldEndJourney(in: .arrived))
    }
}

struct JourneyActivityLifecycleStoreTests {
    @Test
    func pendingDismissalIsRememberedButLaterJourneyPhasesArePreserved() {
        let suiteName = "JourneyActivityLifecycleStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let activityID = "activity-1"
        let scheduleKey = "schedule-1"

        JourneyActivityLifecycleStore.update(
            activityID: activityID,
            state: state(scheduleKey: scheduleKey, phase: .pendingStart),
            defaults: defaults
        )
        JourneyActivityLifecycleStore.setLiveSessionID(
            "live-session-1",
            activityID: activityID,
            defaults: defaults
        )
        JourneyActivityLifecycleStore.markDismissedBeforeStart(
            activityID: activityID,
            defaults: defaults
        )

        let pendingRecord = JourneyActivityLifecycleStore.record(
            scheduleKey: scheduleKey,
            defaults: defaults
        )
        #expect(pendingRecord?.dismissedBeforeStart == true)
        #expect(pendingRecord?.liveSessionID == "live-session-1")

        JourneyActivityLifecycleStore.update(
            activityID: activityID,
            state: state(scheduleKey: scheduleKey, phase: .atStart),
            defaults: defaults
        )
        JourneyActivityLifecycleStore.markDismissedBeforeStart(
            activityID: activityID,
            defaults: defaults
        )

        let atStartRecord = JourneyActivityLifecycleStore.record(
            scheduleKey: scheduleKey,
            defaults: defaults
        )
        #expect(atStartRecord?.phase == .atStart)
        #expect(atStartRecord?.dismissedBeforeStart == false)
        #expect(atStartRecord?.liveSessionID == "live-session-1")

        JourneyActivityLifecycleStore.remove(activityID: activityID, defaults: defaults)
        #expect(JourneyActivityLifecycleStore.record(
            scheduleKey: scheduleKey,
            defaults: defaults
        ) == nil)
    }

    private func state(
        scheduleKey: String,
        phase: JourneyActivityAttributes.JourneyPhase
    ) -> JourneyActivityAttributes.ContentState {
        JourneyActivityAttributes.ContentState(
            fromCRS: "VIC",
            toCRS: "KTH",
            destinationTitle: "Kent House",
            arrivalLabel: nil,
            length: nil,
            platform: "TBC",
            estimated: "18:57",
            statusText: nil,
            delayMinutes: 0,
            scheduleKey: scheduleKey,
            journeyPhase: phase
        )
    }
}
