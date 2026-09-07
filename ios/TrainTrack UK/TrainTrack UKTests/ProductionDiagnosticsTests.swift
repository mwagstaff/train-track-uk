import Foundation
import Testing
@testable import TrainTrack_UK

@Suite(.serialized)
struct ProductionDiagnosticsTests {
    @Test @MainActor
    func troubleshootingIsOptInAndCanBeExportedAndCleared() throws {
        let defaults = try #require(UserDefaults(suiteName: "group.dev.skynolimit.traintrack"))
        let key = "troubleshootingLogsEnabled"
        let previous = defaults.object(forKey: key)
        defer {
            defaults.set(previous, forKey: key)
            DebugLogStore.shared.clear()
        }

        defaults.set(false, forKey: key)
        DebugLogStore.shared.clear()
        var evaluated = false
        func message() -> String {
            evaluated = true
            return "disabled-log-must-not-be-evaluated"
        }
        DebugLogStore.shared.log(message())
        #expect(!evaluated)
        #expect(DebugLogStore.shared.logs.isEmpty)

        defaults.set(true, forKey: key)
        let marker = "release-diagnostics-\(UUID().uuidString)"
        DebugLogStore.shared.log(marker)
        ClientDiagnosticsLogger.log("test", marker)
        let export = DebugLogStore.shared.exportLogs()
        #expect(export.contains(marker))
        #expect(export.contains("## Client Diagnostics"))
        let url = try #require(DebugLogStore.shared.exportFileURL())
        #expect(try String(contentsOf: url, encoding: .utf8).contains(marker))
        try FileManager.default.removeItem(at: url)

        defaults.set(false, forKey: key)
        DebugLogStore.shared.clear()
        #expect(DebugLogStore.shared.logs.isEmpty)
        #expect(!ClientDiagnosticsLogger.exportStoredLogs().contains(marker))
    }
}
