//
//  ScreenshotTests.swift
//  BumpSetCutUITests
//
//  App Store screenshot capture. NOT part of the regression suite — run explicitly:
//    xcodebuild test ... -only-testing:BumpSetCutUITests/ScreenshotTests \
//      -resultBundlePath shots.xcresult
//  then export attachments:
//    xcrun xcresulttool export attachments --path shots.xcresult --output-path out/
//
//  Uses the 5plusrallies fixture (video + metadata) when present in the test
//  bundle for the rally-player hero shots; without it, only the screens that
//  need no footage are captured.
//

import XCTest

final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func shoot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func settle(_ seconds: UInt32 = 2) { sleep(seconds) }

    // MARK: - Onboarding (no footage needed)

    func testCaptureOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--reset-onboarding", "--clear-library"]
        app.launch()

        let onboarding = OnboardingScreen(app: app)
        guard onboarding.nextButton.waitForExistence(timeout: 10) else { return }
        settle()
        shoot("onboarding_1")

        for index in 2...4 {
            if onboarding.nextButton.exists {
                onboarding.nextButton.tap()
                settle(1)
                shoot("onboarding_\(index)")
            } else if onboarding.getStartedButton.exists {
                settle(1)
                shoot("onboarding_\(index)")
                break
            }
        }
    }

    // MARK: - Core screens (uses rally fixture when available)

    func testCaptureCoreScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--skip-onboarding", "--clear-library"]

        let bundle = Bundle(for: type(of: self))
        let videoURL = bundle.url(forResource: "5plusrallies", withExtension: "mov")
        let metadataURL = bundle.url(forResource: "5plusrallies_metadata", withExtension: "json")
        let hasRallyFixture = videoURL != nil && metadataURL != nil
        if let videoURL, let metadataURL {
            app.launchEnvironment["TEST_VIDEO_PATH"] = videoURL.path
            app.launchEnvironment["TEST_METADATA_PATH"] = metadataURL.path
        }
        app.launch()

        // 1. Home
        let home = HomeScreen(app: app)
        _ = home.viewLibraryButton.waitForExistence(timeout: 10)
        settle()
        shoot("home")

        // 2. Feed sign-in gate (branding shot)
        app.tabBars.buttons["Feed"].tap()
        settle(1)
        shoot("feed_gate")
        app.tabBars.buttons["Home"].tap()
        settle(1)

        // 3. Library
        guard home.viewLibraryButton.waitForExistence(timeout: 5) else { return }
        home.viewLibraryButton.tap()
        settle()
        shoot("library")

        guard hasRallyFixture else { return }

        // 4. Rally player (pre-processed video card offers "View Rallies")
        let viewRallies = app.buttons["View Rallies"]
        guard viewRallies.waitForExistence(timeout: 5) else { return }
        viewRallies.tap()

        let player = RallyPlayerScreen(app: app)
        guard player.rallyCounter.waitForExistence(timeout: 10) else { return }
        settle(3) // first frame rendered, overlay visible
        shoot("rally_player")

        // 5. Trim mode (long-press enters trim)
        app.windows.firstMatch.press(forDuration: 0.8)
        settle(2)
        shoot("rally_trim")
    }

    // MARK: - Paywall (App Store subscription review screenshot)

    /// Requires the scheme's StoreKit configuration so the $4.99 product loads.
    func testCapturePaywall() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--skip-onboarding", "--clear-library", "--force-free"]
        app.launch()

        let home = HomeScreen(app: app)
        guard home.settingsButton.waitForExistence(timeout: 10) else { return }
        home.settingsButton.tap()

        let upgrade = app.buttons["Upgrade to Pro"]
        var swipes = 0
        while !upgrade.isHittable && swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        guard upgrade.waitForExistence(timeout: 5) else { return }
        upgrade.tap()

        // Wait for the StoreKit product price to render
        _ = app.buttons["Subscribe Now"].waitForExistence(timeout: 10)
        settle(2)
        shoot("paywall")
    }
}
