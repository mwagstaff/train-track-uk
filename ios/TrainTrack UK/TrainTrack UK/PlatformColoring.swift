import SwiftUI

// Mirror the legacy Ionic logic for platform color mapping.
// - Returns a color chosen from a fixed palette based on the numeric portion of the platform
//   (e.g. "12A" -> 12), or a hash of letters if no digits present.
// - For special values ("TBC", "BUS") or empty/missing strings, no color is applied by callers.

private func colorFromHex(_ hex: String) -> Color {
    var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    if hexSanitized.hasPrefix("#") { hexSanitized.removeFirst() }
    guard hexSanitized.count == 6,
          let intCode = Int(hexSanitized, radix: 16) else {
        return Color.black
    }
    let r = Double((intCode >> 16) & 0xFF) / 255.0
    let g = Double((intCode >> 8) & 0xFF) / 255.0
    let b = Double(intCode & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

func platformIsColorable(_ raw: String) -> Bool {
    let p = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return !p.isEmpty && p != "TBC" && p != "BUS"
}

func platformColor(for platform: String) -> Color {
    // Palette copied from src/lib/stations.ts
    let palette: [String] = [
        "#FF6B6B", // Red
        "#4ECDC4", // Teal
        "#45B7D1", // Blue
        "#96CEB4", // Green
        "#FFEAA7", // Yellow
        "#DDA0DD", // Plum
        "#98D8C8", // Mint
        "#F7DC6F", // Gold
        "#BB8FCE", // Purple
        "#85C1E9", // Light Blue
        "#F8C471", // Orange
        "#82E0AA", // Light Green
        "#F1948A", // Salmon
        "#85C1E9", // Sky Blue
        "#F7DC6F", // Yellow
        "#D7BDE2", // Lavender
        "#A9DFBF", // Light Mint
        "#FAD7A0", // Peach
        "#AED6F1", // Baby Blue
        "#F9E79F", // Light Yellow
    ]

    let trimmed = platform.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = trimmed.filter { $0.isNumber }
    var index: Int? = nil
    if !digits.isEmpty { index = Int(digits) }
    else {
        let letters = trimmed.filter { $0.isLetter }.uppercased()
        if !letters.isEmpty {
            var hash = 0
            for u in letters.unicodeScalars {
                hash = Int(u.value) + ((hash << 5) - hash)
            }
            index = abs(hash)
        }
    }

    guard let i = index, !palette.isEmpty else { return Color.black }
    let hex = palette[i % palette.count]
    return colorFromHex(hex)
}

