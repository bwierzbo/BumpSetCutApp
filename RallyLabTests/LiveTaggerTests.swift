//
//  LiveTaggerTests.swift
//  RallyLabTests
//
//  Live tagging's rules (D-028): a serve opens a rally, D/M/N close it as
//  a rally, a missed serve or not a rally; a serve with one open closes it
//  where the ball's path last ended; undo reopens; nothing closes without
//  a serve. Cuts (D-030): X opens and closes one, ⇧X opens one at the
//  start, the next serve closes an open cut, a cut takes the marks mostly
//  inside it and undo brings them back.
//

import XCTest
@testable import RallyLab

@MainActor
final class LiveTaggerTests: XCTestCase {
    struct Marked: Hashable {
        let start: Double
        let end: Double
        let kind: RallyKind
    }

    final class Store: LiveTagStore {
        var marks: [Marked] = []
        var deleted = 0
        var cuts: [CutRange] = []
        private var next = 0
        private var handles: [Int: Marked] = [:]
        func mark(start: Double, end: Double, kind: RallyKind) -> AnyHashable {
            let m = Marked(start: start, end: end, kind: kind)
            marks.append(m)
            next += 1; handles[next] = m
            return next
        }
        func delete(_ mark: AnyHashable) {
            deleted += 1
            guard let h = mark as? Int, let m = handles.removeValue(forKey: h), let i = marks.firstIndex(of: m) else { return }
            marks.remove(at: i)
        }
        func confirmPretracked(start: Double, end: Double) -> [TrackedRally] { [] }
        func restore(_ rallies: [TrackedRally]) {}
        func marks(overlapping start: Double, _ end: Double) -> [LiveTagger.ExistingMark] {
            handles.filter { min($0.value.end, end) - max($0.value.start, start) > 0 }
                .sorted { $0.key < $1.key }
                .map { LiveTagger.ExistingMark(handle: $0.key, start: $0.value.start, end: $0.value.end, kind: $0.value.kind, contacts: nil) }
        }
        func restoreMark(_ mark: LiveTagger.ExistingMark) -> AnyHashable { self.mark(start: mark.start, end: mark.end, kind: mark.kind ?? .rally) }
        func cut(start: Double, end: Double) -> AnyHashable { let c = CutRange(start: start, end: end); cuts.append(c); return c }
        func uncut(_ cut: AnyHashable) { if let c = cut as? CutRange, let i = cuts.firstIndex(of: c) { cuts.remove(at: i) } }
    }

    private func paused(_ t: Double) -> LiveTagger.Press { LiveTagger.Press(now: t, playing: false, rate: 1) }

    func testServeThenDeadBallMarksARally() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        tagger.serve(paused(10))
        XCTAssertEqual(tagger.open, 10)
        tagger.close(as: .rally, paused(18))
        XCTAssertNil(tagger.open)
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertEqual(store.marks[0].start, 10)
        XCTAssertEqual(store.marks[0].end, 18)
        XCTAssertEqual(store.marks[0].kind, .rally)
    }

    func testMissedServeAndNotARallyKeepTheirKinds() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        tagger.serve(paused(1))
        tagger.close(as: .missedServe, paused(3))
        tagger.serve(paused(20))
        tagger.close(as: .other, paused(25))
        XCTAssertEqual(store.marks.map(\.kind), [.missedServe, .other])
    }

    func testNothingClosesWithoutAServe() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        tagger.close(as: .rally, paused(5))
        XCTAssertTrue(store.marks.isEmpty)
        XCTAssertEqual(tagger.recentNote, "No rally open — S starts one")
    }

    func testAServeWithOneOpenClosesItWhereTheBallPathEnded() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        // The ball seen from 10.0 to 15.0 in a straight line: one stretch, no turns.
        let seen = stride(from: 10.0, through: 15.0, by: 0.1).map {
            BallPath.Sample(time: $0, center: CGPoint(x: 0.5, y: 0.5), size: 0.02)
        }
        tagger.path = BallPath(tracks: [], seen: seen)
        tagger.serve(paused(10))
        tagger.serve(paused(30))
        XCTAssertEqual(store.marks.count, 1)
        XCTAssertEqual(store.marks[0].start, 10)
        XCTAssertEqual(store.marks[0].end, 15, accuracy: 0.001)
        XCTAssertEqual(tagger.open, 30)
    }

    func testAServeWithOneOpenAndNoPathClosesItJustBefore() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        tagger.serve(paused(10))
        tagger.serve(paused(30))
        XCTAssertEqual(store.marks[0].end, 29.7, accuracy: 0.001)
    }

    func testUndoReopensTheLastRallyThenDropsItsServe() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        tagger.serve(paused(10))
        tagger.close(as: .rally, paused(18))
        tagger.undo()
        XCTAssertEqual(store.deleted, 1)
        XCTAssertTrue(store.marks.isEmpty)
        XCTAssertEqual(tagger.open, 10)
        tagger.undo()
        XCTAssertNil(tagger.open)
        XCTAssertEqual(tagger.recentNote, "Serve taken back")
    }

    // MARK: - Cuts (D-030)

    func testXOpensACutAndXClosesIt() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        tagger.cut(paused(141.6))
        XCTAssertEqual(tagger.cutFrom, 141.6)
        tagger.cut(paused(141.8))
        XCTAssertEqual(tagger.cutFrom, 141.6, "too short to be a cut")
        XCTAssertEqual(tagger.recentNote, "A cut has to be at least half a second")
        tagger.cut(paused(157))
        XCTAssertNil(tagger.cutFrom)
        XCTAssertEqual(store.cuts, [CutRange(start: 141.6, end: 157)])
        // While playing, a press is backed up for the reaction like any other.
        tagger.cut(LiveTagger.Press(now: 200, playing: true, rate: 2))
        XCTAssertEqual(try XCTUnwrap(tagger.cutFrom), 199.5, accuracy: 1e-9)
    }

    func testACutCannotStartInsideARallyAndNothingClosesWhileOneIsOpen() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        tagger.serve(paused(10))
        tagger.cut(paused(12))
        XCTAssertNil(tagger.cutFrom)
        XCTAssertEqual(tagger.recentNote, "Close the rally first (D, M or N) — a cut can't start inside one")
        tagger.cutFromStart()
        XCTAssertNil(tagger.cutFrom)
        tagger.close(as: .rally, paused(18))
        tagger.cut(paused(20))
        tagger.close(as: .rally, paused(25))
        XCTAssertEqual(store.marks.count, 1, "D with a cut open does nothing")
        XCTAssertEqual(tagger.recentNote, "Cut open — X ends it, or S at the next serve")
        XCTAssertEqual(tagger.cutFrom, 20)
    }

    func testTheClipStartsMidRallyAndTheNextServeEndsTheCut() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        tagger.cutFromStart()
        XCTAssertEqual(tagger.cutFrom, 0)
        tagger.serve(paused(0.6))
        XCTAssertEqual(tagger.cutFrom, 0, "the serve has to leave room for a cut")
        XCTAssertNil(tagger.open)
        tagger.serve(paused(12.4))
        XCTAssertNil(tagger.cutFrom)
        XCTAssertEqual(store.cuts, [CutRange(start: 0, end: 12.1)])
        XCTAssertEqual(tagger.open, 12.4)
        tagger.cutFromStart()
        XCTAssertEqual(tagger.recentNote, "Close the rally first (D, M or N)")
    }

    func testACutTakesTheMarksMostlyInsideItAndUndoBringsThemBack() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        tagger.serve(paused(10)); tagger.close(as: .rally, paused(20))          // mostly inside the cut: goes
        tagger.serve(paused(30)); tagger.close(as: .missedServe, paused(33))    // inside: goes
        tagger.serve(paused(38)); tagger.close(as: .rally, paused(48))          // brushes it: stays
        tagger.cut(paused(14)); tagger.cut(paused(42))
        XCTAssertEqual(store.cuts, [CutRange(start: 14, end: 42)])
        XCTAssertEqual(store.marks, [Marked(start: 38, end: 48, kind: .rally)])
        XCTAssertEqual(store.deleted, 2)
        // Z: the cut reopens with its marks back; Z again drops it.
        tagger.undo()
        XCTAssertEqual(tagger.cutFrom, 14)
        XCTAssertTrue(store.cuts.isEmpty)
        XCTAssertEqual(Set(store.marks), [Marked(start: 38, end: 48, kind: .rally), Marked(start: 10, end: 20, kind: .rally), Marked(start: 30, end: 33, kind: .missedServe)])
        XCTAssertEqual(tagger.recentNote, "Reopened the cut from 0:14.0 · 2 rallies back")
        tagger.undo()
        XCTAssertNil(tagger.cutFrom)
        XCTAssertEqual(tagger.recentNote, "Cut taken back")
        // Undo past the cut reaches the rallies closed before it.
        tagger.undo()
        XCTAssertEqual(tagger.open, 38)
    }

    func testEscapeDropsAnOpenCutBeforeAnOpenRally() {
        let store = Store()
        let tagger = LiveTagger(tracks: [], store: store)
        XCTAssertFalse(tagger.cancel())
        tagger.cut(paused(5))
        XCTAssertTrue(tagger.cancel())
        XCTAssertNil(tagger.cutFrom)
        XCTAssertEqual(tagger.recentNote, "Cut cancelled")
        tagger.serve(paused(10))
        XCTAssertTrue(tagger.cancel())
        XCTAssertNil(tagger.open)
    }
}
