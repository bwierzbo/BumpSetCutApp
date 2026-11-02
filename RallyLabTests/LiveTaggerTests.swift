//
//  LiveTaggerTests.swift
//  RallyLabTests
//
//  Live tagging's rules (D-028): a serve opens a rally, D/M/N close it as
//  a rally, a missed serve or not a rally; a serve with one open closes it
//  where the ball's path last ended; undo reopens; nothing closes without
//  a serve.
//

import XCTest
@testable import RallyLab

@MainActor
final class LiveTaggerTests: XCTestCase {
    struct Marked: Equatable {
        let start: Double
        let end: Double
        let kind: RallyKind
    }

    final class Store: LiveTagStore {
        var marks: [Marked] = []
        var deleted = 0
        func mark(start: Double, end: Double, kind: RallyKind) -> AnyHashable {
            marks.append(Marked(start: start, end: end, kind: kind))
            return marks.count
        }
        func delete(_ mark: AnyHashable) { deleted += 1; marks.removeLast() }
        func confirmPretracked(start: Double, end: Double) -> [TrackedRally] { [] }
        func restore(_ rallies: [TrackedRally]) {}
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
}
