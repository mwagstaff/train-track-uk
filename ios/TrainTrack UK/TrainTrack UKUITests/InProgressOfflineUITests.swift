import XCTest

final class InProgressOfflineUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSavedArrivalAndWarningRemainVisibleOffline() {
        let app = launch(screen: "in-progress-offline", largeText: false)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Live updates interrupted'")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'ETA '")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Unavailable"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Last updated'")).firstMatch.exists)
        attach("saved-journey-offline", app: app)
    }

    @MainActor
    func testCompactRetryFitsAndWorksInLightAndLargeDarkText() {
        for largeText in [false, true] {
            let app = launch(screen: "in-progress-offline-empty", largeText: largeText)
            let retry = app.buttons["Try again now"]
            XCTAssertTrue(retry.waitForExistence(timeout: 30))
            for _ in 0..<12 where !retry.isHittable { app.swipeUp() }
            XCTAssertTrue(retry.isHittable)
            let container = app.otherElements["service-map.compact-unavailable"]
            XCTAssertTrue(container.exists)
            XCTAssertTrue(container.frame.contains(retry.frame), "Map: \(container.frame); retry: \(retry.frame)")
            XCTAssertGreaterThanOrEqual(retry.frame.height, 44)
            attach(largeText ? "compact-retry-large-dark" : "compact-retry-light", app: app)
            retry.tap()
            // Retry stays in place and must not open the expanded map.
            XCTAssertTrue(container.exists)
            XCTAssertTrue(retry.waitForExistence(timeout: 30))
            app.terminate()
        }
    }

    @MainActor
    private func launch(screen: String, largeText: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["APP_STORE_SCREENSHOTS"] = "1"
        app.launchEnvironment["RELEASE_SCREENSHOT_SCREEN"] = screen
        app.launchEnvironment["UI_TEST_RESET_JOURNEYS"] = "1"
        app.launchEnvironment["UI_TEST_RESET_HISTORY"] = "1"
        app.launchEnvironment["API_BASE"] = "http://127.0.0.1:1/api/v2"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB",
            "-AppleInterfaceStyle", largeText ? "Dark" : "Light",
            "-UIPreferredContentSizeCategoryName", largeText ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryL"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["In Progress"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["In Progress"].isSelected)
        return app
    }

    @MainActor
    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
