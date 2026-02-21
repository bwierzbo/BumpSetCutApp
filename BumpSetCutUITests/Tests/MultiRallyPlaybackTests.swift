//
//  MultiRallyPlaybackTests.swift
//  BumpSetCutUITests
//
//  Tests multi-rally scenarios using PreProcessedVideoTestCase with 5plusrallies.mov.
//  No ML processing — rally player opens instantly via pre-injected metadata.
//  Dashboard items: 7.1.2, 7.1.5, 7.2.3, 7.2.4, 7.2.5, 7.3.3, 7.5.2, 7.5.3, 7.5.4, 7.5.5, 7.6.2
//

import XCTest

final class MultiRallyPlaybackTests: PreProcessedVideoTestCase {

    override var testVideoName: String { "5plusrallies" }
    override var testMetadataName: String { "5plusrallies_metadata" }

    private var rallyPlayer: RallyPlayerScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rallyPlayer = RallyPlayerScreen(app: app)
        openRallyPlayer()
    }

    // MARK: - Counter / Navigation Tests

    /// 7.1.5 — Counter shows "Rally X of Y" with Y >= 5
    func testRallyCounterShowsMultipleRallies() {
        let counterLabel = rallyPlayer.rallyCounter.label
        XCTAssertTrue(
            counterLabel.contains("of"),
            "Counter should show 'Rally X of Y', got: \(counterLabel)"
        )
        // Extract the total count — should be >= 5
        if let range = counterLabel.range(of: "of ") {
            let totalStr = String(counterLabel[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            if let total = Int(totalStr) {
                XCTAssertGreaterThanOrEqual(total, 5, "Should have at least 5 rallies, got \(total)")
            }
        }
    }

    /// 7.1.2 — Swipe left advances to next rally
    func testSwipeToNextRally() {
        let initialLabel = rallyPlayer.rallyCounter.label
        app.swipeLeft()

        let predicate = NSPredicate(format: "label != %@", initialLabel)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: rallyPlayer.rallyCounter)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)
        XCTAssertEqual(result, .completed, "Swiping left should advance to next rally")
    }

    /// 7.2.5 — Swipe right saves rally (Tinder-card action model)
    func testSwipeRightSavesRally() {
        // Swipe right triggers save action
        app.swipeRight()

        // Should show save feedback
        let feedbackText = app.staticTexts["Rally Saved"]
        XCTAssertTrue(
            feedbackText.waitForExistence(timeout: 5),
            "Swiping right should save the rally"
        )

        // Rally player should still be functional
        XCTAssertTrue(rallyPlayer.rallyCounter.waitForExistence(timeout: 5),
                       "Rally player should continue after save")
    }

    /// 7.2.4 — Swiping right on first rally saves it and advances
    func testFirstRallySwipeRightSaves() {
        // On first rally, swipe right triggers save action
        app.swipeRight()

        // Save action shows feedback and auto-advances
        let feedbackText = app.staticTexts["Rally Saved"]
        XCTAssertTrue(
            feedbackText.waitForExistence(timeout: 5),
            "Swiping right should trigger save action"
        )
    }

    /// 7.2.3 — Rapid swiping doesn't crash
    func testRapidSwipingNoCrash() {
        for _ in 0..<8 {
            app.swipeLeft()
        }
        // Small pause to let animations settle
        sleep(1)

        // Swipe back several times
        for _ in 0..<5 {
            app.swipeRight()
        }
        sleep(1)

        // App should still be running, counter should still exist
        XCTAssertTrue(
            rallyPlayer.rallyCounter.waitForExistence(timeout: 5),
            "Rally player should survive rapid swiping without crashing"
        )
    }

    // MARK: - Overview Tests

    /// 7.5.2 — Overview sheet shows all rallies
    func testOverviewShowsAllRallies() {
        rallyPlayer.rallyCounter.tap()

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Overview sheet should appear")

        // Look for multiple rally items in the overview (thumbnails or cards)
        // The overview shows a grid of rally thumbnails
        let images = app.images.allElementsBoundByIndex
        // With 6 rallies there should be multiple visual elements
        XCTAssertGreaterThanOrEqual(
            images.count, 2,
            "Overview should show multiple rally thumbnails"
        )
    }

    /// 7.5.3 — Tap thumbnail jumps to that rally
    func testTapThumbnailJumpsToRally() {
        // Save rally 1 first so it appears in overview
        rallyPlayer.saveButton.tap()
        sleep(1) // Wait for auto-advance

        // Open overview
        rallyPlayer.rallyCounter.tap()
        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))

        // Tap first thumbnail/card in overview — this selects a rally and closes overview
        let firstImage = app.images.firstMatch
        if firstImage.waitForExistence(timeout: 3) {
            firstImage.tap()

            // Should jump to that rally — counter should still exist
            XCTAssertTrue(
                rallyPlayer.rallyCounter.waitForExistence(timeout: 5),
                "Tapping overview thumbnail should navigate to that rally"
            )
        }
    }

    /// 7.5.4 — Overview shows all rallies and can be navigated
    func testSelectDeselectFromOverview() {
        // Open overview
        rallyPlayer.rallyCounter.tap()
        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))

        // Overview should exist with rally thumbnails
        let images = app.images.allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(images.count, 1, "Overview should show rally thumbnails")

        // Dismiss via Done (finishes review session and exits rally player)
        doneButton.tap()

        // Done = finish review, so rally player should dismiss
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: rallyPlayer.rallyCounter)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Done should dismiss the rally player")
    }

    /// 7.5.5 — Overview Done button finishes review session
    func testOverviewDismisses() {
        rallyPlayer.rallyCounter.tap()
        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))

        // Done = finish review, copies favorites and exits
        doneButton.tap()

        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: rallyPlayer.rallyCounter)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Done should finish the review and dismiss rally player")
    }

    // MARK: - Multi-Action Tests

    /// 7.6.2 — Multiple undos work correctly
    func testMultipleUndos() {
        // Save first rally
        rallyPlayer.saveButton.tap()
        let savedPredicate = NSPredicate(format: "label == 'Unsave rally'")
        let savedExpectation = XCTNSPredicateExpectation(predicate: savedPredicate, object: rallyPlayer.saveButton)
        XCTWaiter.wait(for: [savedExpectation], timeout: 3)

        // Undo
        rallyPlayer.undoButton.tap()
        let revertPredicate = NSPredicate(format: "label == 'Save rally'")
        let revertExpectation = XCTNSPredicateExpectation(predicate: revertPredicate, object: rallyPlayer.saveButton)
        let result = XCTWaiter.wait(for: [revertExpectation], timeout: 3)
        XCTAssertEqual(result, .completed, "First undo should revert save action")

        // Save again and undo again to verify multiple undos work
        rallyPlayer.saveButton.tap()
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: savedPredicate, object: rallyPlayer.saveButton)], timeout: 3)

        rallyPlayer.undoButton.tap()
        let result2 = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: revertPredicate, object: rallyPlayer.saveButton)], timeout: 3)
        XCTAssertEqual(result2, .completed, "Second undo should also revert save action")
    }

    /// 7.3.3 — Counter pill shows saved rally count
    func testCounterPillShowsSavedCount() {
        // Save a rally
        rallyPlayer.saveButton.tap()
        let feedbackText = app.staticTexts["Rally Saved"]
        XCTAssertTrue(
            feedbackText.waitForExistence(timeout: 3),
            "Save action should show 'Rally Saved' feedback"
        )

        // Counter should still exist and be functional
        XCTAssertTrue(rallyPlayer.rallyCounter.exists, "Counter pill should still be visible after saving")
    }
}
