import Foundation
import Combine

@MainActor
final class DebugLogStore: ObservableObject {
    static let shared = DebugLogStore()

    @Published private(set) var logs: [DebugLogEntry] = []
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
    }

    func exportLogs() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        return logs.reversed().map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
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
