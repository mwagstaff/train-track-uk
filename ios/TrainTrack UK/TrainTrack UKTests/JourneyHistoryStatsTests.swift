import Foundation
import Testing
@testable import TrainTrack_UK

struct JourneyHistoryStatsTests {
    @Test @MainActor func recordsExcludeUnconfirmedArrivalsAndFilterWholeJourneysByOperator() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let origin = Station(crs: "AAA", name: "Origin", longitude: "0", latitude: "0")
        let destination = Station(crs: "BBB", name: "Destination", longitude: "0", latitude: "0")
        let legs = [("Operator A", 0), ("Operator B", 20)].enumerated().map { index, value in
            JourneyHistoryLeg(plannedLegIndex: index, fromStation: origin, toStation: destination,
                              operatorName: value.0, scheduledArrivalAt: date,
                              actualArrivalAt: date.addingTimeInterval(Double(value.1) * 60), outcome: .completed)
        }
        let checkpoint = ActiveJourneyHistoryCheckpoint(
            id: UUID(), subscriptionId: "stats-test", source: .adhoc,
            plannedStations: [origin, destination], createdAt: date, phase: .arriving,
            plannedLegIndex: 1, detectedDepartureAt: date, lastConfirmedOnRouteStation: destination,
            nextExpectedCallingPointIndex: 0, legs: legs, stationEvents: [], approachNotificationSent: false,
            serviceMatchConfidence: 1, updatedAt: date)
        let completed = JourneyHistoryRecord(checkpoint: checkpoint, outcome: .completed, completedAt: date)
        let incomplete = JourneyHistoryRecord(checkpoint: checkpoint, outcome: .endedEarly, completedAt: date)
        let pending = JourneyHistoryRecord(checkpoint: checkpoint, outcome: .completed, completedAt: date)
        incomplete.id = UUID()
        pending.id = UUID()
        pending.actualArrivalAt = nil
        pending.delayMinutes = nil
        pending.legsData = try JSONEncoder().encode([JourneyHistoryLeg]())
        let stats = JourneyHistoryStats(records: [completed, incomplete, pending])
        #expect(stats.samples.count == 1)
        #expect(stats.excludedCount == 2)
        #expect(stats.averageLateDelay == 20)
        #expect(stats.worst?.recordID == completed.id)
        #expect(stats.operatorShares.map(\.name) == ["Operator A", "Operator B"])
        #expect(stats.operatorShares.map(\.fraction) == [0.5, 0.5])
        #expect(stats.operatorShares.allSatisfy { $0.journeyIDs == [completed.id] })
        #expect(JourneyHistoryStats(records: [incomplete]).operatorShares.isEmpty)
        let other = JourneyHistoryRecord(checkpoint: checkpoint, outcome: .completed, completedAt: date)
        other.id = UUID()
        other.delayMinutes = 3
        let otherLeg = JourneyHistoryLeg(plannedLegIndex: 0, fromStation: origin, toStation: destination,
                                         operatorName: "Operator C", scheduledArrivalAt: date,
                                         actualArrivalAt: date.addingTimeInterval(180), outcome: .completed)
        other.legsData = try JSONEncoder().encode([otherLeg])
        let combinedRecords = [completed, other]
        let combined = JourneyHistoryStats(records: combinedRecords)
        let selection = try #require(combined.operatorShares.first { $0.name == "Operator C" })
        let filtered = JourneyHistoryStats(records: combinedRecords.filter { selection.journeyIDs.contains($0.id) })
        #expect(filtered.samples.count == 1)
        #expect(filtered.averageLateDelay == 3)
        #expect(filtered.worst?.recordID == other.id)
        #expect(filtered.distribution.map(\.count) == [0, 1, 0, 0, 0, 0])
        #expect(combined.samples.count == 2)
        completed.legsData = try JSONEncoder().encode([legs[0]])
        let singleOperator = JourneyHistoryStats(records: [completed])
        #expect(singleOperator.operatorShares.count == 1)
        #expect(singleOperator.operatorShares.first?.fraction == 1)
        completed.actualArrivalAt = nil
        completed.delayMinutes = nil
        #expect(JourneyHistoryStats(records: [completed]).operatorShares.first?.fraction == 1)

    }

    @Test func summariesAndDistributionUseConfirmedSampleDenominator() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let stats = JourneyHistoryStats(samples: [0, 0, 5, 15, 31].map {
            .init(date: date, delay: $0)
        }, totalCount: 7)
        #expect(stats.excludedCount == 2)
        #expect(stats.onTimeFraction == 0.4)
        #expect(stats.lateFraction == 0.6)
        #expect(stats.averageLateDelay == 17)
        #expect(stats.worst?.delay == 31)
        #expect(stats.distribution.map(\.count) == [2, 1, 0, 0, 1, 1])
        #expect(abs(stats.arrivals.reduce(0) { $0 + $1.fraction } - 1) < 0.000001)
        #expect(stats.arrivals.map(\.count) == [2, 1, 2])
    }

    @Test func emptyAndAllOnTimeHistoryDoNotInventDelays() {
        let empty = JourneyHistoryStats(samples: [], totalCount: 3)
        #expect(empty.onTimeFraction == 0)
        #expect(empty.averageLateDelay == 0)
        #expect(empty.worst == nil)
        #expect(empty.distribution.allSatisfy { $0.fraction == 0 })
        let onTime = JourneyHistoryStats(samples: [.init(date: Date(), delay: 0)], totalCount: 1)
        #expect(onTime.onTimeFraction == 1)
        #expect(onTime.lateCount == 0)
        #expect(onTime.averageLateDelay == 0)
    }

    @Test func delayBandsMatchHistoryAndHaveNoBoundaryGaps() {
        #expect(JourneyStatsArrivalBand.band(for: 0) == .onTime)
        #expect(JourneyStatsArrivalBand.band(for: 1) == .mild)
        #expect(JourneyStatsArrivalBand.band(for: 14) == .mild)
        #expect(JourneyStatsArrivalBand.band(for: 15) == .severe)
        let stats = JourneyHistoryStats(samples: (0...60).map { .init(date: Date(), delay: $0) }, totalCount: 61)
        #expect(stats.distribution.map(\.count) == [1, 5, 5, 4, 16, 30])
    }

    @Test func presetsUseCalendarDaysAcrossDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 30, hour: 14)))
        let start = try #require(JourneyStatsPeriod.week.startDate(now: now, calendar: calendar))
        #expect(calendar.component(.day, from: start) == 24)
        #expect(calendar.component(.hour, from: start) == 0)
        #expect(JourneyStatsPeriod.all.startDate(now: now, calendar: calendar) == nil)
    }

    @Test func arrivalBucketsAdaptToHistorySpanAndKeepGaps() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        for (days, unit) in [(3, Calendar.Component.day), (90, .weekOfYear), (800, .month)] {
            let end = try #require(calendar.date(byAdding: .day, value: days, to: start))
            let stats = JourneyHistoryStats(samples: [.init(date: start, delay: 0), .init(date: end, delay: 20)],
                                            totalCount: 2, calendar: calendar)
            #expect(stats.bucketUnit == unit)
            #expect(Set(stats.arrivals.map(\.date)).count == 2)
            #expect(stats.arrivals.reduce(0) { $0 + $1.count } == 2)
        }
    }
}
