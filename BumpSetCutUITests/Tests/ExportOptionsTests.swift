//
//  ExportOptionsTests.swift
//  BumpSetCutUITests
//
//  Tests for export flow: folder selection, individual/combined options.
//  Dashboard items: 8.1.2, 8.3.3
//

import XCTest

final class ExportOptionsTests: PreProcessedVideoTestCase {

    override var testVideoName: String { "5plusrallies" }
    override var testMetadataName: String { "5plusrallies_metadata" }

    private var rallyPlayer: RallyPlayerScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rallyPlayer = RallyPlayerScreen(app: app)
        openRallyPlayer()
    }

    // MARK: - Helpers

    /// Save multiple rallies and open the export sheet.
    /// Returns true if export sheet opened.
    @discardableResult
    private func saveRalliesAndOpenExport(count: Int = 2) -> Bool {
        // Save rallies
        for i in 0..<count {
            if rallyPlayer.saveButton.waitForExistence(timeout: 3) {
                rallyPlayer.saveButton.tap()
                sleep(2)
            }
            if i < count - 1 {
                // Wait for auto-advance
                sleep(1)
            }
        }

        // Open overview
        rallyPlayer.rallyCounter.tap()
        let doneButton = app.buttons["Done"]
        guard doneButton.waitForExistence(timeout: 5) else { return false }

        // Tap export
        let exportButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Export'")
        ).firstMatch
        guard exportButton.waitForExistence(timeout: 5) else { return false }
        exportButton.tap()

        // Wait for export options
        let individualOption = app.descendants(matching: .any)["export.individual"]
        return individualOption.waitForExistence(timeout: 5)
    }

    // MARK: - 8.1.2 — Export shows folder selection / destination choice

    func testExportShowsOptions() {
        let opened = saveRalliesAndOpenExport()
        XCTAssertTrue(opened, "Export options should appear after saving rallies")

        let individualOption = app.descendants(matching: .any)["export.individual"]
        let combinedOption = app.descendants(matching: .any)["export.combined"]

        XCTAssertTrue(individualOption.exists, "Individual export option should exist")
        XCTAssertTrue(combinedOption.exists, "Combined export option should exist")
    }

    // MARK: - 8.3.3 — Each clip is a separate file (individual option)

    func testIndividualExportOptionExists() {
        let opened = saveRalliesAndOpenExport()
        guard opened else {
            XCTFail("Could not open export sheet")
            return
        }

        let individualOption = app.descendants(matching: .any)["export.individual"]
        XCTAssertTrue(individualOption.exists, "Individual export option should exist")

        // Verify it has a label describing individual clips
        let individualLabel = individualOption.label
        XCTAssertFalse(individualLabel.isEmpty, "Individual option should have a label")
    }

    // MARK: - Combined export option

    func testCombinedExportOptionExists() {
        let opened = saveRalliesAndOpenExport()
        guard opened else {
            XCTFail("Could not open export sheet")
            return
        }

        let combinedOption = app.descendants(matching: .any)["export.combined"]
        XCTAssertTrue(combinedOption.exists, "Combined export option should exist")
    }
}
