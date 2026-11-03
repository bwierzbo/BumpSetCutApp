//
//  WorkQueueReconcilerTests.swift
//  RallyLabTests
//
//  The reconciler (RallyLab 2.0, phase 1): a task's state comes from the
//  annotation files and nothing else — a withheld recording is blocked, the
//  legacy "marked every rally" declaration never completes a Stage 1 task, a
//  pre-tracked rally nobody checked never counts as a label, a model's net
//  proposal is pending review rather than labeled — and running it twice
//  changes nothing the second time.
//

import XCTest
@testable import RallyLab

final class WorkQueueReconcilerTests: XCTestCase {
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-11-02T20:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wqr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try DatasetStore(root: root).prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func session(_ name: String, marked: Bool? = nil, tracks: [TrackedRally] = []) -> VideoSession {
        var s = VideoSession(name: name, sourcePath: root.appendingPathComponent("footage/\(name).mp4").path, split: "train", addedAt: now, frames: [])
        s.ralliesMarked = marked
        s.tracks = tracks.isEmpty ? nil : tracks
        return s
    }

    private func recording(_ name: String, withheld: Bool = false, eventsFile: Bool = false, coverage: Double? = nil, reviewed: Int = 0,
                           gaps: Int = 0, complete: Bool = false, legacy: Int? = nil, problem: String? = nil) -> EventInventory.Recording {
        EventInventory.Recording(name: name, split: "train", withheld: withheld, durationSec: eventsFile ? 300 : nil, legacyMarks: legacy, legacyFile: legacy != nil,
                                 eventsFile: eventsFile, reviewedRallies: reviewed, withdrawnRallies: 0, spans: 0, coverageSec: (coverage ?? 0) * 300,
                                 coverageFraction: coverage, unknownGaps: gaps, stage1Complete: complete, recordProblem: problem)
    }

    private func inputs(sessions: [VideoSession], withheld: Set<String> = [], events: [EventInventory.Recording] = [],
                        net: [String: WorkQueueReconciler.NetObservation]? = nil, netProblem: String? = nil,
                        policy: WorkQueue.Policy = WorkQueue.Policy()) -> WorkQueueReconciler.Inputs {
        WorkQueueReconciler.Inputs(sessions: sessions, withheld: withheld,
                                   events: Dictionary(events.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a }),
                                   net: net, netProblem: netProblem, identityKeys: [:], policy: policy, now: now)
    }

    // MARK: - Stage 1 rally boundaries

    func testDeclaredCompletionCompletesTheTaskButIsNotVerifiedCoverage() {
        let v = WorkQueueReconciler.verdicts(inputs(sessions: [session("v", marked: true)], events: [recording("v", legacy: 12)]))
        let rb = v[.rallyBoundaries]!["v"]!
        XCTAssertEqual(rb.state, .complete, "the owner's declaration stands (2026-11-03 §9): nothing is to be redone")
        XCTAssertEqual(rb.observed.declaredComplete, true)
        XCTAssertNil(rb.observed.verifiedCoverage, "but coverage is not verified")
        XCTAssertTrue(rb.observed.summary.contains("not verified"))
        // A Stage 1 record in progress on a declared-complete recording: in progress, verified coverage shown.
        let v2 = WorkQueueReconciler.verdicts(inputs(sessions: [session("v", marked: true)], events: [recording("v", eventsFile: true, coverage: 0.3, reviewed: 1, gaps: 1, legacy: 12)]))
        XCTAssertEqual(v2[.rallyBoundaries]!["v"]?.state, .inProgress)
        XCTAssertEqual(v2[.rallyBoundaries]!["v"]?.observed.verifiedCoverage, 0.3)
        XCTAssertEqual(v2[.rallyBoundaries]!["v"]?.observed.declaredComplete, true)
    }

    func testStage1States() {
        let v = WorkQueueReconciler.verdicts(inputs(sessions: [session("w"), session("p"), session("c"), session("f"), session("n")],
                                                    withheld: ["w"],
                                                    events: [recording("w", withheld: true), recording("p", eventsFile: true, coverage: 0.4, reviewed: 3, gaps: 2),
                                                             recording("c", eventsFile: true, coverage: 1, reviewed: 9, complete: true),
                                                             recording("f", eventsFile: true, problem: "belongs to x")]))
        let rb = v[.rallyBoundaries]!
        XCTAssertEqual(rb["w"]?.state, .blocked)
        XCTAssertNotNil(rb["w"]?.reason)
        XCTAssertEqual(rb["p"]?.state, .inProgress)
        XCTAssertEqual(rb["p"]?.observed.verifiedCoverage, 0.4)
        XCTAssertEqual(rb["c"]?.state, .complete)
        XCTAssertEqual(rb["f"]?.state, .failed)
        XCTAssertEqual(rb["n"]?.state, .ready, "no record, no inventory row: ready")
        // Withheld by the closure alone (no inventory row saying so) is blocked too.
        XCTAssertEqual(v[.ballTracks]!["w"]?.state, .blocked)
    }

    // MARK: - Ball tracks

    func testMachineProposalsNeverCompleteBallTracks() {
        let machine = SourceRegistryTests.rally(done: false, machine: true, isRally: nil)
        let human = SourceRegistryTests.rally(done: true)
        let open = SourceRegistryTests.rally(done: false)
        let confirmedUnchecked = SourceRegistryTests.rally(done: false, machine: true, isRally: true, checked: false)
        let v = WorkQueueReconciler.verdicts(inputs(sessions: [
            session("m", tracks: [machine, machine, machine]),
            session("h1", tracks: [human, machine]),
            session("h2", tracks: [human, human]),
            session("o", tracks: [human, human, open]),
            session("cu", tracks: [confirmedUnchecked]),
            session("e"),
        ]))
        let bt = v[.ballTracks]!
        XCTAssertEqual(bt["m"]?.state, .needsReview)
        XCTAssertEqual(bt["m"]?.observed.humanLabeled, 0)
        XCTAssertEqual(bt["m"]?.observed.machineProposed, 3)
        XCTAssertEqual(bt["h1"]?.state, .inProgress)
        XCTAssertEqual(bt["h2"]?.state, .complete)
        XCTAssertEqual(bt["o"]?.state, .inProgress, "an unfinished rally keeps it in progress even past the target")
        XCTAssertEqual(bt["o"]?.observed.open, 1)
        XCTAssertEqual(bt["cu"]?.state, .ready, "confirmed as a rally but no frame checked: not a label yet")
        XCTAssertEqual(bt["e"]?.state, .ready)
        let three = WorkQueueReconciler.verdicts(inputs(sessions: [session("h2", tracks: [human, human])], policy: WorkQueue.Policy(ballTrackRalliesPerRecording: 3)))
        XCTAssertEqual(three[.ballTracks]!["h2"]?.state, .inProgress, "the target is the policy's")
    }

    // MARK: - Net corners

    func testNetStatesAndProposalsStayProposals() {
        typealias N = WorkQueueReconciler.NetObservation
        let net: [String: N] = [
            "l": N(skip: nil, status: .init(labeled: true), proposalPending: false),
            "b": N(skip: nil, status: .init(boxOnly: true), proposalPending: false),
            "p": N(skip: nil, status: .init(), proposalPending: true),
            "s": N(skip: nil, status: .init(stale: true), proposalPending: false),
            "h": N(skip: .handheld, status: .init(), proposalPending: false),
            "w": N(skip: .withheld, status: .init(labeled: true), proposalPending: false),
            "n": N(skip: nil, status: .init(), proposalPending: false),
        ]
        let v = WorkQueueReconciler.verdicts(inputs(sessions: ["l", "b", "p", "s", "h", "w", "n", "nocard"].map { session($0) }, net: net))
        let nc = v[.netCorners]!
        XCTAssertEqual(nc["l"]?.state, .complete)
        XCTAssertEqual(nc["b"]?.state, .inProgress)
        XCTAssertEqual(nc["p"]?.state, .needsReview, "a model's proposal awaits the person; it is not a label")
        XCTAssertEqual(nc["p"]?.observed.proposalPending, true)
        XCTAssertEqual(nc["s"]?.state, .ready)
        XCTAssertEqual(nc["h"]?.state, .blocked)
        XCTAssertEqual(nc["w"]?.state, .blocked, "withheld even with a label on file")
        XCTAssertEqual(nc["n"]?.state, .ready)
        XCTAssertEqual(nc["nocard"]?.state, .blocked)
        // Withheld by file or content (the inventory's judgement), labelable by the manifest's identities: blocked (Codex, PR #134).
        let byFile = WorkQueueReconciler.verdicts(inputs(sessions: [session("x")], events: [recording("x", withheld: true)],
                                                         net: ["x": N(skip: nil, status: .init(labeled: true), proposalPending: false)]))
        XCTAssertEqual(byFile[.netCorners]!["x"]?.state, .blocked)
        XCTAssertNotNil(byFile[.netCorners]!["x"]?.reason)
        let byClosure = WorkQueueReconciler.verdicts(inputs(sessions: [session("y")], withheld: ["y"],
                                                            net: ["y": N(skip: nil, status: .init(), proposalPending: true)]))
        XCTAssertEqual(byClosure[.netCorners]!["y"]?.state, .blocked)
        let none = WorkQueueReconciler.verdicts(inputs(sessions: [session("l")], net: nil, netProblem: "stale manifest"))
        XCTAssertNil(none[.netCorners], "no net inventory: no net verdicts")
    }

    // MARK: - Apply

    func testApplyIsIdempotentAndCreatesNoContactTasks() throws {
        let human = SourceRegistryTests.rally(done: true)
        let in1 = inputs(sessions: [session("a", tracks: [human, human]), session("w")], withheld: ["w"],
                         events: [recording("a", eventsFile: true, coverage: 0.5, reviewed: 2, gaps: 1), recording("w", withheld: true)],
                         net: ["a": .init(skip: nil, status: .init(), proposalPending: true)])
        var file = WorkQueue.File(project: "Fixture", updatedAt: WorkQueue.stamp(now))
        let first = WorkQueueReconciler.apply(in1, to: &file)
        XCTAssertEqual(first.created, 6)
        XCTAssertEqual(first.changed, 6, "every new task moved from pending to its verdict")
        XCTAssertEqual(file.tasks(.contactLabels).count, 0, "contact tasks are defined, not created")
        XCTAssertEqual(file.task("rally_boundaries:a")?.state, .inProgress)
        XCTAssertEqual(file.task("ball_tracks:a")?.state, .complete)
        XCTAssertEqual(file.task("net_corners:a")?.state, .needsReview)
        XCTAssertEqual(file.task("rally_boundaries:w")?.state, .blocked)
        XCTAssertEqual(file.task("net_corners:w")?.state, .blocked)
        let snapshot = file
        let second = WorkQueueReconciler.apply(in1, to: &file)
        XCTAssertEqual(second.created, 0)
        XCTAssertEqual(second.changed, 0)
        XCTAssertEqual(second.unchanged, 6)
        XCTAssertEqual(file.tasks.map(\.state), snapshot.tasks.map(\.state))
        XCTAssertEqual(file.tasks.map(\.history), snapshot.tasks.map(\.history), "the second run adds no history")
        // The person cancels one; the files still say otherwise; reconcile leaves it cancelled.
        try file.cancel("net_corners:a", now: now)
        _ = WorkQueueReconciler.apply(in1, to: &file)
        XCTAssertEqual(file.task("net_corners:a")?.state, .cancelled)
        // A recording leaves the dataset: its tasks are blocked and say so.
        let in2 = inputs(sessions: [session("w")], withheld: ["w"], events: [recording("w", withheld: true)], net: [:])
        _ = WorkQueueReconciler.apply(in2, to: &file)
        XCTAssertEqual(file.task("ball_tracks:a")?.state, .blocked)
        XCTAssertTrue(file.task("ball_tracks:a")?.reason?.contains("no longer") ?? false)
        XCTAssertEqual(file.task("net_corners:a")?.state, .cancelled, "cancelled stays cancelled")
        // No net inventory: net tasks untouched, the reason reported.
        let in3 = inputs(sessions: [session("w")], withheld: ["w"], net: nil, netProblem: "stale")
        let third = WorkQueueReconciler.apply(in3, to: &file)
        XCTAssertEqual(third.skipped[.netCorners], "stale")
    }

    // MARK: - On a project folder

    func testRunOnAProjectFolderFailsClosedAndWritesWhenReadable() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let project = Project(name: "Fixture", createdAt: now, framesPerRally: 2, clips: [
            SourceRegistryTests.clip("a", number: 1, videos: [SourceRegistryTests.video(nil, fingerprint: "file:aaa")]),
            SourceRegistryTests.clip("w", number: 2, videos: [SourceRegistryTests.video(nil, fingerprint: "file:www")]),
        ])
        try encoder.encode(project).write(to: root.appendingPathComponent("project.json"))
        let store = DatasetStore(root: root)
        try store.save(session("a", marked: true, tracks: [SourceRegistryTests.rally(done: true)]))
        try store.save(session("w"))
        try #"{"tune":[],"holdout":["w"]}"#.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
        // No split manifest: the net inventory can't be read, so net tasks are skipped and said so; the rest is written.
        let (file, summary) = try WorkQueueReconciler.run(root: root, project: "Fixture", now: now)
        XCTAssertEqual(summary.skipped.keys.map(\.rawValue), ["net_corners"])
        XCTAssertEqual(file.tasks.count, 4)
        XCTAssertEqual(file.task("rally_boundaries:a")?.state, .complete, "complete by declaration")
        XCTAssertEqual(file.task("rally_boundaries:a")?.observed?.declaredComplete, true)
        XCTAssertNil(file.task("rally_boundaries:a")?.observed?.verifiedCoverage)
        XCTAssertEqual(file.task("ball_tracks:a")?.state, .inProgress)
        XCTAssertEqual(file.task("ball_tracks:a")?.identityKey, "fp:file:aaa")
        XCTAssertEqual(file.task("rally_boundaries:w")?.state, .blocked, "the legacy holdout is withheld (D-017)")
        XCTAssertEqual(try WorkQueue.Store(root: root).load(), file)
        // A Stage 1 record completes the task on the next run; the legacy file is untouched by it.
        var record = EventReview.File(video: "a", sourceFingerprint: nil, frameRate: 30, durationSec: 300, tool: "test")
        EventReview.Mutation.markReviewed(from: 0, to: 300, in: &record, at: now, annotator: "BW")
        try EventReview.Mutation.complete(&record, at: now, annotator: "BW", tool: "test")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        try EventReview.write(record, to: EventReview.url(forVideo: root.appendingPathComponent("footage/a.mp4")))
        let (again, _) = try WorkQueueReconciler.run(root: root, project: "Fixture", now: now.addingTimeInterval(60))
        XCTAssertEqual(again.task("rally_boundaries:a")?.state, .complete)
        XCTAssertEqual(again.task("rally_boundaries:a")?.observed?.verifiedCoverage, 1)
        // An unreadable validation.json: the withheld closure is unknown, nothing is reconciled, the file is unchanged.
        let before = try Data(contentsOf: WorkQueue.url(in: root))
        try #"{"tune":[],"holdout":["w"]"#.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkQueueReconciler.run(root: root, project: "Fixture", now: now))
        XCTAssertEqual(try Data(contentsOf: WorkQueue.url(in: root)), before)
        // An unreadable queue: refused, never overwritten.
        try #"{"tune":[],"holdout":["w"]}"#.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
        try "{broken".write(to: WorkQueue.url(in: root), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try WorkQueueReconciler.run(root: root, project: "Fixture", now: now))
        XCTAssertEqual(try String(contentsOf: WorkQueue.url(in: root), encoding: .utf8), "{broken")
    }

    func testNetObservationsFromAProjectWithAManifest() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let project = Project(name: "Fixture", createdAt: now, framesPerRally: 2, clips: [
            SourceRegistryTests.clip("a", number: 1, videos: [SourceRegistryTests.video(nil, fingerprint: "file:aaa")]),
            SourceRegistryTests.clip("h", number: 2, camera: "Handheld / corner", videos: [SourceRegistryTests.video(nil, fingerprint: "file:hhh")]),
            SourceRegistryTests.clip("u", number: 3, videos: [SourceRegistryTests.video(nil, fingerprint: nil)]),
        ])
        let projectURL = root.appendingPathComponent("project.json")
        try encoder.encode(project).write(to: projectURL)
        let store = DatasetStore(root: root)
        for n in ["a", "h", "u"] { try store.save(session(n)) }
        let sessions = try store.loadSessionsStrict()
        let manifest = try DatasetSplitManifest.build(.init(
            project: project, sessions: sessions, validation: nil, fingerprint: { $0.fingerprint }, previous: nil, discovered: [:],
            hashes: .init(projectJson: DatasetSplitManifest.sha256(of: projectURL), sessions: nil, validationJson: nil), generator: "test", now: now))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifests"), withIntermediateDirectories: true)
        try manifest.write(to: NetInventory.manifestURL(in: root))
        let label = NetLabel(time: 10, box: TrackCandidate(rect: CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.2), confidence: 1),
                             corners: NetQuad(rect: CGRect(x: 0.2, y: 0.3, width: 0.5, height: 0.2)), proposed: false, adjusted: true,
                             reviewedAt: now, frameWidth: 1920, frameHeight: 1080, fingerprint: "file:aaa")
        try NetLabelStore(projectDir: root).save(["a": label])
        let net = try WorkQueueReconciler.netObservations(root: root)
        XCTAssertEqual(net["a"]?.status.labeled, true)
        XCTAssertEqual(net["h"]?.skip, .handheld)
        XCTAssertEqual(net["u"]?.skip, .unidentified)
        // A label for another file under the same id is stale, not a label.
        try NetLabelStore(projectDir: root).save(["a": { var l = label; l.fingerprint = "file:other"; return l }()])
        XCTAssertEqual(try WorkQueueReconciler.netObservations(root: root)["a"]?.status.stale, true)
    }
}
