//
//  FootagePresenceTests.swift
//  RallyLabTests
//
//  The lists' answer to "is this footage file here": checked once, then the last answer, checked again in the
//  background once it is old.
//

import XCTest
@testable import RallyLab

final class FootagePresenceTests: XCTestCase {
    private final class Disk: @unchecked Sendable {
        private let lock = NSLock()
        private var files: Set<String>
        private var asked: [String] = []
        private var time = Date(timeIntervalSince1970: 1_000)
        init(_ files: Set<String>) { self.files = files }
        func check(_ path: String) -> Bool { lock.lock(); defer { lock.unlock() }; asked.append(path); return files.contains(path) }
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return time }
        func advance(_ seconds: TimeInterval) { lock.lock(); time += seconds; lock.unlock() }
        func set(_ files: Set<String>) { lock.lock(); self.files = files; lock.unlock() }
        var checks: Int { lock.lock(); defer { lock.unlock() }; return asked.count }
    }

    private func presence(_ disk: Disk) -> FootagePresence {
        FootagePresence(read: { disk.check($0) }, now: { disk.now() })
    }

    func testEachPathIsCheckedOnceHoweverOftenTheListIsBuilt() {
        let disk = Disk(["/a.mp4", "/c.mp4"])
        let presence = presence(disk)
        let paths = ["/a.mp4", "/b.mp4", "/c.mp4"]
        XCTAssertEqual(presence.here(paths), ["/a.mp4", "/c.mp4"])
        XCTAssertEqual(disk.checks, 3)
        for _ in 0..<50 { XCTAssertEqual(presence.here(paths), ["/a.mp4", "/c.mp4"]) }
        XCTAssertEqual(disk.checks, 3, "a redraw asks the file system nothing")
    }

    func testAPathNotSeenBeforeIsCheckedBeforeItIsAnswered() {
        let disk = Disk(["/a.mp4", "/new.mp4"])
        let presence = presence(disk)
        _ = presence.here(["/a.mp4"])
        XCTAssertEqual(presence.here(["/a.mp4", "/new.mp4"]), ["/a.mp4", "/new.mp4"])
        XCTAssertEqual(disk.checks, 2)
    }

    func testAnOldAnswerStandsForThisCallAndIsCheckedAgainBehindIt() {
        let disk = Disk(["/a.mp4"])
        let presence = presence(disk)
        XCTAssertEqual(presence.here(["/a.mp4"]), ["/a.mp4"])
        disk.set([])
        disk.advance(FootagePresence.maxAge - 1)
        XCTAssertEqual(presence.here(["/a.mp4"]), ["/a.mp4"], "not old yet")
        XCTAssertEqual(disk.checks, 1)
        disk.advance(2)
        _ = presence.here(["/a.mp4"])
        let gone = expectation(description: "the file's absence is learned in the background")
        func poll() {
            if presence.here(["/a.mp4"]).isEmpty { gone.fulfill() } else { DispatchQueue.global().asyncAfter(deadline: .now() + 0.02, execute: poll) }
        }
        poll()
        wait(for: [gone], timeout: 5)
        XCTAssertEqual(disk.checks, 2, "one check again, not one per call")
    }

    func testTheSamePathTwiceIsOneCheck() {
        let disk = Disk(["/a.mp4"])
        XCTAssertEqual(presence(disk).here(["/a.mp4", "/a.mp4"]), ["/a.mp4"])
        XCTAssertEqual(disk.checks, 1)
    }

    func testARememberedAnswerIsDrawnWithoutACheck() {
        let disk = Disk([])
        let presence = presence(disk)
        XCTAssertEqual(presence.here(["/a.rallylabels.json"]), [])
        presence.remember(true, for: "/a.rallylabels.json")
        XCTAssertEqual(presence.here(["/a.rallylabels.json"]), ["/a.rallylabels.json"])
        XCTAssertEqual(disk.checks, 1, "the writer's word, not another check")
    }

    /// The Label tab's queue and the coverage table's buttons draw the marks from the last answers: a save in
    /// this app shows at once, and a file changed elsewhere is read once, not on every redraw.
    @MainActor
    func testListedMarksFollowTheAppsOwnSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("v.mp4")
        let session = VideoSession(name: "v", sourcePath: video.path, split: "train", addedAt: Date(), frames: [])
        XCTAssertEqual(RallyMarkModel.listedMarks(in: session).count, 0, "no file: no marks")
        let sidecar = RallyMarkModel.labelsURL(for: video)
        try RallyMarkModel.write([RallyMarkRecord(startTime: 10, endTime: 20, kind: .rally, contacts: nil)], to: sidecar)
        XCTAssertEqual(RallyMarkModel.listedMarks(in: session).map(\.start), [10], "the app's own save is drawn at once")
        XCTAssertTrue(FootagePresence.shared.here([sidecar.path]).contains(sidecar.path))
        try "[]".write(to: sidecar, atomically: true, encoding: .utf8)
        XCTAssertEqual(RallyMarkModel.listedMarks(in: session).map(\.start), [10], "a change from elsewhere waits for the next check")
        XCTAssertEqual(RallyMarkModel.marks(in: session).count, 0, "what acts on the marks reads the file")
    }
}
