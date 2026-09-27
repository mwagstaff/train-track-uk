import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct WatchJourneyBridgeTests {
    private func checkpoint() -> ActiveJourneyHistoryCheckpoint {
        let stations = [Station(crs: "KTH", name: "Kent House", longitude: "0", latitude: "0"),
                        Station(crs: "VIC", name: "London Victoria", longitude: "0", latitude: "0"),
                        Station(crs: "BTN", name: "Brighton", longitude: "0", latitude: "0")]
        let now = Date()
        return ActiveJourneyHistoryCheckpoint(
            id: UUID(), subscriptionId: "watch-test", source: .adhoc, plannedStations: stations, createdAt: now,
            phase: .inTransit, plannedLegIndex: 0, detectedDepartureAt: now,
            lastConfirmedOnRouteStation: stations[0], nextExpectedCallingPointIndex: 1,
            legs: [JourneyHistoryLeg(plannedLegIndex: 0, fromStation: stations[0], toStation: stations[1],
                                    detectedDepartureAt: now, outcome: .active)],
            stationEvents: [], approachNotificationSent: false, serviceMatchConfidence: 0, updatedAt: now
        )
    }

    @Test func watchActionsFollowCurrentLegAndInterchange() {
        var active = checkpoint()
        let underway = WatchJourneyBridge.snapshot(active)
        #expect(underway.arrivalAction == "I’ve arrived at London Victoria")
        #expect(underway.serviceAction == "Change the train I’m on")
        #expect(underway.nextDepartureRoute?.origin.crs == "VIC")
        active.phase = .atInterchange
        let interchange = WatchJourneyBridge.snapshot(active)
        #expect(interchange.arrivalAction == nil)
        #expect(interchange.serviceAction == "Choose my next train")
        let oldArrival = WatchJourneyCommand(requestID: UUID(), journeyID: underway.id, context: underway.context, action: .arrive)
        #expect(!oldArrival.matches(interchange))
        let complete = WatchJourneyBridge.snapshot(active, completed: true)
        #expect(complete.isComplete)
        #expect(complete.arrivalAction == nil && complete.serviceAction == nil)
    }

    @Test func oldJourneyCommandDoesNotMutateTracker() async {
        let before = JourneyTrackingCoordinator.shared.activeJourney
        let command = WatchJourneyCommand(requestID: UUID(), journeyID: "nonexistent-test-journey", context: "old", action: .arrive)
        do {
            try await WatchJourneyBridge.perform(command)
            Issue.record("An obsolete command must be rejected")
        } catch {
            #expect(error.localizedDescription.contains("changed"))
        }
        #expect(JourneyTrackingCoordinator.shared.activeJourney == before)
    }
}
