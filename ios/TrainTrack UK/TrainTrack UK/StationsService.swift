import Foundation

enum StationsServiceError: Error {
    case fileNotFound
    case decodeFailed 
}

final class StationsService {
    static let shared = StationsService()
    private(set) var stations: [Station] = []
    private var lastLoadedBase: String? = nil

    private init() {}

    func loadStations() async throws {
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
            request.setValue(DeviceIdentity.deviceToken, forHTTPHeaderField: "X-Device-Token")
            let (data, _) = try await URLSession.shared.data(for: request)
            stations = try JSONDecoder().decode([Station].self, from: data)
        } catch {
            throw StationsServiceError.decodeFailed
        }
    }

    func search(_ query: String, limit: Int = 20) -> [Station] {
        guard !query.isEmpty else { return [] }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return [] }
        // Name prefix match first, then contains, crs match boosts
        let filtered = stations.filter { station in
            let name = station.name.lowercased()
            return name.hasPrefix(q) || name.contains(q) || station.crs.lowercased().contains(q)
        }
        // Simple sort: by whether name starts with query, then by name
        let sorted = filtered.sorted { a, b in
            let aStarts = a.name.lowercased().hasPrefix(q)
            let bStarts = b.name.lowercased().hasPrefix(q)
            if aStarts != bStarts { return aStarts && !bStarts }
            return a.name < b.name
        }
        return Array(sorted.prefix(limit))
    }
}
