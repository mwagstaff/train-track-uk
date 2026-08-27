import Foundation

struct RailwayBackgroundFocalPoint: Codable, Hashable, Sendable {
    let x: Double
    let y: Double
}

struct RailwayBackgroundCredit: Codable, Hashable, Sendable {
    let photographer: String?
    let photographerURL: String?
    let source: String?
    let sourcePage: String?
    let license: String?
    let licenseURL: String?

    enum CodingKeys: String, CodingKey {
        case photographer, source, license
        case photographerURL = "photographer_url"
        case sourcePage = "source_page"
        case licenseURL = "license_url"
    }
}

struct RailwayBackgroundAsset: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let location: String
    let caption: String?
    let focalPoint: RailwayBackgroundFocalPoint
    let scrimOpacity: Double
    let sha256: String
    let assetPath: String
    let assetURL: String
    let contentType: String
    let byteSize: Int
    let width: Int
    let height: Int
    let credit: RailwayBackgroundCredit

    enum CodingKeys: String, CodingKey {
        case id, title, location, caption, sha256, width, height, credit
        case focalPoint = "focal_point"
        case scrimOpacity = "scrim_opacity"
        case assetPath = "asset_path"
        case assetURL = "asset_url"
        case contentType = "content_type"
        case byteSize = "byte_size"
    }

    nonisolated func remoteURL(apiBaseURL: String) -> URL? {
        guard let baseURL = URL(string: apiBaseURL) else { return nil }
        if let absoluteURL = URL(string: assetURL), absoluteURL.scheme != nil {
            return absoluteURL
        }
        let endpointMarker = "railway-backgrounds/assets/"
        let endpointPath: String
        if let markerRange = assetURL.range(of: endpointMarker) {
            endpointPath = String(assetURL[markerRange.lowerBound...])
        } else {
            endpointPath = assetURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard !endpointPath.isEmpty else { return nil }
        return endpointPath.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }
}

struct RailwayBackgroundRotation: Codable, Hashable, Sendable {
    let timeZone: String
    let epochDate: String
    let assetIDs: [String]

    enum CodingKeys: String, CodingKey {
        case timeZone = "time_zone"
        case epochDate = "epoch_date"
        case assetIDs = "asset_ids"
    }
}

struct RailwayBackgroundCatalog: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let catalogVersion: String
    let generatedAt: String
    let rotation: RailwayBackgroundRotation
    let assets: [RailwayBackgroundAsset]

    enum CodingKeys: String, CodingKey {
        case rotation, assets
        case schemaVersion = "schema_version"
        case catalogVersion = "catalog_version"
        case generatedAt = "generated_at"
    }

    nonisolated func asset(id: String?) -> RailwayBackgroundAsset? {
        guard let id else { return nil }
        return assets.first { $0.id == id }
    }
}

enum RailwayBackgroundDailyRotation {
    static func londonCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        return calendar
    }

    static func dayKey(for date: Date, calendar: Calendar = londonCalendar()) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    static func selectedAssetID(
        catalog: RailwayBackgroundCatalog,
        date: Date,
        calendar: Calendar = londonCalendar()
    ) -> String? {
        let ids = catalog.rotation.assetIDs.filter { id in catalog.assets.contains { $0.id == id } }
        guard !ids.isEmpty else { return nil }
        let epochParts = catalog.rotation.epochDate.split(separator: "-").compactMap { Int($0) }
        guard epochParts.count == 3,
              let epoch = calendar.date(from: DateComponents(
                year: epochParts[0], month: epochParts[1], day: epochParts[2]
              )) else { return ids.first }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: epoch),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
        let index = ((days % ids.count) + ids.count) % ids.count
        return ids[index]
    }
}
