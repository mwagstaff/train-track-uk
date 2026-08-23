import SwiftUI

struct JourneyUpdatesChrome: ViewModifier {
    let includeToast: Bool

    @EnvironmentObject private var toastStore: ToastStore
    @EnvironmentObject private var holidayMode: HolidayModeStore
    @State private var bottomBannerHeight: CGFloat = 0

    private var bottomContentClearance: CGFloat {
        holidayMode.isEnabled ? bottomBannerHeight + 16 : 0
    }

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, bottomContentClearance, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) {
                if includeToast, let toast = toastStore.toast {
                    ToastView(toast: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 12)
                        .padding(.bottom, 6)
                        .padding(.horizontal, 16)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if holidayMode.isEnabled {
                    HolidayModeBannerView(onDisable: { holidayMode.setEnabled(false) })
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            bottomBannerHeight = height
                        }
                }
            }
            .animation(.easeOut(duration: 0.25), value: holidayMode.isEnabled)
            .animation(.easeOut(duration: 0.25), value: toastStore.toast)
    }
}

private struct HolidayModeBannerView: View {
    let onDisable: () -> Void

    var body: some View {
        Button(action: onDisable) {
            HStack(spacing: 12) {
                Image(systemName: "beach.umbrella")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Holiday mode enabled")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Tap to disable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
    }
}
