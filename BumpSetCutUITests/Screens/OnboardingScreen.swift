//
//  OnboardingScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Onboarding flow.
//

import XCTest

struct OnboardingScreen {
    let app: XCUIApplication

    var skipButton: XCUIElement {
        app.descendants(matching: .any)["onboarding.skip"]
    }

    var nextButton: XCUIElement {
        app.descendants(matching: .any)["onboarding.next"]
    }

    var getStartedButton: XCUIElement {
        app.descendants(matching: .any)["onboarding.getStarted"]
    }

    /// "Don't Share", on the footage-sharing page.
    var dontShareButton: XCUIElement {
        app.descendants(matching: .any)["onboarding.dontShare"]
    }

    /// From the footage-sharing page: answer it, then Get Started.
    func finishFromFootageSharing() {
        XCTAssertTrue(dontShareButton.waitForExistence(timeout: 5), "The footage-sharing page is showing")
        dontShareButton.tap()
        XCTAssertTrue(getStartedButton.waitForExistence(timeout: 5), "The last page follows the footage-sharing page")
        getStartedButton.tap()
    }

    func page(_ index: Int) -> XCUIElement {
        app.descendants(matching: .any)["onboarding.page.\(index)"]
    }
}
