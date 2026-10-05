//
//  PluralCatalogTests.swift
//  BumpSetCutTests
//
//  Counted strings are single interpolated keys whose English one/other
//  forms live in Localizable.xcstrings — these check the catalog actually
//  ships them (a missing variation would read "1 rallies found").
//

import XCTest
@testable import BumpSetCut

final class PluralCatalogTests: XCTestCase {
    private func localized(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: .main, locale: Locale(identifier: "en_US"))
    }

    func testSingleCountKeyUsesPluralVariations() {
        XCTAssertEqual(localized("\(1) rallies found"), "1 rally found")
        XCTAssertEqual(localized("\(3) rallies found"), "3 rallies found")
        XCTAssertEqual(localized("\(0) rallies found"), "0 rallies found")
    }

    func testTwoCountKeyPluralizesEachArgument() {
        XCTAssertEqual(localized("\(1) folders, \(1) videos"), "1 folder, 1 video")
        XCTAssertEqual(localized("\(2) folders, \(1) videos"), "2 folders, 1 video")
        XCTAssertEqual(localized("\(1) folders, \(5) videos"), "1 folder, 5 videos")
    }

    func testCountAfterAnotherArgument() {
        XCTAssertEqual(localized("\("Beach") folder, \(1) videos"), "Beach folder, 1 video")
        XCTAssertEqual(localized("\("Beach") folder, \(4) videos"), "Beach folder, 4 videos")
        XCTAssertEqual(
            localized("Folder '\("Beach")' contains \(1) videos. Please choose an option for handling them."),
            "Folder 'Beach' contains 1 video. Please choose an option for handling it."
        )
    }

    func testCountBeforeAnotherArgument() {
        XCTAssertEqual(
            localized("Found \(1) rallies in \("Finals"). Open BumpSetCut to watch them."),
            "Found 1 rally in Finals. Open BumpSetCut to watch them."
        )
        XCTAssertEqual(
            localized("Found \(7) rallies in \("Finals"). Open BumpSetCut to watch them."),
            "Found 7 rallies in Finals. Open BumpSetCut to watch them."
        )
    }

    func testSocialCounts() {
        XCTAssertEqual(localized("\(1) likes"), "1 like")
        XCTAssertEqual(localized("\(2) comments"), "2 comments")
        XCTAssertEqual(localized("\(1) votes · tap to vote"), "1 vote · tap to vote")
    }
}
