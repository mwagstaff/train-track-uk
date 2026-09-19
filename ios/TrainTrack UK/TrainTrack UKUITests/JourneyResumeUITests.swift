import XCTest

final class JourneyResumeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEndJourneyRemovesInProgressTab() throws {
        let app = XCUIApplication()
        app.launchEnvironment["APP_STORE_SCREENSHOTS"] = "1"
        app.launchEnvironment["UI_TEST_RESET_HISTORY"] = "1"
        app.launchEnvironment["RELEASE_SCREENSHOT_SCREEN"] = "in-progress"
        app.launch()
        let end = app.buttons["End journey"]
        XCTAssertTrue(end.waitForExistence(timeout: 20))
        for _ in 0..<8 {
            if end.isHittable && end.frame.maxY < app.tabBars.firstMatch.frame.minY { break }
            app.swipeUp()
        }
        end.tap()
        let confirm = app.alerts["End journey?"].buttons["End journey"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let removed = expectation(for: NSPredicate(format: "exists == false"),
            evaluatedWith: app.tabBars.buttons["In Progress"])
        wait(for: [removed], timeout: 20)
        capture("journey-ended-tab-removed", app: app)
    }

    @MainActor
    func testResumeFromCompletion() throws {
        let app = launchEndedJourney()
        let resume = app.buttons["Resume recording"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        capture("ended-early-readable", app: app)
        resume.tap()
        XCTAssertTrue(app.buttons["End journey"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Ended early"].exists)
        capture("recording-resumed", app: app)
    }

    @MainActor
    func testResumeFromHistoryAfterClosingAndRelaunching() throws {
        let app = launchEndedJourney()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 20))
        app.buttons["Close"].tap()
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "RELEASE_SCREENSHOT_SCREEN")
        app.launchEnvironment.removeValue(forKey: "UI_TEST_RESET_HISTORY")
        app.launch()
        let profile = app.tabBars.buttons["Profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 15))
        profile.tap()
        let history = app.buttons["profile.journey-history"]
        XCTAssertTrue(history.waitForExistence(timeout: 15))
        history.tap()
        let journey = app.staticTexts["Kent House → London Victoria"].firstMatch
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        journey.tap()
        let resume = app.buttons["Resume recording"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        capture("resume-from-history", app: app)
        resume.tap()
        XCTAssertTrue(app.buttons["End journey"].waitForExistence(timeout: 20))
    }

    @MainActor
    func testCompletionSupportsAccessibilityTextSize() throws {
        let app = launchEndedJourney(largeText: true)
        let resume = app.buttons["Resume recording"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        for _ in 0..<5 where !resume.isHittable { app.swipeUp() }
        XCTAssertTrue(resume.isHittable)
        capture("ended-early-accessibility-text", app: app)
        let close = app.buttons["Close"]
        for _ in 0..<5 where !close.isHittable { app.swipeUp() }
        XCTAssertTrue(close.isHittable)
    }

    @MainActor
    private func launchEndedJourney(largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["APP_STORE_SCREENSHOTS"] = "1"
        app.launchEnvironment["UI_TEST_RESET_HISTORY"] = "1"
        app.launchEnvironment["RELEASE_SCREENSHOT_SCREEN"] = "journey-ended-early"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
