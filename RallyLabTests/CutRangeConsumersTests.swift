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
        // A missed serve at 33–35 inside a false clip 30–40: the clip stays one false clip, its 2 s inside are not dead time;
        // a clip wholly inside a missed serve is neither.
        var excluded = PipelineTuner.Score()
        excluded.add(clips: [iv(9, 21), iv(30, 40), iv(50, 52)], truth: [iv(10, 20)], excluded: [iv(33, 35), iv(50, 52)])
        XCTAssertEqual(excluded.falseClips, 1); XCTAssertEqual(excluded.deadTime, 10, accuracy: 1e-9, "1 + 1 around the rally, 8 of the clip 30–40")

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
        // A missed serve is an excluded span: the clip inside it is unscored, not a false clip; one straddling it is
        // scored on its piece outside; the rally count never includes it.
        var e = RallyCutScore.Tally()
        e.add(clips: [iv(9, 21), iv(30, 33), iv(70, 76)], truth: [iv(10, 20)], excluded: [iv(30, 33), iv(72, 74)])
        XCTAssertEqual(e.truth, 1); XCTAssertEqual(e.found, 1)
        XCTAssertEqual(e.unscored, 1); XCTAssertEqual(e.clips, 2, "the found clip and the clip over the missed serve at 72–74 — one clip, two pieces")
        XCTAssertEqual(e.falseClips, 1, "the clip 70–76 is one false clip; the clip inside the missed serve is neither hit nor false")
        XCTAssertTrue(e.line.contains("1 unscored"))
        // Contract fixture 21: one prediction runs through the rally 10–29, a missed serve 30–31 and dead time to 40;
        // matched on its two pieces (IoU 19/29), end error +11 from the scorable span's end.
        var f = RallyCutScore.Tally()
        f.add(clips: [iv(10, 40)], truth: [iv(10, 29)], excluded: [iv(30, 31)], iou: 0.5)
        XCTAssertEqual(f.found, 1); XCTAssertEqual(f.falseClips, 0); XCTAssertEqual(f.merged, 0); XCTAssertEqual(f.split, 0)
        XCTAssertEqual(f.startErrors, [0]); XCTAssertEqual(f.endErrors, [11])
        // Contract fixture 14: a prediction over a marked non-rally 60–62 and ordinary dead time: one false clip.
        var g = RallyCutScore.Tally()
        g.add(clips: [iv(10, 14), iv(58, 66)], truth: [iv(10, 14)], excluded: [iv(60, 62)], iou: 0.5)
        XCTAssertEqual(g.found, 1); XCTAssertEqual(g.falseClips, 1); XCTAssertEqual(g.clips, 2); XCTAssertEqual(g.unscored, 0)
        // The matcher itself: the pieces, the span, and a clip wholly inside an excluded span left out.
        let (scored, unscored) = [iv(10, 40), iv(30, 31)].scorable(excluding: [iv(30, 31)])
        XCTAssertEqual(unscored, 1); XCTAssertEqual(scored.map(\.pieces), [[iv(10, 30), iv(31, 40)]])
        XCTAssertEqual(scored[0].span, iv(10, 40)); XCTAssertEqual(scored[0].seconds, 29); XCTAssertEqual(scored[0].iou(iv(10, 29)), 19.0 / 29, accuracy: 1e-9)
    }

    func testRetuneAccountingMasksTheExcludedSpansThroughTheCuts() {
        // Three marks: a rally, a missed serve inside the cut (gone with it), a rally the cut takes the start of.
        let truth = [iv(10, 20), iv(38, 48)]
        let a = DeciderRetune.account(clips: [iv(9, 21), iv(29, 34), iv(41, 49)], raw: [iv(10, 20)], truth: truth, excluded: [iv(30, 33)],
                                      preservedShare: 0.95, cuts: [cut(28, 42)])
        XCTAssertEqual(a.rallies, 2)
        XCTAssertEqual(a.excludedSpans, 0, "the missed-serve mark lay inside the cut")
        XCTAssertEqual(a.rallyTime, 16, accuracy: 1e-9, "10 + the piece 42–48")
        XCTAssertEqual(a.clips, 2); XCTAssertEqual(a.falseClips, 0)
        XCTAssertEqual(a.unscoredClips, 0, "the clip inside the cut is gone with the cut (not footage), not unscored")
        XCTAssertEqual(a.deadTime, 3, accuracy: 1e-9, "1 + 1 around the first rally, 1 after the second")
        // A missed serve the cut only brushes keeps its piece outside, and masks the clip there like the cut does.
        let b = DeciderRetune.account(clips: [iv(42, 46), iv(50, 52)], raw: [], truth: truth, excluded: [iv(40, 45)], preservedShare: 0.95, cuts: [cut(28, 42)])
        XCTAssertEqual(b.excludedSpans, 1)
        XCTAssertEqual(b.rallyTime, 13, accuracy: 1e-9, "10 + the piece 45–48 of the second rally")
        XCTAssertEqual(b.clips, 2, "the clip on its piece 45–46 and the clip at 50–52"); XCTAssertEqual(b.unscoredClips, 0)
        // An excluded span inside a clip never splits it (unlike a cut): one clip, matched on its pieces, one false clip.
        let c = DeciderRetune.account(clips: [iv(10, 40), iv(70, 76)], raw: [iv(10, 40)], truth: [iv(10, 29)], excluded: [iv(30, 31), iv(72, 74)], preservedShare: 0.95)
        XCTAssertEqual(c.clips, 2); XCTAssertEqual(c.falseClips, 1); XCTAssertEqual(c.unscoredClips, 0)
        XCTAssertEqual(c.preserved, 1); XCTAssertEqual(c.endErrors, [11]); XCTAssertEqual(c.rawEndErrors, [11])
        XCTAssertEqual(c.deadTime, 14, accuracy: 1e-9, "10 of 10–40 outside the rally and the missed serve, 4 of 70–76")
    }

    // MARK: - Sampling, net frame, test set

    func testSamplerPlansNoFrameInsideACut() {
        // The burst alone (no random frames, which can land next to a burst frame and merge with it).
        let burst = SamplerModel.plan(rallies: [iv(10, 20)], evidence: [], duration: 100, burstFPS: 2, padding: 0,
                                      includeMissed: false, maxMissed: 0, randomCount: 0, cuts: [cut(14, 17)])
        XCTAssertEqual(burst.map(\.time), [10, 10.5, 11, 11.5, 12, 12.5, 13, 13.5, 17, 17.5, 18, 18.5, 19, 19.5, 20], "14–16.5 are inside the cut")
        let unmasked = SamplerModel.plan(rallies: [iv(10, 20)], evidence: [], duration: 100, burstFPS: 2, padding: 0,
                                         includeMissed: false, maxMissed: 0, randomCount: 0)
        XCTAssertEqual(unmasked.count, 21)
        // With random frames too: still none inside a cut.
        let plan = SamplerModel.plan(rallies: [iv(10, 20)], evidence: [], duration: 100, burstFPS: 2, padding: 0,
                                     includeMissed: false, maxMissed: 0, randomCount: 20, cuts: [cut(14, 17), cut(50, 60)])
        XCTAssertFalse(plan.isEmpty)
        XCTAssertFalse(plan.contains { (14..<17).contains($0.time) || (50..<60).contains($0.time) })
    }

    func testNetFrameComesFromOutsideTheCuts() {
        let rallies = [(start: 5.0, end: 9.0), (start: 20.0, end: 30.0)]
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: rallies), 7)
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: rallies, cuts: [cut(0, 10)]), 25, "the first rally touches the cut")
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: [], cuts: [cut(0, 10), cut(40, 100)]), 25, "the middle of the longest uncut stretch")
        XCTAssertEqual(NetLabels.frameTime(duration: 100, rallies: [], cuts: []), 50)
        XCTAssertNil(NetLabels.frameTime(duration: 100, rallies: [(start: 5.0, end: 9.0)], cuts: [cut(0, 100)]), "cut whole: no frame to take")
        XCTAssertNil(NetLabels.frameTime(duration: 100, rallies: [], cuts: [cut(0, 60), cut(60, 120)]))
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
        let plain = try TestSetScore.jobs(export: dir, cuts: ["a": [], "b": []])
        XCTAssertEqual(plain.jobs.count, 3); XCTAssertEqual(plain.insideCuts, 0)
        let masked = try TestSetScore.jobs(export: dir, cuts: ["a": [cut(4.5, 6)], "b": []])
        XCTAssertEqual(masked.insideCuts, 1)
        XCTAssertEqual(masked.jobs.map { "\($0.clip)@\($0.time)" }, ["a@1.0", "b@1.0"])
        // The last frame alone inside the cut is enough.
        XCTAssertEqual(try TestSetScore.jobs(export: dir, cuts: ["a": [cut(1.02, 2)], "b": []]).insideCuts, 1)
        // A val clip with no session over it (no entry): unknown cuts, not none — the export is not scored.
        XCTAssertThrowsError(try TestSetScore.jobs(export: dir, cuts: ["a": [cut(1.02, 2)]])) {
            XCTAssertEqual($0 as? TestSetScore.ClipSessionUnavailable, TestSetScore.ClipSessionUnavailable(clip: "b"))
        }
        XCTAssertEqual(try XCTUnwrap(TestSetScore.seconds(ofFrame: "frames/a/1033333.jpg")), 1.033333, accuracy: 1e-9)

        // The cache key names the model's actual input: the same labelled frame scored in another window — a cut
        // took the window it used to sit in, so a neighbouring one was chosen — is another job set, not a hit.
        // Two windows label the same two frames (1.0 s and 1.033 s); each frame's job takes the window it sits most
        // centrally in: 1.0 s from the first, 1.033 s from the second. A cut over the first window's first frame
        // leaves both frames to the second window.
        func labelled(_ time: Double, _ keys: [Int], _ labels: String) -> String {
            "{\"clip\":\"a\",\"split\":\"val\",\"time\":\(time),\"size\":[960,540],\"frames\":[\(keys.map { "\"frames/a/\($0).jpg\"" }.joined(separator: ","))],\"target\":1,\"labels\":\(labels)}"
        }
        let ball = "[[0.5,0.5,0.02,0.03]]"
        let overlapping = [labelled(1.0, [966_667, 1_000_000, 1_033_333], "[null,\(ball),\(ball)]"),
                           labelled(1.033333, [1_000_000, 1_033_333, 1_066_667], "[\(ball),\(ball),null]")]
        try (overlapping.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("windows.jsonl"), atomically: true, encoding: .utf8)
        let first = try TestSetScore.jobs(export: dir, cuts: ["a": []]).jobs
        let second = try TestSetScore.jobs(export: dir, cuts: ["a": [cut(0.95, 0.98)]]).jobs
        XCTAssertEqual(first.map { $0.frames.first! }, ["frames/a/966667.jpg", "frames/a/1000000.jpg"])
        XCTAssertEqual(second.map { $0.frames.first! }, ["frames/a/1000000.jpg", "frames/a/1000000.jpg"])
        XCTAssertEqual(Set(first.map { $0.frames[$0.index] }), Set(second.map { $0.frames[$0.index] }), "the same target frames…")
        XCTAssertNotEqual(TestSetScore.jobsKey(first, export: dir), TestSetScore.jobsKey(second, export: dir), "…in other windows: another key")
        XCTAssertEqual(TestSetScore.jobsKey(first, export: dir), TestSetScore.jobsKey(first.reversed(), export: dir), "order does not matter")
        XCTAssertNotEqual(TestSetScore.jobsKey(first, export: dir), TestSetScore.jobsKey(first, export: dir.appendingPathComponent("other")), "the export does")
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
        // The quota: a machine track inside a cut no longer counts (it stays, for undo), nor one said not to be a rally.
        func machine(_ a: Double, _ b: Double, isRally: Bool? = nil) -> TrackedRally {
            var t = SourceRegistryTests.rally(done: true, machine: true, isRally: isRally); t.start = a; t.end = b; return t
        }
        let tracks = [machine(10, 20), machine(30, 40), machine(70, 80, isRally: false)]
        XCTAssertEqual(PreTracker.wanted(perVideo: 2, tracks: tracks, cuts: []), 0)
        XCTAssertEqual(PreTracker.wanted(perVideo: 2, tracks: tracks, cuts: [cut(35, 52)]), 1, "the 30–40 track touches the cut: one place free")
        XCTAssertEqual(PreTracker.wanted(perVideo: 3, tracks: tracks, cuts: [cut(0, 100)]), 3)
    }

    /// A recording cut whole leaves nothing to sample: the ingest ends with an empty session that keeps the cuts
    /// (a re-pull has already deleted the old one), not a failed job; with no cuts an empty plan is a failure as before.
    func testARecordingCutWholeKeepsItsCutsOnAnEmptySession() throws {
        XCTAssertFalse(try SamplerModel.samples([], cuts: [cut(0, 300)]), "an empty session, the cuts kept")
        XCTAssertThrowsError(try SamplerModel.samples([], cuts: []))
        let planned = SamplerModel.plan(rallies: [iv(10, 20)], evidence: [], duration: 100, burstFPS: 2, padding: 0,
                                        includeMissed: false, maxMissed: 0, randomCount: 0, cuts: [cut(0, 50)])
        XCTAssertTrue(planned.isEmpty)
        XCTAssertFalse(try SamplerModel.samples(planned, cuts: [cut(0, 50)]))
        XCTAssertTrue(try SamplerModel.samples(SamplerModel.plan(rallies: [iv(10, 20)], evidence: [], duration: 100, burstFPS: 2, padding: 0,
                                                                 includeMissed: false, maxMissed: 0, randomCount: 0, cuts: []), cuts: []))
    }

    /// The Label tab's queue offers no rally touching a cut as a task — not a marked or found one, not one whose
    /// track was begun — while the marks and tracks stay as they are.
    @MainActor
    func testMacQueueOffersNoRallyTouchingACut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("v.mp4")
        try "[{\"startTime\": 10, \"endTime\": 20}, {\"startTime\": 30, \"endTime\": 40}]"
            .write(to: RallyMarkModel.labelsURL(for: video), atomically: true, encoding: .utf8)
        let burst = [50.0, 52.5, 55.0].map { FrameRecord(id: UUID(), file: "images/train/v_\($0).jpg", time: $0, source: "rally:0", boxes: [], keep: true, reviewed: false) }
        var session = VideoSession(name: "v", sourcePath: video.path, split: "train", addedAt: Date(), frames: burst)
        // A track begun on the 30–40 rally and not finished.
        var begun = SourceRegistryTests.rally(done: false)
        begun.start = 30; begun.end = 40
        session.tracks = [begun]
        XCTAssertEqual(LabelQueue.Video(session: session).nextRally, begun.bounds, "the begun track first")
        session.cuts = [cut(35, 52)]
        let queued = LabelQueue.Video(session: session)
        XCTAssertEqual(queued.nextRally?.start, 10, "the begun track and the found rally touch the cut; the 10–20 rally is the task")
        XCTAssertEqual(session.tracks?.count, 1, "the track itself stays")
        session.cuts = [cut(0, 60)]
        XCTAssertNil(LabelQueue.Video(session: session).nextRally)
    }

    /// A project this Mac remembers that is not there is unknown cuts: the headless lookup throws and the export
    /// stops, instead of finding no project and exporting the cut footage.
    func testHeadlessCutLookupFailsClosedWhenARememberedProjectIsGone() throws {
        let suite = "RallyLabTests.CutRangeConsumers.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("gone-\(UUID().uuidString)", isDirectory: true)
        defaults.set([gone.path], forKey: "RallyLab.projects")
        XCTAssertThrowsError(try ProjectsModel.savedProjectRoots(defaults: defaults)) {
            XCTAssertEqual($0 as? ProjectsModel.ProjectUnavailable, ProjectsModel.ProjectUnavailable(path: gone.standardizedFileURL.path))
        }
        // A remembered project that is there is listed; the last opened too.
        let here = FileManager.default.temporaryDirectory.appendingPathComponent("here-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: here, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: here) }
        try "{}".write(to: here.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        defaults.set([here.path], forKey: "RallyLab.projects")
        defaults.set(here.path, forKey: "RallyLab.lastProjectPath")
        XCTAssertEqual(try ProjectsModel.savedProjectRoots(defaults: defaults).filter { $0.standardizedFileURL == here.standardizedFileURL }.count, 1)
        defaults.set(gone.path, forKey: "RallyLab.lastProjectPath")
        XCTAssertThrowsError(try ProjectsModel.savedProjectRoots(defaults: defaults), "the last project opened is remembered too")
    }

    /// The Pipeline tab's decision: outside the cut ranges, and withheld — no predictions, no score — while they
    /// can't be known (a session that won't read), never made as if there were none.
    func testPipelineTabDecidesNothingWhileTheCutRangesCannotBeKnown() {
        func frame(_ t: Double, ball: Bool) -> VideoProcessor.FrameEvidence {
            VideoProcessor.FrameEvidence(time: t, hasBall: ball, isProjectile: ball, detections: [], trackPoint: ball ? CGPoint(x: 0.5, y: 0.5) : nil,
                                         rSquared: nil, gravitySignature: nil, movementType: nil, rejectionReason: nil, candidates: [], detectedNet: nil)
        }
        let evidence = stride(from: 0.0, to: 60, by: 1 / 30).map { frame($0, ball: ($0 >= 10 && $0 < 20) || ($0 >= 30 && $0 < 40)) }
        let known = RallyLabModel.decide(evidence: evidence, duration: 60, config: ProcessorConfig(), minRallySec: 1, cuts: [cut(28, 42)], cutsProblem: nil)
        XCTAssertNotNil(known)
        XCTAssertFalse(known!.raw.contains { $0.end > 28 && $0.start < 42 }, "nothing decided inside the cut: \(known!.raw)")
        XCTAssertFalse(known!.padded.contains { $0.end > 28 && $0.start < 42 })
        XCTAssertNil(RallyLabModel.decide(evidence: evidence, duration: 60, config: ProcessorConfig(), minRallySec: 1, cuts: [], cutsProblem: "session unreadable"),
                     "the cuts unknown: no decision, not one as if there were none")
    }

    /// The one rule for which rallies there is footage to track or ask about — the Mac's pre-tracker and the
    /// phone's task selectors (LabelerModel.openFound / untrackedRallies) both read it: a rally that touches a cut
    /// is left out, one that ends where a cut starts is not touching it.
    func testRalliesTouchingACutAreNotTasks() {
        let rallies = [LabelRally(start: 10, end: 20), LabelRally(start: 30, end: 40), LabelRally(start: 50, end: 55), LabelRally(start: 60, end: 70)]
        XCTAssertEqual(rallies.outsideCuts([]), rallies)
        XCTAssertEqual(rallies.outsideCuts([cut(35, 52)]).map(\.start), [10, 60], "both that overlap it go")
        XCTAssertEqual(rallies.outsideCuts([cut(20, 30)]).map(\.start), [10, 30, 50, 60], "touching at a point is not overlapping")
        XCTAssertEqual(rallies.outsideCuts([cut(0, 100)]), [])
    }

    func testTrainingDataExportDropsTheFramesInsideCutsAndFindsAVideosCutsByItsSession() throws {
        func frame(_ t: Double, net: CGFloat? = nil) -> VideoProcessor.FrameEvidence {
            VideoProcessor.FrameEvidence(time: t, hasBall: true, isProjectile: true, detections: [], trackPoint: CGPoint(x: 0.5, y: 0.5),
                                         rSquared: nil, gravitySignature: nil, movementType: nil, rejectionReason: nil, candidates: [],
                                         detectedNet: net.map { DetectedNet(box: CGRect(x: 0.1, y: $0, width: 0.8, height: 0.1), confidence: 0.9) })
        }
        func truth(_ marks: [(Double, Double, RallyKind?)], cuts: [CutRange] = []) -> RallyTruth {
            RallyTruth(marks: marks.map { RallyTruth.Mark(start: $0.0, end: $0.1, kind: $0.2) }, cuts: cuts, complete: true)
        }
        // The net too comes from footage: a replay inside a leading cut, shot from another view, found the net elsewhere.
        let viewed = TrainingDataExporter.makeExport(videoName: "v.mp4", duration: 100,
                                                     evidence: [frame(1, net: 0.8), frame(2, net: 0.8), frame(20, net: 0.4), frame(21, net: 0.4)],
                                                     truth: truth([], cuts: [cut(0, 10)]), baselineRaw: [])
        XCTAssertEqual(viewed.netTopY ?? -1, 0.5, accuracy: 1e-9, "the net of the first retained frame, not the replay's")
        XCTAssertEqual(viewed.netBottomY ?? -1, 0.4, accuracy: 1e-9)
        XCTAssertEqual(viewed.frames.map(\.t), [20, 21])
        XCTAssertEqual(viewed.schema, 2); XCTAssertTrue(viewed.complete)
        // Schema 2: the rallies by kind in `labels`, the missed serves and other marks in `excluded` (frames kept, for the
        // trainer to mask), a legacy mark with no kind a rally.
        let export = TrainingDataExporter.makeExport(videoName: "v.mp4", duration: 100, evidence: stride(from: 0.0, to: 100, by: 1).map { frame($0) },
                                                     truth: truth([(10, 20, .rally), (30, 40, nil), (50, 53, .missedServe), (60, 62, .other)], cuts: [cut(15, 35)]),
                                                     baselineRaw: [iv(9, 21), iv(31, 39), iv(50, 53)])
        XCTAssertEqual(export.frames.count, 80)
        XCTAssertFalse(export.frames.contains { (15..<35).contains($0.t) })
        XCTAssertTrue(export.frames.contains { $0.t == 51 }, "the frames of an excluded span stay: the trainer masks them")
        XCTAssertEqual(export.labels.map { [$0.start, $0.end] }, [[10, 15], [35, 40]])
        XCTAssertEqual(export.excluded.map { [$0.start, $0.end] }, [[50, 53], [60, 62]])
        XCTAssertEqual(export.baselineRaw.map { [$0.start, $0.end] }, [[9, 15], [35, 39], [50, 53]], "the baseline is masked by the cuts only; the trainer masks the excluded spans")
        XCTAssertEqual(export.cuts.map { [$0.start, $0.end] }, [[15, 35]], "the trainer masks its own decisions with them")
        let whole = TrainingDataExporter.makeExport(videoName: "v.mp4", duration: 100, evidence: stride(from: 0.0, to: 100, by: 1).map { frame($0) },
                                                    truth: truth([(10, 20, .rally)], cuts: [cut(0, 100)]), baselineRaw: [iv(9, 21)])
        XCTAssertTrue(whole.frames.isEmpty && whole.labels.isEmpty && whole.baselineRaw.isEmpty, "a recording cut whole: nothing to train on")
        // A complete pass with no rally: a negative-only export, every frame outside the cuts not-rally time.
        let none = TrainingDataExporter.makeExport(videoName: "v.mp4", duration: 100, evidence: stride(from: 0.0, to: 100, by: 1).map { frame($0) },
                                                   truth: truth([(40, 42, .missedServe)]), baselineRaw: [])
        XCTAssertEqual(none.frames.count, 100); XCTAssertTrue(none.labels.isEmpty); XCTAssertEqual(none.excluded.count, 1); XCTAssertTrue(none.complete)
        // …and the empty export is still written, replacing an earlier one with the frames in it: the trainer
        // reads sidecars without the project, so a stale one would train on the cut footage.
        let sidecar = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString).trainingdata.json")
        defer { try? FileManager.default.removeItem(at: sidecar) }
        try TrainingDataExporter.write(export, to: sidecar)
        XCTAssertEqual(try JSONDecoder().decode(TrainingDataExporter.Export.self, from: Data(contentsOf: sidecar)).frames.count, 80)
        try TrainingDataExporter.write(whole, to: sidecar)
        let replaced = try JSONDecoder().decode(TrainingDataExporter.Export.self, from: Data(contentsOf: sidecar))
        XCTAssertTrue(replaced.frames.isEmpty); XCTAssertEqual(replaced.cuts.map { [$0.start, $0.end] }, [[0, 100]])

        // The headless export walks a folder of videos; a video's cuts come from the project session over it.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        let project = root.appendingPathComponent("P", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("footage/v.mp4")
        try FileManager.default.createDirectory(at: video.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<5000).map { UInt8($0 % 251) }).write(to: video)
        var session = VideoSession(name: "v", sourcePath: video.path, split: "train", addedAt: Date(), frames: [])
        session.cuts = [cut(1, 2)]
        try DatasetStore(root: project).save(session)
        XCTAssertEqual(try TrainingDataExporter.cutRanges(forVideo: video, projectRoots: [project]), [cut(1, 2)])
        let other = root.appendingPathComponent("footage/other.mp4"); try Data([1, 2, 3]).write(to: other)
        XCTAssertEqual(try TrainingDataExporter.cutRanges(forVideo: other, projectRoots: [project]), [])
        // The export fails closed on the pass: a video no project knows cannot prove it complete, a session not
        // finished is refused, a finished one goes.
        XCTAssertNotNil(try TrainingDataExporter.exportRefusal(forVideo: other, projectRoots: [project]), "no session over it")
        XCTAssertNotNil(try TrainingDataExporter.exportRefusal(forVideo: video, projectRoots: [project]), "not every rally marked")
        session.ralliesMarked = true
        try DatasetStore(root: project).save(session)
        XCTAssertNil(try TrainingDataExporter.exportRefusal(forVideo: video, projectRoots: [project]))
        // …and the session's truth reads the sidecar by kind, outside its cuts, complete.
        let marks = RallyMarkModel.labelsURL(for: video)
        try JSONEncoder().encode([RallyMarkRecord(startTime: 0.5, endTime: 3, kind: nil, contacts: nil),
                                  RallyMarkRecord(startTime: 5, endTime: 6, kind: .missedServe, contacts: nil)]).write(to: marks)
        let read = try XCTUnwrap(try RallyTruth.of(try XCTUnwrap(try TrainingDataExporter.session(forVideo: video, projectRoots: [project]))))
        XCTAssertEqual(read.positives, [RallyTruth.Span(start: 0.5, end: 1), RallyTruth.Span(start: 2, end: 3)])
        XCTAssertEqual(read.excluded, [RallyTruth.Span(start: 5, end: 6)]); XCTAssertTrue(read.complete)
        session.ralliesMarked = false
        try DatasetStore(root: project).save(session)
        XCTAssertEqual(try RallyTruth.of(try XCTUnwrap(try TrainingDataExporter.session(forVideo: video, projectRoots: [project])))?.complete, false)
        try Data("{not json".utf8).write(to: marks)
        XCTAssertThrowsError(try RallyTruth.marks(inSidecarOf: video), "unreadable marks are unknown, never none")
        // The Pipeline tab reads the same sidecar the same way: unknown (undecodable, or absent) is never an empty list.
        func unknown(_ r: Result<[EditableRally], RallyLabModel.LabelsUnknown>) -> Bool? { if case .failure(let p) = r { return p.sidecarExists }; return nil }
        XCTAssertEqual(unknown(RallyLabModel.readLabels(at: marks)), true)
        try FileManager.default.removeItem(at: marks)
        XCTAssertNil(try RallyTruth.marks(inSidecarOf: video))
        XCTAssertEqual(unknown(RallyLabModel.readLabels(at: marks)), false)
        try JSONEncoder().encode([RallyMarkRecord]()).write(to: marks)
        XCTAssertEqual(try RallyLabModel.readLabels(at: marks).get().count, 0, "an empty list read is known: a complete pass with no rally")
        // A copy of the recording under another name and path is the same recording (by content), as the Pipeline tab sees it.
        let copy = root.appendingPathComponent("elsewhere.mp4"); try FileManager.default.copyItem(at: video, to: copy)
        XCTAssertEqual(try TrainingDataExporter.cutRanges(forVideo: copy, projectRoots: [project]), [cut(1, 2)])
        // A project anywhere on the Mac is searched when it is on the list, not only the default location.
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("elsewhere-\(UUID().uuidString)/Q", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere.deletingLastPathComponent()) }
        let far = elsewhere.deletingLastPathComponent().appendingPathComponent("far.mp4")
        var farSession = VideoSession(name: "far", sourcePath: far.path, split: "train", addedAt: Date(), frames: [])
        farSession.cuts = [cut(3, 4)]
        try DatasetStore(root: elsewhere).save(farSession)
        XCTAssertEqual(try TrainingDataExporter.cutRanges(forVideo: far, projectRoots: [root]), [], "not on the list: unknown")
        XCTAssertEqual(try TrainingDataExporter.cutRanges(forVideo: far, projectRoots: [project, elsewhere]), [cut(3, 4)])
        // A card names the recording though no session is over it (the sessions folder gone): unknown cuts, not
        // none — the lookup fails closed; a video no card names is still none; the session back, the cuts are read.
        let carded = root.appendingPathComponent("C", isDirectory: true)
        try FileManager.default.createDirectory(at: carded, withIntermediateDirectories: true)
        let card = SourceRegistryTests.clip("card_0", number: 1, videos: [SourceRegistryTests.video("v", fingerprint: ProjectsModel.readFileFingerprint(atPath: video.path))])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: "C", createdAt: Date(), framesPerRally: 2, clips: [card])).write(to: carded.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try TrainingDataExporter.cutRanges(forVideo: video, projectRoots: [carded])) { XCTAssertTrue($0 is TrainingDataExporter.SessionUnavailable, "\($0)") }
        XCTAssertThrowsError(try TrainingDataExporter.cutRanges(forVideo: copy, projectRoots: [carded]), "by content too")
        XCTAssertEqual(try TrainingDataExporter.cutRanges(forVideo: other, projectRoots: [carded]), [])
        try DatasetStore(root: carded).prepare()
        var cardedSession = VideoSession(name: "v", sourcePath: video.path, split: "train", addedAt: Date(), frames: [])
        cardedSession.cuts = [cut(5, 6)]
        try DatasetStore(root: carded).save(cardedSession)
        XCTAssertEqual(try TrainingDataExporter.cutRanges(forVideo: video, projectRoots: [carded]), [cut(5, 6)])
        // The Pipeline and Compare tabs read the same lookup: the session gone again, the tabs' cuts are unknown.
        XCTAssertEqual(try RallyLabModel.cutRanges(for: video, root: carded), [cut(5, 6)])
        try FileManager.default.removeItem(at: carded.appendingPathComponent("sessions"))
        XCTAssertThrowsError(try RallyLabModel.cutRanges(for: video, root: carded)) { XCTAssertTrue($0 is TrainingDataExporter.SessionUnavailable, "\($0)") }
        XCTAssertEqual(try RallyLabModel.cutRanges(for: other, root: carded), [])
        // A project whose sessions can't all be read: unknown cuts are not no cuts — the lookup fails closed.
        try Data("{not json".utf8).write(to: project.appendingPathComponent("sessions/broken.json"))
        XCTAssertThrowsError(try TrainingDataExporter.cutRanges(forVideo: video, projectRoots: [project]))
        XCTAssertThrowsError(try TrainingDataExporter.cutRanges(forVideo: far, projectRoots: [project, elsewhere]), "even for a video another project holds")
    }

    // MARK: - Pipeline comparison coverage and the Sampler's dataset

    func testTrackedCoverageIsJudgedOnTheSpanOutsideTheCuts() {
        // A track seen 10–60 with a cut 20–50 and perfect rallies on both retained pieces.
        let perfect = [iv(10, 20), iv(50, 60)]
        let covered = PipelineCompare.coverage(first: 10, last: 60, decided: perfect, cuts: [cut(20, 50)])
        XCTAssertNotNil(covered)
        XCTAssertEqual(covered?.start ?? -1, 0, accuracy: 1e-9); XCTAssertEqual(covered?.end ?? -1, 0, accuracy: 1e-9)
        XCTAssertNil(PipelineCompare.coverage(first: 10, last: 60, decided: [iv(10, 14)], cuts: [cut(20, 50)]), "4 of 20 retained seconds")
        XCTAssertNil(PipelineCompare.coverage(first: 10, last: 60, decided: perfect, cuts: [cut(5, 65)]), "nothing retained")
        // Without cuts, as before: half the span.
        let plain = PipelineCompare.coverage(first: 10, last: 60, decided: [iv(8, 36)], cuts: [])
        XCTAssertEqual(plain?.start ?? 1, -2, accuracy: 1e-9); XCTAssertEqual(plain?.end ?? 1, -24, accuracy: 1e-9)
    }

    func testStage1ReviewedSecondsLeaveOutTheCuts() {
        func cov(_ a: Double, _ b: Double) -> EventReview.Coverage { EventReview.Coverage(start: a, end: b, at: "2026-11-03T00:00:00Z", annotator: "t") }
        XCTAssertEqual(EventInventory.reviewedSeconds([cov(0, 50)], cuts: [cut(0, 50)]), 0, "a review of only a replay reviews nothing")
        XCTAssertEqual(EventInventory.reviewedSeconds([cov(0, 50), cov(40, 60)], cuts: [cut(10, 20)]), 50, accuracy: 1e-9, "union 0–60 less 10 s")
        XCTAssertEqual(EventInventory.reviewedSeconds([cov(0, 50)], cuts: []), 50, accuracy: 1e-9)
    }

    func testTheSamplersDatasetParksAFrameInsideACutAndBringsItBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ds-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DatasetStore(root: root)
        try store.prepare()
        let frame = FrameRecord(id: UUID(), file: "images/train/v_12.jpg", time: 12, source: "random",
                                boxes: [], keep: true, reviewed: true)   // a reviewed frame with no ball: an empty label file
        let image = root.appendingPathComponent(frame.file), label = root.appendingPathComponent(frame.labelFile)
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: image)
        try store.writeLabel(for: frame, reviewedOnly: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: label.path))
        try store.writeLabel(for: frame, reviewedOnly: true, inCut: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.path), "parked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: label.path), "no label for a frame that is not footage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("excluded").appendingPathComponent(frame.file).path))
        try store.writeLabel(for: frame, reviewedOnly: true, inCut: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), "back when the cut goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: label.path))
    }
}
