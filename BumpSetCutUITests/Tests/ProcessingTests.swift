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
        processScreen.startProcessing()

        let analyzingText = app.staticTexts["Analyzing video..."]
        XCTAssertTrue(analyzingText.waitForExistence(timeout: 10), "'Analyzing video...' should appear after starting")
    }

    func testCancelProcessing() {
        processScreen.startProcessing()

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

    /// This test runs real ML inference and can take several minutes on a simulator.
    func testProcessingCompletes() throws {
        processScreen.startProcessing()
        try waitForProcessingComplete(timeout: 420)
    }

    /// This test runs real ML inference. Processing now auto-saves into the original
    /// video's folder — there is no destination prompt — and lands on the stats screen.
    func testAutoSaveAfterProcessing() throws {
        processScreen.startProcessing()
        try waitForProcessingComplete(timeout: 420)

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
        processScreen.startProcessing()

        // "Analyzing video..." shows immediately and gives way to the progress
        // phase — check it first, then fall back to any progress indicator.
        let analyzingText = app.staticTexts["Analyzing video..."]
        let progressView = app.progressIndicators.firstMatch
        let hasProgress = analyzingText.waitForExistence(timeout: 10) || progressView.waitForExistence(timeout: 10)
        XCTAssertTrue(hasProgress, "Progress indicator or analyzing text should appear after starting")
    }

    func testProcessingShowsRallyCount() throws {
        processScreen.startProcessing()
        try waitForProcessingComplete(timeout: 420)

        // After completion, rally count text should appear (e.g., "3 Rallies")
        let ralliesText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Rall'")).firstMatch
        XCTAssertTrue(ralliesText.waitForExistence(timeout: 5), "Rally count should be displayed after processing")
    }

    func testViewRalliesOpensPlayer() throws {
        processScreen.startProcessing()
        try waitForProcessingComplete(timeout: 420)

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

    func testDoneButtonDismisses() throws {
        processScreen.startProcessing()
        try waitForProcessingComplete(timeout: 420)

        // Processing auto-saves and lands on the stats screen with a "Done" button.
        XCTAssertTrue(processScreen.doneButton.waitForExistence(timeout: 10), "'Done' button should appear after auto-save")
        processScreen.doneButton.tap()

        // Should dismiss back to library or home
        let libraryExists = app.staticTexts["Test Rally Video"].waitForExistence(timeout: 5)
        let homeExists = app.descendants(matching: .any)["home.viewLibrary"].firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(libraryExists || homeExists, "Should navigate back after tapping Done")
    }

    func testReprocessingBlocked() throws {
        processScreen.startProcessing()
        try waitForProcessingComplete(timeout: 420)

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
