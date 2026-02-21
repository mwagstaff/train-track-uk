import Foundation
import Combine

struct MuteRequestDebugInfo: Identifiable {
    let id = UUID()
    let timestamp: Date
    let payload: String
    let url: String
    let status: String
    let response: String?
}

@MainActor
final class MuteRequestDebugStore: ObservableObject {
    static let shared = MuteRequestDebugStore()

    @Published private(set) var last: MuteRequestDebugInfo? = nil

    private init() {}

    func record(payload: String, url: String, status: String) {
        last = MuteRequestDebugInfo(timestamp: Date(), payload: payload, url: url, status: status, response: nil)
    }

    func update(status: String, response: String?) {
        guard let existing = last else { return }
        last = MuteRequestDebugInfo(
            timestamp: existing.timestamp,
            payload: existing.payload,
            url: existing.url,
            status: status,
            response: response
        )
    }
}
