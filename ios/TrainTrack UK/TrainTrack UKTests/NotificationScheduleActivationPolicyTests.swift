import Foundation
import Testing
@testable import TrainTrack_UK

struct NotificationScheduleActivationPolicyTests {
    @Test func regularScheduleIsActiveOnlyOnSelectedDayAndWindow() throws {
        let calendar = try londonCalendar()
        let monday = try date(2026, 8, 24, 8, 30, calendar: calendar)
        let tuesday = try date(2026, 8, 25, 8, 30, calendar: calendar)

        #expect(NotificationScheduleActivationPolicy.isActive(
            scheduleKind: .regular,
            daysOfWeek: [.mon],
            windowStart: "08:00",
            windowEnd: "09:00",
            travelDate: nil,
            now: monday,
            calendar: calendar
        ))
        #expect(!NotificationScheduleActivationPolicy.isActive(
            scheduleKind: .regular,
            daysOfWeek: [.mon],
            windowStart: "08:00",
            windowEnd: "09:00",
            travelDate: nil,
            now: tuesday,
            calendar: calendar
        ))
    }

    @Test func overnightWindowCarriesIntoFollowingDay() throws {
        let calendar = try londonCalendar()
        let earlyTuesday = try date(2026, 8, 25, 0, 30, calendar: calendar)

        #expect(NotificationScheduleActivationPolicy.isActive(
            scheduleKind: .regular,
            daysOfWeek: [.mon],
            windowStart: "23:30",
            windowEnd: "01:00",
            travelDate: nil,
            now: earlyTuesday,
            calendar: calendar
        ))
    }

    @Test func oneOffScheduleUsesItsTravelDate() throws {
        let calendar = try londonCalendar()
        let travelTime = try date(2026, 8, 24, 14, 15, calendar: calendar)
        let followingDay = try date(2026, 8, 25, 14, 15, calendar: calendar)

        #expect(NotificationScheduleActivationPolicy.isActive(
            scheduleKind: .oneOff,
            daysOfWeek: [],
            windowStart: "14:00",
            windowEnd: "15:00",
            travelDate: "2026-08-24",
            now: travelTime,
            calendar: calendar
        ))
        #expect(!NotificationScheduleActivationPolicy.isActive(
            scheduleKind: .oneOff,
            daysOfWeek: [],
            windowStart: "14:00",
            windowEnd: "15:00",
            travelDate: "2026-08-24",
            now: followingDay,
            calendar: calendar
        ))
    }

    @Test func scheduledReturnActivationUsesTheReturnDirection() throws {
        let calendar = try londonCalendar()
        let now = try date(2026, 8, 24, 17, 6, calendar: calendar)
        let subscription = scheduledSubscription(legs: [
            leg(from: "KTH", to: "VIC", start: "06:00", end: "08:00"),
            leg(from: "VIC", to: "KTH", start: "16:00", end: "18:00")
        ])

        let legs = ScheduledJourneyActivationResolver.legs(
            for: subscription,
            matchingFrom: "VIC",
            to: "KTH",
            now: now,
            calendar: calendar
        )

        #expect(legs.map { "\($0.from)-\($0.to)" } == ["VIC-KTH"])
    }

    @Test func scheduledMultiLegReturnActivationKeepsOnlyTheReturnJourney() throws {
        let calendar = try londonCalendar()
        let now = try date(2026, 8, 24, 17, 6, calendar: calendar)
        let subscription = scheduledSubscription(legs: [
            leg(from: "KTH", to: "HNH", start: "06:00", end: "08:00"),
            leg(from: "HNH", to: "ZFD", start: "06:00", end: "08:00"),
            leg(from: "ZFD", to: "HNH", start: "16:00", end: "18:00"),
            leg(from: "HNH", to: "KTH", start: "16:00", end: "18:00")
        ])

        let legs = ScheduledJourneyActivationResolver.legs(
            for: subscription,
            matchingFrom: "ZFD",
            to: "HNH",
            now: now,
            calendar: calendar
        )

        #expect(legs.map { "\($0.from)-\($0.to)" } == ["ZFD-HNH", "HNH-KTH"])
    }

    private func londonCalendar() throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        calendar: Calendar
    ) throws -> Date {
        try #require(calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )))
    }

    private func leg(from: String, to: String, start: String, end: String) -> NotificationLeg {
        NotificationLeg(
            from: from,
            to: to,
            fromName: from,
            toName: to,
            enabled: true,
            windowStart: start,
            windowEnd: end
        )
    }

    private func scheduledSubscription(legs: [NotificationLeg]) -> NotificationSubscription {
        NotificationSubscription(
            id: "scheduled-return-test",
            deviceId: "device-1",
            routeKey: "KTH-VIC",
            scheduleKind: .regular,
            daysOfWeek: [.mon],
            notificationTypes: [.delays],
            legs: legs,
            muteOnArrival: true,
            source: .scheduled,
            liveSessionOrigin: nil,
            activeUntil: nil,
            mutedByLegDay: nil,
            mutedAtByLegDay: nil,
            createdAt: nil,
            updatedAt: nil
        )
    }
}
