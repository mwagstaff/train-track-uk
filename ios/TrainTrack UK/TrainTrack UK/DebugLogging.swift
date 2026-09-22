@inline(__always)
nonisolated func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    Swift.print(message())
    #endif
}

enum ClientPerf {
    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now).components
        return Int(duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000)
    }

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        Swift.print("[ClientPerf] \(message())")
        #endif
    }
}
