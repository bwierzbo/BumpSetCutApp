//
//  RallyTruthTests.swift
//  RallyLabTests
//
//  The one reading of a recording's marks and cut ranges (RallyTruth; the
//  D-028 amendment of 2026-11-04): a rally by its kind or by having none,
//  a missed serve or a "not a rally" an excluded span, a cut excluded and
//  not footage, the unmarked time not-rally only once the pass is
//  complete — and what closing a mark does to the pre-tracked rallies
//  under it, on the Mac's store against a real project session.
//

import XCTest
@testable import RallyLab

@MainActor
final class RallyTruthTests: XCTestCase {
    private func mark(_ s: Double, _ e: Double, _ k: RallyKind? = .rally) -> RallyTruth.Mark { RallyTruth.Mark(start: s, end: e, kind: k) }
    private func span(_ s: Double, _ e: Double) -> RallyTruth.Span { RallyTruth.Span(start: s, end: e) }

    func testARallyIsAMarkOfKindRallyOrOfNoKind() {
        XCTAssertTrue(RallyTruth.isRally(.rally))
        XCTAssertTrue(RallyTruth.isRally(nil), "a mark from before live tagging is a rally (D-028 §3)")
        XCTAssertFalse(RallyTruth.isRally(.missedServe))
        XCTAssertFalse(RallyTruth.isRally(.other))
    }

    func testMissedServesAndOtherMarksAreExcludedSpansNeverRallies() {
        let t = RallyTruth(marks: [mark(10, 20), mark(30, 32, .missedServe), mark(40, 44, .other), mark(50, 60, nil)], cuts: [], complete: true)
        XCTAssertEqual(t.positives, [span(10, 20), span(50, 60)])
        XCTAssertEqual(t.excluded, [span(30, 32), span(40, 44)])
        XCTAssertEqual(t.mask, [CutRange(start: 30, end: 32), CutRange(start: 40, end: 44)])
        XCTAssertEqual(t.unmarked(within: 70), [span(0, 10), span(20, 30), span(32, 40), span(44, 50), span(60, 70)],
                       "not-rally time: outside the rallies, the excluded spans and the cuts")
    }

    func testCutsTakeTheirPiecesOutOfEveryMarkAndAreExcludedNotNegative() {
        // A cut 15–35 takes the end of the first rally, the whole missed serve, and the start of the second rally.
        let t = RallyTruth(marks: [mark(10, 20), mark(22, 24, .missedServe), mark(30, 40), mark(45, 45.05)], cuts: [CutRange(start: 15, end: 35)], complete: true)
        XCTAssertEqual(t.positives, [span(10, 15), span(35, 40)], "the 45–45.05 sliver is dropped")
        XCTAssertEqual(t.excluded, [])
        XCTAssertEqual(t.cuts, [CutRange(start: 15, end: 35)])
        XCTAssertEqual(t.mask, [CutRange(start: 15, end: 35)])
        XCTAssertEqual(t.unmarked(within: 50), [span(0, 10), span(40, 50)], "the cut is not not-rally time")
    }

    func testUnmarkedTimeIsNotRallyOnlyForACompletePass() {
        let open = RallyTruth(marks: [mark(10, 20)], cuts: [], complete: false)
        XCTAssertEqual(open.unmarked(within: 60), [], "an unfinished pass: the rest is unknown, not dead")
        XCTAssertEqual(open.positives, [span(10, 20)], "the rallies marked so far still are")
        XCTAssertEqual(RallyTruth(marks: [mark(10, 20)], cuts: [], complete: true).unmarked(within: 60), [span(0, 10), span(20, 60)])
        XCTAssertEqual(RallyTruth(marks: [], cuts: [], complete: true).unmarked(within: 60), [span(0, 60)], "a complete pass with no rally: all not-rally")
    }

    func testCoverageIsByTheRalliesOnly() {
        let t = RallyTruth(marks: [mark(10, 20), mark(30, 33, .missedServe)], cuts: [], complete: true)
        XCTAssertTrue(t.coveredByRally(11, 19))
        XCTAssertTrue(t.coveredByRally(8, 18), "more than half inside")
        XCTAssertFalse(t.coveredByRally(5, 14), "less than half inside")
        XCTAssertFalse(t.coveredByRally(30, 33), "a missed serve covers nothing")
        XCTAssertEqual(t.rallySeconds(within: 18, 25), 2, accuracy: 1e-9)
        XCTAssertEqual(t.rallySeconds(within: 30, 33), 0)
        // Overlapping rally marks: the most inside one rally (7 s of 15–25 lie in 18–28), not their sum.
        let two = RallyTruth(marks: [mark(10, 20), mark(18, 28)], cuts: [], complete: true)
        XCTAssertEqual(two.rallySeconds(within: 15, 25), 7, accuracy: 1e-9)
    }

    // MARK: - Pre-tracked rallies under a mark

    private func point(_ t: Double) -> TrackPoint {
        TrackPoint(time: t, state: .visible, origin: .auto, box: TrackCandidate(rect: CGRect(x: 0.5, y: 0.5, width: 0.02, height: 0.03), confidence: 0.9), reviewed: false)
    }
    private func track(_ id: UUID = UUID(), from: Double, to: Double, machine: Bool? = true, isRally: Bool? = nil) -> TrackedRally {
        let points = stride(from: from, through: to, by: 0.5).map(point)
        var r = TrackedRally(id: id, start: from, end: to, points: points, candidates: [], done: false)
        r.machine = machine; r.isRally = isRally
        return r
    }

    func testARallyConfirmsAndTrimsThePretrackedRalliesUnderItAMissedServeTurnsThemDownAsTheyAre() {
        let under = track(from: 10, to: 20), half = track(from: 5, to: 14), elsewhere = track(from: 40, to: 50)
        let person = track(from: 10, to: 20, machine: false)
        let rally = RallyTruth.pretrackedChanges([under, half, elsewhere, person], start: 12, end: 21, kind: .rally)
        XCTAssertEqual(rally.map { $0.before.id }, [under.id], "mostly inside the mark, machine-made: the one at 10–20")
        XCTAssertEqual(rally[0].isRally, true)
        XCTAssertEqual(rally[0].after.start, 12, "trimmed to the mark (the usual margin kept)")
        XCTAssertEqual(rally[0].after.end, 20)
        XCTAssertEqual(rally[0].after.points.count, 17)
        let missed = RallyTruth.pretrackedChanges([under, half, elsewhere, person], start: 12, end: 21, kind: .missedServe)
        XCTAssertEqual(missed.map { $0.before.id }, [under.id])
        XCTAssertEqual(missed[0].isRally, false, "no rally there")
        XCTAssertEqual(missed[0].after, under, "turned down as it is, never trimmed")
        XCTAssertEqual(RallyTruth.pretrackedChanges([under], start: 12, end: 21, kind: .other)[0].isRally, false)
    }

    // MARK: - The Mac's store, on a project session

    func testTheMacStoreTurnsDownAPretrackedRallyUnderAMissedServeAndUndoPutsItBack() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("truth-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("P", isDirectory: true)
        let store = DatasetStore(root: root)
        try store.prepare()
        let footage = base.appendingPathComponent("v.mp4")
        try Data([1, 2, 3]).write(to: footage)
        var session = VideoSession(name: "v", sourcePath: footage.path, split: "train", addedAt: Date(), frames: [])
        let id = UUID()
        session.tracks = [track(id, from: 10, to: 20)]
        try store.save(session)
        let defaults = UserDefaults(suiteName: "RallyTruthTests-\(UUID().uuidString)")!
        let sampler = SamplerModel(defaults: defaults, root: root)
        XCTAssertEqual(sampler.sessions.map(\.name), ["v"])
        let tracker = TrackLabelModel(sampler: sampler)
        let review = ProjectReviewStore(sampler: sampler, tracker: tracker)
        let marker = RallyMarkModel(sampler: sampler)
        marker.open(sessionName: "v")
        let mac = ProjectLiveTagStore(session: sampler.sessions[0], marker: marker, review: review)
        let tagger = LiveTagger(tracks: sampler.sessions[0].tracks ?? [], store: mac)
        func current() -> TrackedRally { sampler.sessions[0].tracks!.first { $0.id == id }! }
        func paused(_ t: Double) -> LiveTagger.Press { LiveTagger.Press(now: t, playing: false, rate: 1) }

        // Serve, then Missed serve over the pre-tracked rally: it is no rally, and it is kept whole.
        tagger.serve(paused(9))
        tagger.close(as: .missedServe, paused(21))
        XCTAssertEqual(marker.rallies.map(\.kind), [.missedServe])
        XCTAssertEqual(current().isRally, false)
        XCTAssertEqual(current().start, 10); XCTAssertEqual(current().end, 20); XCTAssertEqual(current().points.count, 21)
        // Undo: the mark goes, the rally is as it was (not looked at), the serve is open again.
        tagger.undo()
        XCTAssertTrue(marker.rallies.isEmpty)
        XCTAssertNil(current().isRally)
        XCTAssertEqual(tagger.open ?? -1, 9, accuracy: 0.5)
        // Closed as a rally instead: confirmed and trimmed to the mark.
        tagger.close(as: .rally, paused(21))
        XCTAssertEqual(marker.rallies.map(\.kind), [.rally])
        XCTAssertEqual(current().isRally, true)
        XCTAssertEqual(current().points.count, 21, "the mark holds the whole track: nothing to trim")
        tagger.undo()
        XCTAssertNil(current().isRally)
        tagger.cancel()
        // A later serve inside the track trims it on confirmation, and undo restores every frame.
        tagger.serve(paused(12))
        tagger.close(as: .rally, paused(21))
        XCTAssertEqual(current().isRally, true)
        XCTAssertEqual(current().points.count, 17, "the frames before 11.7 s go")
        XCTAssertEqual(current().start, 12)
        tagger.undo()
        XCTAssertNil(current().isRally)
        XCTAssertEqual(current().points.count, 21); XCTAssertEqual(current().start, 10)
        // The file on disk says the same: the session's track as restored.
        XCTAssertEqual(try DatasetStore(root: root).loadSessionsStrict().first?.tracks?.first?.isRally, nil)
    }
}
