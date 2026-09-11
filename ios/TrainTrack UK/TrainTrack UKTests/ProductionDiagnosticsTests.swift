import Foundation
import Testing
@testable import TrainTrack_UK

@Suite(.serialized)
struct ProductionDiagnosticsTests {
    @Test @MainActor
    func troubleshootingIsAlwaysOnAndCanBeExportedAndCleared() throws {
        defer {
            DebugLogStore.shared.clear()
        }

        DebugLogStore.shared.clear()
        let marker = "release-diagnostics-\(UUID().uuidString)"
        DebugLogStore.shared.log(marker)
        ClientDiagnosticsLogger.log("test", marker)
        let export = DebugLogStore.shared.exportLogs()
        #expect(export.contains(marker))
        #expect(export.contains("## Client Diagnostics"))
        let url = try #require(DebugLogStore.shared.exportFileURL())
        #expect(try String(contentsOf: url, encoding: .utf8).contains(marker))
        try FileManager.default.removeItem(at: url)

        DebugLogStore.shared.clear()
        #expect(DebugLogStore.shared.logs.isEmpty)
        #expect(!ClientDiagnosticsLogger.exportStoredLogs().contains(marker))
    }

    @Test @MainActor
    func troubleshootingKeepsOnlyTheTenMostRecentJourneys() {
        defer { DebugLogStore.shared.clear() }
        DebugLogStore.shared.clear()

        let journeyIDs = (0..<11).map { _ in UUID().uuidString }
        for journeyID in journeyIDs {
            ClientDiagnosticsLogger.log("journey_history", "journey_started", metadata: [
                "journey_id": journeyID
            ])
        }

        let export = ClientDiagnosticsLogger.exportStoredLogs()
        #expect(!export.contains(journeyIDs[0]))
        for journeyID in journeyIDs.dropFirst() {
            #expect(export.contains(journeyID))
        }
    }
}
