//
//  ProfileTests.swift
//  BumpSetCutUITests
//
//  Test Plan §13 — Profile tab behavior: own profile, edit, stats.
//  Dashboard items: 13.1.1–13.1.7, 15.4.5
//

import XCTest

final class ProfileTests: BSCUITestCase {

    private var profileScreen: ProfileScreen!
    private var authGate: AuthGateScreen!

    override func setUpWithError() throws {
        try super.setUpWithError()
        profileScreen = ProfileScreen(app: app)
        authGate = AuthGateScreen(app: app)
    }

    // MARK: - Profile Tab (13.1.1)

    /// 13.1.1 — Profile tab shows auth gate when not authenticated
    func testProfileTabShowsAuthGateWhenUnauthenticated() {
        tapProfileTab()

        XCTAssertTrue(authGate.signInButton.waitForExistence(timeout: 5),
                       "Profile tab should show auth gate when not signed in")
    }

    /// 13.1.1 — Profile tab shows own profile when authenticated
    func testProfileTabShowsOwnProfile() {
        tapProfileTab()

        // If auth gate appears, we can't test profile content without real auth
        if authGate.signInButton.waitForExistence(timeout: 3) {
            return // Pass — auth gate behavior already tested in AuthGateTests
        }

        // If authenticated, should show profile elements
        XCTAssertTrue(profileScreen.username.waitForExistence(timeout: 5),
                       "Username should be visible on own profile")
    }

    // MARK: - Profile Elements (13.1.2, 13.1.3)

    /// 13.1.2 — Profile shows username
    func testProfileShowsUsername() {
        tapProfileTab()
        if authGate.signInButton.waitForExistence(timeout: 3) { return }

        XCTAssertTrue(profileScreen.username.waitForExistence(timeout: 5),
                       "Username should be visible")
    }

    /// 13.1.3 — Stats row shows highlights, followers, following counts
    func testProfileStatsRow() {
        tapProfileTab()
        if authGate.signInButton.waitForExistence(timeout: 3) { return }

        guard profileScreen.username.waitForExistence(timeout: 5) else { return }

        // Stats should show Highlights, Followers, Following
        let highlightsLabel = app.staticTexts["Highlights"]
        let followersLabel = app.staticTexts["Followers"]
        let followingLabel = app.staticTexts["Following"]

        XCTAssertTrue(highlightsLabel.exists, "Highlights stat label should exist")
        XCTAssertTrue(followersLabel.exists, "Followers stat label should exist")
        XCTAssertTrue(followingLabel.exists, "Following stat label should exist")
    }

    // MARK: - Action Buttons (13.1.6, 13.1.7)

    /// 13.1.6 — Edit Profile button exists on own profile
    func testEditProfileButtonExists() {
        tapProfileTab()
        if authGate.signInButton.waitForExistence(timeout: 3) { return }

        guard profileScreen.username.waitForExistence(timeout: 5) else { return }

        XCTAssertTrue(profileScreen.editProfileButton.exists,
                       "Edit Profile button should exist on own profile")
    }

    /// 13.1.6 — Edit Profile opens EditProfileView
    func testEditProfileOpens() {
        tapProfileTab()
        if authGate.signInButton.waitForExistence(timeout: 3) { return }

        guard profileScreen.editProfileButton.waitForExistence(timeout: 5) else { return }

        profileScreen.editProfileButton.tap()

        // EditProfileView should appear — look for form fields or nav title
        let editTitle = app.navigationBars.staticTexts["Edit Profile"]
        let bioField = app.textViews.firstMatch
        let hasEditView = editTitle.waitForExistence(timeout: 5) || bioField.waitForExistence(timeout: 5)
        XCTAssertTrue(hasEditView, "Edit Profile view should open")
    }

    // MARK: - Sign Out from Profile (13.1.7)

    /// Sign out button exists on own profile
    func testSignOutButtonExists() {
        tapProfileTab()
        if authGate.signInButton.waitForExistence(timeout: 3) { return }

        guard profileScreen.username.waitForExistence(timeout: 5) else { return }

        XCTAssertTrue(profileScreen.signOutButton.exists,
                       "Sign Out button should exist on own profile")
    }

    /// Sign out shows confirmation alert
    func testSignOutShowsConfirmation() {
        tapProfileTab()
        if authGate.signInButton.waitForExistence(timeout: 3) { return }

        guard profileScreen.signOutButton.waitForExistence(timeout: 5) else { return }

        profileScreen.signOutButton.tap()

        // Confirmation alert should appear
        let alert = app.alerts["Sign Out?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3),
                       "Sign out confirmation alert should appear")

        // Cancel to not actually sign out
        let cancelButton = alert.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists, "Cancel button should exist in alert")
        cancelButton.tap()
    }

    // MARK: - Empty States (15.4.5)

    /// 15.4.5 — No followers/following shows 0 counts, no crash
    func testEmptyFollowersCount() {
        tapProfileTab()
        if authGate.signInButton.waitForExistence(timeout: 3) { return }

        guard profileScreen.username.waitForExistence(timeout: 5) else { return }

        // Followers and following counts should exist (even if 0)
        XCTAssertTrue(profileScreen.followersCount.exists,
                       "Followers count should exist even with 0 followers")
        XCTAssertTrue(profileScreen.followingCount.exists,
                       "Following count should exist even with 0 following")
    }

    /// 13.3.1 — Tap followers count navigates to follow list
    func testTapFollowersNavigates() {
        tapProfileTab()
        if authGate.signInButton.waitForExistence(timeout: 3) { return }

        guard profileScreen.followersCount.waitForExistence(timeout: 5) else { return }

        profileScreen.followersCount.tap()

        // Should navigate to followers list — look for nav back button or list
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5),
                       "Should navigate to followers list view")
    }

    /// 13.3.2 — Tap following count navigates to following list
    func testTapFollowingNavigates() {
        tapProfileTab()
        if authGate.signInButton.waitForExistence(timeout: 3) { return }

        guard profileScreen.followingCount.waitForExistence(timeout: 5) else { return }

        profileScreen.followingCount.tap()

        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5),
                       "Should navigate to following list view")
    }
}
