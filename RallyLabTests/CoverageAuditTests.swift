//
//  CoverageAuditTests.swift
//  RallyLabTests
//
//  The negative-coverage audit's record (CoverageAudit.swift): the unmarked intervals of a
//  recording in the dataset's ticks, the draw file and the sidecar as read, what a record
//  says (an interval's standing, the recording's derived state, the clean intervals a
//  dataset may trust) and the played coverage a `clean` needs. No video, no project.
//

import XCTest
@testable import RallyLab

final class CoverageAuditTests: XCTestCase {
    private typealias A = CoverageAudit

    /// The unmarked intervals of a recording `ticks` long with these marks (start, end, kind) and cut ranges.
    private func unmarked(_ marks: [(Double, Double, RallyKind?)], cuts: [(Double, Double)] = [], ticks: Int) -> [A.Interval] {
        A.unmarkedIntervals(marks: marks.map { RallyMarkRecord(startTime: $0.0, endTime: $0.1, kind: $0.2, contacts: nil) },
                            cuts: cuts.map { CutRange(start: $0.0, end: $0.1) }, durationTicks: ticks)
    }

    private func bounds(_ intervals: [A.Interval]) -> [[Int]] { intervals.map { [$0.startTick, $0.endTick] } }

    // MARK: - Unmarked intervals

    func testNoMarkLeavesTheWholeRecording() {
        XCTAssertEqual(unmarked([], ticks: 6000), [A.Interval(index: 0, startTick: 0, endTick: 6000)])
        XCTAssertEqual(unmarked([], ticks: 0), [], "a recording with no length has no interval")
    }

    func testEveryKindOfMarkCoversAndTheEdgesAreIntervals() {
        // A rally, a legacy mark with no kind, a missed serve and a "not a rally" mark: all four cover.
        let got = unmarked([(1, 2, .rally), (3, 4, nil), (5, 6, .missedServe), (7, 8, .other)], ticks: 6000)
        XCTAssertEqual(bounds(got), [[0, 600], [1200, 1800], [2400, 3000], [3600, 4200], [4800, 6000]])
        XCTAssertEqual(got.map(\.index), [0, 1, 2, 3, 4], "numbered from 0 in time order")
    }

    func testOverlappingAndTouchingMarksMergeAndUnsortedMarksAreOrdered() {
        XCTAssertEqual(bounds(unmarked([(6, 8, .rally), (1, 3, .rally), (2, 4, .missedServe), (4, 5, .rally)], ticks: 6000)), [[0, 600], [3000, 3600], [4800, 6000]],
                       "1–3 and 2–4 overlap, 4–5 touches: one covered stretch 1–5")
    }

    func testMarksAtTheEdgesLeaveNoEdgeIntervalAndAreClampedToTheRecording() {
        XCTAssertEqual(bounds(unmarked([(0, 2, .rally), (8, 12, .rally)], ticks: 6000)), [[1200, 4800]], "nothing before a mark at 0, nothing after one that runs past the end")
        XCTAssertEqual(unmarked([(0, 10, .rally)], ticks: 6000), [], "a recording marked whole has no interval")
    }

    func testCutRangesCoverLikeMarks() {
        // The clip starts mid-rally (cut 0–1.5) and an instant replay sits at 5–6.
        XCTAssertEqual(bounds(unmarked([(2, 3, .rally)], cuts: [(0, 1.5), (5, 6)], ticks: 6000)), [[900, 1200], [1800, 3000], [3600, 6000]])
        // A mark is read outside the cuts, as RallyTruth keeps it: the cut covers what it takes from the mark.
        XCTAssertEqual(bounds(unmarked([(2, 6, .other)], cuts: [(4, 7)], ticks: 6000)), [[0, 1200], [4200, 6000]])
    }

    func testSubSecondIntervalsAreKept() {
        // 50 ms between two rallies is an interval (30 ticks); one tick is one too.
        let got = unmarked([(1, 2, .rally), (2.05, 3, .rally), (3, 9.0 - 1.0 / 600, .rally)], ticks: 5400)
        XCTAssertEqual(bounds(got), [[0, 600], [1200, 1230], [5399, 5400]])
        XCTAssertEqual(got[1].span.ticks, 30)
    }

    func testBoundsAreTheExportersTicks() {
        // The marks of a real sidecar: the interval's bounds are the exporter's ticks of the marks' ends and starts.
        let a = (0.3333666666666667, 3.5371666666666703), b = (6.6665222222222225, 11.624605308)
        let got = unmarked([(a.0, a.1, .rally), (b.0, b.1, .rally)], ticks: RallyClassifierExporter.tick(20))
        XCTAssertEqual(bounds(got), [[0, RallyClassifierExporter.tick(a.0)], [RallyClassifierExporter.tick(a.1), RallyClassifierExporter.tick(b.0)],
                                     [RallyClassifierExporter.tick(b.1), 12000]])
        XCTAssertEqual(got[1].startTick, 2122)
        XCTAssertEqual(A.timescale, 600)
    }

    func testASliverOfAMarkBesideACutIsUnmarked() {
        // RallyTruth drops what a cut leaves of a mark under 0.1 s: that sliver is unmarked time, as the exporter labels it.
        XCTAssertEqual(bounds(unmarked([(10, 20, .missedServe)], cuts: [(10.05, 25)], ticks: 18000)), [[0, 6030], [15000, 18000]])
    }

    func testARallyCoversFromWhereTheDatasetStartsIt() {
        // A serve contact marked after the mark's start: the dataset's rally starts at the contact, so the time
        // before it is unmarked (the exporter labels it not-rally) and the audit reviews it.
        func intervals(_ contacts: [RallyContact]?, kind: RallyKind? = .rally) -> [[Int]] {
            bounds(A.unmarkedIntervals(marks: [RallyMarkRecord(startTime: 2, endTime: 4, kind: kind, contacts: contacts)], cuts: [], durationTicks: 6000))
        }
        XCTAssertEqual(intervals([RallyContact(time: 2.5, kind: .serve), RallyContact(time: 3, kind: .pass)]), [[0, 1500], [2400, 6000]])
        XCTAssertEqual(intervals([RallyContact(time: 2, kind: .serve)]), [[0, 1200], [2400, 6000]], "a contact at the start is the start")
        XCTAssertEqual(intervals(nil), [[0, 1200], [2400, 6000]])
        XCTAssertEqual(intervals([RallyContact(time: 2.5, kind: .pass)]), [[0, 1200], [2400, 6000]], "only a serve starts a rally")
        XCTAssertEqual(intervals([RallyContact(time: 4.5, kind: .serve)]), [[0, 1200], [2400, 6000]], "a contact outside the mark is not its start")
        XCTAssertEqual(intervals([RallyContact(time: 2.5, kind: .serve)], kind: .missedServe), [[0, 1200], [2400, 6000]], "an excluded span covers from its start")
        // The same ticks the exporter gives the rally.
        let record = RallyMarkRecord(startTime: 2, endTime: 4, kind: .rally, contacts: [RallyContact(time: 2.5, kind: .serve)])
        XCTAssertEqual(RallyClassifierExporter.tick(RallyClassifierExporter.rallyStart(RallyTruth.Mark(record), in: [record])), 1500)
    }

    // MARK: - The draw file

    /// A draw as scripts/rally_classifier/coverage_audit_draw.py writes it, cut down to one recording.
    private func drawJSON(version: String = "coverage_audit_draw_v2", intervals: String = #"[{"index":0,"startTick":0,"endTick":600},{"index":1,"startTick":1200,"endTick":6000}]"#,
                          repeatSet: String = "[1]", extra: String = "") -> String {
        """
        {"schemaVersion":"\(version)","procedure":"coverage_draw_v2","stage":"pilot","drawId":"20261114-120000","createdAt":"2026-11-14T12:00:00Z","seed":20261114,
         "dataset":{"name":"rc-v1-20261112","manifestSha256":"aa","timescale":600,"surfaces":["beach"]},"notDrawn":[{"recordingId":"x"}],\(extra)
         "recordings":[{"recordingId":"rec_a","groupId":"g1","surface":"beach","split":"train","fold":2,"camera":"End line",
           "fingerprint":"youtube:abc","sourceId":"youtube:abc","contentFingerprint":"file:11","marksSha256":"m1","durationTicks":6000,
           "marksChangedSinceExport":false,"rallyMarks":2,"intervals":\(intervals),"repeatIndices":\(repeatSet)}]}
        """
    }

    private func writeTemp(_ text: String, name: String = "20261114-120000-draw.json") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cov-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testDrawDecodesWhatTheReviewNeedsAndIgnoresTheRest() throws {
        let loaded = try A.loadDraw(writeTemp(drawJSON()))
        XCTAssertEqual(loaded.draw.drawId, "20261114-120000")
        XCTAssertEqual(loaded.draw.datasetName, "rc-v1-20261112")
        let r = try XCTUnwrap(loaded.draw.recording("rec_a"))
        XCTAssertEqual(r.groupId, "g1"); XCTAssertEqual(r.fingerprint, "youtube:abc"); XCTAssertEqual(r.contentFingerprint, "file:11")
        XCTAssertEqual(r.marksSha256, "m1"); XCTAssertEqual(r.durationTicks, 6000)
        XCTAssertEqual(r.intervals, [A.Interval(index: 0, startTick: 0, endTick: 600), A.Interval(index: 1, startTick: 1200, endTick: 6000)])
        XCTAssertEqual(r.repeatIndices, [1])
        XCTAssertEqual(loaded.sha256.count, 64, "the SHA-256 of the file's bytes, what a record is bound to")
        XCTAssertNil(loaded.draw.recording("rec_b"))
    }

    func testDrawIsRefusedWhenItIsNotAFrozenV2Draw() throws {
        func refused(_ json: String, _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertThrowsError(try A.loadDraw(writeTemp(json)), what, file: file, line: line) { error in
                guard case A.Failure.drawUnreadable = error else { return XCTFail("\(error)", file: file, line: line) }
            }
        }
        try refused(drawJSON(version: "coverage_audit_draw_v1"), "another version")
        try refused("[]", "not an object")
        try refused(drawJSON(intervals: #"[{"index":0,"startTick":0,"endTick":600},{"index":1,"startTick":500,"endTick":6000}]"#), "overlapping intervals")
        try refused(drawJSON(intervals: #"[{"index":1,"startTick":0,"endTick":600}]"#, repeatSet: "[]"), "not numbered from 0")
        try refused(drawJSON(intervals: #"[{"index":0,"startTick":0,"endTick":6001}]"#, repeatSet: "[]"), "past the recording's end")
        try refused(drawJSON(repeatSet: "[2]"), "a repeat index that is no interval")
        try refused(drawJSON().replacingOccurrences(of: #""durationTicks":6000,"#, with: ""), "no durationTicks")
        try refused(drawJSON().replacingOccurrences(of: #""contentFingerprint":"file:11","#, with: ""), "no content fingerprint")
        try refused(drawJSON().replacingOccurrences(of: #""timescale":600"#, with: #""timescale":1000"#), "another timescale")
        try refused(drawJSON().replacingOccurrences(of: #""repeatIndices":[1]"#, with: #""repeat":[1]"#), "no repeat set")
        XCTAssertThrowsError(try A.loadDraw(URL(fileURLWithPath: "/nonexistent/draw.json")))
    }

    // MARK: - The sidecar

    private let at = "2026-11-14T18:00:00Z"

    private func file(_ reviews: [A.Review] = []) -> A.File {
        var f = A.File(recordingId: "rec_a", sourceFingerprint: "file:11", drawId: "20261114-120000", drawSha256: "d1", datasetName: "rc-v1-20261112",
                       marksSha256: "m1", tool: "RallyLab test")
        f.intervals = reviews
        return f
    }

    private func clean(_ index: Int, _ start: Int, _ end: Int, by reviewer: String = "bw", at stamp: String? = nil) -> A.Review {
        A.Review(index: index, startTick: start, endTick: end, verdict: .clean, reviewer: reviewer, reviewedAt: stamp ?? at, playedAllAtMaxRate: 2.0)
    }

    private func found(_ index: Int, _ start: Int, _ end: Int, _ kinds: [A.FindingKind], played: Double? = 2.0, by reviewer: String = "bw") -> A.Review {
        A.Review(index: index, startTick: start, endTick: end, verdict: .notClean, reviewer: reviewer, reviewedAt: at, playedAllAtMaxRate: played,
                 findings: kinds.map { A.Finding(kind: $0, note: $0 == .uncertain ? "net post hides the ball" : nil) })
    }

    func testTheSpecsRecordDecodes() throws {
        let url = try writeTemp("""
        {"annotationVersion": "coverage_audit_v2", "recordingId": "rec_a", "sourceFingerprint": "file:11",
         "drawId": "20261114-120000", "drawSha256": "d1", "datasetName": "rc-v1-20261112", "marksSha256": "m1",
         "timescale": 600, "blindToPipeline": true, "tool": "RallyLab 1.0",
         "intervals": [{"index": 0, "startTick": 0, "endTick": 3120, "verdict": "clean",
                        "reviewer": "bw", "reviewedAt": "2026-11-14T18:00:00Z", "playedAllAtMaxRate": 2.0},
                       {"index": 3, "startTick": 40000, "endTick": 41000, "verdict": "clean",
                        "reviewer": "bw", "reviewedAt": "2026-11-14T18:00:00Z", "playedAllAtMaxRate": 1.0},
                       {"index": 7, "startTick": 71040, "endTick": 78600, "verdict": "not_clean", "reviewer": "bw", "reviewedAt": "2026-11-14T18:05:00Z",
                        "findings": [{"kind": "missed_rally", "approxStartSec": 121.0, "approxEndSec": 127.5}]}],
         "repeat": {"method": "second_reviewer",
                    "intervals": [{"index": 3, "verdict": "not_clean", "reviewer": "jr", "reviewedAt": "2026-11-14T19:00:00Z",
                                   "findings": [{"kind": "non_rally_activity"}]}]},
         "resolutions": [{"index": 3, "verdict": "clean", "findings": [], "reviewer": "bw", "resolvedAt": "2026-11-15T19:00:00Z",
                          "playedAllAtMaxRate": 1.0, "note": "a ball rolled back, off court"}]}
        """, name: "rec_a.coverageaudit.json")
        let f = try A.read(url)
        XCTAssertEqual(f.intervals.count, 3)
        XCTAssertEqual(f.review(7)?.findings, [A.Finding(kind: .missedRally, approxStartSec: 121.0, approxEndSec: 127.5)])
        XCTAssertNil(f.review(7)?.playedAllAtMaxRate)
        XCTAssertEqual(f.review(0)?.findings, [], "a review written without findings has none")
        XCTAssertEqual(f.repeatPass?.method, "second_reviewer")
        XCTAssertEqual(f.resolution(3)?.note, "a ball rolled back, off court")
        XCTAssertEqual(A.cleanIntervals(f), [A.Span(startTick: 0, endTick: 3120), A.Span(startTick: 40000, endTick: 41000)],
                       "interval 3 is clean by its resolution; interval 7 is not")
    }

    func testRecordRoundTripsAndReadsWithoutItsOptionalFields() throws {
        let url = try writeTemp("""
        {"annotationVersion":"coverage_audit_v2","recordingId":"rec_a","sourceFingerprint":"file:11","drawId":"d","drawSha256":"s",
         "datasetName":"rc","marksSha256":"m","timescale":600,"blindToPipeline":true,"tool":"t"}
        """, name: "bare.coverageaudit.json")
        let bare = try A.read(url)
        XCTAssertEqual(bare.intervals, []); XCTAssertNil(bare.repeatPass); XCTAssertEqual(bare.resolutions, [])

        var f = file([clean(0, 0, 600), found(1, 1200, 6000, [.missedServe, .uncertain])])
        f.intervals[1].findings[0].approxStartSec = 3.5
        try A.write(f, to: url)
        XCTAssertEqual(try A.read(url), f)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"annotationVersion\" : \"coverage_audit_v2\""))
        XCTAssertTrue(text.contains("\"verdict\" : \"not_clean\""))
        XCTAssertFalse(text.contains("\"repeat\""), "no repeat pass is written before there is one")
        XCTAssertEqual(A.url(forVideo: URL(fileURLWithPath: "/footage/rec_a.mp4")).lastPathComponent, "rec_a.coverageaudit.json")
        XCTAssertEqual(A.url(forVideo: URL(fileURLWithPath: "/footage/rec_a.mp4")).deletingLastPathComponent(),
                       RallyMarkModel.labelsURL(for: URL(fileURLWithPath: "/footage/rec_a.mp4")).deletingLastPathComponent(), "beside the marks sidecar")
    }

    func testAnotherVersionIsRefusedWholeAndAnInvalidRecordNeverReachesTheDisk() throws {
        let url = try writeTemp("{\"annotationVersion\":\"coverage_audit_v1\"}", name: "old.coverageaudit.json")
        XCTAssertThrowsError(try A.read(url)) { XCTAssertEqual($0 as? A.Failure, .unsupportedVersion("coverage_audit_v1")) }
        try "{}".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try A.read(url)) { XCTAssertEqual($0 as? A.Failure, .unsupportedVersion("(none)")) }
        var bad = file([clean(0, 0, 600)])
        bad.intervals[0].playedAllAtMaxRate = nil
        XCTAssertThrowsError(try A.write(bad, to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{}", "the previous file is untouched by a refused write")
    }

    func testCleanExistsOnlyAsAPlayedVerdict() {
        func invalid(_ f: A.File, _ what: String, line: UInt = #line) {
            XCTAssertThrowsError(try A.validate(f), what, line: line) { error in
                guard case A.Failure.invalid = error else { return XCTFail("\(error)", line: line) }
            }
        }
        XCTAssertNoThrow(try A.validate(file([clean(0, 0, 600), found(1, 1200, 6000, [.nonRallyActivity], played: nil)])))
        var f = file([clean(0, 0, 600)])
        f.intervals[0].playedAllAtMaxRate = nil
        invalid(f, "clean, never played whole")
        f.intervals[0].playedAllAtMaxRate = 4.0
        invalid(f, "clean, played at 4×")
        f.intervals[0].playedAllAtMaxRate = 2.0
        f.intervals[0].findings = [A.Finding(kind: .nonRallyActivity)]
        invalid(f, "clean with a finding")
        invalid(file([A.Review(index: 0, startTick: 0, endTick: 600, verdict: .notClean, reviewer: "bw", reviewedAt: at, playedAllAtMaxRate: nil)]), "not_clean with no finding")
        invalid(file([A.Review(index: 0, startTick: 0, endTick: 600, verdict: .notClean, reviewer: "bw", reviewedAt: at, playedAllAtMaxRate: nil,
                               findings: [A.Finding(kind: .uncertain, note: "  ")])]), "uncertain without a note")
        invalid(file([A.Review(index: 0, startTick: 0, endTick: 600, verdict: .notClean, reviewer: "bw", reviewedAt: at, playedAllAtMaxRate: nil,
                               findings: [A.Finding(kind: .missedServe, edge: .leading)])]), "an edge the kind cannot carry")
        invalid(file([A.Review(index: 0, startTick: 0, endTick: 600, verdict: .notClean, reviewer: "bw", reviewedAt: at, playedAllAtMaxRate: nil,
                               findings: [A.Finding(kind: .missedRally, approxStartSec: 9, approxEndSec: 4)])]), "a finding that ends before it starts")
        invalid(file([clean(0, 0, 600), clean(0, 0, 600)]), "one interval reviewed twice")
        var blind = file([clean(0, 0, 600)])
        blind.blindToPipeline = false
        invalid(blind, "a review with predictions in view")
        var noReviewer = file([clean(0, 0, 600)])
        noReviewer.intervals[0].reviewer = ""
        invalid(noReviewer, "no reviewer")
    }

    func testRepeatAndResolutionRules() {
        func invalid(_ f: A.File, _ what: String, line: UInt = #line) {
            XCTAssertThrowsError(try A.validate(f), what, line: line) { error in
                guard case A.Failure.invalid = error else { return XCTFail("\(error)", line: line) }
            }
        }
        var f = file([clean(0, 0, 600), clean(1, 1200, 6000)])
        // A second reviewer may repeat at once; the first reviewer only a day later.
        f.repeatPass = A.Repeat(method: A.Repeat.secondReviewer, intervals: [A.RepeatReview(index: 1, verdict: .clean, reviewer: "jr", reviewedAt: "2026-11-14T18:30:00Z", playedAllAtMaxRate: 2)])
        XCTAssertNoThrow(try A.validate(f))
        f.repeatPass = A.Repeat(method: A.Repeat.sameReviewer, intervals: [A.RepeatReview(index: 1, verdict: .clean, reviewer: "bw", reviewedAt: "2026-11-15T17:59:59Z", playedAllAtMaxRate: 2)])
        invalid(f, "the first reviewer, one second short of 24 h")
        f.repeatPass?.intervals[0].reviewedAt = "2026-11-15T18:00:00Z"
        XCTAssertNoThrow(try A.validate(f))
        f.repeatPass?.method = A.Repeat.secondReviewer
        invalid(f, "a same-reviewer repeat recorded as a second reviewer's")
        f.repeatPass = A.Repeat(method: A.Repeat.secondReviewer, intervals: [A.RepeatReview(index: 5, verdict: .clean, reviewer: "jr", reviewedAt: at, playedAllAtMaxRate: 2)])
        invalid(f, "a repeat of an interval with no first verdict")
        // A resolution needs a disagreement.
        f.repeatPass = A.Repeat(method: A.Repeat.secondReviewer, intervals: [A.RepeatReview(index: 1, verdict: .clean, reviewer: "jr", reviewedAt: at, playedAllAtMaxRate: 2)])
        f.resolutions = [A.Resolution(index: 1, verdict: .clean, reviewer: "bw", resolvedAt: at, playedAllAtMaxRate: 2)]
        invalid(f, "a resolution where the verdicts agree")
        f.repeatPass?.intervals[0] = A.RepeatReview(index: 1, verdict: .notClean, reviewer: "jr", reviewedAt: at, playedAllAtMaxRate: 2, findings: [A.Finding(kind: .missedServe)])
        XCTAssertNoThrow(try A.validate(f))
        f.resolutions[0].playedAllAtMaxRate = nil
        invalid(f, "a clean resolution that was not played whole")
    }

    // MARK: - Standing, state, clean intervals

    private let drawn = [A.Interval(index: 0, startTick: 0, endTick: 600), A.Interval(index: 1, startTick: 1200, endTick: 6000), A.Interval(index: 2, startTick: 7000, endTick: 9000)]

    func testStateIsPartialUntilEveryIntervalIsReviewed() {
        XCTAssertEqual(A.state(of: nil, intervals: drawn).name, "partial", "no record: nothing is reviewed")
        XCTAssertEqual(A.state(of: file([clean(0, 0, 600), clean(1, 1200, 6000)]), intervals: drawn).name, "partial")
        let all = file([clean(0, 0, 600), clean(1, 1200, 6000), clean(2, 7000, 9000)])
        XCTAssertEqual(A.state(of: all, intervals: drawn), A.RecordingState(contaminated: false, partial: false))
        XCTAssertEqual(A.state(of: all, intervals: drawn).name, "audited_clean")
        // A review of other bounds than the draw's interval is not a review of it.
        XCTAssertEqual(A.state(of: file([clean(0, 0, 600), clean(1, 1200, 5000), clean(2, 7000, 9000)]), intervals: drawn).name, "partial")
        XCTAssertEqual(A.state(of: file(), intervals: []).name, "audited_clean", "a recording with no unmarked interval has nothing left to review")
    }

    func testStateByFindingKind() {
        func state(_ kinds: [A.FindingKind], played: Double? = 2.0) -> A.RecordingState {
            A.state(of: file([clean(0, 0, 600), found(1, 1200, 6000, kinds, played: played), clean(2, 7000, 9000)]), intervals: drawn)
        }
        XCTAssertEqual(state([.nonRallyActivity]).name, "audited_clean", "non-rally activity alone neither contaminates nor leaves it partial")
        XCTAssertEqual(state([.editedFootage]).name, "audited_clean")
        XCTAssertEqual(state([.uncertain]).name, "partial")
        XCTAssertEqual(state([.boundaryError]).name, "partial")
        XCTAssertEqual(state([.missedRally]), A.RecordingState(contaminated: true, partial: false))
        XCTAssertEqual(state([.missedServe]).name, "contaminated")
        let both = state([.missedRally, .uncertain])
        XCTAssertEqual(both, A.RecordingState(contaminated: true, partial: true))
        XCTAssertEqual(both.name, "contaminated", "contaminated outranks partial")
        XCTAssertEqual(both.text, "contaminated (and partial)", "and both are told")
        XCTAssertEqual(state([.nonRallyActivity], played: nil).name, "partial", "findings from a look that did not cover the interval leave it unreviewed")
        XCTAssertEqual(state([.missedRally], played: nil), A.RecordingState(contaminated: true, partial: true))
    }

    func testADisagreementCountsForNothingUntilItIsResolved() {
        var f = file([clean(0, 0, 600), clean(1, 1200, 6000), clean(2, 7000, 9000)])
        f.repeatPass = A.Repeat(method: A.Repeat.secondReviewer, intervals: [
            A.RepeatReview(index: 0, verdict: .clean, reviewer: "jr", reviewedAt: at, playedAllAtMaxRate: 2),
            A.RepeatReview(index: 1, verdict: .notClean, reviewer: "jr", reviewedAt: at, playedAllAtMaxRate: 2, findings: [A.Finding(kind: .missedRally)]),
        ])
        XCTAssertEqual(A.standing(of: 0, in: f), .settled(verdict: .clean, findings: [], playedWhole: true), "an agreeing repeat changes nothing")
        XCTAssertEqual(A.standing(of: 1, in: f), .disputed)
        XCTAssertEqual(A.standing(of: 5, in: f), .unreviewed)
        XCTAssertEqual(A.disagreements(in: f), [1])
        XCTAssertEqual(A.state(of: f, intervals: drawn).name, "partial")
        XCTAssertEqual(A.cleanIntervals(f), [A.Span(startTick: 0, endTick: 600), A.Span(startTick: 7000, endTick: 9000)], "a disputed interval is not clean")
        // Resolved against the first verdict: the resolution is what counts.
        f.resolutions = [A.Resolution(index: 1, verdict: .notClean, findings: [A.Finding(kind: .missedRally, approxStartSec: 4)], reviewer: "bw", resolvedAt: at, playedAllAtMaxRate: 1)]
        XCTAssertNoThrow(try A.validate(f))
        XCTAssertEqual(A.state(of: f, intervals: drawn), A.RecordingState(contaminated: true, partial: false))
        XCTAssertEqual(A.cleanIntervals(f).count, 2)
        // Resolved for it.
        f.resolutions = [A.Resolution(index: 1, verdict: .clean, reviewer: "bw", resolvedAt: at, playedAllAtMaxRate: 1)]
        XCTAssertEqual(A.state(of: f, intervals: drawn).name, "audited_clean")
        XCTAssertEqual(A.cleanIntervals(f), [A.Span(startTick: 0, endTick: 600), A.Span(startTick: 1200, endTick: 6000), A.Span(startTick: 7000, endTick: 9000)])
        XCTAssertEqual(A.disagreements(in: f), [1], "a resolved disagreement is still one")
    }

    func testVerdictsAgreeByVerdictAndKindsFound() {
        let rally = A.Finding(kind: .missedRally, approxStartSec: 3), other = A.Finding(kind: .missedRally, approxStartSec: 9, note: "elsewhere")
        XCTAssertTrue(A.agree((.notClean, [rally]), (.notClean, [other])), "the same kind found, whatever the approximate time")
        XCTAssertFalse(A.agree((.notClean, [rally]), (.notClean, [rally, other])), "one missed rally is not two")
        XCTAssertFalse(A.agree((.notClean, [rally]), (.notClean, [A.Finding(kind: .missedServe)])))
        XCTAssertFalse(A.agree((.clean, []), (.notClean, [rally])))
    }

    func testCleanIntervalsAreOnlyExplicitCleanVerdictsInTimeOrder() {
        let f = file([found(2, 7000, 9000, [.nonRallyActivity]), clean(1, 1200, 6000), found(0, 0, 600, [.uncertain])])
        XCTAssertEqual(A.cleanIntervals(f), [A.Span(startTick: 1200, endTick: 6000)], "non-rally activity is not clean; neither is uncertain")
        XCTAssertEqual(A.cleanIntervals(file()), [])
    }

    func testTheRepeatSetIsTheDrawsPlusEveryUncertainInterval() throws {
        let recording = try XCTUnwrap(A.loadDraw(writeTemp(drawJSON(
            intervals: #"[{"index":0,"startTick":0,"endTick":600},{"index":1,"startTick":1200,"endTick":3000},{"index":2,"startTick":4000,"endTick":6000}]"#, repeatSet: "[2]"))).draw.recording("rec_a"))
        XCTAssertEqual(A.repeatSet(recording, file: nil), [2])
        XCTAssertEqual(A.repeatSet(recording, file: file([found(0, 0, 600, [.uncertain]), clean(1, 1200, 3000)])), [0, 2])
    }

    // MARK: - Played coverage

    func testCoverageIsWhatWasPlayedAtTwoTimesOrSlower() {
        var played = A.PlayedCoverage()
        let interval = A.Span(startTick: 600, endTick: 1800)
        XCTAssertFalse(played.covers(interval))
        played.credit(fromTick: 0, toTick: 900, rate: 2)
        played.credit(fromTick: 1200, toTick: 2400, rate: 1)
        XCTAssertEqual(played.playedTicks(in: interval), 900)
        XCTAssertFalse(played.covers(interval), "300 ticks in the middle were never played")
        played.credit(fromTick: 900, toTick: 1200, rate: 4)
        XCTAssertFalse(played.covers(interval), "played at 4×: no credit")
        played.credit(fromTick: 1200, toTick: 900, rate: 1)
        XCTAssertFalse(played.covers(interval), "backwards is not playing")
        played.credit(fromTick: 880, toTick: 1210, rate: 0.5)
        XCTAssertTrue(played.covers(interval))
        XCTAssertEqual(played.spans, [A.Span(startTick: 0, endTick: 2400)], "touching and overlapping stretches are one")
        XCTAssertEqual(played.maxRate, 2)
    }

    func testSeekingEarnsNothing() {
        var tracker = A.PlayTracker()
        tracker.began(at: 1.0)
        tracker.observed(1.05, rate: 2)
        tracker.observed(1.10, rate: 2)
        // A seek to 5 s: the clock jumps, and nothing between is credited — with or without the jump being announced.
        tracker.jumped()
        tracker.observed(5.0, rate: 2)
        tracker.observed(5.05, rate: 2)
        XCTAssertEqual(tracker.played.spans, [A.Span(startTick: 600, endTick: 660), A.Span(startTick: 3000, endTick: 3030)])
        tracker.observed(9.0, rate: 2)
        XCTAssertEqual(tracker.played.spans.count, 2, "a step too long to have been played is a jump")
        tracker.observed(8.0, rate: 2)
        tracker.observed(8.05, rate: 2)
        XCTAssertFalse(tracker.played.covers(A.Span(startTick: 3030, endTick: 4800)))
        // Paused: what played up to the pause counts, nothing while paused.
        tracker.stopped(at: 8.1, rate: 2)
        tracker.observed(8.5, rate: 2)
        XCTAssertEqual(tracker.played.playedTicks(in: A.Span(startTick: 4800, endTick: 6000)), 60)
        // Faster than 2×: the clock is followed, nothing is credited.
        tracker.began(at: 10)
        tracker.observed(10.5, rate: 3)
        XCTAssertEqual(tracker.played.playedTicks(in: A.Span(startTick: 6000, endTick: 6300)), 0)
    }

    func testPlayingToTheEndOfTheFileCoversItsLastTicks() {
        var tracker = A.PlayTracker()
        tracker.began(at: 0)
        var t = 0.0
        while t < 9.9 { t += 0.05; tracker.observed(t, rate: 2) }
        XCTAssertFalse(tracker.played.covers(A.Span(startTick: 0, endTick: 6000)), "the last observation falls short of the end")
        tracker.reachedEnd(durationTicks: 6000, rate: 2)
        XCTAssertTrue(tracker.played.covers(A.Span(startTick: 0, endTick: 6000)), "played from the first tick to the end of the file")
        var far = A.PlayTracker()
        far.began(at: 2)
        far.reachedEnd(durationTicks: 6000, rate: 2)
        XCTAssertEqual(far.played.spans, [], "an end reached from far away was not played")
    }
}
