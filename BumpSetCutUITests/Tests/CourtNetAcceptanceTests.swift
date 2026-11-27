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

    /// The court's six points: the near corners zoomed out (they are out of this recording's picture), the rest
    /// at the fitted size — zoomed out on a phone held upright the far corners are within a finger's reach of the
    /// net points, and a tap there takes hold of the point already placed.
    private func placeCourt(_ editor: inout CalibrationScreen, afterNearCorners: () -> Void = {}) {
        editor.zoomOut()
        for mark in Marks.court.prefix(2) { editor.tapFrame(x: mark.x, y: mark.y) }
        afterNearCorners()
        editor.fit()
        for mark in Marks.court.dropFirst(2) { editor.tapFrame(x: mark.x, y: mark.y) }
        for mark in Marks.court { assertChip(editor, mark.name, placed: true) }
    }

    /// The net's four corners. On a phone held upright this net is shorter than a finger's reach, so a tap on a
    /// bottom corner would take hold of the top one above it: each bottom corner is put down lower, then dragged up.
    private func placeNet(_ editor: CalibrationScreen, afterThreeCorners: () -> Void = {}) {
        for mark in Marks.net.prefix(2) { editor.tapFrame(x: mark.x, y: mark.y) }
        let below: CGFloat = 0.07
        for (index, mark) in Marks.net.enumerated().dropFirst(2) {
            editor.tapFrame(x: mark.x, y: mark.y - below)
            editor.drag(fromX: mark.x, y: mark.y - below, toX: mark.x, y: mark.y)
            if index == 2 { afterThreeCorners() }
        }
        for mark in Marks.net { assertChip(editor, mark.name, placed: true) }
    }

    /// A video whose court and net are confirmed, editor open on the Court tab.
    private func openEditorWithConfirmedCourtAndNet() -> CalibrationScreen {
        openVideoScreen()
        var editor = openEditor()
        placeCourt(&editor)
        editor.confirmButton.tap()
        assertStatus(editor, contains: "Court confirmed")
        editor.tab("Net").tap()
        placeNet(editor)
        editor.confirmButton.tap()
        assertStatus(editor, contains: "Court and net confirmed")
        editor.tab("Court").tap()
        return editor
    }

    /// A written report for a person to read, attached beside the step's pictures: what Apple's accessibility
    /// audit says about the screen (text cut off, text that doesn't grow, low contrast, small touch areas, missing
    /// descriptions) and which controls come within `margin` points of a screen edge. Nothing here fails the test.
    private func report(_ step: String, margin: CGFloat = 8) throws {
        var lines: [String] = []
        try app.performAccessibilityAudit(for: [.dynamicType, .textClipped, .contrast, .hitRegion, .sufficientElementDescription]) { issue in
            let element = issue.element.map { "\($0.elementType.rawValue) \"\($0.label)\" \($0.frame.integral)" } ?? "(screen)"
            lines.append("audit · \(issue.compactDescription) · \(element)")
            return true
        }
        let screen = app.windows.firstMatch.frame
        for element in app.buttons.allElementsBoundByIndex + app.staticTexts.allElementsBoundByIndex {
            let frame = element.frame
            guard !frame.isEmpty, frame.intersects(screen) else { continue }
            if frame.minX < screen.minX + margin || frame.maxX > screen.maxX - margin {
                lines.append("edge · \"\(element.label.prefix(60))\" runs x \(Int(frame.minX))…\(Int(frame.maxX)) on a \(Int(screen.width)) pt wide screen")
            }
        }
        let text = XCTAttachment(string: lines.isEmpty ? "Nothing found." : lines.joined(separator: "\n"))
        text.name = "\(step) report"
        text.lifetime = .keepAlways
        add(text)
    }

    override var extraLaunchArguments: [String] {
        name.contains("LargestText") ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        try super.tearDownWithError()
    }

    // MARK: - A. Opening

    func testA_Opening() throws {
        openVideoScreen()
        XCTAssertTrue(courtNetRow.label.contains("Mark the court and net on this video") || courtNetRow.label.contains("Not calibrated"),
                      "A1: the row reads \"\(courtNetRow.label)\"")
        XCTAssertTrue(process.startButton.exists, "A1: processing can be started without calibrating")
        // G1: what a run does without a confirmed net is said before the run.
        let warning = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Until the net is confirmed here")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "G1: the screen says rallies aren't checked against the net")
        XCTAssertTrue(warning.label.hasSuffix("isn't ruled out."), "G1: the warning reads \"\(warning.label)\"")
        checkpoint("A1", "video screen with the Court & Net row")
        try report("A1")

        let editor = openEditor()
        assertStatus(editor, contains: "Not calibrated")
        XCTAssertTrue(editor.hint.label.contains("near-left corner"), "A2: the hint reads \"\(editor.hint.label)\"")
        checkpoint("A2", "editor just opened")
        try report("A2")
    }

    // MARK: - B and C. Court, then net, by hand

    func testBC_CourtAndNetByHand() {
        openVideoScreen()
        var editor = openEditor()

        // B6 comes first on this recording: its near corners are out of the picture.
        placeCourt(&editor) { checkpoint("B6", "zoomed out, near corners placed outside the frame") }
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
        placeNet(editor) {
            // C3: three corners are kept on screen but the net is not saved.
            editor.saveDraftButton.tap()
            assertStatus(editor, contains: "The net needs all four corners")
            checkpoint("C3", "saved with three net corners")
        }
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

    // MARK: - B11. A court that can't be one

    func testB11_PointsOnTopOfEachOther() {
        openVideoScreen()
        let editor = openEditor()
        // A tap on a point takes hold of it, so three points are put apart and two dragged onto the first.
        editor.tapFrame(x: 0.3, y: 0.3)
        editor.tapFrame(x: 0.6, y: 0.3)
        editor.tapFrame(x: 0.3, y: 0.7)
        editor.drag(fromX: 0.6, y: 0.3, toX: 0.3, y: 0.3)
        editor.drag(fromX: 0.3, y: 0.7, toX: 0.3, y: 0.3)
        checkpoint("B11a", "three points on top of each other")
        editor.confirmButton.tap()
        XCTAssertFalse(editor.tab("Court").label.contains("✓"), "B11: the Court tab reads \"\(editor.tab("Court").label)\"")
        assertStatus(editor, contains: "Draft")
        checkpoint("B11b", "confirm refused with the reason, kept as a draft")
    }

    // MARK: - D. Later edits

    func testD_LaterEdits() {
        var editor = openEditorWithConfirmedCourtAndNet()
        editor.close()
        XCTAssertTrue(courtNetRow.waitForExistence(timeout: 5))
        editor = openEditor()
        let farLeft = Marks.court[4]

        // D1: an edit after confirming, dropped on closing.
        editor.drag(fromX: farLeft.x, y: farLeft.y, toX: farLeft.x - 0.04, y: farLeft.y + 0.02)
        XCTAssertTrue(editor.tab("Court").label.contains("✓ edited"), "D1: the Court tab reads \"\(editor.tab("Court").label)\"")
        assertStatus(editor, contains: "Court and net confirmed")
        checkpoint("D1a", "far-left moved, tab reads edited, status still confirmed")
        editor.close(saving: false)
        XCTAssertTrue(courtNetRow.waitForExistence(timeout: 5))
        editor = openEditor()
        XCTAssertFalse(editor.tab("Court").label.contains("edited"), "D1: reopened, the Court tab reads \"\(editor.tab("Court").label)\"")
        checkpoint("D1b", "closed without saving and reopened, the confirmed court unchanged")

        // D2: the same edit, confirmed.
        editor.drag(fromX: farLeft.x, y: farLeft.y, toX: farLeft.x - 0.04, y: farLeft.y + 0.02)
        editor.confirmButton.tap()
        assertStatus(editor, contains: "Court confirmed.")
        XCTAssertFalse(editor.tab("Court").label.contains("edited"), "D2: the Court tab reads \"\(editor.tab("Court").label)\"")
        checkpoint("D2", "far-left moved and the court confirmed again")

        // D3: starting over keeps the confirmed court until another is confirmed.
        editor.more("Start the court over")
        for mark in Marks.court { assertChip(editor, mark.name, placed: false) }
        checkpoint("D3a", "court started over, points gone")
        editor.close()
        XCTAssertTrue(courtNetRow.waitForExistence(timeout: 5))
        checkpoint("D3b", "video screen after starting the court over")
        editor = openEditor()
        for mark in Marks.court { assertChip(editor, mark.name, placed: true) }
        checkpoint("D3c", "reopened, the earlier confirmed court is shown")

        // D4: the court's type is kept.
        editor.more("Surface", "Beach")
        editor.more("Players a side", "2 v 2")
        editor.close()
        XCTAssertTrue(courtNetRow.waitForExistence(timeout: 5))
        editor = openEditor()
        // The menu's first level doesn't show what is chosen; each submenu ticks it. Picking the ticked item
        // again closes the menu and changes nothing.
        for (picker, kept, step) in [("Surface", "Beach", "D4a"), ("Players a side", "2 v 2", "D4b")] {
            editor.moreButton.tap()
            app.buttons[picker].firstMatch.tap()
            let item = app.buttons[kept].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "D4: \(picker) offers \(kept)")
            checkpoint(step, "reopened, \(picker) has \(kept) ticked")
            XCTAssertTrue(item.isSelected, "D4: \(kept) is still chosen for \(picker) after closing and reopening")
            item.tap()
        }
    }

    // MARK: - E. Frames and camera views (and G9's line on the video's screen)

    func testE_FramesAndCameraViews() {
        var editor = openEditorWithConfirmedCourtAndNet()

        // E1
        let start = editor.seconds
        app.buttons["Forward one frame"].tap()
        let oneFrame = editor.seconds - start
        XCTAssertTrue(oneFrame > 0.005 && oneFrame < 0.1, "E1: one frame forward moved the time by \(oneFrame) s")
        app.buttons["Back one frame"].tap()
        XCTAssertEqual(editor.seconds, start, accuracy: 0.011, "E1: one frame back")
        app.buttons["Forward 5 seconds"].tap()
        XCTAssertEqual(editor.seconds, start + 5, accuracy: 0.011, "E1: five seconds forward")
        checkpoint("E1a", "five seconds forward, marks stay put")
        app.buttons["Back 5 seconds"].tap()
        editor.positionSlider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(editor.seconds > 20 && editor.seconds < 55, "E1: the slider's middle reads \(editor.clock.label)")
        for mark in Marks.court { assertChip(editor, mark.name, placed: true) }
        checkpoint("E1b", "slider dragged to the middle of the video")

        // E2: the camera moved here.
        editor.more("Camera changed here", "Start from these marks")
        assertStatus(editor, contains: "Camera view 2 of 2")
        for mark in Marks.court { assertChip(editor, mark.name, placed: true) }
        checkpoint("E2a", "camera view 2 of 2, marks carried over but not confirmed")
        editor.close()
        XCTAssertTrue(courtNetRow.waitForExistence(timeout: 5))
        XCTAssertTrue(courtNetRow.label.contains("Needs review"), "E2: the row reads \"\(courtNetRow.label)\"")
        checkpoint("E2b", "video screen row reads Needs review")

        // E3: before the split is view 1, still confirmed.
        editor = openEditor()
        editor.positionSlider.adjust(toNormalizedSliderPosition: 0.8)
        assertStatus(editor, contains: "Camera view 2 of 2")
        editor.positionSlider.adjust(toNormalizedSliderPosition: 0.15)
        assertStatus(editor, contains: "Camera view 1 of 2")
        XCTAssertTrue(editor.tab("Court").label.contains("✓"), "E3: view 1's Court tab reads \"\(editor.tab("Court").label)\"")
        checkpoint("E3", "scrubbed back before the split, view 1 of 2 with its confirmed marks")

        // E4: a part of the video that is not a stable court view takes no marks.
        editor.positionSlider.adjust(toNormalizedSliderPosition: 0.8)
        assertStatus(editor, contains: "Camera view 2 of 2")
        let farRight = Marks.court[5]
        editor.chip(farRight.name).tap()
        app.buttons["Can't place it"].tap()
        assertChip(editor, farRight.name, placed: false)
        editor.more("Not a stable court view")
        XCTAssertTrue(editor.notStableBanner.waitForExistence(timeout: 3), "E4: a banner says this is not a stable court view")
        editor.tapFrame(x: farRight.x, y: farRight.y)
        assertChip(editor, farRight.name, placed: false)
        checkpoint("E4a", "not a stable court view, a tap placed nothing")
        app.buttons["It is a stable view"].tap()
        XCTAssertTrue(editor.notStableBanner.waitForNonExistence(timeout: 3), "E4: the banner goes")
        editor.chip(farRight.name).tap()
        editor.tapFrame(x: farRight.x, y: farRight.y)
        assertChip(editor, farRight.name, placed: true)
        checkpoint("E4b", "stable again, the tap places the corner")

        // G9: the net confirmed in both views is still not used, and the video's screen says so.
        editor.confirmButton.tap()
        editor.tab("Net").tap()
        editor.confirmButton.tap()
        assertStatus(editor, contains: "Court and net confirmed")
        editor.close()
        XCTAssertTrue(courtNetRow.waitForExistence(timeout: 5))
        let line = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This video has more than one camera view")).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "G9: the screen says the video has more than one camera view")
        checkpoint("G9", "two camera views confirmed, the line under Court & Net")
    }

    // MARK: - F. Orientation and size

    func testF2_Landscape() {
        let editor = openEditorWithConfirmedCourtAndNet()
        checkpoint("F2a", "upright, before turning")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(editor.confirmButton.waitForExistence(timeout: 5))
        for mark in Marks.court { assertChip(editor, mark.name, placed: true) }
        checkpoint("F2b", "turned to landscape, picture left and controls right")
        let farLeft = Marks.court[4]
        editor.drag(fromX: farLeft.x, y: farLeft.y, toX: farLeft.x - 0.04, y: farLeft.y + 0.02)
        XCTAssertTrue(editor.tab("Court").label.contains("✓ edited"), "F2: a drag in landscape moves the point (the Court tab reads \"\(editor.tab("Court").label)\")")
        checkpoint("F2c", "far-left dragged in landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(editor.confirmButton.waitForExistence(timeout: 5))
        checkpoint("F2d", "turned back upright")
    }

    func testF3_LargestText() throws {
        openVideoScreen()
        checkpoint("F3a", "video screen at the largest text size")
        try report("F3 video screen")
        let editor = openEditor()
        checkpoint("F3b", "editor at the largest text size")
        try report("F3 editor")
        let controls: [(String, XCUIElement)] = [
            ("Close", editor.closeButton), ("More", editor.moreButton), ("Court tab", editor.tab("Court")), ("Net tab", editor.tab("Net")),
            ("Show the court", editor.showCourtButton), ("Show the net", editor.showNetButton), ("Move all", editor.moveAllToggle),
            ("Zoom out", app.buttons["Zoom out"]), ("Fit the picture", app.buttons["Fit the picture"]), ("Zoom in", app.buttons["Zoom in"]),
            ("Near L chip", editor.chip("Near L")), ("Back one frame", app.buttons["Back one frame"]),
            ("Forward one frame", app.buttons["Forward one frame"]), ("Position slider", editor.positionSlider),
            ("Save draft", editor.saveDraftButton), ("Confirm", editor.confirmButton)
        ]
        // Nothing is drawn over anything else.
        let stacked: [(String, XCUIElement)] = [
            ("the point chips", editor.chip("Near L")), ("the hint", editor.hint), ("the frame's time", editor.clock),
            ("the position slider", editor.positionSlider), ("Save draft", editor.saveDraftButton)
        ]
        for (above, below) in zip(stacked, stacked.dropFirst()) {
            XCTAssertLessThanOrEqual(above.1.frame.maxY, below.1.frame.minY + 1, "F3: \(above.0) runs into \(below.0)")
        }
        var outOfReach = controls.filter { !$0.1.isHittable }.map(\.0)
        if !outOfReach.isEmpty {
            // The controls scroll under the picture.
            editor.hint.swipeUp()
            checkpoint("F3c", "editor controls scrolled up")
            outOfReach = controls.filter { outOfReach.contains($0.0) && !$0.1.isHittable }.map(\.0)
        }
        XCTAssertTrue(outOfReach.isEmpty, "F3: not reachable at the largest text size: \(outOfReach.joined(separator: ", "))")
    }
}
