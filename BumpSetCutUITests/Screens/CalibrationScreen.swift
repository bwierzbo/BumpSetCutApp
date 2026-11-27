//
//  CalibrationScreen.swift
//  BumpSetCutUITests
//
//  Page object for the court page and the net page of the setup before processing. Points are given the way the editor stores them: fractions of the
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
    var confirmButton: XCUIElement { app.buttons["calibration.confirm"] }
    var moreButton: XCUIElement { app.buttons["More"] }
    var moveAllToggle: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Dragging moves the whole shape")).firstMatch
    }
    var showCourtButton: XCUIElement { app.buttons["Show the court"] }
    var showNetButton: XCUIElement { app.buttons["Show the net"] }
    var hiddenToggle: XCUIElement { app.switches["Hidden — my best guess"] }
    var positionSlider: XCUIElement { app.sliders["Position in the video"] }
    /// The frame's time, "m:ss.hh".
    var clock: XCUIElement { app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", #"\d+:\d{2}\.\d{2}"#)).firstMatch }
    var notStableBanner: XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "This part of the video is marked as not a stable court view")).firstMatch
    }

    /// The frame's time in seconds, read off the screen.
    var seconds: Double {
        let parts = clock.label.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]), let rest = Double(parts[1]) else { return .nan }
        return minutes * 60 + rest
    }

    /// Picks an item of the ⋯ menu, through a submenu when `path` has more than one name.
    func more(_ path: String...) {
        moreButton.tap()
        for name in path {
            let item = app.buttons[name].firstMatch
            _ = item.waitForExistence(timeout: 3)
            item.tap()
        }
    }

    func chip(_ name: String) -> XCUIElement { app.buttons[name] }

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

    /// Cancels the setup from this page. If it asks, what was changed is kept as a draft, or dropped when `saving` is false.
    func close(saving: Bool = true) {
        closeButton.tap()
        let answer = app.buttons[saving ? "Save draft and close" : "Close without saving"]
        if answer.waitForExistence(timeout: 1.5) { answer.tap() }
    }
}
