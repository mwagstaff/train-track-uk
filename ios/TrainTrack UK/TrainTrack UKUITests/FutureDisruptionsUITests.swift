import XCTest

final class FutureDisruptionsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testBothSavedTabsOpenChronologicalNoticesInLightAndLargeDarkText() async throws {
        let base = "http://127.0.0.1:3015/api/v2"
        try await requireFixture(base)
        let originalAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = originalAppearance }
        for largeText in [false, true] {
            XCUIDevice.shared.appearance = largeText ? .dark : .light
            let app = launch(base: base, largeText: largeText)
            for tab in ["Favourites", "My Journeys"] {
                app.tabBars.buttons[tab].tap()
                let menu = app.buttons["Journey actions"].firstMatch
                XCTAssertTrue(menu.waitForExistence(timeout: 5))
                menu.tap()
                XCTAssertTrue(app.buttons["Advance warning settings"].waitForExistence(timeout: 3))
                app.buttons["View future disruptions"].tap()
                XCTAssertTrue(app.navigationBars["Future disruptions"].waitForExistence(timeout: 5))
                let first = app.staticTexts["futureDisruptions.notice.earlier"]
                reveal(first, in: app)
                XCTAssertTrue(first.waitForExistence(timeout: 5))
                screenshot(app, name: "\(tab)-future-disruptions-\(largeText ? "dark-large" : "light")")
                let later = app.staticTexts["futureDisruptions.notice.later"]
                reveal(later, in: app)
                XCTAssertTrue(later.exists)
                XCTAssertLessThan(first.frame.minY, later.frame.minY)
                XCTAssertFalse(app.switches["Push notifications"].exists)
                app.buttons["Done"].tap()
                XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    @MainActor
    func testUnavailableSourceDoesNotShowSuccessfulEmptyState() async throws {
        let base = "http://127.0.0.1:3015/unavailable/api/v2"
        try await requireFixture(base)
        let app = launch(base: base, largeText: false)
        app.buttons["Journey actions"].firstMatch.tap()
        app.buttons["View future disruptions"].tap()
        XCTAssertTrue(app.staticTexts["Published notices are unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["No published disruptions found"].exists)
        XCTAssertTrue(app.buttons["Try again"].exists)
        screenshot(app, name: "Future-disruptions-unavailable")
        app.terminate()
    }

    private func requireFixture(_ base: String) async throws {
        var request = URLRequest(url: URL(string: base + "/disruptions/future?stations=KTH,VIC")!)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Start future_disruptions_ui_fixture.py to run these HTTP-backed UI checks.")
        }
    }

    @MainActor
    private func launch(base: String, largeText: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["APP_STORE_SCREENSHOTS"] = "1"
        app.launchEnvironment["API_BASE"] = base
        app.launchEnvironment["UI_TEST_RESET_JOURNEYS"] = "1"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        if largeText {
            app.launchArguments += ["-AppleInterfaceStyle", "Dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
