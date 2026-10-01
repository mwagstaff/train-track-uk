import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct InProgressOfflineTests {
    @Test func failureKeepsCachedServiceAndRecoveryClearsWarning() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let initial = try details(estimate: "17:52")
        let recovered = try details(estimate: "17:55")
        var attempt = 0
        let store = DeparturesStore(defaults: defaults) { _, _ in
            attempt += 1
            switch attempt {
            case 1: return ServiceDetailsBatch(details: ["VIC-KTH": initial])
            case 2: throw URLError(.notConnectedToInternet)
            default: return ServiceDetailsBatch(details: ["VIC-KTH": recovered])
            }
        }
        #expect(await store.ensureServiceDetails(for: ["VIC-KTH"], force: true))
        let updatedAt = try #require(store.serviceDataAvailability(for: "VIC-KTH")?.lastSuccessfulUpdate)
        #expect(await store.ensureServiceDetails(for: ["VIC-KTH"], force: true))
        #expect(store.serviceDetailsById["VIC-KTH"] == initial)
        #expect(store.serviceDataAvailability(for: "VIC-KTH")?.status == .stale)
        #expect(store.serviceDataAvailability(for: "VIC-KTH")?.lastSuccessfulUpdate == updatedAt)
        #expect(await store.ensureServiceDetails(for: ["VIC-KTH"]))
        #expect(store.serviceDetailsById["VIC-KTH"] == recovered)
        #expect(store.serviceDataAvailability(for: "VIC-KTH")?.status == .live)
    }

    @Test func cacheSurvivesRelaunchAndEmptyResponsesWithoutBecomingFresh() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let cached = try details(estimate: "17:52")
        let original = DeparturesStore(defaults: defaults) { _, _ in
            ServiceDetailsBatch(details: ["VIC-KTH": cached])
        }
        await original.ensureServiceDetails(for: ["VIC-KTH"])
        let updatedAt = original.serviceDataAvailability(for: "VIC-KTH")?.lastSuccessfulUpdate
        let restored = DeparturesStore(defaults: defaults) { _, _ in ServiceDetailsBatch() }
        #expect(restored.serviceDetailsById["VIC-KTH"] == cached)
        #expect(restored.serviceDataAvailability(for: "VIC-KTH")?.status == .stale)
        await restored.ensureServiceDetails(for: ["VIC-KTH"])
        #expect(restored.serviceDetailsById["VIC-KTH"] == cached)
        #expect(restored.serviceDataAvailability(for: "VIC-KTH")?.lastSuccessfulUpdate == updatedAt)
        #expect(restored.serviceDetailsById["different-train"] == nil)
    }

    @Test func missingDataIsUnavailableAndCancellationIsNotAConnectionFailure() async {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let failed = DeparturesStore(defaults: defaults) { _, _ in throw URLError(.timedOut) }
        #expect(await !failed.ensureServiceDetails(for: ["missing"]))
        #expect(failed.serviceDataAvailability(for: "missing")?.status == .unavailable)
        let cancelled = DeparturesStore(defaults: defaults) { _, _ in throw CancellationError() }
        #expect(await !cancelled.ensureServiceDetails(for: ["cancelled"]))
        #expect(cancelled.serviceDataAvailability(for: "cancelled") == nil)
    }

    @Test func availabilityAgesWithoutChangingTheLastSuccessfulUpdate() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let cached = try details(estimate: "17:52")
        let store = DeparturesStore(defaults: defaults) { _, _ in ServiceDetailsBatch(details: ["train": cached]) }
        await store.ensureServiceDetails(for: ["train"])
        let date = try #require(store.serviceDataAvailability(for: "train")?.lastSuccessfulUpdate)
        #expect(store.serviceDataAvailability(for: "train", now: date.addingTimeInterval(61))?.status == .stale)
        #expect(store.serviceDataAvailability(for: "train", now: date.addingTimeInterval(61))?.lastSuccessfulUpdate == date)
    }

    @Test func expiredCacheIsNotRestoredAsTodaysService() async throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let cached = try details(estimate: "17:52")
        let store = DeparturesStore(defaults: defaults) { _, _ in ServiceDetailsBatch(details: ["train": cached]) }
        await store.ensureServiceDetails(for: ["train"])
        let data = try #require(defaults.data(forKey: "recentServiceDetailsV1"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
        json["train"]?["fetchedAt"] = Date().addingTimeInterval(-7 * 60 * 60).timeIntervalSinceReferenceDate
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "recentServiceDetailsV1")
        let restored = DeparturesStore(defaults: defaults) { _, _ in ServiceDetailsBatch() }
        #expect(restored.serviceDetailsById.isEmpty)
        #expect(restored.serviceDataAvailability(for: "train") == nil)
    }

    @Test func savedArrivalUsesTheDestinationAndResolvesOnTime() {
        let origin = Station(crs: "VIC", name: "London Victoria", longitude: "0", latitude: "0")
        let destination = Station(crs: "KTH", name: "Kent House", longitude: "0", latitude: "0")
        let leg = JourneyHistoryLeg(plannedLegIndex: 0, fromStation: origin, toStation: destination,
            serviceCallingPoints: [JourneyHistoryCallingPoint(
                locationName: "Kent House", crs: "KTH", scheduledTime: "17:52", estimatedTime: "On time", actualTime: nil
            )])
        #expect(InProgressJourneyPresentation.savedArrivalTime(for: leg, destinationCRS: "kth") == "17:52")
        #expect(InProgressJourneyPresentation.savedArrivalTime(for: leg, destinationCRS: "BNE") == nil)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "InProgressOfflineTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(suite, forKey: "testSuite")
        return defaults
    }

    private func defaultsSuite(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: "testSuite")!
    }

    private func details(estimate: String) throws -> ServiceDetails {
        try JSONDecoder().decode(ServiceDetails.self, from: Data("""
        {"generatedAt":"2026-09-29T16:40:00Z","serviceType":"train","locationName":"Victoria","crs":"VIC","std":"17:27",
         "subsequentCallingPoints":[{"callingPoint":[{"locationName":"Kent House","crs":"KTH","st":"17:52","et":"\(estimate)"}]}]}
        """.utf8))
    }
}
