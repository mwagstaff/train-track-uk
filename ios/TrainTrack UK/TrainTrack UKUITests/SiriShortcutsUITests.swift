import XCTest

final class SiriShortcutsUITests: XCTestCase {
    private let routeID = "00000000-0000-0000-0000-000000000001"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testNamedDefaultRoutePersistsAcrossRelaunch() throws {
        let app = launch(resetJourneys: true)
        openSettings(in: app)
        let rename = app.buttons["siri.rename-route.\(routeID)"]
        scrollTo(rename, in: app)
        XCTAssertTrue(rename.isHittable)
        rename.tap()

        let field = app.textFields["siri.route-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText("Commute")
        app.buttons["siri.route-name.save"].tap()
        XCTAssertTrue(app.navigationBars["Siri & Shortcuts"].waitForExistence(timeout: 5))

        attach("siri-settings-before-selection", in: app)
        attachAccessibilityTree("siri-settings-before-selection", in: app)
        let picker = app.buttons["siri.default-route"]
        scrollTo(picker, in: app, towardTop: true)
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        let option = app.buttons["siri.default-route.option.\(routeID)"]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        attach("siri-settings-default", in: app)
        attachAccessibilityTree("siri-settings-after-selection", in: app)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "Commute"), evaluatedWith: picker)
        waitForExpectations(timeout: 5)

        app.terminate()
        app.launchEnvironment.removeValue(forKey: "UI_TEST_RESET_JOURNEYS")
        app.launch()
        openSettings(in: app)
        let restoredPicker = app.buttons["siri.default-route"]
        attach("siri-settings-restored-before-check", in: app)
        attachAccessibilityTree("siri-settings-restored", in: app)
        expectation(for: NSPredicate(format: "value CONTAINS %@", "Commute"), evaluatedWith: restoredPicker)
        waitForExpectations(timeout: 5)
        let restoredRoute = app.buttons["siri.rename-route.\(routeID)"]
        scrollTo(restoredRoute, in: app)
        XCTAssertTrue(restoredRoute.label.contains("Commute"))
        restoredRoute.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Commute")
        app.buttons["Cancel"].tap()
        attach("siri-settings-restored", in: app)
    }

    @MainActor
    func testMyJourneysRouteCanBeDefaultAndShowsNamedExampleWithoutDefault() throws {
        let app = launch(resetJourneys: true)
        openSettings(in: app)
        // The existing screenshot fixture saves Paddington–Oxford in My Journeys.
        let myJourneyID = "00000000-0000-0000-0000-000000000003"
        let rename = app.buttons["siri.rename-route.\(myJourneyID)"]
        scrollTo(rename, in: app)
        XCTAssertTrue(rename.isHittable)
        rename.tap()
        let field = app.textFields["siri.route-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let existing = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText("A day in Oxford")
        app.buttons["siri.route-name.save"].tap()
        XCTAssertTrue(app.navigationBars["Siri & Shortcuts"].waitForExistence(timeout: 5))

        let picker = app.buttons["siri.default-route"]
        scrollTo(picker, in: app, towardTop: true)
        XCTAssertTrue(picker.isHittable)
        picker.tap()
        let option = app.buttons["siri.default-route.option.\(myJourneyID)"]
        scrollTo(option, in: app)
        XCTAssertTrue(option.isHittable)
        option.tap()
        expectation(for: NSPredicate(format: "value CONTAINS %@", "A day in Oxford"), evaluatedWith: picker)
        waitForExpectations(timeout: 5)

        picker.tap()
        let noDefault = app.buttons["siri.default-route.none"]
        XCTAssertTrue(noDefault.waitForExistence(timeout: 5))
        noDefault.tap()
        expectation(for: NSPredicate(format: "value == %@", "Choose a route"), evaluatedWith: picker)
        waitForExpectations(timeout: 5)
        let example = app.staticTexts["siri.named-route-example"]
        scrollTo(example, in: app)
        XCTAssertTrue(example.isHittable)
        XCTAssertTrue(example.label.contains("Get next trains for A day in Oxford"))
        attach("siri-named-my-journeys-example", in: app)
    }

    @MainActor
    func testSettingsAtLargestTextSize() throws {
        let app = launch(resetJourneys: true, largestText: true)
        openSettings(in: app)
        let picker = app.buttons["siri.default-route"]
        XCTAssertTrue(picker.isHittable)
        attach("siri-settings-largest-text-top", in: app)
        let rename = app.buttons["siri.rename-route.\(routeID)"]
        scrollTo(rename, in: app)
        XCTAssertTrue(rename.isHittable)
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
        // The audit scrolls the form while inspecting its accessible elements.
        scrollTo(rename, in: app, towardTop: true)
        XCTAssertTrue(rename.isHittable)
        attach("siri-settings-largest-text-routes", in: app)
        rename.tap()
        let field = app.textFields["siri.route-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        XCTAssertTrue(app.buttons["siri.route-name.save"].isHittable)
        attach("siri-route-name-largest-text", in: app)
    }

    @MainActor
    private func launch(resetJourneys: Bool, largestText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["APP_STORE_SCREENSHOTS"] = "1"
        app.launchEnvironment["API_BASE"] = "http://127.0.0.1:1/api/v2"
        if resetJourneys { app.launchEnvironment["UI_TEST_RESET_JOURNEYS"] = "1" }
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        if largestText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        } else {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        }
        app.launch()
        return app
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 15))
        let profile = app.buttons["Profile"].firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        let siriSettings = app.buttons["profile.siri-shortcuts"]
        XCTAssertTrue(siriSettings.waitForExistence(timeout: 5))
        siriSettings.tap()
        XCTAssertTrue(app.navigationBars["Siri & Shortcuts"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<8 where !element.isHittable {
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
    }

    @MainActor
    private func attach(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func attachAccessibilityTree(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
