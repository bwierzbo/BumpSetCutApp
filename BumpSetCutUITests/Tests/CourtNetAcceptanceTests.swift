//
//  CourtNetAcceptanceTests.swift
//  BumpSetCutUITests
//
//  The Court & Net device acceptance list (docs/workflow/COURT_NET_CALIBRATION_DEVICE_ACCEPTANCE.md) as
//  scripts. Each step asserts what a script can tell, and attaches a screenshot named by the step's id for a
//  person to look at: the picture, where the marks landed and how the screen reads are theirs to judge.
//
//  Fixture (local, gitignored): TestData/acceptance_beach.mov — a landscape 16:9 recording filmed from behind
//  an end line, a minute or longer, whose near corners are out of the picture.
//

import XCTest

final class CourtNetAcceptanceTests: VideoTestCase {
    override var testVideoName: String { "acceptance_beach" }

    /// The marks for the fixture, as fractions of the frame (origin bottom-left).
    private enum Marks {
        static let court: [(name: String, x: CGFloat, y: CGFloat)] = [
            ("Near L", -0.11, 0.07), ("Near R", 1.20, 0.07), ("Net L", 0.285, 0.298),
            ("Net R", 0.755, 0.298), ("Far L", 0.385, 0.36), ("Far R", 0.667, 0.36)
        ]
        static let net: [(name: String, x: CGFloat, y: CGFloat)] = [
            ("Top L", 0.216, 0.565), ("Top R", 0.833, 0.559), ("Bottom R", 0.833, 0.457), ("Bottom L", 0.216, 0.457)
        ]
    }

    private var process: ProcessScreen { ProcessScreen(app: app) }
    private var courtNetRow: XCUIElement { app.buttons["process.courtNet"] }

    /// A screenshot for a person to check, named by the acceptance step.
    private func checkpoint(_ step: String, _ what: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(step) \(what)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openVideoScreen() {
        navigateToLibrary()
        tapFirstVideoCard()
        XCTAssertTrue(courtNetRow.waitForExistence(timeout: 10), "The video's screen has a Court & Net row")
    }

    private func openEditor() -> CalibrationScreen {
        courtNetRow.tap()
        let editor = CalibrationScreen(app: app, frameAspect: 16.0 / 9.0)
        XCTAssertTrue(editor.canvas.waitForExistence(timeout: 15), "The editor opens on a frame of the video")
        XCTAssertTrue(editor.confirmButton.waitForExistence(timeout: 15))
        return editor
    }

    private func assertStatus(_ editor: CalibrationScreen, contains text: String, file: StaticString = #file, line: UInt = #line) {
        let found = NSPredicate(format: "label CONTAINS %@", text)
        let waited = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: found, object: editor.status)], timeout: 5)
        XCTAssertEqual(waited, .completed, "Status reads \"\(editor.status.label)\", expected it to contain \"\(text)\"", file: file, line: line)
    }

    private func assertChip(_ editor: CalibrationScreen, _ name: String, placed: Bool, file: StaticString = #file, line: UInt = #line) {
        XCTAssertEqual(editor.chip(name).value as? String, placed ? "Placed" : "Not placed", "\(name)", file: file, line: line)
    }

    // MARK: - A. Opening

    func testA_Opening() {
        openVideoScreen()
        XCTAssertTrue(courtNetRow.label.contains("Mark the court and net on this video") || courtNetRow.label.contains("Not calibrated"),
                      "A1: the row reads \"\(courtNetRow.label)\"")
        XCTAssertTrue(process.startButton.exists, "A1: processing can be started without calibrating")
        // G1: what a run does without a confirmed net is said before the run.
        let warning = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Until the net is confirmed here")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "G1: the screen says rallies aren't checked against the net")
        XCTAssertTrue(warning.label.hasSuffix("isn't ruled out."), "G1: the warning reads \"\(warning.label)\"")
        checkpoint("A1", "video screen with the Court & Net row")

        let editor = openEditor()
        assertStatus(editor, contains: "Not calibrated")
        XCTAssertTrue(editor.hint.label.contains("near-left corner"), "A2: the hint reads \"\(editor.hint.label)\"")
        checkpoint("A2", "editor just opened")
    }

    // MARK: - B and C. Court, then net, by hand

    func testBC_CourtAndNetByHand() {
        openVideoScreen()
        var editor = openEditor()

        // B6 comes first on this recording: its near corners are out of the picture.
        editor.zoomOut()
        for mark in Marks.court.prefix(2) { editor.tapFrame(x: mark.x, y: mark.y) }
        checkpoint("B6", "zoomed out, near corners placed outside the frame")
        // The rest at the fitted size: zoomed out on a phone held upright, the far corners are within a
        // finger's reach of the net points, and a tap there takes hold of the point already placed.
        editor.fit()
        for mark in Marks.court.dropFirst(2) { editor.tapFrame(x: mark.x, y: mark.y) }
        for mark in Marks.court { assertChip(editor, mark.name, placed: true) }
        checkpoint("B1", "six court points placed")

        // B2: drag a point (the loupe shows only while a finger is down — a person checks that on a phone).
        editor.drag(fromX: Marks.court[4].x, y: Marks.court[4].y, toX: Marks.court[4].x - 0.02, y: Marks.court[4].y + 0.01)
        checkpoint("B2", "far-left corner dragged a little left and up")

        // B3: drag the near end line by its middle.
        editor.drag(fromX: 0.545, y: 0.07, toX: 0.545, y: 0.10)
        checkpoint("B3", "near end line dragged up, both its ends moved")
        editor.drag(fromX: 0.545, y: 0.10, toX: 0.545, y: 0.07)

        // B4: move the whole court, and back.
        editor.moveAllToggle.tap()
        editor.drag(fromX: 0.5, y: 0.2, toX: 0.6, y: 0.2)
        checkpoint("B4", "Move all on, whole court dragged right")
        editor.drag(fromX: 0.6, y: 0.2, toX: 0.5, y: 0.2)
        editor.moveAllToggle.tap()

        // B5: pinch, then back to the fitted picture.
        editor.canvas.pinch(withScale: 2.5, velocity: 1.5)
        checkpoint("B5", "pinched in, marks stay on the picture")
        editor.fit()

        // B7: a hidden corner is a best guess.
        editor.chip("Far L").tap()
        XCTAssertTrue(editor.hiddenToggle.waitForExistence(timeout: 3), "B7: the selected point offers Hidden — my best guess")
        editor.hiddenToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        checkpoint("B7", "far-left marked hidden, dashed ring")

        // B8: a corner that can't be placed, then placed after all.
        editor.chip("Far R").tap()
        app.buttons["Can't place it"].tap()
        assertChip(editor, "Far R", placed: false)
        checkpoint("B8a", "far-right removed, chip greyed")
        editor.chip("Far R").tap()
        editor.tapFrame(x: Marks.court[5].x, y: Marks.court[5].y)
        assertChip(editor, "Far R", placed: true)
        checkpoint("B8b", "far-right placed again")

        // B9: a draft survives closing.
        editor.saveDraftButton.tap()
        assertStatus(editor, contains: "Draft")
        checkpoint("B9a", "draft saved")
        editor.close()
        XCTAssertTrue(courtNetRow.waitForExistence(timeout: 5))
        XCTAssertTrue(courtNetRow.label.contains("Draft"), "B9: the row reads \"\(courtNetRow.label)\"")
        checkpoint("B9b", "video screen row reads Draft")
        editor = openEditor()
        for mark in Marks.court { assertChip(editor, mark.name, placed: true) }
        editor.zoomOut()
        checkpoint("B9c", "reopened, everything where it was")
        editor.fit()

        // B10
        editor.confirmButton.tap()
        assertStatus(editor, contains: "Court confirmed")
        XCTAssertTrue(editor.tab("Court").label.contains("✓"), "B10: the Court tab reads \"\(editor.tab("Court").label)\"")
        checkpoint("B10", "court confirmed")

        // C1
        editor.tab("Net").tap()
        for mark in Marks.net.prefix(2) { editor.tapFrame(x: mark.x, y: mark.y) }
        // On a phone held upright this net is shorter than a finger's reach, so a tap on a bottom corner
        // would take hold of the top one above it: each bottom corner is put down lower, then dragged up.
        let below: CGFloat = 0.07
        editor.tapFrame(x: Marks.net[2].x, y: Marks.net[2].y - below)
        editor.drag(fromX: Marks.net[2].x, y: Marks.net[2].y - below, toX: Marks.net[2].x, y: Marks.net[2].y)
        // C3: three corners are kept on screen but the net is not saved.
        editor.saveDraftButton.tap()
        assertStatus(editor, contains: "The net needs all four corners")
        checkpoint("C3", "saved with three net corners")
        editor.tapFrame(x: Marks.net[3].x, y: Marks.net[3].y - below)
        editor.drag(fromX: Marks.net[3].x, y: Marks.net[3].y - below, toX: Marks.net[3].x, y: Marks.net[3].y)
        for mark in Marks.net { assertChip(editor, mark.name, placed: true) }
        checkpoint("C1", "net's four corners placed, court dimmed")

        // C2
        editor.showCourtButton.tap()
        checkpoint("C2a", "court hidden")
        editor.showCourtButton.tap()
        editor.showNetButton.tap()
        checkpoint("C2b", "net hidden")
        editor.showNetButton.tap()

        // C4
        editor.confirmButton.tap()
        assertStatus(editor, contains: "Court and net confirmed")
        checkpoint("C4a", "court and net confirmed")
        editor.close()
        XCTAssertTrue(courtNetRow.waitForExistence(timeout: 5))
        XCTAssertTrue(courtNetRow.label.contains("Court and net confirmed"), "C4: the row reads \"\(courtNetRow.label)\"")
        checkpoint("C4b", "video screen row reads Court and net confirmed")
    }
}
