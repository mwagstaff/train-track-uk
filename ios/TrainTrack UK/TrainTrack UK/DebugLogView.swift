import SwiftUI

struct DebugLogView: View {
    @StateObject private var store = DebugLogStore.shared
    @State private var showShareSheet = false
    @State private var exportURL: URL?

    var body: some View {
        NavigationView {
            List {
                if store.logs.isEmpty {
                    Text("No debug logs yet")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(store.logs) { entry in
                        LogEntryRow(entry: entry)
                    }
                }
            }
            .navigationTitle("Debug Logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        store.clear()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack {
                        Button(store.isFetchingServerLogs ? "Fetching" : "Server") {
                            Task {
                                await store.fetchServerAuditLogs()
                            }
                        }
                        .disabled(store.isFetchingServerLogs)

                        Button("Journey") {
                            Task {
                                await JourneyTrackingCoordinator.shared.logDiagnosticSnapshot(reason: "manual")
                            }
                        }

                        Button("Share") {
                            Task {
                                await JourneyTrackingCoordinator.shared.logDiagnosticSnapshot(
                                    reason: "debug-log-share"
                                )
                                exportURL = store.exportFileURL()
                                showShareSheet = exportURL != nil
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let exportURL {
                    ShareSheet(items: [exportURL])
                }
            }
        }
    }
}

struct LogEntryRow: View {
    let entry: DebugLogEntry

    private var categoryColor: Color {
        switch entry.category {
        case "Geofence": return .blue
        case "Mute": return .orange
        case "Network": return .green
        case "Scheduled": return .purple
        case "JourneyHistory": return .indigo
        case "Server": return .teal
        case "Error": return .red
        default: return .gray
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.category)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(categoryColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(categoryColor.opacity(0.15))
                    .cornerRadius(4)

                Spacer()

                Text(entry.timestamp, style: .time)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
        }
        .padding(.vertical, 4)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
