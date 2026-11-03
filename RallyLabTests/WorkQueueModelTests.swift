//
//  WorkQueueModelTests.swift
//  RallyLabTests
//
//  The Queue tab's model serialises every queue-file operation (Codex, PR
//  #134): a person's cancel during a refresh survives whichever finishes
//  first, the refresh's flag clears regardless, and a project change drops
//  results from the old project without leaving the flag set.
//

import XCTest
@testable import RallyLab

final class WorkQueueModelTests: XCTestCase {
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-11-02T20:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wqm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        let store = DatasetStore(root: root)
        try store.prepare()
        // Project cards with fingerprints: an identified recording is admitted; one with no card would be
        // unidentified, and the queue blocks every task of an inadmissible recording (owner, 2026-11-03).
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let project = Project(name: "Fixture", createdAt: now, framesPerRally: 2, clips: ["a", "b", "c"].enumerated().map { n, id in
            SourceRegistryTests.clip(id, number: n + 1, videos: [SourceRegistryTests.video(nil, fingerprint: "file:\(id)\(id)\(id)")])
        })
        try encoder.encode(project).write(to: root.appendingPathComponent("project.json"))
        for n in ["a", "b", "c"] {
            var s = VideoSession(name: n, sourcePath: root.appendingPathComponent("footage/\(n).mp4").path, split: "train", addedAt: now, frames: [])
            s.tracks = [SourceRegistryTests.rally(done: true), SourceRegistryTests.rally(done: true)]
            try store.save(s)
        }
        try #"{"tune":[],"holdout":[]}"#.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testCancelDuringRefreshSurvivesAndRefreshingClears() async throws {
        // A queue to act on.
        _ = try WorkQueueReconciler.run(root: root, project: "Fixture", now: now)
        let model = WorkQueueModel(root: root, project: "Fixture")
        model.load()
        await model.settle()
        XCTAssertEqual(model.file?.task("ball_tracks:a")?.state, .complete)
        // Refresh, and cancel while it runs; then reopen while another refresh runs.
        model.refresh()
        XCTAssertTrue(model.refreshing)
        model.cancel("ball_tracks:a")
        model.retry("ball_tracks:b")   // not failed: refused, and the refusal must not break anything else
        await model.settle()
        XCTAssertFalse(model.refreshing, "the refresh's flag clears whatever else ran")
        XCTAssertEqual(model.file?.task("ball_tracks:a")?.state, .cancelled, "the person's cancel survives the refresh")
        XCTAssertEqual(try WorkQueue.Store(root: root).load()?.task("ball_tracks:a")?.state, .cancelled, "and is on disk")
        XCTAssertEqual(model.file?.task("ball_tracks:a")?.history.last?.by, .user)
        XCTAssertNil(model.problem, "the refresh that finished last cleared the refused retry's message; the file is intact")
        model.retry("ball_tracks:b")
        await model.settle()
        XCTAssertNotNil(model.problem, "a refused retry on its own is reported")
        XCTAssertEqual(try WorkQueue.Store(root: root).load()?.task("ball_tracks:b")?.state, .complete, "and changes nothing")
        model.refresh()
        model.reopen("ball_tracks:a")
        await model.settle()
        XCTAssertFalse(model.refreshing)
        XCTAssertEqual(try WorkQueue.Store(root: root).load()?.task("ball_tracks:a")?.state, .complete, "reopened to pending, then reconciled back to what the files say")
        XCTAssertEqual(model.file, try WorkQueue.Store(root: root).load(), "the model shows the file as last written")
    }

    @MainActor
    func testManyInterleavedOperationsLoseNothing() async throws {
        _ = try WorkQueueReconciler.run(root: root, project: "Fixture", now: now)
        let model = WorkQueueModel(root: root, project: "Fixture")
        for _ in 0..<3 {
            model.refresh()
            model.cancel("ball_tracks:b")
            model.reopen("ball_tracks:b")
            model.cancel("ball_tracks:c")
            await model.settle()
        }
        let file = try XCTUnwrap(try WorkQueue.Store(root: root).load())
        XCTAssertEqual(file.task("ball_tracks:c")?.state, .cancelled)
        // The person's actions land in the order they were made: cancel, then reopen, every round — so b is never
        // left cancelled, and no cancel is refused as a same-state move. Whether the round's refresh reconciled it
        // back to complete before or after the reopen is the scheduler's (a refresh is not in the actions' order).
        XCTAssertTrue([.complete, .pending].contains(file.task("ball_tracks:b")?.state), "\(String(describing: file.task("ball_tracks:b")?.state))")
        let history = file.task("ball_tracks:b")?.history.map { ($0.to, $0.by) } ?? []
        XCTAssertEqual(history.filter { $0.0 == .cancelled }.count, 3, "every cancel is in the history")
        XCTAssertEqual(history.filter { $0.0 == .pending && $0.1 == .user }.count, 3, "every reopen is in the history")
        var last: WorkQueue.State?
        for (to, by) in history where by == .user {
            if to == .cancelled { XCTAssertNotEqual(last, .cancelled, "a cancel landed on a cancelled task") }
            if to == .pending { XCTAssertEqual(last, .cancelled, "a reopen landed before its cancel") }
            last = to
        }
        XCTAssertEqual(model.file, file)
        XCTAssertFalse(model.refreshing)
    }

    @MainActor
    func testProjectChangeDropsOldResultsAndClearsTheFlag() async throws {
        _ = try WorkQueueReconciler.run(root: root, project: "Fixture", now: now)
        let model = WorkQueueModel(root: root, project: "Fixture")
        model.refresh()
        model.projectChanged()
        XCTAssertFalse(model.refreshing)
        await model.settle()
        XCTAssertFalse(model.refreshing)
        XCTAssertNil(model.summary, "the old refresh's result landed nowhere")
    }
}
