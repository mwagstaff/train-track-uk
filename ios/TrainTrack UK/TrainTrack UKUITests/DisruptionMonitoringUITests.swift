import XCTest

final class DisruptionMonitoringUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAutomaticWarningsAreHiddenFromBothSavedTabsAtLargeText() {
        for largeText in [false, true] {
            let app = XCUIApplication()
            app.launchEnvironment["APP_STORE_SCREENSHOTS"] = "1"
            app.launchEnvironment["API_BASE"] = "http://127.0.0.1:1/api/v2"
            app.launchEnvironment["UI_TEST_RESET_JOURNEYS"] = "1"
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
            if largeText {
                app.launchArguments += ["-AppleInterfaceStyle", "Dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 15))

            for tab in ["Favourites", "My Journeys"] {
                app.tabBars.buttons[tab].tap()
                XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "disruptions.row.")).firstMatch.exists)
                let menu = app.buttons["Journey actions"].firstMatch
                XCTAssertTrue(menu.waitForExistence(timeout: 5))
                reveal(menu, in: app)
                menu.tap()
                XCTAssertFalse(app.buttons["Advance warning settings"].exists)
                let futureItem = app.buttons["View future disruptions"]
                XCTAssertTrue(futureItem.waitForExistence(timeout: 5))
                futureItem.tap()
                XCTAssertTrue(app.navigationBars["Future disruptions"].waitForExistence(timeout: 5))
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "\(tab)-manual-future-disruptions-\(largeText ? "dark-large" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertFalse(app.switches["Monitor this direction"].exists)
                XCTAssertFalse(app.switches["Push notifications"].exists)
                app.buttons["Done"].tap()
                XCTAssertTrue(app.navigationBars[tab].waitForExistence(timeout: 5))
            }
            app.terminate()
        }
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
    }
}
