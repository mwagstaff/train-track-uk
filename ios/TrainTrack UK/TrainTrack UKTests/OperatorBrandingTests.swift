import Foundation
import Testing
@testable import TrainTrack_UK

struct OperatorBrandingTests {
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
