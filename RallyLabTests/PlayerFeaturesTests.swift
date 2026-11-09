//
//  PlayerFeaturesTests.swift
//  RallyLabTests
//
//  The player-feasibility research tool (P0) without Vision or video: the
//  sampling rule on presentation times, the tracker's determinism, gaps and
//  resets (IDs never reused), segment boundaries (gap, cut boundary even
//  between frames, suspected camera cut, excluded frames not analysed), pose
//  association, the court lane and its explicit unknowns, the derived
//  features, the interaction interface's missing-data handling, the bounded
//  plan, the admission refusals and the frame encoding's nulls.
//

import XCTest
@testable import RallyLab

final class PlayerFeaturesTests: XCTestCase {
    typealias Box = PlayerFeatures.Box

    private func raw(_ t: Double, _ boxes: [Box], interval: String = "a", poses: [PlayerFeatures.Pose] = [], thumb: Double = 0.5,
                     skipped: String? = nil) -> PlayerVisionExtractor.RawFrame {
        var d = PlayerDetections()
        if skipped == nil {
            let (byBox, unmatched) = PlayerDetections.associate(boxes: boxes, poses: poses)
            d.persons = boxes.enumerated().map { i, b in .init(box: b, conf: 0.9, pose: byBox[i].map { poses[$0] }) }
            d.unpairedPoses = unmatched.map { poses[$0] }
        }
        return PlayerVisionExtractor.RawFrame(t: t, interval: interval, skipped: skipped, detections: d,
                                              thumb: skipped == nil ? Array(repeating: thumb, count: 32 * 18) : [], ms: [:], image: nil)
    }

    private func pose(_ named: [String: (Double, Double)], conf: Double = 0.8) -> PlayerFeatures.Pose {
        PlayerFeatures.Pose(conf: conf, joints: PlayerFeatures.jointNames.map { n in named[n].map { PlayerFeatures.Joint(x: $0.0, y: $0.1, c: conf) } })
    }

    // MARK: Sampling

    func testSamplerTakesOneFramePerTickOnPresentationTimes() {
        let times = (0..<60).map { Double($0) / 30 }
        XCTAssertEqual(PlayerVisionExtractor.sample(times: times, start: 0, end: 2, hz: 5), [0, 6, 12, 18, 24, 30, 36, 42, 48, 54])
        // Frames before the start are never taken; the first is the first at or after it.
        XCTAssertEqual(PlayerVisionExtractor.sample(times: times, start: 0.51, end: 1.0, hz: 5).first, 16)
    }

    func testSamplerNeverTakesAFrameTwiceOrInventsOne() {
        // A dropped stretch (0.3–0.9 s missing): the next frame is taken once, then the grid resumes after it.
        let times = (0..<9).map { Double($0) / 30 } + (27..<40).map { Double($0) / 30 }
        let picked = PlayerVisionExtractor.sample(times: times, start: 0, end: 1.4, hz: 5)
        XCTAssertEqual(Set(picked).count, picked.count)
        XCTAssertEqual(picked.map { times[$0] }.map { ($0 * 30).rounded() }, [0, 6, 27, 30, 36])
    }

    // MARK: Tracker

    func testTrackerKeepsIdentitiesConfirmsAndIsDeterministic() {
        func run() -> [[PlayerTracker.Assignment]] {
            var tr = PlayerTracker()
            return (0..<5).map { k in
                let t = Double(k) * 0.2
                return tr.update([Box(x: 0.1 + 0.01 * Double(k), y: 0.2, w: 0.05, h: 0.2), Box(x: 0.6 - 0.01 * Double(k), y: 0.3, w: 0.05, h: 0.2)], at: t)
            }
        }
        let a = run(), b = run()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.map { $0.map(\.track) }, Array(repeating: [1, 2], count: 5))
        XCTAssertEqual(a[1].map(\.state), [.tentative, .tentative])
        XCTAssertEqual(a[2].map(\.state), [.confirmed, .confirmed])
    }

    func testTrackerEndsAfterTheGapAndResetNeverReusesIds() {
        var tr = PlayerTracker()
        let box = Box(x: 0.4, y: 0.2, w: 0.05, h: 0.2)
        XCTAssertEqual(tr.update([box], at: 0).first?.track, 1)
        XCTAssertEqual(tr.update([], at: 0.2), [])
        let back = tr.update([box], at: 0.6).first!
        XCTAssertEqual(back.track, 1)
        XCTAssertEqual(back.gap, 1, "one sampled frame without a match")
        XCTAssertEqual(tr.update([box], at: 2.0).first?.track, 2, "away longer than maxGapSec: a new identity")
        tr.reset()
        XCTAssertEqual(tr.update([box], at: 2.2).first?.track, 3)
    }

    func testTrackerFlagsAmbiguousOverlap() {
        var tr = PlayerTracker()
        _ = tr.update([Box(x: 0.40, y: 0.2, w: 0.1, h: 0.2), Box(x: 0.44, y: 0.2, w: 0.1, h: 0.2)], at: 0)
        let a = tr.update([Box(x: 0.42, y: 0.2, w: 0.1, h: 0.2)], at: 0.2)
        XCTAssertTrue(a[0].ambiguous)
    }

    // MARK: Assembler

    func testSegmentsResetOnIntervalGapCutBoundaryAndCameraCut() {
        // A cut range lying wholly between two sampled frames still breaks the segment.
        let cut = PlayerFeatures.TickSpan(startTick: PlayerFeatures.tick(0.85), endTick: PlayerFeatures.tick(0.9), kind: "cut")
        var asm = PlayerFrameAssembler(excluded: [cut], lane: nil)
        let b = Box(x: 0.4, y: 0.2, w: 0.05, h: 0.2)
        let f = [asm.add(raw(0.0, [b])), asm.add(raw(0.2, [b])), asm.add(raw(0.4, [b], thumb: 0.95)), asm.add(raw(0.6, [b], thumb: 0.95)),
                 asm.add(raw(1.0, [b], thumb: 0.95)), asm.add(raw(2.0, [b], thumb: 0.95)), asm.add(raw(3.0, [b], interval: "b", thumb: 0.95))]
        XCTAssertEqual(f.map(\.reset), ["interval_start", nil, "suspected_camera_cut", nil, "cut_boundary", "gap", "interval_start"])
        XCTAssertEqual(f.map(\.seg), [0, 0, 1, 1, 2, 3, 4])
        XCTAssertNil(f[0].frameDiff)
        XCTAssertEqual(f[2].frameDiff!, 0.45, accuracy: 1e-9)
        // Every segment starts a new identity, never reusing one.
        let ids = f.map { $0.persons[0].track }
        XCTAssertEqual(ids, [1, 1, 2, 2, 3, 4, 5])
    }

    func testExcludedFramesAreWrittenNotAnalysed() {
        let cut = PlayerFeatures.TickSpan(startTick: 300, endTick: 600, kind: "cut")
        var asm = PlayerFrameAssembler(excluded: [cut], lane: nil)
        let b = Box(x: 0.4, y: 0.2, w: 0.05, h: 0.2)
        _ = asm.add(raw(0.4, [b]))
        let inside = asm.add(raw(0.6, [], skipped: "cut"))
        XCTAssertFalse(inside.masks.ran)
        XCTAssertEqual(inside.masks.skipped, "cut")
        XCTAssertEqual(inside.reset, "cut_boundary")
        XCTAssertTrue(inside.persons.isEmpty)
        let after = asm.add(raw(1.0, [b]))
        XCTAssertEqual(after.reset, "cut_boundary")
        XCTAssertNil(after.frameDiff)
    }

    func testPoseAssociationIsByJointsInsideTheBox() {
        let boxes = [Box(x: 0.1, y: 0.1, w: 0.1, h: 0.3), Box(x: 0.6, y: 0.1, w: 0.1, h: 0.3)]
        let inSecond = pose(["neck": (0.65, 0.35), "root": (0.65, 0.25), "left_ankle": (0.64, 0.11)])
        let nowhere = pose(["neck": (0.4, 0.8), "root": (0.4, 0.7)])
        let (byBox, unmatched) = PlayerDetections.associate(boxes: boxes, poses: [nowhere, inSecond])
        XCTAssertEqual(byBox, [nil, 1])
        XCTAssertEqual(unmatched, [0])
    }

    // MARK: Court lane

    private func net(_ fp: String = "file:a") -> PlayerFeatures.NetGeometry {
        PlayerFeatures.NetGeometry(corners: [[0.3, 0.6], [0.7, 0.6], [0.7, 0.5], [0.3, 0.5]], origin: "person_label", labelFingerprint: fp)
    }

    func testCourtLaneIsUnknownWithoutItsAssumptions() {
        XCTAssertNotNil(PlayerCourtLane.make(net: nil, camera: "End line, ground level", recordingFingerprint: "file:a").unknownReason)
        XCTAssertNotNil(PlayerCourtLane.make(net: net("file:b"), camera: "End line, ground level", recordingFingerprint: "file:a").unknownReason)
        XCTAssertNotNil(PlayerCourtLane.make(net: net(), camera: "Sideline / near net", recordingFingerprint: "file:a").unknownReason)
        XCTAssertNotNil(PlayerCourtLane.make(net: net(), camera: "End line, ground level", recordingFingerprint: nil).unknownReason)
        XCTAssertNotNil(PlayerCourtLane.make(net: net(), camera: "End line, elevated (stands/tripod 2m+)", recordingFingerprint: "file:a").lane)
    }

    func testCourtLaneWidensTowardTheCamera() {
        let lane = PlayerCourtLane.make(net: net(), camera: "End line, ground level", recordingFingerprint: "file:a").lane!
        // At the net's foot line: the posts' span plus the margin either side.
        XCTAssertEqual(lane.membership(Box(x: 0.30, y: 0.5, w: 0.04, h: 0.1)), .inside)
        XCTAssertEqual(lane.membership(Box(x: 0.10, y: 0.5, w: 0.04, h: 0.1)), .outside)
        // Near the bottom of the frame the same x is inside.
        XCTAssertEqual(lane.membership(Box(x: 0.10, y: 0.02, w: 0.04, h: 0.3)), .inside)
        // Far court narrows.
        XCTAssertEqual(lane.membership(Box(x: 0.25, y: 0.9, w: 0.02, h: 0.05)), .outside)
    }

    // MARK: Derived

    func testPoseFeaturesAndMissingJoints() {
        let d = PlayerDerivedFeatures()
        let up = pose(["neck": (0.5, 0.6), "root": (0.5, 0.4), "left_shoulder": (0.45, 0.6), "left_wrist": (0.45, 0.75),
                       "left_hip": (0.47, 0.4), "left_knee": (0.47, 0.3), "left_ankle": (0.47, 0.2)])
        let f = d.poseFeatures(up)
        XCTAssertEqual(f.arm!, 0.75, accuracy: 1e-9)
        XCTAssertEqual(f.lean!, 0, accuracy: 1e-9)
        XCTAssertEqual(f.knee!, 180, accuracy: 1e-6)
        let none = d.poseFeatures(pose(["nose": (0.5, 0.5)]))
        XCTAssertNil(none.arm); XCTAssertNil(none.lean); XCTAssertNil(none.knee)
        XCTAssertNil(d.poseFeatures(nil).arm)
        // Below the confidence floor a joint is unusable.
        XCTAssertNil(d.poseFeatures(pose(["neck": (0.5, 0.6), "root": (0.5, 0.4), "left_shoulder": (0.45, 0.6), "left_wrist": (0.45, 0.75)], conf: 0.1)).arm)
    }

    func testSpeedTurnAndLiftAreCausal() {
        var d = PlayerDerivedFeatures()
        let a = d.observe(track: 1, at: 0, box: Box(x: 0.1, y: 0.2, w: 0.1, h: 0.2), pose: nil)
        XCTAssertNil(a.speed)
        let b = d.observe(track: 1, at: 0.2, box: Box(x: 0.12, y: 0.2, w: 0.1, h: 0.2), pose: nil)
        XCTAssertEqual(b.speed!, 0.1, accuracy: 1e-9)
        let c = d.observe(track: 1, at: 0.4, box: Box(x: 0.12, y: 0.22, w: 0.1, h: 0.2), pose: nil)
        XCTAssertEqual(c.turn!, .pi / 2, accuracy: 1e-9)
        XCTAssertGreaterThan(c.lift!, 0)
        d.reset()
        XCTAssertNil(d.observe(track: 1, at: 0.6, box: Box(x: 0.5, y: 0.2, w: 0.1, h: 0.2), pose: nil).speed)
    }

    // MARK: Interaction (interface only)

    func testInteractionNeverTurnsMissingDataIntoLabels() {
        var asm = PlayerFrameAssembler(excluded: [], lane: nil)
        let frames = [asm.add(raw(0.0, [Box(x: 0.4, y: 0.2, w: 0.1, h: 0.3)])), asm.add(raw(0.2, [Box(x: 0.4, y: 0.2, w: 0.1, h: 0.3)])),
                      asm.add(raw(0.4, [Box(x: 0.4, y: 0.2, w: 0.1, h: 0.3)])), asm.add(raw(0.6, []))]
        let ball: [BallPlayerInteraction.BallSample] = [
            .init(tick: 0, visible: false, x: nil, y: nil, conf: nil),
            .init(tick: 120, visible: true, x: 0.45, y: 0.7, conf: 0.9),
            .init(tick: 240, visible: true, x: 0.45, y: 0.6, conf: 0.8),
            .init(tick: 360, visible: true, x: 0.45, y: 0.6, conf: 0.8),
        ]
        let r = BallPlayerInteraction.compute(frames: frames, ball: ball)
        XCTAssertEqual(r[0].missing, [.ballNotVisible])
        XCTAssertNil(r[0].boxDistance)
        XCTAssertEqual(r[1].nearestTrack, 1)
        XCTAssertEqual(r[1].boxDistance!, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r[1].missing, [.noPose])
        XCTAssertEqual(r[2].approachRate!, -0.5, accuracy: 1e-9, "0.1 closer in 0.2 s")
        XCTAssertEqual(r[3].missing, [.noPersons])
        XCTAssertEqual(BallPlayerInteraction.compute(frames: [frames[1]], ball: []).first?.missing, [.noBallStep])
    }

    // MARK: Plan and admission

    private func interval(_ name: String, _ a: Double, _ b: Double) -> PlayerFeatures.Interval {
        .init(name: name, kind: .activePlay, startSec: a, endSec: b, selection: "test")
    }

    func testPlanIsBounded() {
        let ok = PlayerFeaturesRun.Plan(recordings: [.init(recordingId: "r", intervals: [interval("a", 0, 15), interval("b", 20, 35)])])
        XCTAssertEqual(PlayerFeaturesRun.validate(ok), [])
        var long = ok; long.recordings[0].intervals = [interval("a", 0, 61)]
        XCTAssertFalse(PlayerFeaturesRun.validate(long).isEmpty)
        var overlap = ok; overlap.recordings[0].intervals = [interval("a", 0, 15), interval("b", 10, 20)]
        XCTAssertFalse(PlayerFeaturesRun.validate(overlap).isEmpty)
        var many = ok; many.recordings = (0..<13).map { .init(recordingId: "r\($0)", intervals: [interval("a", 0, 10)]) }
        XCTAssertFalse(PlayerFeaturesRun.validate(many).isEmpty)
        var fast = ok; fast.hz = 30
        XCTAssertFalse(PlayerFeaturesRun.validate(fast).isEmpty)
        var total = ok; total.recordings = (0..<11).map { .init(recordingId: "r\($0)", intervals: [interval("a", 0, 60)]) }
        XCTAssertFalse(PlayerFeaturesRun.validate(total).isEmpty, "660 s > the 600 s budget")
    }

    private func source(_ name: String, admission: SourceRegistry.Admission = .admitted, level: TrainingEligibility.Level = .standard) -> SourceRegistry.Source {
        let v = TrainingEligibility.Verdict(level: level, reasons: level == .standard ? [] : ["because"])
        return SourceRegistry.Source(
            video: name, clipId: nil, surface: "beach", camera: "End line, ground level", originKind: "file", uploader: nil, license: nil,
            pulledFrom: nil, fingerprint: "file:\(name)", identityKey: "fp:file:\(name)", identityConfidence: .inferred, sourceId: nil, sessionId: nil,
            venueId: nil, aliasGroup: name, duplicates: [], sameSource: [], split: .train, reservedAs: nil, admission: admission,
            admissionReason: nil, hasSession: true, frames: 0, reviewedFrames: 0, ralliesMarked: true, humanLabeledRallies: 0,
            machineRalliesAwaitingCheck: 0, exposure: [], recordingType: .continuous, derivedFrom: nil,
            eligibility: TrainingEligibility.Assessment(byModel: [TrainingEligibility.Model.rallyClassifier.rawValue: v], fullVideoNegatives: v))
    }

    private func eligible(_ name: String, split: DatasetSplit = .train) -> LineagePackage.Eligible {
        LineagePackage.Eligible(video: name, split: split, packageSplit: "train", aliasGroup: name, identities: [], reviewedFrames: 0, ralliesMarked: true)
    }

    func testAdmissionRefusesWithheldUnisolatedIneligibleAndUnadmitted() {
        let registry = ["ok": source("ok"), "bad": source("bad", level: .notAssessed), "quar": source("quar", admission: .quarantined),
                        "nosession": source("nosession")]
        let r = PlayerFeaturesRun.admissionRefusals(
            planned: ["ok", "held", "bad", "quar", "stray", "nosession"], closure: ["held"],
            eligible: [eligible("ok"), eligible("bad"), eligible("quar"), eligible("nosession"), eligible("held")],
            registry: registry, sessions: ["ok", "bad", "quar", "held"])
        XCTAssertEqual(r.count, 5)
        XCTAssertTrue(r[0].hasPrefix("held is withheld"))
        XCTAssertTrue(r[1].hasPrefix("bad: rally classifier not_assessed"))
        XCTAssertTrue(r[2].hasPrefix("quar: admission quarantined"))
        XCTAssertTrue(r[3].hasPrefix("stray is not an isolated development recording"))
        XCTAssertTrue(r[4].hasPrefix("nosession has no dataset session"))
        XCTAssertEqual(PlayerFeaturesRun.admissionRefusals(planned: ["ok"], closure: ["held"], eligible: [eligible("ok")], registry: registry, sessions: ["ok"]), [])
    }

    func testExcludedSpansTakeCutsAndEveryActiveTimeBreakingSpan() {
        func span(_ traits: [FootageProperties.Trait], _ origin: FootageProperties.Origin, rejected: Bool = false, start: Double? = 10, end: Double? = 20) -> FootageProperties.Span {
            .init(id: UUID(), start: start, end: end, traits: traits, origin: origin, confidence: nil, source: nil, note: nil, at: "x", by: "y",
                  rejectedAt: rejected ? "z" : nil)
        }
        let file = FootageProperties.File(video: "r", spans: [span([.replay], .proposed), span([.slowMotion], .confirmed, rejected: true),
                                                             span([.handheld], .confirmed), span([.montage], .confirmed, start: nil, end: nil)],
                                          updatedAt: "x")
        let (cuts, breaks) = PlayerFeaturesRun.excludedSpans(cuts: [CutRange(start: 1, end: 2)], properties: file, durationSec: 100)
        XCTAssertEqual(cuts, [.init(startTick: 600, endTick: 1200, kind: "cut")])
        XCTAssertEqual(breaks, [.init(startTick: 6000, endTick: 12000, kind: "time_break"), .init(startTick: 0, endTick: 60000, kind: "time_break")])
        XCTAssertEqual(PlayerFeaturesRun.exclusion(at: 1.5, in: cuts), "cut")
        XCTAssertNil(PlayerFeaturesRun.exclusion(at: 2.0, in: cuts), "half-open")
    }

    // MARK: Encoding

    func testFrameEncodingKeepsMissingJointsAsNull() throws {
        var asm = PlayerFrameAssembler(excluded: [], lane: nil)
        let p = pose(["neck": (0.45, 0.45), "root": (0.45, 0.3)])
        let f = asm.add(raw(12.4333, [Box(x: 0.4, y: 0.2, w: 0.1, h: 0.3)], poses: [p]))
        XCTAssertEqual(f.tick, 7460)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(f)) as! [String: Any]
        let person = (json["persons"] as! [[String: Any]])[0]
        let joints = (person["pose"] as! [String: Any])["joints"] as! [Any]
        XCTAssertEqual(joints.count, 19)
        XCTAssertTrue(joints[0] is NSNull)
        XCTAssertEqual(person["court"] as? String, "unknown")
    }

    // MARK: Summary (shared by the run's summary.json and the Player Lab window)

    func testSummaryCountsTracksPosesAndExcludedFrames() {
        let cut = PlayerFeatures.TickSpan(startTick: 360, endTick: 480, kind: "cut")
        var asm = PlayerFrameAssembler(excluded: [cut], lane: nil)
        let a = Box(x: 0.1, y: 0.2, w: 0.05, h: 0.2), b = Box(x: 0.6, y: 0.2, w: 0.05, h: 0.4)
        let p = pose(["neck": (0.62, 0.5), "root": (0.62, 0.35), "left_ankle": (0.61, 0.21)])
        let frames = [asm.add(raw(0.0, [a, b], poses: [p])), asm.add(raw(0.2, [a])), asm.add(raw(0.4, [a])),
                      asm.add(raw(0.7, [], skipped: "cut")), asm.add(raw(0.9, [a]))]
        let s = PlayerFeaturesSummary.stats(frames, laneKnown: false)
        XCTAssertEqual(s.frames, 5)
        XCTAssertEqual(s.analysed, 4)
        XCTAssertEqual(s.personsPerFrame!, 5.0 / 4, accuracy: 1e-9)
        XCTAssertNil(s.inCourtPerFrame, "no lane: not reported")
        XCTAssertEqual(s.poseShare!, 1.0 / 5, accuracy: 1e-9)
        XCTAssertEqual(s.jointsPerPose!, 3, accuracy: 1e-9)
        XCTAssertEqual(s.tracks, 3, "a, b, and a again after the cut boundary")
        XCTAssertEqual(s.confirmed, 1)
        XCTAssertEqual(s.tentativeOnly, 2)
        XCTAssertEqual(s.resets, ["interval_start": 1, "cut_boundary": 2])
        let spans = PlayerFeaturesSummary.tracks(frames)
        XCTAssertEqual(spans.map(\.id), [1, 2, 3])
        XCTAssertEqual(spans[0].frames, [0, 1, 2])
        XCTAssertEqual(spans[0].confirmedFrom, 2)
    }
}
