import Foundation

nonisolated enum NotificationMuteStorage {
    static let suiteName = "group.dev.skynolimit.traintrack"
    private static let mutedLegsKey = "mutedLegsToday"
    private static let mutedLegsAtKey = "mutedLegsTodayAt"
    private static let pendingArrivalCleanupKey = "pendingLiveSessionPreserveOnArrival"
    private static let pendingArrivalDetectionKey = "pendingArrivalDetection"
    private static let pendingArrivalDetectionAtKey = "pendingArrivalDetectionAt"
    private static let pendingStationDepartureCleanupKey = "pendingStationDepartureCleanup"
    private static let pendingStationDepartureCleanupAtKey = "pendingStationDepartureCleanupAt"
    private static let pendingMuteRequestsKey = "pendingMuteRequests"

    struct PendingMuteRequest: Codable, Identifiable {
        let id: String
        let subscriptionId: String
        let from: String
        let to: String
        let dateKey: String
        let delayMinutes: Int
        let reason: String
        let transition: String?
        let detectionSource: String?
        var journeyNotificationBody: String?
        let createdAt: Date
        var attempts: Int
        var lastAttemptAt: Date?
        var lastError: String?
    }

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
    static func markPendingStationDepartureCleanup(from: String, to: String, at date: Date = Date()) -> String {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else {
            return currentDateKey()
        }

        let key = legKey(from: from, to: to)
        let dateKey = currentDateKey()
        var pending = sharedDefaults.dictionary(forKey: pendingStationDepartureCleanupKey) as? [String: String] ?? [:]
        pending[key] = dateKey
        sharedDefaults.set(pending, forKey: pendingStationDepartureCleanupKey)

        var pendingAt = sharedDefaults.dictionary(forKey: pendingStationDepartureCleanupAtKey) as? [String: String] ?? [:]
        pendingAt[key] = ISO8601DateFormatter().string(from: date)
        sharedDefaults.set(pendingAt, forKey: pendingStationDepartureCleanupAtKey)
        return dateKey
    }

    static func hasPendingStationDepartureCleanup(
        from: String,
        to: String,
        dateKey: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return false }
        guard let pending = sharedDefaults.dictionary(forKey: pendingStationDepartureCleanupKey) as? [String: String] else { return false }
        let key = legKey(from: from, to: to)
        guard pending[key] != nil else { return false }

        if let iso = (sharedDefaults.dictionary(forKey: pendingStationDepartureCleanupAtKey) as? [String: String])?[key],
           let recordedAt = ISO8601DateFormatter().date(from: iso) {
            return StationDetectionPolicy.isPersistedStateCurrent(recordedAt: recordedAt, now: now)
        }

        // Legacy records did not have a timestamp. Keep today's record valid so an update
        // does not strand an already-armed journey, then replace it on the next arrival.
        return pending[key] == (dateKey ?? currentDateKey())
    }

    @discardableResult
    static func consumePendingStationDepartureCleanup(
        from: String,
        to: String,
        dateKey: String? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return false }
        let key = legKey(from: from, to: to)
        guard var pending = sharedDefaults.dictionary(forKey: pendingStationDepartureCleanupKey) as? [String: String],
              pending[key] != nil else {
            return false
        }

        let isCurrent: Bool
        if let iso = (sharedDefaults.dictionary(forKey: pendingStationDepartureCleanupAtKey) as? [String: String])?[key],
           let recordedAt = ISO8601DateFormatter().date(from: iso) {
            isCurrent = StationDetectionPolicy.isPersistedStateCurrent(recordedAt: recordedAt, now: now)
        } else {
            isCurrent = pending[key] == (dateKey ?? currentDateKey())
        }

        pending.removeValue(forKey: key)
        sharedDefaults.set(pending, forKey: pendingStationDepartureCleanupKey)
        removePendingStationDepartureTimestamp(key: key, defaults: sharedDefaults)
        return isCurrent
    }

    static func clearPendingStationDepartureCleanup(from: String, to: String) {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return }
        let key = legKey(from: from, to: to)
        if var pending = sharedDefaults.dictionary(forKey: pendingStationDepartureCleanupKey) as? [String: String] {
            pending.removeValue(forKey: key)
            sharedDefaults.set(pending, forKey: pendingStationDepartureCleanupKey)
        }
        removePendingStationDepartureTimestamp(key: key, defaults: sharedDefaults)
    }

    private static func removePendingStationDepartureTimestamp(key: String, defaults: UserDefaults) {
        if var pendingAt = defaults.dictionary(forKey: pendingStationDepartureCleanupAtKey) as? [String: String] {
            pendingAt.removeValue(forKey: key)
            defaults.set(pendingAt, forKey: pendingStationDepartureCleanupAtKey)
        }
    }

    // MARK: - Pending mute requests
    //
    // Station-exit mute requests are the authoritative server call that sends the
    // boarding confirmation and mutes the scheduled leg. Persist them before
    // upload so a transient mobile-network drop cannot lose that server transition.

    @discardableResult
    static func upsertPendingMuteRequest(
        subscriptionId: String,
        from: String,
        to: String,
        dateKey: String,
        delayMinutes: Int,
        reason: String,
        transition: String? = nil,
        detectionSource: String? = nil,
        journeyNotificationBody: String? = nil
    ) -> PendingMuteRequest? {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return nil }
        let id = pendingMuteRequestId(
            subscriptionId: subscriptionId,
            from: from,
            to: to,
            dateKey: dateKey,
            reason: reason
        )
        var requests = loadPendingMuteRequests(defaults: sharedDefaults)
        if let index = requests.firstIndex(where: { $0.id == id }) {
            requests[index].lastError = nil
            if let journeyNotificationBody {
                requests[index].journeyNotificationBody = journeyNotificationBody
            }
            savePendingMuteRequests(requests, defaults: sharedDefaults)
            return requests[index]
        }

        let request = PendingMuteRequest(
            id: id,
            subscriptionId: subscriptionId,
            from: from.uppercased(),
            to: to.uppercased(),
            dateKey: dateKey,
            delayMinutes: delayMinutes,
            reason: reason,
            transition: transition,
            detectionSource: detectionSource,
            journeyNotificationBody: journeyNotificationBody,
            createdAt: Date(),
            attempts: 0,
            lastAttemptAt: nil,
            lastError: nil
        )
        requests.append(request)
        savePendingMuteRequests(requests, defaults: sharedDefaults)
        return request
    }

    static func pendingMuteRequests(maxAge: TimeInterval = 24 * 60 * 60) -> [PendingMuteRequest] {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return [] }
        let cutoff = Date().addingTimeInterval(-maxAge)
        let loaded = loadPendingMuteRequests(defaults: sharedDefaults)
        let current = loaded.filter { $0.createdAt >= cutoff }
        if current.count != loaded.count {
            savePendingMuteRequests(current, defaults: sharedDefaults)
        }
        return current
    }

    static func markPendingMuteRequestAttempt(id: String, at date: Date = Date()) {
        updatePendingMuteRequest(id: id) { request in
            request.attempts += 1
            request.lastAttemptAt = date
            request.lastError = nil
        }
    }

    static func markPendingMuteRequestFailure(id: String, error: String) {
        updatePendingMuteRequest(id: id) { request in
            request.lastError = error
        }
    }

    static func removePendingMuteRequest(id: String) {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return }
        let requests = loadPendingMuteRequests(defaults: sharedDefaults).filter { $0.id != id }
        savePendingMuteRequests(requests, defaults: sharedDefaults)
    }

    static func removePendingMuteRequests(
        subscriptionId: String,
        from: String,
        to: String,
        dateKey: String? = nil
    ) {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return }
        let targetLegKey = legKey(from: from, to: to)
        let targetDateKey = dateKey ?? currentDateKey()
        let requests = loadPendingMuteRequests(defaults: sharedDefaults).filter { request in
            request.subscriptionId != subscriptionId
                || legKey(from: request.from, to: request.to) != targetLegKey
                || request.dateKey != targetDateKey
        }
        savePendingMuteRequests(requests, defaults: sharedDefaults)
    }

    private static func pendingMuteRequestId(
        subscriptionId: String,
        from: String,
        to: String,
        dateKey: String,
        reason: String
    ) -> String {
        [
            subscriptionId,
            legKey(from: from, to: to),
            dateKey,
            reason
        ].joined(separator: "|")
    }

    private static func updatePendingMuteRequest(id: String, update: (inout PendingMuteRequest) -> Void) {
        guard let sharedDefaults = UserDefaults(suiteName: suiteName) else { return }
        var requests = loadPendingMuteRequests(defaults: sharedDefaults)
        guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
        update(&requests[index])
        savePendingMuteRequests(requests, defaults: sharedDefaults)
    }

    private static func loadPendingMuteRequests(defaults: UserDefaults) -> [PendingMuteRequest] {
        guard let data = defaults.data(forKey: pendingMuteRequestsKey) else { return [] }
        return (try? JSONDecoder().decode([PendingMuteRequest].self, from: data)) ?? []
    }

    private static func savePendingMuteRequests(_ requests: [PendingMuteRequest], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(requests) {
            defaults.set(data, forKey: pendingMuteRequestsKey)
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
