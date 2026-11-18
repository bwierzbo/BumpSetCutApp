//
//  CoverageAuditCorrectionsTests.swift
//  RallyLabTests
//
//  The marking pass's use of the audit's boundary errors (CoverageAuditCorrections.swift;
//  protocol amendment 1, A1.3): what is proposed, that nothing is decided while the stage
//  is incomplete, the ledger before the mark, and the mark as it is moved. Synthetic
//  projects in a temporary folder; the "videos" are small files of bytes.
//

import XCTest
@testable import RallyLab

final class CoverageAuditCorrectionsTests: XCTestCase {
    private typealias A = CoverageAudit
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-11-14T18:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cov-corr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try DatasetStore(root: root).prepare()
        try recording("held")
        try #"{"tune":[],"holdout":["held"]}"#.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
        // 10 s, rallies at 2–4 and 6–8: unmarked 0–2, 4–6 and 8–10 (intervals 0, 1, 2).
        try recording("a")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func video(_ name: String) -> URL { root.appendingPathComponent("footage/\(name).mp4") }

    private func recording(_ name: String) throws {
        try FileManager.default.createDirectory(at: video(name).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("the footage of \(name)".utf8).write(to: video(name), options: .atomic)
        try #"[{"startTime":2,"endTime":4,"kind":"rally"},{"startTime":6,"endTime":8,"kind":"rally"}]"#
            .write(to: RallyMarkModel.labelsURL(for: video(name)), atomically: true, encoding: .utf8)
        var s = VideoSession(name: name, sourcePath: video(name).path, split: "train", addedAt: now, frames: [])
        s.ralliesMarked = true
        try DatasetStore(root: root).save(s)
    }

    /// The draw of `a` as it is now, with no repeat set (so first looks complete the stage).
    private func draw() throws -> A.LoadedDraw {
        let session = try XCTUnwrap(DatasetStore(root: root).loadSessionsStrict().first { $0.name == "a" })
        let marks = try XCTUnwrap(RallyTruth.records(inSidecarOf: video("a")))
        let entry: [String: Any] = [
            "recordingId": "a", "groupId": "a", "surface": "beach",
            "contentFingerprint": ProjectsModel.fileFingerprint(atPath: session.sourcePath) ?? "file:none",
            "marksSha256": DatasetSplitManifest.sha256(of: RallyMarkModel.labelsURL(for: video("a"))) ?? "",
            "durationTicks": 6000,
            "intervals": A.unmarkedIntervals(marks: marks, cuts: session.cutRanges, durationTicks: 6000).map { ["index": $0.index, "startTick": $0.startTick, "endTick": $0.endTick] },
            "repeatIndices": [Int](),
        ]
        let json: [String: Any] = ["schemaVersion": A.drawVersion, "stage": "pilot", "drawId": "20261114-120000",
                                   "dataset": ["name": "rc-v1-20261112", "timescale": 600, "manifestSha256": "aa"], "seed": 20261114, "recordings": [entry]]
        let url = A.drawsDirectory(in: root).appendingPathComponent("20261114-120000-draw.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: url)
        return try A.loadDraw(url)
    }

    private var all: A.PlayedCoverage {
        var coverage = A.PlayedCoverage()
        coverage.credit(fromTick: 0, toTick: 6000, rate: 2)
        return coverage
    }

    private func give(_ index: Int, _ entry: A.Entry, draw d: A.LoadedDraw) throws {
        try A.record(A.Request(recordingId: "a", index: index, pass: .first, entry: entry, reviewer: "bw", played: all, note: nil), draw: d, root: root, tool: "t", now: now)
    }

    private func boundary(_ edge: A.Edge, _ a: Double, _ b: Double) -> A.Entry {
        .finding(A.Finding(kind: .boundaryError, approxStartSec: a, approxEndSec: b, edge: edge, note: nil))
    }

    private func marks() throws -> [[Double]] {
        try XCTUnwrap(RallyTruth.records(inSidecarOf: video("a"))).map { [$0.startTime, $0.endTime] }
    }

    func testABoundaryErrorIsProposedAgainstTheNeighbouringMarkAndNothingIsDecidedWhileTheStageIsIncomplete() throws {
        let d = try draw()
        // Interval 1 (4–6): the rally before runs to 5.5; the others not reviewed yet.
        try give(1, boundary(.leading, 4, 5.5), draw: d)
        let open = try A.corrections(draw: d, root: root)
        let proposal = A.Correction(recordingId: "a", intervalIndex: 1, edge: .leading, markStartSec: 2, markEndSec: 4, fromSec: 4, toSec: 5.5)
        XCTAssertEqual(open.proposals, [proposal])
        XCTAssertEqual(proposal.addedSec, 1.5)
        XCTAssertNotNil(open.blocked, "two intervals have no verdict")
        XCTAssertThrowsError(try A.decide(proposal, .applied, draw: d, root: root, now: now)) {
            guard case A.CorrectionFailure.blocked = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try marks(), [[2, 4], [6, 8]], "no mark moved")
        XCTAssertEqual(try A.correctionEntries(in: root, drawId: d.draw.drawId), [], "and nothing on the ledger")
    }

    func testApplyingMovesTheMarkAfterTheLedgerAndDecliningMovesNothing() throws {
        let d = try draw()
        try give(0, .clean, draw: d)
        try give(1, boundary(.leading, 4, 5.5), draw: d)
        try give(2, boundary(.trailing, 8, 9.2), draw: d)
        var current = try A.corrections(draw: d, root: root)
        XCTAssertNil(current.blocked)
        XCTAssertEqual(current.proposals.map(\.id), ["a#1#leading"], "interval 2 ends at the recording's end: no mark after it")
        XCTAssertEqual(current.notProposed.count, 1)

        let lead = try XCTUnwrap(current.proposals.first)
        try A.decide(lead, .applied, draw: d, root: root, now: now)
        XCTAssertEqual(try marks(), [[2, 5.5], [6, 8]])
        XCTAssertEqual(try A.correctionEntries(in: root, drawId: d.draw.drawId).map(\.action), [.applied])
        current = try A.corrections(draw: d, root: root)
        XCTAssertEqual(current.proposals, [], "a decided correction is not proposed again")
        XCTAssertThrowsError(try A.decide(lead, .applied, draw: d, root: root, now: now), "nor applied twice") {
            XCTAssertEqual($0 as? A.CorrectionFailure, .stale("a#1#leading"))
        }
    }

    func testATrailingErrorMovesTheNextMarksStartAndADeclinedOneIsRemembered() throws {
        let d = try draw()
        try give(0, boundary(.trailing, 0.8, 2), draw: d)
        try give(1, boundary(.trailing, 4.5, 6), draw: d)
        try give(2, .clean, draw: d)
        let proposals = try A.corrections(draw: d, root: root).proposals
        XCTAssertEqual(proposals.map(\.toSec), [0.8, 4.5])
        try A.decide(proposals[0], .declined, draw: d, root: root, now: now)
        XCTAssertEqual(try marks(), [[2, 4], [6, 8]])
        try A.decide(proposals[1], .applied, draw: d, root: root, now: now)
        XCTAssertEqual(try marks(), [[2, 4], [4.5, 8]])
        XCTAssertEqual(try A.correctionEntries(in: root, drawId: d.draw.drawId).map(\.action), [.declined, .applied])
        XCTAssertEqual(try A.corrections(draw: d, root: root).proposals, [])
    }

    func testTwoTrimsOfOneIntervalThatCrossAreNotProposed() throws {
        let d = try draw()
        try give(0, .clean, draw: d)
        try give(1, boundary(.leading, 4, 5.6), draw: d)
        try give(1, boundary(.trailing, 4.4, 6), draw: d)
        try give(2, .clean, draw: d)
        let current = try A.corrections(draw: d, root: root)
        XCTAssertEqual(current.proposals, [])
        XCTAssertTrue(current.notProposed.contains { $0.contains("cross") }, "\(current.notProposed)")
    }

    func testACorrectionWhoseAddedTimeIsMarkedOrCutSinceTheReviewIsNotProposedOrApplied() throws {
        let d = try draw()
        try give(0, .clean, draw: d)
        try give(1, boundary(.leading, 4, 5.8), draw: d)
        try give(2, .clean, draw: d)
        let proposal = try XCTUnwrap(A.corrections(draw: d, root: root).proposals.first)
        // After the review a mark is added inside the interval: 4.5–5.5.
        try #"[{"startTime":2,"endTime":4,"kind":"rally"},{"startTime":4.5,"endTime":5.5,"kind":"rally"},{"startTime":6,"endTime":8,"kind":"rally"}]"#
            .write(to: RallyMarkModel.labelsURL(for: video("a")), atomically: true, encoding: .utf8)
        let current = try A.corrections(draw: d, root: root)
        XCTAssertEqual(current.proposals, [])
        XCTAssertTrue(current.notProposed.contains { $0.contains("no longer all unmarked") }, "\(current.notProposed)")
        XCTAssertThrowsError(try A.decide(proposal, .applied, draw: d, root: root, now: now)) {
            XCTAssertEqual($0 as? A.CorrectionFailure, .stale("a#1#leading"))
        }
        XCTAssertEqual(try marks(), [[2, 4], [4.5, 5.5], [6, 8]])
        XCTAssertEqual(try A.correctionEntries(in: root, drawId: d.draw.drawId), [])
    }

    func testARallyThatStartsAtItsServeContactIsFoundByThatStartAndTheContactMovesWithIt() throws {
        // The second rally is marked 5.5–8 with its serve contact at 6: the audit's interval ends at 6, not 5.5.
        try #"[{"startTime":2,"endTime":4,"kind":"rally"},{"startTime":5.5,"endTime":8,"kind":"rally","contacts":[{"time":6,"kind":"serve"},{"time":7,"kind":"pass"}]}]"#
            .write(to: RallyMarkModel.labelsURL(for: video("a")), atomically: true, encoding: .utf8)
        let d = try draw()
        try give(0, .clean, draw: d)
        try give(1, boundary(.trailing, 4.5, 6), draw: d)
        try give(2, .clean, draw: d)
        let proposal = try XCTUnwrap(A.corrections(draw: d, root: root).proposals.first)
        XCTAssertEqual(proposal, A.Correction(recordingId: "a", intervalIndex: 1, edge: .trailing, markStartSec: 5.5, markEndSec: 8, fromSec: 6, toSec: 4.5, movesServeContact: true))
        XCTAssertEqual(proposal.addedSec, 1.5)
        try A.decide(proposal, .applied, draw: d, root: root, now: now)
        let moved = try XCTUnwrap(RallyTruth.records(inSidecarOf: video("a")))
        XCTAssertEqual(moved[1].startTime, 4.5)
        XCTAssertEqual(moved[1].contacts?.map(\.time), [4.5, 7])
        let session = try XCTUnwrap(DatasetStore(root: root).loadSessionsStrict().first { $0.name == "a" })
        XCTAssertEqual(A.unmarkedIntervals(marks: moved, cuts: session.cutRanges, durationTicks: 6000).map(\.span),
                       [A.Span(startTick: 0, endTick: 1200), A.Span(startTick: 2400, endTick: 2700), A.Span(startTick: 4800, endTick: 6000)], "the next draw's interval ends at the corrected start")
    }

    func testAnUnwritableLedgerMovesNoMark() throws {
        let d = try draw()
        try give(0, .clean, draw: d)
        try give(1, boundary(.leading, 4, 5.5), draw: d)
        try give(2, .clean, draw: d)
        let proposal = try XCTUnwrap(A.corrections(draw: d, root: root).proposals.first)
        // A directory where the ledger file goes: it can be neither read nor written.
        try FileManager.default.createDirectory(at: A.correctionsLedger(in: root, drawId: d.draw.drawId), withIntermediateDirectories: true)
        XCTAssertThrowsError(try A.decide(proposal, .applied, draw: d, root: root, now: now))
        XCTAssertEqual(try marks(), [[2, 4], [6, 8]])
    }
}
