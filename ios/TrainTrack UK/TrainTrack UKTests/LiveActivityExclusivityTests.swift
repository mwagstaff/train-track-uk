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

struct LiveActivityInProgressUpdatePolicyTests {
    @Test
    func staleLocalOnTimeResultDoesNotReplaceDelayedServerEstimate() {
        let current = state(
            estimated: "08:06",
            delayMinutes: 2,
            statusText: "Currently 3 minutes late",
            revision: 50
        )
        let candidate = state(
            estimated: "08:03",
            delayMinutes: 0,
            statusText: "Currently on time",
            revision: 50
        )

        let reconciled = LiveActivityInProgressUpdatePolicy.reconcilingLocalUpdate(
            candidate,
            with: current
        )

        #expect(reconciled.estimated == "08:06")
        #expect(reconciled.delayMinutes == 2)
        #expect(reconciled.statusText == "Currently 3 minutes late")
    }

    @Test
    func localRefreshCanReportAnIncreasingDelay() {
        let current = state(
            estimated: "08:06",
            delayMinutes: 2,
            statusText: "Currently 3 minutes late",
            revision: 50
        )
        let candidate = state(
            estimated: "08:09",
            delayMinutes: 5,
            statusText: "Currently 6 minutes late",
            revision: 50
        )

        let reconciled = LiveActivityInProgressUpdatePolicy.reconcilingLocalUpdate(
            candidate,
            with: current
        )

        #expect(reconciled.estimated == "08:09")
        #expect(reconciled.delayMinutes == 5)
        #expect(reconciled.statusText == "Currently 6 minutes late")
    }

    @Test
    func anUnconfirmedJourneyClearsTheNextTrainsDetailsDespiteItsServerRevision() {
        var current = state(estimated: "17:42", delayMinutes: 12, statusText: "Currently 12 minutes late", revision: 50)
        current.platform = "4"
        current.isCancelled = true
        current.upcomingDepartures = [.init(time: "17:57", delayMinutes: 0, isCancelled: false)]
        var candidate = current
        candidate.delayMinutes = 0
        let reconciled = LiveActivityInProgressUpdatePolicy.reconcilingLocalUpdate(
            candidate, with: current, serviceMatchConfirmed: false
        )
        #expect(reconciled.scheduledDeparture == nil)
        #expect(reconciled.arrivalLabel == nil)
        #expect(reconciled.length == nil)
        #expect(reconciled.platform == "TBC")
        #expect(reconciled.estimated == "—")
        #expect(reconciled.statusText == "Train not yet confirmed")
        #expect(!reconciled.isCancelled)
        #expect(reconciled.delayMinutes == 0)
        #expect(reconciled.arrivalDelayMinutes == nil)
        #expect(reconciled.upcomingDepartures.isEmpty)
        #expect(reconciled.journeyPhase == .enRoute)
    }

    @Test
    func anUnconfirmedTrainPreservesTheConfirmedDeviceArrival() {
        let current = state(estimated: "18:10", delayMinutes: 20, statusText: "Delayed", revision: 50)
        var arrived = current
        arrived.journeyPhase = .arrived
        arrived.arrivalDelayMinutes = 20
        let reconciled = LiveActivityInProgressUpdatePolicy.reconcilingLocalUpdate(
            arrived, with: current, serviceMatchConfirmed: false, confirmedArrivalTime: "17:52"
        )
        #expect(reconciled.journeyPhase == .arrived)
        #expect(reconciled.estimated == "17:52")
        #expect(reconciled.scheduledDeparture == nil)
        #expect(reconciled.statusText == nil)
        #expect(reconciled.arrivalDelayMinutes == nil)
        #expect(reconciled.delayMinutes == 0)
    }

    @Test
    func anUnconfirmedArrivalCannotReuseTheNextTrainsEstimatedTime() {
        var arrived = state(estimated: "18:10", delayMinutes: 20, statusText: "Delayed", revision: 50)
        arrived.journeyPhase = .arrived
        let reconciled = LiveActivityInProgressUpdatePolicy.reconcilingLocalUpdate(
            arrived, with: arrived, serviceMatchConfirmed: false
        )
        #expect(reconciled.estimated == "—")
        #expect(reconciled.arrivalLabel == nil)
    }

    @Test
    func aBoardBeforeBoardingStillShowsItsDeparture() {
        var board = state(estimated: "17:42", delayMinutes: 0, statusText: "On time", revision: 50)
        board.journeyPhase = .atStart
        let reconciled = LiveActivityInProgressUpdatePolicy.reconcilingLocalUpdate(
            board, with: board, serviceMatchConfirmed: false
        )
        #expect(reconciled == board)
    }

    private func state(
        estimated: String,
        delayMinutes: Int,
        statusText: String,
        revision: Int?
    ) -> JourneyActivityAttributes.ContentState {
        JourneyActivityAttributes.ContentState(
            fromCRS: "KTH",
            toCRS: "VIC",
            destinationTitle: "London Victoria",
            arrivalLabel: "Departed 07:44",
            scheduledDeparture: "07:42",
            length: 8,
            platform: "TBC",
            estimated: estimated,
            statusText: statusText,
            delayMinutes: delayMinutes,
            revision: revision,
            journeyPhase: .enRoute
        )
    }
}

struct JourneyActivityLifecycleStoreTests {
    @Test
    func remoteStartCanSeedDismissalStateBeforeTheAppDiscoversTheActivity() {
        let suiteName = "JourneyActivityLifecycleStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let startedAt = Date().addingTimeInterval(-60)

        JourneyActivityLifecycleStore.seedPendingRemoteStart(
            scheduleKey: "VIC-KTH|16:30|20:30|2026-09-13",
            fromCRS: "VIC",
            toCRS: "KTH",
            startedAt: startedAt,
            defaults: defaults
        )

        let record = JourneyActivityLifecycleStore.record(
            scheduleKey: "VIC-KTH|16:30|20:30|2026-09-13",
            defaults: defaults
        )
        #expect(record?.phase == .pendingStart)
        #expect(record?.fromCRS == "VIC")
        #expect(record?.toCRS == "KTH")
        #expect(record?.updatedAt == startedAt)
    }

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
