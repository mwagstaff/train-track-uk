import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct SiriLookupServiceTests {
    private var now: Date { ISO8601DateFormatter().date(from: "2026-09-15T07:30:00Z")! }
    private var origin: Station { Station(crs: "KTH", name: "Kent House", longitude: "0", latitude: "0") }
    private var destination: Station { Station(crs: "VIC", name: "London Victoria", longitude: "0", latitude: "0") }

    @Test func lookupMakesOneBoardRequestAndOneBoundedDetailsRequest() async throws {
        var boardCalls = 0
        var detailCalls: [[String]] = []
        let board = snapshot((0..<15).map { departure(id: "service-\($0)") })
        let detail = details()
        let service = makeService(fetchBoard: { from, to in
            #expect(from.crs == "KTH" && to.crs == "VIC")
            boardCalls += 1
            return board
        }, fetchDetails: { ids in
            detailCalls.append(ids)
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, detail) })
        })

        let result = try await service.lookup(from: origin, to: destination)
        #expect(boardCalls == 1)
        #expect(detailCalls.count == 1)
        #expect(detailCalls.first?.count == 12)
        #expect(result.departures.count == 3)
        #expect(result.departures.allSatisfy { detailCalls[0].contains($0.serviceID) })
    }

    @Test func invalidRouteAndUnavailableBoardAvoidExtraRequests() async throws {
        var boardCalls = 0
        var detailCalls = 0
        let unavailable = JourneyDeparturesSnapshot(departures: [], dataStatus: .unavailable, lastSuccessfulUpdate: nil)
        let service = makeService(fetchBoard: { _, _ in boardCalls += 1; return unavailable },
                                  fetchDetails: { _ in detailCalls += 1; return [:] })
        let sameStation = Station(crs: "kth", name: "Kent House", longitude: "0", latitude: "0")
        let invalid = try await service.lookup(from: origin, to: sameStation)
        #expect(invalid.freshnessLabel == "Invalid route")
        #expect(boardCalls == 0 && detailCalls == 0)
        let result = try await service.lookup(from: origin, to: destination)
        #expect(result.freshnessLabel == "Live information unavailable")
        #expect(boardCalls == 1 && detailCalls == 0)
    }

    @Test func networkAuthenticationRateLimitAndMalformedFailuresAreUnavailable() async throws {
        let failures: [Error] = [
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
            PhoneNetworkError.httpStatus(401),
            PhoneNetworkError.httpStatus(429),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Synthetic malformed payload"))
        ]
        for failure in failures {
            let service = makeService(fetchBoard: { _, _ in throw failure })
            let result = try await service.lookup(from: origin, to: destination)
            #expect(result.departures.isEmpty)
            #expect(result.freshnessLabel == "Live information unavailable")
            #expect(!result.dialog.contains("no trains"))
        }
    }

    @Test func failedDetailVerificationDoesNotPromoteAnUnverifiedBoardResult() async throws {
        let board = snapshot([departure()])
        let service = makeService(fetchBoard: { _, _ in board }, fetchDetails: { _ in throw URLError(.networkConnectionLost) })
        let result = try await service.lookup(from: origin, to: destination)
        #expect(result.departures.isEmpty)
        #expect(result.freshnessLabel == "Live information unavailable")
    }

    @Test func deadlineCancelsOutstandingNetworkWork() async throws {
        var requestCancelled = false
        let board = snapshot([departure()])
        let service = makeService(deadlineSeconds: 0.02, fetchBoard: { _, _ in
            do {
                try await Task.sleep(for: .seconds(5))
                return board
            } catch {
                requestCancelled = Task.isCancelled
                throw error
            }
        })
        let result = try await service.lookup(from: origin, to: destination)
        #expect(requestCancelled)
        #expect(result.freshnessLabel == "Live information unavailable")
    }

    @Test func userCancellationPropagatesAndStopsTheRequest() async throws {
        let signal = AsyncStream<Void>.makeStream()
        var requestCancelled = false
        let board = snapshot([departure()])
        let service = makeService(fetchBoard: { _, _ in
            signal.continuation.yield(())
            defer { signal.continuation.finish() }
            do {
                try await Task.sleep(for: .seconds(5))
                return board
            } catch {
                requestCancelled = Task.isCancelled
                throw error
            }
        })
        let task = Task { try await service.lookup(from: origin, to: destination) }
        for await _ in signal.stream { break }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancellation should propagate instead of returning an unavailable result")
        } catch is CancellationError {
            #expect(requestCancelled)
        } catch {
            Issue.record("Unexpected cancellation error: \(error)")
        }
    }

    @Test func concurrentInvocationsKeepTheirOwnBoardResults() async throws {
        var boardCalls = 0
        let detail = details()
        let service = makeService(fetchBoard: { _, _ in
            boardCalls += 1
            let id = "invocation-\(boardCalls)"
            await Task.yield()
            return snapshot([departure(id: id)])
        }, fetchDetails: { ids in
            await Task.yield()
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, detail) })
        })
        async let first = service.lookup(from: origin, to: destination)
        async let second = service.lookup(from: origin, to: destination)
        let results = try await [first, second]

        #expect(boardCalls == 2)
        #expect(Set(results.compactMap { $0.departures.first?.serviceID }) == Set(["invocation-1", "invocation-2"]))
        #expect(results.allSatisfy { $0.departures.count == 1 })
    }

    @Test func noActiveTrainOrInterchangeDoesNotFetchOrSelectTheNextTrain() async throws {
        var requests = 0
        let empty = snapshot([])
        var active: ActiveJourneyHistoryCheckpoint?
        let service = makeService(fetchBoard: { _, _ in requests += 1; return empty },
                                  fetchDetails: { _ in requests += 1; return [:] },
                                  readActive: { active })
        let missing = try await service.trackedJourneyStatus()
        #expect(missing.dialog.contains("don't have a train selected"))
        active = checkpoint(phase: .atInterchange)
        let interchange = try await service.trackedJourneyPlatform()
        #expect(interchange.dialog.contains("don't have a train selected"))
        #expect(requests == 0)
    }

    @Test func trackedLookupUsesOnlyTheExactServiceAndBoardingPlatform() async throws {
        let active = checkpoint()
        let detail = details(boardingPlatform: "2", arrivalPlatform: "9")
        var requestedIDs: [[String]] = []
        var boardCalls = 0
        let empty = snapshot([])
        let service = makeService(fetchBoard: { _, _ in boardCalls += 1; return empty },
                                  fetchDetails: { ids in requestedIDs.append(ids); return ["selected": detail] },
                                  readActive: { active })
        let result = try await service.trackedJourneyPlatform()

        #expect(requestedIDs == [["selected"]])
        #expect(boardCalls == 0)
        #expect(result.departures.first?.serviceID == "selected")
        #expect(result.departures.first?.platform == "2")
        #expect(result.dialog.contains("platform two"))
        #expect(!result.dialog.contains("platform nine"))
    }

    @Test func trackedServiceMissingOrChangedDuringRefreshNeverRebounds() async throws {
        var active = checkpoint()
        let detail = details()
        let missingService = makeService(fetchDetails: { _ in ["some-other-service": detail] }, readActive: { active })
        let missingResult = try await missingService.trackedJourneyStatus()
        #expect(missingResult.freshnessLabel == "Live information unavailable")
        #expect(missingResult.departures.isEmpty)

        let changedService = makeService(fetchDetails: { _ in
            active = checkpoint(serviceID: "replacement")
            return ["selected": detail]
        }, readActive: { active })
        let changedResult = try await changedService.trackedJourneyStatus()
        #expect(changedResult.dialog.contains("tracked train changed"))
        #expect(changedResult.departures.isEmpty)
    }

    @Test func expiredDepartureReferencesAreRejectedWithoutAnyRequest() async throws {
        var requests = 0
        let empty = snapshot([])
        let service = makeService(fetchBoard: { _, _ in requests += 1; return empty },
                                  loadStations: { requests += 1; return [] })
        let expired = SiriDepartureReference(serviceID: "expired", originCRS: "KTH", destinationCRS: "VIC",
                                             scheduledDeparture: now.addingTimeInterval(-25 * 3_600))
        #expect(try await service.resolveDeparture(id: expired.id) == nil)
        #expect(try await service.resolveDeparture(id: "unrecognised") == nil)
        #expect(requests == 0)
    }

    @Test func exactDepartureRehydrationRejectsPartialCancellationWithoutSelectingAReplacement() async throws {
        let board = snapshot([departure(id: "selected"), departure(id: "replacement")])
        let cancelledCall = details(arrivalCancelled: true)
        let replacement = details()
        let catalogue = [origin, destination]
        var requests: [[String]] = []
        let service = makeService(fetchBoard: { _, _ in board }, fetchDetails: { ids in
            requests.append(ids)
            return ["selected": cancelledCall, "replacement": replacement]
        }, loadStations: { catalogue })
        let reference = SiriDepartureReference(serviceID: "selected", originCRS: "KTH", destinationCRS: "VIC",
                                               scheduledDeparture: now.addingTimeInterval(12 * 60))

        #expect(try await service.resolveDeparture(id: reference.id) == nil)
        #expect(requests == [["selected"]])
    }

    @Test func staleDetailsCannotBecomeLiveInDepartureOrTrackedAnswers() async throws {
        let board = snapshot([departure()])
        let stale = details(generatedAt: "2026-09-15T07:28:00Z")
        let active = checkpoint()
        let service = makeService(fetchBoard: { _, _ in board }, fetchDetails: { _ in ["selected": stale] },
                                  readActive: { active })

        let departures = try await service.lookup(from: origin, to: destination)
        let tracked = try await service.trackedJourneyStatus()
        for result in [departures, tracked] {
            #expect(result.departures.isEmpty)
            #expect(result.freshnessLabel == "Live information unavailable")
            #expect(!result.dialog.contains("no trains"))
        }
    }

    @Test func trackedCancelledAssociationCannotSupplyADestinationOrPlatform() async throws {
        let active = checkpoint()
        let cancelled = details(associationCancelled: true)
        let service = makeService(fetchDetails: { _ in ["selected": cancelled] }, readActive: { active })

        let result = try await service.trackedJourneyPlatform()
        #expect(result.departures.isEmpty)
        #expect(result.dialog.contains("couldn't confirm"))
        #expect(!result.dialog.contains("platform two"))
    }

    @Test func trackedDestinationUsesTheCallAfterBoardingWhenTheStationRepeats() async throws {
        let previousVisit = CallingPoint(locationName: "London Victoria", crs: "VIC", st: "08:00", et: nil,
                                         at: "08:00", isCancelled: false, cancelReason: nil, platform: "8",
                                         length: nil, detachFront: nil, affectedByDiversion: nil, rerouteDelay: nil)
        let active = checkpoint()
        let repeated = details(previous: [previousVisit])
        let service = makeService(fetchDetails: { _ in ["selected": repeated] }, readActive: { active })

        let result = try await service.trackedJourneyStatus()
        #expect(result.dialog.contains("expected at London Victoria at 08:55"))
        #expect(!result.dialog.contains("has arrived"))
        #expect(result.departures.first?.platform == "2")
    }

    @Test func explicitStationSearchIsColdAndKeepsAmbiguousCandidates() async throws {
        let catalogue = [origin, destination, Station(crs: "MCV", name: "Manchester Victoria", longitude: "0", latitude: "0")]
        var loads = 0
        let service = makeService(loadStations: { loads += 1; return catalogue })
        let matches = try await service.stations(matching: "Victoria")
        #expect(Set(matches.map(\.crs)) == Set(["VIC", "MCV"]))
        let restored = try await service.stations(identifiers: ["vic", "KTH", "missing"])
        #expect(restored.map(\.crs) == ["VIC", "KTH"])
        #expect(loads == 2)
    }

    private func makeService(
        deadlineSeconds: Double = 1,
        fetchBoard: @escaping @MainActor (Station, Station) async throws -> JourneyDeparturesSnapshot = { _, _ in
            throw SiriLookupError.unavailable
        },
        fetchDetails: @escaping @MainActor ([String]) async throws -> [String: ServiceDetails] = { _ in [:] },
        loadStations: @escaping @MainActor () async throws -> [Station] = { [] },
        readActive: @escaping @MainActor () -> ActiveJourneyHistoryCheckpoint? = { nil }
    ) -> SiriLookupService {
        let fixedNow = now
        return SiriLookupService(clock: { fixedNow }, deadlineSeconds: deadlineSeconds,
                                 fetchBoard: fetchBoard, fetchDetails: fetchDetails,
                                 loadStations: loadStations, readActive: readActive,
                                 recordOutcome: { _, _, _ in })
    }

    private func snapshot(_ departures: [DepartureV2]) -> JourneyDeparturesSnapshot {
        JourneyDeparturesSnapshot(departures: departures, dataStatus: .live, lastSuccessfulUpdate: now,
                                  siri: SiriBoardProvenance(providerObservedAt: "2026-09-15T07:30:00Z",
                                                            fetchedAt: "2026-09-15T07:30:00Z",
                                                            requestedOffsetsMinutes: [0], searchWindowMinutes: 120,
                                                            complete: false, failureReason: nil))
    }

    private func departure(id: String = "selected") -> DepartureV2 {
        DepartureV2(departureTime: .init(scheduled: "08:42", estimated: "On time"), serviceType: "train",
                    platform: "2", isCancelled: false, length: nil,
                    destination: [.init(crs: "VIC", locationName: "London Victoria", via: nil)], origin: nil,
                    serviceID: id, delayReason: nil, cancelReason: nil, timestamp: nil,
                    siri: SiriDepartureProvenance(providerObservedAt: "2026-09-15T07:30:00Z", platformSource: "reported",
                                                  platformObservedAt: "2026-09-15T07:30:00Z", requestedOffsetMinutes: 0))
    }

    private func details(boardingPlatform: String = "2", arrivalPlatform: String = "9",
                         generatedAt: String = "2026-09-15T07:30:00Z", arrivalCancelled: Bool = false,
                         associationCancelled: Bool = false, previous: [CallingPoint] = []) -> ServiceDetails {
        let arrival = CallingPoint(locationName: "London Victoria", crs: "VIC", st: "08:55", et: "On time", at: nil,
                                   isCancelled: arrivalCancelled, cancelReason: nil, platform: arrivalPlatform, length: nil,
                                   detachFront: nil, affectedByDiversion: nil, rerouteDelay: nil)
        return ServiceDetails(previousCallingPoints: previous.isEmpty ? nil : [.init(callingPoint: previous, serviceType: "train",
                                                                                  serviceChangeRequired: false, assocIsCancelled: false)],
                              subsequentCallingPoints: [.init(callingPoint: [arrival], serviceType: "train",
                                                               serviceChangeRequired: false, assocIsCancelled: associationCancelled)],
                              generatedAt: generatedAt, serviceType: "train", locationName: "Kent House", crs: "KTH",
                              operator: nil, operatorCode: nil, isCancelled: false, length: nil, detachFront: nil,
                              isReverseFormation: nil, platform: boardingPlatform, sta: nil, eta: nil, ata: nil,
                              std: "08:42", etd: "On time", atd: nil, delayReason: nil, cancelReason: nil)
    }

    private func checkpoint(serviceID: String = "selected", phase: JourneyTrackingPhase = .inTransit) -> ActiveJourneyHistoryCheckpoint {
        ActiveJourneyHistoryCheckpoint(id: UUID(), subscriptionId: "subscription", source: .adhoc,
                                       plannedStations: [origin, destination], createdAt: now, phase: phase,
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
}
