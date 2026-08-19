import SwiftUI

struct HorizontalTabSwipeModifier: ViewModifier {
    @Binding var selection: Tab
    let tabs: [Tab]
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var translation: CGFloat = 0
    @State private var isTracking = false
    @State private var isReady = false
    @State private var thresholdFeedbackTrigger = 0

    private let commitDistance: CGFloat = 44
    private let projectedCommitDistance: CGFloat = 90

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(swipeGesture, isEnabled: isEnabled)
            .overlay(alignment: hintAlignment) { swipeHint }
            .sensoryFeedback(.impact(weight: .light), trigger: thresholdFeedbackTrigger)
            .onChange(of: isEnabled) { _, isEnabled in
                guard !isEnabled else { return }
                translation = 0
                isTracking = false
                isReady = false
            }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)

                guard isTracking || horizontal > vertical * 1.1 else { return }

                if !isTracking {
                    isTracking = true
                }
                translation = value.translation.width

                let newReadyState = horizontal >= commitDistance
                    && adjacentTab(for: value.translation.width) != nil
                if newReadyState != isReady {
                    if newReadyState {
                        thresholdFeedbackTrigger += 1
                    }
                    isReady = newReadyState
                }
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let projectedHorizontal = value.predictedEndTranslation.width
                let direction = abs(projectedHorizontal) > abs(horizontal)
                    ? projectedHorizontal
                    : horizontal
                let shouldCommit = isTracking
                    && (abs(horizontal) >= commitDistance
                        || abs(projectedHorizontal) >= projectedCommitDistance)
                let target = shouldCommit ? adjacentTab(for: direction) : nil

                withAnimation(resetAnimation) {
                    translation = 0
                }
                isTracking = false
                isReady = false

                if let target {
                    selection = target
                }
            }
    }

    private var resetAnimation: Animation? {
        accessibilityReduceMotion
            ? nil
            : .timingCurve(0.16, 1, 0.3, 1, duration: 0.18)
    }

    private var progress: CGFloat {
        min(abs(translation) / commitDistance, 1)
    }

    private var hintAlignment: Alignment {
        translation < 0 ? .trailing : .leading
    }

    private func adjacentTab(for horizontalTranslation: CGFloat) -> Tab? {
        guard horizontalTranslation != 0,
              let currentIndex = tabs.firstIndex(of: selection) else {
            return nil
        }
        let targetIndex = horizontalTranslation < 0 ? currentIndex + 1 : currentIndex - 1
        guard tabs.indices.contains(targetIndex) else { return nil }
        return tabs[targetIndex]
    }

    @ViewBuilder
    private var swipeHint: some View {
        if let target = adjacentTab(for: translation) {
            HStack(spacing: 8) {
                if translation > 0 {
                    Image(systemName: "chevron.backward")
                }
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.16), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            isReady ? Color.accentColor : Color.primary,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Image(systemName: target.systemImage)
                        .font(.caption.weight(.semibold))
                }
                .frame(width: 28, height: 28)
                Text(target.title)
                if translation < 0 {
                    Image(systemName: "chevron.forward")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isReady ? Color.accentColor : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .opacity(0.35 + (0.65 * progress))
            .scaleEffect(accessibilityReduceMotion ? 1 : 0.96 + (0.04 * progress))
            .offset(x: accessibilityReduceMotion
                ? 0
                : (translation < 0 ? 16 : -16) * (1 - progress))
            .padding(.horizontal, 12)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
    }
}

extension View {
    func horizontalTabSwipe(
        selection: Binding<Tab>,
        tabs: [Tab],
        isEnabled: Bool = true
    ) -> some View {
        modifier(HorizontalTabSwipeModifier(
            selection: selection,
            tabs: tabs,
            isEnabled: isEnabled
        ))
    }
}

private struct HorizontalTabSwipeDisabledEnvironmentKey: EnvironmentKey {
    static let defaultValue: Binding<Bool> = .constant(false)
}

private extension EnvironmentValues {
    var horizontalTabSwipeDisabled: Binding<Bool> {
        get { self[HorizontalTabSwipeDisabledEnvironmentKey.self] }
        set { self[HorizontalTabSwipeDisabledEnvironmentKey.self] = newValue }
    }
}

private struct HorizontalTabSwipeDisabledModifier: ViewModifier {
    @Environment(\.horizontalTabSwipeDisabled) private var isDisabled

    func body(content: Content) -> some View {
        content
            .onAppear {
                isDisabled.wrappedValue = true
            }
            .onDisappear {
                isDisabled.wrappedValue = false
            }
    }
}

extension View {
    func horizontalTabSwipeDisabled(_ isDisabled: Binding<Bool>) -> some View {
        environment(\.horizontalTabSwipeDisabled, isDisabled)
    }

    func disablesHorizontalTabSwipe() -> some View {
        modifier(HorizontalTabSwipeDisabledModifier())
    }
}
