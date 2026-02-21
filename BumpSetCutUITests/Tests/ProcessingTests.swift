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
        let title = app.staticTexts["Rally Detection"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
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
        let homeExists = app.descendants(matching: .any)["home.viewLibrary"].waitForExistence(timeout: 5)
        XCTAssertTrue(libraryExists || homeExists, "Should navigate back after cancelling")
    }

    /// This test runs real ML inference and may take 60-180 seconds.
    func testProcessingCompletes() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)
    }

    /// This test runs real ML inference. After processing, taps "Save to Library".
    func testSaveAfterProcessing() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)

        // Tap "Save to Library"
        XCTAssertTrue(processScreen.saveToLibraryButton.waitForExistence(timeout: 5), "'Save to Library' button should appear")
        processScreen.saveToLibraryButton.tap()

        // Folder picker should appear with "Choose Destination"
        let folderPicker = app.staticTexts["Choose Destination"]
        XCTAssertTrue(folderPicker.waitForExistence(timeout: 5), "Folder picker should appear after tapping Save")
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

    func testViewRalliesButtonAfterSave() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)

        // Save the processed video
        XCTAssertTrue(processScreen.saveToLibraryButton.waitForExistence(timeout: 5))
        processScreen.saveToLibraryButton.tap()

        let saveButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Save to'")).firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        // After save, the app auto-opens the rally player.
        // Dismiss it by tapping the back button.
        let rallyPlayer = RallyPlayerScreen(app: app)
        XCTAssertTrue(rallyPlayer.rallyCounter.waitForExistence(timeout: 15), "Rally player should auto-open after save")
        rallyPlayer.backButton.tap()

        // Now on processing view with .hasMetadata state — "View Rallies" should be visible
        XCTAssertTrue(
            processScreen.viewRalliesButton.waitForExistence(timeout: 5),
            "'View Rallies' button should appear for processed video"
        )
    }

    func testDoneButtonDismisses() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)

        // Save first
        if processScreen.saveToLibraryButton.waitForExistence(timeout: 5) {
            processScreen.saveToLibraryButton.tap()

            let saveButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Save to'")).firstMatch
            if saveButton.waitForExistence(timeout: 3) {
                saveButton.tap()
            }
        }

        // Done button should appear in complete state
        if processScreen.doneButton.waitForExistence(timeout: 5) {
            processScreen.doneButton.tap()

            // Should dismiss back to library or home
            let libraryExists = app.staticTexts["Test Rally Video"].waitForExistence(timeout: 5)
            let homeExists = app.descendants(matching: .any)["home.viewLibrary"].waitForExistence(timeout: 5)
            XCTAssertTrue(libraryExists || homeExists, "Should navigate back after tapping Done")
        }
    }

    func testReprocessingBlocked() {
        processScreen.startButton.tap()
        waitForProcessingComplete(timeout: 180)

        // Save the processed video
        XCTAssertTrue(processScreen.saveToLibraryButton.waitForExistence(timeout: 5))
        processScreen.saveToLibraryButton.tap()

        let saveButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Save to'")).firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        // After save, the app auto-opens the rally player. Dismiss it.
        let rallyPlayer = RallyPlayerScreen(app: app)
        if rallyPlayer.rallyCounter.waitForExistence(timeout: 15) {
            rallyPlayer.backButton.tap()
        }

        // Back on processing view — "View Rallies" should be visible, NOT the start button
        XCTAssertTrue(
            processScreen.viewRalliesButton.waitForExistence(timeout: 5),
            "'View Rallies' should appear instead of Start for processed video"
        )
        // Start button should NOT appear for already-processed video
        XCTAssertFalse(processScreen.startButton.exists, "Start button should not appear for already-processed video")
    }
}
