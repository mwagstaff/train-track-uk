import AppIntents
import Foundation

// MARK: - AppEntity representing a saved journey from the app (read via App Group)
struct JourneyEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Journey"

    let id: String // "FROM_TO"
    let fromCRS: String
    let toCRS: String
    let fromName: String
    let toName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(fromCRS) → \(toCRS)", subtitle: .init("\(fromName) → \(toName)"))
    }

    // Query helper
    static var defaultQuery = JourneyEntityQuery()
}

// Provide a no-op perform() for iOS 16.2+ to satisfy AppIntent in Swift 6 mode
@MainActor
@available(iOSApplicationExtension 16.2, *)
extension CustomJourneyIntent {
    func perform() async throws -> some IntentResult { .result() }
}

struct JourneyEntityQuery: EntityQuery {
    func entities(for identifiers: [JourneyEntity.ID]) async throws -> [JourneyEntity] {
        let all = await loadSavedJourneys()
        let set = Set(identifiers)
        return all.filter { set.contains($0.id) }
    }

    func suggestedEntities() async throws -> [JourneyEntity] {
        let all = await loadSavedJourneys()
        return Array(all.prefix(20))
    }

    private func loadSavedJourneys() async -> [JourneyEntity] {
        guard let ud = UserDefaults(suiteName: "group.dev.skynolimit.traintrack"),
              let data = ud.data(forKey: "saved_journeys") else { return [] }
        struct Station: Decodable { let crs: String; let name: String }
        struct Journey: Decodable { let fromStation: Station; let toStation: Station }
        let list = (try? JSONDecoder().decode([Journey].self, from: data)) ?? []
        return list.map { j in
            JourneyEntity(
                id: "\(j.fromStation.crs)_\(j.toStation.crs)",
                fromCRS: j.fromStation.crs, toCRS: j.toStation.crs,
                fromName: j.fromStation.name, toName: j.toStation.name
            )
        }
    }
}

// MARK: - Intent used by the Custom Journey widget
struct CustomJourneyIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Custom Journey" }
    static var description: IntentDescription { "Select a journey to display its next departures." }

    @Parameter(title: "Journey")
    var journey: JourneyEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Journey: \(\.$journey)")
    }
}
