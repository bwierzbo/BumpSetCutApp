//
//  NoRallyProcessingTests.swift
//  BumpSetCutUITests
//
//  Tests the "no rallies detected" flow using norallies.mov (~11MB, ~10s processing).
//  Dashboard items: 6.4.1, 6.4.2, 6.4.3, 6.5.3, 15.4.2
//

import XCTest

final class NoRallyProcessingTests: VideoTestCase {

    override var testVideoName: String { "norallies" }

    private var processScreen: ProcessScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        processScreen = ProcessScreen(app: app)

        // Navigate to library and open processing screen
        navigateToLibrary()
        tapFirstVideoCard()

        let title = app.staticTexts["Rally Detection"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), "Rally Detection title should appear")
    }

    // MARK: - No Rallies Flow

    /// 6.4.1, 6.5.3, 15.4.2 — "No Rallies Detected" message appears after processing
    func testNoRalliesMessageShown() {
        processScreen.startButton.tap()

        let noRalliesText = app.staticTexts["No Rallies Detected"]
        XCTAssertTrue(
            noRalliesText.waitForExistence(timeout: 120),
            "Should show 'No Rallies Detected' after processing a video with no volleyball"
        )
    }

    /// 6.4.2 — Tips are visible when no rallies detected
    func testNoRalliesTipsVisible() {
        processScreen.startButton.tap()

        let noRalliesText = app.staticTexts["No Rallies Detected"]
        XCTAssertTrue(noRalliesText.waitForExistence(timeout: 120))

        let tipsHeader = app.staticTexts["For best results with a different video:"]
        XCTAssertTrue(tipsHeader.exists, "Tips header should be visible when no rallies detected")
    }

    /// 6.4.3 — "Back to Library" button returns to library
    func testBackToLibraryButton() {
        processScreen.startButton.tap()

        let noRalliesText = app.staticTexts["No Rallies Detected"]
        XCTAssertTrue(noRalliesText.waitForExistence(timeout: 120))

        let backButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Back to Library'")
        ).firstMatch
        XCTAssertTrue(backButton.exists, "Back to Library button should exist")
        backButton.tap()

        // Should return to home or library view
        let homeExists = app.descendants(matching: .any)["home.viewLibrary"].firstMatch.waitForExistence(timeout: 5)
        let libraryExists = app.staticTexts["Test Rally Video"].waitForExistence(timeout: 5)
        XCTAssertTrue(homeExists || libraryExists, "Should navigate back to home or library")
    }
}
