import SwiftUI
import Testing
import UIKit
@testable import TrainTrack_UK

@MainActor
private final class HorizontalTabSwipeDisabledState {
    var value = false
}

struct HorizontalTabSwipeTests {
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

        controller.rootView = AnyView(Color.clear)
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!state.value)

        window.isHidden = true
    }
}
