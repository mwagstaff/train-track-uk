import Foundation

enum NotificationMuteStorage {
    static let suiteName = "group.dev.skynolimit.traintrack"
    private static let mutedLegsKey = "mutedLegsToday"
    private static let mutedLegsAtKey = "mutedLegsTodayAt"
    private static let pendingLiveActivityAutoEndKey = "pendingLiveActivityAutoEndOnDeparture"
    private static let pendingArrivalCleanupKey = "pendingLiveSessionPreserveOnArrival"
    private static let pendingArrivalDetectionKey = "pendingArrivalDetection"
    private static let pendingArrivalDetectionAtKey = "pendingArrivalDetectionAt"

    static func currentDateKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func legKey(from: String, to: String) -> String {
        "\(from.uppercased())-\(to.uppercased())"
    }

    @discardableResult
    static func markMuted(from: String, to: String, mutedAt: Date = Date()) -> String {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else {
            return currentDateKey()
        }

        let key = legKey(from: from, to: to)
        let dateKey = currentDateKey()

        var mutedLegs = sharedDefaults.dictionary(forKey: mutedLegsKey) as? [String: String] ?? [:]
        mutedLegs[key] = dateKey
        sharedDefaults.set(mutedLegs, forKey: mutedLegsKey)

        var mutedAtByLeg = sharedDefaults.dictionary(forKey: mutedLegsAtKey) as? [String: String] ?? [:]
        let iso = ISO8601DateFormatter().string(from: mutedAt)
        mutedAtByLeg[key] = iso
        sharedDefaults.set(mutedAtByLeg, forKey: mutedLegsAtKey)

        return dateKey
    }

    static func isMutedToday(from: String, to: String, dateKey: String? = nil) -> Bool {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return false }
        guard let mutedLegs = sharedDefaults.dictionary(forKey: mutedLegsKey) as? [String: String] else { return false }
        let key = legKey(from: from, to: to)
        let today = dateKey ?? currentDateKey()
        return mutedLegs[key] == today
    }

    static func mutedTimeLabel(from: String, to: String) -> String? {
        guard let date = mutedAtDate(from: from, to: to) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    static func mutedAtDate(from: String, to: String) -> Date? {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return nil }
        guard let mutedAtByLeg = sharedDefaults.dictionary(forKey: mutedLegsAtKey) as? [String: String] else { return nil }
        let key = legKey(from: from, to: to)
        guard let iso = mutedAtByLeg[key] else { return nil }
        return ISO8601DateFormatter().date(from: iso)
    }

    static func clearMute(from: String, to: String) {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return }
        let key = legKey(from: from, to: to)

        if var mutedLegs = sharedDefaults.dictionary(forKey: mutedLegsKey) as? [String: String] {
            mutedLegs.removeValue(forKey: key)
            sharedDefaults.set(mutedLegs, forKey: mutedLegsKey)
        }

        if var mutedAtByLeg = sharedDefaults.dictionary(forKey: mutedLegsAtKey) as? [String: String] {
            mutedAtByLeg.removeValue(forKey: key)
            sharedDefaults.set(mutedAtByLeg, forKey: mutedLegsAtKey)
        }
    }

    @discardableResult
    static func markPendingLiveActivityAutoEndOnDeparture(from: String, to: String) -> String {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else {
            return currentDateKey()
        }

        let key = legKey(from: from, to: to)
        let dateKey = currentDateKey()
        var pending = sharedDefaults.dictionary(forKey: pendingLiveActivityAutoEndKey) as? [String: String] ?? [:]
        pending[key] = dateKey
        sharedDefaults.set(pending, forKey: pendingLiveActivityAutoEndKey)
        return dateKey
    }

    static func hasPendingLiveActivityAutoEndOnDeparture(from: String, to: String, dateKey: String? = nil) -> Bool {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return false }
        guard let pending = sharedDefaults.dictionary(forKey: pendingLiveActivityAutoEndKey) as? [String: String] else { return false }
        let key = legKey(from: from, to: to)
        let today = dateKey ?? currentDateKey()
        return pending[key] == today
    }

    @discardableResult
    static func consumePendingLiveActivityAutoEndOnDeparture(from: String, to: String, dateKey: String? = nil) -> Bool {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return false }
        let key = legKey(from: from, to: to)
        let today = dateKey ?? currentDateKey()
        guard var pending = sharedDefaults.dictionary(forKey: pendingLiveActivityAutoEndKey) as? [String: String],
              pending[key] == today else {
            return false
        }

        pending.removeValue(forKey: key)
        sharedDefaults.set(pending, forKey: pendingLiveActivityAutoEndKey)
        return true
    }

    static func clearPendingLiveActivityAutoEndOnDeparture(from: String, to: String) {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return }
        let key = legKey(from: from, to: to)
        if var pending = sharedDefaults.dictionary(forKey: pendingLiveActivityAutoEndKey) as? [String: String] {
            pending.removeValue(forKey: key)
            sharedDefaults.set(pending, forKey: pendingLiveActivityAutoEndKey)
        }
    }

    @discardableResult
    static func markPendingLiveSessionPreserveOnArrival(from: String, to: String) -> String {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else {
            return currentDateKey()
        }

        let key = legKey(from: from, to: to)
        let dateKey = currentDateKey()
        var pending = sharedDefaults.dictionary(forKey: pendingArrivalCleanupKey) as? [String: String] ?? [:]
        pending[key] = dateKey
        sharedDefaults.set(pending, forKey: pendingArrivalCleanupKey)
        return dateKey
    }

    @discardableResult
    static func consumePendingLiveSessionPreserveOnArrival(from: String, to: String, dateKey: String? = nil) -> Bool {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return false }
        let key = legKey(from: from, to: to)
        let today = dateKey ?? currentDateKey()
        guard var pending = sharedDefaults.dictionary(forKey: pendingArrivalCleanupKey) as? [String: String],
              pending[key] == today else {
            return false
        }

        pending.removeValue(forKey: key)
        sharedDefaults.set(pending, forKey: pendingArrivalCleanupKey)
        return true
    }

    static func clearPendingLiveSessionPreserveOnArrival(from: String, to: String) {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return }
        let key = legKey(from: from, to: to)
        if var pending = sharedDefaults.dictionary(forKey: pendingArrivalCleanupKey) as? [String: String] {
            pending.removeValue(forKey: key)
            sharedDefaults.set(pending, forKey: pendingArrivalCleanupKey)
        }
    }

    // MARK: - Pending arrival detection
    //
    // Set when the user enters the origin station geofence. Cleared when arrival is
    // confirmed (the leg is muted). If the marker survives — i.e. the user reached the
    // station but background location was suspended before arrival could be confirmed —
    // we surface a "couldn't detect your arrival" notification instead of failing silently.

    @discardableResult
    static func markArrivalDetectionPending(from: String, to: String, at date: Date = Date()) -> String {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else {
            return currentDateKey()
        }

        let key = legKey(from: from, to: to)
        let dateKey = currentDateKey()

        var pending = sharedDefaults.dictionary(forKey: pendingArrivalDetectionKey) as? [String: String] ?? [:]
        pending[key] = dateKey
        sharedDefaults.set(pending, forKey: pendingArrivalDetectionKey)

        var pendingAt = sharedDefaults.dictionary(forKey: pendingArrivalDetectionAtKey) as? [String: String] ?? [:]
        pendingAt[key] = ISO8601DateFormatter().string(from: date)
        sharedDefaults.set(pendingAt, forKey: pendingArrivalDetectionAtKey)

        return dateKey
    }

    /// Returns the time the user entered the origin geofence today, if arrival detection
    /// is still pending (not yet confirmed) for this leg; otherwise `nil`.
    static func arrivalDetectionPendingSince(from: String, to: String, dateKey: String? = nil) -> Date? {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return nil }
        guard let pending = sharedDefaults.dictionary(forKey: pendingArrivalDetectionKey) as? [String: String] else { return nil }
        let key = legKey(from: from, to: to)
        let today = dateKey ?? currentDateKey()
        guard pending[key] == today else { return nil }
        if let iso = (sharedDefaults.dictionary(forKey: pendingArrivalDetectionAtKey) as? [String: String])?[key],
           let date = ISO8601DateFormatter().date(from: iso) {
            return date
        }
        // Pending but no usable timestamp — treat as long ago so callers don't wait.
        return Date(timeIntervalSince1970: 0)
    }

    /// Atomically clears the pending marker and returns whether it was set today.
    @discardableResult
    static func consumeArrivalDetectionPending(from: String, to: String, dateKey: String? = nil) -> Bool {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return false }
        let key = legKey(from: from, to: to)
        let today = dateKey ?? currentDateKey()
        guard var pending = sharedDefaults.dictionary(forKey: pendingArrivalDetectionKey) as? [String: String],
              pending[key] == today else {
            return false
        }

        pending.removeValue(forKey: key)
        sharedDefaults.set(pending, forKey: pendingArrivalDetectionKey)
        if var pendingAt = sharedDefaults.dictionary(forKey: pendingArrivalDetectionAtKey) as? [String: String] {
            pendingAt.removeValue(forKey: key)
            sharedDefaults.set(pendingAt, forKey: pendingArrivalDetectionAtKey)
        }
        return true
    }

    static func clearArrivalDetectionPending(from: String, to: String) {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return }
        let key = legKey(from: from, to: to)
        if var pending = sharedDefaults.dictionary(forKey: pendingArrivalDetectionKey) as? [String: String] {
            pending.removeValue(forKey: key)
            sharedDefaults.set(pending, forKey: pendingArrivalDetectionKey)
        }
        if var pendingAt = sharedDefaults.dictionary(forKey: pendingArrivalDetectionAtKey) as? [String: String] {
            pendingAt.removeValue(forKey: key)
            sharedDefaults.set(pendingAt, forKey: pendingArrivalDetectionAtKey)
        }
    }
}
