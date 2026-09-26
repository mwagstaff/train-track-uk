import Foundation

nonisolated struct WatchStation: Codable, Hashable, Sendable {
    let crs: String
    let name: String
}

nonisolated struct WatchRoute: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let stations: [WatchStation]
    let favourite: Bool

    var origin: WatchStation { stations[0] }
    var destination: WatchStation { stations[stations.count - 1] }
    var via: [WatchStation] { Array(stations.dropFirst().dropLast()) }
    var title: String { "\(origin.name) → \(destination.name)" }
}

/// App groups do not cross devices. This snapshot travels over WatchConnectivity.
nonisolated struct WatchLibrary: Codable, Equatable, Sendable {
    static let contextKey = "watchLibrary.v1"
    let routes: [WatchRoute]
    let apiBase: String
    let updatedAt: Date

    static func decode(_ data: Data) throws -> Self {
        let library = try JSONDecoder().decode(Self.self, from: data)
        guard library.routes.allSatisfy({ $0.stations.count >= 2 }),
              Set(library.routes.map(\.id)).count == library.routes.count,
              let url = URL(string: library.apiBase),
              ["https", "http"].contains(url.scheme), url.host != nil else {
            throw CocoaError(.coderReadCorrupt)
        }
        return library
    }
}
