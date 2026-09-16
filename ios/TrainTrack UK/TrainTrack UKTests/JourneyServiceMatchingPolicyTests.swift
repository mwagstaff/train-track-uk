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

    @Test func automaticLiveActivityPreferenceCannotResolveAmbiguousBoarding() {
        let result = match(
            departures: [departure("17:27"), departure("17:32")],
            preferredServiceID: "17:27"
        )
        #expect(result.departure == nil)
        #expect(result.confidence == 0)
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
            departures: [departure("17:27", estimated: "17:40", observedAt: date("17:33"))],
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

    @Test func predictedFutureDeparturesCannotExplainAnObservedExit() {
        #expect(match(departures: [departure("17:33")]).departure != nil)
        #expect(match(departures: [departure("17:34")]).departure == nil)
        #expect(match(departures: [departure("17:35")]).departure == nil)
        #expect(match(departures: [departure("17:36")]).departure == nil)
    }

    @Test func anActualDepartureAfterTheObservedExitCannotExplainBoarding() {
        #expect(match(departures: [departure("17:27", actual: "17:34")]).departure == nil)
        #expect(match(recent: [recent("17:27", actual: "17:34")]).departure == nil)
    }

    @Test func anUnresolvedDelayCannotEstablishThatATrainDeparted() {
        #expect(match(departures: [departure("17:27", estimated: "Delayed")]).departure == nil)
        #expect(match(recent: [recent("17:27", estimated: "Delayed")]).departure == nil)
        #expect(match(departures: [departure("17:27", estimated: "On time")]).departure?.serviceID == "17:27")
        #expect(match(departures: [departure("17:27", estimated: "Delayed", actual: "17:30")]).departure?.serviceID == "17:27")
    }

    @Test func anUnresolvedDelayBeforeArrivalStillMakesAnotherTrainAmbiguous() {
        let timed = departure("17:27")
        #expect(match(departures: [departure("17:00", estimated: "Delayed"), timed]).departure == nil)
        #expect(match(departures: [timed], recent: [recent("17:00", estimated: "Delayed")]).departure == nil)
    }

    @Test func delayedKentHouseExitDoesNotChooseTheLaterTrainFromAStaleSnapshot() {
        let result = JourneyServiceMatchingPolicy.match(
            departures: [
                departure("07:42", id: "8787963KENTHOS_", estimated: "07:48", observedAt: date("07:35", day: 16)),
                departure("07:57", id: "8787966KENTHOS_", observedAt: date("07:35", day: 16))
            ],
            recentDepartures: [], from: destination, to: origin,
            detectedAt: date("07:57", day: 16).addingTimeInterval(51),
            originArrivedAt: date("07:35", day: 16)
        )
        #expect(result.departure == nil)
        #expect(result.confidence == 0)
    }

    @Test func freshDelayEstimatesRecoverThe0742InsteadOfTheNotYetDeparted0757() {
        let captured = [
            departure("07:42", id: "caught", estimated: "07:48", observedAt: date("07:35", day: 16)),
            departure("07:57", id: "later", observedAt: date("07:35", day: 16))
        ]
        let current = [
            departure("07:42", id: "caught", estimated: "07:52", observedAt: date("07:49", day: 16)),
            departure("07:57", id: "later", estimated: "08:00", observedAt: date("07:55", day: 16))
        ]
        let result = JourneyServiceMatchingPolicy.match(
            departures: JourneyServiceMatchingPolicy.mergedDepartures(originSnapshot: captured, currentDepartures: current),
            recentDepartures: [], from: destination, to: origin,
            detectedAt: date("07:57", day: 16).addingTimeInterval(51),
            originArrivedAt: date("07:35", day: 16)
        )
        #expect(result.departure?.serviceID == "caught")
        #expect(result.scheduledDepartureAt == date("07:42", day: 16))
        #expect(result.departure?.departureTime.estimated == "07:52")
    }

    @Test func refreshingTheBoardRetainsTheDepartedDelayedTrain() {
        let captured = [departure("17:12", id: "caught", estimated: "17:30", observedAt: date("17:25"))]
        let current = [departure("17:42", id: "later", observedAt: date("17:33"))]
        let merged = JourneyServiceMatchingPolicy.mergedDepartures(originSnapshot: captured, currentDepartures: current)
        #expect(Set(merged.map(\.serviceID)) == ["caught", "later"])
        #expect(match(departures: merged).departure?.serviceID == "caught")
    }

    @Test func anOlderBoardCannotRollBackANewerDelayEstimate() {
        let newer = departure("17:27", estimated: "17:40", observedAt: date("17:32"))
        let stale = departure("17:27", estimated: "17:28", observedAt: date("17:20"))
        let merged = JourneyServiceMatchingPolicy.mergedDepartures(originSnapshot: [newer], currentDepartures: [stale])
        #expect(merged.first?.departureTime.estimated == "17:40")
        #expect(match(departures: merged).departure == nil)
    }

    @Test func aPredictionBeforeTheTimetableCannotJustifyAnEarlyDeparture() {
        #expect(match(departures: [departure("17:42", estimated: "17:32")]).departure == nil)
        #expect(match(recent: [recent("17:42", estimated: "17:32")]).departure == nil)
        #expect(match(recent: [recent("17:42", actual: "17:32")]).departure?.serviceID == "17:42")
    }

    @Test func actualDepartureEvidenceSurvivesANewerForecastForTheSameTrain() {
        let result = match(
            departures: [departure("17:12", estimated: "17:40", observedAt: date("17:33")), departure("17:42")],
            recent: [recent("17:12", actual: "17:30")]
        )
        #expect(result.departure?.serviceID == "17:12")
        #expect(result.departure?.departureTime.actual == "17:30")
        #expect(result.timeDifferenceMinutes == 3)
    }

    @Test func anActualDepartureDoesNotIdentifyThePassengerAmongTwoPlausibleTrains() {
        let result = match(
            departures: [departure("17:27")],
            recent: [recent("16:57", actual: "17:32")]
        )
        #expect(result.departure == nil)
        #expect(result.confidence == 0)
    }

    @Test func aDirectBoardActualOverridesTheForecastForThatService() {
        let result = match(departures: [departure("17:12", estimated: "17:40", actual: "17:30")])
        #expect(result.departure?.serviceID == "17:12")
        #expect(result.timeDifferenceMinutes == 3)
        #expect(result.departure?.departureTime.actual == "17:30")
    }

    @Test func boardUnionPreservesActualWhenANewerBoardOnlyHasAForecast() {
        let actual = departure("17:12", estimated: "17:30", actual: "17:30", observedAt: date("17:31"))
        let forecast = departure("17:12", estimated: "17:40", observedAt: date("17:33"))
        for merged in [
            JourneyServiceMatchingPolicy.mergedDepartures(originSnapshot: [actual], currentDepartures: [forecast]),
            JourneyServiceMatchingPolicy.mergedDepartures(originSnapshot: [forecast], currentDepartures: [actual])
        ] {
            #expect(merged.first?.departureTime.actual == "17:30")
            #expect(merged.first?.departureTime.estimated == "17:40")
            #expect(merged.first?.timestamp == date("17:33"))
            #expect(match(departures: merged).departure?.serviceID == "17:12")
        }
    }

    @Test func aBoardActualSurvivesANewerRecentRecordWithoutActualData() {
        let result = match(
            departures: [departure("17:12", actual: "17:30", observedAt: date("17:31"))],
            recent: [recent("17:12", estimated: "17:40")]
        )
        #expect(result.departure?.serviceID == "17:12")
        #expect(result.departure?.departureTime.actual == "17:30")
    }

    @Test func mergingActualEvidencePreservesProviderMetadata() {
        let provenance = SiriDepartureProvenance(providerObservedAt: "2026-09-09T16:33:00Z",
            platformSource: "provider", platformObservedAt: nil, requestedOffsetMinutes: nil)
        let actual = departure("17:12", actual: "17:30", observedAt: date("17:31"))
        let newer = departure("17:12", estimated: "17:40", observedAt: date("17:33"),
            siri: provenance, hasProviderServiceID: false)
        let merged = JourneyServiceMatchingPolicy.mergedDepartures(originSnapshot: [actual], currentDepartures: [newer])
        #expect(merged.first?.siri == provenance)
        #expect(merged.first?.hasProviderServiceID == false)
        let reconstructed = match(departures: [newer], recent: [recent("17:12", actual: "17:30")])
        #expect(reconstructed.departure?.siri == provenance)
        #expect(reconstructed.departure?.hasProviderServiceID == false)
    }

    @Test func twoActuallyDepartedTrainsStillNeedEvidenceOfWhichOneWasBoarded() {
        #expect(match(recent: [recent("17:12", actual: "17:25"), recent("17:27", actual: "17:31")]).departure == nil)
    }

    @Test func aPreviousServiceDayCannotOverwriteTodaysBoardWithAReusedIdentifier() {
        let result = match(
            departures: [departure("17:27", id: "reused", observedAt: date("17:32"))],
            recent: [recent("17:27", id: "reused", actual: "17:30", day: 8)]
        )
        #expect(result.departure?.serviceID == "reused")
        #expect(result.scheduledDepartureAt == date("17:27"))
    }

    @Test func anOldDatedBoardDoesNotBecomeTodaysTrain() {
        #expect(match(departures: [departure("17:27", observedAt: date("17:32", day: 8))]).departure == nil)
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
        actual: String? = nil,
        observedAt: Date? = nil,
        siri: SiriDepartureProvenance? = nil,
        hasProviderServiceID: Bool = true
    ) -> DepartureV2 {
        DepartureV2(
            departureTime: DepartureTimeV2(scheduled: scheduled, estimated: estimated ?? scheduled, actual: actual),
            serviceType: "train", platform: nil, isCancelled: false, length: nil,
            destination: [PlaceInfoV2(crs: "KTH", locationName: "Kent House", via: nil)],
            origin: [PlaceInfoV2(crs: "VIC", locationName: "London Victoria", via: nil)],
            serviceID: id ?? scheduled, delayReason: nil, cancelReason: nil, timestamp: observedAt,
            siri: siri, hasProviderServiceID: hasProviderServiceID
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
            estimatedDepartureAt: estimated.flatMap { JourneyHistoryTime.date(for: $0, near: date(scheduled, day: day)) },
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
