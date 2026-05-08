import Foundation

enum ClientDiagnosticsLogger {
    private static let suiteName = "group.dev.skynolimit.traintrack"
    private static let queue = DispatchQueue(label: "dev.skynolimit.traintrack.client-diagnostics")
    private static let maxFileBytes = 512 * 1024

    static func log(_ category: String, _ event: String, metadata: [String: Any?] = [:]) {
        queue.async {
            guard let url = logFileURL(named: "diagnostics-app.jsonl") else { return }
            let entry: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "category": category,
                "event": event,
                "metadata": sanitize(metadata)
            ]

            guard JSONSerialization.isValidJSONObject(entry),
                  let data = try? JSONSerialization.data(withJSONObject: entry),
                  let line = String(data: data, encoding: .utf8)?.appending("\n"),
                  let lineData = line.data(using: .utf8) else {
                return
            }

            append(lineData, to: url)
            trimIfNeeded(url)
        }
    }

    static func appLogURL() -> URL? {
        logFileURL(named: "diagnostics-app.jsonl")
    }

    static func notificationServiceLogURL() -> URL? {
        logFileURL(named: "diagnostics-notification-service.jsonl")
    }

    static func exportStoredLogs() -> String {
        [
            ("Client Diagnostics", appLogURL()),
            ("Notification Service Extension Diagnostics", notificationServiceLogURL())
        ].map { title, url in
            let body: String
            if let url, let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8), !text.isEmpty {
                body = text
            } else {
                body = "(no entries)"
            }
            return "## \(title)\n\(body)"
        }
        .joined(separator: "\n\n")
    }

    static func clearStoredLogs() {
        [appLogURL(), notificationServiceLogURL()].forEach { url in
            guard let url else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func logFileURL(named name: String) -> URL? {
        let fileManager = FileManager.default
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let directory else { return nil }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    private static func append(_ data: Data, to url: URL) {
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let data = try? Data(contentsOf: url), data.count > maxFileBytes else { return }
        let suffix = data.suffix(maxFileBytes / 2)
        try? Data(suffix).write(to: url, options: .atomic)
    }

    private static func sanitize(_ metadata: [String: Any?]) -> [String: Any] {
        metadata.reduce(into: [:]) { partial, item in
            guard let value = item.value else { return }
            partial[item.key] = sanitizeValue(value)
        }
    }

    private static func sanitizeValue(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number
        case let bool as Bool:
            return bool
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { partial, item in
                partial[item.key] = sanitizeValue(item.value)
            }
        case let array as [Any]:
            return array.map(sanitizeValue)
        default:
            return String(describing: value)
        }
    }
}
