import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct SiriLookupTests {
    private let observed = "2026-09-15T07:30:00Z"
    private var now: Date { date(observed) }
    private var origin: Station { station("KTH", "Kent House") }
    private var destination: Station { station("VIC", "London Victoria") }

    @Test func freshBoardOrdersByExpectedTimeAndProducesMatchingSpeechAndReferences() throws {
        let result = lookup([
            departure(id: "later", scheduled: "08:35", estimated: "08:50"),
            departure(id: "next", scheduled: "08:42"),
            departure(id: "third", scheduled: "09:00"),
            departure(id: "fourth", scheduled: "09:10")
        ])

        #expect(result.departures.map(\.serviceID) == ["next", "later", "third"])
        #expect(result.dialog.contains("08:42"))
        #expect(result.dialog.contains("in 12 minutes"))
        #expect(result.dialog.contains("platform two"))
        #expect(result.dialog.contains("running on time"))
        let first = try #require(result.departures.first)
        let reference = try #require(SiriDepartureReference(id: first.id))
        #expect(reference.serviceID == first.serviceID)
        #expect(reference.originCRS == "KTH")
        #expect(reference.destinationCRS == "VIC")
        #expect(reference.scheduledDeparture == date("2026-09-15T07:42:00Z"))
    }

    @Test func newHTTPResponseCannotMakeOldProviderOrRowDataLive() {
        let old = "2026-09-15T07:28:59Z"
        let staleBoard = snapshot([departure()], providerObservedAt: old, fetchedAt: observed)
        let staleRow = snapshot([departure(providerObservedAt: old)])
        let staleFetch = snapshot([departure()], fetchedAt: old)

        for board in [staleBoard, staleRow, staleFetch] {
            let result = SiriDeparturePolicy.result(snapshot: board, from: origin, to: destination, now: now)
            #expect(result.departures.isEmpty)
            #expect(result.freshnessLabel == "Live information unavailable")
            #expect(!result.dialog.contains("no trains"))
        }
    }

    @Test func providerFailureAndStaleBoardStateNeverBecomeAnEmptyLiveBoard() {
        var provenance = boardProvenance()
        provenance.failureReason = "provider_timeout"
        let boards = [
            JourneyDeparturesSnapshot(departures: [], dataStatus: .live, lastSuccessfulUpdate: now, siri: provenance),
            snapshot([departure()], status: .stale),
            snapshot([], status: .unavailable)
        ]
        for board in boards {
            let result = SiriDeparturePolicy.result(snapshot: board, from: origin, to: destination, now: now)
            #expect(result == .unavailable(routeLabel: "Kent House to London Victoria"))
        }
    }

    @Test func oldPayloadShapesStillDecodeButDoNotClaimFreshLiveData() throws {
        let row = #"{"departure_time":{"scheduled":"08:42","estimated":"On time"},"serviceType":"train","platform":"2","isCancelled":false,"destination":{"crs":"VIC","locationName":"London Victoria"},"serviceID":"legacy"}"#
        let array = try JSONDecoder().decode(JourneyDeparturesSnapshot.self, from: Data("[\(row)]".utf8))
        let wrapped = try JSONDecoder().decode(JourneyDeparturesSnapshot.self, from: Data("{\"departures\":[\(row)],\"data_status\":\"live\",\"last_successful_update\":\"\(observed)\"}".utf8))

        for board in [array, wrapped] {
            #expect(board.departures.first?.serviceID == "legacy")
            #expect(board.departures.first?.hasProviderServiceID == true)
            #expect(board.departures.first?.departureTime.actual == nil)
            #expect(board.siri == nil)
            #expect(SiriDeparturePolicy.result(snapshot: board, from: origin, to: destination, now: now).departures.isEmpty)
        }
    }

    @Test func retainedUnknownSuppressedAndOldPlatformsAreNotAnnounced() throws {
        for source in ["retained", "unknown", "suppressed"] {
            let result = lookup([departure(platformSource: source)])
            #expect(try #require(result.departures.first).platform == nil)
            #expect(result.dialog.contains("platform is not confirmed"))
            #expect(!result.dialog.contains("platform two"))
        }
        let oldPlatform = lookup([departure(platformObservedAt: "2026-09-15T07:28:00Z")])
        #expect(try #require(oldPlatform.departures.first).platform == nil)
        let missingPlatform = lookup([departure(platform: nil)])
        #expect(try #require(missingPlatform.departures.first).platform == nil)
        for placeholder in ["TBC", "Unknown", " "] {
            let result = lookup([departure(platform: placeholder)])
            #expect(try #require(result.departures.first).platform == nil)
        }
    }

    @Test func confirmedDeparturesAndCancelledTrainsAreExcluded() {
        let result = lookup([
            departure(id: "departed", scheduled: "08:31", actual: "08:31"),
            departure(id: "departed-on-time", scheduled: "08:32", actual: "On time"),
            departure(id: "cancelled", scheduled: "08:35", cancelled: true),
            departure(id: "cancelled-text", scheduled: "08:36", estimated: "Cancelled"),
            departure(id: "available", scheduled: "08:42")
        ])

        #expect(result.departures.map(\.serviceID) == ["available"])
        #expect(result.dialog.contains("08:35 service is cancelled"))
        #expect(result.dialog.contains("08:42"))
    }

    @Test func delayedTrainRemainsAvailableAfterScheduledDeparture() throws {
        let result = lookup([
            departure(id: "delayed", scheduled: "08:20", estimated: "08:35"),
            departure(id: "other", scheduled: "08:42")
        ])

        let first = try #require(result.departures.first)
        #expect(first.serviceID == "delayed")
        #expect(first.scheduledDeparture < now)
        #expect(first.expectedDeparture == date("2026-09-15T07:35:00Z"))
        #expect(!first.timingUncertain)
        #expect(result.dialog.contains("15 minutes late"))
    }

    @Test func delayWithoutEstimateIsExplicitlyUncertainAlongsideNextKnownEstimate() throws {
        let result = lookup([
            departure(id: "uncertain", scheduled: "08:20", estimated: "Delayed"),
            departure(id: "known", scheduled: "08:42")
        ])

        let first = try #require(result.departures.first)
        #expect(first.serviceID == "uncertain")
        #expect(first.expectedDeparture == nil)
        #expect(first.timingUncertain)
        #expect(first.statusLabel == "Delayed · No new time yet")
        #expect(result.dialog.contains("is delayed, with no new departure time yet"))
        #expect(result.dialog.contains("Another train is expected at 08:42"))
        #expect(!result.dialog.contains("has left"))
        #expect(!result.dialog.contains("running on time"))
    }

    @Test func recentlyPassedEstimateDoesNotBecomeANegativeCountdownOrConfirmedDeparture() throws {
        let result = lookup([departure(scheduled: "08:29", estimated: "08:29")])
        let first = try #require(result.departures.first)
        #expect(first.timingUncertain)
        #expect(first.statusLabel == "Departure not yet confirmed")
        #expect(result.dialog.contains("I can't confirm whether the 08:29 train from Kent House to London Victoria has left"))
        #expect(!result.dialog.contains("is delayed"))
        #expect(!result.dialog.contains("in -"))
    }

    @Test func justPassedEastCroydonDepartureExplainsUnconfirmedDepartureAndFollowingTrain() throws {
        let boardObserved = "2026-09-15T21:19:20Z"
        let board = snapshot([
            departure(id: "just-due", scheduled: "22:19", providerObservedAt: boardObserved,
                      platformObservedAt: boardObserved),
            departure(id: "following", scheduled: "22:29", providerObservedAt: boardObserved,
                      platformObservedAt: boardObserved)
        ], providerObservedAt: boardObserved, fetchedAt: boardObserved)
        let result = SiriDeparturePolicy.result(snapshot: board,
                                               from: station("ECR", "East Croydon"),
                                               to: station("BTN", "Brighton"),
                                               now: date("2026-09-15T21:19:30Z"))
        let first = try #require(result.departures.first)
        #expect(result.departures.map(\.serviceID) == ["just-due", "following"])
        #expect(first.expectedDeparture == date("2026-09-15T21:19:00Z"))
        #expect(first.timingUncertain)
        #expect(first.statusLabel == "Departure not yet confirmed")
        #expect(result.dialog.contains("I can't confirm whether the 22:19 train from East Croydon to Brighton has left"))
        #expect(result.dialog.contains("Another train is expected at 22:29"))
        #expect(!result.dialog.contains("is delayed"))
        #expect(!result.dialog.contains("has departed"))
        #expect(!result.dialog.contains("in -"))
    }

    @Test func replacementBusIsNamedInSpeechAndStructuredResult() throws {
        let result = lookup([departure(serviceType: "bus")])
        #expect(try #require(result.departures.first).transportLabel == "Replacement bus")
        #expect(result.dialog.contains("next replacement bus"))
        #expect(!result.dialog.contains("next train"))
    }

    @Test func identicalStationCodesAreRejectedRegardlessOfCase() {
        for code in ["KTH", "kth"] {
            let result = SiriDeparturePolicy.result(snapshot: snapshot([departure()]), from: origin,
                                                    to: station(code, "Kent House"), now: now)
            #expect(result.departures.isEmpty)
            #expect(result.freshnessLabel == "Invalid route")
            #expect(result.dialog.contains("two different stations"))
        }
    }

    @Test func missingProviderIdentityDoesNotExposeGeneratedUUIDAsAService() throws {
        let encoded = try JSONEncoder().encode(departure())
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "serviceID")
        let decoded = try JSONDecoder().decode(DepartureV2.self, from: JSONSerialization.data(withJSONObject: object))

        #expect(!decoded.hasProviderServiceID)
        #expect(!decoded.serviceID.isEmpty)
        #expect(lookup([decoded]).departures.isEmpty)
        #expect(!decoded.withPlatform("5").hasProviderServiceID)
        let restored = try JSONDecoder().decode(DepartureV2.self, from: JSONEncoder().encode(decoded))
        #expect(!restored.hasProviderServiceID)
        #expect(lookup([restored]).departures.isEmpty)
    }

    @Test func intermediateDestinationIsValidButEarlierAndSkippedCallsAreExcluded() {
        let valid = details(previous: [], following: [point("VIC", "08:55"), point("BTN", "09:30")])
        let beforeBoarding = details(previous: [point("VIC", "08:10")], following: [point("BTN", "09:30")])
        let skipped = details(previous: [], following: [point("VIC", "08:55", cancelled: true), point("BTN", "09:30")])

        #expect(lookup([departure()], details: ["service": valid]).departures.count == 1)
        #expect(lookup([departure()], details: ["service": beforeBoarding]).departures.isEmpty)
        #expect(lookup([departure()], details: ["service": skipped]).departures.isEmpty)
    }

    @Test func serviceDetailsActualDepartureCannotBeOfferedAgain() {
        let departed = details(previous: [], following: [point("VIC", "08:55")], actualDeparture: "08:29")
        #expect(lookup([departure()], details: ["service": departed]).departures.isEmpty)
    }

    @Test func fresherDetailTimingAndPlatformSupersedeTheBoardConsistently() throws {
        let board = departure(providerObservedAt: "2026-09-15T07:29:40Z",
                              platformObservedAt: "2026-09-15T07:29:40Z")
        let update = details(previous: [], following: [point("VIC", "09:02")],
                             expectedDeparture: "08:49", platform: "5", generatedAt: "2026-09-15T07:29:55Z")
        let result = lookup([board], details: ["service": update])
        let first = try #require(result.departures.first)
        #expect(first.expectedDeparture == date("2026-09-15T07:49:00Z"))
        #expect(first.platform == "5")
        #expect(result.dialog.contains("08:49"))
        #expect(result.dialog.contains("platform five"))
        #expect(result.dialog.contains("7 minutes late"))
        #expect(!result.dialog.contains("platform two"))

        let withdrawn = details(previous: [], following: [point("VIC", "09:02")],
                                expectedDeparture: "08:49", platform: nil, generatedAt: "2026-09-15T07:29:55Z")
        let withdrawnResult = lookup([board], details: ["service": withdrawn])
        #expect(try #require(withdrawnResult.departures.first).platform == nil)
        #expect(withdrawnResult.dialog.contains("platform is not confirmed"))
    }

    @Test func newerBoardTimingAndPlatformAreNotReplacedByOlderDetails() throws {
        let board = departure(estimated: "08:47", platform: "3")
        let older = details(previous: [], following: [point("VIC", "09:02")],
                            expectedDeparture: "08:49", platform: "2", generatedAt: "2026-09-15T07:29:45Z")
        let result = lookup([board], details: ["service": older])
        let first = try #require(result.departures.first)
        #expect(first.expectedDeparture == date("2026-09-15T07:47:00Z"))
        #expect(first.platform == "3")
        #expect(first.providerObservedAt == now)
        #expect(result.dialog.contains("08:47"))
        #expect(result.dialog.contains("platform three"))
        #expect(!result.dialog.contains("08:49"))
        #expect(!result.dialog.contains("platform two"))
    }

    @Test func newerBoardWithdrawalOrRetentionCannotResurrectOlderDetailPlatform() throws {
        let older = details(previous: [], following: [point("VIC", "09:02")],
                            platform: "2", generatedAt: "2026-09-15T07:29:45Z")
        let boards = [
            departure(platform: nil, platformSource: "unknown"),
            departure(platform: "2", platformSource: "retained"),
            departure(platform: "suppressed", platformSource: "reported")
        ]
        for board in boards {
            let result = lookup([board], details: ["service": older])
            #expect(try #require(result.departures.first).platform == nil)
            #expect(result.dialog.contains("platform is not confirmed"))
            #expect(!result.dialog.contains("platform two"))
        }
    }

    @Test func knownCancellationAndActualDepartureDoNotRequireDetailsOrMakeResultsPartial() {
        let rows = [
            departure(id: "cancelled", scheduled: "08:35", cancelled: true),
            departure(id: "departed", scheduled: "08:29", actual: "08:29"),
            departure(id: "available")
        ]
        let verified = details(previous: [], following: [point("VIC", "08:55")])
        let result = SiriDeparturePolicy.result(snapshot: snapshot(rows), from: origin, to: destination,
                                               now: now, details: ["available": verified], requireDetails: true)
        #expect(result.departures.map(\.serviceID) == ["available"])
        #expect(result.outcome == .live)
        #expect(result.dialog.contains("08:35 service is cancelled"))
        #expect(!result.dialog.contains("Some departure information is unavailable"))

        let allCancelled = SiriDeparturePolicy.result(snapshot: snapshot([rows[0]]), from: origin, to: destination,
                                                     now: now, requireDetails: true)
        #expect(allCancelled.outcome == .noDepartures)
        #expect(allCancelled.departures.isEmpty)
    }

    @Test func missingFreshnessTimestampsCannotBeReplacedByClientTime() {
        var missingProvider = boardProvenance()
        missingProvider.providerObservedAt = nil
        var missingFetch = boardProvenance()
        missingFetch.fetchedAt = nil
        for provenance in [missingProvider, missingFetch] {
            let board = JourneyDeparturesSnapshot(departures: [departure()], dataStatus: .live,
                                                  lastSuccessfulUpdate: now, siri: provenance)
            let result = SiriDeparturePolicy.result(snapshot: board, from: origin, to: destination, now: now)
            #expect(result.freshnessLabel == "Live information unavailable")
            #expect(result.departures.isEmpty)
        }
        let undated = details(previous: [], following: [point("VIC", "08:55")], generatedAt: "")
        #expect(lookup([departure()], details: ["service": undated]).freshnessLabel == "Live information unavailable")
    }

    @Test func cancelledAssociationOrRequiredChangeCannotBecomeADirectService() {
        let cancelled = details(previous: [], following: [point("VIC", "08:55")], associationCancelled: true)
        let changeRequired = details(previous: [], following: [point("VIC", "08:55")], serviceChangeRequired: true)
        for detail in [cancelled, changeRequired] {
            #expect(lookup([departure()], details: ["service": detail]).departures.isEmpty)
            #expect(SiriDeparturePolicy.trackedCalls(details: detail, from: "KTH", to: "VIC") == nil)
        }
    }

    @Test func emptyAndPartialBoardsDescribeOnlyTheirLimitedEvidence() {
        let empty = lookup([])
        let partial = SiriDeparturePolicy.result(snapshot: snapshot([], status: .partial),
                                                 from: origin, to: destination, now: now)
        #expect(empty.dialog.contains("returned departure board"))
        #expect(!empty.dialog.contains("today"))
        #expect(partial.dialog.contains("incomplete"))
        #expect(!partial.dialog.contains("no trains"))
    }

    @Test func partialBoardAvoidsNextTrainClaimAndLaterUnknownDelayDoesNotDisplaceEarlierTrain() throws {
        let partial = SiriDeparturePolicy.result(snapshot: snapshot([departure()], status: .partial),
                                                 from: origin, to: destination, now: now)
        #expect(partial.dialog.contains("A confirmed train"))
        #expect(!partial.dialog.contains("Your next"))
        #expect(partial.dialog.contains("Some departure information is unavailable"))

        let complete = lookup([
            departure(id: "earlier", scheduled: "08:42"),
            departure(id: "later-unknown", scheduled: "09:10", estimated: "Delayed")
        ])
        #expect(try #require(complete.departures.first).serviceID == "earlier")
        #expect(complete.dialog.contains("Your next train"))
        #expect(complete.dialog.contains("08:42"))
        #expect(!complete.dialog.contains("no new departure time yet"))
    }

    @Test func midnightDelayKeepsPreviousScheduledDateWithoutInventingOperatingDate() throws {
        let midnightObserved = "2026-09-15T23:00:00Z"
        let row = departure(scheduled: "23:55", estimated: "00:10", providerObservedAt: midnightObserved,
                            platformObservedAt: midnightObserved)
        let board = snapshot([row], providerObservedAt: midnightObserved, fetchedAt: midnightObserved)
        let result = SiriDeparturePolicy.result(snapshot: board, from: origin, to: destination,
                                                now: date(midnightObserved))

        let first = try #require(result.departures.first)
        #expect(first.scheduledDeparture == date("2026-09-15T22:55:00Z"))
        #expect(first.expectedDeparture == date("2026-09-15T23:10:00Z"))
        #expect(first.operatingDate == nil)
        #expect(result.dialog.contains("00:10"))
        #expect(result.dialog.contains("15 minutes late"))
        let reference = try #require(SiriDepartureReference(id: first.id))
        #expect(reference.scheduledDeparture == first.scheduledDeparture)
    }

    @Test func missingSpringHourAndRepeatedAutumnHourAreNotGuessed() {
        let spring = date("2026-03-29T00:30:00Z")
        let autumn = date("2026-10-25T00:00:00Z")
        #expect(SiriRailTime.uniqueDate("01:30", near: spring, from: 0, through: 6 * 3_600) == nil)
        #expect(SiriRailTime.uniqueDate("01:30", near: autumn, from: 0, through: 6 * 3_600) == nil)
        let repeated = SiriRailTime.candidates("01:30", near: autumn).filter {
            $0 >= autumn && $0 < autumn.addingTimeInterval(6 * 3_600)
        }
        #expect(repeated == [date("2026-10-25T00:30:00Z"), date("2026-10-25T01:30:00Z")])
    }

    @Test func LondonTimeIsInvariantAcrossTimestampOffsetsAndCountdownNeverGoesNegative() throws {
        let uk = date("2026-09-15T08:30:00+01:00")
        let abroad = date("2026-09-15T16:30:00+09:00")
        #expect(uk == abroad)
        #expect(SiriDisplayTime.format(abroad) == "08:30")
        #expect(SiriRailTime.calendar.timeZone.identifier == "Europe/London")
        let first = try #require(lookup([departure()]).departures.first)
        let later = SiriResponseFormatter.departure(first, now: date("2026-09-15T07:43:00Z"))
        #expect(later.contains("due now"))
        #expect(!later.contains("in -"))
    }

    @Test func referencePreservesExactServiceAndDateAndRejectsInvalidIdentity() throws {
        let reference = SiriDepartureReference(serviceID: "provider-id", originCRS: "KTH", destinationCRS: "VIC",
                                               scheduledDeparture: date("2025-12-31T23:55:00Z"))
        #expect(SiriDepartureReference(id: reference.id) == reference)
        #expect(SiriDepartureReference(id: "v2:anything") == nil)
        #expect(SiriDepartureReference(id: "v1:not-base64") == nil)
        #expect(SiriDepartureReference(id: String(repeating: "x", count: 2_049)) == nil)
        let invalid = SiriDepartureReference(serviceID: "", originCRS: "KTH", destinationCRS: "VIC", scheduledDeparture: now)
        #expect(SiriDepartureReference(id: invalid.id) == nil)
    }

    @Test func stationSearchPreservesVictoriaAmbiguityAndCanonicalCodes() {
        let stations = [station("VIC", "London Victoria"), station("MCV", "Manchester Victoria"), origin]
        let matches = StationsService.search(" Victoria ", in: stations)
        #expect(Set(matches.map(\.crs)) == Set(["VIC", "MCV"]))
        #expect(StationsService.search("vic", in: stations).first?.crs == "VIC")
        #expect(StationsService.search("kth", in: stations).map(\.crs) == ["KTH"])
        #expect(StationsService.search("nowhere at all", in: stations).isEmpty)
        #expect(StationsService.search("Victoria", in: stations, limit: 1).count == 1)
    }

    @Test func stationSearchNormalizesCaseWhitespacePunctuationAndDiacritics() {
        #expect(StationsService.normalizedSearchText("  LÓNDON — VICTORIA  ") == "london victoria")
        let stations = [destination, station("MCV", "Manchester Victoria")]
        #expect(StationsService.search(" LONDON—Victoria ", in: stations).map(\.crs) == ["VIC"])
        #expect(StationsService.search("King’s Cross", in: [station("KGX", "London Kings Cross")]).map(\.crs) == ["KGX"])
        #expect(StationsService.search(" --- ", in: stations).isEmpty)
    }

    @Test func checkpointReadsKeepExactActiveSelectionAndDoNotPruneExpiredCompletion() throws {
        let suite = "SiriLookupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let active = checkpoint(serviceID: "selected-service")
        let completed = RecentlyCompletedJourneyCheckpoint(checkpoint: checkpoint(serviceID: "old-service"),
                                                           outcome: .completed, completedAt: now.addingTimeInterval(-900),
                                                           autoDismissAt: now.addingTimeInterval(-300))
        let pending = ArmedJourneyHistoryCandidate(subscriptionId: "different-route", source: .adhoc,
                                                   stations: [destination, origin], createdAt: now,
                                                   activeUntil: now.addingTimeInterval(300), originArrivedAt: nil,
                                                   candidateDepartures: [])
        let envelope = JourneyHistoryCheckpointEnvelope(armedCandidates: [pending], activeJourney: active,
                                                        recentlyCompleted: completed)
        try JourneyTrackingCheckpointStore.save(envelope, to: defaults)
        let before = defaults.data(forKey: JourneyTrackingCheckpointStore.key)

        let read = try #require(JourneyTrackingCheckpointStore.load(from: defaults))
        #expect(read.activeJourney == active)
        #expect(read.activeJourney?.currentLeg?.serviceID == "selected-service")
        #expect(read.armedCandidates == [pending])
        #expect(read.recentlyCompleted?.checkpoint.currentLeg?.serviceID == "old-service")
        #expect(defaults.data(forKey: JourneyTrackingCheckpointStore.key) == before)

        defaults.set(Data("invalid".utf8), forKey: JourneyTrackingCheckpointStore.key)
        #expect(JourneyTrackingCheckpointStore.load(from: defaults) == nil)
    }

    private func lookup(_ departures: [DepartureV2], details: [String: ServiceDetails] = [:]) -> SiriLookupResult {
        SiriDeparturePolicy.result(snapshot: snapshot(departures), from: origin, to: destination, now: now, details: details)
    }

    private func snapshot(_ departures: [DepartureV2], status: JourneyDataStatus = .live,
                          providerObservedAt: String? = nil, fetchedAt: String? = nil) -> JourneyDeparturesSnapshot {
        JourneyDeparturesSnapshot(departures: departures, dataStatus: status, lastSuccessfulUpdate: now,
                                  siri: boardProvenance(providerObservedAt: providerObservedAt, fetchedAt: fetchedAt))
    }

    private func boardProvenance(providerObservedAt: String? = nil, fetchedAt: String? = nil) -> SiriBoardProvenance {
        SiriBoardProvenance(providerObservedAt: providerObservedAt ?? observed, fetchedAt: fetchedAt ?? observed,
                            requestedOffsetsMinutes: [0], searchWindowMinutes: 120, complete: false, failureReason: nil)
    }

    private func departure(id: String = "service", scheduled: String = "08:42", estimated: String? = nil,
                           actual: String? = nil, cancelled: Bool = false, serviceType: String = "train",
                           platform: String? = "2", providerObservedAt: String? = nil,
                           platformSource: String = "reported", platformObservedAt: String? = nil) -> DepartureV2 {
        DepartureV2(departureTime: .init(scheduled: scheduled, estimated: estimated ?? "On time", actual: actual),
                    serviceType: serviceType, platform: platform, isCancelled: cancelled, length: nil,
                    destination: [.init(crs: "VIC", locationName: "London Victoria", via: nil)], origin: nil,
                    serviceID: id, delayReason: nil, cancelReason: nil, timestamp: nil,
                    siri: SiriDepartureProvenance(providerObservedAt: providerObservedAt ?? observed,
                                                  platformSource: platformSource,
                                                  platformObservedAt: platformObservedAt ?? observed,
                                                  requestedOffsetMinutes: 0))
    }

    private func point(_ crs: String, _ time: String, cancelled: Bool = false) -> CallingPoint {
        CallingPoint(locationName: crs, crs: crs, st: time, et: "On time", at: nil,
                     isCancelled: cancelled, cancelReason: nil, platform: nil, length: nil,
                     detachFront: nil, affectedByDiversion: nil, rerouteDelay: nil)
    }

    private func details(previous: [CallingPoint], following: [CallingPoint],
                         actualDeparture: String? = nil, expectedDeparture: String? = "On time",
                         platform: String? = "2", generatedAt: String? = nil,
                         serviceChangeRequired: Bool = false, associationCancelled: Bool = false) -> ServiceDetails {
        ServiceDetails(previousCallingPoints: [.init(callingPoint: previous, serviceType: "train", serviceChangeRequired: false, assocIsCancelled: false)],
                       subsequentCallingPoints: [.init(callingPoint: following, serviceType: "train", serviceChangeRequired: serviceChangeRequired, assocIsCancelled: associationCancelled)],
                       generatedAt: generatedAt ?? observed, serviceType: "train", locationName: "Kent House", crs: "KTH",
                       operator: nil, operatorCode: nil, isCancelled: false, length: nil, detachFront: nil,
                       isReverseFormation: nil, platform: platform, sta: nil, eta: nil, ata: nil, std: "08:42",
                       etd: expectedDeparture, atd: actualDeparture, delayReason: nil, cancelReason: nil)
    }

    private func checkpoint(serviceID: String) -> ActiveJourneyHistoryCheckpoint {
        ActiveJourneyHistoryCheckpoint(id: UUID(), subscriptionId: "subscription-\(serviceID)", source: .adhoc,
                                       plannedStations: [origin, destination], createdAt: now, phase: .inTransit,
                                       plannedLegIndex: 0, originArrivedAt: nil, detectedDepartureAt: now,
                                       detectedArrivalAt: nil, lastConfirmedOnRouteStation: origin,
                                       nextExpectedCallingPointIndex: 0,
                                       legs: [JourneyHistoryLeg(plannedLegIndex: 0, fromStation: origin,
                                                                toStation: destination, serviceID: serviceID,
                                                                scheduledDepartureAt: now)],
                                       stationEvents: [], approachNotificationSent: false, backendSessionID: nil,
                                       serviceMatchConfidence: 1, unexpectedStation: nil, unexpectedStationObservedAt: nil,
                                       serviceDepartedStationCRS: nil, serviceDepartedStationAt: nil, updatedAt: now)
    }

    private func station(_ crs: String, _ name: String) -> Station {
        Station(crs: crs, name: name, longitude: "0", latitude: "0")
    }

    private func date(_ value: String) -> Date {
        // Fixtures are fixed, complete ISO timestamps; a parse failure is a fixture error.
        ISO8601DateFormatter().date(from: value)!
    }
}
