import Foundation

enum ApiHost: String, CaseIterable, Identifiable {
    case prod
    case dev

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .prod: return "Production"
        case .dev: return "Dev (Mike's MacBook Air)"
        }
    }

    var baseURL: String {
        switch self {
        case .prod: return "https://api.skynolimit.dev/train-track/api/v2"
        case .dev: return "http://Mikes-MacBook-Air.local:3000/api/v2"
        }
    }

    var hostDescription: String {
        switch self {
        case .prod: return "api.skynolimit.dev"
        case .dev: return "Mikes-MacBook-Air.local:3000"
        }
    }
}

enum ApiHostPreference {
    static let storageKey = "api_host_preference"
    static let store: UserDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard

    /// Returns the currently selected base URL, preferring an environment override when present.
    static var currentBaseURL: String {
        if let envBase = ProcessInfo.processInfo.environment["API_BASE"], !envBase.isEmpty {
            return envBase
        }
        return (ApiHost(rawValue: store.string(forKey: storageKey) ?? "") ?? .prod).baseURL
    }
}

enum DeviceIdentity {
    private static let storageKey = "device_token"
    private static let store: UserDefaults = UserDefaults(suiteName: "group.dev.skynolimit.traintrack") ?? .standard

    static var deviceToken: String {
        if let existing = store.string(forKey: storageKey), !existing.isEmpty {
            return existing
        }
        let newToken = UUID().uuidString
        store.set(newToken, forKey: storageKey)
        return newToken
    }
}

enum PhoneNetworkError: Error, LocalizedError {
    case invalidURL
    case decodingError
    case noData
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .decodingError: return "Decode error"
        case .noData: return "No data"
        case .networkError(let e): return e.localizedDescription
        }
    }
}

final class NetworkServicePhone {
    static let shared = NetworkServicePhone()
    private init() {}

    // Read the current host selection (production by default) from shared settings.
    private var base: String { ApiHostPreference.currentBaseURL }
    private var deviceToken: String { DeviceIdentity.deviceToken }

    private let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // Maximum number of service IDs per request when batching.
    // Configurable via setter below. Defaults to 50 as requested.
    private var maxIdsPerRequest: Int = 50

    func setServiceDetailsMaxIdsPerRequest(_ n: Int) {
        maxIdsPerRequest = max(1, n)
    }

    func fetchDeparturesAggregated(pairs: [(from: String, to: String)]) async throws -> [String: [DepartureV2]] {
        guard !pairs.isEmpty else { return [:] }
        let path = pairs.map { "from/\($0.from)/to/\($0.to)" }.joined(separator: "/")
        guard let url = URL(string: "\(base)/departures/\(path)") else { throw PhoneNetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        // Response shape: [ { "EUS_WFJ": [ ... ] }, { "ECR_VIC": [ ... ] } ]
        var arrAny: Any
        arrAny = try JSONSerialization.jsonObject(with: data, options: [])
        var result: [String: [DepartureV2]] = [:]

        if let dict = arrAny as? [String: Any] {
            // Top-level object: { "ECR_GTW": [ ... ], ... }
            for (key, val) in dict {
                let valData = try JSONSerialization.data(withJSONObject: val, options: [])
                let deps = try jsonDecoder.decode([DepartureV2].self, from: valData)
                result[key] = deps
            }
        } else if let arr = arrAny as? [[String: Any]] {
            // Array of single-key objects: [ {"ECR_GTW": [...]}, ... ]
            for item in arr {
                if let key = item.keys.first, let val = item[key] {
                    let valData = try JSONSerialization.data(withJSONObject: val, options: [])
                    let deps = try jsonDecoder.decode([DepartureV2].self, from: valData)
                    result[key] = deps
                }
            }
        }
        return result
    }

    func fetchServiceDetailsAggregated(ids: [String]) async throws -> [String: ServiceDetails] {
        guard !ids.isEmpty else { return [:] }
        let path = ids.joined(separator: "/")
        guard let url = URL(string: "\(base)/service_details/\(path)") else { throw PhoneNetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, _) = try await URLSession.shared.data(for: request)
        let arrAny = try JSONSerialization.jsonObject(with: data, options: [])
        let arr = arrAny as? [[String: Any]] ?? []
        var result: [String: ServiceDetails] = [:]
        for item in arr {
            if let key = item.keys.first, let val = item[key] {
                let valData = try JSONSerialization.data(withJSONObject: val, options: [])
                // Allow empty objects -> skip
                if let dict = try JSONSerialization.jsonObject(with: valData) as? [String: Any], dict.isEmpty {
                    continue
                }
                let details = try jsonDecoder.decode(ServiceDetails.self, from: valData)
                result[key] = details
            }
        }
        return result
    }

    // Chunk the service IDs and fetch in parallel, merging results.
    func fetchServiceDetailsAggregatedChunked(ids: [String]) async throws -> [String: ServiceDetails] {
        guard !ids.isEmpty else { return [:] }
        let chunkSize = max(1, maxIdsPerRequest)
        var chunks: [[String]] = []
        var i = 0
        while i < ids.count {
            let end = min(i + chunkSize, ids.count)
            chunks.append(Array(ids[i..<end]))
            i = end
        }

        var combined: [String: ServiceDetails] = [:]
        try await withThrowingTaskGroup(of: [String: ServiceDetails].self) { group in
            for chunk in chunks {
                group.addTask { [chunk] in
                    return try await self.fetchServiceDetailsAggregated(ids: chunk)
                }
            }
            for try await partial in group {
                for (k, v) in partial { combined[k] = v }
            }
        }
        return combined
    }
}
