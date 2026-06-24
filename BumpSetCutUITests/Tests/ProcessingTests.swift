//
//  ProcessingTests.swift
//  BumpSetCutUITests
//
//  Test Plan §6, §7 — Processing flow: ready state, start, cancel, complete, save.
//

import XCTest

final class ProcessingTests: VideoTestCase {

    private var processScreen: ProcessScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        processScreen = ProcessScreen(app: app)

        // Navigate to the processing screen
        navigateToLibrary()
        tapFirstVideoCard()

        // Wait for processing screen to load
        XCTAssertTrue(processScreen.startButton.waitForExistence(timeout: 10),
                       "Processing screen should show start button")
    }

    func testReadyStateShown() {
        let readyText = app.staticTexts["Ready to Process"]
        XCTAssertTrue(readyText.waitForExistence(timeout: 3), "'Ready to Process' should be visible")
        XCTAssertTrue(processScreen.startButton.waitForExistence(timeout: 3), "'Start AI Processing' button should be visible")
    }

    func testStartShowsProgress() {
        processScreen.startButton.tap()

        let analyzingText = app.staticTexts["Analyzing video..."]
        XCTAssertTrue(analyzingText.waitForExistence(timeout: 10), "'Analyzing video...' should appear after starting")
    }

    func testCancelProcessing() {
        processScreen.startButton.tap()

        // Wait for processing to start
        let analyzingText = app.staticTexts["Analyzing video..."]
        XCTAssertTrue(analyzingText.waitForExistence(timeout: 10))

        // Cancel
        processScreen.cancelButton.tap()

        // Should return (dismiss). Verify by checking we're back at library or home.
        let libraryExists = app.staticTexts["Test Rally Video"].waitForExistence(timeout: 5)
        let homeExists = app.descendants(matching: .any)["home.viewLibrary"].firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(libraryExists || homeExists, "Should navigate back after cancelling")
    }

    /// This test runs real ML inference and may take 60-180 seconds.
    func testProcessingCompletes() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)
    }

    /// This test runs real ML inference. Processing now auto-saves into the original
    /// video's folder — there is no destination prompt — and lands on the stats screen.
    func testAutoSaveAfterProcessing() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)

        // No "Save to Library" step — the stats screen with "View Rallies" appears directly.
        XCTAssertTrue(
            processScreen.viewRalliesButton.waitForExistence(timeout: 10),
            "'View Rallies' should appear after auto-save"
        )
        XCTAssertFalse(
            app.buttons["Save to Library"].exists,
            "No 'Save to Library' button should appear — saving is automatic"
        )
    }

    // MARK: - Additional Processing Tests

    func testProgressBarAppears() {
        processScreen.startButton.tap()

        // Progress indicator should appear during processing
        let progressView = app.progressIndicators.firstMatch
        let analyzingText = app.staticTexts["Analyzing video..."]
        let hasProgress = progressView.waitForExistence(timeout: 10) || analyzingText.waitForExistence(timeout: 10)
        XCTAssertTrue(hasProgress, "Progress indicator or analyzing text should appear after starting")
    }

    func testProcessingShowsRallyCount() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)

        // After completion, rally count text should appear (e.g., "3 Rallies")
        let ralliesText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Rall'")).firstMatch
        XCTAssertTrue(ralliesText.waitForExistence(timeout: 5), "Rally count should be displayed after processing")
    }

    func testViewRalliesOpensPlayer() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)

        // Processing auto-saves and lands on the stats screen with "View Rallies".
        XCTAssertTrue(
            processScreen.viewRalliesButton.waitForExistence(timeout: 10),
            "'View Rallies' button should appear after auto-save"
        )
        processScreen.viewRalliesButton.tap()

        // The rally player should open.
        let rallyPlayer = RallyPlayerScreen(app: app)
        XCTAssertTrue(rallyPlayer.rallyCounter.waitForExistence(timeout: 15), "Rally player should open from 'View Rallies'")
        rallyPlayer.backButton.tap()

        // Back on the stats screen — "View Rallies" remains visible.
        XCTAssertTrue(
            processScreen.viewRalliesButton.waitForExistence(timeout: 5),
            "'View Rallies' button should still be visible after dismissing the player"
        )
    }

    func testDoneButtonDismisses() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)

        // Processing auto-saves and lands on the stats screen with a "Done" button.
        XCTAssertTrue(processScreen.doneButton.waitForExistence(timeout: 10), "'Done' button should appear after auto-save")
        processScreen.doneButton.tap()

        // Should dismiss back to library or home
        let libraryExists = app.staticTexts["Test Rally Video"].waitForExistence(timeout: 5)
        let homeExists = app.descendants(matching: .any)["home.viewLibrary"].firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(libraryExists || homeExists, "Should navigate back after tapping Done")
    }

    func testReprocessingBlocked() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)

        // Processing auto-saves and lands on the stats screen.
        // "View Rallies" should be visible, NOT the start button.
        XCTAssertTrue(
            processScreen.viewRalliesButton.waitForExistence(timeout: 10),
            "'View Rallies' should appear instead of Start for processed video"
        )
        // Start button should NOT appear for already-processed video
        XCTAssertFalse(processScreen.startButton.exists, "Start button should not appear for already-processed video")
    }
}
