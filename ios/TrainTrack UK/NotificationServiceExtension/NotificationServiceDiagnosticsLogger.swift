import Foundation

nonisolated enum NotificationServiceDiagnosticsLogger {
    private static let suiteName = "group.dev.skynolimit.traintrack"
    private static let queue = DispatchQueue(label: "dev.skynolimit.traintrack.notification-service-diagnostics")
    private static let maxJourneyCount = 10
    private static let maxFileBytes = 512 * 1024

    static let isEnabled = true

    static func log(
        _ event: String,
        metadata: @autoclosure () -> [String: Any?] = [:]
    ) {
        guard isEnabled else { return }
        let metadata = metadata()
        queue.async {
            guard isEnabled else { return }
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
            trimIfNeeded(url, afterLogging: event)
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
        guard event == "did_receive" || size > maxFileBytes,
              let data = try? Data(contentsOf: url) else { return }
        var lines = Array(data).split(separator: 0x0A).map { Data($0) }
        if event == "did_receive" {
            var scheduleKeys: [String] = []
            var firstIndexByScheduleKey: [String: Int] = [:]

            for index in lines.indices {
                guard let entry = try? JSONSerialization.jsonObject(with: lines[index]) as? [String: Any],
                      let metadata = entry["metadata"] as? [String: Any],
                      let scheduleKey = metadata["schedule_key"] as? String,
                      !scheduleKey.isEmpty,
                      firstIndexByScheduleKey[scheduleKey] == nil else {
                    continue
                }
                scheduleKeys.append(scheduleKey)
                firstIndexByScheduleKey[scheduleKey] = index
            }

            if scheduleKeys.count > maxJourneyCount,
               let cutoff = firstIndexByScheduleKey[scheduleKeys[scheduleKeys.count - maxJourneyCount]] {
                lines = Array(lines[cutoff...])
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
