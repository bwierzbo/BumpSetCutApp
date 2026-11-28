//
//  FootageSharingDefaultTests.swift
//  BumpSetCutTests
//
//  Footage sharing is on by default (D-046): everyone the default has not reached yet is switched on, except a
//  person who turned sharing off themselves.
//

import XCTest
@testable import BumpSetCut

@MainActor
final class FootageSharingDefaultTests: XCTestCase {

    private func switchedOn(stored: Bool, consent: String, testerDefault: Bool) -> Bool {
        AppSettings.sharesFootageByDefault(storedSwitch: stored, consentVersion: consent, testerDefaultWasApplied: testerDefault)
    }

    func testANewInstallAndAPersonWhoNeverAnsweredAreSwitchedOn() {
        XCTAssertTrue(switchedOn(stored: false, consent: "", testerDefault: false))
    }

    func testAPersonWhoAgreedAndThenTurnedItOffStaysOff() {
        XCTAssertFalse(switchedOn(stored: false, consent: FlywheelConsent.currentVersion, testerDefault: false))
        XCTAssertFalse(switchedOn(stored: false, consent: "1.0", testerDefault: false))
    }

    func testATesterWhoTurnedTheTesterDefaultOffStaysOff() {
        XCTAssertFalse(switchedOn(stored: false, consent: FlywheelConsent.testerDefault, testerDefault: true))
        XCTAssertFalse(switchedOn(stored: false, consent: "", testerDefault: true))
    }

    /// Their switch was never turned off by them: the app stopped honouring the earlier consent.
    func testAPersonSwitchedOffOnlyByTheChangedConsentIsSwitchedOn() {
        XCTAssertTrue(switchedOn(stored: true, consent: "1.0", testerDefault: false))
    }

    func testTheDefaultIsAConsentInForceAndIsNotTheSheets() {
        XCTAssertTrue(FlywheelConsent.inForce.contains(FlywheelConsent.defaultOn))
        XCTAssertTrue(FlywheelConsent.inForce.contains(FlywheelConsent.testerDefault))
        XCTAssertNotEqual(FlywheelConsent.defaultOn, FlywheelConsent.currentVersion)
        XCTAssertFalse(FlywheelConsent.inForce.contains("1.0"))
    }

    func testTheOnboardingPagesSayFootageIsSharedBeforeTheLastOne() throws {
        let pages = OnboardingPage.allPages
        let index = try XCTUnwrap(pages.firstIndex { $0.kind == .footageSharing })
        XCTAssertEqual(pages.filter { $0.kind == .footageSharing }.count, 1)
        XCTAssertLessThan(index, pages.count - 1)
        XCTAssertTrue(pages[index].kind.isChoice)
    }
}
