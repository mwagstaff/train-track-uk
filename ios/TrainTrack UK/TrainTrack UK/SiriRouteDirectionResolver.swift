import CoreLocation
import Foundation

@MainActor
enum SiriRouteDirectionDecision {
    case selected(SiriSavedRoute)
    case needsDirection([SiriSavedRoute])
    case invalidDepartureStation
    case unavailable
}

@MainActor
enum SiriRouteDirectionResolver {
    static func resolve(
        directions: [SiriSavedRoute],
        departureStationCRS: String?,
        now: @escaping () -> Date = { Date() },
        location: () async throws -> CLLocation? = { try await SiriRouteLocationProvider.currentLocation() }
    ) async throws -> SiriRouteDirectionDecision {
        try Task.checkCancellation()
        // An explicit station and a one-way saved route do not need location access.
        let observation = departureStationCRS == nil && directions.count > 1 ? try await location() : nil
        try Task.checkCancellation()
        return select(directions: directions, departureStationCRS: departureStationCRS,
                      location: observation, now: now())
    }

    static func select(directions: [SiriSavedRoute], departureStationCRS: String?,
                       location: CLLocation?, now: Date) -> SiriRouteDirectionDecision {
        guard !directions.isEmpty else { return .unavailable }
        if let departureStationCRS {
            guard let direction = directions.first(where: {
                $0.origin.crs.caseInsensitiveCompare(departureStationCRS) == .orderedSame
            }) else { return .invalidDepartureStation }
            return .selected(direction)
        }
        if directions.count == 1, let direction = directions.first { return .selected(direction) }
        guard let location, SiriRouteLocationProvider.isUsable(location, now: now),
              directions.allSatisfy({ route in
                  route.origin.coordinates.allSatisfy {
                      CLLocationCoordinate2DIsValid($0) && ($0.latitude != 0 || $0.longitude != 0)
                  }
              }) else { return .needsDirection(directions) }

        let ranked = directions.map { (route: $0, distance: $0.origin.distance(from: location)) }
            .sorted { $0.distance < $1.distance }
        guard ranked.allSatisfy({ $0.distance.isFinite }), let first = ranked.first,
              let second = ranked.dropFirst().first,
              second.distance - first.distance > max(200, 2 * location.horizontalAccuracy) else {
            // An accuracy circle or a near tie must not silently reverse a journey.
            return .needsDirection(directions)
        }
        return .selected(first.route)
    }
}
