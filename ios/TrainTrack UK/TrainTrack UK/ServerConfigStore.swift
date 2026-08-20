import Foundation
import Combine

/// Fetches and caches server-side configuration so that limits (e.g. max
/// subscriptions per device) stay in sync with the server without requiring
/// an app update.
///
/// Values are persisted in UserDefaults so the last-known config is available
/// immediately on next launch. The conservative default (1) is only used on
/// the very first install before the server has ever been reached, and is
/// immediately replaced once the first fetch completes.
@MainActor
final class ServerConfigStore: ObservableObject {
    static let shared = ServerConfigStore()

    // MARK: - Published properties

    /// Maximum number of scheduled subscriptions a single device may hold.
    @Published private(set) var maxSubscriptionsPerDevice: Int
    /// Maximum number of live sessions a single device may hold.
    @Published private(set) var maxLiveSessionsPerDevice: Int

    // MARK: - UserDefaults keys & defaults

    private let maxSubsKey = "serverConfig_maxSubscriptionsPerDevice"
    private let maxLiveKey = "serverConfig_maxLiveSessionsPerDevice"

    /// Intentionally conservative: ensures the schedule button is disabled
    /// rather than enabled on the very first install before the server is
    /// ever reached. Replaced by the real server value after the first
    /// successful fetch.
    private let conservativeDefault = 1

    // MARK: - Init

    private init() {
        let storedSubs = UserDefaults.standard.integer(forKey: "serverConfig_maxSubscriptionsPerDevice")
        let storedLive = UserDefaults.standard.integer(forKey: "serverConfig_maxLiveSessionsPerDevice")
        maxSubscriptionsPerDevice = storedSubs > 0 ? storedSubs : 1
        maxLiveSessionsPerDevice  = storedLive > 0 ? storedLive : 1
        startBackgroundRefresh()
    }

    // MARK: - Fetch

    /// Fetches config from the server and updates published properties.
    /// Silently ignores network/decode errors — the last cached value is kept.
    func refresh() async {
        guard let url = URL(string: "\(ApiHostPreference.currentBaseURL)/config") else { return }
        guard let (data, response) = try? await URLSession.shared.data(from: url) else { return }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
        guard let config = try? JSONDecoder().decode(ServerConfigResponse.self, from: data) else { return }

        if let maxSubs = config.maxSubscriptionsPerDevice, maxSubs > 0 {
            UserDefaults.standard.set(maxSubs, forKey: maxSubsKey)
            maxSubscriptionsPerDevice = maxSubs
            debugLog("⚙️ [ServerConfig] maxSubscriptionsPerDevice = \(maxSubs)")
        }
        if let maxLive = config.maxLiveSessionsPerDevice, maxLive > 0 {
            UserDefaults.standard.set(maxLive, forKey: maxLiveKey)
            maxLiveSessionsPerDevice = maxLive
            debugLog("⚙️ [ServerConfig] maxLiveSessionsPerDevice = \(maxLive)")
        }
    }

    // MARK: - Background refresh

    private var backgroundRefreshTask: Task<Void, Never>?
    private let backgroundRefreshInterval: TimeInterval = 4 * 60 * 60 // 4 hours

    private func startBackgroundRefresh() {
        backgroundRefreshTask?.cancel()
        backgroundRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.backgroundRefreshInterval ?? 14400) * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }
}

// MARK: - Response model

private struct ServerConfigResponse: Codable {
    let maxSubscriptionsPerDevice: Int?
    let maxLiveSessionsPerDevice: Int?

    enum CodingKeys: String, CodingKey {
        case maxSubscriptionsPerDevice = "max_subscriptions_per_device"
        case maxLiveSessionsPerDevice  = "max_live_sessions_per_device"
    }
}
