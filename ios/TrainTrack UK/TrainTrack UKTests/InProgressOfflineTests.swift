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

    @Test func connectionWindowIncludesThreeMinutesEarlyAndUsesLiveTimes() {
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 7, minute: 40))!
        let arrival = JourneyItineraryBuilder.date(for: "07:57", now: now)!
        func departure(_ scheduled: String, _ estimated: String) -> DepartureV2 {
            DepartureV2(departureTime: DepartureTimeV2(scheduled: scheduled, estimated: estimated),
                serviceType: "train", platform: "1", isCancelled: false, length: nil,
                destination: [], origin: nil, serviceID: scheduled, delayReason: nil, cancelReason: nil, timestamp: nil)
        }
        #expect(!ConnectionDeparturePolicy.isVisible(departure("07:53", "07:53"), arrival: arrival, now: now))
        #expect(ConnectionDeparturePolicy.isVisible(departure("07:54", "07:54"), arrival: arrival, now: now))
        #expect(ConnectionDeparturePolicy.isUnlikely(departure("07:54", "07:54"), arrival: arrival, now: now))
        #expect(!ConnectionDeparturePolicy.isUnlikely(departure("07:57", "07:57"), arrival: arrival, now: now))
        #expect(!ConnectionDeparturePolicy.isUnlikely(departure("07:54", "08:01"), arrival: arrival, now: now))
        #expect(ConnectionDeparturePolicy.isVisible(departure("07:50", "08:01"), arrival: arrival, now: now))
        #expect(ConnectionDeparturePolicy.isVisible(departure("07:50", "07:50"), arrival: nil, now: now))
    }

    @Test func servicePickerPinsSuggestionThenOrdersOtherServicesByScheduledDate() {
        let midnight = Date(timeIntervalSince1970: 1_800_000_000)
        func departure(_ id: String, offset: Double, delayedBy: Double = 0) -> RecentDepartureV2 {
            let date = midnight.addingTimeInterval(offset)
            return RecentDepartureV2(serviceID: id, serviceType: "train", fromCRS: "BFR", toCRS: "HNH",
                scheduledDeparture: "00:00", estimatedDeparture: nil, actualDeparture: nil,
                scheduledDepartureAt: date, estimatedDepartureAt: date.addingTimeInterval(delayedBy),
                actualDepartureAt: nil, platform: nil, isCancelled: false, lastObservedAt: midnight)
        }
        let input = [departure("suggestion", offset: 1800), departure("late", offset: 900),
            departure("previous-day", offset: -60, delayedBy: 3600), departure("tie-b", offset: 0),
            departure("tie-a", offset: 0)]
        let ordered = InProgressJourneyPresentation.servicePickerDepartures(input) { left, right in
            left.id == "suggestion" && right.id != "suggestion"
        }
        #expect(ordered.map(\.id) == ["suggestion", "previous-day", "tie-a", "tie-b", "late"])
        #expect(Set(ordered.map(\.id)).count == input.count)
        #expect(InProgressJourneyPresentation.servicePickerDepartures([]) { _, _ in false }.isEmpty)
        #expect(InProgressJourneyPresentation.servicePickerDepartures([input[0]]) { _, _ in false } == [input[0]])
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
