//
//  ReservationAndExposureTests.swift
//  RallyLabTests
//
//  The final-test reservation must fail closed, and exposure must be
//  recorded from every artefact kind and from the append-only log.
//

import XCTest
@testable import RallyLab

final class ReservationAndExposureTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeValidation(_ text: String) throws {
        try text.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
    }

    // MARK: - Reservations fail closed

    func testMissingValidationFileMeansNoReservations() throws {
        XCTAssertEqual(try PipelineTuner.ValidationSet.finalTestNames(in: root), [])
        XCTAssertNil(try PipelineTuner.ValidationSet.loadStrict(from: root))
    }

    func testLegacyValidationFileWithoutFinalTestMeansNoReservations() throws {
        try writeValidation(#"{"tune":["a"],"holdout":["b"]}"#)
        XCTAssertEqual(try PipelineTuner.ValidationSet.finalTestNames(in: root), [])
    }

    func testFinalTestNamesAreReturned() throws {
        try writeValidation(#"{"tune":["a"],"holdout":["b"],"finalTest":["z","y"]}"#)
        XCTAssertEqual(try PipelineTuner.ValidationSet.finalTestNames(in: root), ["y", "z"])
    }

    func testUnreadableValidationFileThrowsInsteadOfEmptying() throws {
        try writeValidation(#"{"tune":["a"],"holdout":["b"],"finalTest":["z"]"#)   // truncated
        XCTAssertThrowsError(try PipelineTuner.ValidationSet.finalTestNames(in: root)) { error in
            XCTAssertTrue(error is PipelineTuner.ValidationSet.ReservationError)
        }
        XCTAssertThrowsError(try PipelineTuner.ValidationSet.loadStrict(from: root))
        // The lenient loader used by older code paths still returns nil; nothing must treat that as "none".
        XCTAssertNil(PipelineTuner.ValidationSet.load(from: root))
    }

    // MARK: - Exposure discovery

    func testExposureIsFoundInScoresWindowsManifestCsvLogAndSeed() throws {
        let fm = FileManager.default
        // scores/<export>/scores.json
        let scores = root.appendingPathComponent("scores/Export-A")
        try fm.createDirectory(at: scores, withIntermediateDirectories: true)
        try #"{"clips":{"v_scored":{"f1":[0.9]}}}"#.write(to: scores.appendingPathComponent("scores.json"), atomically: true, encoding: .utf8)
        // exports/<multi-frame folder>/windows.jsonl
        let mf = root.appendingPathComponent("exports/Pkg-MF")
        try fm.createDirectory(at: mf, withIntermediateDirectories: true)
        try "{\"clip\":\"v_mf\",\"split\":\"train\"}\n{\"clip\":\"v_mf\",\"split\":\"train\"}\n".write(to: mf.appendingPathComponent("windows.jsonl"), atomically: true, encoding: .utf8)
        // exports/<yolo folder>/manifest.csv
        let yolo = root.appendingPathComponent("exports/Pkg-YOLO")
        try fm.createDirectory(at: yolo, withIntermediateDirectories: true)
        try "image,clip,split,source,time,boxes\na.jpg,v_yolo,val,rally:0,1.000,1\nb.jpg,v_yolo,val,rally:0,2.000,0\n".write(to: yolo.appendingPathComponent("manifest.csv"), atomically: true, encoding: .utf8)
        // exposure-log.json via the API, and a hand-written seed
        ExposureLog.record(videos: ["v_logged"], kind: .pipelineTune, ref: "report-1.md", note: nil, in: root)
        try fm.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try #"[{"video":"v_seed","kind":"training_package","ref":"Old.zip","date":"2026-10-17","note":"from zip"}]"#
            .write(to: ExposureLog.seedURL(in: root), atomically: true, encoding: .utf8)

        let found = DatasetSplitManifest.discoverExposure(in: root)
        XCTAssertEqual(found["v_scored"]?.map(\.kind), [.testSetScoring])
        XCTAssertEqual(found["v_scored"]?.first?.ref, "Export-A")
        XCTAssertEqual(found["v_mf"]?.map(\.kind), [.trainingPackage])
        XCTAssertEqual(found["v_yolo"]?.map(\.kind), [.trainingPackage])
        XCTAssertEqual(found["v_yolo"]?.first?.note, "manifest.csv split=val")
        XCTAssertEqual(found["v_logged"]?.map(\.kind), [.pipelineTune])
        XCTAssertEqual(found["v_seed"]?.first?.ref, "Old.zip")
    }

    func testExposureLogAppendsWithoutDuplicates() throws {
        ExposureLog.record(videos: ["a", "b"], kind: .trainingPackage, ref: "P1", note: nil, in: root)
        ExposureLog.record(videos: ["b", "c"], kind: .trainingPackage, ref: "P1", note: nil, in: root)
        ExposureLog.record(videos: ["a"], kind: .testSetScoring, ref: "S1", note: nil, in: root)
        let rows = ExposureLog.read(in: root)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.filter { $0.video == "b" }.count, 1)
        XCTAssertEqual(Set(rows.filter { $0.video == "a" }.map(\.kind)), [.trainingPackage, .testSetScoring])
    }

    func testLoggedExposureBlocksFinalTestReservation() throws {
        ExposureLog.record(videos: ["bch_a_v3"], kind: .trainingPackage, ref: "P1", note: nil, in: root)
        var inputs = DatasetSplitManifestTests.inputs(validation: PipelineTuner.ValidationSet(tune: [], holdout: [], finalTest: ["bch_a_v3"]))
        inputs.discovered = DatasetSplitManifest.discoverExposure(in: root)
        XCTAssertThrowsError(try DatasetSplitManifest.build(inputs))
    }
}
