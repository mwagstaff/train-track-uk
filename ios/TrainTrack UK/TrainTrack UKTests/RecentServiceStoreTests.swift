import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct RecentServiceStoreTests {
    @Test func rereadingTheOriginSnapshotDoesNotRefreshItsAge() throws {
        let cached = try observation(estimated: "07:48", observedAt: "07:35", readAt: "07:57")
        #expect(cached.lastObservedAt == date("07:35"))
        #expect(cached.estimatedDepartureAt == date("07:48"))
    }

    @Test func staleOriginSnapshotCannotRollBackANewerDelayOrCancellation() throws {
        let latest = try observation(estimated: "07:52", observedAt: "07:49", cancelled: true)
        let cached = try observation(estimated: "07:48", observedAt: "07:35", readAt: "07:57")
        let merged = RecentServiceStore.preferred(latest, cached)
        #expect(merged.estimatedDepartureAt == date("07:52"))
        #expect(merged.isCancelled)
        #expect(merged.lastObservedAt == date("07:49"))
        #expect(RecentServiceStore.preferred(cached, latest) == merged)
    }

    @Test func actualDepartureSurvivesAForecastOnlyRefresh() throws {
        let departed = try observation(estimated: "07:51", actual: "07:52", observedAt: "07:53")
        let forecast = try observation(estimated: "07:55", observedAt: "07:54")
        let merged = RecentServiceStore.preferred(departed, forecast)
        #expect(merged.actualDeparture == "07:52")
        #expect(merged.actualDepartureAt == date("07:52"))
        #expect(merged.estimatedDepartureAt == date("07:55"))
        #expect(merged.lastObservedAt == date("07:54"))
    }

    @Test func anIndefiniteDelayDoesNotRetainAnOutdatedEstimatedTime() throws {
        let earlier = try observation(estimated: "07:48", observedAt: "07:35")
        let delayed = try observation(estimated: "Delayed", observedAt: "07:49")
        let merged = RecentServiceStore.preferred(earlier, delayed)
        #expect(merged.estimatedDeparture == "Delayed")
        #expect(merged.estimatedDepartureAt == nil)
    }

    @Test func anOldSnapshotCannotBecomeTodaysService() {
        let yesterday = departure(estimated: "07:48", observedAt: date("07:35").addingTimeInterval(-24 * 60 * 60))
        #expect(RecentServiceStore.observation(yesterday, fromCRS: "KTH", toCRS: "VIC", now: date("07:57")) == nil)
    }

    @Test func productionPayloadUsesProviderObservationInsteadOfCacheReadTime() throws {
        let payload = try decodedDeparture(estimated: "07:48", observedAt: date("07:35"))
        #expect(payload.timestamp == nil)
        let observed = try #require(RecentServiceStore.observation(
            payload, fromCRS: "KTH", toCRS: "VIC", now: date("07:57")
        ))
        #expect(observed.lastObservedAt == date("07:35"))
        #expect(observed.providerObservedAt == date("07:35"))
        #expect(observed.estimatedDepartureAt == date("07:48"))
    }

    @Test func cachedProductionPayloadCannotRollBackANewerDelay() throws {
        let fresh = try #require(RecentServiceStore.observation(
            decodedDeparture(estimated: "07:52", observedAt: date("07:49")),
            fromCRS: "KTH", toCRS: "VIC", now: date("07:50")
        ))
        let stale = try #require(RecentServiceStore.observation(
            decodedDeparture(estimated: "07:48", observedAt: date("07:35")),
            fromCRS: "KTH", toCRS: "VIC", now: date("07:57")
        ))
        let merged = RecentServiceStore.preferred(fresh, stale)
        #expect(merged.lastObservedAt == date("07:49"))
        #expect(merged.estimatedDepartureAt == date("07:52"))
    }

    @Test func anOldProviderDatedPayloadCannotBecomeTodaysService() throws {
        let old = try decodedDeparture(estimated: "07:48", observedAt: date("07:35").addingTimeInterval(-24 * 60 * 60))
        #expect(RecentServiceStore.observation(old, fromCRS: "KTH", toCRS: "VIC", now: date("07:57")) == nil)
    }

    @Test func aLegacyHistoryReceiptCannotOverrideAKnownProviderObservation() throws {
        let known = try observation(estimated: "07:52", observedAt: "07:49")
        let legacy = RecentDepartureV2(
            serviceID: "caught", serviceType: "train", fromCRS: "KTH", toCRS: "VIC",
            scheduledDeparture: "07:42", estimatedDeparture: "07:48", actualDeparture: nil,
            scheduledDepartureAt: date("07:42"), estimatedDepartureAt: date("07:48"), actualDepartureAt: nil,
            platform: nil, isCancelled: true, lastObservedAt: date("07:57")
        )
        for merged in [RecentServiceStore.preferred(known, legacy), RecentServiceStore.preferred(legacy, known)] {
            #expect(merged.estimatedDepartureAt == date("07:52"))
            #expect(!merged.isCancelled)
            #expect(merged.providerObservedAt == date("07:49"))
            #expect(merged.evidenceObservedAt == date("07:49"))
        }
    }

    @Test func recentHistoryDecodesProviderTimeAndAcceptsLegacyRecords() throws {
        let known = try observation(estimated: "07:52", observedAt: "07:49")
        let encoded = try JSONEncoder().encode(known)
        #expect(try JSONDecoder().decode(RecentDepartureV2.self, from: encoded).providerObservedAt == date("07:49"))
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "providerObservedAt")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(RecentDepartureV2.self, from: legacyData).providerObservedAt == nil)
    }

    private func decodedDeparture(estimated: String, observedAt: Date) throws -> DepartureV2 {
        let data = try JSONSerialization.data(withJSONObject: [
            "departure_time": ["scheduled": "07:42", "estimated": estimated],
            "serviceID": "caught",
            "destination": ["crs": "VIC", "locationName": "London Victoria"],
            "siri": ["providerObservedAt": ISO8601DateFormatter().string(from: observedAt)]
        ])
        return try JSONDecoder().decode(DepartureV2.self, from: data)
    }

    private func observation(
        estimated: String,
        actual: String? = nil,
        observedAt: String,
        readAt: String = "07:57",
        cancelled: Bool = false
    ) throws -> RecentDepartureV2 {
        try #require(RecentServiceStore.observation(
            departure(estimated: estimated, actual: actual, observedAt: date(observedAt), cancelled: cancelled),
            fromCRS: "KTH", toCRS: "VIC", now: date(readAt)
        ))
    }

    private func departure(estimated: String, actual: String? = nil, observedAt: Date, cancelled: Bool = false) -> DepartureV2 {
        DepartureV2(
            departureTime: DepartureTimeV2(scheduled: "07:42", estimated: estimated, actual: actual),
            serviceType: "train", platform: "2", isCancelled: cancelled, length: nil,
            destination: [PlaceInfoV2(crs: "VIC", locationName: "London Victoria", via: nil)],
            origin: [PlaceInfoV2(crs: "KTH", locationName: "Kent House", via: nil)],
            serviceID: "caught", delayReason: nil, cancelReason: nil, timestamp: observedAt
        )
    }

    private func date(_ time: String) -> Date {
        let components = time.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: 16, hour: components[0], minute: components[1]
        ))!
    }
}
