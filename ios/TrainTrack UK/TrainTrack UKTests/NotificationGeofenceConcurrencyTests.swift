import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct NotificationGeofenceConcurrencyTests {
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
