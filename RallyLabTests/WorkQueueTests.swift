//
//  WorkQueueTests.swift
//  RallyLabTests
//
//  The persistent work queue (RallyLab 2.0, phase 1): deterministic task ids
//  and idempotent enqueue, the lifecycle table, retry / cancel / reopen, the
//  strict store (an unreadable file is refused, never read as empty or
//  overwritten), and the atomic write.
//

import XCTest
@testable import RallyLab

final class WorkQueueTests: XCTestCase {
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-11-02T20:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func file() -> WorkQueue.File { WorkQueue.File(project: "Fixture", updatedAt: WorkQueue.stamp(now)) }

    // MARK: - Identity

    func testTaskIdIsDeterministicAndScoped() {
        XCTAssertEqual(WorkQueue.Task.id(kind: .rallyBoundaries, video: "v1", scope: nil), "rally_boundaries:v1")
        XCTAssertEqual(WorkQueue.Task.id(kind: .contactLabels, video: "v1", scope: "ABC"), "contact_labels:v1:ABC")
    }

    func testEnqueueIsIdempotent() {
        var f = file()
        let first = f.enqueue(kind: .ballTracks, video: "v1", identityKey: "fp:file:1", now: now)
        XCTAssertTrue(first.created)
        XCTAssertEqual(first.task.state, .pending)
        XCTAssertEqual(first.task.history.count, 1)
        let again = f.enqueue(kind: .ballTracks, video: "v1", now: now.addingTimeInterval(60))
        XCTAssertFalse(again.created)
        XCTAssertEqual(again.task, first.task, "asking again returns the one record, unchanged")
        XCTAssertEqual(f.tasks.count, 1)
        // A contact-label task per rally stands on its own: it does not need the boundaries task to be complete.
        let contact = f.enqueue(kind: .contactLabels, video: "v1", scope: UUID().uuidString, now: now)
        XCTAssertTrue(contact.created)
        XCTAssertEqual(f.tasks.count, 2)
    }

    // MARK: - Lifecycle

    func testReconcileMayMoveBetweenAnyNonFinalStatesAndNeverTouchesCancelled() throws {
        var f = file()
        let id = f.enqueue(kind: .rallyBoundaries, video: "v1", now: now).task.id
        let o = WorkQueue.Observed(at: WorkQueue.stamp(now), summary: "seen")
        XCTAssertTrue(try f.reconcile(id, state: .inProgress, reason: nil, observed: o, now: now))
        XCTAssertTrue(try f.reconcile(id, state: .complete, reason: nil, observed: o, now: now))
        XCTAssertTrue(try f.reconcile(id, state: .inProgress, reason: nil, observed: o, now: now), "the files are the truth: a withdrawn completion moves it back")
        XCTAssertFalse(try f.reconcile(id, state: .inProgress, reason: nil, observed: o, now: now), "same verdict: no change")
        XCTAssertEqual(f.task(id)?.history.count, 4)
        try f.cancel(id, now: now)
        XCTAssertFalse(try f.reconcile(id, state: .complete, reason: nil, observed: o, now: now))
        XCTAssertEqual(f.task(id)?.state, .cancelled)
        XCTAssertThrowsError(try f.transition(id, to: .ready, by: .reconcile, now: now))
    }

    func testUserMovesAreRetryCancelReopenOnly() throws {
        var f = file()
        let id = f.enqueue(kind: .netCorners, video: "v1", now: now).task.id
        XCTAssertThrowsError(try f.transition(id, to: .complete, by: .user, now: now), "a person cannot declare a task complete; the files do")
        XCTAssertThrowsError(try f.retry(id, now: now), "only a failed task is retried")
        let o = WorkQueue.Observed(at: WorkQueue.stamp(now), summary: "broken")
        _ = try f.reconcile(id, state: .failed, reason: "record not accepted", observed: o, now: now)
        XCTAssertEqual(f.task(id)?.reason, "record not accepted")
        try f.retry(id, now: now)
        XCTAssertEqual(f.task(id)?.state, .pending)
        XCTAssertEqual(f.task(id)?.attempts, 1)
        XCTAssertNil(f.task(id)?.reason)
        try f.cancel(id, now: now)
        XCTAssertThrowsError(try f.cancel(id, now: now))
        try f.reopen(id, now: now)
        XCTAssertEqual(f.task(id)?.state, .pending)
        XCTAssertEqual(f.task(id)?.history.map(\.by), [.reconcile, .reconcile, .user, .user, .user])
    }

    func testAllowedTable() {
        for from in WorkQueue.State.allCases {
            for to in WorkQueue.State.allCases where from != to {
                let reconcile = WorkQueue.allowed(from: from, to: to, by: .reconcile)
                XCTAssertEqual(reconcile, from != .cancelled && to != .cancelled, "\(from) → \(to) by reconcile")
                let user = WorkQueue.allowed(from: from, to: to, by: .user)
                let expected = (from == .failed && to == .pending) || (from == .cancelled && to == .pending) || (to == .cancelled && from != .cancelled)
                XCTAssertEqual(user, expected, "\(from) → \(to) by user")
            }
        }
    }

    // MARK: - Store

    func testRoundTripAndAtomicWrite() throws {
        var f = file()
        f.enqueue(kind: .ballTracks, video: "v1", now: now)
        let store = WorkQueue.Store(root: root)
        try store.save(f)
        XCTAssertEqual(try store.load(), f)
        let dir = root.appendingPathComponent("tasks")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0 != "work-queue.json" }
        XCTAssertEqual(leftovers, [], "written whole: no temporary file left beside it")
    }

    func testUnreadableQueueIsRefusedNotEmptied() throws {
        let store = WorkQueue.Store(root: root)
        XCTAssertNil(try store.load(), "absence is not an error")
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"schemaVersion\":1,\"project\":\"x\",\"tasks\":[{".write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0 is WorkQueue.Failure) }
        try "{\"schemaVersion\":2,\"project\":\"x\",\"updatedAt\":\"t\",\"tasks\":[]}".write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? WorkQueue.Failure, .unsupportedVersion(2)) }
        let dup = """
        {"schemaVersion":1,"project":"x","updatedAt":"t","tasks":[
          {"id":"a","kind":"ball_tracks","video":"v","state":"pending","createdAt":"t","updatedAt":"t","attempts":0,"history":[]},
          {"id":"a","kind":"ball_tracks","video":"v","state":"pending","createdAt":"t","updatedAt":"t","attempts":0,"history":[]}]}
        """
        try dup.write(to: store.url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load())
    }

    func testOlderFileWithoutPolicyReadsWithDefaults() throws {
        let text = "{\"schemaVersion\":1,\"project\":\"x\",\"updatedAt\":\"t\",\"tasks\":[]}"
        let f = try JSONDecoder().decode(WorkQueue.File.self, from: Data(text.utf8))
        XCTAssertEqual(f.policy.ballTrackRalliesPerRecording, 2)
    }
}
