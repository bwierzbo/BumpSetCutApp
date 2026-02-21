//
//  SettingsScreen.swift
//  BumpSetCutUITests
//
//  Page object for the Settings screen.
//

import XCTest

struct SettingsScreen {
    let app: XCUIApplication

    var doneButton: XCUIElement {
        app.buttons["settings.done"]
    }

    var analyticsToggle: XCUIElement {
        app.descendants(matching: .any)["settings.analytics"]
    }

    var thoroughAnalysisToggle: XCUIElement {
        app.descendants(matching: .any)["settings.thoroughAnalysis"]
    }

    var themeLightButton: XCUIElement {
        app.descendants(matching: .any)["settings.theme.light"]
    }

    var themeDarkButton: XCUIElement {
        app.descendants(matching: .any)["settings.theme.dark"]
    }

    var themeSystemButton: XCUIElement {
        app.descendants(matching: .any)["settings.theme.system"]
    }

    var privacyPolicyButton: XCUIElement {
        app.descendants(matching: .any)["settings.privacyPolicy"]
    }

    var termsOfServiceButton: XCUIElement {
        app.descendants(matching: .any)["settings.termsOfService"]
    }

    var communityGuidelinesButton: XCUIElement {
        app.descendants(matching: .any)["settings.communityGuidelines"]
    }

    var appName: XCUIElement {
        app.descendants(matching: .any)["settings.appName"]
    }

    var appVersion: XCUIElement {
        app.descendants(matching: .any)["settings.appVersion"]
    }
}
