import Foundation
import Testing
@testable import TrainTrack_UK

struct RailwayBackgroundTests {
    @Test func dailyRotationIsStableAndAdvancesAtLondonMidnight() throws {
        let catalog = makeCatalog()
        let formatter = ISO8601DateFormatter()
        let beforeMidnight = try #require(formatter.date(from: "2026-08-27T22:30:00Z"))
        let afterMidnight = try #require(formatter.date(from: "2026-08-27T23:30:00Z"))

        let first = RailwayBackgroundDailyRotation.selectedAssetID(catalog: catalog, date: beforeMidnight)
        let repeated = RailwayBackgroundDailyRotation.selectedAssetID(catalog: catalog, date: beforeMidnight)
        let next = RailwayBackgroundDailyRotation.selectedAssetID(catalog: catalog, date: afterMidnight)

        #expect(first == repeated)
        #expect(first != next)
        #expect(RailwayBackgroundDailyRotation.dayKey(for: beforeMidnight) == "2026-08-27")
        #expect(RailwayBackgroundDailyRotation.dayKey(for: afterMidnight) == "2026-08-28")
    }

    @Test func relativeAssetURLPreservesTheTrainTrackDeploymentPrefix() throws {
        let asset = try #require(makeCatalog().assets.first)
        let url = asset.remoteURL(apiBaseURL: "https://api.skynolimit.dev/train-track/api/v2")
        #expect(url?.absoluteString == "https://api.skynolimit.dev/train-track/api/v2/railway-backgrounds/assets/test.webp")
    }

    private func makeCatalog() -> RailwayBackgroundCatalog {
        let ids = ["one", "two", "three"]
        return RailwayBackgroundCatalog(
            schemaVersion: 1,
            catalogVersion: String(repeating: "a", count: 64),
            generatedAt: "2026-08-27T00:00:00Z",
            rotation: RailwayBackgroundRotation(
                timeZone: "Europe/London",
                epochDate: "2026-01-01",
                assetIDs: ids
            ),
            assets: ids.map { id in
                RailwayBackgroundAsset(
                    id: id,
                    title: id,
                    location: "Test",
                    caption: nil,
                    focalPoint: RailwayBackgroundFocalPoint(x: 0.5, y: 0.5),
                    scrimOpacity: 0.3,
                    sha256: String(repeating: id == "one" ? "a" : "b", count: 64),
                    assetPath: "assets/test.webp",
                    assetURL: "/api/v2/railway-backgrounds/assets/test.webp",
                    contentType: "image/webp",
                    byteSize: 100,
                    width: 640,
                    height: 480,
                    credit: RailwayBackgroundCredit(
                        photographer: nil,
                        photographerURL: nil,
                        source: nil,
                        sourcePage: nil,
                        license: "POC",
                        licenseURL: nil
                    )
                )
            }
        )
    }
}
