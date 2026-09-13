import Foundation

public struct JourneyActivityLifecycleRecord: Codable, Equatable, Sendable {
    public let activityID: String
    public let scheduleKey: String
    public let fromCRS: String
    public let toCRS: String
    public let phase: JourneyActivityAttributes.JourneyPhase
    public let liveSessionID: String?
    public let updatedAt: Date
    public let dismissedBeforeStart: Bool
}

public enum JourneyActivityLifecycleStore {
    private static let suiteName = "group.dev.skynolimit.traintrack"
    private static let storageKey = "journey_activity_lifecycle_records_v1"
    private static let retentionInterval: TimeInterval = 24 * 60 * 60

    public static func update(
        activityID: String,
        state: JourneyActivityAttributes.ContentState,
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) {
        guard let scheduleKey = normalized(state.scheduleKey) else { return }
        let store = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        var records = load(now: now, defaults: store)
        let existing = records.first { $0.activityID == activityID || $0.scheduleKey == scheduleKey }
        records.removeAll { $0.activityID == activityID || $0.scheduleKey == scheduleKey }
        records.append(JourneyActivityLifecycleRecord(
            activityID: activityID,
            scheduleKey: scheduleKey,
            fromCRS: state.fromCRS.uppercased(),
            toCRS: state.toCRS.uppercased(),
            phase: state.journeyPhase,
            liveSessionID: existing?.liveSessionID,
            updatedAt: now,
            dismissedBeforeStart: false
        ))
        save(records, defaults: store)
    }

    public static func seedPendingRemoteStart(
        scheduleKey: String,
        fromCRS: String,
        toCRS: String,
        startedAt: Date,
        defaults: UserDefaults? = nil
    ) {
        guard let scheduleKey = normalized(scheduleKey) else { return }
        let store = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        var records = load(now: Date(), defaults: store)
        guard records.contains(where: { $0.scheduleKey == scheduleKey }) == false else { return }
        records.append(JourneyActivityLifecycleRecord(
            activityID: "remote-start|\(scheduleKey)",
            scheduleKey: scheduleKey,
            fromCRS: fromCRS.uppercased(),
            toCRS: toCRS.uppercased(),
            phase: .pendingStart,
            liveSessionID: nil,
            updatedAt: startedAt,
            dismissedBeforeStart: false
        ))
        save(records, defaults: store)
    }

    public static func setLiveSessionID(
        _ liveSessionID: String,
        activityID: String,
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) {
        let store = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        var records = load(now: now, defaults: store)
        guard let index = records.firstIndex(where: { $0.activityID == activityID }) else { return }
        let record = records[index]
        records[index] = JourneyActivityLifecycleRecord(
            activityID: record.activityID,
            scheduleKey: record.scheduleKey,
            fromCRS: record.fromCRS,
            toCRS: record.toCRS,
            phase: record.phase,
            liveSessionID: liveSessionID,
            updatedAt: now,
            dismissedBeforeStart: record.dismissedBeforeStart
        )
        save(records, defaults: store)
    }

    public static func markDismissedBeforeStart(
        activityID: String,
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) {
        let store = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        var records = load(now: now, defaults: store)
        guard let index = records.firstIndex(where: {
            $0.activityID == activityID && $0.phase == .pendingStart
        }) else { return }
        let record = records[index]
        records[index] = JourneyActivityLifecycleRecord(
            activityID: record.activityID,
            scheduleKey: record.scheduleKey,
            fromCRS: record.fromCRS,
            toCRS: record.toCRS,
            phase: record.phase,
            liveSessionID: record.liveSessionID,
            updatedAt: now,
            dismissedBeforeStart: true
        )
        save(records, defaults: store)
    }

    public static func record(
        scheduleKey: String,
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) -> JourneyActivityLifecycleRecord? {
        let store = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        return load(now: now, defaults: store).first { $0.scheduleKey == scheduleKey }
    }

    public static func dismissedBeforeStartRecords(
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) -> [JourneyActivityLifecycleRecord] {
        let store = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        return load(now: now, defaults: store).filter(\.dismissedBeforeStart)
    }

    public static func remove(
        activityID: String,
        now: Date = Date(),
        defaults: UserDefaults? = nil
    ) {
        let store = defaults ?? UserDefaults(suiteName: suiteName) ?? .standard
        var records = load(now: now, defaults: store)
        records.removeAll { $0.activityID == activityID }
        save(records, defaults: store)
    }

    private static func load(now: Date, defaults: UserDefaults) -> [JourneyActivityLifecycleRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([JourneyActivityLifecycleRecord].self, from: data) else {
            return []
        }
        let cutoff = now.addingTimeInterval(-retentionInterval)
        return decoded.filter { $0.updatedAt >= cutoff }
    }

    private static func save(_ records: [JourneyActivityLifecycleRecord], defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
