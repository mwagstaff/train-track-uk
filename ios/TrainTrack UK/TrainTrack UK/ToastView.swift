import SwiftUI
import Combine

struct Toast: Identifiable, Equatable {
    let id: UUID
    let message: String
    let icon: String?

    init(message: String, icon: String? = nil) {
        self.id = UUID()
        self.message = message
        self.icon = icon
    }
}

@MainActor
final class ToastStore: ObservableObject {
    static let shared = ToastStore()

    @Published private(set) var toast: Toast? = nil
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, icon: String? = nil, duration: TimeInterval = 2.2) {
        dismissTask?.cancel()
        let toast = Toast(message: message, icon: icon)
        self.toast = toast

        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            await MainActor.run {
                if self?.toast?.id == toast.id {
                    self?.toast = nil
                }
            }
        }
    }
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            if let icon = toast.icon {
                Image(systemName: icon)
                    .font(.subheadline)
            }
            Text(toast.message)
                .font(.subheadline)
                .lineLimit(2)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
        .padding(.top, 12)
        .padding(.horizontal, 16)
    }
}
