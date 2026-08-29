import CoreGraphics
import Foundation
import Testing
@testable import TrainTrack_UK

@MainActor
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

    @Test func UnsplashAssetProvidesFilenameDerivedAttributionAndSourceURL() throws {
        let json = """
        {
          "id":"unsplash-one","title":"Highland train","location":"Scottish Highlands",
          "caption":null,"focal_point":{"x":0.5,"y":0.5},"scrim_opacity":0.3,
          "delivery":"server","provider_asset_id":"sKsNVoa_NsY",
          "sha256":"\(String(repeating: "c", count: 64))","asset_path":null,
          "asset_url":"/api/v2/railway-backgrounds/assets/test.webp",
          "content_type":"image/webp","byte_size":100,"width":2560,"height":1707,
          "credit":{"photographer":"Diane Picchiottino","source":"Unsplash","source_page":"https://unsplash.com/photos/sKsNVoa_NsY"}
        }
        """
        let asset = try JSONDecoder().decode(RailwayBackgroundAsset.self, from: Data(json.utf8))

        #expect(asset.isUnsplashPhoto)
        #expect(asset.cacheFileExtension == "webp")
        #expect(asset.attributionText == "Image courtesy of Diane Picchiottino, Unsplash")
        #expect(asset.unsplashSourceURL?.absoluteString == "https://unsplash.com/photos/sKsNVoa_NsY")
    }

    @Test func parallaxFilteringEasesTowardClampedTranslation() {
        var filter = RailwayBackgroundParallaxFilter()

        let first = filter.update(horizontalAngle: 1, verticalAngle: -1, timestamp: 0)
        var settled = first
        for frame in 1...240 {
            settled = filter.update(
                horizontalAngle: 1,
                verticalAngle: -1,
                timestamp: Double(frame) / 60
            )
        }

        #expect(abs(first.width) < RailwayBackgroundParallaxFilter.maximumHorizontalTranslation)
        #expect(abs(first.height) < RailwayBackgroundParallaxFilter.maximumVerticalTranslation)
        #expect(abs(settled.width) <= RailwayBackgroundParallaxFilter.maximumHorizontalTranslation)
        #expect(abs(settled.height) <= RailwayBackgroundParallaxFilter.maximumVerticalTranslation)
        #expect(abs(settled.width) > abs(first.width))
        #expect(abs(settled.height) > abs(first.height))
    }

    @Test func parallaxFilteringSmoothlyReturnsToCentre() {
        var filter = RailwayBackgroundParallaxFilter()
        for frame in 0...120 {
            _ = filter.update(horizontalAngle: 0.18, verticalAngle: -0.18, timestamp: Double(frame) / 60)
        }
        let displaced = filter.translation
        var returned = displaced
        for frame in 121...360 {
            returned = filter.update(horizontalAngle: 0, verticalAngle: 0, timestamp: Double(frame) / 60)
        }

        #expect(abs(returned.width) < abs(displaced.width))
        #expect(abs(returned.height) < abs(displaced.height))
        #expect(abs(returned.width) < 0.01)
        #expect(abs(returned.height) < 0.01)
    }

    @Test func parallaxFilteringIgnoresTinyAttitudeNoise() {
        var filter = RailwayBackgroundParallaxFilter()
        let translation = filter.update(
            horizontalAngle: 0.003,
            verticalAngle: -0.003,
            timestamp: 0
        )

        #expect(translation == .zero)
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
                    delivery: "server",
                    providerAssetID: nil,
                    sha256: String(repeating: id == "one" ? "a" : "b", count: 64),
                    assetPath: "assets/test.webp",
                    assetURL: "/api/v2/railway-backgrounds/assets/test.webp",
                    contentType: "image/webp",
                    byteSize: 100,
                    width: 640,
                    height: 480,
                    credit: RailwayBackgroundCredit(
                        photographer: nil,
                        source: nil
                    )
                )
            }
        )
    }
}
