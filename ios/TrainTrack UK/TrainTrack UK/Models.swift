import Foundation
import CoreLocation

struct Station: Codable, Identifiable, Hashable {
    let crs: String
    let name: String
    let longitude: String
    let latitude: String

    var id: String { crs }

    var coordinate: CLLocationCoordinate2D {
        // Some stations have multiple coordinate values separated by "\n" - take the first one
        let latValue = latitude.split(separator: "\n").first.map(String.init) ?? latitude
        let lonValue = longitude.split(separator: "\n").first.map(String.init) ?? longitude
        return CLLocationCoordinate2D(
            latitude: Double(latValue) ?? 0,
            longitude: Double(lonValue) ?? 0
        )
    }
}

struct Journey: Codable, Identifiable, Hashable {
    let id: UUID
    let groupId: UUID
    let legIndex: Int
    let fromStation: Station
    let toStation: Station
    let createdAt: Date
    let favorite: Bool

    init(fromStation: Station, toStation: Station, favorite: Bool = false) {
        let newId = UUID()
        self.id = newId
        self.groupId = newId
        self.legIndex = 0
        self.fromStation = fromStation
        self.toStation = toStation
        self.createdAt = Date()
        self.favorite = favorite
    }

    init(id: UUID, groupId: UUID, legIndex: Int, fromStation: Station, toStation: Station, createdAt: Date, favorite: Bool) {
        self.id = id
        self.groupId = groupId
        self.legIndex = legIndex
        self.fromStation = fromStation
        self.toStation = toStation
        self.createdAt = createdAt
        self.favorite = favorite
    }

    private enum CodingKeys: String, CodingKey {
        case id, groupId, legIndex, fromStation, toStation, createdAt, favorite
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        self.id = id
        self.groupId = (try? container.decode(UUID.self, forKey: .groupId)) ?? id
        self.legIndex = (try? container.decode(Int.self, forKey: .legIndex)) ?? 0
        self.fromStation = try container.decode(Station.self, forKey: .fromStation)
        self.toStation = try container.decode(Station.self, forKey: .toStation)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.favorite = try container.decode(Bool.self, forKey: .favorite)
    }
}

struct JourneyGroup: Identifiable, Hashable {
    let id: UUID
    let legs: [Journey]

    var favorite: Bool { legs.first?.favorite ?? false }
    var startStation: Station { legs.first!.fromStation }
    var endStation: Station { legs.last!.toStation }
    var viaStations: [Station] {
        guard legs.count > 1 else { return [] }
        return legs.dropLast().map { $0.toStation }
    }

    var displayTitle: String {
        let start = startStation.name
        let end = endStation.name
        let via = viaStations.map { $0.name }
        if via.isEmpty {
            return "\(start) → \(end)"
        }
        return "\(start) → \(end) via \(via.joined(separator: ", "))"
    }

    var stationSequence: [Station] {
        var stations = [startStation]
        stations.append(contentsOf: viaStations)
        stations.append(endStation)
        return stations
    }
}
