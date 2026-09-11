import Testing
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
