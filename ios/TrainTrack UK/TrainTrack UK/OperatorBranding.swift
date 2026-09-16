import SwiftUI

struct OperatorBrandingConfig: Codable, Equatable {
    let version: String
    let operators: [OperatorBranding]
}

struct OperatorBranding: Codable, Equatable, Identifiable {
    let name: String
    let operatorCodes: [String]
    let aliases: [String]
    let colorHex: String

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case operatorCodes = "operator_codes"
        case aliases
        case colorHex = "color_hex"
    }

    var color: Color {
        guard let value = UInt64(colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else {
            return .secondary
        }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    var usesBlackText: Bool {
        guard let value = UInt64(colorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) else {
            return false
        }
        func linear(_ component: UInt64) -> Double {
            let channel = Double(component) / 255
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear((value >> 16) & 0xFF)
            + 0.7152 * linear((value >> 8) & 0xFF)
            + 0.0722 * linear(value & 0xFF)
        return (luminance + 0.05) / 0.05 >= 1.05 / (luminance + 0.05)
    }
}

enum OperatorBrandingResolver {
    static func resolve(
        name: String?,
        code: String?,
        in config: OperatorBrandingConfig?
    ) -> OperatorBranding? {
        // Support LF before the updated server configuration replaces an older cache.
        if normalize(code) == "lf" || normalize(name) == "lf" {
            return resolve(name: "Lumo", code: "LD", in: config)
                ?? OperatorBranding(name: "Lumo", operatorCodes: ["LD", "LF"], aliases: [], colorHex: "#2D2A8C")
        }
        guard let config else { return nil }
        let normalizedName = normalize(name)
        if !normalizedName.isEmpty,
           let nameMatch = config.operators.first(where: { operatorBrand in
               ([operatorBrand.name] + operatorBrand.aliases)
                   .map { normalize($0) }
                   .contains(normalizedName)
           }) {
            return nameMatch
        }

        let normalizedCode = normalize(code)
        guard !normalizedCode.isEmpty else { return nil }
        return config.operators.first { operatorBrand in
            operatorBrand.operatorCodes.map { normalize($0) }.contains(normalizedCode)
        }
    }

    private static func normalize(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}
