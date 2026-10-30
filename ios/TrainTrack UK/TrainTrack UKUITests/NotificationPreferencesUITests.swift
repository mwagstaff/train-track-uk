import XCTest

final class NotificationPreferencesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testNotificationControlsInLightAndLargeDarkText() {
        let originalAppearance = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = originalAppearance }
        for largeText in [false, true] {
            XCUIDevice.shared.appearance = largeText ? .dark : .light
            let app = XCUIApplication()
            app.launchEnvironment["APP_STORE_SCREENSHOTS"] = "1"
            app.launchEnvironment["API_BASE"] = "http://127.0.0.1:1/api/v2"
            app.launchEnvironment["LOADING_API_BASE"] = "http://127.0.0.1:1/api/v2"
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB",
                                   "-notificationPreferences.platformOnlyNearStation", "YES",
                                   "-notificationPreferences.connectionAlerts", "YES",
                                   "-notificationPreferences.connectionUnknownDelay", "YES",
                                   "-notificationPreferences.connectionDelayMinutes", "5"]
            if largeText {
                app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
            }
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Profile"].waitForExistence(timeout: 15))
            app.tabBars.buttons["Profile"].tap()
            app.staticTexts["Preferences"].tap()
            let nearStation = app.switches["Platform updates only near the station"]
            reveal(nearStation, in: app)
            XCTAssertEqual(nearStation.value as? String, "1")
            screenshot(app, name: "Platform-preferences-\(largeText ? "dark-large" : "light")")
            let connections = app.switches["Notify about remaining connections"]
            reveal(connections, in: app)
            XCTAssertEqual(connections.value as? String, "1")
            let unknown = app.switches["Notify when delay length is unknown"]
            reveal(unknown, in: app)
            XCTAssertEqual(unknown.value as? String, "1")
            XCTAssertTrue(app.steppers.firstMatch.exists)
            screenshot(app, name: "Connection-preferences-\(largeText ? "dark-large" : "light")")
            app.terminate()
        }
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
