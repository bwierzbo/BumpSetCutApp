//
//  LoopingPlayerPoolTests.swift
//  BumpSetCutTests
//
//  Creation, sliding-window eviction, teardown and end-of-item looping of
//  LoopingPlayerPool, against real clips from TestVideoFactory.
//

import XCTest
import AVFoundation
@testable import BumpSetCut

@MainActor
final class LoopingPlayerPoolTests: XCTestCase {

    private var clip: URL!

    override func setUpWithError() throws {
        clip = try TestVideoFactory.makeTempVideo(duration: 1.0)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: clip)
    }

    func testPlayerIsCreatedOnceAndReused() {
        let pool = LoopingPlayerPool<Int>()
        XCTAssertNil(pool.player(for: 0))

        let first = pool.player(for: 0, url: clip)
        let second = pool.player(for: 0, url: clip)

        XCTAssertTrue(first === second)
        XCTAssertTrue(pool.player(for: 0) === first)
        XCTAssertEqual(pool.players.count, 1)
    }

    func testPoolSettingsApplyToEveryPlayer() {
        let pool = LoopingPlayerPool<Int>(isMuted: true, automaticallyWaitsToMinimizeStalling: false)
        let player = pool.player(for: 0, url: clip)

        XCTAssertTrue(player.isMuted)
        XCTAssertFalse(player.automaticallyWaitsToMinimizeStalling)
    }

    func testRetainWindowTearsDownEverythingOutsideIt() {
        let pool = LoopingPlayerPool<Int>()
        let players = (0..<5).map { pool.player(for: $0, url: clip) }

        pool.retain(window: [1, 2, 3])

        XCTAssertEqual(Set(pool.players.keys), [1, 2, 3])
        for evicted in [players[0], players[4]] {
            XCTAssertNil(evicted.currentItem, "evicted player must release its item")
            XCTAssertEqual(evicted.rate, 0)
        }
        XCTAssertNotNil(players[2].currentItem)
    }

    func testRetainWithLimitEvictsOldestFirst() {
        let pool = LoopingPlayerPool<Int>()
        for key in [7, 3, 9, 1] { pool.player(for: key, url: clip) }

        // Only 1 is kept; 7, 3, 9 are outside the window. Dropping oldest
        // first (7, then 3) gets down to the limit, so 9 survives.
        pool.retain(window: [1], limit: 2)

        XCTAssertEqual(Set(pool.players.keys), [9, 1])
    }

    func testTeardownAllReleasesEveryPlayer() {
        let pool = LoopingPlayerPool<Int>()
        let players = (0..<3).map { pool.player(for: $0, url: clip) }
        players[1].play()

        pool.teardownAll()

        XCTAssertTrue(pool.players.isEmpty)
        for player in players {
            XCTAssertNil(player.currentItem)
            XCTAssertEqual(player.rate, 0)
        }
    }

    func testActivatePlaysOnlyTheGivenKey() {
        let pool = LoopingPlayerPool<Int>()
        let a = pool.player(for: 0, url: clip)
        let b = pool.player(for: 1, url: clip)
        a.play()

        pool.activate(1)

        XCTAssertEqual(a.rate, 0)
        XCTAssertGreaterThan(b.rate, 0)

        pool.activate(0, play: false)
        XCTAssertEqual(a.rate, 0)
        XCTAssertEqual(b.rate, 0)
    }

    func testEndOfItemRestartsPlayback() async throws {
        let pool = LoopingPlayerPool<Int>()
        let player = pool.player(for: 0, url: clip)
        let item = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(player.rate, 0)

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertGreaterThan(player.rate, 0, "reaching the end loops back and keeps playing")
        pool.teardownAll()
    }

    func testSubRangeLoopsAtItsBoundary() async throws {
        let pool = LoopingPlayerPool<Int>()
        let start = CMTime(seconds: 0.1, preferredTimescale: 600)
        let end = CMTime(seconds: 0.4, preferredTimescale: 600)
        let player = pool.player(for: 0, url: clip, loopStart: start, loopEnd: end)
        _ = await pool.waitUntilReady(0, timeout: 5)

        player.play()
        try await Task.sleep(for: .milliseconds(900))

        XCTAssertGreaterThan(player.rate, 0)
        XCTAssertLessThan(CMTimeGetSeconds(player.currentTime()), 0.6,
                          "playback should wrap at the 0.4s boundary instead of running to the 1s end")
        pool.teardownAll()
    }

    func testTornDownPlayerNoLongerLoops() async throws {
        let pool = LoopingPlayerPool<Int>()
        let player = pool.player(for: 0, url: clip)
        let item = try XCTUnwrap(player.currentItem)

        pool.teardown(0)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(player.rate, 0, "the end observer must be gone after teardown")
    }

    func testWaitUntilReadyForLocalClip() async {
        let pool = LoopingPlayerPool<Int>()
        pool.player(for: 0, url: clip)

        let ready = await pool.waitUntilReady(0, timeout: 5)
        let missing = await pool.waitUntilReady(1, timeout: 0.1)

        XCTAssertTrue(ready)
        XCTAssertFalse(missing)
        pool.teardownAll()
    }
}
