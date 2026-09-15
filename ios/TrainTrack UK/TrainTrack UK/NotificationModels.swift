import Foundation

enum NotificationSubscriptionSource: String, Codable {
    case scheduled
    case liveSession = "live_session"
}

enum NotificationScheduleKind: String, Codable, CaseIterable, Identifiable {
    case regular
    case oneOff = "one_off"

    var id: Self { self }

    var displayName: String {
        switch self {
        case .regular: return "Regular"
        case .oneOff: return "One-off"
        }
    }
}

enum NotificationLiveSessionOrigin: String, Codable {
    case manual
    case scheduled
}

enum NotificationType: String, CaseIterable, Codable, Identifiable {
    case summary
    case delays
    case platform

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .summary: return "Service status summary at start time"
        case .delays: return "Delays or cancellations"
        case .platform: return "Platform updates"
        }
    }
}

enum NotificationPreferences {
    static let store: UserDefaults = .standard
    static let summaryKey = "notificationPreferences.summary"
    static let delaysKey = "notificationPreferences.delays"
    static let platformKey = "notificationPreferences.platform"

    static func selectedTypes() -> [NotificationType] {
        let selected = NotificationType.allCases.filter { isEnabled($0) }
        return selected.isEmpty ? NotificationType.allCases : selected
    }

    static func effectiveTypes(for source: NotificationSubscriptionSource) -> [NotificationType] {
        selectedTypes().filter { type in
            switch (source, type) {
            case (.liveSession, .summary):
                return false
            default:
                return true
            }
        }
    }

    static func isEnabled(_ type: NotificationType) -> Bool {
        let key = storageKey(for: type)
        if store.object(forKey: key) == nil {
            return true
        }
        return store.bool(forKey: key)
    }

    static func storageKey(for type: NotificationType) -> String {
        switch type {
        case .summary:
            return summaryKey
        case .delays:
            return delaysKey
        case .platform:
            return platformKey
        }
    }
}

enum DayOfWeek: String, CaseIterable, Codable, Identifiable {
    case mon, tue, wed, thu, fri, sat, sun

    var id: String { rawValue }

    static let weekdays: [DayOfWeek] = [.mon, .tue, .wed, .thu, .fri]
    static let weekend: [DayOfWeek] = [.sat, .sun]

    var fullLabel: String {
        switch self {
        case .mon: return "Monday"
        case .tue: return "Tuesday"
        case .wed: return "Wednesday"
        case .thu: return "Thursday"
        case .fri: return "Friday"
        case .sat: return "Saturday"
        case .sun: return "Sunday"
        }
    }

    static func friendlyLabel(for days: [DayOfWeek]) -> String {
        let ordered = allCases.filter(Set(days).contains)
        if ordered == allCases { return "Every day" }
        if ordered == weekdays { return "Weekdays" }
        if ordered == weekend { return "Weekends" }
        let names = ordered.map(\.fullLabel)
        guard let last = names.last else { return "No days selected" }
        if names.count == 1 { return last }
        return "\(names.dropLast().joined(separator: ", ")) and \(last)"
    }

    var shortLabel: String {
        switch self {
        case .mon: return "Mon"
        case .tue: return "Tue"
        case .wed: return "Wed"
        case .thu: return "Thu"
        case .fri: return "Fri"
        case .sat: return "Sat"
        case .sun: return "Sun"
        }
    }
}

struct NotificationTimeWindow: Codable, Hashable {
    var windowStart: String
    var windowEnd: String

    enum CodingKeys: String, CodingKey {
        case windowStart = "window_start"
        case windowEnd = "window_end"
    }
}

enum NotificationWindowPattern: String, CaseIterable, Identifiable {
    case same = "Same times every day"
    case split = "Weekdays & weekends"
    case custom = "Custom per day"

    var id: Self { self }

    var dayGroups: [[DayOfWeek]] {
        switch self {
        case .same: return [DayOfWeek.allCases]
        case .split: return [DayOfWeek.weekdays, DayOfWeek.weekend]
        case .custom: return DayOfWeek.allCases.map { [$0] }
        }
    }

    static func matching(legs: [NotificationLeg], days: [DayOfWeek]) -> Self {
        for pattern in [Self.same, .split] {
            if legs.allSatisfy({ leg in
                pattern.dayGroups.allSatisfy { group in
                    Set(group.filter(days.contains).map { leg.window(on: $0) }).count <= 1
                }
            }) { return pattern }
        }
        return .custom
    }
}

struct NotificationLeg: Codable, Identifiable, Hashable {
    let from: String
    let to: String
    let fromName: String?
    let toName: String?
    var enabled: Bool
    var windowStart: String
    var windowEnd: String
    var travelDate: String? = nil
    var dayWindows: [String: NotificationTimeWindow]? = nil

    var id: String { "\(from)->\(to)" }

    enum CodingKeys: String, CodingKey {
        case from
        case to
        case fromName = "from_name"
        case toName = "to_name"
        case enabled
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case travelDate = "travel_date"
        case dayWindows = "day_windows"
    }

    func window(on day: DayOfWeek) -> NotificationTimeWindow {
        dayWindows?[day.rawValue]
            ?? NotificationTimeWindow(windowStart: windowStart, windowEnd: windowEnd)
    }

    mutating func setWindow(_ window: NotificationTimeWindow, for days: [DayOfWeek]) {
        for day in days {
            if dayWindows == nil { dayWindows = [:] }
            dayWindows?[day.rawValue] = window
        }
    }

    func windowGroups(for days: [DayOfWeek]) -> [(days: [DayOfWeek], window: NotificationTimeWindow)] {
        var groups: [(days: [DayOfWeek], window: NotificationTimeWindow)] = []
        for day in DayOfWeek.allCases where days.contains(day) {
            let window = window(on: day)
            if let index = groups.firstIndex(where: { $0.window == window }) {
                groups[index].days.append(day)
            } else {
                groups.append(([day], window))
            }
        }
        return groups
    }

    func windowLabel(for days: [DayOfWeek]) -> String {
        windowGroups(for: days).map { group in
            let label: String
            if group.days == DayOfWeek.allCases { label = "Every day" }
            else if group.days == DayOfWeek.weekdays { label = "Weekdays" }
            else if group.days == DayOfWeek.weekend { label = "Weekends" }
            else { label = group.days.map(\.shortLabel).joined(separator: ", ") }
            return "\(label) \(group.window.windowStart)–\(group.window.windowEnd)"
        }.joined(separator: " · ")
    }
}

enum NotificationScheduleEditing {
    /// Reverse each direction's route while keeping the schedule attached to its form position.
    static func reversingDirections(in legs: [NotificationLeg], outboundLegCount: Int) -> [NotificationLeg] {
        let split = min(max(outboundLegCount, 0), legs.count)
        return [Array(legs.prefix(split)), Array(legs.dropFirst(split))].flatMap { direction in
            zip(direction, direction.reversed()).map { schedule, route in
                NotificationLeg(
                    from: route.to,
                    to: route.from,
                    fromName: route.toName,
                    toName: route.fromName,
                    enabled: schedule.enabled,
                    windowStart: schedule.windowStart,
                    windowEnd: schedule.windowEnd,
                    travelDate: schedule.travelDate,
                    dayWindows: schedule.dayWindows
                )
            }
        }
    }
}

struct NotificationSubscription: Codable, Identifiable, Hashable {
    let id: String
    let deviceId: String
    let routeKey: String
    var scheduleKind: NotificationScheduleKind? = nil
    let daysOfWeek: [DayOfWeek]
    let notificationTypes: [NotificationType]
    let legs: [NotificationLeg]
    let muteOnArrival: Bool?
    let source: NotificationSubscriptionSource?
    let liveSessionOrigin: NotificationLiveSessionOrigin?
    let activeUntil: Date?
    let mutedByLegDay: [String: String]?
    let mutedAtByLegDay: [String: String]?
    let createdAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case deviceId = "device_id"
        case routeKey = "route_key"
        case scheduleKind = "schedule_type"
        case daysOfWeek = "days_of_week"
        case notificationTypes = "notification_types"
        case legs
        case muteOnArrival = "mute_on_arrival"
        case source
        case liveSessionOrigin = "live_session_origin"
        case activeUntil = "active_until"
        case mutedByLegDay = "muted_by_leg_day"
        case mutedAtByLegDay = "muted_at_by_leg_day"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var routeTitle: String {
        guard let first = legs.first, let last = legs.last else { return routeKey }
        let from = first.fromName ?? first.from
        let to = last.toName ?? last.to
        if legs.count <= 1 {
            return "\(from) → \(to)"
        }
        let via = legs.dropLast().map { $0.toName ?? $0.to }
        return "\(from) → \(to) via \(via.joined(separator: ", "))"
    }

    var daysLabel: String {
        if scheduleKind == .oneOff {
            let dates = legs.compactMap(\.travelDate)
            guard let first = dates.first else { return "One-off" }
            if let last = dates.last, last != first {
                return "\(formattedTravelDate(first)) – \(formattedTravelDate(last))"
            }
            return formattedTravelDate(first)
        }
        let labels = daysOfWeek.map { $0.shortLabel }
        return labels.joined(separator: ", ")
    }

    private func formattedTravelDate(_ value: String) -> String {
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: value) else { return value }

        let output = DateFormatter()
        output.dateStyle = .medium
        output.timeStyle = .none
        return output.string(from: date)
    }

    var windowLabel: String {
        let enabledLegs = legs.filter { $0.enabled }
        guard !enabledLegs.isEmpty else { return "No window" }
        if scheduleKind != .oneOff, enabledLegs.contains(where: { !($0.dayWindows ?? [:]).isEmpty }) {
            return enabledLegs.map { $0.windowLabel(for: daysOfWeek) }.joined(separator: " / ")
        }
        if enabledLegs.count == 1, let leg = enabledLegs.first {
            return "\(leg.windowStart)–\(leg.windowEnd)"
        }
        let parts = enabledLegs.map { "\($0.windowStart)–\($0.windowEnd)" }
        return parts.joined(separator: " / ")
    }

    var typeLabel: String {
        guard !notificationTypes.isEmpty else { return "No active alerts" }
        let labels = notificationTypes.map { type in
            switch type {
            case .summary: return "Summary"
            case .delays: return "Delays"
            case .platform: return "Platform"
            }
        }
        return labels.joined(separator: ", ")
    }
}

enum NotificationScheduleExpiry {
    static func expirationDate(
        for subscription: NotificationSubscription,
        calendar: Calendar = .current
    ) -> Date? {
        guard subscription.scheduleKind == .oneOff else { return nil }
        return subscription.legs
            .filter(\.enabled)
            .compactMap { leg in
                guard let travelDate = leg.travelDate,
                      var components = dateComponents(from: travelDate),
                      let time = timeComponents(from: leg.windowEnd) else {
                    return nil
                }
                components.hour = time.hour
                components.minute = time.minute
                guard var windowEnd = calendar.date(from: components) else { return nil }
                if let start = timeComponents(from: leg.windowStart),
                   time.hour * 60 + time.minute < start.hour * 60 + start.minute {
                    guard let followingDay = calendar.date(byAdding: .day, value: 1, to: windowEnd) else { return nil }
                    windowEnd = followingDay
                }
                return calendar.date(byAdding: .minute, value: 1, to: windowEnd)
            }
            .max()
    }

    static func isExpired(
        _ subscription: NotificationSubscription,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let expirationDate = expirationDate(for: subscription, calendar: calendar) else {
            return false
        }
        return expirationDate <= now
    }

    private static func timeComponents(from value: String) -> (hour: Int, minute: Int)? {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }

    private static func dateComponents(from value: String) -> DateComponents? {
        let parts = value.split(separator: "-", maxSplits: 2)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        return DateComponents(year: year, month: month, day: day)
    }
}

enum NotificationScheduleActivationPolicy {
    static func isActive(
        scheduleKind: NotificationScheduleKind?,
        daysOfWeek: [DayOfWeek],
        windowStart: String,
        windowEnd: String,
        travelDate: String?,
        dayWindows: [String: NotificationTimeWindow]? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        activationIntervals(
            scheduleKind: scheduleKind,
            daysOfWeek: daysOfWeek,
            windowStart: windowStart,
            windowEnd: windowEnd,
            travelDate: travelDate,
            dayWindows: dayWindows,
            around: now,
            calendar: calendar
        ).contains { $0.start <= now && now < $0.end }
    }

    static func activeWindowEnd(
        for subscription: NotificationSubscription,
        leg: NotificationLeg,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        activeWindow(for: subscription, leg: leg, now: now, calendar: calendar)?.end
    }

    /// Resolve the dated occurrence at the observation time, which may precede delivery.
    static func activeWindow(
        for subscription: NotificationSubscription,
        leg: NotificationLeg,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DateInterval? {
        activeWindow(
            scheduleKind: subscription.scheduleKind,
            daysOfWeek: subscription.daysOfWeek,
            windowStart: leg.windowStart,
            windowEnd: leg.windowEnd,
            travelDate: leg.travelDate,
            dayWindows: leg.dayWindows,
            now: now,
            calendar: calendar
        )
    }

    static func activeWindow(
        scheduleKind: NotificationScheduleKind?,
        daysOfWeek: [DayOfWeek],
        windowStart: String,
        windowEnd: String,
        travelDate: String?,
        dayWindows: [String: NotificationTimeWindow]? = nil,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> DateInterval? {
        activationIntervals(
            scheduleKind: scheduleKind,
            daysOfWeek: daysOfWeek,
            windowStart: windowStart,
            windowEnd: windowEnd,
            travelDate: travelDate,
            dayWindows: dayWindows,
            around: now,
            calendar: calendar
        ).first { $0.start <= now && now < $0.end }
    }

    static func recoverableWindow(
        for subscription: NotificationSubscription,
        leg: NotificationLeg,
        observedAt: Date,
        receivedAt: Date,
        calendar: Calendar = .current
    ) -> DateInterval? {
        guard observedAt <= receivedAt,
              receivedAt.timeIntervalSince(observedAt) <= StationDetectionPolicy.recoveryLifetime,
              let window = activeWindow(for: subscription, leg: leg, now: observedAt, calendar: calendar),
              receivedAt < window.end.addingTimeInterval(StationDetectionPolicy.recoveryLifetime) else {
            return nil
        }
        return window
    }

    /// A downstream observation may identify an occurrence after its boarding window.
    /// This creates a recovery candidate, not evidence that boarding happened in the window.
    static func windowForRouteRecovery(
        for subscription: NotificationSubscription,
        leg: NotificationLeg,
        observedAt: Date,
        receivedAt: Date,
        calendar: Calendar = .current
    ) -> DateInterval? {
        guard observedAt <= receivedAt,
              receivedAt.timeIntervalSince(observedAt) <= StationDetectionPolicy.recoveryLifetime else { return nil }
        return activationIntervals(
            scheduleKind: subscription.scheduleKind,
            daysOfWeek: subscription.daysOfWeek,
            windowStart: leg.windowStart,
            windowEnd: leg.windowEnd,
            travelDate: leg.travelDate,
            dayWindows: leg.dayWindows,
            around: observedAt,
            calendar: calendar
        ).filter {
            $0.start <= observedAt && receivedAt < $0.end.addingTimeInterval(StationDetectionPolicy.recoveryLifetime)
        }.max { $0.start < $1.start }
    }

    static func nextStart(
        for subscription: NotificationSubscription,
        leg: NotificationLeg,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        activationIntervals(
            scheduleKind: subscription.scheduleKind,
            daysOfWeek: subscription.daysOfWeek,
            windowStart: leg.windowStart,
            windowEnd: leg.windowEnd,
            travelDate: leg.travelDate,
            dayWindows: leg.dayWindows,
            around: now,
            calendar: calendar
        )
        .filter { $0.end >= now }
        .map(\.start)
        .min()
    }

    private static func activationIntervals(
        scheduleKind: NotificationScheduleKind?,
        daysOfWeek: [DayOfWeek],
        windowStart: String,
        windowEnd: String,
        travelDate: String?,
        dayWindows: [String: NotificationTimeWindow]? = nil,
        around now: Date,
        calendar: Calendar
    ) -> [DateInterval] {
        guard let startTime = timeComponents(from: windowStart),
              let endTime = timeComponents(from: windowEnd) else {
            return []
        }

        if scheduleKind == .oneOff {
            guard let travelDate,
                  let day = date(from: travelDate, calendar: calendar),
                  let interval = interval(
                    on: day,
                    startTime: startTime,
                    endTime: endTime,
                    calendar: calendar
                  ) else {
                return []
            }
            return [interval]
        }

        let allowedDays = Set(daysOfWeek)
        guard !allowedDays.isEmpty else { return [] }
        let startOfToday = calendar.startOfDay(for: now)
        return (-1...7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  allowedDays.contains(dayOfWeek(for: day, calendar: calendar)) else {
                return nil
            }
            let window = dayWindows?[dayOfWeek(for: day, calendar: calendar).rawValue]
            guard let dayStart = timeComponents(from: window?.windowStart ?? windowStart),
                  let dayEnd = timeComponents(from: window?.windowEnd ?? windowEnd) else { return nil }
            return interval(on: day, startTime: dayStart, endTime: dayEnd, calendar: calendar)
        }
    }

    private static func interval(
        on day: Date,
        startTime: (hour: Int, minute: Int),
        endTime: (hour: Int, minute: Int),
        calendar: Calendar
    ) -> DateInterval? {
        guard let start = calendar.date(
            bySettingHour: startTime.hour,
            minute: startTime.minute,
            second: 0,
            of: day
        ), var end = calendar.date(
            bySettingHour: endTime.hour,
            minute: endTime.minute,
            second: 0,
            of: day
        ) else {
            return nil
        }
        if end < start {
            end = calendar.date(byAdding: .day, value: 1, to: end) ?? end
        }
        return DateInterval(start: start, end: end)
    }

    private static func timeComponents(from value: String) -> (hour: Int, minute: Int)? {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return (hour, minute)
    }

    private static func date(from value: String, calendar: Calendar) -> Date? {
        let parts = value.split(separator: "-", maxSplits: 2)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    private static func dayOfWeek(for date: Date, calendar: Calendar) -> DayOfWeek {
        switch calendar.component(.weekday, from: date) {
        case 1: return .sun
        case 2: return .mon
        case 3: return .tue
        case 4: return .wed
        case 5: return .thu
        case 6: return .fri
        default: return .sat
        }
    }
}

enum ScheduledJourneyRecoveryGeometryPolicy {
    /// Geometry learned from a calling pattern is only a wake-up hint, never service evidence.
    static func intermediateStationCodes(in branches: [[String]], from: String, to: String) -> [String]? {
        let from = from.uppercased()
        let to = to.uppercased()
        for branch in branches {
            let codes = branch.map { $0.uppercased() }
            guard let start = codes.firstIndex(of: from),
                  let end = codes.indices.first(where: { $0 > start && codes[$0] == to }) else { continue }
            var seen = Set([from, to])
            return Array(codes[(start + 1)..<end].filter { seen.insert($0).inserted }.prefix(2))
        }
        return nil
    }
}

enum ScheduledJourneyActivationResolver {
    static func legs(
        for subscription: NotificationSubscription,
        matchingFrom from: String,
        to: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [NotificationLeg] {
        let fromCode = from.uppercased()
        let toCode = to.uppercased()
        let enabledLegs = subscription.legs.filter(\.enabled)
        guard let startIndex = enabledLegs.firstIndex(where: { leg in
            leg.from.uppercased() == fromCode
                && leg.to.uppercased() == toCode
                && NotificationScheduleActivationPolicy.isActive(
                    scheduleKind: subscription.scheduleKind,
                    daysOfWeek: subscription.daysOfWeek,
                    windowStart: leg.windowStart,
                    windowEnd: leg.windowEnd,
                    travelDate: leg.travelDate,
                    dayWindows: leg.dayWindows,
                    now: now,
                    calendar: calendar
                )
        }) else {
            return []
        }

        var result = [enabledLegs[startIndex]]
        var visitedStations = Set([fromCode, toCode])
        for leg in enabledLegs.dropFirst(startIndex + 1) {
            let legFrom = leg.from.uppercased()
            let legTo = leg.to.uppercased()
            guard legFrom == result.last?.to.uppercased(),
                  !visitedStations.contains(legTo) else {
                break
            }
            result.append(leg)
            visitedStations.insert(legTo)
        }
        return result
    }
}

struct NotificationSubscriptionRequest: Codable {
    let subscriptionId: String?
    let deviceId: String
    let pushToken: String
    let routeKey: String
    var scheduleKind: NotificationScheduleKind? = nil
    let daysOfWeek: [DayOfWeek]
    let notificationTypes: [NotificationType]
    let legs: [NotificationLeg]
    let windowStart: String?
    let windowEnd: String?
    let from: String?
    let to: String?
    let fromName: String?
    let toName: String?
    let useSandbox: Bool?
    let muteOnArrival: Bool?
    let liveSessionOrigin: NotificationLiveSessionOrigin?
    let activeUntil: Date?

    enum CodingKeys: String, CodingKey {
        case subscriptionId = "subscription_id"
        case deviceId = "device_id"
        case pushToken = "push_token"
        case routeKey = "route_key"
        case scheduleKind = "schedule_type"
        case daysOfWeek = "days_of_week"
        case notificationTypes = "notification_types"
        case legs
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case from
        case to
        case fromName = "from_name"
        case toName = "to_name"
        case useSandbox = "use_sandbox"
        case muteOnArrival = "mute_on_arrival"
        case liveSessionOrigin = "live_session_origin"
        case activeUntil = "active_until"
    }
}
