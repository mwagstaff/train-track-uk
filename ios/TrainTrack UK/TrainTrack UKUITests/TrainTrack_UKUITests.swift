//
//  TrainTrack_UKUITests.swift
//  TrainTrack UKUITests
//
//  Created by Mike Wagstaff on 04/11/2025.
//

import XCTest

final class TrainTrack_UKUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testTopLevelScreensCanBeSwipedAndSelectedFromTheTabBar() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.tabBars.count, 1)
        XCTAssertEqual(app.tabBars.buttons.count, 5)
        XCTAssertTrue(app.tabBars.buttons["Add Journey"].exists)

        app.swipeLeft()

        XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.tabBars.buttons["My Journeys"].isSelected)

        app.swipeRight()

        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.tabBars.buttons["Favourites"].isSelected)

        app.tabBars.buttons["Profile"].tap()

        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.tabBars.buttons["Profile"].isSelected)
    }

    @MainActor
    func testRepeatedTopLevelSwipesKeepNavigationStable() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))

        let swipeHeights: [CGFloat] = [0.28, 0.48, 0.68, 0.38]
        for height in swipeHeights {
            horizontalSwipe(in: app, from: 0.82, to: 0.18, at: height)
            XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 2))

            horizontalSwipe(in: app, from: 0.18, to: 0.82, at: height)
            XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 2))
        }

        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(app.tabBars.count, 1)
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.tabBars.buttons["Favourites"].isSelected)
    }

    @MainActor
    func testBackgroundPhotoCanBeClosedWithLeftOrDownSwipe() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))
        horizontalSwipe(in: app, from: 0.18, to: 0.82, at: 0.5)

        let closePhotoButton = app.buttons["Close photo"]
        XCTAssertTrue(closePhotoButton.waitForExistence(timeout: 2))

        app.swipeLeft()

        XCTAssertTrue(closePhotoButton.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.tabBars.buttons["Favourites"].isSelected)

        app.buttons["View background photo"].tap()
        XCTAssertTrue(closePhotoButton.waitForExistence(timeout: 2))

        app.swipeDown()

        XCTAssertTrue(closePhotoButton.waitForNonExistence(timeout: 2))
        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 2))
    }

    @MainActor
    func testAddJourneyTabShowsDependentJourneyOptions() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Add Journey"].tap()

        XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 2))

        let startNow = app.switches["Start journey now"]
        let schedule = app.switches["Schedule journey"]
        let oneOff = app.switches["Don't save, this is a one-off"]
        XCTAssertTrue(startNow.waitForExistence(timeout: 2))
        XCTAssertTrue(schedule.exists)
        XCTAssertTrue(oneOff.exists)
        XCTAssertFalse(oneOff.isEnabled)

        app.swipeUp()
        startNow.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(
            for: NSPredicate(format: "isEnabled == true"),
            evaluatedWith: oneOff
        )
        waitForExpectations(timeout: 2)

        oneOff.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let disabled = NSPredicate(format: "isEnabled == false")
        expectation(for: disabled, evaluatedWith: schedule)
        expectation(for: disabled, evaluatedWith: app.switches["Mark as favourite"])
        waitForExpectations(timeout: 2)
        XCTAssertTrue(app.buttons["Start one-off journey"].exists)
    }

    private func horizontalSwipe(
        in app: XCUIApplication,
        from startX: CGFloat,
        to endX: CGFloat,
        at y: CGFloat
    ) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: y))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: endX, dy: y))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    func testCancellingStandaloneAddJourneyReturnsToMyJourneys() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))

        app.swipeLeft()

        XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.keyboards.firstMatch.exists)

        app.buttons["toolbar.add-journey"].tap()

        XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)

        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 2))
    }

    @MainActor
    func testSavingJourneyReturnsToMyJourneysWithoutCrashing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["UI_TEST_RESET_JOURNEYS"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 5))

        app.buttons["toolbar.add-journey"].tap()

        XCTAssertTrue(app.navigationBars["Add Journey"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.tabBars.firstMatch.isHittable)

        let fromField = app.textFields["add-journey.from"]
        XCTAssertTrue(fromField.waitForExistence(timeout: 2))

        fromField.tap()
        fromField.typeText("cambridge")

        XCTAssertTrue(app.staticTexts["Cambridge South"].waitForExistence(timeout: 5))

        let fromSuggestion = app.staticTexts["Cambridge"]
        XCTAssertTrue(fromSuggestion.waitForExistence(timeout: 5))
        fromSuggestion.tap()

        let destinationField = app.textFields["add-journey.destination"]
        XCTAssertTrue(destinationField.waitForExistence(timeout: 5))
        destinationField.tap()
        destinationField.typeText("ECR")

        let destinationSuggestion = app.staticTexts["East Croydon"]
        XCTAssertTrue(destinationSuggestion.waitForExistence(timeout: 5))
        destinationSuggestion.tap()

        app.swipeUp()

        let saveButton = app.buttons["Save"]
        let saveEnabled = NSPredicate(format: "isEnabled == true")
        expectation(for: saveEnabled, evaluatedWith: saveButton)
        waitForExpectations(timeout: 5)
        saveButton.tap()

        XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    @MainActor
    func testAppStoreScreenshots() throws {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchEnvironment["APP_STORE_SCREENSHOTS"] = "1"
        app.launchEnvironment["UI_TEST_RESET_JOURNEYS"] = "1"
        app.launchEnvironment["UI_TEST_RESET_HISTORY"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_GB",
            "-journeySortMode", "alphabetical",
            "-showClosestJourneyLegOnly", "NO"
        ]
        app.launch()

        XCTAssertTrue(app.navigationBars["Favourites"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Kent House → London Victoria"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["East Croydon → Brighton"].waitForExistence(timeout: 10))
        capture("01-favourites", in: app)

        tapTab("My Journeys", in: app)
        XCTAssertTrue(app.navigationBars["My Journeys"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Edinburgh Waverley → Glasgow Queen Street"].waitForExistence(timeout: 10))
        capture("02-my-journeys-top", in: app)

        let finalJourney = app.staticTexts["Manchester Piccadilly → Leeds"]
        scrollToVisible(finalJourney, in: app)
        XCTAssertTrue(finalJourney.exists)
        capture("03-my-journeys-lower", in: app)

        tapTab("History", in: app)
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 10))
        app.buttons["Journey history actions"].tap()
        app.buttons["Generate test history to 2,000"].tap()

        let historyAlert = app.alerts["Test journey history"]
        XCTAssertTrue(historyAlert.waitForExistence(timeout: 120))
        historyAlert.buttons["OK"].tap()

        app.buttons["Filter journey history"].tap()
        let delayRepayToggle = app.descendants(matching: .any)
            .matching(identifier: "Delay Repay eligible only")
            .firstMatch
        XCTAssertTrue(delayRepayToggle.waitForExistence(timeout: 10))
        delayRepayToggle.tap()

        let claimButton = app.buttons["Claim Delay Repay"].firstMatch
        XCTAssertTrue(claimButton.waitForExistence(timeout: 15))
        capture("04-history-delay-repay", in: app)

        app.buttons["Delay Repay claim options"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Mark claim as successful"].waitForExistence(timeout: 10))
        capture("05-delay-repay-options", in: app)
        app.buttons["Mark claim as successful"].tap()

        let eligibleJourney = app.staticTexts["London Kings Cross → Finsbury Park"]
        XCTAssertTrue(eligibleJourney.waitForExistence(timeout: 15))
        eligibleJourney.tap()
        XCTAssertTrue(app.navigationBars["London Kings Cross → Finsbury Park"].waitForExistence(timeout: 15))
        capture("06-history-detail", in: app)

        let routeMapLink = app.descendants(matching: .any)
            .matching(identifier: "View Route Map")
            .firstMatch
        XCTAssertTrue(routeMapLink.waitForExistence(timeout: 10))
        routeMapLink.tap()
        XCTAssertTrue(app.maps.firstMatch.waitForExistence(timeout: 60))
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        capture("07-route-map", in: app)
    }

    private func tapTab(_ label: String, in app: XCUIApplication) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
    }

    private func scrollToVisible(_ element: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !element.isHittable && attempts < 6 {
            app.swipeUp()
            attempts += 1
        }
    }

    private func capture(_ name: String, in app: XCUIApplication) {
        XCTAssertEqual(app.state, .runningForeground)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
