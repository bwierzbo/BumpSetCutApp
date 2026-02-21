//
//  AuthGateTests.swift
//  BumpSetCutUITests
//
//  Test Plan §9 — Auth gate behavior: sign-in/sign-up forms, skip, session.
//  Dashboard items: 9.1.1–9.1.6, 9.2.4, 9.3.3
//

import XCTest

final class AuthGateTests: BSCUITestCase {

    private var authGate: AuthGateScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        authGate = AuthGateScreen(app: app)
    }

    // MARK: - Auth Gate Appearance (9.1.1)

    /// 9.1.1 — Feed tab shows auth gate with sign-in form
    func testFeedTabShowsAuthGateWithSignIn() {
        tapFeedTab()

        XCTAssertTrue(authGate.signInButton.waitForExistence(timeout: 5),
                       "Auth gate should show email sign-in button")
        XCTAssertTrue(authGate.joinTitle.exists,
                       "Auth gate should show 'Join the Community' title")
    }

    /// 9.1.1 — Profile tab shows auth gate
    func testProfileTabShowsAuthGate() {
        tapProfileTab()

        XCTAssertTrue(authGate.signInButton.waitForExistence(timeout: 5),
                       "Auth gate should appear on Profile tab")
    }

    // MARK: - Sign-In Form (9.1.2, 9.1.3)

    /// 9.1.2 — Sign-in form has email and password fields
    func testSignInFormFields() {
        tapFeedTab()
        XCTAssertTrue(authGate.signInButton.waitForExistence(timeout: 5))

        // Sign-in mode should show email and password fields
        XCTAssertTrue(authGate.emailField.exists, "Email field should exist in sign-in mode")
        XCTAssertTrue(authGate.passwordField.exists, "Password field should exist in sign-in mode")
    }

    /// 9.1.2 — Forgot password link visible in sign-in mode
    func testForgotPasswordVisible() {
        tapFeedTab()
        XCTAssertTrue(authGate.signInButton.waitForExistence(timeout: 5))

        XCTAssertTrue(authGate.forgotPasswordButton.exists,
                       "Forgot password button should be visible in sign-in mode")
    }

    // MARK: - Sign-Up Mode Toggle (9.1.4, 9.1.5)

    /// 9.1.4 — Toggle to sign-up mode shows additional fields
    func testToggleToSignUpMode() {
        tapFeedTab()
        XCTAssertTrue(authGate.signInButton.waitForExistence(timeout: 5))

        // Tap toggle to switch to sign-up mode
        authGate.toggleModeButton.tap()

        // Sign-up mode should show username and confirm password fields
        XCTAssertTrue(authGate.usernameField.waitForExistence(timeout: 3),
                       "Username field should appear in sign-up mode")
        XCTAssertTrue(authGate.confirmPasswordField.exists,
                       "Confirm password field should appear in sign-up mode")
    }

    /// 9.1.5 — Toggle back to sign-in mode hides extra fields
    func testToggleBackToSignInMode() {
        tapFeedTab()
        XCTAssertTrue(authGate.signInButton.waitForExistence(timeout: 5))

        // Go to sign-up, then back to sign-in
        authGate.toggleModeButton.tap()
        XCTAssertTrue(authGate.usernameField.waitForExistence(timeout: 3))

        authGate.toggleModeButton.tap()

        // Username and confirm password should disappear
        let usernamePredicate = NSPredicate(format: "exists == false")
        let usernameExpectation = XCTNSPredicateExpectation(
            predicate: usernamePredicate, object: authGate.usernameField
        )
        let result = XCTWaiter.wait(for: [usernameExpectation], timeout: 3)
        XCTAssertEqual(result, .completed, "Username field should disappear in sign-in mode")
    }

    // MARK: - Continue Without Account (9.3.1, 9.3.2, 9.3.3)

    /// 9.3.1 — Skip button exists
    func testContinueWithoutAccountOptionExists() {
        tapFeedTab()

        XCTAssertTrue(authGate.skipButton.waitForExistence(timeout: 5),
                       "Continue without account button should exist")
    }

    /// 9.3.2 — Skip dismisses auth gate and returns to Home
    func testSkipDismissesAuthGate() {
        tapFeedTab()

        XCTAssertTrue(authGate.skipButton.waitForExistence(timeout: 5))
        authGate.skipButton.tap()

        // Should navigate back to Home tab
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        XCTAssertTrue(tabBar.buttons["Home"].isSelected,
                       "Should return to Home tab after skipping auth")
    }

    /// 9.3.3 — Social features gated: feed tab still shows auth gate on revisit
    func testSocialFeaturesGatedAfterSkip() {
        tapFeedTab()
        XCTAssertTrue(authGate.skipButton.waitForExistence(timeout: 5))
        authGate.skipButton.tap()

        // Wait for home tab
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        // Try feed again — should still be gated
        tapFeedTab()
        XCTAssertTrue(authGate.signInButton.waitForExistence(timeout: 5),
                       "Feed should still show auth gate after skipping")
    }

    // MARK: - Sign Out (9.2.4) — tested from Settings

    /// 9.2.4 — Sign out button in Settings returns to unauthenticated state
    func testSignOutFromSettingsReturnsToAuthGate() {
        // Settings has a sign out button
        let settingsButton = app.descendants(matching: .any)["home.settings"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()

            let signOut = app.buttons["settings.signOut"]
            if signOut.waitForExistence(timeout: 3) {
                signOut.tap()

                // Accept confirmation if present
                let confirmButton = app.alerts.buttons["Sign Out"]
                if confirmButton.waitForExistence(timeout: 2) {
                    confirmButton.tap()
                }

                // Feed tab should now show auth gate
                tapFeedTab()
                XCTAssertTrue(authGate.signInButton.waitForExistence(timeout: 5),
                               "Should show auth gate after signing out")
            }
        }
    }

    // MARK: - Search Tab Access (unauthenticated)

    /// Search tab should be accessible without authentication
    func testSearchTabAccessibleWithoutAuth() {
        tapSearchTab()

        // Search should load without auth gate
        let searchField = app.searchFields.firstMatch
        let searchTitle = app.navigationBars["Search"]
        let hasSearch = searchField.waitForExistence(timeout: 5) || searchTitle.waitForExistence(timeout: 5)
        XCTAssertTrue(hasSearch, "Search tab should be accessible without authentication")
    }
}
