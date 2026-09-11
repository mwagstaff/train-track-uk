import Foundation
import Combine

enum MuteDebugEntryKind {
    case sent
    case response
}

struct MuteDebugEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let from: String
    let to: String
    let kind: MuteDebugEntryKind
    /// Human-readable detail: "sent" for outgoing, "200 OK" / "error: …" for responses.
    let detail: String

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: timestamp)
    }

    var routeLabel: String { "\(from) → \(to)" }
}

@MainActor
final class MuteRequestDebugStore: ObservableObject {
    static let shared = MuteRequestDebugStore()

    /// Newest entries first. Capped at 10 (5 sent + 5 response pairs).
    @Published private(set) var entries: [MuteDebugEntry] = []

    /// Convenience for callers that just need the latest entry.
    var last: MuteDebugEntry? { entries.first }

    // Retains from/to so the response entry can match the corresponding sent entry.
    private var lastSentEntry: MuteDebugEntry?

    static let maxEntries = 10

    private init() {}

    /// Call when a terminate request is about to be uploaded.
    func record(from: String, to: String) {
        let entry = MuteDebugEntry(
            timestamp: Date(),
            from: from.uppercased(),
            to: to.uppercased(),
            kind: .sent,
            detail: "sent"
        )
        lastSentEntry = entry
        addEntry(entry)
    }

    /// Call when the server response (or error) arrives for the last recorded request.
    func update(status: String, response: String?) {
        let from = lastSentEntry?.from ?? "?"
        let to   = lastSentEntry?.to   ?? "?"
        let detail: String
        switch status {
        case "200":   detail = "200 OK"
        case "error": detail = "error: \(response ?? "unknown")"
        case "ok":    detail = "ok"
        default:
            if let body = response, !body.isEmpty {
                detail = "\(status): \(body)"
            } else {
                detail = status
            }
        }
        addEntry(MuteDebugEntry(
            timestamp: Date(),
            from: from,
            to: to,
            kind: .response,
            detail: detail
        ))
    }

    private func addEntry(_ entry: MuteDebugEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
    }
}
