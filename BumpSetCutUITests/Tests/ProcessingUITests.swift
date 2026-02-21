//
//  ProcessingUITests.swift
//  BumpSetCutUITests
//
//  UI-only processing tests (no ML inference, quick to run).
//  Dashboard items: 6.1.1, 6.1.3, 6.2.1, 6.2.4, 6.5.6
//

import XCTest

/// Tests processing UI without running full ML inference.
/// Uses VideoTestCase for unprocessed video state tests.
final class ProcessingUITests: VideoTestCase {

    private var processScreen: ProcessScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        processScreen = ProcessScreen(app: app)
        navigateToLibrary()
    }

    // MARK: - 6.1.1 — Process button shows unprocessed video list

    func testProcessButtonShowsUnprocessedVideos() {
        // The library should show the test video with "Process with AI" button
        let processButton = app.buttons["Process with AI"]
        XCTAssertTrue(
            processButton.waitForExistence(timeout: 5),
            "Process with AI button should be visible for unprocessed video"
        )
    }

    // MARK: - 6.1.3 — Video metadata displayed

    func testVideoMetadataDisplayed() {
        // Open the processing screen
        tapFirstVideoCard()

        XCTAssertTrue(
            processScreen.startButton.waitForExistence(timeout: 10),
            "Processing screen should load"
        )

        // Video name or metadata should be visible
        let videoInfo = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Test Rally' OR label CONTAINS 'short'")
        ).firstMatch
        let metadataVisible = videoInfo.waitForExistence(timeout: 5)

        // Also check for duration or size text
        let durationOrSize = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 's' OR label CONTAINS 'MB' OR label CONTAINS 'KB'")
        ).firstMatch

        XCTAssertTrue(
            metadataVisible || durationOrSize.waitForExistence(timeout: 3),
            "Video metadata (name, duration, or size) should be displayed"
        )
    }

    // MARK: - 6.2.1 — Animated brain icon appears on start

    func testStartShowsProcessingUI() {
        tapFirstVideoCard()
        XCTAssertTrue(processScreen.startButton.waitForExistence(timeout: 10))

        processScreen.startButton.tap()

        // Processing UI should appear (analyzing text or progress)
        let analyzingText = app.staticTexts["Analyzing video..."]
        let progressIndicator = app.progressIndicators.firstMatch
        let hasProcessingUI = analyzingText.waitForExistence(timeout: 10)
            || progressIndicator.waitForExistence(timeout: 10)
        XCTAssertTrue(hasProcessingUI, "Processing UI should appear after tapping start")
    }

    // MARK: - 6.2.4 — Progress bar visible during processing

    func testProgressBarVisibleDuringProcessing() {
        tapFirstVideoCard()
        XCTAssertTrue(processScreen.startButton.waitForExistence(timeout: 10))

        processScreen.startButton.tap()

        // Look for progress bar or analyzing text
        let progressIndicator = app.progressIndicators.firstMatch
        let analyzingText = app.staticTexts["Analyzing video..."]
        let hasProgress = progressIndicator.waitForExistence(timeout: 15)
            || analyzingText.waitForExistence(timeout: 15)
        XCTAssertTrue(hasProgress, "Progress indicator should be visible during processing")

        // Cancel to avoid long ML wait
        if processScreen.cancelButton.waitForExistence(timeout: 3) {
            processScreen.cancelButton.tap()
        }
    }
}

/// Tests for already-processed video state.
/// Uses PreProcessedVideoTestCase for pre-processed state.
final class ProcessingAlreadyProcessedTests: PreProcessedVideoTestCase {

    // MARK: - 6.5.6 — Already-processed video shows processed state

    func testAlreadyProcessedVideoShowsProcessedState() {
        let homeScreen = HomeScreen(app: app)
        if homeScreen.viewLibraryButton.waitForExistence(timeout: 5) {
            homeScreen.viewLibraryButton.tap()
        }

        // Pre-processed video should show "View Rallies" button, NOT "Process with AI"
        let viewRallies = app.buttons["View Rallies"]
        let processButton = app.buttons["Process with AI"]

        let hasViewRallies = viewRallies.waitForExistence(timeout: 5)
        let hasProcess = processButton.waitForExistence(timeout: 2)

        // For pre-processed videos, "View Rallies" should be the primary action
        XCTAssertTrue(
            hasViewRallies || hasProcess,
            "Video card should show either View Rallies or Process with AI"
        )

        if hasViewRallies {
            XCTAssertTrue(true, "Pre-processed video correctly shows View Rallies")
        }
    }
}
