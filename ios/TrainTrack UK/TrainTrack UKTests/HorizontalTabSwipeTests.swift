import SwiftUI
import Testing
import UIKit
@testable import TrainTrack_UK

@MainActor
private final class HorizontalTabSwipeDisabledState {
    var value = false
}

struct HorizontalTabSwipeTests {
    @Test
    func backgroundPhotoPrecedesFavouritesWithoutReplacingNextTab() {
        let tabs: [TrainTrack_UK.Tab] = [.favourites, .myJourneys, .history, .profile]

        #expect(HorizontalTabSwipeDestination.resolve(
            horizontalTranslation: 50,
            selection: .favourites,
            tabs: tabs,
            hasBackgroundPhoto: true
        ) == .backgroundPhoto)
        #expect(HorizontalTabSwipeDestination.resolve(
            horizontalTranslation: -50,
            selection: .favourites,
            tabs: tabs,
            hasBackgroundPhoto: true
        ) == .tab(.myJourneys))
        #expect(HorizontalTabSwipeDestination.resolve(
            horizontalTranslation: 50,
            selection: .myJourneys,
            tabs: tabs,
            hasBackgroundPhoto: true
        ) == .tab(.favourites))
    }

    @Test
    func contentOffsetTracksTheDragAndResistsUnavailableEdges() {
        #expect(
            HorizontalTabSwipeMotion.visualOffset(
                for: -72,
                hasAdjacentTab: true,
                reduceMotion: false
            ) == -72
        )

        let resistedOffset = HorizontalTabSwipeMotion.visualOffset(
            for: 72,
            hasAdjacentTab: false,
            reduceMotion: false
        )
        #expect(abs(resistedOffset - 12.96) < 0.001)
    }

    @Test
    func reducedMotionLimitsInteractiveTravel() {
        let offset = HorizontalTabSwipeMotion.visualOffset(
            for: -72,
            hasAdjacentTab: true,
            reduceMotion: true
        )

        #expect(abs(offset - -15.84) < 0.001)
    }

    @Test
    func commitRequiresHorizontalIntentAndAConsistentProjection() {
        #expect(HorizontalTabSwipeMotion.shouldCommit(
            translationWidth: -50,
            translationHeight: 12,
            predictedEndTranslationWidth: -70,
            commitDistance: 44,
            projectedCommitDistance: 90
        ))
        #expect(!HorizontalTabSwipeMotion.shouldCommit(
            translationWidth: -50,
            translationHeight: 80,
            predictedEndTranslationWidth: -140,
            commitDistance: 44,
            projectedCommitDistance: 90
        ))
        #expect(!HorizontalTabSwipeMotion.shouldCommit(
            translationWidth: -24,
            translationHeight: 4,
            predictedEndTranslationWidth: 140,
            commitDistance: 44,
            projectedCommitDistance: 90
        ))
        #expect(HorizontalTabSwipeMotion.shouldCommit(
            translationWidth: -24,
            translationHeight: 4,
            predictedEndTranslationWidth: -140,
            commitDistance: 44,
            projectedCommitDistance: 90
        ))
        #expect(!HorizontalTabSwipeMotion.hasHorizontalIntent(
            translationWidth: 11,
            translationHeight: 10
        ))
        #expect(HorizontalTabSwipeMotion.hasHorizontalIntent(
            translationWidth: 12,
            translationHeight: 10
        ))
    }

    @Test @MainActor
    func routeMapExclusionDisablesSwipeOnlyWhileVisible() async throws {
        let state = HorizontalTabSwipeDisabledState()
        let isDisabled = Binding(
            get: { state.value },
            set: { state.value = $0 }
        )
        let controller = UIHostingController(rootView: AnyView(
            VStack {
                Color.clear
                    .disablesHorizontalTabSwipe()
            }
            .horizontalTabSwipeDisabled(isDisabled)
        ))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()

        try await Task.sleep(for: .milliseconds(50))
        #expect(state.value)

        controller.rootView = AnyView(
            Color.clear
                .disablesHorizontalTabSwipe(false)
                .horizontalTabSwipeDisabled(isDisabled)
        )
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!state.value)

        controller.rootView = AnyView(Color.clear)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!state.value)

        window.isHidden = true
    }
}
