import SwiftUI
import Observation

@MainActor @Observable
final class HorizontalTabSwipePresentation {
    var offset: CGFloat = 0
    var isInteracting = false
    var selectedTab: Tab?
}

struct HorizontalTabSwipePresentationEnvironmentKey: EnvironmentKey {
    static let defaultValue: HorizontalTabSwipePresentation? = nil
}

extension EnvironmentValues {
    var horizontalTabSwipePresentation: HorizontalTabSwipePresentation? {
        get { self[HorizontalTabSwipePresentationEnvironmentKey.self] }
        set { self[HorizontalTabSwipePresentationEnvironmentKey.self] = newValue }
    }
}

private struct ActiveHorizontalTabSwipePageEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isActiveHorizontalTabSwipePage: Bool {
        get { self[ActiveHorizontalTabSwipePageEnvironmentKey.self] }
        set { self[ActiveHorizontalTabSwipePageEnvironmentKey.self] = newValue }
    }
}

struct HorizontalTabSwipeModifier: ViewModifier {
    @Binding var selection: Tab
    let tabs: [Tab]
    let isEnabled: Bool
    let onOpenBackgroundPhoto: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var translation: CGFloat = 0
    @State private var dragAxis: DragAxis?
    @State private var isReady = false
    @State private var thresholdFeedbackTrigger = 0
    @State private var presentation = HorizontalTabSwipePresentation()

    private let commitDistance: CGFloat = 44
    private let projectedCommitDistance: CGFloat = 90

    private enum DragAxis {
        case horizontal
        case vertical
    }

    func body(content: Content) -> some View {
        content
            .environment(\.horizontalTabSwipePresentation, presentation)
            .contentShape(Rectangle())
            .simultaneousGesture(swipeGesture, isEnabled: isEnabled)
            .overlay(alignment: hintAlignment) { swipeHint }
            .sensoryFeedback(.impact(weight: .light), trigger: thresholdFeedbackTrigger)
            .onChange(of: isEnabled) { _, isEnabled in
                guard !isEnabled else { return }
                resetSwipeWithoutAnimation()
            }
            .onChange(of: selection) { _, _ in
                resetSwipeWithoutAnimation()
                presentation.selectedTab = selection
            }
            .onChange(of: tabs) { _, _ in
                resetSwipeWithoutAnimation()
            }
            .onDisappear {
                resetSwipeWithoutAnimation()
            }
            .onAppear {
                presentation.selectedTab = selection
            }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { value in
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)

                if dragAxis == nil {
                    guard max(horizontal, vertical) >= 10 else { return }
                    dragAxis = HorizontalTabSwipeMotion.hasHorizontalIntent(
                        translationWidth: value.translation.width,
                        translationHeight: value.translation.height
                    ) ? .horizontal : .vertical
                }

                guard dragAxis == .horizontal else { return }
                translation = value.translation.width
                presentation.selectedTab = selection
                presentation.offset = HorizontalTabSwipeMotion.visualOffset(
                    for: value.translation.width,
                    hasAdjacentTab: destination(for: value.translation.width) != nil,
                    reduceMotion: accessibilityReduceMotion
                )
                presentation.isInteracting = true

                let newReadyState = HorizontalTabSwipeMotion.hasHorizontalIntent(
                    translationWidth: value.translation.width,
                    translationHeight: value.translation.height
                ) && horizontal >= commitDistance
                    && destination(for: value.translation.width) != nil
                if newReadyState != isReady {
                    if newReadyState {
                        thresholdFeedbackTrigger += 1
                    }
                    isReady = newReadyState
                }
            }
            .onEnded { value in
                defer {
                    dragAxis = nil
                    presentation.isInteracting = false
                }
                let horizontal = value.translation.width
                let shouldCommit = dragAxis == .horizontal
                    && HorizontalTabSwipeMotion.shouldCommit(
                        translationWidth: horizontal,
                        translationHeight: value.translation.height,
                        predictedEndTranslationWidth: value.predictedEndTranslation.width,
                        commitDistance: commitDistance,
                        projectedCommitDistance: projectedCommitDistance
                    )
                let target = shouldCommit ? destination(for: horizontal) : nil

                if let target {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        translation = 0
                        presentation.offset = 0
                        isReady = false
                        if case .tab(let tab) = target {
                            selection = tab
                        }
                    }
                    if target == .backgroundPhoto {
                        onOpenBackgroundPhoto?()
                    }
                } else {
                    withAnimation(resetAnimation) {
                        translation = 0
                        presentation.offset = 0
                    }
                    isReady = false
                }
            }
    }

    private func resetSwipeWithoutAnimation() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            translation = 0
            presentation.offset = 0
            presentation.isInteracting = false
            dragAxis = nil
            isReady = false
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

    private func destination(for horizontalTranslation: CGFloat) -> HorizontalTabSwipeDestination? {
        HorizontalTabSwipeDestination.resolve(
            horizontalTranslation: horizontalTranslation,
            selection: selection,
            tabs: tabs,
            hasBackgroundPhoto: onOpenBackgroundPhoto != nil
        )
    }

    @ViewBuilder
    private var swipeHint: some View {
        if let target = destination(for: translation) {
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

enum HorizontalTabSwipeDestination: Equatable {
    case tab(Tab)
    case backgroundPhoto

    static func resolve(
        horizontalTranslation: CGFloat,
        selection: Tab,
        tabs: [Tab],
        hasBackgroundPhoto: Bool
    ) -> Self? {
        guard horizontalTranslation != 0,
              let currentIndex = tabs.firstIndex(of: selection) else {
            return nil
        }
        if horizontalTranslation > 0, currentIndex == tabs.startIndex, hasBackgroundPhoto {
            return .backgroundPhoto
        }
        let targetIndex = horizontalTranslation < 0 ? currentIndex + 1 : currentIndex - 1
        guard tabs.indices.contains(targetIndex) else { return nil }
        return .tab(tabs[targetIndex])
    }

    var title: String {
        switch self {
        case .tab(let tab): tab.title
        case .backgroundPhoto: "Photo"
        }
    }

    var systemImage: String {
        switch self {
        case .tab(let tab): tab.systemImage
        case .backgroundPhoto: "photo"
        }
    }
}

enum HorizontalTabSwipeMotion {
    private static let edgeResistance: CGFloat = 0.18
    private static let reducedMotionScale: CGFloat = 0.22
    private static let horizontalDominance: CGFloat = 1.15

    static func visualOffset(
        for translation: CGFloat,
        hasAdjacentTab: Bool,
        reduceMotion: Bool
    ) -> CGFloat {
        let motionScale: CGFloat = reduceMotion ? reducedMotionScale : 1
        let boundaryScale: CGFloat = hasAdjacentTab ? 1 : edgeResistance
        return translation * motionScale * boundaryScale
    }

    static func shouldCommit(
        translationWidth: CGFloat,
        translationHeight: CGFloat,
        predictedEndTranslationWidth: CGFloat,
        commitDistance: CGFloat,
        projectedCommitDistance: CGFloat
    ) -> Bool {
        let horizontalDistance = abs(translationWidth)
        guard hasHorizontalIntent(
            translationWidth: translationWidth,
            translationHeight: translationHeight
        ) else { return false }

        let projectionContinuesDirection = translationWidth * predictedEndTranslationWidth > 0
        return horizontalDistance >= commitDistance || (
            projectionContinuesDirection &&
            abs(predictedEndTranslationWidth) >= projectedCommitDistance
        )
    }

    static func hasHorizontalIntent(
        translationWidth: CGFloat,
        translationHeight: CGFloat
    ) -> Bool {
        abs(translationWidth) > abs(translationHeight) * horizontalDominance
    }
}

private struct HorizontalTabSwipePageModifier: ViewModifier {
    let tab: Tab
    @Environment(\.horizontalTabSwipePresentation) private var presentation

    @ViewBuilder
    func body(content: Content) -> some View {
        if let presentation, presentation.selectedTab == tab {
            ZStack {
                // A translated NavigationStack clips its own background at the page edge.
                // Keep a sibling backdrop stationary so a swipe never reveals the tab host.
                RailwayBackgroundBackdrop()

                content
                    .environment(\.isActiveHorizontalTabSwipePage, true)
                    .offset(x: presentation.offset)
                    .allowsHitTesting(!presentation.isInteracting)
            }
        } else {
            content
                .environment(\.isActiveHorizontalTabSwipePage, false)
        }
    }
}

extension View {
    func horizontalTabSwipePage(_ tab: Tab) -> some View {
        modifier(HorizontalTabSwipePageModifier(tab: tab))
    }

    func horizontalTabSwipe(
        selection: Binding<Tab>,
        tabs: [Tab],
        isEnabled: Bool = true,
        onOpenBackgroundPhoto: (() -> Void)? = nil
    ) -> some View {
        modifier(HorizontalTabSwipeModifier(
            selection: selection,
            tabs: tabs,
            isEnabled: isEnabled,
            onOpenBackgroundPhoto: onOpenBackgroundPhoto
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
    let shouldDisable: Bool
    @Environment(\.horizontalTabSwipeDisabled) private var isDisabled

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard shouldDisable else { return }
                isDisabled.wrappedValue = true
            }
            .onDisappear {
                guard shouldDisable else { return }
                isDisabled.wrappedValue = false
            }
    }
}

extension View {
    func horizontalTabSwipeDisabled(_ isDisabled: Binding<Bool>) -> some View {
        environment(\.horizontalTabSwipeDisabled, isDisabled)
    }

    func disablesHorizontalTabSwipe(_ isDisabled: Bool = true) -> some View {
        modifier(HorizontalTabSwipeDisabledModifier(shouldDisable: isDisabled))
    }
}
