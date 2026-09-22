import Foundation

@inline(__always)
nonisolated func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    Swift.print(message())
    #endif
}

nonisolated enum ClientPerf {
    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        Swift.print("[ClientPerf] \(message())")
        #endif
    }

    static func errorMetadata(_ error: Error) -> String {
        if error is CancellationError {
            return "errorType=CancellationError cancelled=true"
        }
        if let error = error as? URLError {
            return "errorType=URLError urlCode=\(error.code.rawValue) urlName=\(error.code) cancelled=\(error.code == .cancelled)"
        }
        return "errorType=\(type(of: error))"
    }

    static func metricsSummary(_ metrics: URLSessionTaskMetrics) -> String {
        let transaction = metrics.transactionMetrics.last
        return [
            "totalMs=\(milliseconds(metrics.taskInterval.duration))",
            duration("dnsMs", transaction?.domainLookupStartDate, transaction?.domainLookupEndDate),
            duration("connectMs", transaction?.connectStartDate, transaction?.connectEndDate),
            duration("tlsMs", transaction?.secureConnectionStartDate, transaction?.secureConnectionEndDate),
            duration("ttfbMs", transaction?.requestStartDate, transaction?.responseStartDate),
            duration("transferMs", transaction?.responseStartDate, transaction?.responseEndDate),
            "reused=\(transaction?.isReusedConnection ?? false)",
            "protocol=\(transaction?.networkProtocolName ?? "unknown")",
            "redirects=\(metrics.redirectCount)"
        ].joined(separator: " ")
    }

    private static func duration(_ name: String, _ start: Date?, _ end: Date?) -> String {
        guard let start, let end else { return "\(name)=-1" }
        return "\(name)=\(milliseconds(end.timeIntervalSince(start)))"
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(0, Int((interval * 1_000).rounded()))
    }
}

final class ClientTaskMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let summary = ClientPerf.metricsSummary(metrics)
        lock.lock()
        value = summary
        lock.unlock()
    }

    func summary() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
