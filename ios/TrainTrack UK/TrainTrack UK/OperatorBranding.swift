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
}

enum OperatorBrandingResolver {
    static func resolve(
        name: String?,
        code: String?,
        in config: OperatorBrandingConfig?
    ) -> OperatorBranding? {
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
