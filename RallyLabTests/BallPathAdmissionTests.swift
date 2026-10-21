//
//  BallPathAdmissionTests.swift
//  RallyLabTests
//
//  Building a ball path runs the pipeline over a whole video, which is
//  exposure (D-002): reserved recordings are refused, admitted runs are on
//  the ledger before they start, and a broken ledger refuses too.
//

import XCTest
@testable import RallyLab

final class BallPathAdmissionTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rl-bp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeValidation(_ text: String) throws {
        try text.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
    }

    func testReservedRecordingIsRefusedAndNotLogged() throws {
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["z"]}"#)
        let why = BallPathBuilder.admission(of: "z", in: root)
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.contains("reserved") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExposureLog.url(in: root).path), "a refused run must leave no ledger row")
    }

    func testAdmittedRunIsOnTheLedgerBeforeItStarts() throws {
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["z"]}"#)
        XCTAssertNil(BallPathBuilder.admission(of: "a", in: root))
        let rows = try ExposureLog.readStrict(in: root)
        XCTAssertEqual(rows.map(\.video), ["a"])
        XCTAssertEqual(rows.first?.kind, .ballPath)
        XCTAssertEqual(rows.first?.ref, "BallPathBuilder")
    }

    func testUnreadableReservationsRefuse() throws {
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["z"]"#)   // truncated: must fail closed
        XCTAssertNotNil(BallPathBuilder.admission(of: "a", in: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExposureLog.url(in: root).path))
    }

    func testUnreadableLedgerParksASidecarAndNeverOverwrites() throws {
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":[]}"#)
        try "not json".write(to: ExposureLog.url(in: root), atomically: true, encoding: .utf8)
        XCTAssertNil(BallPathBuilder.admission(of: "a", in: root), "a damaged main log parks the row in a sidecar; the run is still recorded")
        XCTAssertEqual(try String(contentsOf: ExposureLog.url(in: root), encoding: .utf8), "not json")
        let sidecars = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("manifests"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("exposure-log.unmerged-") }
        XCTAssertEqual(sidecars.count, 1)
    }

    func testUnwritableLedgerRefuses() throws {
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":[]}"#)
        try FileManager.default.removeItem(at: root.appendingPathComponent("manifests"))
        try "".write(to: root.appendingPathComponent("manifests"), atomically: true, encoding: .utf8)   // a file where the folder must be
        let why = BallPathBuilder.admission(of: "a", in: root)
        XCTAssertNotNil(why, "a ledger that cannot be written must refuse the run")
    }
}
