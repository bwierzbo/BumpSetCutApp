//
//  BSCUITestCase.swift
//  BumpSetCutUITests
//
//  Base class for all UI tests with common setup and helpers.
//

import XCTest

class BSCUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--skip-onboarding", "--clear-library"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Tab Navigation

    func tapHomeTab() {
        app.tabBars.buttons["Home"].tap()
    }

    func tapFeedTab() {
        app.tabBars.buttons["Feed"].tap()
    }

    func tapSearchTab() {
        app.tabBars.buttons["Search"].tap()
    }

    func tapProfileTab() {
        app.tabBars.buttons["Profile"].tap()
    }

    // MARK: - Element Helpers

    /// Wait for an element identified by accessibility ID to exist.
    @discardableResult
    func waitForElement(_ identifier: String, timeout: TimeInterval = 5) -> XCUIElement {
        let element = app.descendants(matching: .any)[identifier]
        let exists = element.waitForExistence(timeout: timeout)
        XCTAssertTrue(exists, "Element '\(identifier)' did not appear within \(timeout)s")
        return element
    }

    /// Wait for an element to disappear.
    func waitForElementToDisappear(_ identifier: String, timeout: TimeInterval = 5) {
        let element = app.descendants(matching: .any)[identifier]
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Element '\(identifier)' did not disappear within \(timeout)s")
    }

    /// Assert an element with the given accessibility ID exists.
    func assertExists(_ identifier: String, file: StaticString = #file, line: UInt = #line) {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 3), "Expected '\(identifier)' to exist", file: file, line: line)
    }

    /// Assert an element with the given accessibility ID does NOT exist.
    func assertNotExists(_ identifier: String, file: StaticString = #file, line: UInt = #line) {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertFalse(element.exists, "Expected '\(identifier)' to NOT exist", file: file, line: line)
    }
}
