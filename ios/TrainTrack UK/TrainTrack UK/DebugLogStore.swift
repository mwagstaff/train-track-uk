import Foundation
import Combine

@MainActor
final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()

    @Published private(set) var logs: [DebugLogEntry] = []
    @Published private(set) var isFetchingServerLogs = false
    private let maxLogs = 500

    private init() {
        // Load persisted logs
        if let data = UserDefaults.standard.data(forKey: "debug_logs"),
           let decoded = try? JSONDecoder().decode([DebugLogEntry].self, from: data) {
            logs = decoded
        }
    }

    func log(_ message: String, category: String = "General") {
        let entry = DebugLogEntry(
            timestamp: Date(),
            category: category,
            message: message
        )
        logs.insert(entry, at: 0)

        // Keep only recent logs
        if logs.count > maxLogs {
            logs = Array(logs.prefix(maxLogs))
        }

        // Persist logs
        if let encoded = try? JSONEncoder().encode(logs) {
            UserDefaults.standard.set(encoded, forKey: "debug_logs")
        }

        // Also print to console
        print("[\(category)] \(message)")
    }

    func clear() {
        logs.removeAll()
        UserDefaults.standard.removeObject(forKey: "debug_logs")
        ClientDiagnosticsLogger.clearStoredLogs()
    }

    func exportLogs() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        let debugLogs = logs.reversed().map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")

        return [
            "## Debug Logs\n\(debugLogs.isEmpty ? "(no entries)" : debugLogs)",
            ClientDiagnosticsLogger.exportStoredLogs()
        ].joined(separator: "\n\n")
    }

    func fetchServerAuditLogs(limit: Int = 40) async {
        guard !isFetchingServerLogs else { return }
        isFetchingServerLogs = true
        defer { isFetchingServerLogs = false }

        let deviceId = DeviceIdentity.deviceToken
        var components = URLComponents(string: "\(ApiHostPreference.currentBaseURL)/notifications/debug/subscription-audit")
        components?.queryItems = [
            URLQueryItem(name: "q", value: deviceId),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else {
            log("Server audit fetch failed: invalid URL", category: "Error")
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                log("Server audit fetch failed: HTTP \(http.statusCode)", category: "Error")
                return
            }
            guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let events = payload["events"] as? [[String: Any]] else {
                log("Server audit fetch failed: unexpected response", category: "Error")
                return
            }

            log("Fetched \(events.count) server audit event(s) for device \(deviceId)", category: "Server")
            for event in events.prefix(30).reversed() {
                log(serverAuditSummary(event), category: "Server")
            }
        } catch {
            log("Server audit fetch failed: \(error.localizedDescription)", category: "Error")
        }
    }

    private func serverAuditSummary(_ event: [String: Any]) -> String {
        let recordedAt = event["recorded_at"] as? String ?? "unknown-time"
        let action = event["action"] as? String ?? "unknown-action"
        let reason = event["reason"] as? String ?? "unknown-reason"
        let routeKey = event["route_key"] as? String ?? "no-route"
        let source = event["source"] as? String ?? "no-source"
        let subscriptionId = event["subscription_id"] as? String ?? "no-subscription"
        let metadata = event["metadata"] as? [String: Any]
        let leg = metadata?["leg"] as? String
        let scheduleKey = metadata?["schedule_key"] as? String
        let journeyId = metadata?["journey_id"] as? String
        let serviceId = metadata?["service_id"] as? String
        let stationCRS = metadata?["station_crs"] as? String
        let pushStatus = metadata?["push_status"]
        let actualArrival = metadata?["actual_arrival"] as? String

        return [
            "\(recordedAt) \(action)",
            "Reason: \(reason)",
            "Source: \(source)",
            "Route: \(routeKey)",
            "Leg: \(leg ?? "nil")",
            "Schedule: \(scheduleKey ?? "nil")",
            "Journey: \(journeyId ?? "nil")",
            "Service: \(serviceId ?? "nil")",
            "Station: \(stationCRS ?? "nil")",
            "Push status: \(pushStatus.map(String.init(describing:)) ?? "nil")",
            "Actual arrival: \(actualArrival ?? "nil")",
            "Subscription: \(subscriptionId)"
        ].joined(separator: "\n")
    }
}

struct DebugLogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let category: String
    let message: String

    init(timestamp: Date, category: String, message: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}
