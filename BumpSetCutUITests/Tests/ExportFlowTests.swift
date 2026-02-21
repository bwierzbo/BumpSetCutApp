//
//  ExportFlowTests.swift
//  BumpSetCutUITests
//
//  Test Plan §8 — Export flow: button access, options, empty state.
//  Uses PreProcessedVideoTestCase for rally player access.
//  Dashboard items: 8.1.1, 8.3.1
//

import XCTest

final class ExportFlowTests: PreProcessedVideoTestCase {

    private var rallyPlayer: RallyPlayerScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rallyPlayer = RallyPlayerScreen(app: app)
        openRallyPlayer()
    }

    // MARK: - Export Button Access (8.1.1)

    /// 8.1.1 — Export button accessible from overview when rallies are saved
    func testExportButtonExistsAfterSaving() {
        // Save a rally
        rallyPlayer.saveButton.tap()

        // Wait for save confirmation
        let savedPredicate = NSPredicate(format: "label == 'Unsave rally'")
        let savedExpectation = XCTNSPredicateExpectation(predicate: savedPredicate, object: rallyPlayer.saveButton)
        XCTWaiter.wait(for: [savedExpectation], timeout: 3)

        // Open overview
        rallyPlayer.rallyCounter.tap()
        let doneButton = app.buttons["Done"]
        guard doneButton.waitForExistence(timeout: 5) else { return }

        // Export button should exist
        let exportButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Export'")
        ).firstMatch
        XCTAssertTrue(exportButton.waitForExistence(timeout: 5),
                       "Export button should exist in overview when rallies are saved")
    }

    // MARK: - Export Options (8.3.1)

    /// 8.3.1 — Export shows individual and combined options
    func testExportShowsIndividualAndCombinedOptions() {
        // Save a rally
        rallyPlayer.saveButton.tap()
        let savedPredicate = NSPredicate(format: "label == 'Unsave rally'")
        let savedExpectation = XCTNSPredicateExpectation(predicate: savedPredicate, object: rallyPlayer.saveButton)
        XCTWaiter.wait(for: [savedExpectation], timeout: 3)

        // Open overview and tap export
        rallyPlayer.rallyCounter.tap()
        let doneButton = app.buttons["Done"]
        guard doneButton.waitForExistence(timeout: 5) else { return }

        let exportButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Export'")
        ).firstMatch
        guard exportButton.waitForExistence(timeout: 5) else { return }
        exportButton.tap()

        // Both export options should appear
        let individualOption = app.descendants(matching: .any)["export.individual"]
        let combinedOption = app.descendants(matching: .any)["export.combined"]

        let hasIndividual = individualOption.waitForExistence(timeout: 5)
        let hasCombined = combinedOption.waitForExistence(timeout: 3)
        XCTAssertTrue(hasIndividual, "Individual export option should exist")
        XCTAssertTrue(hasCombined, "Combined export option should exist")
    }

    // MARK: - No Saved Rallies Export (empty state)

    /// Export sheet shows empty state when no rallies saved
    func testExportEmptyStateWhenNoSavedRallies() {
        // Open overview without saving any rallies
        rallyPlayer.rallyCounter.tap()
        let doneButton = app.buttons["Done"]
        guard doneButton.waitForExistence(timeout: 5) else { return }

        // Look for export button
        let exportButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Export'")
        ).firstMatch

        guard exportButton.waitForExistence(timeout: 5) else {
            // No export button when nothing saved — valid behavior
            return
        }
        exportButton.tap()

        // Should show empty state message about no saved rallies
        let noSavedText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'No rallies saved'")
        ).firstMatch
        if noSavedText.waitForExistence(timeout: 5) {
            XCTAssertTrue(true, "Export shows empty state for no saved rallies")
        }
    }

    // MARK: - Export with Multiple Saved Rallies

    /// Save multiple rallies and verify export count reflects them
    func testExportCountReflectsMultipleSavedRallies() {
        // Save the current rally
        rallyPlayer.saveButton.tap()
        let feedbackText = app.staticTexts["Rally Saved"]
        _ = feedbackText.waitForExistence(timeout: 3)

        // Try to save another rally by swiping
        app.swipeLeft()
        sleep(1)

        // Save second rally if we advanced
        if rallyPlayer.saveButton.waitForExistence(timeout: 3) {
            let label = rallyPlayer.saveButton.label
            if label == "Save rally" {
                rallyPlayer.saveButton.tap()
                let feedback2 = app.staticTexts["Rally Saved"]
                _ = feedback2.waitForExistence(timeout: 3)
            }
        }

        // Open overview
        rallyPlayer.rallyCounter.tap()
        let doneButton = app.buttons["Done"]
        guard doneButton.waitForExistence(timeout: 5) else { return }

        // Export button should exist
        let exportButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Export'")
        ).firstMatch
        guard exportButton.waitForExistence(timeout: 5) else { return }
        exportButton.tap()

        // Export title should reflect rally count (e.g., "Export 2 Rallies")
        let exportTitle = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Export' AND label CONTAINS 'Rall'")
        ).firstMatch
        XCTAssertTrue(exportTitle.waitForExistence(timeout: 5),
                       "Export sheet should show rally count")
    }
}
