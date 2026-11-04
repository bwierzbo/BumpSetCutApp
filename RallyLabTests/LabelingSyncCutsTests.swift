//
//  LabelingSyncCutsTests.swift
//  RallyLabTests
//
//  Cut ranges travel with the rally times (D-030): a row from before the
//  column decodes with no cuts, a row with them carries them, and the sync's
//  "same" rule tells a change of cuts alone apart — so it is pushed or
//  pulled like a change of rallies.
//

import XCTest
@testable import RallyLab

final class LabelingSyncCutsTests: XCTestCase {
    private let id = UUID()

    private func times(_ rallies: [(Double, Double)], complete: Bool = false, cuts: [CutRange]? = nil) -> LabelRallyTimes {
        LabelRallyTimes(videoId: id, rallies: rallies.map { LabelRally(start: $0.0, end: $0.1) }, complete: complete, updatedAt: nil, cuts: cuts)
    }

    func testARowFromBeforeTheColumnDecodesWithNoCutsAndOneWithThemCarriesThem() throws {
        let old = try JSONDecoder().decode(LabelRallyTimes.self, from: Data("""
        {"videoId":"\(id.uuidString)","rallies":[{"start":1,"end":2}],"complete":false}
        """.utf8))
        XCTAssertNil(old.cuts); XCTAssertEqual(old.cutRanges, [])
        let new = try JSONDecoder().decode(LabelRallyTimes.self, from: Data("""
        {"videoId":"\(id.uuidString)","rallies":[],"complete":true,"cuts":[{"start":141.6,"end":157},{"start":0,"end":12.4}]}
        """.utf8))
        XCTAssertEqual(new.cuts, [CutRange(start: 141.6, end: 157), CutRange(start: 0, end: 12.4)])
        XCTAssertEqual(new.cutRanges, [CutRange(start: 0, end: 12.4), CutRange(start: 141.6, end: 157)])
        // Encoded only when set: a build that never knew cuts sends no key, and the server keeps its value.
        let encoded = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        XCTAssertFalse(encoded.contains("cuts"))
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(new), as: UTF8.self).contains("\"cuts\""))
    }

    @MainActor
    func testSameTellsAChangeOfCutsAlone() {
        let a = times([(10, 20)], cuts: [CutRange(start: 30, end: 40)])
        XCTAssertTrue(LabelingSync.same(a, times([(10, 20.01)], cuts: [CutRange(start: 30.01, end: 40)])), "within a frame")
        XCTAssertFalse(LabelingSync.same(a, times([(10, 20)])), "no cuts on one side")
        XCTAssertFalse(LabelingSync.same(a, times([(10, 20)], cuts: [CutRange(start: 30, end: 45)])))
        XCTAssertFalse(LabelingSync.same(a, times([(10, 20)], cuts: [CutRange(start: 30, end: 40), CutRange(start: 50, end: 60)])))
        XCTAssertTrue(LabelingSync.same(times([(10, 20)]), times([(10, 20)], cuts: [])), "nil and empty are the same: no cuts")
    }
}
