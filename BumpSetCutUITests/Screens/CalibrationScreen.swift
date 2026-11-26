//
//  CalibrationScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Court & Net editor. Points are given the way the editor stores them: fractions of the
//  upright frame, origin bottom-left, outside 0…1 for a corner that is out of the picture.
//

import XCTest

struct CalibrationScreen {
    let app: XCUIApplication
    /// The upright frame's width over its height.
    let frameAspect: CGFloat
    /// The editor's zoom, as this test has set it with the zoom buttons (the picture is not panned).
    var scale: CGFloat = 1

    static let zoomStep: CGFloat = 1.5

    var canvas: XCUIElement { app.descendants(matching: .any)["calibration.canvas"] }
    var status: XCUIElement { app.descendants(matching: .any)["calibration.status"] }
    var hint: XCUIElement { app.staticTexts["calibration.hint"] }
    var closeButton: XCUIElement { app.buttons["calibration.close"] }
    var saveDraftButton: XCUIElement { app.buttons["calibration.saveDraft"] }
    var confirmButton: XCUIElement { app.buttons["calibration.confirm"] }
    var moreButton: XCUIElement { app.buttons["More"] }
    var moveAllToggle: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Dragging moves the whole shape")).firstMatch
    }
    var showCourtButton: XCUIElement { app.buttons["Show the court"] }
    var showNetButton: XCUIElement { app.buttons["Show the net"] }
    var hiddenToggle: XCUIElement { app.switches["Hidden — my best guess"] }

    func chip(_ name: String) -> XCUIElement { app.buttons[name] }

    /// The Court / Net tab, whatever mark its title carries ("Court ✓", "Net ✓ edited").
    func tab(_ name: String) -> XCUIElement {
        app.segmentedControls.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    /// Where a frame point is on the screen at the current zoom.
    func coordinate(x: CGFloat, y: CGFloat) -> XCUICoordinate {
        let size = canvas.frame.size
        let height = min(size.width / frameAspect, size.height) * scale
        let width = height * frameAspect
        let px = (size.width - width) / 2 + x * width
        let py = (size.height - height) / 2 + (1 - y) * height
        return canvas.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: px, dy: py))
    }

    func tapFrame(x: CGFloat, y: CGFloat) { coordinate(x: x, y: y).tap() }

    func drag(fromX x0: CGFloat, y y0: CGFloat, toX x1: CGFloat, y y1: CGFloat) {
        coordinate(x: x0, y: y0).press(forDuration: 0.2, thenDragTo: coordinate(x: x1, y: y1), withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    mutating func zoomOut() { app.buttons["Zoom out"].tap(); scale /= Self.zoomStep }
    mutating func zoomIn() { app.buttons["Zoom in"].tap(); scale *= Self.zoomStep }
    mutating func fit() { app.buttons["Fit the picture"].tap(); scale = 1 }

    /// Closes the editor, keeping what was changed as a draft if it asks.
    func close() {
        closeButton.tap()
        let save = app.buttons["Save draft and close"]
        if save.waitForExistence(timeout: 1.5) { save.tap() }
    }
}
