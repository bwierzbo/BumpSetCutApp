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
        let shared = try await FrameIdentity.allFrameTimes(of: url)
        XCTAssertEqual(clock.digest, FrameIdentity.digest(of: shared), "the Mac's clock is the shared enumerator's")
        // The x265 fixture's media times start at 1/30 s (its encoder delay) and its edit list shows that frame at
        // 0: on the presentation timeline it has all 180 frames of 3 s at 60 fps, 0 to 2.9833 s — what the player
        // shows and seeks on. (Read as media times it seemed to have 179, from 1/30 s: the last frame fell past the
        // window and every time was one frame late.)
        XCTAssertEqual(clock.times.count, 180)
        XCTAssertEqual(clock.times.first ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(clock.times.last ?? -1, 179.0 / 60, accuracy: 1e-6)
        XCTAssertEqual(clock.index(at: 0), 0)
        XCTAssertEqual(clock.index(at: 2.999), 179)
        XCTAssertEqual(clock.step(from: 0, by: 1), clock.times[1], accuracy: 1e-9)
    }

    func testFrameTimesAreThePlayersPresentationTimesThroughTheEditList() async throws {
        // Ground truth: the image generator, asked for a frame's time with zero tolerance, returns that same time
        // when the time is a presented frame's. Both fixtures carry an edit list (media starts at 1/30 or 2/30 s).
        let bundle = Bundle(for: Self.self)
        for name in ["h264-damaged-inter-frame", "open-gop-hevc-leading3"] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "mp4") ?? bundle.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
            let times = try await FrameIdentity.allFrameTimes(of: url)
            XCTAssertEqual(times.first ?? -1, 0, accuracy: 1e-6, "\(name): the first presented frame is at 0")
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            // (The H.264 fixture is damaged near its end on purpose; the generator substitutes there, so only
            // frames before the damage are asked for.) Every request must succeed: a time the generator cannot
            // produce is a failure of this test, not a frame to skip.
            for i in [0, 1, 2, 30, 60] {
                let shown = try await generator.image(at: CMTime(seconds: times[i], preferredTimescale: 600_000)).actualTime.seconds
                XCTAssertEqual(shown, times[i], accuracy: 1e-4, "\(name) frame \(i)")
            }
        }
    }

    func testPresentationTimesFollowTrimsAndOffsets() {
        func edit(_ s: Double, _ d: Double, to t: Double) -> CMTimeMapping {
            CMTimeMapping(source: CMTimeRange(start: CMTime(seconds: s, preferredTimescale: 600_000), duration: CMTime(seconds: d, preferredTimescale: 600_000)),
                          target: CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600_000), duration: CMTime(seconds: d, preferredTimescale: 600_000)))
        }
        let media = (0..<10).map { Double($0) / 10 }                         // 0, 0.1 … 0.9
        XCTAssertEqual(FrameIdentity.presentationTimes(media: media, edits: []), media, "no edit list: media times are shown as they are")
        // An encoder delay: media 0.2… shown from 0.
        let delayed = FrameIdentity.presentationTimes(media: media, edits: [edit(0.2, 0.8, to: 0)])
        XCTAssertEqual(delayed.count, 8); XCTAssertEqual(delayed.first!, 0, accuracy: 1e-9); XCTAssertEqual(delayed.last!, 0.7, accuracy: 1e-9)
        // A trim that starts mid-frame: the frame showing at the cut is presented from the cut; frames cut off are not frames.
        let trimmed = FrameIdentity.presentationTimes(media: media, edits: [edit(0.35, 0.4, to: 0)])
        XCTAssertEqual(trimmed.map { ($0 * 1000).rounded() / 1000 }, [0, 0.05, 0.15, 0.25, 0.35], "media 0.3 (showing at the cut) to 0.7 (starts before the cut's end)")
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
        // Right after a commit the rally stays selected with an empty draft: selecting it again loads it for editing.
        XCTAssertEqual(e.selected, b); XCTAssertTrue(e.draft.isEmpty)
        _ = e.apply(.select(b), at: 0, now: now)
        XCTAssertEqual(e.draft.rallyId, b, "the just-committed rally is loaded, not a new one started")
        _ = e.apply(.mark(.dead, .earliest), at: 2.2, now: now)
        _ = e.apply(.select(b), at: 0, now: now)
        XCTAssertEqual(e.draft.dead?.earliest, 2.2, "selecting the rally in the draft again keeps the edits")
        _ = e.apply(.cancel, at: 0, now: now)
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

    func testEditingKeepsTheSecondReviewAndTheLegacyLink() {
        var e = editor()
        _ = e.apply(.reviewedThrough, at: 3, now: now)
        let id = commitRally(&e, contact: 0.5, dead: 1.0)
        // A second review and a legacy link arrive on the record (the pilot's selector and repeat pass write them).
        var f = e.file
        f.rallies[0].secondReview = EventReview.SecondReview(annotator: "BW", reviewedAt: "2026-10-28T10:00:00Z", method: "blind_repeat_same_reviewer_24h",
                                                             contact: EventReview.EventTime(earliest: 0.5, latest: 0.5), dead: EventReview.EventTime(earliest: 1.0, latest: 1.0))
        f.rallies[0].legacyIndex = 3; f.rallies[0].legacyStart = 0.4; f.rallies[0].legacyEnd = 1.1; f.rallies[0].sourceMethod = "manual_event"
        e = BoundaryEditor(file: f, annotator: "CD", tool: "t")
        _ = e.apply(.select(id), at: 0, now: now)
        _ = e.apply(.cycleKind, at: 0, now: now)   // a change that leaves the events alone
        XCTAssertTrue(e.apply(.commit, at: 0, now: now).changed)
        var r = e.file.rallies[0]
        XCTAssertEqual(r.rallyId, id); XCTAssertEqual(r.kind, .missedServe)
        XCTAssertNotNil(r.secondReview, "an edit keeps the second review")
        XCTAssertEqual(r.legacyIndex, 3); XCTAssertEqual(r.legacyStart, 0.4); XCTAssertEqual(r.sourceMethod, "manual_event")
        XCTAssertEqual(r.annotator, "CD")
        XCTAssertFalse(r.flags.contains("second_review_before_edit"), "the events did not change")
        _ = e.apply(.select(id), at: 0, now: now)
        _ = e.apply(.mark(.dead, .earliest), at: 1.2, now: now)
        XCTAssertTrue(e.apply(.commit, at: 0, now: now).changed)
        r = e.file.rallies[0]
        XCTAssertEqual(r.dead?.earliest, 1.2)
        XCTAssertEqual(r.secondReview?.dead?.earliest, 1.0, "the second review stays as it was made")
        XCTAssertTrue(r.flags.contains("second_review_before_edit"), "and is flagged as predating the change")
        _ = e.apply(.select(id), at: 0, now: now)
        XCTAssertTrue(e.apply(.commit, at: 0, now: now).changed)
        XCTAssertEqual(e.file.rallies[0].flags.filter { $0 == "second_review_before_edit" }.count, 1, "flagged once")
    }

    func testSeekClockCountsRelativeMovesFromThePendingPosition() {
        var clock = SeekClock()
        let frames = FrameClock(times: (0..<90).map { Double($0) / 30 }, frameRate: 30)
        // Three quick presses while the player still shows frame 10: each counts from the position last asked for.
        var requested: [Double] = []
        for _ in 0..<3 {
            let base = clock.base(playerTime: 10.0 / 30)
            let t = frames.step(from: base, by: 1)
            clock.request(t); requested.append(t)
        }
        XCTAssertEqual(requested.map { frames.index(at: $0) }, [11, 12, 13], "one frame per press, not three requests for frame 11")
        clock.settled()
        XCTAssertEqual(frames.index(at: clock.base(playerTime: 13.0 / 30)), 13, "settled: the player's own time counts again")
    }

    func testAdjacentRalliesWalkTheRecordingInOrder() {
        var e = editor(duration: 10, frameRate: 30)
        _ = e.apply(.reviewedThrough, at: 10, now: now)
        let c = commitRally(&e, contact: 7, dead: 8)
        let a = commitRally(&e, contact: 1, dead: 2)
        let b = commitRally(&e, contact: 4, dead: 5)
        _ = e.apply(.cancel, at: 0, now: now)
        XCTAssertEqual(e.reviewedRallies.map(\.rallyId), [a, b, c], "ordered by start, not by commit")
        XCTAssertEqual(e.adjacentRally(to: 0, forward: true), a)
        XCTAssertEqual(e.adjacentRally(to: 4.5, forward: true), c, "the next rally starting after the playhead")
        XCTAssertEqual(e.adjacentRally(to: 4.5, forward: false), b, "the last rally starting before it")
        XCTAssertNil(e.adjacentRally(to: 0, forward: false))
        XCTAssertNil(e.adjacentRally(to: 9, forward: true))
        _ = e.apply(.select(b), at: 0, now: now)
        XCTAssertEqual(e.adjacentRally(to: 0, forward: true), c, "with one selected, the next in order regardless of the playhead")
        XCTAssertEqual(e.adjacentRally(to: 0, forward: false), a)
        _ = e.apply(.select(c), at: 0, now: now)
        _ = e.apply(.withdraw, at: 0, now: now)
        XCTAssertEqual(e.reviewedRallies.map(\.rallyId), [a, b], "a withdrawn rally is not walked")
        _ = e.apply(.select(b), at: 0, now: now)
        XCTAssertNil(e.adjacentRally(to: 0, forward: true))
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

    func testReviewedThroughFillsGapsBetweenReviewedStretches() {
        var e = editor(duration: 40, frameRate: 30)
        _ = e.apply(.reviewedThrough, at: 10, now: now)
        _ = e.apply(.reviewedThrough, at: 30, now: now)   // 10–30 in one go, then the record is edited to leave a gap
        var f = e.file
        f.coverage = [EventReview.Coverage(start: 0, end: 10, at: "t", annotator: "A"), EventReview.Coverage(start: 20, end: 30, at: "t", annotator: "A")]
        e = BoundaryEditor(file: f, annotator: "BW", tool: "t")
        XCTAssertEqual(e.unknownGaps.map { "\($0.start)-\($0.end)" }, ["10.0-20.0", "30.0-40.0"])
        XCTAssertEqual(e.unknownStart(before: 15), 10, "the gap the playhead is in starts where the last reviewed stretch ended")
        XCTAssertNil(e.unknownStart(before: 25), "inside reviewed coverage")
        XCTAssertEqual(e.unknownStart(before: 35), 30)
        XCTAssertTrue(e.apply(.reviewedThrough, at: 25, now: now).refused)
        XCTAssertTrue(e.apply(.reviewedThrough, at: 15, now: now).changed)
        XCTAssertEqual(EventReview.union(e.file.coverage).map { "\($0.start)-\($0.end)" }, ["0.0-15.0", "20.0-30.0"])
        XCTAssertTrue(e.apply(.reviewedThrough, at: 20, now: now).changed, "closing the gap merges the stretches")
        XCTAssertEqual(EventReview.union(e.file.coverage).map { "\($0.start)-\($0.end)" }, ["0.0-30.0"])
        XCTAssertTrue(e.apply(.reviewedThrough, at: 40, now: now).changed)
        XCTAssertTrue(e.unknownGaps.isEmpty)
        XCTAssertTrue(e.apply(.complete, at: 0, now: now).changed)
    }

    func testReviewedThroughCompletionAndUndo() {
        var e = editor(duration: 10, frameRate: 30)
        XCTAssertTrue(e.apply(.reviewedThrough, at: 4, now: now).changed)
        XCTAssertEqual(e.reviewedUntil, 4)
        XCTAssertTrue(e.apply(.reviewedThrough, at: 3, now: now).refused, "3 s is inside reviewed coverage")
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
    func testEventsLandOnTheDisplayedFramesPresentationTimeNotThePlayersClock() {
        // 29.97 fps-like times: a scrub or a pause leaves the player's clock between frames.
        let times = (0..<90).map { Double($0) * 1001 / 30000 }
        let clock = FrameClock(times: times, frameRate: 29.97)
        XCTAssertEqual(clock.snap(1.02), times[30], "between frames 30 and 31: frame 30 is shown")
        XCTAssertEqual(clock.snap(times[31] - 1e-9), times[31], "a hair before a frame's start is that frame")
        XCTAssertEqual(clock.snap(-0.5), times[0]); XCTAssertEqual(clock.snap(10), times[89])
        XCTAssertNil(FrameClock(times: [], frameRate: 30).snap(1), "no frame times: nothing to land on")
        // The editor, given the snapped time, records exactly that frame.
        var e = editor(duration: 3, frameRate: 29.97)
        _ = e.apply(.mark(.contact, .earliest), at: clock.snap(1.02)!, now: now)
        XCTAssertEqual(e.draft.contact?.earliest, times[30]); XCTAssertEqual(e.draft.contact?.latest, times[30])
    }

    func testOnlyMarksLandOnFramesSoCoverageCanReachTheRecordingsEnd() {
        // The last frame starts at 0.1 s but the recording lasts 0.3 s (a long final frame, an audio tail):
        // "reviewed through here" at the end must reach 0.3, which no frame start can give.
        let clock = FrameClock(times: [0, 0.0333, 0.0667, 0.1], frameRate: 30)
        XCTAssertEqual(clock.snap(0.3), 0.1, "the shown frame at the end is the last one")
        XCTAssertTrue(BoundaryEditor.Action.mark(.contact, .earliest).landsOnFrame)
        for action in [BoundaryEditor.Action.reviewedThrough, .span(.transition), .commit, .complete, .select(nil), .cancel, .undo, .withdraw] {
            XCTAssertFalse(action.landsOnFrame, "\(action) takes the playhead itself")
        }
        var e = editor(duration: 0.3, frameRate: 30)
        _ = e.apply(.reviewedThrough, at: clock.snap(0.3)!, now: now)
        XCTAssertFalse(e.unknownGaps.isEmpty, "snapped to the last frame's start, the end stays unknown")
        var f = editor(duration: 0.3, frameRate: 30)
        _ = f.apply(.reviewedThrough, at: 0.3, now: now)
        XCTAssertTrue(f.unknownGaps.isEmpty)
        XCTAssertTrue(f.apply(.complete, at: 0.3, now: now).changed, "the recording completes")
    }


    // MARK: - Second review (blind repeat, protocol §6) and the legacy link

    func testANewRallyIsLinkedToTheLegacyMarkItOverlapsMost() {
        var e = editor(duration: 60)
        e.legacyMarks = [.init(index: 0, start: 2, end: 6), .init(index: 1, start: 10, end: 20), .init(index: 2, start: 40, end: 45)]
        commitRally(&e, contact: 11, dead: 19)
        XCTAssertEqual(e.file.rallies[0].legacyIndex, 1); XCTAssertEqual(e.file.rallies[0].legacyStart, 10); XCTAssertEqual(e.file.rallies[0].legacyEnd, 20)
        // No overlap: the nearest start within 3 s, else none.
        commitRally(&e, contact: 38, dead: 39.5)
        XCTAssertEqual(e.file.rallies[1].legacyIndex, 2)
        commitRally(&e, contact: 30, dead: 33)
        XCTAssertNil(e.file.rallies[2].legacyIndex)
    }

    func testTheSameReviewerMayRepeatBlindOnlyAfter24Hours() {
        var e = editor(duration: 60)
        let id = commitRally(&e, contact: 10, dead: 20)
        e.setMode(.secondReview)
        XCTAssertNil(e.selected, "switching modes drops the selection")
        _ = e.apply(.select(id), at: 0, now: now)
        XCTAssertEqual(e.draft.rallyId, id); XCTAssertNil(e.draft.contact, "blind: the first result is not loaded into the draft")
        _ = e.apply(.mark(.contact, .earliest), at: 10.1, now: now.addingTimeInterval(3600))
        _ = e.apply(.mark(.dead, .earliest), at: 19.9, now: now.addingTimeInterval(3600))
        let early = e.apply(.commit, at: 19.9, now: now.addingTimeInterval(3600))
        XCTAssertTrue(early.refused); XCTAssertTrue(early.message.contains("24 h"), early.message)
        XCTAssertNil(e.file.rallies[0].secondReview)
        // A day later it is recorded beside the first result, which is untouched.
        let later = now.addingTimeInterval(24 * 3600 + 1)
        let out = e.apply(.commit, at: 19.9, now: later)
        XCTAssertTrue(out.changed, out.message)
        let r = e.file.rallies[0]
        XCTAssertEqual(r.contact?.earliest, 10); XCTAssertEqual(r.dead?.earliest, 20)
        XCTAssertEqual(r.secondReview?.method, EventReview.SecondReview.sameReviewer)
        XCTAssertEqual(r.secondReview?.contact?.earliest, 10.1); XCTAssertEqual(r.secondReview?.dead?.earliest, 19.9)
        XCTAssertEqual(r.secondReview?.tool, "RallyLab test"); XCTAssertEqual(r.secondReview?.annotator, "BW")
        XCTAssertNil(e.selected); XCTAssertTrue(e.canUndo)
    }

    func testTheSameAccountOnTheOtherPlatformIsTheSameReviewer() {
        var e = editor(duration: 60)
        let id = commitRally(&e, contact: 10, dead: 20)   // "BW" on the Mac
        var phone = BoundaryEditor(file: e.file, annotator: "bw", tool: "Labeler 1.0")   // the same account, differently cased
        phone.setMode(.secondReview)
        _ = phone.apply(.select(id), at: 0, now: now)
        _ = phone.apply(.mark(.contact, .earliest), at: 10.1, now: now)
        _ = phone.apply(.mark(.dead, .earliest), at: 19.9, now: now)
        XCTAssertTrue(phone.apply(.commit, at: 19.9, now: now.addingTimeInterval(3600)).refused, "the same person: the 24-h rule applies across platforms")
        XCTAssertTrue(phone.apply(.commit, at: 19.9, now: now.addingTimeInterval(25 * 3600)).changed)
        XCTAssertEqual(phone.file.rallies[0].secondReview?.method, EventReview.SecondReview.sameReviewer)
        XCTAssertEqual(phone.file.rallies[0].secondReview?.tool, "Labeler 1.0")
    }

    func testAnotherReviewerIsASecondReviewerAtOnce() {
        var e = editor(duration: 60)
        let id = commitRally(&e, contact: 10, dead: 20)
        var other = BoundaryEditor(file: e.file, annotator: "KD", tool: "Labeler 1.0")
        other.setMode(.secondReview)
        _ = other.apply(.select(id), at: 0, now: now)
        _ = other.apply(.mark(.contact, .earliest), at: 10.05, now: now)
        _ = other.apply(.mark(.dead, .earliest), at: 20.2, now: now)
        XCTAssertTrue(other.apply(.commit, at: 20.2, now: now).changed)
        XCTAssertEqual(other.file.rallies[0].secondReview?.method, EventReview.SecondReview.otherReviewer)
        XCTAssertEqual(other.file.rallies[0].secondReview?.tool, "Labeler 1.0")
    }

    func testASecondReviewRecordsTheTwoEventsOnly() {
        var e = editor(duration: 60)
        let id = commitRally(&e, contact: 10, dead: 20)
        e.setMode(.secondReview)
        for action in [BoundaryEditor.Action.withdraw, .complete, .reviewedThrough, .span(.transition), .cycleKind, .cycleEdge, .toggleFlag("ambiguous")] {
            let out = e.apply(action, at: 30, now: now)
            XCTAssertTrue(out.refused, "\(action) must be refused in a second review")
            XCTAssertFalse(out.changed)
        }
        XCTAssertTrue(e.apply(.commit, at: 30, now: now).refused, "nothing selected")
        _ = e.apply(.select(id), at: 0, now: now)
        XCTAssertTrue(e.apply(.commit, at: 30, now: now).refused, "nothing marked")
        XCTAssertEqual(e.file.rallies.count, 1); XCTAssertNil(e.file.rallies[0].secondReview)
        e.setMode(.first)
        XCTAssertEqual(e.mode, .first); XCTAssertNil(e.selected)
    }

    func testAFreshRepeatAfterAnEditIsCurrentAgain() {
        var e = editor(duration: 60)
        let id = commitRally(&e, contact: 10, dead: 20)
        let later = now.addingTimeInterval(25 * 3600)
        e.setMode(.secondReview)
        _ = e.apply(.select(id), at: 0, now: later)
        _ = e.apply(.mark(.contact, .earliest), at: 10.1, now: later)
        _ = e.apply(.mark(.dead, .earliest), at: 20, now: later)
        XCTAssertTrue(e.apply(.commit, at: 20, now: later).changed)
        // The primary review is edited: the repeat becomes stale evidence.
        e.setMode(.first)
        _ = e.apply(.select(id), at: 0, now: later)
        _ = e.apply(.mark(.contact, .earliest), at: 11, now: later)
        XCTAssertTrue(e.apply(.commit, at: 11, now: later).changed)
        XCTAssertTrue(e.file.rallies[0].flags.contains("second_review_before_edit"))
        // A fresh repeat against the edited review clears it.
        let evenLater = later.addingTimeInterval(25 * 3600)
        e.setMode(.secondReview)
        _ = e.apply(.select(id), at: 0, now: evenLater)
        _ = e.apply(.mark(.contact, .earliest), at: 11, now: evenLater)
        _ = e.apply(.mark(.dead, .earliest), at: 20, now: evenLater)
        XCTAssertTrue(e.apply(.commit, at: 20, now: evenLater).changed)
        XCTAssertFalse(e.file.rallies[0].flags.contains("second_review_before_edit"))
        XCTAssertEqual(e.file.rallies[0].secondReview?.contact?.earliest, 11)
    }

    func testASyncDuringABlindRepeatNeverShowsOrLoadsThePrimaryEvents() {
        var e = editor(duration: 60)
        let id = commitRally(&e, contact: 10, dead: 20)
        e.setMode(.secondReview)
        _ = e.apply(.select(id), at: 0, now: now)
        _ = e.apply(.mark(.contact, .earliest), at: 10.2, now: now)
        var theirs = e.file; theirs.revision = 5; theirs.rallies[0].contact = .init(earliest: 9, latest: 9)
        XCTAssertTrue(e.adopt(theirs))
        XCTAssertNil(e.draftConflict, "no conflict banner with the primary times")
        XCTAssertEqual(e.draft.contact?.earliest, 10.2, "the blind marks stay the reviewer's own")
        e.resolveDraftConflict(keepMine: false)
        XCTAssertEqual(e.draft.contact?.earliest, 10.2)
    }

    func testASecondReviewNeedsBothEventsUnlessTheEdgeCutOneOff() {
        var e = editor(duration: 60)
        let id = commitRally(&e, contact: 10, dead: 20)
        let later = now.addingTimeInterval(25 * 3600)
        e.setMode(.secondReview)
        _ = e.apply(.select(id), at: 0, now: later)
        _ = e.apply(.mark(.contact, .earliest), at: 10.1, now: later)
        let half = e.apply(.commit, at: 10.1, now: later)
        XCTAssertTrue(half.refused); XCTAssertTrue(half.message.contains("ball dead"), half.message)
        XCTAssertNil(e.file.rallies[0].secondReview, "nothing recorded"); XCTAssertEqual(e.draft.contact?.earliest, 10.1, "the incomplete repeat stays in the draft")
        _ = e.apply(.mark(.dead, .earliest), at: 20, now: later)
        XCTAssertTrue(e.apply(.commit, at: 20, now: later).changed)
        // A rally cut off at the start: the repeat may lack the contact, as the first review does.
        var f = editor(duration: 60)
        _ = f.apply(.cycleEdge, at: 0, now: now)
        _ = f.apply(.mark(.dead, .earliest), at: 3, now: now)
        XCTAssertTrue(f.apply(.commit, at: 3, now: now).changed)
        let edgeId = f.selected!
        f.setMode(.secondReview)
        _ = f.apply(.select(edgeId), at: 0, now: later)
        _ = f.apply(.mark(.dead, .earliest), at: 3.1, now: later)
        XCTAssertTrue(f.apply(.commit, at: 3.1, now: later).changed)
    }

    func testAConflictRaisedBeforeABlindRepeatIsClearedWhenItStarts() {
        var e = editor(duration: 60)
        let id = commitRally(&e, contact: 10, dead: 20)
        _ = e.apply(.select(id), at: 0, now: now)
        _ = e.apply(.toggleFlag("ambiguous"), at: 0, now: now)
        var theirs = e.file; theirs.revision = 3; theirs.rallies[0].contact = .init(earliest: 9, latest: 9)
        XCTAssertTrue(e.adopt(theirs)); XCTAssertNotNil(e.draftConflict)
        e.setMode(.secondReview)
        XCTAssertNil(e.draftConflict, "no banner with the primary times in a blind repeat")
        _ = e.apply(.select(id), at: 0, now: now)
        XCTAssertNil(e.draftConflict); XCTAssertNil(e.draft.contact)
    }
}
