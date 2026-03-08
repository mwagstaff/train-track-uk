import Foundation

enum NotificationMuteStorage {
    static let suiteName = "group.dev.skynolimit.traintrack"
    private static let mutedLegsKey = "mutedLegsToday"
    private static let mutedLegsAtKey = "mutedLegsTodayAt"

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
}
