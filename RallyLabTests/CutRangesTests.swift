//
//  CutRangesTests.swift
//  RallyLabTests
//
//  Cut ranges (D-030): kept raw, read normalised; the pieces of a stretch
//  outside them; the seconds they take from a recording; the mask over
//  scoring intervals.
//

import XCTest
@testable import RallyLab

final class CutRangesTests: XCTestCase {
    private func cut(_ a: Double, _ b: Double) -> CutRange { CutRange(start: a, end: b) }

    func testNormalisedDropsEmptyAndNegativeSortsAndMerges() {
        let raw = [cut(50, 60), cut(10, 20), cut(20, 25), cut(5, 5), cut(30, 28), cut(-1, 3), cut(55, 58)]
        XCTAssertEqual(raw.normalised(), [cut(10, 25), cut(50, 60)])
        XCTAssertEqual([CutRange]().normalised(), [])
    }

    func testContainsIsClosedAtTheStartOpenAtTheEnd() {
        let cuts = [cut(10, 20)]
        XCTAssertTrue(cuts.contains(10))
        XCTAssertTrue(cuts.contains(19.99))
        XCTAssertFalse(cuts.contains(20))
        XCTAssertFalse(cuts.contains(9.99))
    }

    func testOverlapsNeedsMoreThanAPoint() {
        let cuts = [cut(10, 20)]
        XCTAssertTrue(cuts.overlaps(15, 25))
        XCTAssertTrue(cuts.overlaps(0, 100))
        XCTAssertFalse(cuts.overlaps(20, 30))
        XCTAssertFalse(cuts.overlaps(0, 10))
    }

    func testOutsideReturnsThePiecesAroundTheCuts() {
        let cuts = [cut(10, 20), cut(30, 40)]
        func pieces(_ a: Double, _ b: Double) -> [[Double]] { cuts.outside(a, b).map { [$0.start, $0.end] } }
        XCTAssertEqual(pieces(0, 50), [[0, 10], [20, 30], [40, 50]])
        XCTAssertEqual(pieces(12, 18), [])                 // cut whole
        XCTAssertEqual(pieces(15, 35), [[20, 30]])         // cut at both ends
        XCTAssertEqual(pieces(5, 15), [[5, 10]])           // cut at the end
        XCTAssertEqual(pieces(15, 25), [[20, 25]])         // cut at the start
        XCTAssertEqual(pieces(22, 28), [[22, 28]])         // untouched
        XCTAssertEqual(pieces(28, 28), [])                 // empty stretch
        XCTAssertEqual([CutRange]().outside(3, 4).map { [$0.start, $0.end] }, [[3, 4]])
    }

    func testOutsideUsesTheNormalisedRanges() {
        let raw = [cut(15, 25), cut(10, 20)]
        XCTAssertEqual(raw.outside(0, 30).map { [$0.start, $0.end] }, [[0, 10], [25, 30]])
    }

    func testSecondsWithinClampsToTheDuration() {
        let cuts = [cut(0, 12), cut(290, 400)]
        XCTAssertEqual(cuts.seconds(within: 300), 22, accuracy: 1e-9)
        XCTAssertEqual(cuts.seconds(within: 10), 10, accuracy: 1e-9)
        XCTAssertEqual([CutRange]().seconds(within: 300), 0)
    }

    func testIntervalMaskKeepsPiecesOutsideAndDropsSlivers() {
        let cuts = [cut(10, 20)]
        let ivs = [Interval(start: 0, end: 5), Interval(start: 8, end: 12), Interval(start: 12, end: 18),
                   Interval(start: 19.95, end: 30), Interval(start: 15, end: 25)]
        let masked = ivs.outside(cuts)
        XCTAssertEqual(masked, [Interval(start: 0, end: 5), Interval(start: 8, end: 10), Interval(start: 20, end: 30),
                                Interval(start: 20, end: 25)])
        XCTAssertEqual(ivs.outside([]), ivs)
    }
}
