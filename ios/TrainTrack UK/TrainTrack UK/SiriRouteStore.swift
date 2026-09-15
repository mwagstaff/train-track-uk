import Combine
import Foundation
import AppIntents

struct SiriSavedRoute: Identifiable, Equatable {
    let id: UUID
    let origin: Station
    let destination: Station
    let displayName: String
    var isFavourite: Bool = false
    var isBidirectional: Bool = false

    var pairKey: String { siriRoutePairKey(origin, destination) }
    var stationSummary: String {
        "\(origin.name) \(isBidirectional ? "↔" : "→") \(destination.name)"
    }
}

private func siriRoutePairKey(_ origin: Station, _ destination: Station) -> String {
    [origin.crs, destination.crs]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        .sorted()
        .joined(separator: "|")
}

@MainActor
final class SiriRouteStore: ObservableObject {
    static let shared = SiriRouteStore(
        defaults: UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard,
        updateSuggestions: { TrainTrackShortcuts.updateAppShortcutParameters() }
    )

    let objectWillChange = ObservableObjectPublisher()

    private static let defaultRouteKey = "siri_default_route_id_v1"
    private static let legacyRouteNamesKey = "siri_route_names_v1"
    private static let routeNamesKey = "siri_route_names_v2"
    private let defaults: UserDefaults
    private let readJourneys: () -> [Journey]
    private let updateSuggestions: () -> Void

    init(
        defaults: UserDefaults,
        readJourneys: (() -> [Journey])? = nil,
        updateSuggestions: @escaping () -> Void = {}
    ) {
        self.defaults = defaults
        self.readJourneys = readJourneys ?? {
            guard let data = defaults.data(forKey: "saved_journeys") else { return [] }
            return (try? JSONDecoder().decode([Journey].self, from: data)) ?? []
        }
        self.updateSuggestions = updateSuggestions
    }

    /// Favourites and My Journeys share one entry for each saved outward/return pair.
    var routes: [SiriSavedRoute] {
        let saved = savedRoutes()
        return Dictionary(grouping: saved, by: \.pairKey).compactMap { _, routes in
            routes.min { $0.id.uuidString < $1.id.uuidString }
        }.sorted {
            let comparison = $0.displayName.localizedStandardCompare($1.displayName)
            return comparison == .orderedSame
                ? $0.id.uuidString < $1.id.uuidString
                : comparison == .orderedAscending
        }
    }

    var defaultRouteID: UUID? {
        defaults.string(forKey: Self.defaultRouteKey).flatMap(UUID.init(uuidString:))
    }

    var defaultRoute: SiriSavedRoute? {
        guard let id = defaultRouteID else { return nil }
        return route(id: id)
    }

    /// A named route remains discoverable even when it is not the default.
    var namedExampleRoute: SiriSavedRoute? {
        if let route = defaultRoute, !name(for: route.id).isEmpty { return route }
        return routes.first { !name(for: $0.id).isEmpty }
    }

    /// Keep every existing group UUID and its station orientation resolvable.
    func route(id: UUID) -> SiriSavedRoute? {
        savedRoutes().first { $0.id == id }
    }

    /// Only return directions the user actually saved, with the requested one first.
    func directions(for id: UUID) -> [SiriSavedRoute] {
        let saved = savedRoutes()
        guard let original = saved.first(where: { $0.id == id }) else { return [] }
        let reverse = saved.filter {
            $0.id != id && $0.origin.crs.caseInsensitiveCompare(original.destination.crs) == .orderedSame
                && $0.destination.crs.caseInsensitiveCompare(original.origin.crs) == .orderedSame
        }.min { $0.id.uuidString < $1.id.uuidString }
        return [original] + (reverse.map { [$0] } ?? [])
    }

    func name(for id: UUID) -> String {
        let journeys = directJourneys()
        guard let journey = journeys.first(where: { $0.groupId == id }) else { return "" }
        return sharedName(for: siriRoutePairKey(journey.fromStation, journey.toStation), journeys: journeys)
    }

    func setDefaultRoute(id: UUID?) {
        if let id, route(id: id) == nil { return }
        guard defaultRouteID != id else { return }
        objectWillChange.send()
        preserveLegacyNames()
        if let id {
            defaults.set(id.uuidString, forKey: Self.defaultRouteKey)
        } else {
            defaults.removeObject(forKey: Self.defaultRouteKey)
        }
        updateSuggestions()
    }

    func setName(_ name: String, for id: UUID) {
        guard let route = route(id: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = routeNames
        guard names[route.pairKey] != trimmed else { return }
        // An explicit blank overrides old per-direction names without deleting them.
        names[route.pairKey] = trimmed
        objectWillChange.send()
        defaults.set(names, forKey: Self.routeNamesKey)
        updateSuggestions()
    }

    /// Call before a saved-journey or default edit, while old group IDs are still
    /// available. Querying routes never migrates data or updates suggestions.
    func preserveLegacyNames() {
        let journeys = directJourneys()
        let existingNames = routeNames
        var names = existingNames
        for journey in journeys {
            let key = siriRoutePairKey(journey.fromStation, journey.toStation)
            guard names[key] == nil else { continue }
            let resolvedName = sharedName(for: key, journeys: journeys)
            if !resolvedName.isEmpty { names[key] = resolvedName }
        }
        if names != existingNames { defaults.set(names, forKey: Self.routeNamesKey) }
    }

    /// Called after the existing journey store has persisted a route edit.
    func refresh() {
        objectWillChange.send()
        updateSuggestions()
    }

    private var routeNames: [String: String] {
        defaults.dictionary(forKey: Self.routeNamesKey) as? [String: String] ?? [:]
    }

    private func directJourneys() -> [Journey] {
        Dictionary(grouping: readJourneys(), by: \.groupId).compactMap { _, legs in
            guard legs.count == 1, let leg = legs.first, leg.legIndex == 0 else { return nil }
            return leg
        }
    }

    private func sharedName(for key: String, journeys: [Journey]) -> String {
        if let name = routeNames[key] { return name.trimmingCharacters(in: .whitespacesAndNewlines) }
        let legacyNames = defaults.dictionary(forKey: Self.legacyRouteNamesKey) as? [String: String] ?? [:]
        let pair = journeys.filter { siriRoutePairKey($0.fromStation, $0.toStation) == key }.sorted {
            if ($0.groupId == defaultRouteID) != ($1.groupId == defaultRouteID) {
                return $0.groupId == defaultRouteID
            }
            return $0.groupId.uuidString < $1.groupId.uuidString
        }
        return pair.lazy.compactMap { journey -> String? in
            let name = (legacyNames[journey.groupId.uuidString] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : name
        }.first ?? ""
    }

    private func savedRoutes() -> [SiriSavedRoute] {
        let journeys = directJourneys()
        let pairs = Dictionary(grouping: journeys) { siriRoutePairKey($0.fromStation, $0.toStation) }
        return journeys.map { journey in
            let key = siriRoutePairKey(journey.fromStation, journey.toStation)
            let pair = pairs[key] ?? [journey]
            let bidirectional = pair.contains {
                $0.groupId != journey.groupId
                    && $0.fromStation.crs.caseInsensitiveCompare(journey.toStation.crs) == .orderedSame
                    && $0.toStation.crs.caseInsensitiveCompare(journey.fromStation.crs) == .orderedSame
            }
            let title = sharedName(for: key, journeys: pair)
            let stations = "\(journey.fromStation.name) \(bidirectional ? "↔" : "→") \(journey.toStation.name)"
            return SiriSavedRoute(
                id: journey.groupId,
                origin: journey.fromStation,
                destination: journey.toStation,
                displayName: title.isEmpty ? stations : title,
                isFavourite: pair.contains(where: \.favorite),
                isBidirectional: bidirectional
            )
        }
    }
}
