//
//  ScoringExposureTests.swift
//  RallyLabTests
//
//  The scoring run's ledger identity: two models give two rows, the same run
//  again gives none, a model that can't be digested stops the run, and the
//  withheld closure is refused beside the final-test reservation.
//

import XCTest
@testable import RallyLab

final class ScoringExposureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("scoring-exposure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A stand-in model package: a folder whose bytes are its identity.
    private func model(_ name: String, bytes: String) throws -> URL {
        let dir = root.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Data"), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: dir.appendingPathComponent("Data/weights.bin"))
        return dir
    }

    private func heatConfig(_ model: URL) -> ProcessorConfig {
        var c = ProcessorConfig()
        c.heatmapModel = model
        c.heatmapOnly = true
        return c
    }

    func testTwoModelsAreTwoRowsAndTheSameRunAgainIsNone() throws {
        let l1 = try model("Scratch-l1", bytes: "l1 weights")
        let l2 = try model("Scratch-l2", bytes: "l2 weights")
        let refL1 = try ScoringExposure.ref(command: "--score-rallies", config: heatConfig(l1))
        let refL2 = try ScoringExposure.ref(command: "--score-rallies", config: heatConfig(l2))
        XCTAssertNotEqual(refL1, refL2)
        XCTAssertTrue(refL1.hasPrefix("--score-rallies heat=Scratch-l1@"), refL1)
        XCTAssertTrue(refL2.hasPrefix("--score-rallies heat=Scratch-l2@"), refL2)
        XCTAssertEqual(refL1, try ScoringExposure.ref(command: "--score-rallies", config: heatConfig(l1)), "deterministic")
        // The L1 pass, the L2 pass, then the L1 pass again: two rows a video, not one and not three.
        for ref in [refL1, refL2, refL1] {
            try ExposureLog.record(videos: ["bch_a", "ind_b"], kind: .rallyScoring, ref: ref, note: nil, in: root)
        }
        let rows = try ExposureLog.readStrict(in: root)
        XCTAssertEqual(rows.filter { $0.video == "bch_a" }.map(\.ref), [refL1, refL2])
        XCTAssertEqual(rows.filter { $0.video == "ind_b" }.map(\.ref), [refL1, refL2])
        XCTAssertEqual(rows.count, 4)
    }

    func testARetrainedModelUnderTheSameNameIsAnotherRun() throws {
        let before = try ScoringExposure.ref(command: "--score-rallies", config: heatConfig(try model("same", bytes: "v1")))
        try Data("v2".utf8).write(to: root.appendingPathComponent("same.mlpackage/Data/weights.bin"))
        let after = try ScoringExposure.ref(command: "--score-rallies", config: heatConfig(root.appendingPathComponent("same.mlpackage")))
        XCTAssertNotEqual(before, after, "the digest, not the file name, is the model")
    }

    func testSettingsThatChangeTheRunChangeTheRef() throws {
        let m = try model("m", bytes: "w")
        let base = heatConfig(m)
        var padded = base; padded.preroll = 1.0
        var joined = base; joined.minGapToMerge = 0
        var hopped = base; hopped.heatmapHop = 3
        var both = base; both.heatmapOnly = false
        let refs = try [base, padded, joined, hopped, both].map { try ScoringExposure.ref(command: "--score-rallies", config: $0) }
        XCTAssertEqual(Set(refs).count, refs.count, "\(refs)")
        XCTAssertTrue(refs[0].contains(" hop=5 "), refs[0])
        XCTAssertTrue(refs[4].contains("+yolo=\(ProcessorConfig().ballModel.rawValue)"), refs[4])
        XCTAssertNotEqual(try ScoringExposure.ref(command: "--render-pipeline", config: base), refs[0], "the command is part of the use")
        let note = ScoringExposure.note(config: padded)
        XCTAssertTrue(note.hasPrefix("multi-frame m only; "), note)
        XCTAssertTrue(note.contains("preroll=1 "), note)
    }

    func testYOLOOnlyNamesTheBallModel() throws {
        var c = ProcessorConfig()
        c.heatmapModel = nil
        c.heatmapOnly = false
        let ref = try ScoringExposure.ref(command: "--diagnose-rallies", config: c)
        XCTAssertTrue(ref.hasPrefix("--diagnose-rallies yolo=\(c.ballModel.rawValue) "), ref)
        XCTAssertFalse(ref.contains("heat="))
    }

    func testAModelThatCannotBeDigestedStopsTheRun() {
        let missing = root.appendingPathComponent("gone.mlpackage")
        XCTAssertThrowsError(try ScoringExposure.ref(command: "--score-rallies", config: heatConfig(missing))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Nothing is scored"), error.localizedDescription)
        }
    }

    func testReservedAndWithheldAreRefusedAndTheRestScored() {
        let reserved: Set<String> = ["bch_final"], withheld: Set<String> = ["grs_extra_self_02", "bch_final"]
        XCTAssertNil(ScoringExposure.refusal("bch_dev", reserved: reserved, withheld: withheld))
        XCTAssertTrue(ScoringExposure.refusal("grs_extra_self_02", reserved: reserved, withheld: withheld)!.contains("withheld"))
        XCTAssertTrue(ScoringExposure.refusal("bch_final", reserved: reserved, withheld: withheld)!.contains("final_test"), "the final test is named first")
    }
}
