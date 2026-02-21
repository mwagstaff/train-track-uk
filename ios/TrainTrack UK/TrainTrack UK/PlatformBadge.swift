import SwiftUI

struct PlatformBadge: View {
    let platform: String
    var isBus: Bool = false

    var body: some View {
        Group {
            if isBus || platform.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "BUS" {
                HStack(spacing: 4) {
                    Image(systemName: "bus")
                    Text("Bus")
                        .lineLimit(1)
                }
                .font(.headline)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.yellow)
                .foregroundStyle(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Bus replacement service")
            } else {
                let colorable = platformIsColorable(platform)
                let bg: Color = colorable ? platformColor(for: platform) : Color.gray.opacity(0.18)
                let fg: Color = colorable ? .black : .secondary

                Text(displayText())
                    .font(.headline)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(bg)
                    .foregroundStyle(fg)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Platform \(displayText())")
            }
        }
    }

    private func displayText() -> String {
        let t = platform.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "TBC" : t
    }
}
