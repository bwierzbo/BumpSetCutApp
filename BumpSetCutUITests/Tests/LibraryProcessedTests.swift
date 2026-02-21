//
//  LibraryProcessedTests.swift
//  BumpSetCutUITests
//
//  Test Plan §4.6 — Processed library: filter behavior, tap opens rally player.
//  Uses PreProcessedVideoTestCase for instant metadata injection.
//  Dashboard items: 4.6.1, 4.6.2, 4.6.3
//

import XCTest

final class LibraryProcessedTests: PreProcessedVideoTestCase {

    private var library: LibraryScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Navigate to library
        let homeScreen = HomeScreen(app: app)
        if homeScreen.viewLibraryButton.waitForExistence(timeout: 5) {
            homeScreen.viewLibraryButton.tap()
        }

        library = LibraryScreen(app: app)
    }

    // MARK: - Processed Filter (4.6.1, 4.6.3)

    /// 4.6.1 — Processed filter shows processed video
    func testProcessedFilterShowsProcessedVideo() {
        guard library.filterProcessed.waitForExistence(timeout: 5) else {
            XCTFail("Processed filter chip not found — filter chips may not be visible")
            return
        }

        library.filterProcessed.tap()

        // Pre-processed video should appear under Processed filter
        let videoCard = app.staticTexts["Test Rally Video"]
        XCTAssertTrue(videoCard.waitForExistence(timeout: 5),
                       "Pre-processed video should appear under Processed filter")
    }

    /// 4.6.3 — Unprocessed filter hides processed video
    func testUnprocessedFilterHidesProcessedVideo() {
        guard library.filterUnprocessed.waitForExistence(timeout: 5) else {
            XCTFail("Unprocessed filter chip not found — filter chips may not be visible")
            return
        }

        library.filterUnprocessed.tap()

        // Pre-processed video should NOT appear under Unprocessed filter
        let videoCard = app.staticTexts["Test Rally Video"]
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: videoCard)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed,
                       "Pre-processed video should be hidden under Unprocessed filter")
    }

    // MARK: - Tap to Open (4.6.2)

    /// 4.6.2 — Tap processed video opens rally player
    func testTapProcessedVideoOpensRallyPlayer() {
        // Pre-processed video has processedVideoIds set, so card shows "View Rallies"
        let viewRalliesOnCard = app.buttons["View Rallies"]
        XCTAssertTrue(viewRalliesOnCard.waitForExistence(timeout: 5),
                       "'View Rallies' button should appear on processed video card")
        viewRalliesOnCard.tap()

        // Rally player should open
        let rallyPlayer = RallyPlayerScreen(app: app)
        XCTAssertTrue(rallyPlayer.rallyCounter.waitForExistence(timeout: 10),
                       "Tapping processed video should open rally player")
    }
}
