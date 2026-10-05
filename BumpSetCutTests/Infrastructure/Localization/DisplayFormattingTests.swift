//
//  DisplayFormattingTests.swift
//  BumpSetCutTests
//
//  The shared display formatters (Core/Utilities/DisplayFormatting.swift)
//  must follow the locale — digits, separators and unit words — instead of
//  hard-coding English formats.
//

import XCTest
@testable import BumpSetCut

final class DisplayFormattingTests: XCTestCase {
    private let enUS = Locale(identifier: "en_US")
    private let deDE = Locale(identifier: "de_DE")
    private let frFR = Locale(identifier: "fr_FR")

    // MARK: - Clock durations

    func testClockFormatMatchesMinuteSecondReadout() {
        XCTAssertEqual(TimeInterval(5).formattedClock(locale: enUS), "0:05")
        XCTAssertEqual(TimeInterval(65).formattedClock(locale: enUS), "1:05")
        XCTAssertEqual(TimeInterval(600).formattedClock(locale: enUS), "10:00")
        // Minutes keep counting past an hour, like the old "%d:%02d".
        XCTAssertEqual(TimeInterval(3725).formattedClock(locale: enUS), "62:05")
    }

    func testClockFormatDropsPartialSecondsAndGuardsBadInput() {
        XCTAssertEqual(TimeInterval(59.9).formattedClock(locale: enUS), "0:59")
        XCTAssertEqual(TimeInterval(-3).formattedClock(locale: enUS), "0:00")
        XCTAssertEqual(TimeInterval.nan.formattedClock(locale: enUS), "0:00")
        XCTAssertEqual(TimeInterval.infinity.formattedClock(locale: enUS), "0:00")
    }

    func testSpokenDurationUsesLocaleUnitWords() {
        XCTAssertEqual(TimeInterval(65).formattedSpokenDuration(locale: enUS), "1 minute, 5 seconds")
        XCTAssertEqual(TimeInterval(5).formattedSpokenDuration(locale: enUS), "5 seconds")
        XCTAssertTrue(TimeInterval(65).formattedSpokenDuration(locale: deDE).contains("Minute"))
        XCTAssertTrue(TimeInterval(65).formattedSpokenDuration(locale: frFR).contains("minute"))
    }

    func testSecondsUseLocaleDecimalSeparator() {
        XCTAssertEqual(TimeInterval(12.34).formattedSeconds(locale: enUS), "12.3s")
        XCTAssertTrue(TimeInterval(12.34).formattedSeconds(locale: deDE).hasPrefix("12,3"))
        XCTAssertTrue(TimeInterval(12.34).formattedSeconds(locale: frFR).hasPrefix("12,3"))
        XCTAssertEqual(TimeInterval(12.34).formattedSpokenSeconds(locale: enUS), "12.3 seconds")
    }

    // MARK: - Counts

    func testCompactCountsFollowLocale() {
        XCTAssertEqual(999.formattedCompact(locale: enUS), "999")
        XCTAssertEqual(1_000.formattedCompact(locale: enUS), "1K")
        XCTAssertEqual(1_234.formattedCompact(locale: enUS), "1.2K")
        XCTAssertEqual(1_250_000.formattedCompact(locale: enUS), "1.2M")
        // German abbreviates millions as "Mio." with a decimal comma.
        let germanMillions = 1_250_000.formattedCompact(locale: deDE)
        XCTAssertTrue(germanMillions.hasPrefix("1,2") && germanMillions.hasSuffix("Mio."), germanMillions)
        XCTAssertTrue(1_234.formattedCompact(locale: frFR).hasPrefix("1,2"))
    }

    // MARK: - Percentages, multipliers, angles

    func testPercentRoundsDownAndClamps() {
        XCTAssertEqual(0.428.formattedPercent(locale: enUS), "42%")
        XCTAssertEqual(0.999.formattedPercent(locale: enUS), "99%")
        XCTAssertEqual(1.0.formattedPercent(locale: enUS), "100%")
        XCTAssertEqual(1.7.formattedPercent(locale: enUS), "100%")
        XCTAssertEqual((-0.2).formattedPercent(locale: enUS), "0%")
        // German/French put a (non-breaking) space before the sign.
        XCTAssertNotEqual(0.42.formattedPercent(locale: deDE), "42%")
        XCTAssertTrue(0.42.formattedPercent(locale: deDE).hasPrefix("42"))
    }

    func testMultiplierAndDegreesUseLocaleDecimalSeparator() {
        XCTAssertEqual(1.5.formattedMultiplier(locale: enUS), "1.5×")
        XCTAssertEqual(1.5.formattedMultiplier(locale: deDE), "1,5×")
        XCTAssertEqual(2.5.formattedSignedDegrees(locale: enUS), "+2.5°")
        XCTAssertEqual((-1.0).formattedSignedDegrees(locale: enUS), "-1.0°")
        XCTAssertEqual(0.0.formattedSignedDegrees(locale: enUS), "+0.0°")
        XCTAssertEqual(2.5.formattedSignedDegrees(locale: frFR), "+2,5°")
    }
}
