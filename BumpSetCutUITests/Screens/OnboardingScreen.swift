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

    func page(_ index: Int) -> XCUIElement {
        app.descendants(matching: .any)["onboarding.page.\(index)"]
    }
}
