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

    @Test func scheduledCandidateExpiresAtTheCurrentWindowEnd() throws {
        let calendar = try londonCalendar()
        let route = leg(from: "VIC", to: "KTH", start: "16:00", end: "18:00")
        let subscription = scheduledSubscription(legs: [route])
        let end = try date(2026, 8, 24, 18, 0, calendar: calendar)
        #expect(NotificationScheduleActivationPolicy.activeWindowEnd(
            for: subscription, leg: route, now: end.addingTimeInterval(-1), calendar: calendar
        ) == end)
        for now in [end, end.addingTimeInterval(5 * 60)] {
            #expect(NotificationScheduleActivationPolicy.activeWindowEnd(
                for: subscription, leg: route, now: now, calendar: calendar
            ) == nil)
            #expect(!NotificationScheduleActivationPolicy.isActive(
                scheduleKind: .regular, daysOfWeek: [.mon], windowStart: "16:00",
                windowEnd: "18:00", travelDate: nil, now: now, calendar: calendar
            ))
        }
    }

    @Test func overnightCandidateExpiresOnTheFollowingDay() throws {
        let calendar = try londonCalendar()
        let route = leg(from: "VIC", to: "KTH", start: "23:30", end: "01:00")
        let subscription = scheduledSubscription(legs: [route])
        #expect(NotificationScheduleActivationPolicy.activeWindowEnd(
            for: subscription, leg: route,
            now: try date(2026, 8, 25, 0, 30, calendar: calendar), calendar: calendar
        ) == (try date(2026, 8, 25, 1, 0, calendar: calendar)))
    }

    @Test func lateDeliveryKeepsTheObservationInItsOriginalOccurrence() throws {
        let calendar = try londonCalendar()
        let route = leg(from: "VIC", to: "KTH", start: "16:00", end: "18:00")
        let subscription = scheduledSubscription(legs: [route])
        let observation = try date(2026, 8, 24, 17, 56, calendar: calendar)
        let delivery = try date(2026, 8, 24, 18, 0, calendar: calendar)
        let occurrence = try #require(NotificationScheduleActivationPolicy.recoverableWindow(
            for: subscription, leg: route, observedAt: observation, receivedAt: delivery, calendar: calendar
        ))
        #expect(occurrence.start == (try date(2026, 8, 24, 16, 0, calendar: calendar)))
        #expect(occurrence.end == delivery)
        #expect(NotificationScheduleActivationPolicy.recoverableWindow(
            for: subscription, leg: route, observedAt: delivery, receivedAt: delivery, calendar: calendar
        ) == nil)
    }

    @Test func recoveryRejectsExpiredEvidenceAndFutureClockErrors() throws {
        let calendar = try londonCalendar()
        let route = leg(from: "VIC", to: "KTH", start: "16:00", end: "18:00")
        let subscription = scheduledSubscription(legs: [route])
        let observation = try date(2026, 8, 24, 17, 56, calendar: calendar)
        #expect(NotificationScheduleActivationPolicy.recoverableWindow(
            for: subscription, leg: route, observedAt: observation,
            receivedAt: observation.addingTimeInterval(61 * 60), calendar: calendar
        ) == nil)
        #expect(NotificationScheduleActivationPolicy.recoverableWindow(
            for: subscription, leg: route, observedAt: observation,
            receivedAt: observation.addingTimeInterval(-1), calendar: calendar
        ) == nil)
    }

    @Test func aRecurringScheduleResolvesWeeksLaterWithoutPersistingDailyCandidates() throws {
        let calendar = try londonCalendar()
        let route = leg(from: "VIC", to: "KTH", start: "16:00", end: "18:00")
        let subscription = scheduledSubscription(legs: [route])
        let observation = try date(2026, 9, 14, 17, 0, calendar: calendar)
        let occurrence = try #require(NotificationScheduleActivationPolicy.activeWindow(
            for: subscription, leg: route, now: observation, calendar: calendar
        ))
        #expect(occurrence.start == (try date(2026, 9, 14, 16, 0, calendar: calendar)))
        #expect(occurrence.end == (try date(2026, 9, 14, 18, 0, calendar: calendar)))
    }

    @Test func downstreamRecoveryUsesTheRecentOccurrenceWithoutExtendingBoardingEligibility() throws {
        let calendar = try londonCalendar()
        let route = leg(from: "VIC", to: "KTH", start: "16:00", end: "18:00")
        let subscription = scheduledSubscription(legs: [route])
        let downstream = try date(2026, 8, 24, 18, 15, calendar: calendar)
        let end = try date(2026, 8, 24, 18, 0, calendar: calendar)
        #expect(NotificationScheduleActivationPolicy.windowForRouteRecovery(
            for: subscription, leg: route, observedAt: downstream, receivedAt: downstream, calendar: calendar
        )?.end == end)
        #expect(NotificationScheduleActivationPolicy.recoverableWindow(
            for: subscription, leg: route, observedAt: downstream, receivedAt: downstream, calendar: calendar
        ) == nil)
        #expect(NotificationScheduleActivationPolicy.windowForRouteRecovery(
            for: subscription, leg: route, observedAt: downstream,
            receivedAt: end.addingTimeInterval(60 * 60), calendar: calendar
        ) == nil)
        let beforeWindow = try date(2026, 8, 24, 15, 59, calendar: calendar)
        #expect(NotificationScheduleActivationPolicy.windowForRouteRecovery(
            for: subscription, leg: route, observedAt: beforeWindow, receivedAt: beforeWindow, calendar: calendar
        ) == nil)
    }

    @Test func aPreWindowVisitDoesNotBecomeAnEligibleArrivalByDelayedDelivery() throws {
        let calendar = try londonCalendar()
        let route = leg(from: "VIC", to: "KTH", start: "16:00", end: "18:00")
        let subscription = scheduledSubscription(legs: [route])
        #expect(NotificationScheduleActivationPolicy.recoverableWindow(
            for: subscription, leg: route,
            observedAt: try date(2026, 8, 24, 15, 55, calendar: calendar),
            receivedAt: try date(2026, 8, 24, 16, 5, calendar: calendar), calendar: calendar
        ) == nil)
    }

    @Test func recoveryGeometryUsesTheBranchContainingTheScheduledDestination() {
        let codes = ScheduledJourneyRecoveryGeometryPolicy.intermediateStationCodes(
            in: [["AAA", "BBB", "CCC"], ["AAA", "DDD", "EEE", "FFF", "ZZZ"]],
            from: "aaa", to: "zzz"
        )
        #expect(codes == ["DDD", "EEE"])
        #expect(ScheduledJourneyRecoveryGeometryPolicy.intermediateStationCodes(
            in: [["ZZZ", "DDD", "AAA"]], from: "AAA", to: "ZZZ"
        ) == nil)
    }

    @Test func overnightOneOffSurvivesUntilItsWindowEndsTheFollowingDay() throws {
        let calendar = try londonCalendar()
        var route = leg(from: "VIC", to: "KTH", start: "23:30", end: "01:00")
        route.travelDate = "2026-08-24"
        var subscription = scheduledSubscription(legs: [route])
        subscription.scheduleKind = .oneOff
        let observation = try date(2026, 8, 25, 0, 56, calendar: calendar)
        let delivery = try date(2026, 8, 25, 1, 3, calendar: calendar)
        #expect(NotificationScheduleExpiry.expirationDate(for: subscription, calendar: calendar)
            == (try date(2026, 8, 25, 1, 1, calendar: calendar)))
        #expect(!NotificationScheduleExpiry.isExpired(subscription, now: observation, calendar: calendar))
        #expect(NotificationScheduleActivationPolicy.recoverableWindow(
            for: subscription, leg: route, observedAt: observation, receivedAt: delivery, calendar: calendar
        )?.start == (try date(2026, 8, 24, 23, 30, calendar: calendar)))
    }

    @Test func aDirectCallingPatternNeedsOnlyTheDestinationSentinel() {
        #expect(ScheduledJourneyRecoveryGeometryPolicy.intermediateStationCodes(
            in: [["AAA", "ZZZ"]], from: "AAA", to: "ZZZ"
        ) == [])
    }

    @Test func dayWindowsRoundTripAndLegacyLegsKeepTheirDefaults() throws {
        let legacy = Data(#"{"from":"KTH","to":"VIC","enabled":true,"window_start":"07:00","window_end":"09:00"}"#.utf8)
        var route = try JSONDecoder().decode(NotificationLeg.self, from: legacy)
        #expect(route.dayWindows == nil)
        #expect(route.window(on: .sat).windowStart == "07:00")
        route.setWindow(NotificationTimeWindow(windowStart: "09:00", windowEnd: "11:00"), for: DayOfWeek.weekend)
        let data = try JSONEncoder().encode(route)
        #expect(try JSONDecoder().decode(NotificationLeg.self, from: data) == route)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let windows = try #require(json["day_windows"] as? [String: [String: String]])
        #expect(windows["sat"]?["window_start"] == "09:00")
    }

    @Test func weekdayWeekendAndCustomPatternsPreserveIndependentTimes() {
        var route = leg(from: "KTH", to: "VIC", start: "07:00", end: "09:00")
        #expect(NotificationWindowPattern.matching(legs: [route], days: DayOfWeek.allCases) == .same)
        route.setWindow(NotificationTimeWindow(windowStart: "09:00", windowEnd: "11:00"), for: DayOfWeek.weekend)
        #expect(NotificationWindowPattern.matching(legs: [route], days: DayOfWeek.allCases) == .split)
        #expect(route.windowLabel(for: DayOfWeek.allCases) == "Weekdays 07:00–09:00 · Weekends 09:00–11:00")
        route.setWindow(NotificationTimeWindow(windowStart: "08:15", windowEnd: "09:15"), for: [.wed])
        #expect(NotificationWindowPattern.matching(legs: [route], days: DayOfWeek.allCases) == .custom)
        #expect(route.window(on: .mon).windowStart == "07:00")
        #expect(route.window(on: .sun).windowStart == "09:00")
        #expect(route.window(on: .wed).windowStart == "08:15")
    }

    @Test func weekendActivationAndNextStartUseTheCorrectWindow() throws {
        let calendar = try londonCalendar()
        var route = leg(from: "KTH", to: "VIC", start: "07:00", end: "09:00")
        route.setWindow(NotificationTimeWindow(windowStart: "09:00", windowEnd: "11:00"), for: DayOfWeek.weekend)
        let subscription = scheduledSubscription(legs: [route], days: DayOfWeek.allCases)
        let saturdayEarly = try date(2026, 9, 5, 8, 0, calendar: calendar)
        let saturdayStart = try date(2026, 9, 5, 9, 0, calendar: calendar)
        let saturdayEnd = try date(2026, 9, 5, 11, 0, calendar: calendar)
        #expect(NotificationScheduleActivationPolicy.activeWindowEnd(for: subscription, leg: route, now: saturdayEarly, calendar: calendar) == nil)
        #expect(NotificationScheduleActivationPolicy.nextStart(for: subscription, leg: route, now: saturdayEarly, calendar: calendar) == saturdayStart)
        #expect(NotificationScheduleActivationPolicy.activeWindowEnd(for: subscription, leg: route, now: saturdayStart, calendar: calendar) == saturdayEnd)
        #expect(NotificationScheduleActivationPolicy.activeWindowEnd(for: subscription, leg: route, now: saturdayEnd, calendar: calendar) == nil)
        #expect(ScheduledJourneyActivationResolver.legs(for: subscription, matchingFrom: "KTH", to: "VIC", now: saturdayStart, calendar: calendar).count == 1)
        #expect(ScheduledJourneyActivationResolver.legs(for: subscription, matchingFrom: "KTH", to: "VIC", now: saturdayEarly, calendar: calendar).isEmpty)
        let weekdaysOnly = scheduledSubscription(legs: [route])
        #expect(NotificationScheduleActivationPolicy.activeWindowEnd(for: weekdaysOnly, leg: route, now: saturdayStart, calendar: calendar) == nil)
        #expect(JourneyUpdateSchedulePresentation.detail(for: route, subscription: subscription, scheduled: true) == "• Weekdays 07:00–09:00\n• Weekends 09:00–11:00")
    }

    @Test func friendlyDayLabelsDescribeTheActualSelection() {
        #expect(DayOfWeek.friendlyLabel(for: DayOfWeek.allCases) == "Every day")
        #expect(DayOfWeek.friendlyLabel(for: DayOfWeek.weekdays) == "Weekdays")
        #expect(DayOfWeek.friendlyLabel(for: DayOfWeek.weekend) == "Weekends")
        #expect(DayOfWeek.friendlyLabel(for: [.fri, .mon, .tue]) == "Monday, Tuesday and Friday")
        #expect(DayOfWeek.friendlyLabel(for: [.mon, .fri]) == "Monday and Friday")
        #expect(DayOfWeek.friendlyLabel(for: [.wed]) == "Wednesday")
    }

    @Test func reversingHeadingsKeepsEachSectionsScheduleInPlace() {
        var outbound = leg(from: "KTH", to: "VIC", start: "07:00", end: "12:00")
        outbound.setWindow(NotificationTimeWindow(windowStart: "09:00", windowEnd: "14:00"), for: DayOfWeek.weekend)
        outbound.travelDate = "2026-09-07"
        var inbound = leg(from: "VIC", to: "KTH", start: "16:00", end: "18:00")
        inbound.enabled = false
        inbound.travelDate = "2026-09-08"
        let original = [outbound, inbound]
        let reversed = NotificationScheduleEditing.reversingDirections(in: original, outboundLegCount: 1)
        #expect(reversed.map(\.id) == ["VIC->KTH", "KTH->VIC"])
        for (before, after) in zip(original, reversed) {
            #expect(before.windowStart == after.windowStart)
            #expect(before.windowEnd == after.windowEnd)
            #expect(before.dayWindows == after.dayWindows)
            #expect(before.enabled == after.enabled)
            #expect(before.travelDate == after.travelDate)
        }
        #expect(NotificationScheduleEditing.reversingDirections(in: reversed, outboundLegCount: 1) == original)
    }

    @Test func reversingMultiLegDirectionsKeepsConnectionsAndTimePositions() {
        let original = [
            leg(from: "KTH", to: "HNH", start: "07:00", end: "09:00"),
            leg(from: "HNH", to: "ZFD", start: "08:00", end: "10:00"),
            leg(from: "ZFD", to: "HNH", start: "16:00", end: "18:00"),
            leg(from: "HNH", to: "KTH", start: "17:00", end: "19:00")
        ]
        let reversed = NotificationScheduleEditing.reversingDirections(in: original, outboundLegCount: 2)
        #expect(reversed.map(\.id) == ["ZFD->HNH", "HNH->KTH", "KTH->HNH", "HNH->ZFD"])
        #expect(reversed.map(\.windowStart) == original.map(\.windowStart))
        #expect(NotificationScheduleEditing.reversingDirections(in: reversed, outboundLegCount: 2) == original)
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

    private func scheduledSubscription(legs: [NotificationLeg], days: [DayOfWeek] = [.mon]) -> NotificationSubscription {
        NotificationSubscription(
            id: "scheduled-return-test",
            deviceId: "device-1",
            routeKey: "KTH-VIC",
            scheduleKind: .regular,
            daysOfWeek: days,
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
