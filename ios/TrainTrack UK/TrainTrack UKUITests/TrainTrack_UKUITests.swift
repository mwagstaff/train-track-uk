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
        XCTAssertEqual(app.tabBars.buttons.count, 4)
        XCTAssertFalse(app.tabBars.buttons["Add Journey"].exists)

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
}
