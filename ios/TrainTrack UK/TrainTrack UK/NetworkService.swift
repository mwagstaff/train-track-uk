import Foundation

struct ServiceDetailsLookupContext: Equatable {
    let fromCRS: String
    let toCRS: String
    let originCRS: String?
    let `operator`: String?
    let destinationCRSs: [String]
    let length: Int?

    var queryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "fromCRS", value: fromCRS),
            URLQueryItem(name: "toCRS", value: toCRS),
        ]
        if let originCRS, !originCRS.isEmpty {
            items.append(URLQueryItem(name: "originCRS", value: originCRS))
        }
        if let `operator`, !`operator`.isEmpty {
            items.append(URLQueryItem(name: "operator", value: `operator`))
        }
        if !destinationCRSs.isEmpty {
            items.append(URLQueryItem(
                name: "destinationCRS",
                value: destinationCRSs.joined(separator: ",")
            ))
        }
        if let length, length > 0 {
            items.append(URLQueryItem(name: "length", value: String(length)))
        }
        return items
    }
}

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

    var loadingBaseURL: String {
        switch self {
        case .prod: return "https://api.skynolimit.dev/train-track-loading/api/v1"
        case .dev: return "http://Mikes-MacBook-Air.local:3001/api/v1"
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
        #if DEBUG
        if let envBase = ProcessInfo.processInfo.environment["API_BASE"], !envBase.isEmpty {
            return envBase
        }
        return (ApiHost(rawValue: store.string(forKey: storageKey) ?? "") ?? .prod).baseURL
        #else
        return ApiHost.prod.baseURL
        #endif
    }

    static var currentLoadingBaseURL: String {
        #if DEBUG
        if let envBase = ProcessInfo.processInfo.environment["LOADING_API_BASE"], !envBase.isEmpty {
            return envBase
        }
        return (ApiHost(rawValue: store.string(forKey: storageKey) ?? "") ?? .prod).loadingBaseURL
        #else
        return ApiHost.prod.loadingBaseURL
        #endif
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

struct DevicePreferencesPayload: Codable, Sendable {
    let minShortTrainCars: Int
    let distanceVeryCloseMiles: Double
    let distanceModeratelyCloseMiles: Double
    let liveActivityDurationMinutes: Int
    let journeySortMode: String
    let apiHost: String
    let autoReturnToFavouritesMinutes: Int
    let autoMuteOnArrival: Bool
    let muteDelayMinutes: Int
    let autoEndLiveActivity: Bool
    let showClosestJourneyLegOnly: Bool
    let showTransferWarnings: Bool
    let transferWarningThresholdMinutes: Int
    let notificationSummary: Bool
    let notificationDelays: Bool
    let notificationPlatform: Bool
}

private struct DelayRepayOperatorResponse: Decodable {
    let name: String
    let operatorCode: String?
    let claimURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case operatorCode = "operator_code"
        case claimURL = "claim_url"
    }
}

private struct DevicePreferencesUpload: Encodable {
    let deviceId: String
    let preferences: DevicePreferencesPayload

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case preferences
    }
}

enum DevicePreferencesSync {
    static func currentPayload() -> DevicePreferencesPayload {
        let defaults = UserDefaults.standard
        return DevicePreferencesPayload(
            minShortTrainCars: defaults.object(forKey: "minShortTrainCars") as? Int ?? 4,
            distanceVeryCloseMiles: defaults.object(forKey: "distanceVeryCloseMiles") as? Double ?? 3,
            distanceModeratelyCloseMiles: defaults.object(forKey: "distanceModeratelyCloseMiles") as? Double ?? 5,
            liveActivityDurationMinutes: defaults.object(forKey: "liveActivityDurationMinutes") as? Int ?? 60,
            journeySortMode: defaults.string(forKey: "journeySortMode") ?? "distance",
            apiHost: currentApiHost,
            autoReturnToFavouritesMinutes: defaults.object(forKey: "autoReturnToFavouritesMinutes") as? Int ?? 0,
            autoMuteOnArrival: defaults.object(forKey: "autoMuteOnArrival") as? Bool ?? true,
            muteDelayMinutes: defaults.object(forKey: "muteDelayMinutes") as? Int ?? 3,
            autoEndLiveActivity: false,
            showClosestJourneyLegOnly: defaults.object(forKey: "showClosestJourneyLegOnly") as? Bool ?? true,
            showTransferWarnings: defaults.object(forKey: "showTransferWarnings") as? Bool ?? true,
            transferWarningThresholdMinutes: defaults.object(forKey: "transferWarningThresholdMinutes") as? Int ?? 3,
            notificationSummary: NotificationPreferences.isEnabled(.summary),
            notificationDelays: NotificationPreferences.isEnabled(.delays),
            notificationPlatform: NotificationPreferences.isEnabled(.platform)
        )
    }

    private static var currentApiHost: String {
        #if DEBUG
        ApiHostPreference.store.string(forKey: ApiHostPreference.storageKey) ?? ApiHost.prod.rawValue
        #else
        ApiHost.prod.rawValue
        #endif
    }

    static func syncCurrent() async {
        try? await NetworkServicePhone.shared.syncDevicePreferences(currentPayload())
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

    private let maxDeparturePairsPerRequest = 4
    private let departureBatchDelayRangeMs: ClosedRange<UInt64> = 0...500

    // Read the current host selection (production by default) from shared settings.
    private var base: String { ApiHostPreference.currentBaseURL }
    private var loadingBase: String { ApiHostPreference.currentLoadingBaseURL }
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

    func syncDevicePreferences(_ preferences: DevicePreferencesPayload) async throws {
        guard let url = URL(string: "\(base)/device_preferences") else { throw PhoneNetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.httpBody = try JSONEncoder().encode(DevicePreferencesUpload(
            deviceId: deviceToken,
            preferences: preferences
        ))

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PhoneNetworkError.noData
        }
    }

    func fetchDelayRepayClaimURL(
        operatorCode: String?,
        operatorName: String?
    ) async throws -> URL {
        guard var components = URLComponents(string: "\(base)/delay-repay/operator") else {
            throw PhoneNetworkError.invalidURL
        }
        components.queryItems = [
            operatorCode.map { URLQueryItem(name: "operator_code", value: $0) },
            operatorName.map { URLQueryItem(name: "operator_name", value: $0) }
        ].compactMap { $0 }
        guard let url = components.url else { throw PhoneNetworkError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PhoneNetworkError.noData
        }
        return try jsonDecoder.decode(DelayRepayOperatorResponse.self, from: data).claimURL
    }

    func fetchDeparturesAggregated(
        pairs: [(from: String, to: String)],
        delayBeforeEachBatch: Bool = true
    ) async throws -> [String: JourneyDeparturesSnapshot] {
        guard !pairs.isEmpty else { return [:] }
        let chunkSize = max(1, maxDeparturePairsPerRequest)
        var combined: [String: JourneyDeparturesSnapshot] = [:]
        var startIndex = 0

        while startIndex < pairs.count {
            let endIndex = min(startIndex + chunkSize, pairs.count)
            let chunk = Array(pairs[startIndex..<endIndex])
            if delayBeforeEachBatch {
                try await sleepBeforeDepartureBatch()
            }
            let partial = try await fetchDeparturesBatch(pairs: chunk)
            for (key, value) in partial {
                combined[key] = value
            }
            startIndex = endIndex
        }

        return combined
    }

    private func fetchDeparturesBatch(pairs: [(from: String, to: String)]) async throws -> [String: JourneyDeparturesSnapshot] {
        guard !pairs.isEmpty else { return [:] }
        let path = pairs.map { "from/\($0.from)/to/\($0.to)" }.joined(separator: "/")
        guard var components = URLComponents(string: "\(base)/departures/\(path)") else {
            throw PhoneNetworkError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "includeStatus", value: "true")]
        guard let url = components.url else { throw PhoneNetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PhoneNetworkError.noData
        }

        if let items = try? jsonDecoder.decode([[String: JourneyDeparturesSnapshot]].self, from: data) {
            return items.reduce(into: [:]) { result, item in
                for (key, snapshot) in item {
                    result[key] = snapshot
                }
            }
        }
        return try jsonDecoder.decode([String: JourneyDeparturesSnapshot].self, from: data)
    }

    func fetchRecentDepartures(
        pairs: [(from: String, to: String)]
    ) async throws -> [String: [RecentDepartureV2]] {
        guard !pairs.isEmpty else { return [:] }
        let path = pairs.map { "from/\($0.from)/to/\($0.to)" }.joined(separator: "/")
        guard let url = URL(string: "\(base)/departures/recent/\(path)") else {
            throw PhoneNetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PhoneNetworkError.noData
        }
        if let items = try? jsonDecoder.decode([[String: [RecentDepartureV2]]].self, from: data) {
            return items.reduce(into: [:]) { result, item in
                for (key, departures) in item { result[key] = departures }
            }
        }
        return try jsonDecoder.decode([String: [RecentDepartureV2]].self, from: data)
    }

    private func sleepBeforeDepartureBatch() async throws {
        let delayMs = UInt64.random(in: departureBatchDelayRangeMs)
        if delayMs == 0 {
            return
        }
        try await Task.sleep(nanoseconds: delayMs * 1_000_000)
    }

    func fetchServiceDetailsAggregated(
        ids: [String],
        context: ServiceDetailsLookupContext? = nil
    ) async throws -> [String: ServiceDetails] {
        guard !ids.isEmpty else { return [:] }
        let path = ids.joined(separator: "/")
        guard var components = URLComponents(string: "\(base)/service_details/\(path)") else {
            throw PhoneNetworkError.invalidURL
        }
        components.queryItems = context?.queryItems
        guard let url = components.url else { throw PhoneNetworkError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
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
    func fetchServiceDetailsAggregatedChunked(
        ids: [String],
        context: ServiceDetailsLookupContext? = nil
    ) async throws -> [String: ServiceDetails] {
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
                    return try await self.fetchServiceDetailsAggregated(
                        ids: chunk,
                        context: context
                    )
                }
            }
            for try await partial in group {
                for (k, v) in partial { combined[k] = v }
            }
        }
        return combined
    }

    func fetchLoadingDetails(requests: [LoadingDetailsRequestV1]) async throws -> [String: ServiceLoadingV1] {
        guard !requests.isEmpty else { return [:] }
        guard let url = URL(string: "\(loadingBase)/loading_details/batch") else {
            throw PhoneNetworkError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceToken, forHTTPHeaderField: "X-Device-Token")
        request.httpBody = try JSONEncoder().encode(LoadingDetailsBatchRequestV1(services: requests))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PhoneNetworkError.noData
        }
        return try jsonDecoder.decode(LoadingDetailsBatchResponseV1.self, from: data).services
    }
}
