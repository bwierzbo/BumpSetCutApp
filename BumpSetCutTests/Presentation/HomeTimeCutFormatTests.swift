//
//  HomeTimeCutFormatTests.swift
//  BumpSetCutTests
//
//  The Home "Time Cut" stat scales through units and must stay
//  locale-aware (unit abbreviations come from the formatter, not code).
//

import XCTest
@testable import BumpSetCut

@MainActor
final class HomeTimeCutFormatTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")
    private let deDE = Locale(identifier: "de_DE")

    func testScalesThroughUnitsInEnglish() {
        XCTAssertEqual(HomeViewModel.formatTimeCut(seconds: 45, locale: enUS), "45s")
        XCTAssertEqual(HomeViewModel.formatTimeCut(seconds: 38 * 60 + 12, locale: enUS), "38m")
        XCTAssertEqual(HomeViewModel.formatTimeCut(seconds: 2 * 3600 + 14 * 60, locale: enUS), "2h 14m")
        XCTAssertEqual(HomeViewModel.formatTimeCut(seconds: 3 * 86_400 + 4 * 3600, locale: enUS), "3d 4h")
        XCTAssertEqual(HomeViewModel.formatTimeCut(seconds: 365 * 86_400 + 23 * 86_400, locale: enUS), "1y 23d")
    }

    func testKeepsZeroLowerUnit() {
        XCTAssertEqual(HomeViewModel.formatTimeCut(seconds: 3 * 86_400, locale: enUS), "3d 0h")
    }

    func testUsesLocaleUnitAbbreviations() {
        XCTAssertEqual(HomeViewModel.formatTimeCut(seconds: 2 * 3600 + 14 * 60, locale: deDE), "2h 14min")
    }

    func testInvalidInputIsZero() {
        XCTAssertEqual(HomeViewModel.formatTimeCut(seconds: -5, locale: enUS), "0s")
        XCTAssertEqual(HomeViewModel.formatTimeCut(seconds: .nan, locale: enUS), "0s")
    }
}
