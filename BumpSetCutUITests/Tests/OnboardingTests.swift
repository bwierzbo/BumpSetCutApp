//
//  OnboardingTests.swift
//  BumpSetCutUITests
//
//  Test Plan §1.1 — Onboarding flow tests.
//

import XCTest

final class OnboardingTests: BSCUITestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        // Ensure clean state between tests
        let existing = XCUIApplication()
        existing.terminate()
        // Brief pause to let the process fully exit
        Thread.sleep(forTimeInterval: 0.5)

        app = XCUIApplication()
        // Reset onboarding so it appears
        app.launchArguments = ["--uitesting", "--reset-onboarding"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testOnboardingAppearsOnFreshLaunch() {
        let onboarding = OnboardingScreen(app: app)
        // First page should be visible
        XCTAssertTrue(onboarding.page(0).waitForExistence(timeout: 10))
    }

    func testNextButtonNavigatesThroughPages() {
        let onboarding = OnboardingScreen(app: app)
        XCTAssertTrue(onboarding.page(0).waitForExistence(timeout: 10))

        // Navigate through pages 0-3 using Next
        for pageIndex in 0..<4 {
            XCTAssertTrue(onboarding.page(pageIndex).exists, "Page \(pageIndex) should be visible")
            XCTAssertTrue(onboarding.nextButton.waitForExistence(timeout: 3))
            onboarding.nextButton.tap()
            // Brief wait for animation
            sleep(1)
        }

        // Page 4 (last page) should now be visible with "Get Started"
        XCTAssertTrue(onboarding.page(4).waitForExistence(timeout: 5))
        XCTAssertTrue(onboarding.getStartedButton.waitForExistence(timeout: 3))
    }

    func testSkipButtonDismissesOnboarding() {
        let onboarding = OnboardingScreen(app: app)
        XCTAssertTrue(onboarding.skipButton.waitForExistence(timeout: 10))

        onboarding.skipButton.tap()

        // Should now be on Home screen — tab bar should appear
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
    }

    func testGetStartedDismissesToHome() {
        let onboarding = OnboardingScreen(app: app)
        XCTAssertTrue(onboarding.nextButton.waitForExistence(timeout: 10))

        // Navigate to last page (5 pages total, need 4 taps)
        for i in 0..<4 {
            let nextBtn = onboarding.nextButton
            XCTAssertTrue(nextBtn.waitForExistence(timeout: 5), "Next button should exist on page \(i)")
            nextBtn.tap()
            // Wait for page transition animation to settle
            let nextPage = onboarding.page(i + 1)
            XCTAssertTrue(nextPage.waitForExistence(timeout: 5), "Page \(i + 1) should appear")
            // TabView page animation needs time to fully settle
            Thread.sleep(forTimeInterval: 0.5)
        }

        XCTAssertTrue(onboarding.getStartedButton.waitForExistence(timeout: 5))
        onboarding.getStartedButton.tap()

        // Should be on Home screen
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 10))
    }

    func testOnboardingDoesNotReappearAfterCompletion() {
        let onboarding = OnboardingScreen(app: app)
        XCTAssertTrue(onboarding.skipButton.waitForExistence(timeout: 10))

        // Dismiss onboarding
        onboarding.skipButton.tap()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))

        // Relaunch
        app.terminate()
        app.launchArguments = ["--uitesting"]  // No --reset-onboarding
        app.launch()

        // Tab bar should appear directly, no onboarding
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))
        // Onboarding skip button should NOT appear
        let skipButton = app.descendants(matching: .any)["onboarding.skip"]
        XCTAssertFalse(skipButton.waitForExistence(timeout: 2))
    }
}
