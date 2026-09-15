import Foundation

// Shares the coordinator's persisted envelope without initializing its timers,
// monitoring, subscription lifecycle, or completion cleanup.
@MainActor
enum JourneyTrackingCheckpointStore {
    static let key = "journeyHistoryTrackingCheckpointV1"

    static func load(from defaults: UserDefaults) -> JourneyHistoryCheckpointEnvelope? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(JourneyHistoryCheckpointEnvelope.self, from: data)
    }

    static func save(_ envelope: JourneyHistoryCheckpointEnvelope, to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(envelope), forKey: key)
    }

    static func activeJourney() -> ActiveJourneyHistoryCheckpoint? {
        let defaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard
        return load(from: defaults)?.activeJourney
    }
}
