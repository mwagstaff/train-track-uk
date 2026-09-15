import Foundation

enum StationsServiceError: Error {
    case fileNotFound
    case decodeFailed 
}

final class StationsService {
    static let shared = StationsService()
    private static let supplementalStations = [
        Station(
            crs: "CMS",
            name: "Cambridge South",
            longitude: "0.1312738",
            latitude: "52.1740325"
        )
    ]

    private(set) var stations: [Station] = []
    private var lastLoadedBase: String? = nil

    private init() {}

    func loadStations(timeout: TimeInterval? = nil) async throws {
        let base = ApiHostPreference.currentBaseURL
        if let lastLoadedBase, lastLoadedBase != base {
            // Base switched (prod vs dev); reset cache so we fetch from the new host.
            stations = []
        }

        if !stations.isEmpty { return }
        // Load stations from API asynchronously to avoid blocking the main thread.
        lastLoadedBase = base
        guard let url = URL(string: "\(base)/stations") else { throw StationsServiceError.fileNotFound }
        do {
            var request = URLRequest(url: url)
            if let timeout { request.timeoutInterval = timeout }
            request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")
            #if DEBUG
            request.setValue("true", forHTTPHeaderField: "X-Debug-Build")
            #endif
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw StationsServiceError.decodeFailed
            }
            let decoded = try JSONDecoder().decode([Station].self, from: data)
            if base == ApiHostPreference.currentBaseURL {
                stations = Self.includingSupplementalStations(in: decoded)
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw StationsServiceError.decodeFailed
        }
    }

    static func includingSupplementalStations(in stations: [Station]) -> [Station] {
        let existingCRSs = Set(stations.map { $0.crs.uppercased() })
        return stations + supplementalStations.filter {
            !existingCRSs.contains($0.crs.uppercased())
        }
    }

    func search(_ query: String, limit: Int = 20) -> [Station] {
        Self.search(query, in: stations, limit: limit)
    }

    static func normalizedSearchText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_GB"))
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func search(_ query: String, in stations: [Station], limit: Int = 20) -> [Station] {
        let q = normalizedSearchText(query)
        if q.isEmpty { return [] }
        // Name prefix match first, then contains, crs match boosts
        let filtered = stations.filter { station in
            let name = normalizedSearchText(station.name)
            return name.hasPrefix(q) || name.contains(q) || station.crs.lowercased().contains(q)
        }
        // Simple sort: by whether name starts with query, then by name
        let sorted = filtered.sorted { a, b in
            let aExact = normalizedSearchText(a.name) == q || a.crs.lowercased() == q
            let bExact = normalizedSearchText(b.name) == q || b.crs.lowercased() == q
            if aExact != bExact { return aExact }
            let aStarts = normalizedSearchText(a.name).hasPrefix(q)
            let bStarts = normalizedSearchText(b.name).hasPrefix(q)
            if aStarts != bStarts { return aStarts && !bStarts }
            return a.name < b.name
        }
        return Array(sorted.prefix(max(0, limit)))
    }
}
