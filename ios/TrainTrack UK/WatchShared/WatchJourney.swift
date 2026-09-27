import Foundation

nonisolated struct WatchJourney: Codable, Equatable, Identifiable, Sendable {
    let id: String
    // Changes with the leg, phase and selected train. Rejects commands from old screens.
    let context: String
    let route: WatchRoute
    let phase: String
    let title: String
    let detail: String
    let destination: String
    let arrival: String?
    let finalArrival: String?
    let status: String?
    let platform: String?
    let length: Int?
    let arrivalAction: String?
    let serviceAction: String?
    let services: [WatchJourneyService]
    let updatedAt: Date
    var nextDepartureRoute: WatchRoute? = nil

    var isComplete: Bool { phase == "completed" }
}

nonisolated struct WatchJourneyService: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let departure: String
    let status: String
    let platform: String?
    let cancelled: Bool
}

nonisolated struct WatchJourneyCommand: Codable, Sendable {
    static let messageKey = "watchJourneyCommand.v1"
    enum Action: String, Codable, Sendable { case arrive, selectService, unlistedService, end }
    let requestID: UUID
    let journeyID: String
    let context: String
    let action: Action
    var serviceID: String? = nil

    func matches(_ journey: WatchJourney) -> Bool {
        journeyID == journey.id && context == journey.context && !journey.isComplete
    }
}

nonisolated struct WatchLaunch: Hashable, Sendable {
    let from: String
    let to: String
    let fromName: String
    let toName: String
    let showsProgress: Bool

    init?(url: URL) {
        guard url.scheme == "traintrack", ["journey", "in-progress", "history"].contains(url.host ?? ""),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ key: String) -> String? { components.queryItems?.first { $0.name == key }?.value }
        guard let from = value("from")?.uppercased(), let to = value("to")?.uppercased(),
              from.count == 3, to.count == 3, from.allSatisfy(\.isLetter), to.allSatisfy(\.isLetter) else { return nil }
        self.from = from
        self.to = to
        fromName = value("fromName") ?? from
        toName = value("toName") ?? to
        showsProgress = value("watch") == "progress" || (value("watch") == nil && url.host != "journey")
    }

    func matches(_ route: WatchRoute) -> Bool {
        route.origin.crs.caseInsensitiveCompare(from) == .orderedSame
            && route.destination.crs.caseInsensitiveCompare(to) == .orderedSame
    }
}
