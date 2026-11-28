//
//  CourtNetAcceptanceTests.swift
//  BumpSetCutUITests
//
//  The Court & Net device acceptance list (docs/workflow/COURT_NET_CALIBRATION_DEVICE_ACCEPTANCE.md) as
//  scripts. The court and the net are marked on their pages of the setup before a run (trim, camera position,
//  court, net). Each step asserts what a script can tell, and attaches a screenshot named by the step's id for a
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

    /// A screenshot for a person to check, named by the acceptance step.
    private func checkpoint(_ step: String, _ what: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(step) \(what)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The video's screen, before a run.
    private func openVideoScreen() {
        navigateToLibrary()
        tapFirstVideoCard()
        XCTAssertTrue(process.startButton.waitForExistence(timeout: 10), "The video's screen offers Start AI Processing")
    }

    /// The court or net page once it is showing.
    private func page(_ name: String, file: StaticString = #file, line: UInt = #line) -> CalibrationScreen {
        let heading = NSPredicate(format: "label BEGINSWITH %@", name + ",")
        let shown = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: heading, object: process.setupProgress)], timeout: 10)
        XCTAssertEqual(shown, .completed, "The \(name) page is showing", file: file, line: line)
        // The court of this recording reaches past the picture's edge, so its page opens zoomed out.
        let editor = CalibrationScreen(app: app, frameAspect: 16.0 / 9.0, scale: name == "Court" ? CalibrationScreen.courtStartScale : 1)
        XCTAssertTrue(editor.canvas.waitForExistence(timeout: 15), "The \(name) page opens on a frame of the video", file: file, line: line)
        XCTAssertTrue(editor.confirmButton.waitForExistence(timeout: 15), file: file, line: line)
        return editor
    }

    /// From the video's screen: Start, past the trim and camera pages, to the court page.
    private func openCourtPage() -> CalibrationScreen {
        XCTAssertTrue(process.startButton.waitForExistence(timeout: 10))
        process.startButton.tap()
        XCTAssertTrue(process.setupSkipButton.waitForExistence(timeout: 10), "Start opens the setup pages")
        process.setupSkipButton.tap()
        let cameraContinue = app.buttons["process.cameraSetupContinue"]
        XCTAssertTrue(cameraContinue.waitForExistence(timeout: 5), "The camera page follows the trim page")
        cameraContinue.tap()
        return page("Court")
    }

    /// The run the last page started is stopped (which goes back to the library), and the video's screen opened again.
    private func stopRun() {
        XCTAssertTrue(process.cancelButton.waitForExistence(timeout: 15), "The last page starts the run")
        process.cancelButton.tap()
        tapFirstVideoCard()
        XCTAssertTrue(process.startButton.waitForExistence(timeout: 15), "A stopped run leaves the video ready to start again")
    }

    private func assertStatus(_ editor: CalibrationScreen, contains text: String, file: StaticString = #file, line: UInt = #line) {
        let found = NSPredicate(format: "label CONTAINS %@", text)
        let waited = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: found, object: editor.status)], timeout: 5)
        XCTAssertEqual(waited, .completed, "Status reads \"\(editor.status.label)\", expected it to contain \"\(text)\"", file: file, line: line)
    }

    /// Where the court page's outline starts (CalibrationWorkingShapes.courtOutline): the far corners in the picture,
    /// the near corners off its lower edge, each centre-line point three tenths of the way down its sideline.
    private enum Outline {
        static let nearLeft = CGPoint(x: -0.18, y: -0.12), nearRight = CGPoint(x: 1.18, y: -0.12)
        static let farLeft = CGPoint(x: 0.36, y: 0.42), farRight = CGPoint(x: 0.64, y: 0.42)
        static let centreDownSideline: CGFloat = 0.3
    }

    private func mark(_ name: String) -> CGPoint {
        let found = Marks.court.first { $0.name == name }!
        return CGPoint(x: found.x, y: found.y)
    }

    private func assertHint(_ editor: CalibrationScreen, contains text: String, file: StaticString = #file, line: UInt = #line) {
        let found = NSPredicate(format: "label CONTAINS %@", text)
        let waited = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: found, object: editor.hint)], timeout: 5)
        XCTAssertEqual(waited, .completed, "The instruction reads \"\(editor.hint.label)\", expected it to contain \"\(text)\"", file: file, line: line)
    }

    /// The court page opens zoomed out with an outline on the picture. Its corners are dragged onto the court's
    /// corners — the near ones are out of this recording's picture — and then each centre-line point is slid along
    /// its sideline to where the line under the net meets it.
    private func fitCourt(_ editor: CalibrationScreen, afterNearCorners: () -> Void = {}) {
        assertHint(editor, contains: "Drag the outline")
        for (from, name) in [(Outline.nearLeft, "Near L"), (Outline.nearRight, "Near R")] {
            editor.drag(fromX: from.x, y: from.y, toX: mark(name).x, y: mark(name).y)
        }
        afterNearCorners()
        for (from, name) in [(Outline.farLeft, "Far L"), (Outline.farRight, "Far R")] {
            editor.drag(fromX: from.x, y: from.y, toX: mark(name).x, y: mark(name).y)
        }
        for (far, near, centre) in [("Far L", "Near L", "Net L"), ("Far R", "Near R", "Net R")] {
            let (f, n, t) = (mark(far), mark(near), Outline.centreDownSideline)
            editor.drag(fromX: f.x + t * (n.x - f.x), y: f.y + t * (n.y - f.y), toX: mark(centre).x, y: mark(centre).y)
        }
        assertHint(editor, contains: "Drag a corner or a line")
    }

    /// The net's four corners, one tap each in the order asked: a tap always puts the next corner down, so the
    /// bottom corners go straight under the top ones though they are within a finger's reach of them.
    private func placeNet(_ editor: CalibrationScreen, afterThreeCorners: () -> Void = {}) {
        let asked = ["top-left", "top-right", "bottom-right", "bottom-left"]
        for (index, mark) in Marks.net.enumerated() {
            assertHint(editor, contains: asked[index])
            editor.tapFrame(x: mark.x, y: mark.y)
            if index == 2 { afterThreeCorners() }
        }
        assertHint(editor, contains: "Is this the net?")
        XCTAssertTrue(editor.backButton.exists, "Back is offered once a corner is down")
    }

    /// A video whose court and net are confirmed, on its court page again.
    private func openCourtPageWithConfirmedCourtAndNet() -> CalibrationScreen {
        openVideoScreen()
        var editor = openCourtPage()
        fitCourt(editor)
        editor.confirmButton.tap()
        editor = page("Net")
        placeNet(editor)
        editor.confirmButton.tap()
        stopRun()
        editor = openCourtPage()
        assertStatus(editor, contains: "Court and net confirmed")
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
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Court & Net")).firstMatch.exists,
                       "A1: the video's screen has no Court & Net row; the setup pages ask")
        checkpoint("A1", "video screen before a run")
        try report("A1")

        let editor = openCourtPage()
        assertStatus(editor, contains: "Not calibrated")
        assertHint(editor, contains: "Drag the outline")
        XCTAssertFalse(editor.backButton.exists, "A2: the court page is about the court alone")
        checkpoint("A2", "court page just opened")
        try report("A2")
    }

    // MARK: - B and C. Court, then net, by hand

    func testBC_CourtAndNetByHand() {
        openVideoScreen()
        var editor = openCourtPage()

        checkpoint("B0", "court page opened: zoomed out, the outline on the picture")
        // B6 comes first on this recording: its near corners are out of the picture.
        fitCourt(editor) { checkpoint("B6", "near corners dragged to where the court's are, outside the frame") }
        assertStatus(editor, contains: "Not saved")
        checkpoint("B1", "the outline fitted to the court")

        // B2: drag a point (the loupe shows only while a finger is down — a person checks that on a phone).
        editor.drag(fromX: Marks.court[4].x, y: Marks.court[4].y, toX: Marks.court[4].x - 0.03, y: Marks.court[4].y + 0.03)
        checkpoint("B2", "far-left corner dragged a little left and up")
        editor.drag(fromX: Marks.court[4].x - 0.03, y: Marks.court[4].y + 0.03, toX: Marks.court[4].x, y: Marks.court[4].y)

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

        // B7: a hidden corner is a best guess. A tap on a corner selects it.
        editor.tapFrame(x: Marks.court[4].x, y: Marks.court[4].y)
        XCTAssertTrue(editor.hiddenToggle.waitForExistence(timeout: 3), "B7: the selected corner offers Hidden — my best guess")
        editor.hiddenToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        checkpoint("B7", "far-left marked hidden, dashed ring")

        // B8: a centre-line point slides along its sideline, wherever the finger goes.
        editor.drag(fromX: Marks.court[2].x, y: Marks.court[2].y, toX: Marks.court[2].x - 0.06, y: Marks.court[2].y - 0.12)
        checkpoint("B8", "left centre-line point dragged straight down and a little left: it slid down its sideline")

        // B9: skipping the page keeps what was placed as a draft.
        process.setupSkipButton.tap()
        editor = page("Net")
        checkpoint("B9a", "court page skipped, net page showing")
        editor.close()
        editor = openCourtPage()
        assertHint(editor, contains: "Drag a corner or a line")
        assertStatus(editor, contains: "Draft")
        checkpoint("B9b", "setup started again, the draft court where it was")

        // B10
        XCTAssertEqual(editor.confirmButton.label, "Confirm court")
        editor.confirmButton.tap()
        editor = page("Net")
        assertStatus(editor, contains: "Court confirmed")
        checkpoint("B10", "court confirmed, net page showing")

        // C1
        placeNet(editor) {
            // C3: three corners are kept on screen but the net is not saved.
            editor.closeButton.tap()
            app.buttons["Save draft and close"].tap()
            assertStatus(editor, contains: "The net needs all four corners")
            checkpoint("C3", "cancelled with three net corners: not saved, the page stays")
            // Skip does not drop them without a word either.
            process.setupSkipButton.tap()
            XCTAssertTrue(app.buttons["Go on without them"].waitForExistence(timeout: 3), "C3: skipping with a net that can't be saved asks first")
            checkpoint("C3b", "skip with three net corners asks before dropping them")
            // The system draws the dialog's way back itself (as "Cancel", or by a tap outside it).
            let back = app.buttons.matching(NSPredicate(format: "(label == %@ OR label == %@) AND identifier != %@", "Keep editing", "Cancel", "calibration.close")).firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 3))
            back.tap()
            XCTAssertTrue(app.buttons["Go on without them"].waitForNonExistence(timeout: 3))
            XCTAssertTrue(process.setupProgress.label.hasPrefix("Net,"), "C3: keep editing stays on the Net page")
        }
        checkpoint("C1", "net's four corners tapped, court dimmed")

        // C5: Back takes the last corner away and asks for it again.
        editor.backButton.tap()
        assertHint(editor, contains: "bottom-left")
        checkpoint("C5", "Back: the fourth corner is asked for again")
        editor.tapFrame(x: Marks.net[3].x, y: Marks.net[3].y)
        assertHint(editor, contains: "Is this the net?")

        // C2
        editor.showCourtButton.tap()
        checkpoint("C2a", "court hidden")
        editor.showCourtButton.tap()
        editor.showNetButton.tap()
        checkpoint("C2b", "net hidden")
        editor.showNetButton.tap()

        // C4: the last page done, the run starts; the marks are there the next time.
        editor.confirmButton.tap()
        XCTAssertTrue(process.cancelButton.waitForExistence(timeout: 15), "C4: confirming the net starts the run")
        checkpoint("C4a", "net confirmed, the run started")
        stopRun()
        editor = openCourtPage()
        assertStatus(editor, contains: "Court and net confirmed")
        XCTAssertEqual(editor.confirmButton.label, "Continue", "C4: a court confirmed and untouched only needs Continue")
        checkpoint("C4b", "setup started again: court and net confirmed, Continue")
    }

    // MARK: - B11. A court that can't be one

    func testB11_AnOutlineThatCrossesItself() {
        openVideoScreen()
        let editor = openCourtPage()
        // The far-left corner is dragged across to the right of the far-right one: the outline crosses itself.
        editor.drag(fromX: Outline.farLeft.x, y: Outline.farLeft.y, toX: 0.85, y: Outline.farLeft.y)
        checkpoint("B11a", "the far-left corner dragged past the far-right one")
        editor.confirmButton.tap()
        assertStatus(editor, contains: "Draft")
        XCTAssertTrue(process.setupProgress.label.hasPrefix("Court,"), "B11: a court that can't be confirmed stays on its page")
        checkpoint("B11b", "confirm refused with the reason, kept as a draft")
    }

    // MARK: - D. Later edits

    func testD_LaterEdits() {
        var editor = openCourtPageWithConfirmedCourtAndNet()
        let farLeft = Marks.court[4]

        // D1: an edit after confirming, dropped on cancelling.
        editor.drag(fromX: farLeft.x, y: farLeft.y, toX: farLeft.x - 0.04, y: farLeft.y + 0.02)
        assertStatus(editor, contains: "Not saved")
        assertStatus(editor, contains: "Court and net confirmed")
        XCTAssertEqual(editor.confirmButton.label, "Confirm court", "D1: an edited court asks to be confirmed again")
        checkpoint("D1a", "far-left moved: not saved, status still confirmed")
        editor.close(saving: false)
        editor = openCourtPage()
        XCTAssertEqual(editor.confirmButton.label, "Continue", "D1: cancelled without saving, the confirmed court is untouched")
        checkpoint("D1b", "cancelled without saving and started again, the confirmed court unchanged")

        // D2: the same edit, confirmed.
        editor.drag(fromX: farLeft.x, y: farLeft.y, toX: farLeft.x - 0.04, y: farLeft.y + 0.02)
        editor.confirmButton.tap()
        editor = page("Net")
        assertStatus(editor, contains: "Court and net confirmed")
        checkpoint("D2", "far-left moved and the court confirmed again, net page showing")
        editor.close()

        // D3: starting over keeps the confirmed court until another is confirmed.
        editor = openCourtPage()
        editor.more("Start the court over")
        assertHint(editor, contains: "Drag the outline")
        checkpoint("D3a", "court started over: the outline again")
        editor.close()
        editor = openCourtPage()
        assertHint(editor, contains: "Drag a corner or a line")
        XCTAssertEqual(editor.confirmButton.label, "Continue", "D3: the earlier confirmed court stands")
        checkpoint("D3b", "started again, the earlier confirmed court is shown")

        // D4: the court's type is kept.
        editor.more("Surface", "Beach")
        editor.more("Players a side", "2 v 2")
        editor.close()
        editor = openCourtPage()
        // The menu's first level doesn't show what is chosen; each submenu ticks it. Picking the ticked item
        // again closes the menu and changes nothing.
        for (picker, kept, step) in [("Surface", "Beach", "D4a"), ("Players a side", "2 v 2", "D4b")] {
            editor.moreButton.tap()
            app.buttons[picker].firstMatch.tap()
            let item = app.buttons[kept].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "D4: \(picker) offers \(kept)")
            checkpoint(step, "started again, \(picker) has \(kept) ticked")
            XCTAssertTrue(item.isSelected, "D4: \(kept) is still chosen for \(picker) after cancelling and starting again")
            item.tap()
        }
    }

    // MARK: - E. Frames and camera views

    func testE_FramesAndCameraViews() {
        var editor = openCourtPageWithConfirmedCourtAndNet()

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
        assertHint(editor, contains: "Drag a corner or a line")
        checkpoint("E1b", "slider dragged to the middle of the video")

        // E2: the camera moved here.
        editor.more("Camera changed here", "Start from these marks")
        assertStatus(editor, contains: "Camera view 2 of 2")
        assertStatus(editor, contains: "Needs review")
        assertHint(editor, contains: "Drag a corner or a line")
        checkpoint("E2", "camera view 2 of 2, marks carried over but not confirmed")
        editor.close()

        // E3: before the split is view 1, still confirmed.
        editor = openCourtPage()
        editor.positionSlider.adjust(toNormalizedSliderPosition: 0.8)
        assertStatus(editor, contains: "Camera view 2 of 2")
        editor.positionSlider.adjust(toNormalizedSliderPosition: 0.15)
        assertStatus(editor, contains: "Camera view 1 of 2")
        XCTAssertEqual(editor.confirmButton.label, "Continue", "E3: view 1's court is still confirmed")
        checkpoint("E3", "scrubbed back before the split, view 1 of 2 with its confirmed marks")

        // E4: a part of the video that is not a stable court view takes no marks.
        editor.positionSlider.adjust(toNormalizedSliderPosition: 0.8)
        assertStatus(editor, contains: "Camera view 2 of 2")
        let farRight = Marks.court[5]
        editor.more("Not a stable court view")
        XCTAssertTrue(editor.notStableBanner.waitForExistence(timeout: 3), "E4: a banner says this is not a stable court view")
        assertHint(editor, contains: "Nothing is marked")
        editor.drag(fromX: farRight.x, y: farRight.y, toX: farRight.x + 0.05, y: farRight.y + 0.04)
        XCTAssertFalse(editor.status.label.contains("Not saved"), "E4: a drag moved nothing: \(editor.status.label)")
        checkpoint("E4a", "not a stable court view, a drag moved nothing")
        app.buttons["It is a stable view"].tap()
        XCTAssertTrue(editor.notStableBanner.waitForNonExistence(timeout: 3), "E4: the banner goes")
        editor.drag(fromX: farRight.x, y: farRight.y, toX: farRight.x + 0.05, y: farRight.y + 0.04)
        assertStatus(editor, contains: "Not saved")
        checkpoint("E4b", "stable again, the drag moves the corner")
    }

    // MARK: - F. Orientation and size

    func testF2_Landscape() {
        let editor = openCourtPageWithConfirmedCourtAndNet()
        checkpoint("F2a", "upright, before turning")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(editor.confirmButton.waitForExistence(timeout: 5))
        assertHint(editor, contains: "Drag a corner or a line")
        checkpoint("F2b", "turned to landscape, picture left and controls right")
        let farLeft = Marks.court[4]
        editor.drag(fromX: farLeft.x, y: farLeft.y, toX: farLeft.x - 0.04, y: farLeft.y + 0.02)
        assertStatus(editor, contains: "Not saved")
        checkpoint("F2c", "far-left dragged in landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(editor.confirmButton.waitForExistence(timeout: 5))
        checkpoint("F2d", "turned back upright")
    }

    func testF3_LargestText() throws {
        openVideoScreen()
        checkpoint("F3a", "video screen at the largest text size")
        try report("F3 video screen")
        let editor = openCourtPage()
        checkpoint("F3b", "court page at the largest text size")
        try report("F3 court page")
        let controls: [(String, XCUIElement)] = [
            ("Cancel", editor.closeButton), ("More", editor.moreButton),
            ("Show the court", editor.showCourtButton), ("Show the net", editor.showNetButton), ("Move all", editor.moveAllToggle),
            ("Zoom out", app.buttons["Zoom out"]), ("Fit the picture", app.buttons["Fit the picture"]), ("Zoom in", app.buttons["Zoom in"]),
            ("Back one frame", app.buttons["Back one frame"]),
            ("Forward one frame", app.buttons["Forward one frame"]), ("Position slider", editor.positionSlider),
            ("Skip", process.setupSkipButton), ("Confirm", editor.confirmButton)
        ]
        // Nothing is drawn over anything else.
        let stacked: [(String, XCUIElement)] = [
            ("the instruction", editor.hint), ("the frame's time", editor.clock),
            ("the position slider", editor.positionSlider), ("Skip", process.setupSkipButton)
        ]
        for (above, below) in zip(stacked, stacked.dropFirst()) {
            XCTAssertLessThanOrEqual(above.1.frame.maxY, below.1.frame.minY + 1, "F3: \(above.0) runs into \(below.0)")
        }
        var outOfReach = controls.filter { !$0.1.isHittable }.map(\.0)
        if !outOfReach.isEmpty {
            // The controls scroll under the picture.
            editor.hint.swipeUp()
            checkpoint("F3c", "court page controls scrolled up")
            outOfReach = controls.filter { outOfReach.contains($0.0) && !$0.1.isHittable }.map(\.0)
        }
        XCTAssertTrue(outOfReach.isEmpty, "F3: not reachable at the largest text size: \(outOfReach.joined(separator: ", "))")
    }

    // MARK: - The setup pages before a run: trim, camera position, court, net

    func testSetupPagesBeforeProcessing() {
        openVideoScreen()
        process.startButton.tap()
        let step = process.setupProgress

        XCTAssertTrue(process.setupSkipButton.waitForExistence(timeout: 10), "Start opens the setup pages")
        XCTAssertEqual(step.label, "Trim, Step 1 of 4")
        checkpoint("P1", "trim page")
        process.setupSkipButton.tap()

        let continueButton = app.buttons["process.cameraSetupContinue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5), "The camera page follows the trim page")
        XCTAssertEqual(step.label, "Camera position, Step 2 of 4")
        XCTAssertTrue(app.descendants(matching: .any)["process.setupSkipRisk"].label.hasPrefix("Skip at your own risk"), "The camera page says what skipping costs")
        checkpoint("P2", "camera position page")
        continueButton.tap()

        var editor = page("Court")
        XCTAssertEqual(step.label, "Court, Step 3 of 4")
        XCTAssertFalse(app.descendants(matching: .any)["process.setupSkipRisk"].exists, "The court page makes no claim: a run does not read the court")
        checkpoint("P3a", "court page, nothing marked")
        fitCourt(editor)
        checkpoint("P3b", "court page, court marked")
        editor.confirmButton.tap()

        editor = page("Net")
        XCTAssertEqual(step.label, "Net, Step 4 of 4")
        assertHint(editor, contains: "top-left")
        let risk = app.descendants(matching: .any)["process.setupSkipRisk"]
        XCTAssertTrue(risk.exists && risk.label.contains("accuracy drops"), "The net page says what skipping costs while no net is confirmed")
        checkpoint("P4a", "net page, the confirmed court dimmed behind")
        placeNet(editor)
        checkpoint("P4b", "net page, net marked")
        editor.confirmButton.tap()

        XCTAssertTrue(process.cancelButton.waitForExistence(timeout: 15), "Confirming the net starts the run")
        checkpoint("P5", "processing started after the last page")
        stopRun()
    }

    // MARK: - Recalibrate: a processed video's camera, court and net set again, its rallies found again

    func testR_RecalibrateAProcessedVideo() {
        // A real run with nothing set up, so the video has rallies and the balls its run found.
        openVideoScreen()
        process.startProcessing()
        XCTAssertTrue(process.doneButton.waitForExistence(timeout: 600), "The run finishes")
        XCTAssertFalse(app.alerts.firstMatch.exists, "The run finishes without an error")
        process.doneButton.tap()

        // From the library: the processed video's menu leads to its screen.
        let card = app.buttons["View Processed Rallies"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "The library shows the video as processed")
        card.press(forDuration: 1.5)
        let entry = app.buttons["process.recalibrateEntry"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "A processed video's menu offers Recalibrate")
        checkpoint("R0", "processed video's menu")
        entry.tap()
        XCTAssertTrue(process.viewRalliesButton.waitForExistence(timeout: 15), "A processed video offers its rallies")
        XCTAssertTrue(process.recalibrateButton.isEnabled, "A video whose run kept its balls can be recalibrated")
        XCTAssertFalse(app.descendants(matching: .any)["process.recalibrateUnavailable"].exists)
        checkpoint("R1", "processed video, Recalibrate offered")

        process.recalibrateButton.tap()
        let confirm = app.buttons["process.recalibrateConfirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Recalibrate says what it clears before it starts")
        checkpoint("R2", "what recalibrating clears")
        confirm.tap()

        let step = process.setupProgress
        let continueButton = app.buttons["process.cameraSetupContinue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 10), "Recalibrate opens on the camera page: there is no trim page")
        XCTAssertEqual(step.label, "Camera position, Step 1 of 3")
        continueButton.tap()

        var editor = page("Court")
        XCTAssertEqual(step.label, "Court, Step 2 of 3")
        fitCourt(editor)
        editor.confirmButton.tap()

        editor = page("Net")
        XCTAssertEqual(step.label, "Net, Step 3 of 3")
        placeNet(editor)
        editor.confirmButton.tap()

        // No run: the rallies are found again from the saved balls, and the screen is the processed video's again.
        XCTAssertTrue(process.recalibrateButton.waitForExistence(timeout: 120), "The rallies are found again and the video's screen is back")
        XCTAssertFalse(process.cancelButton.exists, "Recalibrating starts no processing run")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Recalibrating ends without an error")
        XCTAssertTrue(process.viewRalliesButton.isEnabled, "The new rallies can be opened")
        checkpoint("R3", "after recalibrating under the confirmed net")
    }
}
