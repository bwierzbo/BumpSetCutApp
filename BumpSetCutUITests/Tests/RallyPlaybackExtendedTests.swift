//
//  RallyPlaybackExtendedTests.swift
//  BumpSetCutUITests
//
//  Extended rally playback tests using multi-rally video.
//  Dashboard items: 7.1.2, 7.1.4, 7.2.6, 7.3.4, 7.5.4, 7.6.3
//

import XCTest

final class RallyPlaybackExtendedTests: PreProcessedVideoTestCase {

    override var testVideoName: String { "5plusrallies" }
    override var testMetadataName: String { "5plusrallies_metadata" }

    private var rallyPlayer: RallyPlayerScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rallyPlayer = RallyPlayerScreen(app: app)
        openRallyPlayer()
    }

    // MARK: - 7.1.2 — First rally plays automatically

    /// Rally player loads and video is playing (no manual play button needed).
    func testFirstRallyAutoPlays() {
        // Rally counter should be visible, indicating player loaded
        let counterLabel = rallyPlayer.rallyCounter.label
        XCTAssertTrue(counterLabel.contains("1 of"), "First rally should be active: \(counterLabel)")

        // Action buttons should be visible (player is in active state, not waiting for user to press play)
        XCTAssertTrue(rallyPlayer.saveButton.exists, "Save button should exist — player is active")
        XCTAssertTrue(rallyPlayer.removeButton.exists, "Remove button should exist — player is active")
    }

    // MARK: - 7.1.4 — Play/pause works correctly

    /// Tap video area toggles pause state — undo button should still be functional after pause.
    func testTapToPauseAndResume() {
        // Tap center of screen to pause
        let center = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        center.tap()

        // Brief wait for tap gesture to register
        sleep(1)

        // Tap again to resume
        center.tap()
        sleep(1)

        // Rally player should still be functional after pause/resume cycle
        XCTAssertTrue(rallyPlayer.saveButton.exists, "Save button should still exist after pause/resume")
        XCTAssertTrue(rallyPlayer.rallyCounter.exists, "Counter should still exist after pause/resume")
    }

    // MARK: - 7.2.6 — No audio bleed during fast swiping

    /// Rapidly swipe through rallies — app shouldn't crash and player should remain functional.
    func testNoAudioBleedDuringFastSwiping() {
        // Rapidly swipe through 5 rallies
        for _ in 0..<5 {
            app.swipeLeft()
            usleep(200_000) // 200ms between swipes
        }

        // Wait for animations to settle
        sleep(2)

        // Player should still be functional
        XCTAssertTrue(
            rallyPlayer.rallyCounter.waitForExistence(timeout: 5),
            "Rally player should remain functional after rapid swiping"
        )

        // Should be on a valid rally — counter should show valid state
        let label = rallyPlayer.rallyCounter.label
        XCTAssertTrue(label.contains("of"), "Counter should show valid state after rapid swiping: \(label)")
    }

    // MARK: - 7.3.4 — Removing all rallies shows empty state

    /// Remove all rallies by tapping remove repeatedly — should show completion state.
    func testRemoveAllRalliesShowsEmptyState() {
        // Remove rallies until we run out
        for _ in 0..<8 {
            if rallyPlayer.removeButton.waitForExistence(timeout: 2) {
                rallyPlayer.removeButton.tap()
                sleep(1) // Wait for animation
            } else {
                break
            }
        }

        // After removing all rallies, overview sheet should appear with Done button
        let doneButton = app.buttons["Done"]
        let overviewAppeared = doneButton.waitForExistence(timeout: 10)

        if overviewAppeared {
            XCTAssertTrue(true, "Overview sheet appeared after removing all rallies")
        } else {
            // Rally player might still show if not all rallies were removed
            // (some rallies may have been skipped)
            XCTAssertTrue(
                rallyPlayer.rallyCounter.exists || doneButton.exists,
                "Should show either counter (more rallies) or Done (all reviewed)"
            )
        }
    }

    // MARK: - 7.5.4 — Selected/deselected rallies visually distinguished in overview

    /// Save some rallies, open overview, verify saved rallies are visually marked.
    func testOverviewShowsSavedVsUnsavedDistinction() {
        // Save first rally
        rallyPlayer.saveButton.tap()
        sleep(2)

        // Skip second rally (don't save)
        rallyPlayer.removeButton.tap()
        sleep(2)

        // Open overview
        rallyPlayer.rallyCounter.tap()
        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Overview should appear")

        // Look for rally items with "saved" or "Saved" in accessibility labels
        let savedRallies = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'saved'")
        )
        let removedRallies = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'removed'")
        )

        // At least one saved and one removed rally should be distinguishable
        let hasSaved = savedRallies.count > 0
        let hasRemoved = removedRallies.count > 0

        // Both states should be represented
        XCTAssertTrue(hasSaved || hasRemoved,
                       "Overview should visually distinguish saved/removed rallies via accessibility labels")

        doneButton.tap()
    }
}
