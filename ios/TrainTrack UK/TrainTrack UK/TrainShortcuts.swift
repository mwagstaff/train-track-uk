import AppIntents
import Foundation
import SwiftUI

struct StationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Station"
    static let defaultQuery = StationEntityQuery()

    let id: String
    @Property(title: "Station name") var name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(id)")
    }
}

nonisolated struct StationEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [StationEntity] {
        try await SiriLookupService.shared.stations(identifiers: identifiers)
            .map { StationEntity(id: $0.crs, name: $0.name) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [StationEntity] {
        try await SiriLookupService.shared.stations(matching: string)
            .map { StationEntity(id: $0.crs, name: $0.name) }
    }

    @MainActor
    func suggestedEntities() async throws -> [StationEntity] {
        try await SiriLookupService.shared.stations(matching: nil)
            .map { StationEntity(id: $0.crs, name: $0.name) }
    }
}

struct SavedRouteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Saved route"
    static let defaultQuery = SavedRouteEntityQuery()

    let id: UUID
    @Property(title: "Route name") var name: String
    @Property(title: "From station") var origin: String
    @Property(title: "To station") var destination: String

    @MainActor
    init(route: SiriSavedRoute) {
        id = route.id
        name = route.displayName
        origin = route.origin.name
        destination = route.destination.name
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(origin) / \(destination)")
    }
}

nonisolated struct SavedRouteEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [SavedRouteEntity] {
        try Task.checkCancellation()
        return identifiers.prefix(100).compactMap { id in
            SiriRouteStore.shared.route(id: id).map { SavedRouteEntity(route: $0) }
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [SavedRouteEntity] {
        try Task.checkCancellation()
        return SiriRouteStore.shared.routes.prefix(20).map { SavedRouteEntity(route: $0) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [SavedRouteEntity] {
        try Task.checkCancellation()
        let query = Self.normalized(string)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return SiriRouteStore.shared.routes.filter { route in
            Self.normalized(route.displayName).contains(query)
                || Self.normalized("\(route.origin.name) to \(route.destination.name)").contains(query)
        }.prefix(20).map { SavedRouteEntity(route: $0) }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

struct DepartureEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Departure"
    static let defaultQuery = DepartureEntityQuery()

    let id: String
    @Property(title: "From station") var origin: String
    @Property(title: "From station code") var originCRS: String
    @Property(title: "To station") var destination: String
    @Property(title: "To station code") var destinationCRS: String
    @Property(title: "Service identifier") var serviceID: String
    @Property(title: "Operating date") var operatingDate: String?
    @Property(title: "Scheduled departure") var scheduledDeparture: Date
    @Property(title: "Expected departure") var expectedDeparture: Date?
    @Property(title: "Platform") var platform: String?
    @Property(title: "Status") var status: String
    @Property(title: "Transport") var transport: String
    @Property(title: "Data freshness") var freshness: String
    @Property(title: "Departure time uncertain") var timingUncertain: Bool
    @Property(title: "Provider observation time") var providerObservedAt: Date?
    @Property(title: "Backend snapshot time") var backendSnapshotAt: Date?
    @Property(title: "Client fetch time") var clientFetchedAt: Date?

    init(departure: SiriDeparture) {
        id = departure.id
        origin = departure.originName
        originCRS = departure.originCRS
        destination = departure.destinationName
        destinationCRS = departure.destinationCRS
        serviceID = departure.serviceID
        operatingDate = departure.operatingDate
        scheduledDeparture = departure.scheduledDeparture
        expectedDeparture = departure.expectedDeparture
        platform = departure.platform
        status = departure.statusLabel
        transport = departure.transportLabel
        freshness = departure.freshnessLabel
        timingUncertain = departure.timingUncertain
        providerObservedAt = departure.providerObservedAt
        backendSnapshotAt = departure.backendSnapshotAt
        clientFetchedAt = departure.clientFetchedAt
    }

    var displayRepresentation: DisplayRepresentation {
        let timing = expectedDeparture.map {
            timingUncertain ? "last estimated at \(SiriDisplayTime.format($0))" : "expected at \(SiriDisplayTime.format($0))"
        }
            ?? "scheduled at \(SiriDisplayTime.format(scheduledDeparture))"
        return DisplayRepresentation(
            title: "\(transport) \(timing)",
            subtitle: "\(origin) to \(destination)"
        )
    }
}

nonisolated struct DepartureEntityQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [DepartureEntity] {
        try Task.checkCancellation()
        // Rehydration shares one request deadline across the bounded result list.
        return try await SiriLookupService.shared.resolveDepartures(ids: Array(identifiers.prefix(3)))
            .map { DepartureEntity(departure: $0) }
    }

    func suggestedEntities() async throws -> [DepartureEntity] { [] }
}

struct GetNextFavouriteTrainIntent: AppIntent {
    static let title: LocalizedStringResource = "Get My Next Train"
    static let description = IntentDescription("Get live departures for the default route selected in Siri & Shortcuts settings.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Departure station", description: "Leave blank to use the nearer end of a saved outward and return route.")
    var departureStation: StationEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get my next train") { \.$departureStation }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[DepartureEntity]> & ProvidesDialog & ShowsSnippetView {
        try Task.checkCancellation()
        guard let route = SiriRouteStore.shared.defaultRoute else {
            return SiriIntentResponse.make(SiriIntentResponse.setup(
                "Choose a default route in TrainTrack UK's Siri & Shortcuts settings, then ask again."
            ))
        }
        let result = try await SiriIntentResponse.lookup(route: route, departureStation: departureStation,
                                                        parameter: $departureStation)
        return SiriIntentResponse.make(result)
    }
}

struct GetNextTrainsForSavedRouteIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Trains for Saved Route"
    static let description = IntentDescription("Get live departures for one of your saved routes.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Saved route", requestValueDialog: "Which saved route?")
    var route: SavedRouteEntity

    @Parameter(title: "Departure station", description: "Leave blank to use the nearer end of a saved outward and return route.")
    var departureStation: StationEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Get next trains for \(\.$route)") { \.$departureStation }
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[DepartureEntity]> & ProvidesDialog & ShowsSnippetView {
        try Task.checkCancellation()
        guard let savedRoute = SiriRouteStore.shared.route(id: route.id) else {
            return SiriIntentResponse.make(SiriIntentResponse.setup(
                "That saved route is no longer available. Choose another route in your shortcut."
            ))
        }
        let result = try await SiriIntentResponse.lookup(route: savedRoute, departureStation: departureStation,
                                                        parameter: $departureStation)
        return SiriIntentResponse.make(result)
    }
}

struct GetNextDeparturesIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Train Departures"
    static let description = IntentDescription("Get direct departures between two stations. Siri asks for any missing stations.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "From station", requestValueDialog: "Which station are you leaving from?")
    var origin: StationEntity

    @Parameter(title: "To station", requestValueDialog: "Which station are you travelling to?")
    var destination: StationEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Get departures from \(\.$origin) to \(\.$destination)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[DepartureEntity]> & ProvidesDialog & ShowsSnippetView {
        try Task.checkCancellation()
        let stations = try await SiriLookupService.shared.stations(identifiers: [origin.id, destination.id])
        guard let from = stations.first(where: { $0.crs == origin.id }),
              let to = stations.first(where: { $0.crs == destination.id }) else {
            return SiriIntentResponse.make(SiriIntentResponse.setup(
                "I couldn't resolve those stations. Choose the stations again in your shortcut."
            ))
        }
        let result = try await SiriLookupService.shared.lookup(from: from, to: to)
        return SiriIntentResponse.make(result)
    }
}

struct GetTrackedJourneyStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Tracked Journey"
    static let description = IntentDescription("Refresh the status of your tracked train without starting or changing tracking.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[DepartureEntity]> & ProvidesDialog & ShowsSnippetView {
        SiriIntentResponse.make(try await SiriLookupService.shared.trackedJourneyStatus())
    }
}

struct GetTrackedTrainPlatformIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Tracked Train Platform"
    static let description = IntentDescription("Refresh the boarding platform for your tracked train.")
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<[DepartureEntity]> & ProvidesDialog & ShowsSnippetView {
        SiriIntentResponse.make(try await SiriLookupService.shared.trackedJourneyPlatform())
    }
}

nonisolated struct TrainTrackShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetNextFavouriteTrainIntent(),
            phrases: [
                "Get my next train in \(.applicationName)",
                "Get me my next train in \(.applicationName)",
                "Use \(.applicationName) to get my next train"
            ],
            shortTitle: "My Next Train",
            systemImageName: "tram.fill"
        )
        AppShortcut(
            intent: GetNextTrainsForSavedRouteIntent(),
            phrases: ["Get next trains for \(\.$route) in \(.applicationName)"],
            shortTitle: "Saved Route Trains",
            systemImageName: "star.fill"
        )
        AppShortcut(
            intent: GetNextDeparturesIntent(),
            phrases: ["Check train departures in \(.applicationName)"],
            shortTitle: "Train Departures",
            systemImageName: "arrow.right"
        )
        AppShortcut(
            intent: GetTrackedJourneyStatusIntent(),
            phrases: ["Check my journey in \(.applicationName)"],
            shortTitle: "Tracked Journey",
            systemImageName: "location.fill"
        )
        AppShortcut(
            intent: GetTrackedTrainPlatformIntent(),
            phrases: ["Check my train platform in \(.applicationName)"],
            shortTitle: "Train Platform",
            systemImageName: "signpost.right.fill"
        )
    }
}

private nonisolated enum SiriIntentResponse {
    static func setup(_ dialog: String) -> SiriLookupResult {
        SiriLookupResult(dialog: dialog, routeLabel: "Siri & Shortcuts", departures: [], freshnessLabel: "", outcome: .needsSetup)
    }

    @MainActor
    static func lookup(route: SiriSavedRoute, departureStation: StationEntity?,
                       parameter: IntentParameter<StationEntity?>) async throws -> SiriLookupResult {
        let directions = SiriRouteStore.shared.directions(for: route.id)
        let decision = try await SiriRouteDirectionResolver.resolve(
            directions: directions, departureStationCRS: departureStation?.id
        )
        let selected: SiriSavedRoute
        switch decision {
        case .selected(let direction):
            selected = direction
        case .needsDirection(let choices):
            let station = try await parameter.requestDisambiguation(
                among: choices.map { StationEntity(id: $0.origin.crs, name: $0.origin.name) },
                dialog: "Which station are you leaving from?"
            )
            guard let direction = choices.first(where: { $0.origin.crs == station.id }) else {
                return setup("I couldn't choose a direction for that route. Please ask again.")
            }
            selected = direction
        case .invalidDepartureStation:
            return setup("That departure station isn't part of the saved route. Choose one of its departure stations in your shortcut.")
        case .unavailable:
            return setup("That saved route is no longer available. Choose another route in your shortcut.")
        }
        // The user can edit or remove a route while Siri is asking for a direction.
        guard let current = SiriRouteStore.shared.route(id: selected.id),
              current.origin.crs == selected.origin.crs, current.destination.crs == selected.destination.crs else {
            return setup("That saved route changed. Please choose the route again.")
        }
        return try await SiriLookupService.shared.lookup(from: current.origin, to: current.destination)
    }

    @MainActor
    static func make(_ result: SiriLookupResult) -> some IntentResult & ReturnsValue<[DepartureEntity]> & ProvidesDialog & ShowsSnippetView {
        .result(
            value: result.departures.map { DepartureEntity(departure: $0) },
            dialog: IntentDialog(stringLiteral: result.dialog),
            view: SiriDepartureSnippet(result: result)
        )
    }
}
