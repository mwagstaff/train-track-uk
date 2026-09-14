import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct NotificationGeofenceConcurrencyTests {
    @Test func explicitJourneyPreparesBackgroundSessionBeforeLeavingForeground() {
        #expect(BackgroundActivitySessionPolicy.shouldRetainSession(
            hasActiveGeofences: true,
            hasExplicitJourneyTarget: true,
            isHighSensitivityTracking: false,
            usesWhenInUseAuthorization: false
        ))
        #expect(BackgroundActivitySessionPolicy.canCreateSession(
            applicationIsActive: true,
            hasOutstandingSession: false
        ))
    }

    @Test func scheduledGeofencesDoNotKeepBackgroundSessionAlive() {
        #expect(!BackgroundActivitySessionPolicy.shouldRetainSession(
            hasActiveGeofences: true,
            hasExplicitJourneyTarget: false,
            isHighSensitivityTracking: false,
            usesWhenInUseAuthorization: false
        ))
    }

    @Test func backgroundCanOnlyRejoinAnOutstandingSession() {
        #expect(!BackgroundActivitySessionPolicy.canCreateSession(
            applicationIsActive: false,
            hasOutstandingSession: false
        ))
        #expect(BackgroundActivitySessionPolicy.canCreateSession(
            applicationIsActive: false,
            hasOutstandingSession: true
        ))
    }

    @Test func scheduledGeofenceCannotDetectDepartureAfterWindowEnds() throws {
        let now = Date()
        var calendar = Calendar.current
        calendar.timeZone = .current
        let start = calendar.startOfDay(for: now)
        let end = try #require(calendar.date(bySettingHour: 18, minute: 0, second: 0, of: start))
        let target = StationArrivalTarget(
            identifier: "scheduled", subscriptionId: "scheduled", from: "VIC", to: "KTH",
            station: Station(crs: "VIC", name: "Victoria", longitude: "0", latitude: "0"),
            activeUntil: nil, muteOnArrival: true, isScheduledActivation: true,
            scheduleKind: .regular, daysOfWeek: [.mon, .tue, .wed, .thu, .fri, .sat, .sun],
            windowStart: "16:00", windowEnd: "18:00", travelDate: nil
        )
        #expect(target.isActive(at: end.addingTimeInterval(-1)))
        #expect(!target.isActive(at: end))
        #expect(!target.isActive(at: end.addingTimeInterval(5 * 60)))
    }

    @Test func stationDepartureOwnershipSeparatesSubscriptionsForTheSameRoute() {
        #expect(NotificationMuteStorage.pendingStationDepartureOwnerMatches(
            recordedSubscriptionId: "ad-hoc",
            requestedSubscriptionId: "ad-hoc"
        ))
        #expect(!NotificationMuteStorage.pendingStationDepartureOwnerMatches(
            recordedSubscriptionId: "ad-hoc",
            requestedSubscriptionId: "scheduled"
        ))
        #expect(NotificationMuteStorage.pendingStationDepartureOwnerMatches(
            recordedSubscriptionId: nil,
            requestedSubscriptionId: "scheduled"
        ))
    }

    @Test func singleFlightSharesAnInProgressOperation() async {
        let singleFlight = AsyncSingleFlight<Int>()
        var invocationCount = 0

        let first = Task { @MainActor in
            await singleFlight.run {
                invocationCount += 1
                try? await Task.sleep(for: .milliseconds(75))
                return 42
            }
        }
        while invocationCount == 0 {
            await Task.yield()
        }

        let second = Task { @MainActor in
            await singleFlight.run {
                invocationCount += 1
                return 99
            }
        }

        let firstValue = await first.value
        let secondValue = await second.value
        #expect(firstValue == 42)
        #expect(secondValue == 42)
        #expect(invocationCount == 1)
    }

    @Test func monitorOperationsNeverOverlap() async {
        let serialiser = AsyncOperationSerialiser()
        var activeOperationCount = 0
        var maximumActiveOperationCount = 0
        var events: [String] = []

        let first = Task { @MainActor in
            await serialiser.run {
                activeOperationCount += 1
                maximumActiveOperationCount = max(maximumActiveOperationCount, activeOperationCount)
                events.append("first-start")
                try? await Task.sleep(for: .milliseconds(75))
                events.append("first-end")
                activeOperationCount -= 1
            }
        }
        while events.isEmpty {
            await Task.yield()
        }

        let second = Task { @MainActor in
            await serialiser.run {
                activeOperationCount += 1
                maximumActiveOperationCount = max(maximumActiveOperationCount, activeOperationCount)
                events.append("second-start")
                events.append("second-end")
                activeOperationCount -= 1
            }
        }

        await first.value
        await second.value
        #expect(maximumActiveOperationCount == 1)
        #expect(events == ["first-start", "first-end", "second-start", "second-end"])
    }
}
