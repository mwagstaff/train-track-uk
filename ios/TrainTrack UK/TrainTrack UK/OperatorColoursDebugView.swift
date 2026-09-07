#if DEBUG
import SwiftUI

struct OperatorColoursDebugView: View {
    @ObservedObject private var serverConfig = ServerConfigStore.shared

    private var operators: [OperatorBranding] {
        (serverConfig.operatorBranding?.operators ?? [])
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if operators.isEmpty {
                ContentUnavailableView(
                    "Operator colours unavailable",
                    systemImage: "paintpalette",
                    description: Text("Refresh after selecting the API host you want to validate.")
                )

                Button("Refresh configuration") {
                    Task { await serverConfig.refresh() }
                }
            } else {
                Section {
                    ForEach(operators) { operatorBrand in
                        operatorRow(operatorBrand)
                    }
                    .listRowSeparator(.hidden)
                } header: {
                    Text("\(operators.count) configured operators")
                } footer: {
                    if let version = serverConfig.operatorBranding?.version {
                        Text("Branding configuration \(version)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Operator Colours")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await serverConfig.refresh()
        }
        .task {
            await serverConfig.refresh()
        }
    }

    private func operatorRow(_ operatorBrand: OperatorBranding) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(operatorBrand.name)
                .font(.headline)

            HStack(spacing: 8) {
                if !operatorBrand.operatorCodes.isEmpty {
                    Text(operatorBrand.operatorCodes.joined(separator: ", "))
                }
                Text(operatorBrand.colorHex.uppercased())
                    .monospaced()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(alignment: .leading) {
            Capsule()
                .fill(operatorBrand.color)
                .frame(width: 4)
                .padding(.vertical, 6)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(for: operatorBrand))
        .listRowBackground(Color.clear)
    }

    private func accessibilityLabel(for operatorBrand: OperatorBranding) -> String {
        let codes = operatorBrand.operatorCodes.joined(separator: ", ")
        if codes.isEmpty {
            return "\(operatorBrand.name), colour \(operatorBrand.colorHex)"
        }
        return "\(operatorBrand.name), operator code \(codes), colour \(operatorBrand.colorHex)"
    }
}
#endif
