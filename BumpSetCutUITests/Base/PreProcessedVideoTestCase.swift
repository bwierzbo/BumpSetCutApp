//
//  PreProcessedVideoTestCase.swift
//  BumpSetCutUITests
//
//  Base class for UI tests that require a pre-processed video with metadata.
//  Injects both a video and its metadata JSON so the app sees rallies immediately
//  without running ML processing. This cuts test setUp from ~120s to ~5s.
//

import XCTest

class PreProcessedVideoTestCase: BSCUITestCase {

    /// Override in subclasses to use a different test video.
    var testVideoName: String { "short" }

    /// Override in subclasses to use different metadata.
    var testMetadataName: String { "short_metadata" }

    override func setUpWithError() throws {
        continueAfterFailure = false

        let bundle = Bundle(for: type(of: self))

        guard let videoURL = bundle.url(forResource: testVideoName, withExtension: "mov") else {
            XCTFail("\(testVideoName).mov not found in test bundle.")
            return
        }

        guard let metadataURL = bundle.url(forResource: testMetadataName, withExtension: "json") else {
            XCTFail("\(testMetadataName).json not found in test bundle.")
            return
        }

        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--skip-onboarding", "--clear-library"]
        app.launchEnvironment["TEST_VIDEO_PATH"] = videoURL.path
        app.launchEnvironment["TEST_METADATA_PATH"] = metadataURL.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Navigation Helpers

    /// Navigate to library, tap the pre-processed video, then open the rally player.
    func openRallyPlayer() {
        let homeScreen = HomeScreen(app: app)
        if homeScreen.viewLibraryButton.waitForExistence(timeout: 5) {
            homeScreen.viewLibraryButton.tap()
        }

        // Tap the "Process with AI" button to open ProcessVideoView
        let processButton = app.buttons["Process with AI"]
        XCTAssertTrue(processButton.waitForExistence(timeout: 5), "Process with AI button not found")
        processButton.tap()

        // Since metadata is injected, the view should show "Rallies Detected!" state
        // with a "View Rallies" button
        let viewRalliesButton = app.buttons["process.viewRallies"]
        XCTAssertTrue(
            viewRalliesButton.waitForExistence(timeout: 10),
            "View Rallies button should appear for pre-processed video"
        )
        viewRalliesButton.tap()

        // Wait for rally player to load
        let rallyPlayer = RallyPlayerScreen(app: app)
        XCTAssertTrue(
            rallyPlayer.rallyCounter.waitForExistence(timeout: 10),
            "Rally player counter should appear"
        )
    }
}
