import Foundation
import Testing
@testable import TrainTrack_UK

struct OperatorBrandingTests {
    @Test func westCoastLumoResolvesWithMissingAndOlderCachedBranding() {
        let lumo = OperatorBranding(name: "Lumo", operatorCodes: ["LD"], aliases: [], colorHex: "#2D2A8C")
        let oldConfig = OperatorBrandingConfig(version: "old", operators: [lumo])
        #expect(OperatorBrandingResolver.resolve(name: "LF", code: "LF", in: oldConfig) == lumo)
        #expect(OperatorBrandingResolver.resolve(name: nil, code: "lf", in: nil)?.name == "Lumo")
    }

    @Test func pillTextChoosesTheHigherContrastBlackOrWhite() {
        for hex in ["#FFFFFF", "#FFFF00", "#009FE3"] {
            #expect(OperatorBranding(name: "Test", operatorCodes: [], aliases: [], colorHex: hex).usesBlackText)
        }
        for hex in ["#000000", "#1B2254", "#666666", "invalid"] {
            #expect(!OperatorBranding(name: "Test", operatorCodes: [], aliases: [], colorHex: hex).usesBlackText)
        }
    }

    private let config = OperatorBrandingConfig(
        version: "test",
        operators: [
            OperatorBranding(
                name: "Southeastern",
                operatorCodes: ["SE"],
                aliases: ["South Eastern"],
                colorHex: "#009FE3"
            ),
            OperatorBranding(
                name: "Thameslink",
                operatorCodes: ["TL"],
                aliases: ["Thameslink Railway"],
                colorHex: "#E5007D"
            )
        ]
    )

    @Test func resolvesOperatorByNormalizedNameAliasAndCode() {
        #expect(OperatorBrandingResolver.resolve(
            name: " southeastern ",
            code: nil,
            in: config
        )?.name == "Southeastern")
        #expect(OperatorBrandingResolver.resolve(
            name: "South-Eastern",
            code: nil,
            in: config
        )?.name == "Southeastern")
        #expect(OperatorBrandingResolver.resolve(
            name: nil,
            code: "tl",
            in: config
        )?.name == "Thameslink")
    }

    @Test func departureDecodesOperatorIdentity() throws {
        let json = Data(#"{"departure_time":{"scheduled":"10:12","estimated":"10:12"},"operator":"Southeastern","operatorCode":"SE","serviceType":"train","serviceID":"service-1"}"#.utf8)

        let departure = try JSONDecoder().decode(DepartureV2.self, from: json)

        #expect(departure.operator == "Southeastern")
        #expect(departure.operatorCode == "SE")
    }
}
