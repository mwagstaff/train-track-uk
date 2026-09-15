import AppIntents
import Foundation
import Testing
@testable import TrainTrack_UK

struct SiriIntentTests {
    @Test func coreActionExecutionPoliciesAllowBackgroundAndLockedUse() {
        #expect(!GetNextFavouriteTrainIntent.openAppWhenRun)
        #expect(!GetNextTrainsForSavedRouteIntent.openAppWhenRun)
        #expect(!GetNextDeparturesIntent.openAppWhenRun)
        #expect(!GetTrackedJourneyStatusIntent.openAppWhenRun)
        #expect(!GetTrackedTrainPlatformIntent.openAppWhenRun)

        #expect(GetNextFavouriteTrainIntent.authenticationPolicy == .alwaysAllowed)
        #expect(GetNextTrainsForSavedRouteIntent.authenticationPolicy == .alwaysAllowed)
        #expect(GetNextDeparturesIntent.authenticationPolicy == .alwaysAllowed)
        #expect(GetTrackedJourneyStatusIntent.authenticationPolicy == .alwaysAllowed)
        #expect(GetTrackedTrainPlatformIntent.authenticationPolicy == .alwaysAllowed)

        if #available(iOS 26.0, *) {
            #expect(GetNextFavouriteTrainIntent.supportedModes == .background)
            #expect(GetNextTrainsForSavedRouteIntent.supportedModes == .background)
            #expect(GetNextDeparturesIntent.supportedModes == .background)
            #expect(GetTrackedJourneyStatusIntent.supportedModes == .background)
            #expect(GetTrackedTrainPlatformIntent.supportedModes == .background)
        }
    }

    @Test func coreAppShortcutsStayWithinThePlatformLimit() {
        #expect(TrainTrackShortcuts.appShortcuts.count == 5)
    }

    @Test func structuredDeparturePreservesIdentityAndUnknownValues() {
        let scheduled = Date(timeIntervalSince1970: 1_789_458_120)
        var departure = SiriDeparture(
            id: "provider-service|operating-date-unknown|KTH|VIC",
            originCRS: "KTH",
            originName: "Kent House",
            destinationCRS: "VIC",
            destinationName: "London Victoria",
            serviceID: "provider-service",
            operatingDate: nil,
            scheduledDeparture: scheduled,
            expectedDeparture: nil,
            platform: nil,
            statusLabel: "Delayed without an estimate",
            transportLabel: "Replacement bus",
            freshnessLabel: "Upstream freshness unknown",
            timingUncertain: true
        )

        let entity = DepartureEntity(departure: departure)

        #expect(entity.id == departure.id)
        #expect(entity.serviceID == departure.serviceID)
        #expect(entity.originCRS == "KTH")
        #expect(entity.destinationCRS == "VIC")
        #expect(entity.operatingDate == nil)
        #expect(entity.scheduledDeparture == scheduled)
        #expect(entity.expectedDeparture == nil)
        #expect(entity.platform == nil)
        #expect(entity.status == departure.statusLabel)
        #expect(entity.transport == "Replacement bus")
        #expect(entity.freshness == "Upstream freshness unknown")
        #expect(entity.timingUncertain)
        #expect(entity.providerObservedAt == nil)
        #expect(entity.backendSnapshotAt == nil)
        #expect(entity.clientFetchedAt == nil)

        // These clocks describe different stages; never replace all three with fetch time.
        departure.providerObservedAt = scheduled.addingTimeInterval(-50)
        departure.backendSnapshotAt = scheduled.addingTimeInterval(-30)
        departure.clientFetchedAt = scheduled.addingTimeInterval(-10)
        let timestampedEntity = DepartureEntity(departure: departure)
        #expect(timestampedEntity.providerObservedAt == scheduled.addingTimeInterval(-50))
        #expect(timestampedEntity.backendSnapshotAt == scheduled.addingTimeInterval(-30))
        #expect(timestampedEntity.clientFetchedAt == scheduled.addingTimeInterval(-10))
    }
}
