import Foundation

nonisolated enum ClientDiagnosticsLogger {
    private static let suiteName = "group.dev.skynolimit.traintrack"
    private static let queue = DispatchQueue(label: "dev.skynolimit.traintrack.client-diagnostics")
    private static let maxJourneyCount = 10
    private static let maxFileBytes = 2 * 1024 * 1024

    static let isEnabled = true

    static func log(
        _ category: String,
        _ event: String,
        metadata: @autoclosure () -> [String: Any?] = [:]
    ) {
        guard isEnabled else { return }
        let metadata = metadata()
        queue.async {
            guard isEnabled else { return }
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
            trimIfNeeded(url, afterLogging: event)
        }
    }

    static func appLogURL() -> URL? {
        logFileURL(named: "diagnostics-app.jsonl")
    }

    static func notificationServiceLogURL() -> URL? {
        logFileURL(named: "diagnostics-notification-service.jsonl")
    }

    static func exportStoredLogs() -> String {
        queue.sync {
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
    }

    static func clearStoredLogs() {
        queue.sync {
            [appLogURL(), notificationServiceLogURL()].forEach { url in
                guard let url else { return }
                try? FileManager.default.removeItem(at: url)
            }
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
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func trimIfNeeded(_ url: URL, afterLogging event: String) {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard event == "journey_started" || size > maxFileBytes,
              let data = try? Data(contentsOf: url) else { return }

        var lines = Array(data).split(separator: 0x0A).map { Data($0) }
        if event == "journey_started" {
            var seenJourneyIDs = Set<String>()
            let journeyStartIndices = lines.indices.filter { index in
                guard let entry = try? JSONSerialization.jsonObject(with: lines[index]) as? [String: Any] else {
                    return false
                }
                guard entry["event"] as? String == "journey_started",
                      let journeyID = (entry["metadata"] as? [String: Any])?["journey_id"] as? String else {
                    return false
                }
                return seenJourneyIDs.insert(journeyID).inserted
            }
            if journeyStartIndices.count > maxJourneyCount {
                lines = Array(lines[journeyStartIndices[journeyStartIndices.count - maxJourneyCount]...])
            }
        }

        var retained = lines.joinedWithNewlines()
        if retained.count > maxFileBytes {
            retained = Data(retained.suffix(maxFileBytes / 2)).droppingPartialFirstLine()
        }
        try? retained.write(to: url, options: .atomic)
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

private extension Array where Element == Data {
    func joinedWithNewlines() -> Data {
        var result = Data()
        for line in self {
            result.append(line)
            result.append(0x0A)
        }
        return result
    }
}

private extension Data {
    func droppingPartialFirstLine() -> Data {
        guard let newlineIndex = firstIndex(of: 0x0A) else { return Data() }
        return Data(self[index(after: newlineIndex)...])
    }
}
