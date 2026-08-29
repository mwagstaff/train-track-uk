import Combine
import Foundation

private struct RailwayBackgroundCatalogCache: Codable, Sendable {
    let apiBaseURL: String
    let fetchedAt: Date
    let etag: String?
    let catalog: RailwayBackgroundCatalog
}

private struct RailwayBackgroundFetchResult: Sendable {
    let catalog: RailwayBackgroundCatalog?
    let etag: String?
    let isNotModified: Bool
}

@MainActor
final class RailwayBackgroundStore: ObservableObject {
    private static let refreshInterval: TimeInterval = 4 * 60 * 60
    private static let selectedDayKey = "railwayBackground_selectedDay"
    private static let selectedAssetKey = "railwayBackground_selectedAsset"
    private static let debugDayKey = "railwayBackground_debugDay"
    private static let debugAssetKey = "railwayBackground_debugAsset"

    @Published private(set) var catalog: RailwayBackgroundCatalog?
    @Published private(set) var selectedAsset: RailwayBackgroundAsset?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefreshErrorDescription: String?

    private let cacheURL: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private var apiBaseURL: String?
    private var fetchedAt: Date?
    private var refreshAttemptedAt: Date?
    private var etag: String?

    init(
        cacheURL: URL = RailwayBackgroundStore.defaultCacheURL(),
        session: URLSession? = nil,
        defaults: UserDefaults = .standard,
        now: Date = Date()
    ) {
        self.cacheURL = cacheURL
        self.defaults = defaults
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: configuration)
        }
        if let cached = Self.loadCache(from: cacheURL) {
            catalog = cached.catalog
            apiBaseURL = cached.apiBaseURL
            fetchedAt = cached.fetchedAt
            refreshAttemptedAt = cached.fetchedAt
            etag = cached.etag
        }
        reconcileSelection(now: now)
    }

    func ensureFresh(
        apiBaseURL: String? = nil,
        force: Bool = false,
        now: Date = Date()
    ) async {
        let normalizedBaseURL = (apiBaseURL ?? ApiHostPreference.currentBaseURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let baseURL = URL(string: normalizedBaseURL) else {
            lastRefreshErrorDescription = "Invalid API base URL."
            return
        }
        if let existingBaseURL = self.apiBaseURL, existingBaseURL != normalizedBaseURL {
            catalog = nil
            selectedAsset = nil
            fetchedAt = nil
            refreshAttemptedAt = nil
            etag = nil
        }
        self.apiBaseURL = normalizedBaseURL

        let shouldRefresh = force || refreshAttemptedAt.map {
            now.timeIntervalSince($0) >= Self.refreshInterval
        } ?? true
        if shouldRefresh {
            guard !isRefreshing else { return }
            refreshAttemptedAt = now
            isRefreshing = true
            lastRefreshErrorDescription = nil
            defer { isRefreshing = false }
            do {
                let result = try await fetchCatalog(baseURL: baseURL, ifNoneMatch: etag)
                if result.isNotModified, catalog != nil {
                    fetchedAt = now
                    etag = result.etag ?? etag
                } else if let nextCatalog = result.catalog,
                          nextCatalog.schemaVersion == 1,
                          nextCatalog.rotation.timeZone == "Europe/London",
                          !nextCatalog.assets.isEmpty {
                    catalog = nextCatalog
                    fetchedAt = now
                    etag = result.etag
                    Task(priority: .utility) {
                        await RailwayBackgroundImageCache.shared.prune(
                            keeping: Set(nextCatalog.assets.map(\.sha256))
                        )
                    }
                } else {
                    lastRefreshErrorDescription = "The server returned an unsupported background catalogue."
                }
                persistCache()
            } catch is CancellationError {
                return
            } catch {
                lastRefreshErrorDescription = error.localizedDescription
                debugLog("🖼️ [RailwayBackground] Catalogue refresh failed: \(error)")
            }
        }

        reconcileSelection(now: now)
        if let selectedAsset {
            _ = await RailwayBackgroundImageCache.shared.image(
                for: selectedAsset,
                apiBaseURL: normalizedBaseURL
            )
        }
    }

    #if DEBUG
    func advanceDebugBackground(now: Date = Date()) async {
        if catalog == nil {
            await ensureFresh(force: true, now: now)
        }
        guard let catalog, !catalog.rotation.assetIDs.isEmpty else { return }
        let ids = catalog.rotation.assetIDs.filter { catalog.asset(id: $0) != nil }
        guard !ids.isEmpty else { return }
        let currentIndex = selectedAsset.flatMap { asset in ids.firstIndex(of: asset.id) } ?? -1
        let nextID = ids[(currentIndex + 1) % ids.count]
        let day = RailwayBackgroundDailyRotation.dayKey(for: now)
        defaults.set(day, forKey: Self.debugDayKey)
        defaults.set(nextID, forKey: Self.debugAssetKey)
        reconcileSelection(now: now)
        if let selectedAsset, let apiBaseURL {
            _ = await RailwayBackgroundImageCache.shared.image(for: selectedAsset, apiBaseURL: apiBaseURL)
        }
    }

    func advanceDebugUnsplashBackground(now: Date = Date()) async {
        await ensureFresh(force: true, now: now)
        guard let catalog else { return }
        let ids = catalog.rotation.assetIDs.filter { catalog.asset(id: $0)?.isUnsplashPhoto == true }
        guard !ids.isEmpty else { return }
        let currentIndex = selectedAsset.flatMap { asset in ids.firstIndex(of: asset.id) } ?? -1
        let nextID = ids[(currentIndex + 1) % ids.count]
        let day = RailwayBackgroundDailyRotation.dayKey(for: now)
        defaults.set(day, forKey: Self.debugDayKey)
        defaults.set(nextID, forKey: Self.debugAssetKey)
        reconcileSelection(now: now)
        if let selectedAsset, let apiBaseURL {
            _ = await RailwayBackgroundImageCache.shared.image(for: selectedAsset, apiBaseURL: apiBaseURL)
        }
    }

    var debugUnsplashPositionDescription: String {
        guard let catalog else { return "Catalogue not loaded" }
        let ids = catalog.rotation.assetIDs.filter { catalog.asset(id: $0)?.isUnsplashPhoto == true }
        guard !ids.isEmpty else { return "No approved photos" }
        guard let selectedID = selectedAsset?.id, let index = ids.firstIndex(of: selectedID) else {
            return "\(ids.count) available"
        }
        return "\(index + 1) of \(ids.count)"
    }

    func resetDebugBackground(now: Date = Date()) {
        defaults.removeObject(forKey: Self.debugDayKey)
        defaults.removeObject(forKey: Self.debugAssetKey)
        defaults.removeObject(forKey: Self.selectedDayKey)
        defaults.removeObject(forKey: Self.selectedAssetKey)
        reconcileSelection(now: now)
    }
    #endif

    private func reconcileSelection(now: Date) {
        guard let catalog else {
            selectedAsset = nil
            return
        }
        let day = RailwayBackgroundDailyRotation.dayKey(for: now)
        #if DEBUG
        if defaults.string(forKey: Self.debugDayKey) == day,
           let debugAsset = catalog.asset(id: defaults.string(forKey: Self.debugAssetKey)) {
            selectedAsset = debugAsset
            return
        }
        defaults.removeObject(forKey: Self.debugDayKey)
        defaults.removeObject(forKey: Self.debugAssetKey)
        #endif

        if defaults.string(forKey: Self.selectedDayKey) == day,
           let persistedAsset = catalog.asset(id: defaults.string(forKey: Self.selectedAssetKey)) {
            selectedAsset = persistedAsset
            return
        }
        let asset = catalog.asset(id: RailwayBackgroundDailyRotation.selectedAssetID(catalog: catalog, date: now))
        selectedAsset = asset
        defaults.set(day, forKey: Self.selectedDayKey)
        defaults.set(asset?.id, forKey: Self.selectedAssetKey)
    }

    private func fetchCatalog(baseURL: URL, ifNoneMatch: String?) async throws -> RailwayBackgroundFetchResult {
        let url = baseURL
            .appendingPathComponent("railway-backgrounds")
            .appendingPathComponent("catalog")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let ifNoneMatch { request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let responseETag = http.value(forHTTPHeaderField: "ETag")
        if http.statusCode == 304 {
            return RailwayBackgroundFetchResult(catalog: nil, etag: responseETag, isNotModified: true)
        }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        return RailwayBackgroundFetchResult(
            catalog: try JSONDecoder().decode(RailwayBackgroundCatalog.self, from: data),
            etag: responseETag,
            isNotModified: false
        )
    }

    private func persistCache() {
        guard let apiBaseURL, let fetchedAt, let catalog else { return }
        let payload = RailwayBackgroundCatalogCache(
            apiBaseURL: apiBaseURL,
            fetchedAt: fetchedAt,
            etag: etag,
            catalog: catalog
        )
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(payload).write(to: cacheURL, options: .atomic)
        } catch {
            debugLog("🖼️ [RailwayBackground] Failed to persist catalogue: \(error)")
        }
    }

    private static func loadCache(from url: URL) -> RailwayBackgroundCatalogCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RailwayBackgroundCatalogCache.self, from: data)
    }

    private nonisolated static func defaultCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("railway-backgrounds", isDirectory: true)
            .appendingPathComponent("catalog-cache.json")
    }
}
