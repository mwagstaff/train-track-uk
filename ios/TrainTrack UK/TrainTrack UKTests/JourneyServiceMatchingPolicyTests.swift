import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct JourneyServiceMatchingPolicyTests {
    private let origin = Station(crs: "VIC", name: "London Victoria", longitude: "-0.1442", latitude: "51.4951")
    private let destination = Station(crs: "KTH", name: "Kent House", longitude: "-0.0458", latitude: "51.4127")

    @Test func delayedVictoriaExitRecoversThe1727AfterItDisappearsFromTheLiveBoard() {
        let result = match(
            departures: [departure("17:42", id: "8561000VICTRIE_")],
            recent: [recent("17:27", id: "8560997VICTRIE_")]
        )

        #expect(result.departure?.serviceID == "8560997VICTRIE_")
        #expect(result.scheduledDepartureAt == date("17:27"))
        #expect(result.timeDifferenceMinutes == 6)
        #expect(result.confidence == 0.55)
    }

    @Test func aFutureOnlyBoardDoesNotTurnThe1742IntoAnAlreadyBoardedTrain() {
        let result = match(departures: [departure("17:42"), departure("17:57")])
        #expect(result.departure == nil)
        #expect(result.confidence == 0)
    }

    @Test func liveActivityPreferenceCannotOverrideDepartureEligibility() {
        let result = match(
            departures: [departure("17:27"), departure("17:42")],
            preferredServiceID: "17:42"
        )
        #expect(result.departure?.serviceID == "17:27")
        #expect(result.confidence == 0.55)
    }

    @Test func eligibleLiveActivityPreferenceIsPreserved() {
        let result = match(
            departures: [departure("17:27"), departure("17:32")],
            preferredServiceID: "17:27"
        )
        #expect(result.departure?.serviceID == "17:27")
        #expect(result.confidence == 0.98)
    }

    @Test func anExplicitManualSelectionCanChooseAnUpcomingTrain() {
        let result = match(
            departures: [departure("17:27")],
            preferredDeparture: departure("17:42")
        )
        #expect(result.departure?.serviceID == "17:42")
        #expect(result.confidence == 1)
    }

    @Test func actualDepartureTimeCanMakeAnEarlierDelayedServiceTheBestMatch() {
        let result = match(
            departures: [departure("17:27")],
            recent: [recent("16:57", estimated: "17:40", actual: "17:32")]
        )
        #expect(result.departure?.serviceID == "16:57")
        #expect(result.scheduledDepartureAt == date("16:57"))
        #expect(result.timeDifferenceMinutes == 1)
        #expect(result.confidence == 0.9)
    }

    @Test func delayedServiceUsesExpectedDepartureForArrivalAndLookbackBounds() {
        let result = match(recent: [recent("16:57", estimated: "17:30")])
        #expect(result.departure?.serviceID == "16:57")
        #expect(result.timeDifferenceMinutes == 3)
    }

    @Test func recentlyObservedCancellationCannotBeSelectedFromAnOlderOriginSnapshot() {
        let result = match(
            departures: [departure("17:27"), departure("17:42")],
            recent: [recent("17:27", cancelled: true)]
        )
        #expect(result.departure == nil)
    }

    @Test func servicesBeforeThePassengerArrivedCannotBeSelected() {
        let result = match(departures: [departure("17:12")], originArrivedAt: date("17:20"))
        #expect(result.departure == nil)
    }

    @Test func anOlderServiceCannotBeAssumedWhenArrivalWasNotObserved() {
        let result = match(
            departures: [departure("17:00")],
            originArrivedAt: nil
        )
        #expect(result.departure == nil)
    }

    @Test func departureJitterAllowsAtMostTwoMinutesInTheFuture() {
        #expect(match(departures: [departure("17:35")]).departure != nil)
        #expect(match(departures: [departure("17:36")]).departure == nil)
    }

    @Test func matchingAcrossMidnightKeepsTheActualServiceDay() {
        let result = JourneyServiceMatchingPolicy.match(
            departures: [departure("00:12")],
            recentDepartures: [recent("23:57")],
            from: origin,
            to: destination,
            detectedAt: date("00:03", day: 10),
            originArrivedAt: date("23:50")
        )
        #expect(result.departure?.serviceID == "23:57")
        #expect(result.scheduledDepartureAt == date("23:57"))
        #expect(result.timeDifferenceMinutes == 6)
    }

    @Test func aRecentRecordFromYesterdayOrAnotherRouteIsIneligible() {
        let yesterday = recent("17:27", day: 8)
        let otherRoute = recent("17:27", fromCRS: "BFR")
        #expect(match(recent: [yesterday, otherRoute]).departure == nil)
    }

    @Test func aNewerBoardUpdateSupersedesAnOlderRecentObservation() {
        let result = match(
            departures: [departure("17:27", estimated: "17:42", observedAt: date("17:33"))],
            recent: [recent("17:27")]
        )
        #expect(result.departure == nil)
    }

    private func match(
        departures: [DepartureV2] = [],
        recent: [RecentDepartureV2] = [],
        originArrivedAt: Date? = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 17, minute: 15)),
        preferredServiceID: String? = nil,
        preferredDeparture: DepartureV2? = nil
    ) -> JourneyServiceMatchingPolicy.Match {
        JourneyServiceMatchingPolicy.match(
            departures: departures,
            recentDepartures: recent,
            from: origin,
            to: destination,
            detectedAt: date("17:33").addingTimeInterval(37),
            originArrivedAt: originArrivedAt,
            preferredServiceID: preferredServiceID,
            preferredDeparture: preferredDeparture
        )
    }

    private func departure(
        _ scheduled: String,
        id: String? = nil,
        estimated: String? = nil,
        observedAt: Date? = nil
    ) -> DepartureV2 {
        DepartureV2(
            departureTime: DepartureTimeV2(scheduled: scheduled, estimated: estimated ?? scheduled),
            serviceType: "train", platform: nil, isCancelled: false, length: nil,
            destination: [PlaceInfoV2(crs: "KTH", locationName: "Kent House", via: nil)],
            origin: [PlaceInfoV2(crs: "VIC", locationName: "London Victoria", via: nil)],
            serviceID: id ?? scheduled, delayReason: nil, cancelReason: nil, timestamp: observedAt
        )
    }

    private func recent(
        _ scheduled: String,
        id: String? = nil,
        estimated: String? = nil,
        actual: String? = nil,
        cancelled: Bool = false,
        day: Int = 9,
        fromCRS: String = "VIC"
    ) -> RecentDepartureV2 {
        RecentDepartureV2(
            serviceID: id ?? scheduled,
            serviceType: "train",
            fromCRS: fromCRS,
            toCRS: "KTH",
            scheduledDeparture: scheduled,
            estimatedDeparture: estimated,
            actualDeparture: actual,
            scheduledDepartureAt: date(scheduled, day: day),
            estimatedDepartureAt: estimated.map { date($0, day: day) },
            actualDepartureAt: actual.map { date($0, day: day) },
            platform: nil,
            isCancelled: cancelled,
            lastObservedAt: date("17:32", day: day)
        )
    }

    private func date(_ time: String, day: Int = 9) -> Date {
        let components = time.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: components[0], minute: components[1]
        ))!
    }
}
