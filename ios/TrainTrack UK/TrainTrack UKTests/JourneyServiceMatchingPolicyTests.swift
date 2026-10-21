import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct JourneyServiceMatchingPolicyTests {
    private let origin = Station(crs: "VIC", name: "London Victoria", longitude: "-0.1442", latitude: "51.4951")
    private let destination = Station(crs: "KTH", name: "Kent House", longitude: "-0.0458", latitude: "51.4127")

    @Test func octoberTwentyFirstActualDiscrepancyResolvesWithinThreeMinutes() throws {
        for laterMinute in [43, 45, 46] {
            for staffIsLater in [true, false] {
                let later = "07:\(laterMinute)"
                let records = try octoberTwelfthDepartures(staffChanges: [
                    "serviceID": "staff_202610218086990_KTH_20261021T074200_P", "platform": "1",
                    "departure_time": ["scheduled": "07:42", "estimated": later,
                                       "actual": staffIsLater ? later : "07:42"],
                    "timestamp": "2026-10-21T06:46:15Z"
                ], publicChanges: [
                    "serviceID": "9925621KENTHOS_", "platform": "1",
                    "departure_time": ["scheduled": "07:42", "estimated": "07:42",
                                       "actual": staffIsLater ? "07:42" : later],
                    "timestamp": "2026-10-21T06:46:21Z"
                ])
                for ordered in [records, Array(records.reversed())] {
                    let result = JourneyServiceMatchingPolicy.match(
                        departures: ordered, recentDepartures: [], from: destination, to: origin,
                        detectedAt: ISO8601DateFormatter().date(from: "2026-10-21T06:46:12Z")!,
                        originArrivedAt: ISO8601DateFormatter().date(from: "2026-10-21T06:36:27Z")!)
                    if laterMinute <= 45 {
                        #expect(result.departure?.serviceID == (staffIsLater
                            ? "staff_202610218086990_KTH_20261021T074200_P" : "9925621KENTHOS_"))
                        #expect(result.departure?.departureTime.actual == later)
                        #expect(result.eligibleServiceIDs.count == 1)
                    } else {
                        #expect(result.departure == nil)
                        #expect(result.eligibleServiceIDs.count == 2)
                    }
                }
            }
        }
    }

    @Test func actualDiscrepancyCannotSelectTrainBeforeLaterReportedDeparture() throws {
        let records = try octoberFirstRecentDepartures(staffChanges: [
            "actualDeparture": "07:54", "actualDepartureAt": "2026-10-01T06:54:00Z"
        ], publicChanges: [
            "actualDeparture": "07:51", "actualDepartureAt": "2026-10-01T06:51:00Z"
        ])
        let result = JourneyServiceMatchingPolicy.match(
            departures: [], recentDepartures: records, from: destination, to: origin,
            detectedAt: octoberFirst("06:52:20"), originArrivedAt: octoberFirst("06:38:01"))
        #expect(result.departure == nil)
        #expect(result.eligibleServiceIDs.isEmpty)
    }

    @Test func octoberTwentiethLaterOriginPresenceExcludesAlreadyDepartedTrain() throws {
        let records = try octoberTwelfthDepartures(staffChanges: [
            "serviceID": "staff_202610208088420_VIC_20261020T172700_P",
            "platform": NSNull(), "departure_time": ["scheduled": "17:27", "estimated": "17:27"]
        ], publicChanges: [
            "serviceID": "9891538VICTRIE_", "platform": "3",
            "departure_time": ["scheduled": "17:12", "estimated": "17:14", "actual": "17:14"],
            "timestamp": "2026-10-20T16:31:15Z"
        ])
        let arrival = ISO8601DateFormatter().date(from: "2026-10-20T16:15:47Z")!
        let detected = ISO8601DateFormatter().date(from: "2026-10-20T16:31:12Z")!
        let presence = ISO8601DateFormatter().date(from: "2026-10-20T16:20:36Z")!
        func resolve(_ presence: Date?) -> JourneyServiceMatchingPolicy.Match {
            JourneyServiceMatchingPolicy.match(departures: records, recentDepartures: [],
                from: origin, to: destination, detectedAt: detected, originArrivedAt: arrival,
                lastOriginPresenceAt: presence)
        }
        #expect(resolve(nil).departure == nil)
        #expect(resolve(presence).departure?.serviceID == "staff_202610208088420_VIC_20261020T172700_P")
        // Ignore evidence outside this boarding interval, and retain the timing tolerance.
        #expect(resolve(arrival.addingTimeInterval(-60)).departure == nil)
        #expect(resolve(detected.addingTimeInterval(60)).departure == nil)
        #expect(resolve(arrival.addingTimeInterval(10)).departure == nil)
    }

    @Test func originPresenceRequiresFreshAccurateInsideFixAndSurvivesPersistence() throws {
        let arrival = date("17:15")
        let presence = arrival.addingTimeInterval(300)
        var candidate = ArmedJourneyHistoryCandidate(subscriptionId: "presence", source: .scheduled,
            stations: [origin, destination], createdAt: arrival, activeUntil: arrival.addingTimeInterval(3600),
            originArrivedAt: arrival, candidateDepartures: [])
        let accepted = candidate.recordOriginPresence(rawDistance: 80, accuracy: 20,
            observedAt: presence, receivedAt: presence.addingTimeInterval(1))
        #expect(accepted)
        for (distance, accuracy, observed, received) in [
            (80.0, 60.0, presence.addingTimeInterval(10), presence.addingTimeInterval(10)),
            (120.0, 20.0, presence.addingTimeInterval(10), presence.addingTimeInterval(10)),
            (80.0, -1.0, presence.addingTimeInterval(10), presence.addingTimeInterval(10)),
            (80.0, 20.0, presence.addingTimeInterval(10), presence.addingTimeInterval(100)),
            (80.0, 20.0, presence.addingTimeInterval(10), presence),
            (80.0, 20.0, arrival, arrival)
        ] {
            let accepted = candidate.recordOriginPresence(rawDistance: distance, accuracy: accuracy,
                observedAt: observed, receivedAt: received)
            #expect(!accepted)
        }
        let restored = try JSONDecoder().decode(ArmedJourneyHistoryCandidate.self,
            from: JSONEncoder().encode(candidate))
        #expect(restored.lastOriginPresenceAt == presence)
        #expect(restored.originArrivedAt == arrival)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(candidate)) as? [String: Any])
        legacy.removeValue(forKey: "lastOriginPresenceAt")
        #expect(try JSONDecoder().decode(ArmedJourneyHistoryCandidate.self,
            from: JSONSerialization.data(withJSONObject: legacy)).lastOriginPresenceAt == nil)
    }

    @Test func octoberNineteenthMissingPlatformsResolveToConfirmed1712Service() throws {
        let records = try octoberTwelfthDepartures(staffChanges: [
            "serviceID": "staff_202610198088416_VIC_20261019T171200_P",
            "platform": NSNull(),
            "departure_time": ["scheduled": "17:12", "estimated": "17:12"]
        ], publicChanges: [
            "serviceID": "9857195VICTRIE_", "platform": NSNull(),
            "departure_time": ["scheduled": "17:12", "estimated": "17:15", "actual": "17:15"],
            "timestamp": "2026-10-19T16:18:38Z"
        ])
        let restored = try JSONDecoder().decode([DepartureV2].self, from: JSONEncoder().encode(records))
        for departures in [records, restored, Array(restored.reversed())] {
            let result = JourneyServiceMatchingPolicy.match(
                departures: departures, recentDepartures: [], from: origin, to: destination,
                detectedAt: ISO8601DateFormatter().date(from: "2026-10-19T16:18:36Z")!,
                originArrivedAt: ISO8601DateFormatter().date(from: "2026-10-19T16:04:34Z")!
            )
            #expect(result.departure?.serviceID == "9857195VICTRIE_")
            #expect(result.departure?.departureTime.actual == "17:15")
            #expect(result.eligibleServiceIDs == ["9857195VICTRIE_"])
        }
    }

    @Test func missingPlatformDoesNotConflictWithKnownPlatformInEitherFeed() throws {
        for unknown: Any in [NSNull(), "", "  ", "TBC", " tbc "] {
            for staffHasActual in [false, true] {
                for staffHasPlatform in [false, true] {
                    var staff: [String: Any] = ["platform": staffHasPlatform ? "3" : unknown]
                    var other: [String: Any] = ["platform": staffHasPlatform ? unknown : "3"]
                    if staffHasActual {
                        staff["departure_time"] = ["scheduled": "16:42", "estimated": "16:44", "actual": "16:44"]
                        staff["timestamp"] = "2026-10-12T15:46:00Z"
                        other["departure_time"] = ["scheduled": "16:42", "estimated": "16:42"]
                        other["timestamp"] = NSNull()
                    }
                    let result = octoberTwelfthMatch(try octoberTwelfthDepartures(
                        staffChanges: staff, publicChanges: other))
                    #expect(result.departure?.serviceID == (staffHasActual
                        ? "staff_202610128088407_VIC_20261012T164200_P" : "9632411VICTRIE_"))
                }
            }
        }
    }

    @Test func missingPlatformsStillRequireConsistentDatedActualEvidence() throws {
        let conflicts: [[String: Any]] = [
            ["timestamp": NSNull()],
            ["departure_time": ["scheduled": "16:42", "estimated": "16:42"]]
        ]
        for conflict in conflicts {
            var other: [String: Any] = ["platform": NSNull()]
            other.merge(conflict) { _, new in new }
            let result = octoberTwelfthMatch(try octoberTwelfthDepartures(
                staffChanges: ["platform": NSNull()], publicChanges: other))
            #expect(result.departure == nil)
            #expect(result.eligibleServiceIDs.count == 2)
        }
        let future = octoberTwelfthMatch(try octoberTwelfthDepartures(
            staffChanges: ["platform": NSNull()], publicChanges: [
                "platform": NSNull(),
                "departure_time": ["scheduled": "16:42", "estimated": "16:47", "actual": "16:47"]
            ]))
        #expect(future.departure == nil)
        #expect(future.eligibleServiceIDs.isEmpty)
    }

    @Test func octoberTwelfthUndatedStaffSnapshotResolvesToConfirmedPublicService() throws {
        let records = try octoberTwelfthDepartures()
        // Exercise the persisted origin snapshot as well as the in-memory board.
        let restored = try JSONDecoder().decode([DepartureV2].self, from: JSONEncoder().encode(records))
        for departures in [records, restored, Array(restored.reversed())] {
            let result = octoberTwelfthMatch(departures)
            #expect(result.departure?.serviceID == "9632411VICTRIE_")
            #expect(result.departure?.departureTime.actual == "16:44")
            #expect(result.eligibleServiceIDs == ["9632411VICTRIE_"])
        }
    }

    @Test func undatedAliasStillRequiresDatedActualEvidenceAndMatchingIdentity() throws {
        let conflicts: [(staff: [String: Any], other: [String: Any])] = [
            ([:], ["timestamp": NSNull()]),
            ([:], ["departure_time": ["scheduled": "16:42", "estimated": "16:42"]]),
            (["platform": "4"], [:]),
            (["departure_time": ["scheduled": "16:42", "estimated": "16:43", "actual": "16:43"]], [:]),
            (["serviceID": "staff_202610118088407_VIC_20261011T164200_P"], [:]),
            (["serviceID": "staff_202610128088407_VIC_20261012T162700_P"], [:]),
            (["timestamp": "2026-10-12T15:46:35Z"], [:])
        ]
        for conflict in conflicts {
            let result = octoberTwelfthMatch(try octoberTwelfthDepartures(
                staffChanges: conflict.staff, publicChanges: conflict.other))
            #expect(result.departure == nil)
            #expect(result.eligibleServiceIDs.count == 2)
        }
    }

    @Test func undatedForecastCannotMatchBeforeTheConfirmedDeparture() throws {
        let records = try octoberTwelfthDepartures(publicChanges: [
            "departure_time": ["scheduled": "16:42", "estimated": "16:47", "actual": "16:47"]
        ])
        let result = octoberTwelfthMatch(records)
        #expect(result.departure == nil)
        #expect(result.eligibleServiceIDs.isEmpty)
    }

    @Test func confirmedStaffDepartureAlsoResolvesAnUndatedPublicForecast() throws {
        let records = try octoberTwelfthDepartures(staffChanges: [
            "departure_time": ["scheduled": "16:42", "estimated": "16:44", "actual": "16:44"],
            "timestamp": "2026-10-12T15:46:00Z"
        ], publicChanges: [
            "departure_time": ["scheduled": "16:42", "estimated": "16:42"],
            "timestamp": NSNull()
        ])
        #expect(octoberTwelfthMatch(records).departure?.serviceID
            == "staff_202610128088407_VIC_20261012T164200_P")
    }

    private func octoberTwelfthMatch(_ departures: [DepartureV2]) -> JourneyServiceMatchingPolicy.Match {
        JourneyServiceMatchingPolicy.match(
            departures: departures, recentDepartures: [], from: origin, to: destination,
            detectedAt: ISO8601DateFormatter().date(from: "2026-10-12T15:46:37Z")!,
            originArrivedAt: ISO8601DateFormatter().date(from: "2026-10-12T15:30:44Z")!
        )
    }

    private func octoberTwelfthDepartures(
        staffChanges: [String: Any] = [:], publicChanges: [String: Any] = [:]
    ) throws -> [DepartureV2] {
        // IDs, timetable and detection times come from the report. Platform and actual
        // departure are representative values: the export omits these recovered fields.
        var staff: [String: Any] = [
            "serviceID": "staff_202610128088407_VIC_20261012T164200_P",
            "serviceType": "train", "platform": "3", "isCancelled": false,
            "departure_time": ["scheduled": "16:42", "estimated": "16:42"]
        ]
        var other = staff
        other["serviceID"] = "9632411VICTRIE_"
        other["departure_time"] = ["scheduled": "16:42", "estimated": "16:44", "actual": "16:44"]
        other["timestamp"] = "2026-10-12T15:46:00Z"
        staff.merge(staffChanges) { _, new in new }
        other.merge(publicChanges) { _, new in new }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([DepartureV2].self, from: JSONSerialization.data(withJSONObject: [staff, other]))
    }

    @Test func octoberFirstDelayed0742IsOneTrainAcrossStaffAndPublicFeeds() throws {
        let records = try octoberFirstRecentDepartures()
        let result = JourneyServiceMatchingPolicy.match(
            departures: [], recentDepartures: records, from: destination, to: origin,
            detectedAt: octoberFirst("06:52:20"), originArrivedAt: octoberFirst("06:38:01")
        )
        #expect(result.departure?.serviceID == "staff_202610018086990_KTH_20261001T074200_P")
        #expect(result.departure?.departureTime.actual == "07:49")
        #expect(result.scheduledDepartureAt == octoberFirst("06:42:00"))
        #expect(result.timeDifferenceMinutes == 3)
    }

    @Test func publicActualDepartureResolvesAnOlderStaffForecast() throws {
        let records = try publicActualDepartureRecords()
        for orderedRecords in [records, Array(records.reversed())] {
            let result = JourneyServiceMatchingPolicy.match(
                departures: [], recentDepartures: orderedRecords, from: destination, to: origin,
                detectedAt: octoberFirst("06:52:20"), originArrivedAt: octoberFirst("06:38:01")
            )
            #expect(result.departure?.serviceID == "9277918KENTHOS_")
            #expect(result.departure?.departureTime.actual == "07:49")
            #expect(result.eligibleServiceIDs == ["9277918KENTHOS_"])
        }
    }

    @Test func publicActualEvidenceMustBeNewerAndNonConflicting() throws {
        let conflicts: [[String: Any]] = [
            ["providerObservedAt": "2026-10-01T07:50:00Z"],
            ["actualDeparture": "07:45", "actualDepartureAt": "2026-10-01T06:45:00Z"],
            ["platform": "3"]
        ]
        for conflict in conflicts {
            let result = JourneyServiceMatchingPolicy.match(
                departures: [], recentDepartures: try publicActualDepartureRecords(staffChanges: conflict),
                from: destination, to: origin,
                detectedAt: octoberFirst("06:52:20"), originArrivedAt: octoberFirst("06:38:01")
            )
            #expect(result.departure == nil)
            #expect(result.eligibleServiceIDs.count == 2)
        }
    }

    @Test func publicActualAfterDetectionCannotLeaveAnEligibleStaleStaffForecast() throws {
        let result = JourneyServiceMatchingPolicy.match(
            departures: [], recentDepartures: try publicActualDepartureRecords(actual: "07:54"),
            from: destination, to: origin,
            detectedAt: octoberFirst("06:52:20"), originArrivedAt: octoberFirst("06:38:01")
        )
        #expect(result.departure == nil)
        #expect(result.eligibleServiceIDs.isEmpty)
    }

    private func publicActualDepartureRecords(
        staffChanges: [String: Any] = [:], actual: String = "07:49"
    ) throws -> [RecentDepartureV2] {
        // Reproduce the October 8 failure shape: only the public feed supplies an
        // actual departure; the matching staff record remains a forecast.
        var staff: [String: Any] = [
            "actualDeparture": NSNull(), "actualDepartureAt": NSNull(),
            "providerObservedAt": "2026-10-01T06:40:49Z"
        ]
        staff.merge(staffChanges) { _, new in new }
        return try octoberFirstRecentDepartures(staffChanges: staff, publicChanges: [
            "actualDeparture": actual,
            "actualDepartureAt": "2026-10-01T06:\(actual.suffix(2)):00Z",
            "providerObservedAt": "2026-10-01T07:49:38Z"
        ])
    }

    @Test func feedAliasRecoveryPreservesRealAmbiguityAndRequiresNewerActualEvidence() throws {
        let conflicts: [(staff: [String: Any], other: [String: Any])] = [
            ([:], ["platform": "3"]),
            ([:], ["serviceType": "bus"]),
            ([:], ["serviceID": "staff_202610018086991_KTH_20261001T074200_P"]),
            ([:], ["actualDeparture": "07:45", "actualDepartureAt": "2026-10-01T06:45:00Z"]),
            ([:], ["providerObservedAt": "2026-10-01T07:50:00Z"]),
            (["actualDeparture": NSNull(), "actualDepartureAt": NSNull()], [:])
        ]
        for conflict in conflicts {
            let records = try octoberFirstRecentDepartures(staffChanges: conflict.staff, publicChanges: conflict.other)
            let result = JourneyServiceMatchingPolicy.match(
                departures: [], recentDepartures: records, from: destination, to: origin,
                detectedAt: octoberFirst("06:52:20"), originArrivedAt: octoberFirst("06:38:01")
            )
            #expect(result.departure == nil)
            #expect(result.eligibleServiceIDs.count == 2)
        }
    }

    @Test func aliasResolutionPrecedesEligibilitySoAnOldForecastCannotSelectAFutureTrain() throws {
        let records = try octoberFirstRecentDepartures(staffChanges: [
            "actualDeparture": "07:54", "actualDepartureAt": "2026-10-01T06:54:00Z"
        ])
        let result = JourneyServiceMatchingPolicy.match(
            departures: [], recentDepartures: records, from: destination, to: origin,
            detectedAt: octoberFirst("06:52:20"), originArrivedAt: octoberFirst("06:38:01")
        )
        #expect(result.departure == nil)
        #expect(result.eligibleServiceIDs.isEmpty)
    }

    @Test func threeSameMinuteRecordsCannotBeAssumedToBeOneTrain() throws {
        let records = try octoberFirstRecentDepartures()
        let extra = try octoberFirstRecentDepartures(publicChanges: ["serviceID": "9277919KENTHOS_"])[1]
        #expect(JourneyServiceMatchingPolicy.match(
            departures: [], recentDepartures: records + [extra], from: destination, to: origin,
            detectedAt: octoberFirst("06:52:20"), originArrivedAt: octoberFirst("06:38:01")
        ).departure == nil)
    }

    private func octoberFirst(_ time: String) -> Date {
        ISO8601DateFormatter().date(from: "2026-10-01T\(time)Z")!
    }

    private func octoberFirstRecentDepartures(
        staffChanges: [String: Any] = [:], publicChanges: [String: Any] = [:]
    ) throws -> [RecentDepartureV2] {
        // Public service observations captured from the API after the reported journey.
        // The same scheduled departure has different IDs in the two upstream feeds.
        let json = """
        [
          {"serviceID":"staff_202610018086990_KTH_20261001T074200_P","serviceType":"train",
           "fromCRS":"KTH","toCRS":"VIC","scheduledDeparture":"07:42","estimatedDeparture":"07:49",
           "actualDeparture":"07:49","scheduledDepartureAt":"2026-10-01T06:42:00Z",
           "estimatedDepartureAt":"2026-10-01T06:49:00Z","actualDepartureAt":"2026-10-01T06:49:00Z",
           "platform":"2","isCancelled":false,"providerObservedAt":"2026-10-01T07:49:38Z",
           "lastObservedAt":"2026-10-01T07:49:38Z"},
          {"serviceID":"9277918KENTHOS_","serviceType":"train","fromCRS":"KTH","toCRS":"VIC",
           "scheduledDeparture":"07:42","estimatedDeparture":"07:45","scheduledDepartureAt":"2026-10-01T06:42:00Z",
           "estimatedDepartureAt":"2026-10-01T06:45:00Z","platform":"2","isCancelled":false,
           "providerObservedAt":"2026-10-01T06:40:49Z","lastObservedAt":"2026-10-01T06:40:50Z"}
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        records[0].merge(staffChanges) { _, new in new }
        records[1].merge(publicChanges) { _, new in new }
        return try decoder.decode([RecentDepartureV2].self, from: JSONSerialization.data(withJSONObject: records))
    }

    @Test func delayed1727CanRecoverFromActualDepartureWhenTheBoardStillPredicts1740() throws {
        let board = [departure("17:27", estimated: "17:40"), departure("17:42")]
        let detectedAt = date("17:38").addingTimeInterval(30)
        #expect(JourneyServiceMatchingPolicy.match(departures: board, recentDepartures: [],
            from: origin, to: destination, detectedAt: detectedAt, originArrivedAt: date("17:20")
        ).departure == nil)
        #expect(JourneyServiceMatchingPolicy.detailRecoveryServiceIDs(
            departures: board, recentDepartures: [], detectedAt: detectedAt) == ["17:27"])
        let evidence = try #require(JourneyServiceMatchingPolicy.departureEvidence(
            serviceID: "17:27", details: recoveryDetails(), from: origin, to: destination, detectedAt: detectedAt
        ))
        let result = JourneyServiceMatchingPolicy.match(departures: board, recentDepartures: [evidence],
            from: origin, to: destination, detectedAt: detectedAt, originArrivedAt: date("17:20"))
        #expect(result.departure?.serviceID == "17:27")
        #expect(result.scheduledDepartureAt == date("17:27"))
        #expect(result.departure?.departureTime.actual == "17:38")
        #expect(result.confidence == 0.9)
        #expect(JourneyServiceMatchingPolicy.match(
            departures: board + [departure("17:32")], recentDepartures: [evidence],
            from: origin, to: destination, detectedAt: detectedAt, originArrivedAt: date("17:20")
        ).departure == nil)
    }

    @Test func recoveryDetailsMustProveDepartureOnTheCorrectRouteAndDay() throws {
        for details in [
            try recoveryDetails(actual: "Delayed"),
            try recoveryDetails(actual: "17:40"),
            try recoveryDetails(crs: "BRX"),
            try recoveryDetails(destinationCRS: "ORP"),
            try recoveryDetails(day: 8),
            try recoveryDetails(cancelled: true)
        ] {
            #expect(JourneyServiceMatchingPolicy.departureEvidence(serviceID: "17:27", details: details,
                from: origin, to: destination, detectedAt: date("17:38").addingTimeInterval(30)) == nil)
        }
    }

    @Test func recoveryLookupIncludesRecentOnlyTrainsAndExcludesOldOrFutureServices() {
        #expect(JourneyServiceMatchingPolicy.detailRecoveryServiceIDs(
            departures: [departure("16:57"), departure("17:42"), departure("17:27")],
            recentDepartures: [recent("17:27"), recent("17:12"), recent("17:20", cancelled: true)],
            detectedAt: date("17:38")
        ) == ["17:27", "17:12"])
    }

    private func recoveryDetails(actual: String = "17:38", crs: String = "VIC",
        destinationCRS: String = "KTH", day: Int = 9, cancelled: Bool = false) throws -> ServiceDetails {
        let data = try JSONSerialization.data(withJSONObject: [
            "generatedAt": ISO8601DateFormatter().string(from: date("17:39", day: day)),
            "serviceType": "train", "locationName": "London Victoria", "crs": crs,
            "std": "17:27", "etd": "17:40", "atd": actual, "isCancelled": cancelled,
            "subsequentCallingPoints": [["callingPoint": [[
                "locationName": "Kent House", "crs": destinationCRS, "st": "17:45"
            ]]]]
        ])
        return try JSONDecoder().decode(ServiceDetails.self, from: data)
    }

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

    @Test func providerDatedPayloadKeepsTheFreshBoardWhenTheOriginCacheIsMergedLast() throws {
        let fresh = try decodedDeparture("17:27", observedAt: date("17:33"))
        let cached = try decodedDeparture("17:27", estimated: "17:40", observedAt: date("17:20"))
        #expect(fresh.timestamp == nil)
        for merged in [
            JourneyServiceMatchingPolicy.mergedDepartures(originSnapshot: [fresh], currentDepartures: [cached]),
            JourneyServiceMatchingPolicy.mergedDepartures(originSnapshot: [cached], currentDepartures: [fresh])
        ] {
            #expect(merged.first?.evidenceObservedAt == date("17:33"))
            #expect(match(departures: merged).departure?.serviceID == "17:27")
        }
    }

    @Test func providerDatedOnTimeBoardSupersedesAnOlderRecentDelay() throws {
        let result = match(
            departures: [try decodedDeparture("17:27", observedAt: date("17:33"))],
            recent: [recent("17:27", estimated: "17:40", observedAt: date("17:35"))]
        )
        #expect(result.departure?.serviceID == "17:27")
        #expect(result.departure?.departureTime.estimated == "17:27")
    }

    @Test func providerDatedFutureEstimateCannotBeRolledBackByARecentOnTimeRecord() throws {
        let result = match(
            departures: [try decodedDeparture("17:27", estimated: "17:40", observedAt: date("17:33"))],
            recent: [recent("17:27", observedAt: date("17:35"))]
        )
        #expect(result.departure == nil)
    }

    @Test func recentProviderObservationCanSupersedeAnOlderBoardDespiteReceiptOrder() throws {
        let result = match(
            departures: [try decodedDeparture("17:27", estimated: "17:40", observedAt: date("17:30"))],
            recent: [recent("17:27", observedAt: date("17:32"), providerObservedAt: date("17:31"))]
        )
        #expect(result.departure?.serviceID == "17:27")
    }

    @Test func oldRecentProviderObservationCannotOverrideAFreshBoardEvenWithALaterReceipt() throws {
        let result = match(
            departures: [try decodedDeparture("17:27", observedAt: date("17:33"))],
            recent: [recent("17:27", estimated: "17:40", observedAt: date("17:35"),
                providerObservedAt: date("17:20"))]
        )
        #expect(result.departure?.serviceID == "17:27")
    }

    @Test func providerObservationDatePreventsAnOldBoardBecomingTodaysTrain() throws {
        let old = try decodedDeparture("17:27", observedAt: date("17:32", day: 8))
        #expect(match(departures: [old]).departure == nil)
    }

    @Test func providerDatedCandidatesStillRequireUnambiguousBoarding() throws {
        let result = match(departures: [
            try decodedDeparture("17:27", observedAt: date("17:33")),
            try decodedDeparture("17:32", observedAt: date("17:33"))
        ])
        #expect(result.departure == nil)
    }

    private func decodedDeparture(_ scheduled: String, estimated: String? = nil, observedAt: Date) throws -> DepartureV2 {
        // The production board has provider provenance, but no legacy `timestamp`.
        let data = try JSONSerialization.data(withJSONObject: [
            "departure_time": ["scheduled": scheduled, "estimated": estimated ?? scheduled],
            "serviceID": scheduled,
            "destination": ["crs": "KTH", "locationName": "Kent House"],
            "siri": ["providerObservedAt": ISO8601DateFormatter().string(from: observedAt)]
        ])
        return try JSONDecoder().decode(DepartureV2.self, from: data)
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
        fromCRS: String = "VIC",
        observedAt: Date? = nil,
        providerObservedAt: Date? = nil
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
            lastObservedAt: observedAt ?? date("17:32", day: day),
            providerObservedAt: providerObservedAt
        )
    }

    private func date(_ time: String, day: Int = 9) -> Date {
        let components = time.split(separator: ":").compactMap { Int($0) }
        return Calendar.current.date(from: DateComponents(
            year: 2026, month: 9, day: day, hour: components[0], minute: components[1]
        ))!
    }
}
