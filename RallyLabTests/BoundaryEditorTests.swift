//
//  BoundaryEditorTests.swift
//  RallyLabTests
//
//  The Rally Boundaries tab's logic (S1-b) without the window: frame stepping on
//  the original footage's frame times, and the editor's actions — marking events,
//  spans, coverage, commits, completion, withdrawal, undo — against the record's
//  rules. The window only maps keys to these actions.
//

import AVFoundation
import XCTest
@testable import RallyLab

final class BoundaryEditorTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-26T16:00:00Z")!

    private func editor(duration: Double = 3, frameRate: Double = 60) -> BoundaryEditor {
        BoundaryEditor(file: EventReview.File(video: "v", sourceFingerprint: "file:abc", frameRate: frameRate, durationSec: duration, tool: "t"), annotator: "BW", tool: "RallyLab test")
    }

    @discardableResult
    private func commitRally(_ e: inout BoundaryEditor, contact: Double, dead: Double) -> UUID {
        _ = e.apply(.mark(.contact, .earliest), at: contact, now: now)
        _ = e.apply(.mark(.dead, .earliest), at: dead, now: now)
        let out = e.apply(.commit, at: dead, now: now)
        XCTAssertTrue(out.changed, out.message)
        return e.selected!
    }

    // MARK: - Frames

    func testFrameClockStepsOnRealFrameTimes() {
        let clock = FrameClock(times: (0..<90).map { Double($0) / 30 }, frameRate: 30)
        XCTAssertEqual(clock.index(at: 0), 0)
        XCTAssertEqual(clock.index(at: 1.0), 30)
        XCTAssertEqual(clock.index(at: 1.0 - 1e-9), 30, "a hair before a frame's start is that frame (seconds round)")
        XCTAssertEqual(clock.index(at: 1.02), 30, "between frames: the one being shown")
        XCTAssertEqual(clock.index(at: 10), 89)
        XCTAssertEqual(clock.step(from: 1.0, by: 1), 31.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(clock.step(from: 1.02, by: -1), 29.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(clock.step(from: 0, by: -5), 0)
        XCTAssertEqual(clock.step(from: 2.9, by: 50), 89.0 / 30, accuracy: 1e-12)
        XCTAssertEqual(clock.label(at: 61.5), "1:01.500 · frame 89")
        let empty = FrameClock(times: [], frameRate: 60)
        XCTAssertEqual(empty.step(from: 1, by: 6), 1.1, accuracy: 1e-9, "before the times are read, steps use the nominal rate")
        XCTAssertEqual(empty.label(at: 0.5), "0:00.500 · frame 30")
    }

    func testFrameClockFromAFixtureVideo() async throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: "open-gop-hevc-leading3", withExtension: "mp4") ?? bundle.url(forResource: "open-gop-hevc-leading3", withExtension: "mp4", subdirectory: "Fixtures"))
        let clock = await RallyBoundariesModel.frameClock(of: url, frameRate: 60)
        // The x265 fixture shows its first frame at 1/30 s (a one-frame encoder delay): 179 frames, 0.0333…3.0 s.
        XCTAssertEqual(clock.times.count, 179)
        XCTAssertEqual(clock.times.first ?? -1, 1.0 / 30, accuracy: 1e-6)
        XCTAssertEqual(clock.times.last ?? -1, 3.0, accuracy: 1e-6)
        XCTAssertEqual(clock.index(at: 0), 0, "before the first frame: the first")
        XCTAssertEqual(clock.step(from: 0.5, by: 1), 31.0 / 60, accuracy: 1e-6)
        XCTAssertEqual(clock.index(at: 2.999), 177)
        XCTAssertEqual(clock.label(at: 0.5), "0:00.500 · frame 28")
    }

    // MARK: - Marking and committing

    func testMarkCommitAndTheRubric() {
        var e = editor()
        XCTAssertTrue(e.apply(.reviewedThrough, at: 3, now: now).changed)
        XCTAssertTrue(e.apply(.commit, at: 0, now: now).refused, "nothing marked yet")
        XCTAssertFalse(e.apply(.mark(.contact, .earliest), at: 0.5, now: now).changed, "marking changes the draft, not the record")
        XCTAssertEqual(e.draft.contact, EventReview.EventTime(earliest: 0.5, latest: 0.5), "one press: the frame itself")
        _ = e.apply(.mark(.contact, .latest), at: 0.55, now: now)
        XCTAssertEqual(e.draft.contact, EventReview.EventTime(earliest: 0.5, latest: 0.55))
        XCTAssertTrue(e.apply(.commit, at: 0, now: now).refused, "no ball dead and no end edge")
        _ = e.apply(.mark(.dead, .earliest), at: 1.4, now: now)
        _ = e.apply(.mark(.dead, .latest), at: 1.7, now: now)
        XCTAssertTrue(e.apply(.toggleOccluded, at: 0, now: now).message.contains("occluded"))
        XCTAssertEqual(e.draft.dead?.visibility, .occluded)
        let c = e.apply(.commit, at: 0, now: now)
        XCTAssertTrue(c.changed); XCTAssertFalse(c.refused)
        XCTAssertEqual(e.file.rallies.count, 1)
        let r = e.file.rallies[0]
        XCTAssertEqual(e.selected, r.rallyId, "the committed rally is selected")
        XCTAssertEqual(r.flags, ["ambiguous_dead"], "0.3 s is wider than the 0.2 s rubric; 0.05 s is not")
        XCTAssertEqual(r.contact, EventReview.EventTime(earliest: 0.5, latest: 0.55))
        XCTAssertEqual(r.dead, EventReview.EventTime(earliest: 1.4, latest: 1.7, visibility: .occluded))
        XCTAssertEqual(r.annotator, "BW"); XCTAssertEqual(r.reviewedAt, "2026-10-26T16:00:00Z")
        XCTAssertTrue(e.draft.isEmpty, "the draft is cleared after a commit")
        // An earliest press after the latest resets the interval to that frame; a latest press before the earliest widens down.
        _ = e.apply(.mark(.contact, .earliest), at: 2.0, now: now)
        _ = e.apply(.mark(.contact, .earliest), at: 2.1, now: now)
        XCTAssertEqual(e.draft.contact, EventReview.EventTime(earliest: 2.1, latest: 2.1))
        _ = e.apply(.mark(.contact, .latest), at: 2.05, now: now)
        XCTAssertEqual(e.draft.contact, EventReview.EventTime(earliest: 2.05, latest: 2.1))
        XCTAssertTrue(e.apply(.cancel, at: 0, now: now).message.contains("cancelled"))
        XCTAssertTrue(e.draft.isEmpty); XCTAssertNil(e.selected)
    }

    func testEdgesKindsAndFlags() {
        var e = editor()
        _ = e.apply(.reviewedThrough, at: 3, now: now)
        _ = e.apply(.mark(.dead, .earliest), at: 0.3, now: now)
        XCTAssertTrue(e.apply(.commit, at: 0, now: now).refused, "a rally needs a serve contact or a start edge")
        _ = e.apply(.cycleEdge, at: 0, now: now)
        XCTAssertEqual(e.draft.edge, .start)
        XCTAssertTrue(e.apply(.commit, at: 0, now: now).changed, "the recording starts after the serve: an edge, not a gap")
        XCTAssertEqual(e.file.rallies.last?.edge, .start)
        _ = e.apply(.cycleKind, at: 0, now: now); XCTAssertEqual(e.draft.kind, .missedServe)
        _ = e.apply(.cycleKind, at: 0, now: now); XCTAssertEqual(e.draft.kind, .other)
        XCTAssertTrue(e.apply(.commit, at: 0, now: now).refused, "an empty `other` is nothing to commit")
        _ = e.apply(.toggleFlag("ambiguous"), at: 0, now: now)
        XCTAssertEqual(e.draft.flags, ["ambiguous"])
        XCTAssertTrue(e.apply(.commit, at: 0, now: now).changed, "`other` may stay unresolved (protocol §4)")
        XCTAssertEqual(e.file.rallies.last?.kind, .other); XCTAssertEqual(e.file.rallies.last?.flags, ["ambiguous"])
        _ = e.apply(.toggleFlag("ambiguous"), at: 0, now: now); _ = e.apply(.toggleFlag("ambiguous"), at: 0, now: now)
        XCTAssertEqual(e.draft.flags, [], "a flag toggles off")
        XCTAssertTrue(e.apply(.toggleOccluded, at: 0, now: now).refused, "nothing marked to make occluded")
        XCTAssertFalse(e.apply(.cycleEdge, at: 0, now: now).changed)
        _ = e.apply(.cycleEdge, at: 0, now: now); XCTAssertEqual(e.draft.edge, .end)
        _ = e.apply(.cycleEdge, at: 0, now: now); XCTAssertNil(e.draft.edge)
    }

    func testSelectEditsTheSameRallyAndWithdrawKeepsIt() {
        var e = editor()
        _ = e.apply(.reviewedThrough, at: 3, now: now)
        let a = commitRally(&e, contact: 0.5, dead: 1.0)
        let b = commitRally(&e, contact: 1.5, dead: 2.0)
        XCTAssertEqual(e.file.rallies.map(\.rallyId), [a, b])
        _ = e.apply(.select(a), at: 0, now: now)
        XCTAssertEqual(e.draft.rallyId, a); XCTAssertEqual(e.draft.contact?.earliest, 0.5)
        _ = e.apply(.mark(.dead, .earliest), at: 1.1, now: now)
        XCTAssertTrue(e.apply(.commit, at: 0, now: now).message.contains("updated"))
        XCTAssertEqual(e.file.rallies.map(\.rallyId), [a, b], "editing keeps the id and the order")
        XCTAssertEqual(e.file.rallies[0].dead, EventReview.EventTime(earliest: 1.1, latest: 1.1))
        XCTAssertEqual(e.selected, a, "the committed rally stays selected")
        _ = e.apply(.select(b), at: 0, now: now)
        XCTAssertTrue(e.apply(.withdraw, at: 0, now: now).changed)
        XCTAssertEqual(e.file.rallies.count, 2, "a withdrawn rally stays on record")
        XCTAssertEqual(e.file.rallies[1].reviewState, .withdrawn)
        XCTAssertNil(e.selected)
        _ = e.apply(.select(b), at: 0, now: now)
        XCTAssertTrue(e.apply(.withdraw, at: 0, now: now).refused, "already withdrawn")
        _ = e.apply(.select(UUID()), at: 0, now: now)
        XCTAssertTrue(e.draft.isEmpty, "selecting an unknown id selects nothing")
    }

    func testSpansLieInsideCoverageAndNeedTwoPresses() {
        var e = editor()
        let first = e.apply(.span(.nonRallyActivity), at: 0.2, now: now)
        XCTAssertFalse(first.changed); XCTAssertEqual(e.openSpan?.start, 0.2)
        XCTAssertTrue(e.apply(.span(.nonRallyActivity), at: 0.1, now: now).refused, "a span ends after it starts")
        XCTAssertTrue(e.apply(.span(.nonRallyActivity), at: 0.6, now: now).refused, "nothing reviewed yet: spans lie inside reviewed coverage")
        XCTAssertEqual(e.file.spans.count, 0); XCTAssertEqual(e.openSpan?.start, 0.2, "the open span waits")
        _ = e.apply(.reviewedThrough, at: 1.0, now: now)
        XCTAssertTrue(e.apply(.span(.nonRallyActivity), at: 0.6, now: now).changed)
        XCTAssertEqual(e.file.spans.map { ($0.kind, $0.start, $0.end) }.map { "\($0.0.rawValue) \($0.1) \($0.2)" }, ["nonRallyActivity 0.2 0.6"])
        XCTAssertNil(e.openSpan)
        _ = e.apply(.span(.uncertain), at: 0.7, now: now)
        _ = e.apply(.span(.transition), at: 0.8, now: now)
        XCTAssertEqual(e.openSpan?.kind, .transition, "another kind starts a new span")
        _ = e.apply(.cancel, at: 0, now: now)
        XCTAssertNil(e.openSpan)
    }

    func testReviewedThroughCompletionAndUndo() {
        var e = editor(duration: 10, frameRate: 30)
        XCTAssertTrue(e.apply(.reviewedThrough, at: 4, now: now).changed)
        XCTAssertEqual(e.reviewedUntil, 4)
        XCTAssertTrue(e.apply(.reviewedThrough, at: 3, now: now).refused, "already reviewed through 4 s")
        XCTAssertEqual(e.unknownGaps.count, 1)
        let incomplete = e.apply(.complete, at: 0, now: now)
        XCTAssertTrue(incomplete.refused); XCTAssertTrue(incomplete.message.contains("unknown 4.000–10.000"), incomplete.message)
        XCTAssertNil(e.file.stage1Complete)
        _ = e.apply(.reviewedThrough, at: 10, now: now)
        XCTAssertEqual(e.file.coverage.count, 2, "records are history")
        XCTAssertTrue(e.unknownGaps.isEmpty)
        commitRally(&e, contact: 5, dead: 6)
        XCTAssertTrue(e.apply(.complete, at: 0, now: now).changed)
        XCTAssertNotNil(e.file.stage1Complete)
        XCTAssertEqual(e.file.stage1Complete?.tool, "RallyLab test")
        // Undo walks back one record change at a time, and leaves nothing selected.
        XCTAssertTrue(e.apply(.undo, at: 0, now: now).changed); XCTAssertNil(e.file.stage1Complete); XCTAssertEqual(e.file.rallies.count, 1)
        XCTAssertTrue(e.apply(.undo, at: 0, now: now).changed); XCTAssertEqual(e.file.rallies.count, 0)
        XCTAssertTrue(e.apply(.undo, at: 0, now: now).changed); XCTAssertEqual(e.file.coverage.count, 1)
        XCTAssertTrue(e.apply(.undo, at: 0, now: now).changed); XCTAssertEqual(e.file.coverage.count, 0)
        XCTAssertTrue(e.apply(.undo, at: 0, now: now).refused)
        XCTAssertFalse(e.canUndo)
        // Every record the editor produces passes the store's validation.
        _ = e.apply(.reviewedThrough, at: 10, now: now)
        commitRally(&e, contact: 1, dead: 2)
        XCTAssertNoThrow(try EventReview.validate(e.file))
    }
}
