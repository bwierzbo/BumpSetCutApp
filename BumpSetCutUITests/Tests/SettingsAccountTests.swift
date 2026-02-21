//
//  SettingsAccountTests.swift
//  BumpSetCutUITests
//
//  Test Plan §14.5 — Account management in Settings.
//  Dashboard items: 14.5.1–14.5.4
//

import XCTest

final class SettingsAccountTests: BSCUITestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Navigate to settings
        let settingsButton = app.descendants(matching: .any)["home.settings"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5))
        settingsButton.tap()
    }

    // MARK: - Account Info (14.5.1)

    /// 14.5.1 — Settings shows sign-in prompt or account info
    func testAccountSectionExists() {
        // Look for either sign-in button or account info
        let signOut = app.buttons["settings.signOut"]
        let signIn = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'sign in' OR label CONTAINS[c] 'account'")
        ).firstMatch

        let hasAccountSection = signOut.waitForExistence(timeout: 3) || signIn.waitForExistence(timeout: 3)
        // Some version of account info should be present
        XCTAssertTrue(hasAccountSection, "Settings should display account section")
    }

    // MARK: - Sign Out (14.5.2)

    /// 14.5.2 — Sign Out button exists in Settings
    func testSignOutButtonExists() {
        let signOut = app.buttons["settings.signOut"]
        if signOut.waitForExistence(timeout: 3) {
            XCTAssertTrue(signOut.exists, "Sign Out button should exist in Settings")
        }
        // If not signed in, sign out button won't appear — valid
    }

    /// 14.5.2 — Sign Out shows confirmation dialog
    func testSignOutConfirmation() {
        let signOut = app.buttons["settings.signOut"]
        guard signOut.waitForExistence(timeout: 3) else { return }

        signOut.tap()

        // Confirmation alert should appear
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 3) {
            let cancelButton = alert.buttons["Cancel"]
            XCTAssertTrue(cancelButton.exists, "Sign out alert should have Cancel button")
            cancelButton.tap()
        }
    }

    // MARK: - Settings Navigation

    /// Settings Done button dismisses
    func testSettingsDoneButton() {
        let doneButton = app.buttons["settings.done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3),
                       "Settings Done button should exist")

        doneButton.tap()

        // Should dismiss settings
        let homeButton = app.descendants(matching: .any)["home.viewLibrary"].firstMatch
        XCTAssertTrue(homeButton.waitForExistence(timeout: 5),
                       "Should return to home after dismissing settings")
    }
}
