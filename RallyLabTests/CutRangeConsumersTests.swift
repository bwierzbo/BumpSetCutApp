//
//  CutRangeConsumersTests.swift
//  RallyLabTests
//
//  Every consumer of a recording's time honours its cut ranges (D-030): the
//  tuner's score and the retune's accounting take truth and clips outside
//  them (a replay the pipeline cut is neither dead time nor a false clip,
//  a rally inside one is not a rally to find), the rally-cut tally sees the
//  masked lists, the Sampler plans no frame inside one, the net frame is
//  taken outside them, a test-set window with a frame inside one is left
//  out, the pre-tracker opens no span over one, the training-data export
//  drops the frames inside them and finds a video's cuts by its session.
//

import XCTest
@testable import RallyLab

final class CutRangeConsumersTests: XCTestCase {

    private func iv(_ s: Double, _ e: Double) -> Interval { Interval(start: s, end: e) }
    private func cut(_ s: Double, _ e: Double) -> CutRange { CutRange(start: s, end: e) }

    // MARK: - Scores

    func testTunerScoreCountsNothingInsideACut() {
        // Truth: a rally at 10–20, a replay of it the uploader cut in at 30–40 (not marked), a rally at 50–60.
        // The pipeline cut 9–21, 30–40 (the replay) and 49–61; a false clip at 70–72.
        let truth = [iv(10, 20), iv(50, 60)]
        let clips = [iv(9, 21), iv(30, 40), iv(49, 61), iv(70, 72)]
        var plain = PipelineTuner.Score()
        plain.add(clips: clips, truth: truth)
        XCTAssertEqual(plain.falseClips, 2); XCTAssertEqual(plain.deadTime, 16, accuracy: 1e-9)

        var masked = PipelineTuner.Score()
        masked.add(clips: clips, truth: truth, cuts: [cut(28, 42)])
        XCTAssertEqual(masked.rallies, 2); XCTAssertEqual(masked.covered, 20, accuracy: 1e-9)
        XCTAssertEqual(masked.falseClips, 1, "the replay clip is gone; the 70–72 clip stays")
        XCTAssertEqual(masked.deadTime, 6, accuracy: 1e-9, "1 + 1 + 1 + 1 + 2: the replay's 10 s are not dead time")

        // A rally whose serve the clip missed (the recording starts mid-rally, cut 0–12): not a rally to find.
        var start = PipelineTuner.Score()
        start.add(clips: [iv(0, 25)], truth: [iv(5, 20), iv(30, 40)], cuts: [cut(0, 12)])
        XCTAssertEqual(start.rallies, 2, "the piece 12–20 of the first rally is still footage")
        XCTAssertEqual(start.covered, 8, accuracy: 1e-9); XCTAssertEqual(start.missed, 1)
        XCTAssertEqual(start.deadTime, 5, accuracy: 1e-9, "20–25; 0–12 is not footage")
    }

    func testRallyCutTallySeesTheMaskedLists() {
        let cuts = [cut(28, 42)]
        var t = RallyCutScore.Tally()
        t.add(clips: [iv(9, 21), iv(30, 40), iv(49, 61)].outside(cuts), truth: [iv(10, 20), iv(50, 60)].outside(cuts))
        XCTAssertEqual(t.truth, 2); XCTAssertEqual(t.found, 2); XCTAssertEqual(t.falseClips, 0); XCTAssertEqual(t.clips, 2)
    }

    func testRetuneAccountingKeepsEachMarksKindThroughTheMask() {
        // Three marks: a rally, a missed serve inside the cut (gone), a rally the cut takes the start of.
        let truth = [iv(10, 20), iv(30, 33), iv(38, 48)]
        let kinds: [RallyKind?] = [.rally, .missedServe, .rally]
        let a = DeciderRetune.account(clips: [iv(9, 21), iv(29, 34), iv(41, 49)], raw: [iv(10, 20)], truth: truth, kinds: kinds,
                                      preservedShare: 0.95, cuts: [cut(28, 42)])
        XCTAssertEqual(a.rallies, 2)
        XCTAssertEqual(a.missedServeMarks, 0, "the missed-serve mark lay inside the cut")
        XCTAssertEqual(a.rallyTime, 16, accuracy: 1e-9, "10 + the piece 42–48")
        XCTAssertEqual(a.clips, 2); XCTAssertEqual(a.falseClips, 0)
        XCTAssertEqual(a.deadTime, 3, accuracy: 1e-9, "1 + 1 around the first rally, 1 after the second")
        // With the mark's kind on the surviving piece: a missed-serve mark at 38–48 would still count.
        let b = DeciderRetune.account(clips: [], raw: [], truth: truth, kinds: [.rally, .rally, .missedServe], preservedShare: 0.95, cuts: [cut(28, 42)])
        XCTAssertEqual(b.missedServeMarks, 1); XCTAssertEqual(b.missedServeMarksMissed, 1)
    }

    // MARK: - Sampling, net frame, test set

    func testSamplerPlansNoFrameInsideACut() {
        let plan = SamplerModel.plan(rallies: [iv(10, 20)], evidence: [], duration: 100, burstFPS: 2, padding: 0,
                                     includeMissed: false, maxMissed: 0, randomCount: 20, cuts: [cut(14, 17), cut(50, 60)])
        XCTAssertFalse(plan.isEmpty)
        XCTAssertFalse(plan.contains { (14..<17).contains($0.time) || (50..<60).contains($0.time) })
        XCTAssertTrue(plan.contains { $0.time == 10 } && plan.contains { $0.time == 20 })
        let unmasked = SamplerModel.plan(rallies: [iv(10, 20)], evidence: [], duration: 100, burstFPS: 2, padding: 0,
                                         includeMissed: false, maxMissed: 0, randomCount: 0)
        XCTAssertEqual(unmasked.filter { $0.source != .random }.count, 21)
    }

    func testNetFrameComesFromOutsideTheCuts() {
        let rallies = [(start: 5.0, end: 9.0), (start: 20.0, end: 30.0)]
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: rallies), 7)
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: rallies, cuts: [cut(0, 10)]), 25, "the first rally touches the cut")
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: [], cuts: [cut(0, 10), cut(40, 100)]), 25, "the middle of the longest uncut stretch")
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: [], cuts: []), 50)
    }

    func testTestSetJobsLeaveOutAWindowWithAFrameInsideACut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func window(_ clip: String, _ time: Double, _ keys: [Int]) -> String {
            "{\"clip\":\"\(clip)\",\"split\":\"val\",\"time\":\(time),\"size\":[960,540],\"frames\":[\(keys.map { "\"frames/\(clip)/\($0).jpg\"" }.joined(separator: ","))],\"target\":1,\"balls\":[[0.5,0.5,0.02,0.03]]}"
        }
        let lines = [window("a", 1.0, [966_667, 1_000_000, 1_033_333]), window("a", 5.0, [4_966_667, 5_000_000, 5_033_333]),
                     window("b", 1.0, [966_667, 1_000_000, 1_033_333])]
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("windows.jsonl"), atomically: true, encoding: .utf8)
        let plain = try TestSetScore.jobs(export: dir)
        XCTAssertEqual(plain.jobs.count, 3); XCTAssertEqual(plain.insideCuts, 0)
        let masked = try TestSetScore.jobs(export: dir, cuts: ["a": [cut(4.5, 6)]])
        XCTAssertEqual(masked.insideCuts, 1)
        XCTAssertEqual(masked.jobs.map { "\($0.clip)@\($0.time)" }, ["a@1.0", "b@1.0"])
        // The last frame alone inside the cut is enough.
        XCTAssertEqual(try TestSetScore.jobs(export: dir, cuts: ["a": [cut(1.02, 2)]]).insideCuts, 1)
        XCTAssertEqual(try XCTUnwrap(TestSetScore.seconds(ofFrame: "frames/a/1033333.jpg")), 1.033333, accuracy: 1e-9)
    }

    // MARK: - Pre-tracking and the training-data export

    @MainActor
    func testPreTrackerOpensNoSpanOverACut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("v.mp4")
        try "[{\"startTime\": 10, \"endTime\": 20}, {\"startTime\": 30, \"endTime\": 40}]"
            .write(to: RallyMarkModel.labelsURL(for: video), atomically: true, encoding: .utf8)
        // A found rally the Sampler took burst frames from at 50–55.
        let burst = [50.0, 52.5, 55.0].map { FrameRecord(id: UUID(), file: "images/train/v_\($0).jpg", time: $0, source: "rally:0", boxes: [], keep: true, reviewed: false) }
        var session = VideoSession(name: "v", sourcePath: video.path, split: "train", addedAt: Date(), frames: burst)
        XCTAssertEqual(PreTracker.openSpans(session, tracks: []).map(\.start), [10, 30, 50])
        session.cuts = [cut(35, 52)]
        XCTAssertEqual(PreTracker.openSpans(session, tracks: []).map(\.start), [10], "the second mark and the found rally touch the cut")
    }

    func testTrainingDataExportDropsTheFramesInsideCutsAndFindsAVideosCutsByItsSession() throws {
        func frame(_ t: Double) -> VideoProcessor.FrameEvidence {
            VideoProcessor.FrameEvidence(time: t, hasBall: true, isProjectile: true, detections: [], trackPoint: CGPoint(x: 0.5, y: 0.5),
                                         rSquared: nil, gravitySignature: nil, movementType: nil, rejectionReason: nil, candidates: [], detectedNet: nil)
        }
        let export = TrainingDataExporter.makeExport(videoName: "v.mp4", duration: 100, evidence: stride(from: 0.0, to: 100, by: 1).map(frame),
                                                     labels: [iv(10, 20), iv(30, 40)], baselineRaw: [iv(9, 21), iv(31, 39)], cuts: [cut(15, 35)])
        XCTAssertEqual(export.frames.count, 80)
        XCTAssertFalse(export.frames.contains { (15..<35).contains($0.t) })
        XCTAssertEqual(export.labels.map { [$0.start, $0.end] }, [[10, 15], [35, 40]])
        XCTAssertEqual(export.baselineRaw.map { [$0.start, $0.end] }, [[9, 15], [35, 39]])
        XCTAssertEqual(export.cuts.map { [$0.start, $0.end] }, [[15, 35]], "the trainer masks its own decisions with them")

        // The headless export walks a folder of videos; a video's cuts come from the project session over it.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        let project = root.appendingPathComponent("P", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("footage/v.mp4")
        var session = VideoSession(name: "v", sourcePath: video.path, split: "train", addedAt: Date(), frames: [])
        session.cuts = [cut(1, 2)]
        try DatasetStore(root: project).save(session)
        XCTAssertEqual(TrainingDataExporter.cutRanges(forVideo: video, projectsRoot: root), [cut(1, 2)])
        XCTAssertEqual(TrainingDataExporter.cutRanges(forVideo: root.appendingPathComponent("footage/other.mp4"), projectsRoot: root), [])
    }
}
