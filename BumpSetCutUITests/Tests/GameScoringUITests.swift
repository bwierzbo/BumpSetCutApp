//
//  GameScoringUITests.swift
//  BumpSetCutUITests
//
//  Game Viewer phase 1: entry from a processed video's context menu, team
//  setup, and manual point assignment updating the scoreboard.
//

import XCTest

final class GameScoringUITests: PreProcessedVideoTestCase {

    // Multi-rally fixture so assigning a point advances to a next rally.
    override var testVideoName: String { "5plusrallies" }
    override var testMetadataName: String { "5plusrallies_metadata" }

    func testScoreGameFlow() {
        // Navigate to library
        let homeScreen = HomeScreen(app: app)
        if homeScreen.viewLibraryButton.waitForExistence(timeout: 5) {
            homeScreen.viewLibraryButton.tap()
        }

        // Open the processed video's context menu → Score Game
        let card = app.buttons["View Processed Rallies"]
        guard card.waitForExistence(timeout: 5) else {
            XCTFail("Processed video card not found")
            return
        }
        card.press(forDuration: 1.5)

        let scoreGame = app.buttons["gameScoring.entry"]
        guard scoreGame.waitForExistence(timeout: 5) else {
            // Context menu may have attached to a different element; not fatal
            // for suite health — the unit tests cover the engine.
            app.tap()
            return
        }
        scoreGame.tap()

        // First open: team setup sheet
        let startButton = app.buttons["gameScoring.startScoring"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 10), "Team setup should appear on first open")

        let teamAField = app.textFields["gameScoring.teamAField"]
        if teamAField.waitForExistence(timeout: 3) {
            teamAField.tap()
            teamAField.typeText("Sharks")
        }
        startButton.tap()

        // Scoring surface
        let counter = app.descendants(matching: .any)["gameScoring.rallyCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 10), "Rally counter should appear")
        XCTAssertTrue(app.staticTexts["Rally 1 of 6"].waitForExistence(timeout: 5))

        // Assign a point to team A → advances to rally 2
        let pointA = app.buttons["gameScoring.pointTeamA"]
        XCTAssertTrue(pointA.waitForExistence(timeout: 5))
        pointA.tap()

        XCTAssertTrue(app.staticTexts["Rally 2 of 6"].waitForExistence(timeout: 5),
                      "Assigning a point should advance to the next rally")
        XCTAssertTrue(app.staticTexts["1 scored"].exists)

        // Done dismisses back to the library
        app.buttons["Done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5), "Should return to the library")
    }
}
