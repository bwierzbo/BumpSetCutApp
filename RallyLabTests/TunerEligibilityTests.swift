//
//  TunerEligibilityTests.swift
//  RallyLabTests
//
//  The pool --tune-pipeline and --serve-report read (D-027): validation.json's
//  tune list less the withheld closure, a line for each name left out; the
//  holdout list is not a pool; a reserved name in the file stops the run.
//

import XCTest
@testable import RallyLab

final class TunerEligibilityTests: XCTestCase {
    func testWithheldNamesLeaveTheTunePoolWithALineEachAndTheHoldoutListIsNotAPool() {
        let set = PipelineTuner.ValidationSet(tune: ["bch_a", "ind_b", "grs_c"], holdout: ["bch_h"], lineageHoldout: ["ind_b"])
        var lines: [String] = []
        let names = PipelineTuner.eligible(set, reserved: [], withheld: ["ind_b", "bch_h", "bch_h_v2"]) { lines.append($0) }
        XCTAssertEqual(names, ["bch_a", "grs_c"], "in the file's order, the withheld one out, the holdout list unread")
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("ind_b") && lines[0].contains("withheld"), lines[0])
    }

    func testAReservedNameInTheFileStopsTheRun() {
        let set = PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_h"], finalTest: ["bch_h"])
        var lines: [String] = []
        XCTAssertNil(PipelineTuner.eligible(set, reserved: ["bch_h"], withheld: ["bch_h"]) { lines.append($0) })
        XCTAssertTrue(lines.last?.contains("Fix validation.json") ?? false, lines.joined(separator: "\n"))
    }
}
