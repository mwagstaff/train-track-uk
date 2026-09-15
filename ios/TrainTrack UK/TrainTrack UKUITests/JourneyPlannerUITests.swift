import XCTest

final class JourneyPlannerUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testUnavailablePlannerKeepsSavedRouteAndFavouritePrefill() throws {
        let app = launch(plannerEnabled: true)
        let favouriteEntry = app.buttons["Add favourite journey"]
        XCTAssertTrue(favouriteEntry.waitForExistence(timeout: 5))
        favouriteEntry.tap()
        XCTAssertTrue(app.navigationBars["Find journeys"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Scheduled times only"].exists)
        XCTAssertFalse(app.buttons["planner.search"].isEnabled)
        let savedRoute = app.buttons["planner.saved-route"]
        scrollTo(savedRoute, in: app)
        XCTAssertTrue(savedRoute.exists)
        var accessibilityIssues: [String] = []
        try app.performAccessibilityAudit(for: [.contrast, .textClipped, .hitRegion]) { issue in
            // Native disabled controls are exempt from contrast requirements.
            if issue.auditType == .contrast && issue.element?.isEnabled == false { return true }
            accessibilityIssues.append("\(issue.compactDescription): \(issue.element?.label ?? "Unknown element")")
            return true
        }
        XCTAssertTrue(accessibilityIssues.isEmpty, accessibilityIssues.joined(separator: "\n"))
        attach("planner-unavailable", app: app)
        savedRoute.tap()
        XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["add-journey.from"].exists)
        XCTAssertTrue(app.textFields["add-journey.destination"].exists)
        app.swipeUp()
        XCTAssertTrue(app.buttons["Add intermediate stop"].exists)
        let favourite = app.switches["Mark as favourite"]
        scrollTo(favourite, in: app)
        XCTAssertEqual(favourite.value as? String, "1")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDisabledPlannerPreservesOriginalAddJourney() throws {
        let app = launch(plannerEnabled: false)
        openAddJourney(in: app)
        XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["add-journey.from"].exists)
        XCTAssertFalse(app.navigationBars["Find journeys"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testPlannerLargestDynamicTypeLayout() throws {
        let app = launch(plannerEnabled: true, largeText: true)
        openAddJourney(in: app)
        XCTAssertTrue(app.navigationBars["Find journeys"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["planner.origin"].isHittable)
        XCTAssertTrue(app.buttons["planner.destination"].isHittable)
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
        attach("planner-large-text", app: app)
        scrollTo(app.buttons["planner.saved-route"], in: app)
        XCTAssertTrue(app.buttons["planner.saved-route"].isHittable)
        attach("planner-large-text-saved-route", app: app)
    }

    @MainActor
    func testEmptyWindowExplainsScopeAndCanSearchEarlierAndLaterAtLargestTextSize() async throws {
        let app = try await launchEmptyWindowAtLargestTextSize()
        let interval = app.staticTexts["planner.empty.interval"]
        scrollTo(interval, in: app)
        XCTAssertTrue(interval.label.hasPrefix("Departures searched:"))
        let originalInterval = interval.label
        XCTAssertEqual(app.staticTexts["planner.empty.change-limit"].label, "Up to 5 changes.")
        attach("planner-empty-window-context", app: app)
        let earlier = app.buttons["planner.empty.earlier"]
        let later = app.buttons["planner.empty.later"]
        scrollTo(earlier, in: app)
        XCTAssertTrue(earlier.isHittable)
        XCTAssertTrue(later.isHittable)
        attach("planner-empty-window-large-text", app: app)
        earlier.tap()
        scrollTo(interval, in: app, towardTop: true)
        let earlierLoaded = expectation(for: NSPredicate(format: "label != %@", originalInterval), evaluatedWith: interval)
        await fulfillment(of: [earlierLoaded], timeout: 10)
        XCTAssertTrue(interval.label.hasPrefix("Departures searched:"))
        scrollTo(later, in: app)
        later.tap()
        scrollTo(interval, in: app, towardTop: true)
        let originalLoaded = expectation(for: NSPredicate(format: "label == %@", originalInterval), evaluatedWith: interval)
        await fulfillment(of: [originalLoaded], timeout: 10)
        scrollTo(later, in: app)
        later.tap()
        let journey = app.buttons["planner.journey.fixture-later-journey"]
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["planner.empty.later"].exists)
    }

    @MainActor
    func testEmptyWindowAccessibilityAtLargestTextSize() async throws {
        let app = try await launchEmptyWindowAtLargestTextSize()
        let earlier = app.buttons["planner.empty.earlier"]
        scrollTo(earlier, in: app)
        XCTAssertTrue(earlier.isHittable)
        XCTAssertTrue(app.buttons["planner.empty.later"].isHittable)
        attach("planner-empty-window-accessibility", app: app)
        // Keep the audit isolated: its scan can invalidate the iOS 26 collection snapshot.
        try app.performAccessibilityAudit(for: [.textClipped, .hitRegion])
    }

    @MainActor
    func testLocalPlannerSearchResultsDetailsAndRecentSearch() async throws {
        let base = ProcessInfo.processInfo.environment["PLANNER_INTEGRATION_API_BASE"] ?? "http://127.0.0.1:3013/api/v2"
        let statusURL = URL(string: base.replacingOccurrences(of: "/api/v2", with: "/api/v3/journey-planner/status"))!
        var request = URLRequest(url: statusURL)
        request.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Start the local planner server to run the integration UI test.")
        }
        let app = launch(plannerEnabled: true, apiBase: base)
        openAddJourney(in: app)
        selectStations(origin: "KTH", destination: "VIC", in: app)
        let search = app.buttons["planner.search"]
        scrollTo(search, in: app)
        XCTAssertTrue(search.isEnabled)
        search.tap()
        guard app.navigationBars["Journeys"].waitForExistence(timeout: 35) else { XCTFail("Planner search did not open results"); return }
        let journey = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'planner.journey.'")).firstMatch
        XCTAssertTrue(journey.waitForExistence(timeout: 10))
        attach("planner-results", app: app)
        journey.tap()
        XCTAssertTrue(app.navigationBars["Journey details"].waitForExistence(timeout: 10))
        let points = app.buttons["Calling points"]
        XCTAssertTrue(points.waitForExistence(timeout: 15))
        points.tap()
        XCTAssertTrue(app.staticTexts["Penge East"].waitForExistence(timeout: 5))
        attach("planner-details", app: app)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let later = app.buttons["Later journeys"]
        scrollTo(later, in: app)
        XCTAssertTrue(later.exists)
        later.tap()
        XCTAssertTrue(app.navigationBars["Journeys"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Find journeys"].waitForExistence(timeout: 5))
        let recent = app.buttons.containing(.staticText, identifier: "Kent House → London Victoria").firstMatch
        scrollTo(recent, in: app)
        XCTAssertTrue(recent.exists)
        recent.tap()
        XCTAssertTrue(app.navigationBars["Find journeys"].exists)
    }

    @MainActor
    private func launchEmptyWindowAtLargestTextSize() async throws -> XCUIApplication {
        // Start journey_planner_ui_fixture.py to run this deterministic HTTP scenario.
        let base = ProcessInfo.processInfo.environment["PLANNER_EMPTY_WINDOW_API_BASE"] ?? "http://127.0.0.1:3014/api/v2"
        var statusRequest = URLRequest(url: URL(string: base.replacingOccurrences(of: "/api/v2", with: "/api/v3/journey-planner/status"))!)
        statusRequest.timeoutInterval = 2
        guard let (_, response) = try? await URLSession.shared.data(for: statusRequest),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw XCTSkip("Start journey_planner_ui_fixture.py to run the empty-window UI test.")
        }
        let app = launch(plannerEnabled: true, largeText: true, apiBase: base)
        openAddJourney(in: app)
        selectStations(origin: "KTH", destination: "INV", in: app)
        scrollTo(app.buttons["planner.search"], in: app)
        app.buttons["planner.search"].tap()
        XCTAssertTrue(app.navigationBars["Journeys"].waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func launch(plannerEnabled: Bool, largeText: Bool = false, apiBase: String = "http://127.0.0.1:1/api/v2") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["JOURNEY_PLANNER_ENABLED"] = plannerEnabled ? "1" : "0"
        app.launchEnvironment["API_BASE"] = apiBase
        app.launchEnvironment["UI_TEST_RESET_JOURNEYS"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_GB"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func selectStations(origin: String, destination: String, in app: XCUIApplication) {
        for (field, code) in [("origin", origin), ("destination", destination)] {
            let stationField = app.buttons["planner.\(field)"]
            scrollTo(stationField, in: app)
            stationField.tap()
            let search = app.searchFields.firstMatch
            guard search.waitForExistence(timeout: 5) else { XCTFail("Station search field is unavailable"); return }
            search.tap()
            search.typeText(code)
            let station = app.buttons["planner.station.\(code)"]
            guard station.waitForExistence(timeout: 10) else { XCTFail("Station suggestion is unavailable"); return }
            station.tap()
        }
    }

    @MainActor private func openAddJourney(in app: XCUIApplication) {
        let add = app.buttons["toolbar.add-journey"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
    }

    @MainActor private func scrollTo(_ element: XCUIElement, in app: XCUIApplication, towardTop: Bool = false) {
        for _ in 0..<8 where !element.isHittable {
            if towardTop { app.swipeDown() } else { app.swipeUp() }
        }
    }

    @MainActor private func attach(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
