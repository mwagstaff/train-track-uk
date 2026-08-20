import Foundation

nonisolated enum NotificationServiceDiagnosticsLogger {
    #if DEBUG
    private static let suiteName = "group.dev.skynolimit.traintrack"
    private static let queue = DispatchQueue(label: "dev.skynolimit.traintrack.notification-service-diagnostics")
    private static let maxFileBytes = 512 * 1024
    #endif

    static func log(
        _ event: String,
        metadata: @autoclosure () -> [String: Any?] = [:]
    ) {
        #if DEBUG
        let metadata = metadata()
        queue.async {
            guard let url = logFileURL(named: "diagnostics-notification-service.jsonl") else { return }
            let entry: [String: Any] = [
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                "category": "notification_service",
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
        #endif
    }

    #if DEBUG
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
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func trimIfNeeded(_ url: URL) {
        guard let data = try? Data(contentsOf: url), data.count > maxFileBytes else { return }
        try? Data(data.suffix(maxFileBytes / 2)).write(to: url, options: .atomic)
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
        case let array as [Any]:
            return array.map(sanitizeValue)
        case let dict as [String: Any]:
            return dict.reduce(into: [String: Any]()) { partial, item in
                partial[item.key] = sanitizeValue(item.value)
            }
        default:
            return String(describing: value)
        }
    }
    #endif
}
