//
//  CoverageAuditPhoneTests.swift
//  RallyLabTests
//
//  The phone's Audit mode as shared code (Labeler/Shared: CoverageAuditPhone, CoverageAuditSync), on synthetic
//  draws and records only: the record format both devices write, the draw's bytes and identity, viewing credit,
//  the reviewer, the blind repeat and its 24 hours, refusals (withheld, unpublished, other footage, moved marks),
//  resuming after the app is killed, and the look-by-look merge — offline retries, duplicates, conflicts.
//  No verdict here is a review of any real recording.
//

import CryptoKit
import XCTest
@testable import RallyLab

final class CoverageAuditPhoneTests: XCTestCase {
    private typealias A = CoverageAudit
    private typealias P = CoverageAuditPhone
    private let me = "00000000-0000-0000-0000-00000000000a"
    private let other = "00000000-0000-0000-0000-00000000000e"
    private let t0 = ISO8601DateFormatter().date(from: "2026-11-17T10:00:00Z")!
    private let videoId = UUID(uuidString: "10000000-0000-0000-0000-00000000000a")!

    private let body = #"{"schemaVersion":"coverage_audit_draw_v2","drawId":"d1","dataset":{"name":"rc-test","timescale":600},"recordings":[{"recordingId":"a","groupId":"g","contentFingerprint":"file:a","marksSha256":"m0","durationTicks":6000,"intervals":[{"index":0,"startTick":0,"endTick":600},{"index":1,"startTick":1200,"endTick":3000},{"index":2,"startTick":4000,"endTick":6000}],"repeatIndices":[1]},{"recordingId":"b","groupId":"h","contentFingerprint":"file:b","marksSha256":"m0","durationTicks":1200,"intervals":[{"index":0,"startTick":0,"endTick":1200}],"repeatIndices":[]}]}"#

    private func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    /// The phone's store for draw d1, with both recordings published (a: intervals 0 and 1 still as drawn; 2 moved).
    private func phone() throws -> P {
        var p = try P(row: LabelCoverageAuditDraw(project: "Scratch", drawId: "d1", drawSha256: sha(body), body: body, publishedAt: nil))
        p.recordings["a"] = LabelCoverageAuditRecording(project: "Scratch", drawId: "d1", recordingId: "a", videoId: videoId, sourceFingerprint: "file:a",
                                                        marksSha256: "m1", openIndices: [0, 1], publishedAt: nil)
        p.recordings["b"] = LabelCoverageAuditRecording(project: "Scratch", drawId: "d1", recordingId: "b", videoId: UUID(), sourceFingerprint: "file:b",
                                                        marksSha256: "m1", openIndices: [0], publishedAt: nil)
        return p
    }

    private func played(_ a: Int, _ b: Int, rate: Double = 2) -> A.PlayedCoverage {
        var c = A.PlayedCoverage(); c.credit(fromTick: a, toTick: b, rate: rate); return c
    }

    private func video(fingerprint: String = "file:a", digest: String? = "frames") -> LabelVideo {
        var v = LabelVideo(id: videoId, project: "Scratch", sessionName: "a", title: "", surface: .beach, camera: .endlineGround, lighting: "",
                           split: "train", clipPath: "rallylab/Scratch/a.mp4", duration: 10, ralliesFound: [], status: .rallylab, updatedAt: nil)
        v.sourceFingerprint = fingerprint
        v.frameTimesDigest = digest
        return v
    }

    private func refused(_ expected: A.Failure, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? A.Failure, expected, "\($0)", file: file, line: line) }
    }

    // MARK: - One record format, one draw

    func testARecordMadeOnThePhoneIsTheMacsCoverageAuditV2Record() throws {
        var p = try phone()
        try p.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: me, tool: "Labeler test", now: t0)
        let record = try XCTUnwrap(p.local["a"])
        // The Mac reads it as any sidecar it wrote: the same reader, the same validation.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID().uuidString).coverageaudit.json")
        defer { try? FileManager.default.removeItem(at: url) }
        try A.write(record, to: url)
        XCTAssertEqual(try A.read(url), record)
        XCTAssertEqual(record.annotationVersion, "coverage_audit_v2")
        XCTAssertEqual(record.drawSha256, sha(body), "bound to the draw's bytes")
        XCTAssertEqual(record.sourceFingerprint, "file:a", "and to the draw's footage")
        XCTAssertEqual(record.marksSha256, "m1", "stamped with the marks the Mac published")
        XCTAssertTrue(record.blindToPipeline)
        // The server's row, as PostgREST returns it, decodes to the same record.
        let rowJSON = #"{"project":"Scratch","draw_id":"d1","recording_id":"a","revision":1,"updated_by":null,"updated_at":null,"record":"#
            + String(decoding: try JSONEncoder().encode(record), as: UTF8.self) + "}"
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        XCTAssertEqual(try decoder.decode(LabelCoverageAudit.self, from: Data(rowJSON.utf8)).record, record)
    }

    func testTheDrawIsTakenOnlyAsTheBytesPublishedAndStaysCheckedInTheStore() throws {
        XCTAssertThrowsError(try P(row: LabelCoverageAuditDraw(project: "Scratch", drawId: "d1", drawSha256: sha(body + " "), body: body, publishedAt: nil)),
                             "bytes that are not the ones hashed are refused")
        XCTAssertThrowsError(try P(row: LabelCoverageAuditDraw(project: "Scratch", drawId: "d2", drawSha256: sha(body), body: body, publishedAt: nil)),
                             "a body under another draw's id is refused")
        // A store whose bytes were altered on the phone does not read (fail closed, never half-read).
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try phone())) as! [String: Any]
        json["drawBody"] = Data((body.replacingOccurrences(of: "\"endTick\":600", with: "\"endTick\":601")).utf8).base64EncodedString()
        XCTAssertThrowsError(try JSONDecoder().decode(P.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testTheTimelineIsTheDrawsTicksOnTheOneClock() throws {
        XCTAssertEqual(A.timescale, RallyClassifierExporter.timescale)
        for s in [0.0, 0.0008, 1.2345, 299.99916, 300.135] { XCTAssertEqual(A.tick(s), RallyClassifierExporter.tick(s)) }
        var p = try phone()
        try p.give(.finding(.init(kind: .missedServe, approxStartSec: 2.5)), pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: .init(), reviewer: me, tool: "t", now: t0)
        let review = try XCTUnwrap(p.local["a"]?.review(1))
        XCTAssertEqual([review.startTick, review.endTick], [1200, 3000], "the verdict is on the interval's own ticks")
        refused(.badFinding("its approximate time is outside interval 1")) {
            try p.give(.finding(.init(kind: .missedServe, approxStartSec: 6.5)), pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: .init(), reviewer: me, tool: "t", now: t0)
        }
    }

    // MARK: - Viewing credit

    func testCleanNeedsTheWholeIntervalPlayedForwardAtThreeTimesOrSlower() throws {
        var p = try phone()
        refused(.notPlayed(index: 1, missingSec: 3)) { try p.give(.clean, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: .init(), reviewer: me, tool: "t", now: t0) }
        refused(.notPlayed(index: 1, missingSec: 3)) { try p.give(.clean, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000, rate: 4), reviewer: me, tool: "t", now: t0) }
        // A seek mid-way and a pause: what was skipped earns nothing.
        var tracker = A.PlayTracker()
        tracker.began(at: 1.0)
        (1...40).forEach { tracker.observed(1.0 + Double($0) * 0.05, rate: 2) }
        tracker.jumped()
        tracker.began(at: 4.0)
        (1...40).forEach { tracker.observed(4.0 + Double($0) * 0.05, rate: 2) }
        tracker.stopped(at: 6.0, rate: 2)
        XCTAssertFalse(tracker.played.covers(A.Span(startTick: 1200, endTick: 3000)), "3–4 s was jumped over")
        refused(.notPlayed(index: 1, missingSec: 1.0)) { try p.give(.clean, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: tracker.played, reviewer: me, tool: "t", now: t0) }
        // Paused, then a step longer than could have played (the app was away): nothing across it.
        var away = A.PlayTracker()
        away.began(at: 1.0); away.observed(1.5, rate: 1); away.observed(4.0, rate: 1)
        XCTAssertEqual(away.played.playedTicks(in: A.Span(startTick: 0, endTick: 6000)), 300, "only the half second actually seen")
        try p.give(.clean, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000, rate: 0.5), reviewer: me, tool: "t", now: t0)
        XCTAssertEqual(p.local["a"]?.review(1)?.playedAllAtMaxRate, 0.5)
    }

    // MARK: - Reviewer, refusals

    func testTheReviewerIsTheSignedInAccountAndALookIsItsReviewersAlone() throws {
        var p = try phone()
        refused(.noReviewer) { try p.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: "  ", tool: "t", now: t0) }
        try p.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: other, tool: "t", now: t0)
        XCTAssertEqual(p.local["a"]?.review(0)?.reviewer, other)
        refused(.othersLook(index: 0, reviewer: other)) { try p.give(.withdraw, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: .init(), reviewer: me, tool: "t", now: t0) }
    }

    func testWithheldUnpublishedOtherFootageAndMovedIntervalsAreRefused() throws {
        var p = try phone()
        XCTAssertNil(p.unavailable("a", video: video(), withheld: false))
        XCTAssertNotNil(p.unavailable("a", video: video(), withheld: true), "withheld")
        XCTAssertNotNil(p.unavailable("a", video: video(), withheld: nil), "the list is not known: never read as not withheld")
        XCTAssertNotNil(p.unavailable("a", video: video(fingerprint: "file:other"), withheld: false), "a copy of other footage")
        XCTAssertNotNil(p.unavailable("a", video: video(digest: nil), withheld: false), "no frame identity to check the copy against")
        XCTAssertNotNil(p.unavailable("a", video: nil, withheld: false), "no copy")
        var retyped = video()
        retyped.recordingType = "edited"
        XCTAssertEqual(p.unavailable("a", video: retyped, withheld: false), "typed edited since the draw: not audited, and no source of negatives")
        retyped.recordingType = "continuous"
        XCTAssertNil(p.unavailable("a", video: retyped, withheld: false))
        XCTAssertNotNil(p.unavailable("zz", video: video(), withheld: false), "not drawn")
        p.recordings["a"] = nil
        XCTAssertNotNil(p.unavailable("a", video: video(), withheld: false), "not published by the Mac")
        p = try phone()
        // Interval 2 is no longer unmarked as drawn (the marks moved): no verdict on it; taking one back stays possible.
        refused(.marksChanged(recording: "a", index: 2)) { try p.give(.clean, pass: .first, recordingId: "a", index: 2, video: video(), withheld: false, played: played(4000, 6000), reviewer: me, tool: "t", now: t0) }
        // The Mac published other footage than the draw's: nothing is recorded against it.
        p.recordings["a"]?.sourceFingerprint = "file:changed"
        refused(.notOnThisDevice(recording: "a", why: "the Mac published other footage than the draw's")) {
            try p.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: me, tool: "t", now: t0)
        }
        XCTAssertNil(p.local["a"])
        // Withheld after it was opened: the next verdict is refused (the phone asks at every verdict, not only at opening).
        p = try phone()
        refused(.notOnThisDevice(recording: "a", why: "withheld: no review of it anywhere")) {
            try p.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: true, played: played(0, 600), reviewer: me, tool: "t", now: t0)
        }
        XCTAssertNil(p.local["a"])
    }

    // MARK: - One look at each interval (amendment 2)

    func testNoSecondLookIsOwedOrGivenOnThePhone() throws {
        var p = try phone()
        try p.give(.finding(.init(kind: .uncertain, approxStartSec: 1, note: "blocked")), pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: me, tool: "t", now: t0)
        try p.give(.clean, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000), reviewer: me, tool: "t", now: t0)
        let all: (String) -> Bool = { _ in true }
        let later = t0.addingTimeInterval(48 * 3600)
        // Interval 1 is the draw's repeat interval and interval 0 was left uncertain: neither is queued again, for anyone.
        XCTAssertEqual(p.queue(.repeatLook, reviewable: all, reviewer: me, now: later), [])
        XCTAssertEqual(p.queue(.repeatLook, reviewable: all, reviewer: other, now: later), [])
        XCTAssertEqual(p.queue(.resolution, reviewable: all, reviewer: me, now: later), [])
        refused(.noSecondLook(index: 1)) {
            try p.give(.clean, pass: .repeatLook, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000), reviewer: other, tool: "t", now: later)
        }
        refused(.noSecondLook(index: 1)) {
            try p.give(.clean, pass: .resolution, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000), reviewer: me, tool: "t", now: later)
        }
        XCTAssertNil(p.local["a"]?.repeatPass)
        XCTAssertEqual(p.totals(.first, reviewable: all).findings, [.uncertain: 1], "the uncertain interval stands")
        XCTAssertEqual(p.totals(.repeatLook, reviewable: all).left, 0)
    }

    // MARK: - Progress and resuming

    func testAPlaceKeptInALaterPassByAnOlderBuildResumesInTheFirstPass() throws {
        // An older build left the phone in Resolve, on a disagreement its record still holds.
        var p = try phone()
        try p.give(.clean, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000), reviewer: me, tool: "t", now: t0)
        p.local["a"] = CoverageAuditSync.setting(.init(pass: .repeatLook, index: 1), to: .repeatLook(A.RepeatReview(index: 1, verdict: .notClean, reviewer: other, reviewedAt: "2026-11-17T10:00:00Z",
                                                                                                                 playedAllAtMaxRate: 2, findings: [.init(kind: .missedServe, approxStartSec: 3)])), in: try XCTUnwrap(p.local["a"]))
        let all: (String) -> Bool = { _ in true }
        XCTAssertEqual(p.queue(.resolution, reviewable: all, reviewer: me, now: t0).map(\.index), [1], "the old disagreement is still counted as unresolved")
        for pass in [A.Pass.resolution, .repeatLook] {
            p.position = P.Position(pass: pass, recordingId: "a", index: 1)
            XCTAssertEqual(p.resume(reviewable: all, reviewer: me, now: t0), P.Position(pass: .first, recordingId: "a", index: 0), "the first interval still owed its look")
        }
    }

    func testTotalsAndResumingAfterTheAppIsKilled() throws {
        var p = try phone()
        let reviewable: (String) -> Bool = { $0 == "a" }
        XCTAssertEqual(p.totals(.first, reviewable: reviewable), P.Totals(reviewed: 0, total: 4, left: 2, recordingsDone: 0, recordings: 2, findingsHidden: false, unavailable: 1, pending: 0))
        try p.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: me, tool: "t", now: t0)
        p.position = P.Position(pass: .first, recordingId: "a", index: 1)
        let t = p.totals(.first, reviewable: reviewable)
        XCTAssertEqual([t.reviewed, t.left, t.recordingsDone, t.pending], [1, 1, 0, 1])
        // Killed and launched again: the store read back holds the verdict, what is unsent, and where the reviewer was.
        let back = try JSONDecoder().decode(P.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.resume(reviewable: reviewable, reviewer: me, now: t0), P.Position(pass: .first, recordingId: "a", index: 1))
        var done = back
        try done.give(.clean, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000), reviewer: me, tool: "t", now: t0)
        XCTAssertNil(done.resume(reviewable: reviewable, reviewer: me, now: t0), "nothing left in the pass: no interval is offered")
        XCTAssertEqual(done.totals(.first, reviewable: reviewable).recordingsDone, 1)
    }

    func testTheDrawIsKeptUntilAReplacementComesAndNothingUnsettledIsDropped() throws {
        let held = try phone()
        let d1 = LabelCoverageAuditDraw(project: "Scratch", drawId: "d1", drawSha256: sha(body), body: body, publishedAt: nil)
        let body2 = body.replacingOccurrences(of: #""drawId":"d1""#, with: #""drawId":"d2","supersedes":["d1"]"#)
        let d2 = LabelCoverageAuditDraw(project: "Scratch", drawId: "d2", drawSha256: sha(body2), body: body2, publishedAt: nil)
        let other = LabelCoverageAuditDraw(project: "Scratch", drawId: "d9", drawSha256: sha(body.replacingOccurrences(of: #""drawId":"d1""#, with: #""drawId":"d9""#)),
                                           body: body.replacingOccurrences(of: #""drawId":"d1""#, with: #""drawId":"d9""#), publishedAt: nil)
        XCTAssertEqual(P.choose(held: nil, published: [d1]), .start(d1))
        XCTAssertEqual(P.choose(held: nil, published: []), .nothing)
        XCTAssertEqual(P.choose(held: held, published: [d1, other]), .keep, "a newer draw that does not replace it changes nothing")
        XCTAssertEqual(P.choose(held: held, published: [d1, d2]), .start(d2), "settled, and replaced: the replacement")
        var busy = held
        try busy.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: me, tool: "t", now: t0)
        guard case .keepUnsettled = P.choose(held: busy, published: [d1, d2]) else { return XCTFail("an unsent verdict keeps the draw") }
        guard case .keepUnsettled = P.choose(held: busy, published: []) else { return XCTFail("withdrawn too") }
        XCTAssertEqual(P.choose(held: held, published: [other]), .start(other), "settled and withdrawn: the newest published")
    }

    func testTheStage2DrawThatFollowsTheHeldPilotIsStartedOnceNothingOfThePilotIsUnsettled() throws {
        let held = try phone()
        func row(_ id: String, _ extra: String) -> LabelCoverageAuditDraw {
            let b = body.replacingOccurrences(of: #""drawId":"d1""#, with: #""drawId":"\#(id)"\#(extra)"#)
            return LabelCoverageAuditDraw(project: "Scratch", drawId: id, drawSha256: sha(b), body: b, publishedAt: nil)
        }
        let pilot = LabelCoverageAuditDraw(project: "Scratch", drawId: "d1", drawSha256: sha(body), body: body, publishedAt: nil)
        let stage2 = row("d2", #","follows":{"drawId":"d1","sha256":"\#(sha(body))"}"#)
        XCTAssertEqual(P.choose(held: held, published: [pilot, stage2]), .start(stage2), "the pilot stays published; the review goes on in stage 2")
        let ofAnotherPilot = row("d3", #","follows":{"drawId":"d1","sha256":"\#(String(repeating: "0", count: 64))"}"#)
        XCTAssertEqual(P.choose(held: held, published: [pilot, ofAnotherPilot]), .keep, "a draw that follows other bytes under the same id is not this pilot's stage 2")
        let elsewhere = LabelCoverageAuditDraw(project: "Other", drawId: stage2.drawId, drawSha256: stage2.drawSha256, body: stage2.body, publishedAt: nil)
        XCTAssertEqual(P.choose(held: held, published: [pilot, elsewhere]), .keep, "another project's draw")
        var busy = held
        try busy.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: me, tool: "t", now: t0)
        guard case .keepUnsettled = P.choose(held: busy, published: [pilot, stage2]) else { return XCTFail("an unsent pilot verdict keeps the pilot") }
        // Once on stage 2, the pilot (older, still published, naming nothing) does not take the phone back.
        let onStage2 = try P(row: stage2)
        XCTAssertEqual(P.choose(held: onStage2, published: [pilot, stage2]), .keep)
    }

    func testAStoreThatCantBeReadIsSetAsideNeverReplaced() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("coverage-audit.json")
        XCTAssertEqual(P.load(from: url), .none)
        let p = try phone()
        try JSONEncoder().encode(p).write(to: url)
        XCTAssertEqual(P.load(from: url), .store(p))
        let garbled = Data("{\"project\":\"Scratch\",\"local\":".utf8)
        try garbled.write(to: url)
        guard case .setAside(let kept, _) = P.load(from: url, now: t0) else { return XCTFail("set aside") }
        XCTAssertEqual(try Data(contentsOf: kept), garbled, "kept whole")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a new store starts beside it, not over it")
    }

    // MARK: - Synchronising

    private func row(_ record: A.File, revision: Int) -> LabelCoverageAudit {
        LabelCoverageAudit(project: "Scratch", drawId: "d1", recordingId: record.recordingId, record: record, revision: revision, updatedBy: nil, updatedAt: nil)
    }

    func testAnUnsentVerdictSurvivesBeingOfflineAndIsSentOnceNotTwice() throws {
        var p = try phone()
        try p.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: me, tool: "t", now: t0)
        // Offline: the send never happened. The next round decides the same push from what is kept.
        guard case .push(let first, let expected) = p.merge("a", server: nil) else { return XCTFail("a new record goes up") }
        XCTAssertEqual(expected, 0)
        guard case .push(let again, 0) = p.merge("a", server: nil) else { return XCTFail("still owed after a failed send") }
        XCTAssertEqual(again, first)
        // The server took it: the next round has nothing to send (a duplicate is never made).
        p.pushed(first, saved: row(first, revision: 1))
        XCTAssertEqual(p.merge("a", server: row(first, revision: 1)), .upToDate)
        XCTAssertEqual(p.totals(.first, reviewable: { _ in true }).pending, 0)
        // The reply was lost: the server has revision 1 and the phone does not know it. The same content is not sent again.
        var lost = try phone()
        lost.local["a"] = first
        XCTAssertEqual(lost.merge("a", server: row(first, revision: 1)), .upToDate)
        XCTAssertEqual(lost.revision["a"], 1)
    }

    func testTheOtherDevicesLooksComeInAndAConflictKeepsTheirsAndMineAside() throws {
        var mac = try phone(), phone = try phone()
        // The Mac reviewed interval 0, the server has it (revision 1); the phone has its own look on interval 1, unsent.
        try mac.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: me, tool: "RallyLab", now: t0)
        let server1 = row(try XCTUnwrap(mac.local["a"]), revision: 1)
        try phone.give(.clean, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000), reviewer: me, tool: "Labeler", now: t0)
        guard case .push(let merged, 1) = phone.merge("a", server: server1) else { return XCTFail("merged, then sent on revision 1") }
        XCTAssertEqual(merged.intervals.map(\.index), [0, 1], "both looks: nobody's overwritten")
        phone.pushed(merged, saved: row(merged, revision: 2))
        // Both devices then change the same look (interval 1) differently.
        var macRecord = merged
        macRecord = CoverageAuditSync.setting(.init(pass: .first, index: 1), to: .first(A.Review(index: 1, startTick: 1200, endTick: 3000, verdict: .notClean,
                                                                                                 reviewer: me, reviewedAt: "2026-11-17T11:00:00Z", playedAllAtMaxRate: 2,
                                                                                                 findings: [.init(kind: .missedRally, approxStartSec: 3)])), in: macRecord)
        let server3 = row(macRecord, revision: 3)
        try phone.give(.withdraw, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: .init(), reviewer: me, tool: "Labeler", now: t0)
        XCTAssertEqual(phone.merge("a", server: server3), .upToDate, "the server's look stays; nothing is sent over it")
        XCTAssertEqual(phone.local["a"]?.review(1)?.verdict, .notClean)
        let conflict = try XCTUnwrap(phone.conflicts["a"]?.first)
        XCTAssertEqual(conflict, CoverageAuditSync.Conflict(slot: .init(pass: .first, index: 1), mine: nil))
        // A conflict over a first look carries that look: shown in the first pass and the resolution, never in the blind repeat.
        // Listed whatever is left to review (the interval may be off the queue: the other device's look is a finished one).
        XCTAssertEqual(phone.shownConflicts(.first), [P.OpenConflict(recordingId: "a", conflict: conflict)])
        XCTAssertEqual(phone.shownConflicts(.repeatLook), [])
        XCTAssertEqual(phone.shownConflicts(.resolution), [P.OpenConflict(recordingId: "a", conflict: conflict)])
        // While another reviewer's repeat stands on the other device's first look, this phone's withdrawal can't be put
        // back (a repeat with no first verdict): nothing changes and the conflict stays, with why.
        var blocked = phone
        blocked.local["a"] = CoverageAuditSync.setting(.init(pass: .repeatLook, index: 1), to: .repeatLook(A.RepeatReview(index: 1, verdict: .clean, reviewer: other,
                                                                                                                       reviewedAt: "2026-11-17T12:00:00Z", playedAllAtMaxRate: 2)),
                                                      in: try XCTUnwrap(blocked.local["a"]))
        let before = blocked
        XCTAssertThrowsError(try blocked.resolve(conflict, recordingId: "a", keep: true))
        XCTAssertEqual(blocked, before)
        // The reviewer chooses this phone's: it goes up as an explicit change on revision 3.
        try phone.resolve(conflict, recordingId: "a", keep: true)
        XCTAssertNil(phone.conflicts["a"])
        guard case .push(let mine, 3) = phone.merge("a", server: server3) else { return XCTFail("the chosen look is sent") }
        XCTAssertNil(mine.review(1))
    }

    func testLooksTakenFromTheServerStayAgreedWhenTheSendThatFollowsFails() throws {
        // The phone holds its own look on interval 1 (unsent); the server has the Mac's look X on interval 0.
        var p = try phone(), mac = try phone()
        try mac.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: me, tool: "RallyLab", now: t0)
        let x = try XCTUnwrap(mac.local["a"])
        try p.give(.clean, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000), reviewer: me, tool: "Labeler", now: t0)
        guard case .push(_, 1) = p.merge("a", server: row(x, revision: 1)) else { return XCTFail("merged and sent") }
        // The send fails: the Mac changed interval 0 to Y first (revision 2). The phone never touched interval 0.
        let y = CoverageAuditSync.setting(.init(pass: .first, index: 0), to: .first(A.Review(index: 0, startTick: 0, endTick: 600, verdict: .notClean, reviewer: me,
                                                                                           reviewedAt: "2026-11-17T11:00:00Z", playedAllAtMaxRate: 2,
                                                                                           findings: [.init(kind: .editedFootage, approxStartSec: 0.5)])), in: x)
        guard case .push(let again, 2) = p.merge("a", server: row(y, revision: 2)) else { return XCTFail("merged again on revision 2") }
        XCTAssertNil(p.conflicts["a"], "the Mac's change to a look the phone only took from the server is not a conflict")
        XCTAssertEqual(again.review(0)?.verdict, .notClean, "the Mac's newer look")
        XCTAssertEqual(again.review(1)?.verdict, .clean, "and the phone's own, still to go up")
    }

    func testARecordOfOtherFootageOrAnotherDrawIsNeverMerged() throws {
        var p = try phone()
        try p.give(.clean, pass: .first, recordingId: "a", index: 0, video: video(), withheld: false, played: played(0, 600), reviewer: me, tool: "t", now: t0)
        var foreign = try XCTUnwrap(p.local["a"])
        foreign.sourceFingerprint = "file:other"
        guard case .refused(let why) = p.merge("a", server: row(foreign, revision: 4)) else { return XCTFail("refused") }
        XCTAssertTrue(why.contains("footage"), why)
        foreign = try XCTUnwrap(p.local["a"]); foreign.drawSha256 = "beef"
        guard case .refused = p.merge("a", server: row(foreign, revision: 4)) else { return XCTFail("another draw's record is refused") }
        XCTAssertEqual(p.local["a"]?.sourceFingerprint, "file:a", "this phone's record is left as it was")
    }

    func testAMergeThatWouldBreakARuleIsRefused() throws {
        // The server has a resolution of a disagreement this phone has since withdrawn the repeat of — merged, the
        // record would hold a resolution with nothing to resolve: refused, not sent, not adopted.
        var p = try phone()
        try p.give(.clean, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000), reviewer: me, tool: "t", now: t0)
        // (A second look can only be in a record from before amendment 2; this phone's holds one.)
        let alone = try XCTUnwrap(p.local["a"])
        let base = CoverageAuditSync.setting(.init(pass: .repeatLook, index: 1), to: .repeatLook(A.RepeatReview(index: 1, verdict: .notClean, reviewer: other, reviewedAt: "2026-11-17T10:00:00Z",
                                                                                                                 playedAllAtMaxRate: 2, findings: [.init(kind: .missedServe, approxStartSec: 3)])), in: alone)
        p.local["a"] = base
        p.pushed(base, saved: row(base, revision: 1))
        var server = base
        server = CoverageAuditSync.setting(.init(pass: .resolution, index: 1), to: .resolution(A.Resolution(index: 1, verdict: .clean, reviewer: me, resolvedAt: "2026-11-17T12:00:00Z",
                                                                                                            playedAllAtMaxRate: 2)), in: server)
        p.local["a"] = alone
        guard case .refused(let why) = p.merge("a", server: row(server, revision: 2)) else { return XCTFail("refused") }
        XCTAssertTrue(why.contains("breaks a rule"), why)
    }

    func testTheServersRefusalsAreToldApart() {
        XCTAssertEqual(CoverageAuditSync.refusal(in: "conflict: the record changed on the server (revision 3, expected 2)"), .conflict(serverRevision: 3))
        XCTAssertEqual(CoverageAuditSync.refusal(in: "withheld: a is withheld"), .withheld)
        XCTAssertEqual(CoverageAuditSync.refusal(in: "identity: the record describes footage"), .identity)
        XCTAssertEqual(CoverageAuditSync.refusal(in: "reviewer: interval 0 (intervals) is x's look"), .reviewer)
        XCTAssertEqual(CoverageAuditSync.refusal(in: "interval: interval 2 of a is no longer unmarked as drawn"), .interval)
        XCTAssertEqual(CoverageAuditSync.refusal(in: "coverage audit: leads only in this release"), .notLead)
        XCTAssertNil(CoverageAuditSync.refusal(in: "The network connection was lost."))
    }

    // MARK: - Placing a finding by scrubbing

    func testWhatIsLeftOnAnIntervalFollowsItsLookAndWhatHasPlayed() throws {
        var p = try phone()
        let serve = A.Finding(kind: .missedRally, approxStartSec: 2.5, approxEndSec: 4)
        XCTAssertEqual(p.remaining(.first, recordingId: "a", index: 1, played: false), .verdict)
        XCTAssertEqual(p.remaining(.first, recordingId: "a", index: 1, played: true), .verdict, "played whole with no verdict: Clean or a finding is still owed")
        // A finding marked part-way through: the rest is watched, then saying so completes the look.
        try p.give(.finding(serve), pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 2000), reviewer: me, tool: "t", now: t0)
        XCTAssertEqual(p.remaining(.first, recordingId: "a", index: 1, played: false), .rest)
        XCTAssertEqual(p.remaining(.first, recordingId: "a", index: 1, played: true), .completion)
        XCTAssertTrue(p.queue(.first, reviewable: { _ in true }, reviewer: me, now: t0).contains(.init(pass: .first, recordingId: "a", index: 1)), "a partial look is still owed")
        try p.give(.playedWhole, pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000), reviewer: me, tool: "t", now: t0)
        XCTAssertEqual(p.remaining(.first, recordingId: "a", index: 1, played: true), .nothing)
        XCTAssertFalse(p.queue(.first, reviewable: { _ in true }, reviewer: me, now: t0).contains(.init(pass: .first, recordingId: "a", index: 1)))
        // A finding marked after the interval played whole is a whole look at once: nothing but the next interval.
        var q = try phone()
        try q.give(.finding(serve), pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: played(1200, 3000), reviewer: me, tool: "t", now: t0)
        XCTAssertEqual(q.remaining(.first, recordingId: "a", index: 1, played: true), .nothing)
        XCTAssertFalse(q.queue(.first, reviewable: { _ in true }, reviewer: me, now: t0).contains(.init(pass: .first, recordingId: "a", index: 1)))
    }

    private let scrubbed = A.Interval(index: 1, startTick: 1200, endTick: 3000)   // 2.0–5.0 s; shown 1.0–6.0

    func testAFindingIsPlacedWhereTheFootageStandsToATenthAndInsideWhatIsShown() throws {
        var m = P.Marking(kind: .missedRally, interval: scrubbed, shown: 1...6, playhead: 2.537)
        XCTAssertEqual(m.start, 2.5)
        XCTAssertNil(m.end, "a finding names only its start until an end is marked")
        XCTAssertEqual(m.resume, 2.537, "playback returns to where the reviewer was")
        m.setEnd(9)
        XCTAssertEqual(m.end, 6, "an end past what is shown is the last moment shown")
        m.setStart(0)
        XCTAssertEqual(m.start, 1)
        m.note = "  two touches  "
        m.edge = .end
        XCTAssertEqual(m.finding, A.Finding(kind: .missedRally, approxStartSec: 1, approxEndSec: 6, edge: .end, note: "two touches"))
        // The shared rules take it on the interval it was placed on.
        var p = try phone()
        try p.give(.finding(try XCTUnwrap(m.finding)), pass: .first, recordingId: "a", index: 1, video: video(), withheld: false, played: .init(), reviewer: me, tool: "t", now: t0)
        XCTAssertEqual(p.local["a"]?.review(1)?.findings, [try XCTUnwrap(m.finding)])
    }

    func testAnEndBeforeTheStartMovesTheStartAndAStartPastTheEndDropsTheEnd() {
        var m = P.Marking(kind: .missedServe, interval: scrubbed, shown: 1...6, playhead: 4)
        m.setEnd(3)
        XCTAssertEqual([m.start, m.end], [3, 3])
        m.setEnd(5)
        m.setStart(5.5)
        XCTAssertEqual(m.start, 5.5)
        XCTAssertNil(m.end)
        m.setEnd(5.8)
        m.clearEnd()
        XCTAssertNil(m.end)
        XCTAssertEqual(m.finding, A.Finding(kind: .missedServe, approxStartSec: 5.5, approxEndSec: nil, edge: nil, note: nil))
    }

    func testATrimKeepsTheIntervalsOwnEndAndIsRefusedInsideTheOneSecondTolerance() {
        var lead = P.Marking(kind: .boundaryError, trim: .leading, interval: scrubbed, shown: 1...6, playhead: 2.6)
        XCTAssertEqual([lead.start, lead.end], [2, 2.6])
        XCTAssertNotNil(lead.problem, "0.6 s is inside the tolerance")
        XCTAssertNil(lead.finding)
        lead.setStart(4)
        XCTAssertEqual(lead.start, 2, "a leading trim starts at the interval's start")
        lead.setEnd(5.9)
        XCTAssertEqual(lead.end, 5, "a trim stays inside the interval")
        lead.setEnd(3.25)
        XCTAssertEqual(lead.finding, A.Finding(kind: .boundaryError, approxStartSec: 2, approxEndSec: 3.3, edge: .leading, note: nil))

        var trail = P.Marking(kind: .boundaryError, trim: .trailing, interval: scrubbed, shown: 1...6, playhead: 0.2)
        XCTAssertEqual([trail.start, trail.end], [2, 5])
        trail.setEnd(3)
        trail.clearEnd()
        XCTAssertEqual(trail.end, 5, "a trailing trim ends at the interval's end")
        trail.setStart(4.4)
        XCTAssertNotNil(trail.problem)
        trail.setStart(3.9)
        XCTAssertEqual(trail.finding, A.Finding(kind: .boundaryError, approxStartSec: 3.9, approxEndSec: 5, edge: .trailing, note: nil))
    }

    func testAnUncertainFindingIsNotPlacedWithoutItsNote() {
        var m = P.Marking(kind: .uncertain, interval: scrubbed, shown: 1...6, playhead: 3)
        XCTAssertNil(m.finding)
        m.note = "ball out of frame"
        XCTAssertEqual(m.finding?.note, "ball out of frame")
    }
}
