import XCTest

final class DisruptionMonitoringUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testWarningsAndSettingsAreAccessibleFromBothSavedTabsAtLargeText() {
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
                let warning = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "disruptions.row.")).firstMatch
                XCTAssertTrue(warning.waitForExistence(timeout: 5))
                reveal(warning, in: app)
                warning.tap()
                XCTAssertTrue(app.navigationBars["Advance warnings"].waitForExistence(timeout: 5))
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "\(tab)-advance-warnings-\(largeText ? "dark-large" : "light")"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertTrue(app.buttons["disruptions.save"].exists)
                let monitor = app.switches["Monitor this direction"]
                reveal(monitor, in: app)
                XCTAssertTrue(monitor.isHittable)
                let pushes = app.switches["Push notifications"]
                reveal(pushes, in: app)
                XCTAssertEqual(pushes.value as? String, "0")
                XCTAssertTrue(app.buttons["disruptions.save"].isHittable)
                app.buttons["Cancel"].tap()
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
