import CoreLocation
import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
struct SiriRouteDirectionTests {
    private let now = Date(timeIntervalSince1970: 1_789_500_000)
    private let kentHouse = Station(crs: "KTH", name: "Kent House", longitude: "-0.045786", latitude: "51.412659")
    private let victoria = Station(crs: "VIC", name: "London Victoria", longitude: "-0.144200", latitude: "51.495100")

    private var outward: SiriSavedRoute {
        SiriSavedRoute(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                       origin: kentHouse, destination: victoria, displayName: "Work")
    }

    private var returning: SiriSavedRoute {
        SiriSavedRoute(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                       origin: victoria, destination: kentHouse, displayName: "Work")
    }

    private func location(at station: Station, age: TimeInterval = 0, accuracy: Double = 30) -> CLLocation {
        CLLocation(coordinate: station.coordinate, altitude: 0, horizontalAccuracy: accuracy,
                   verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
    }

    @Test func nearerEndSelectsBothOutwardAndReturnRegardlessOfStoredOrder() {
        for (station, expected) in [(kentHouse, outward), (victoria, returning)] {
            let decision = SiriRouteDirectionResolver.select(directions: [returning, outward], departureStationCRS: nil,
                                                              location: location(at: station), now: now)
            guard case .selected(let selected) = decision else { Issue.record("Expected nearest direction"); return }
            #expect(selected.id == expected.id)
            #expect(selected.origin == station)
        }
    }

    @Test func explicitDepartureOverridesLocationAndDoesNotRequestIt() async throws {
        let decision = try await SiriRouteDirectionResolver.resolve(
            directions: [outward, returning], departureStationCRS: "vic", now: { now },
            location: { Issue.record("Explicit direction must not request location"); return nil }
        )
        guard case .selected(let selected) = decision else { Issue.record("Expected explicit direction"); return }
        #expect(selected.id == returning.id)
    }

    @Test func oneWayRouteNeverInventsAnUnstoredReturnOrRequestsLocation() async throws {
        let decision = try await SiriRouteDirectionResolver.resolve(
            directions: [outward], departureStationCRS: nil, now: { now },
            location: { Issue.record("One-way route must not request location"); return nil }
        )
        guard case .selected(let selected) = decision else { Issue.record("Expected saved direction"); return }
        #expect(selected.id == outward.id)
    }

    @Test func unavailableStaleOrInaccurateLocationAsksForDirection() {
        let observations: [CLLocation?] = [nil, location(at: kentHouse, age: 61),
                                         location(at: kentHouse, age: -10), location(at: kentHouse, accuracy: 2_000)]
        for observation in observations {
            let decision = SiriRouteDirectionResolver.select(directions: [outward, returning], departureStationCRS: nil,
                                                              location: observation, now: now)
            guard case .needsDirection(let choices) = decision else { Issue.record("Expected direction prompt"); continue }
            #expect(choices.map(\.id) == [outward.id, returning.id])
        }
    }

    @Test func nearTieDoesNotGuess() {
        let midpoint = CLLocation(coordinate: CLLocationCoordinate2D(
            latitude: (kentHouse.coordinate.latitude + victoria.coordinate.latitude) / 2,
            longitude: (kentHouse.coordinate.longitude + victoria.coordinate.longitude) / 2),
            altitude: 0, horizontalAccuracy: 100, verticalAccuracy: -1, timestamp: now)
        let decision = SiriRouteDirectionResolver.select(directions: [outward, returning], departureStationCRS: nil,
                                                          location: midpoint, now: now)
        guard case .needsDirection = decision else { Issue.record("A near tie must ask for direction"); return }
    }

    @Test func invalidStationCoordinatesDoNotSelectAFalseNearestEnd() {
        let invalid = SiriSavedRoute(id: returning.id,
                                    origin: Station(crs: "VIC", name: "London Victoria", longitude: "0", latitude: "0"),
                                    destination: kentHouse, displayName: "Work")
        let decision = SiriRouteDirectionResolver.select(directions: [outward, invalid], departureStationCRS: nil,
                                                          location: location(at: kentHouse), now: now)
        guard case .needsDirection = decision else { Issue.record("Missing coordinates must ask for direction"); return }
    }

    @Test func unrelatedExplicitStationIsRejected() {
        let decision = SiriRouteDirectionResolver.select(directions: [outward, returning], departureStationCRS: "ECR",
                                                          location: location(at: kentHouse), now: now)
        guard case .invalidDepartureStation = decision else { Issue.record("Invalid override must be rejected"); return }
    }

    @Test func cancellationIsNotConvertedIntoADirectionPrompt() async {
        do {
            _ = try await SiriRouteDirectionResolver.resolve(directions: [outward, returning], departureStationCRS: nil,
                                                             location: { throw CancellationError() })
            Issue.record("Expected cancellation")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @Test func existingActionsDefaultToAutomaticDirectionWithoutANewRequiredParameter() {
        #expect(GetNextFavouriteTrainIntent().departureStation == nil)
        #expect(GetNextTrainsForSavedRouteIntent().departureStation == nil)
    }
}
