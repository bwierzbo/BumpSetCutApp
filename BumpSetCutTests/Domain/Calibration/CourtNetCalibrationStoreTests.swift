//
//  CourtNetCalibrationStoreTests.swift
//  BumpSetCutTests
//
//  The calibration file on disk: read back as written, refused when unreadable or
//  malformed and never written over, no confirmation lost by a save, a file for another
//  video set aside.
//

import XCTest
@testable import BumpSetCut

final class CourtNetCalibrationStoreTests: XCTestCase {
    private typealias F = CalibrationFixtures
    private var dir: URL!
    private var store: CourtNetCalibrationStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("CourtNetCalibrationStoreTests_\(UUID().uuidString)")
        store = CourtNetCalibrationStore(directory: dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func confirmed(_ b: CourtNetCalibrationFile.Binding = F.binding) throws -> CourtNetCalibrationFile {
        var f = CourtNetCalibrationFile.new(for: b)
        f.setup = CourtSetup(surface: .beach, format: .twos, answeredAt: F.day)
        try f.saveDraft(F.court, of: \.court, segment: 0, startedFrom: CourtNetCalibrationV1.manual, baseline: nil)
        try f.confirm(\.court, segment: 0, by: "ben", tool: "test", now: F.day.addingTimeInterval(0.4))
        try f.saveDraft(F.net, of: \.net, segment: 0, startedFrom: CourtNetCalibrationV1.manual, baseline: nil)
        try f.confirm(\.net, segment: 0, by: "ben", tool: "test", now: F.day)
        return f
    }

    private func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    func testNoFileIsNoCalibration() throws {
        XCTAssertNil(try store.load(F.binding.recordingId))
        XCTAssertEqual(store.lookup(for: F.binding), .none)
    }

    func testAFileReadsBackAsWrittenAndLeavesNothingElseBehind() throws {
        var f = try confirmed()
        XCTAssertTrue(f.split(at: 40, reuse: true))
        try f.setView(.unsuitable, segment: 1, note: "zoomed in", at: F.day)
        try f.add(CalibrationProposal(method: "net_guided_v1", kind: .estimate, geometry: F.court, confidence: 0.4,
                                      uncertainty: ["assumed camera height"], createdAt: F.day), to: \.court, segment: 0)
        try store.save(f)
        XCTAssertEqual(try store.load(F.binding.recordingId), f)
        XCTAssertEqual(store.lookup(for: F.binding), .usable(f))
        XCTAssertEqual(try names(), ["\(F.binding.recordingId)_calibration.json"])
        // Saving again what was read changes nothing and is allowed.
        try store.save(f)
        XCTAssertEqual(try store.load(F.binding.recordingId), f)
    }

    func testTheFileNamesItsSchemaAndCoordinates() throws {
        try store.save(try confirmed())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.url(F.binding.recordingId))) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? String, "court_net_calibration_v1")
        XCTAssertEqual(json["coordinateSpace"] as? String, "upright_vision_normalized")
        XCTAssertEqual(json["sourceFingerprint"] as? String, "file:abc")
        XCTAssertEqual(json["frameWidth"] as? Int, 1920)
    }

    func testAnUnreadableFileIsAnErrorAndIsNotWrittenOver() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = store.url(F.binding.recordingId)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)
        XCTAssertThrowsError(try store.load(F.binding.recordingId)) {
            guard case CourtNetCalibrationError.unreadable = $0 else { return XCTFail("\($0)") }
        }
        guard case .unreadable = store.lookup(for: F.binding) else { return XCTFail("not unreadable") }
        XCTAssertThrowsError(try store.save(try confirmed()))
        XCTAssertEqual(try Data(contentsOf: url), garbage)
    }

    func testAMalformedFileOnDiskIsRefused() throws {
        var f = try confirmed()
        try store.save(f)
        f.segments[0].validToSec = 60
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        try e.encode(f).write(to: store.url(F.binding.recordingId))
        XCTAssertThrowsError(try store.load(F.binding.recordingId)) {
            guard case CourtNetCalibrationError.invalid = $0 else { return XCTFail("\($0)") }
        }
    }

    func testAMalformedFileIsNotSaved() throws {
        var f = try confirmed()
        f.segments[0].validToSec = 60
        XCTAssertThrowsError(try store.save(f))
        f = try confirmed()
        f.recordingId = "../escape"
        XCTAssertThrowsError(try store.save(f))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }

    func testASaveThatWouldLoseAConfirmationIsRefused() throws {
        let f = try confirmed()
        try store.save(f)
        // A fresh file for the same video — what a careless caller holding only new proposals would write.
        var fresh = CourtNetCalibrationFile.new(for: F.binding)
        try fresh.add(CalibrationProposal(method: "court_lines_v1", kind: .detection, geometry: F.court, confidence: 0.9, uncertainty: [],
                                          createdAt: F.day), to: \.court, segment: 0)
        XCTAssertThrowsError(try store.save(fresh)) { XCTAssertEqual($0 as? CourtNetCalibrationError, .wouldDropConfirmation) }
        XCTAssertEqual(try store.load(F.binding.recordingId), f)

        // Dropping only the history is refused too.
        var edited = f
        try edited.saveDraft(F.net.offset(dx: 0.01, dy: 0), of: \.net, segment: 0, startedFrom: CourtNetCalibrationV1.confirmation, baseline: F.net)
        try edited.confirm(\.net, segment: 0, by: "ben", tool: "test", now: F.day.addingTimeInterval(90))
        try store.save(edited)
        var forgetful = edited
        forgetful.segments[0].net.history = []
        XCTAssertThrowsError(try store.save(forgetful)) { XCTAssertEqual($0 as? CourtNetCalibrationError, .wouldDropConfirmation) }

        // Withdrawing a view keeps them in history: allowed.
        var withdrawn = edited
        try withdrawn.setView(.unsuitable, segment: 0, note: nil, at: F.day)
        XCTAssertNoThrow(try store.save(withdrawn))
    }

    func testAFileForAnotherVideoUnderTheSameIdIsStaleThenSetAside() throws {
        let old = try confirmed()
        try store.save(old)
        var replaced = F.binding
        replaced.sourceFingerprint = "file:def"
        XCTAssertEqual(store.lookup(for: replaced), .stale(old, reason: "the video file changed"))

        let fresh = CourtNetCalibrationFile.new(for: replaced)
        try store.save(fresh)
        XCTAssertEqual(store.lookup(for: replaced), .usable(fresh))
        let all = try names()
        XCTAssertEqual(all.count, 2)
        let aside = try XCTUnwrap(all.first { $0.contains("_calibration.superseded-") })
        XCTAssertTrue(aside.hasPrefix(F.binding.recordingId))
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try d.decode(CourtNetCalibrationFile.self, from: Data(contentsOf: dir.appendingPathComponent(aside))), old)
    }
}
