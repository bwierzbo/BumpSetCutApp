//
//  VideoTestCase.swift
//  BumpSetCutUITests
//
//  Base class for UI tests that require a test video injected into the app.
//  NOTE: Video injection uses shared filesystem — runs on Simulator only.
//

import XCTest

class VideoTestCase: BSCUITestCase {

    /// Override in subclasses to use a different test video.
    var testVideoName: String { "short" }

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Get the test video URL from the test bundle (no copy needed on simulator)
        let bundle = Bundle(for: type(of: self))
        guard let videoURL = bundle.url(forResource: testVideoName, withExtension: "mov") else {
            XCTFail("\(testVideoName).mov not found in test bundle. Ensure it has Target Membership for BumpSetCutUITests.")
            return
        }

        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--skip-onboarding", "--clear-library"]
        app.launchEnvironment["TEST_VIDEO_PATH"] = videoURL.path
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Navigation Helpers

    /// Navigate to the Library tab from any screen.
    func navigateToLibrary() {
        let homeScreen = HomeScreen(app: app)
        // Tap library button from home
        if homeScreen.viewLibraryButton.waitForExistence(timeout: 5) {
            homeScreen.viewLibraryButton.tap()
        }
    }

    /// Tap the "Process with AI" brain icon on the first video card to open the processing screen.
    func tapFirstVideoCard() {
        let processButton = app.buttons["Process with AI"]
        XCTAssertTrue(processButton.waitForExistence(timeout: 5), "Process with AI button not found on video card")
        processButton.tap()
    }

    /// Wait for processing to complete (shows "Processing Complete!").
    func waitForProcessingComplete(timeout: TimeInterval = 180) {
        let completeText = app.staticTexts["Processing Complete!"]
        XCTAssertTrue(
            completeText.waitForExistence(timeout: timeout),
            "Processing did not complete within \(timeout)s"
        )
    }
}
