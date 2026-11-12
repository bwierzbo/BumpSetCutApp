//
//  CourtCalibrationTests.swift
//  RallyLabTests
//
//  Court calibration (research P2) without video: the perspective maps and their
//  explicit unknowns, the zones with their boundary doubt and smoothing, the feet,
//  the calibration file (serialisation, staleness, confirmation as the only path to
//  evidence, scripted confirmations never used, segments), the net-guided proposal's
//  geometry, the line search on a drawn court, and the assembler using a confirmed court.
//

import XCTest
@testable import RallyLab

final class CourtCalibrationTests: XCTestCase {
    typealias Box = PlayerFeatures.Box

    /// A court seen from behind the near end line: wide at the bottom, narrow at the far end.
    private func layout(far: CourtPoint.Status = .seen) -> CourtLayout {
        CourtLayout(nearLeft: CourtPoint(x: 0.1, y: 0.1, status: .seen), nearRight: CourtPoint(x: 0.9, y: 0.1, status: .seen),
                    netRight: CourtPoint(x: 0.75, y: 0.45, status: .seen), netLeft: CourtPoint(x: 0.25, y: 0.45, status: .seen),
                    farLeft: CourtPoint(x: 0.32, y: 0.6, status: far), farRight: CourtPoint(x: 0.68, y: 0.6, status: far))
    }

    private func person(_ box: Box, track: Int = 1, pose: PlayerFeatures.Pose? = nil, lift: Double? = nil) -> PlayerFeatures.Person {
        var d = PlayerFeatures.PersonDerived()
        d.lift = lift
        return PlayerFeatures.Person(box: box, conf: 0.9, track: track, state: .confirmed, hits: 3, gap: 0, ambiguous: false, court: .unknown,
                                     pose: pose, derived: d)
    }

    /// A 0.04 × 0.15 box standing at (x, y).
    private func standing(_ x: Double, _ y: Double) -> Box { Box(x: x - 0.02, y: y, w: 0.04, h: 0.15) }

    // MARK: Maps

    func testHomographyRoundTripsAndInverts() throws {
        let h = try XCTUnwrap(Homography.fit(from: [(0, 0), (1, 0), (1, 1), (0, 1)], to: [(0.1, 0.1), (0.9, 0.1), (0.7, 0.6), (0.3, 0.6)]))
        let p = h.apply(1, 1)
        XCTAssertEqual(p.x, 0.7, accuracy: 1e-9); XCTAssertEqual(p.y, 0.6, accuracy: 1e-9)
        let back = try XCTUnwrap(h.inverse).apply(0.5, 0.35)
        let again = h.apply(back.x, back.y)
        XCTAssertEqual(again.x, 0.5, accuracy: 1e-9); XCTAssertEqual(again.y, 0.35, accuracy: 1e-9)
        XCTAssertNil(Homography.fit(from: [(0, 0), (1, 0), (2, 0), (0, 1)], to: [(0, 0), (1, 0), (2, 0), (0, 1)]), "three collinear points have no map")
    }

    func testEachHalfMapsItsOwnCornersAndTheNetLineIsKeptAsPlaced() throws {
        let g = layout()
        for r in CourtLayout.Role.allCases {
            let p = try XCTUnwrap(g.image(u: r.court.u, v: r.court.v))
            XCTAssertEqual(p.x, g[r].x, accuracy: 1e-9, r.rawValue); XCTAssertEqual(p.y, g[r].y, accuracy: 1e-9, r.rawValue)
        }
        // The net line on screen is not the near half's perspective midpoint: each half keeps it where it was placed.
        let c = try XCTUnwrap(g.courtCoordinates(0.5, 0.45))
        XCTAssertEqual(c.v, 0.5, accuracy: 1e-9)
        XCTAssertTrue(g.isUsable)
    }

    func testFoldedOrOverlappingCourtsAreRefused() {
        var g = layout()
        g.nearLeft = CourtPoint(x: 0.9, y: 0.1, status: .seen)
        g.nearRight = CourtPoint(x: 0.1, y: 0.1, status: .seen)
        XCTAssertNil(g.map(near: true), "a near half that crosses itself has no map")
        var h = layout()
        h.farLeft = CourtPoint(x: 0.3, y: 0.3, status: .seen); h.farRight = CourtPoint(x: 0.7, y: 0.3, status: .seen)
        XCTAssertFalse(h.problems.isEmpty, "a far half on the near side of the net is refused")
        var o = layout()
        o.farLeft.x = 4
        XCTAssertTrue(o.problems.contains { $0.contains("outside the frame") })
    }

    // MARK: Zones

    func testZonesNearFarServingOutsideAndBoundaryDoubt() {
        let c = CourtZoneClassifier(geometry: layout(), spec: .indoor, settings: .init())
        XCTAssertEqual(c.classify(x: 0.5, y: 0.25).zone, .nearCourt)
        XCTAssertEqual(c.classify(x: 0.5, y: 0.52).zone, .farCourt)
        XCTAssertEqual(c.classify(x: 0.5, y: 0.07).zone, .nearServingArea)
        XCTAssertEqual(c.classify(x: 0.5, y: 0.63).zone, .farServingArea)
        XCTAssertEqual(c.classify(x: 0.02, y: 0.3).zone, .outsideCourt)
        XCTAssertTrue(c.classify(x: 0.5, y: 0.452).uncertain, "on the net line")
        XCTAssertFalse(c.classify(x: 0.5, y: 0.25).uncertain)
        XCTAssertEqual(c.classify(x: 0.5, y: 1.4).zone, .unknown, "beyond the horizon of the far half's map")
    }

    func testAHalfWithAnUnknownPointHasNoZones() {
        let c = CourtZoneClassifier(geometry: layout(far: .unknown), spec: .indoor, settings: .init())
        XCTAssertEqual(c.classify(x: 0.5, y: 0.25).zone, .nearCourt)
        XCTAssertEqual(c.classify(x: 0.5, y: 0.52).zone, .unknown, "the far half has no map: never guessed")
        XCTAssertTrue(layout(far: .unknown).isUsable, "one mapped half is a usable court")
    }

    func testFeetFromReliableAnklesElseTheBox() {
        let box = Box(x: 0.4, y: 0.2, w: 0.1, h: 0.3)
        let joints: [String: PlayerFeatures.Joint] = ["left_ankle": .init(x: 0.43, y: 0.24, c: 0.9), "right_ankle": .init(x: 0.47, y: 0.22, c: 0.9)]
        let pose = PlayerFeatures.Pose(conf: 0.9, joints: PlayerFeatures.jointNames.map { joints[$0] })
        let g = CourtGround.point(person(box, pose: pose))
        XCTAssertEqual(g.foot, "ankles")
        XCTAssertEqual(g.x, 0.45, accuracy: 1e-9)
        XCTAssertEqual(g.y, 0.22 - 0.03 * 0.3, accuracy: 1e-9)
        let weak = PlayerFeatures.Pose(conf: 0.9, joints: PlayerFeatures.jointNames.map { joints[$0].map { PlayerFeatures.Joint(x: $0.x, y: $0.y, c: 0.1) } })
        XCTAssertEqual(CourtGround.point(person(box, pose: weak)).foot, "box")
        XCTAssertEqual(CourtGround.point(person(box)).y, 0.2)
    }

    func testSmoothingHoldsThroughDoubtAndNeedsTwoFramesToChange() {
        var s = CourtZoneSmoother()
        XCTAssertEqual(s.observe(track: 1, raw: .nearCourt, reliable: true).zone, .nearCourt)
        XCTAssertEqual(s.observe(track: 1, raw: .outsideCourt, reliable: false).zone, .nearCourt, "doubt holds")
        XCTAssertEqual(s.observe(track: 1, raw: .outsideCourt, reliable: true).zone, .nearCourt, "one frame is not enough")
        XCTAssertEqual(s.observe(track: 1, raw: .outsideCourt, reliable: true).zone, .outsideCourt)
        XCTAssertEqual(s.observe(track: 2, raw: .farCourt, reliable: true).zone, .farCourt, "tracks are independent")
        s.reset()
        XCTAssertEqual(s.observe(track: 1, raw: .farServingArea, reliable: false).zone, .farServingArea, "after a reset the first observation stands")
    }

    func testPassMarksJumpsAndCutFeetAndNeverDropsAnyone() {
        var pass = CourtMembershipPass { _ in (CourtZoneClassifier(geometry: self.layout(), spec: .indoor, settings: .init()), 0) }
        let crowd = (0..<14).map { person(standing(0.3 + 0.03 * Double($0 % 10), 0.2), track: $0) }
        let z = try! XCTUnwrap(pass.zones(crowd, at: 1))
        XCTAssertEqual(z.count, 14, "fourteen people on a 6v6 court are all kept")
        XCTAssertTrue(z.allSatisfy { $0.zone == .nearCourt })
        let jump = try! XCTUnwrap(pass.zones([person(standing(0.5, 0.52), track: 0, lift: 0.6)], at: 2))[0]
        XCTAssertEqual(jump.zone, .nearCourt, "a jump holds the track's zone")
        XCTAssertTrue(jump.why.contains("airborne") && jump.why.contains("held"))
        let cut = try! XCTUnwrap(pass.zones([person(Box(x: 0.5, y: 0, w: 0.1, h: 0.3), track: 99)], at: 3))[0]
        XCTAssertTrue(cut.uncertain && cut.why.contains("truncated"))
        var none = CourtMembershipPass { _ in nil }
        XCTAssertNil(none.zones(crowd, at: 1), "no confirmed court: no zones")
    }

    // MARK: The calibration file

    private func binding(_ decoded: String = "file:copy") -> CourtCalibrationFile.Binding {
        CourtCalibrationFile.Binding(recordingId: "rec_01", sourceFingerprint: "file:orig", decodedFingerprint: decoded, frameWidth: 960, frameHeight: 540,
                                     orientation: 1, camera: "End line, ground level", surface: "indoor", durationSec: 300)
    }

    private func proposal(_ g: CourtLayout) -> CourtProposal {
        CourtProposal(method: .netGuided, geometry: g, confidence: 0.25, uncertainty: ["assumed"], pointSources: [:], inputs: [:], frameTimes: [],
                      createdAt: Date(timeIntervalSince1970: 1_700_000_000), ms: 0, codeSha: "abc")
    }

    func testFileRoundTripsByteForByteAndGoesStaleWithTheFile() throws {
        var f = CourtCalibrationFile.new(for: binding())
        f.segments[0].proposals = [proposal(layout())]
        f.setup = CourtSetup(surface: .indoor, format: .sixes, markings: .lines, answeredAt: Date(timeIntervalSince1970: 1_700_000_100))
        let a = try CourtCalibrationStore.encoder.encode(f)
        let back = try CourtCalibrationStore.decoder.decode(CourtCalibrationFile.self, from: a)
        XCTAssertEqual(back, f)
        XCTAssertEqual(try CourtCalibrationStore.encoder.encode(back), a, "deterministic")
        XCTAssertNil(f.staleReason(for: binding()))
        XCTAssertNotNil(f.staleReason(for: binding("file:other")), "another decoded file")
        var b = binding(); b.frameWidth = 1920
        XCTAssertNotNil(f.staleReason(for: b), "another frame size")
        XCTAssertEqual(CourtSetup(surface: .beach, format: .fours, markings: nil, answeredAt: nil).spec?.lengthM, 16)
        XCTAssertEqual(CourtSetup(surface: .grass, format: .sixes, markings: nil, answeredAt: nil).spec?.lengthM, 18)
    }

    func testOnlyAPersonsConfirmIsEvidenceAndItKeepsWhatWasMoved() throws {
        var f = CourtCalibrationFile.new(for: binding())
        let p = layout()
        f.segments[0].proposals = [proposal(p)]
        XCTAssertNil(f.confirmed(at: 10), "a proposal is never a confirmation")
        var bad = p; bad.nearLeft = CourtPoint(x: 0.9, y: 0.1, status: .seen); bad.nearRight = CourtPoint(x: 0.1, y: 0.1, status: .seen)
        bad.farLeft.status = .unknown
        XCTAssertThrowsError(try f.confirm(segment: 0, geometry: bad, startedFrom: "net_guided_v1", baseline: p, by: "o", net: nil, spec: .indoor,
                                           format: nil, now: Date()))
        let moved = p.moving(.nearLeft, to: 0.12, 0.1)
        try f.confirm(segment: 0, geometry: moved, startedFrom: "net_guided_v1", baseline: p, by: "Owner", net: nil, spec: .indoor, format: "6v6",
                      now: Date(timeIntervalSince1970: 1_700_000_200))
        XCTAssertEqual(f.segments[0].confirmation?.adjustedRoles, ["nearLeft"])
        XCTAssertEqual(f.confirmed(at: 10)?.geometry, moved)
        XCTAssertEqual(f.segments[0].proposals.first?.geometry, p, "the proposal is kept as made")
        // Re-confirming keeps the earlier one; taking the segment out of use keeps it too.
        try f.confirm(segment: 0, geometry: p, startedFrom: "confirmation", baseline: moved, by: "Owner", net: nil, spec: .indoor, format: nil, now: Date())
        XCTAssertEqual(f.segments[0].history.count, 1)
        f.set(segment: 0, status: .unknownView, note: "pan")
        XCTAssertNil(f.confirmed(at: 10))
        XCTAssertEqual(f.segments[0].history.count, 2)
        // A scripted GUI test's confirmation is recorded and never used.
        var s = CourtCalibrationFile.new(for: binding())
        try s.confirm(segment: 0, geometry: p, startedFrom: "manual", baseline: nil, by: "script", net: nil, spec: .indoor, format: nil, now: Date(),
                      method: CourtConfirmation.scriptMethod)
        XCTAssertEqual(s.segments[0].status, .confirmed)
        XCTAssertNil(s.confirmed(at: 10))
    }

    func testSegmentsSplitAtACameraChangeAndRefuseOverlap() throws {
        var f = CourtCalibrationFile.new(for: binding())
        try f.confirm(segment: 0, geometry: layout(), startedFrom: "manual", baseline: nil, by: "o", net: nil, spec: .indoor, format: nil, now: Date())
        XCTAssertTrue(f.split(at: 120))
        XCTAssertEqual(f.segments.map(\.validToSec), [120, 300])
        XCTAssertNotNil(f.confirmed(at: 60))
        XCTAssertNil(f.confirmed(at: 200), "the new view is unconfirmed until a person confirms it")
        XCTAssertEqual(f.segments[1].draft, layout(), "it starts from the earlier court as a draft")
        XCTAssertTrue(f.segmentProblems.isEmpty)
        f.segments[1].validFromSec = 100
        XCTAssertFalse(f.segmentProblems.isEmpty)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("court-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CourtCalibrationStore(experiment: dir)
        XCTAssertThrowsError(try store.save(f), "a malformed file is never written")
    }

    func testLookupRefusesStaleUnreadableAndUnconfirmedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("court-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CourtCalibrationStore(experiment: dir)
        XCTAssertEqual(store.confirmedLookup(for: binding()).unusable, "no court calibration")
        var f = CourtCalibrationFile.new(for: binding())
        try store.save(f)
        XCTAssertNotNil(store.confirmedLookup(for: binding()).unusable)
        try f.confirm(segment: 0, geometry: layout(), startedFrom: "manual", baseline: nil, by: "o", net: nil, spec: .indoor, format: nil, now: Date())
        try store.save(f)
        XCTAssertNil(store.confirmedLookup(for: binding()).unusable)
        XCTAssertNotNil(store.confirmedLookup(for: binding("file:other")).unusable, "stale")
        try Data("{".utf8).write(to: store.url("rec_01"))
        XCTAssertTrue(store.confirmedLookup(for: binding()).unusable?.contains("unreadable") == true, "unreadable is an error, never empty")
    }

    // MARK: Proposals

    /// Net posts 180 px apart at 640 × 360, mesh 30 px deep.
    private func syntheticNet() -> PlayerFeatures.NetGeometry {
        let w = 640.0, h = 360.0
        func v(_ x: Double, _ y: Double) -> [Double] { [x / w, 1 - y / h] }
        return PlayerFeatures.NetGeometry(corners: [v(230, 119.5), v(410, 119.5), v(410, 149.5), v(230, 149.5)], origin: "person_label",
                                          labelFingerprint: "file:orig")
    }

    func testNetGuidedPutsTheSidelinesInsideThePostsAndEstimatesEverything() throws {
        let p = try XCTUnwrap(CourtProposer.netGuided(net: syntheticNet(), width: 640, height: 360, camera: "End line, ground level", spec: .indoor))
        let g = p.geometry
        XCTAssertTrue(CourtLayout.Role.allCases.allSatisfy { g[$0].status != .seen }, "nothing the method assumed is 'seen'")
        // The ground under the net: 1.35 m of the 30 px/m scale below the mesh's bottom.
        XCTAssertEqual(g.netLeft.y, 1 - (149.5 + 40.5) / 360, accuracy: 1e-9)
        XCTAssertGreaterThan(g.netLeft.x, 230 / 640); XCTAssertLessThan(g.netRight.x, 410 / 640)
        XCTAssertLessThan(g.nearLeft.y, g.netLeft.y); XCTAssertGreaterThan(g.farLeft.y, g.netLeft.y)
        XCTAssertLessThan(g.nearLeft.x, g.netLeft.x, "wider toward the camera")
        XCTAssertTrue(g.isUsable)
        XCTAssertTrue(p.uncertainty.contains { $0.hasPrefix("assumed") })
    }

    func testLineSearchFindsADrawnCourt() throws {
        // Green ground with a deterministic speckle, white court lines: sidelines through the net line near the posts.
        let w = 640, h = 360
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        var seed: UInt32 = 7
        for i in 0..<(w * h) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let n = Int(seed >> 28)
            rgb[3 * i] = UInt8(40 + n); rgb[3 * i + 1] = UInt8(120 + n); rgb[3 * i + 2] = UInt8(40 + n)
        }
        func line(_ a: (Double, Double), _ b: (Double, Double)) {
            let len = Int(hypot(b.0 - a.0, b.1 - a.1))
            for s in 0...len {
                let t = Double(s) / Double(max(len, 1))
                let x = Int((a.0 + (b.0 - a.0) * t).rounded()), y = Int((a.1 + (b.1 - a.1) * t).rounded())
                for dx in 0...1 where x + dx < w && y < h && y >= 0 { let i = (y * w + x + dx) * 3; rgb[i] = 250; rgb[i + 1] = 250; rgb[i + 2] = 250 }
            }
        }
        let groundY = 149.5 + 40.5   // where the net-guided ground line falls
        line((236, groundY), (150, 340)); line((404, groundY), (490, 340)); line((150, 340), (490, 340))
        line((236, groundY), (262, 165)); line((404, groundY), (378, 165)); line((262, 165), (378, 165))
        let img = CourtRGBImage(width: w, height: h, rgb: rgb)
        let ev = try XCTUnwrap(CourtProposer.lineEvidence(img, net: syntheticNet()))
        let netGuided = CourtProposer.netGuided(net: syntheticNet(), width: w, height: h, camera: "End line, ground level", spec: .indoor)
        let r = CourtProposer.fromLines(ev, net: syntheticNet(), netGuided: netGuided, spec: .indoor, frameTimes: [1, 2, 3], ms: 0)
        let g = try XCTUnwrap(r.lines?.geometry, r.notes.joined(separator: "; "))
        XCTAssertEqual(g.nearLeft.x * 640, 150, accuracy: 4); XCTAssertEqual((1 - g.nearLeft.y) * 360, 340, accuracy: 4)
        XCTAssertEqual(g.nearRight.x * 640, 490, accuracy: 4)
        XCTAssertEqual(g.netLeft.x * 640, 236, accuracy: 4)
        XCTAssertEqual(g.nearLeft.status, .seen)
        XCTAssertNotEqual(r.lines?.method, .combined)
    }

    func testPilotMeasuresEachProposalAgainstTheConfirmedCourt() throws {
        var f = CourtCalibrationFile.new(for: binding())
        let p = layout()
        f.segments[0].proposals = [proposal(p)]
        try f.confirm(segment: 0, geometry: p.moving(.nearLeft, to: 0.11, 0.1), startedFrom: "net_guided_v1", baseline: p, by: "Owner", net: nil,
                      spec: .indoor, format: nil, now: Date())
        let a = CourtPilot.against(try XCTUnwrap(f.segments[0].confirmation), proposals: f.segments[0].proposals, w: 1000, h: 500)
        XCTAssertEqual(a.pointErrorPx["net_guided_v1"]?["nearLeft"] ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(a.meanErrorPx["net_guided_v1"] ?? -1, 10 / 6, accuracy: 1e-9)
        XCTAssertEqual(a.adjustedRoles, ["nearLeft"])
    }

    func testTheLineSearchRecordsItsReadsBeforeDecodingAndNoMarkingsReadsNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("court-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("footage/none.mp4")
        let none = try await CourtProposer.propose(footage: missing, net: syntheticNet(), binding: binding(), from: 0, to: 60, excluded: [], spec: .indoor,
                                                   markings: CourtSetup.Markings.none, experiment: dir, ref: "test", codeSha: nil)
        XCTAssertEqual(none.proposals.map(\.method), [.netGuided])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExposureLog.url(in: dir).path), "nothing read, nothing recorded")
        do {
            _ = try await CourtProposer.propose(footage: missing, net: syntheticNet(), binding: binding(), from: 0, to: 60, excluded: [], spec: .indoor,
                                                experiment: dir, ref: "test", codeSha: nil)
            XCTFail("a missing file can't be decoded")
        } catch {}
        let rows = try String(contentsOf: ExposureLog.url(in: dir), encoding: .utf8)
        XCTAssertTrue(rows.contains("rec_01") && rows.contains("detector_evaluation"), "the use is on record before the first frame")
    }

    /// A run manifest's recording as the GUI gets it.
    private func recording(decoded: String) -> PlayerFeatures.Recording {
        PlayerFeatures.Recording(recordingId: "rec_01", groupId: "rec_01", split: "train", surface: "indoor", camera: "End line, ground level",
                                 cardOrientation: "Landscape", sourceId: nil, fingerprint: "file:orig",
                                 decoded: PlayerFeatures.DecodedFile(kind: "scrub_proxy", fileName: "rec_01.mp4", fingerprint: decoded, width: 960, height: 540,
                                                                     orientation: 1, nominalFrameRate: 30, durationSec: 300),
                                 aspect: 16.0 / 9, recordingType: "continuous", eligibility: [:], eligibilityReasons: [], net: nil, courtUnknownReason: nil,
                                 cutRanges: [], timeBreakingSpans: [], intervals: [], framesFile: "frames/rec_01.jsonl", framesSha256: "", frameCount: 1)
    }

    @MainActor
    func testAStaleCalibrationClassifiesNobodyInTheGUIAndIsShownApart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("court-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = CourtCalibrationFile.new(for: binding("file:copy"))
        try f.confirm(segment: 0, geometry: layout(), startedFrom: "manual", baseline: nil, by: "Owner", net: nil, spec: .indoor, format: nil, now: Date())
        try CourtCalibrationStore(experiment: dir).save(f)
        let frame = PlayerFeatures.Frame(t: 10, tick: 6000, interval: "a", seg: 0, reset: "interval_start", frameDiff: nil,
                                         persons: [person(standing(0.5, 0.25))], unmatchedPoses: [],
                                         scene: PlayerFeatures.SceneDerived(persons: 1, confirmed: 1, inCourt: 0, posesInCourt: 0),
                                         masks: PlayerFeatures.Masks(ran: true, skipped: nil, rectFailed: false, poseFailed: false), ms: [:])
        // The same footage: the confirmed court classifies.
        let current = CourtCalibrationModel(experiment: dir, recording: recording(decoded: "file:copy"), footage: dir)
        XCTAssertNil(current.stale)
        XCTAssertEqual(current.zones(for: [frame]).first??.first??.zone, .nearCourt)
        // Other footage under the same name: stale — nothing classified, nothing in force, the old court kept for review.
        let other = CourtCalibrationModel(experiment: dir, recording: recording(decoded: "file:newcopy"), footage: dir)
        XCTAssertNotNil(other.stale)
        XCTAssertNil(other.shown, "a stale court is never the court in force, confirmed or not")
        XCTAssertEqual(other.staleGeometry, layout(), "kept apart, for review")
        XCTAssertNil(other.zones(for: [frame]).first!, "no zones from a stale file")
        other.editConfirmed()
        other.use(.netGuided)
        XCTAssertNil(other.draft, "a stale court can't be edited back into use")
        XCTAssertFalse(other.canConfirm)
    }

    @MainActor
    func testAnUnreviewedRecordingOpensOnItsBestProposalAndNothingIsConfirmed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("court-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = CourtCalibrationFile.new(for: binding("file:copy"))
        var lines = proposal(layout().moving(.nearLeft, to: 0.12, 0.1)); lines.method = .courtLines
        f.segments[0].proposals = [proposal(layout()), lines]
        try CourtCalibrationStore(experiment: dir).save(f)
        let m = CourtCalibrationModel(experiment: dir, recording: recording(decoded: "file:copy"), footage: dir)
        XCTAssertEqual(m.startedFrom, "court_lines_v1")
        XCTAssertEqual(m.shown?.style, .proposal, "shown as a proposal")
        XCTAssertNil(try CourtCalibrationStore(experiment: dir).load("rec_01")?.segments[0].confirmation)
        XCTAssertNil(try CourtCalibrationStore(experiment: dir).load("rec_01")?.segments[0].draft, "opening saves nothing")
        XCTAssertNil(m.file?.confirmed(at: 10), "a proposal on screen is not a confirmed court")
    }

    func testReviewScoresFalseInLostPlayersServersAndHalves() throws {
        let persons = [person(standing(0.5, 0.25), track: 1), person(standing(0.5, 0.52), track: 2), person(standing(0.02, 0.3), track: 3),
                       person(standing(0.5, 0.07), track: 4), person(standing(0.5, 0.26), track: 5)]
        let frame = PlayerFeatures.Frame(t: 1, tick: 600, interval: "a", seg: 0, reset: "interval_start", frameDiff: nil, persons: persons, unmatchedPoses: [],
                                         scene: PlayerFeatures.SceneDerived(persons: 5, confirmed: 5, inCourt: 0, posesInCourt: 0),
                                         masks: PlayerFeatures.Masks(ran: true, skipped: nil, rectFailed: false, poseFailed: false), ms: [:])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let rows = [CourtReview.personsHeader,
                    "rec_01,a,600,1,x.jpg,1,0,0,0,0,near_court,Owner,", "rec_01,a,600,1,x.jpg,2,0,0,0,0,far_court,Owner,",
                    "rec_01,a,600,1,x.jpg,3,0,0,0,0,spectator,Owner,", "rec_01,a,600,1,x.jpg,4,0,0,0,0,near_serving_area,Owner,",
                    "rec_01,a,600,1,x.jpg,5,0,0,0,0,duplicate_or_not_a_person,Owner,"]
        try Data(rows.joined(separator: "\n").utf8).write(to: dir.appendingPathComponent("persons.csv"))
        try Data([CourtReview.framesHeader, "rec_01,a,600,1,x.jpg,1,0,Owner,"].joined(separator: "\r\n").utf8).write(to: dir.appendingPathComponent("frames.csv"))
        let review = try CourtReview.read(dir)
        XCTAssertEqual(review.persons.count, 5)
        var pass = CourtMembershipPass { _ in (CourtZoneClassifier(geometry: self.layout(), spec: .indoor, settings: .init()), 0) }
        let z = try XCTUnwrap(pass.zones(persons, at: 1))
        let court = CourtReview.score(source: "confirmed", confirmed: true, frames: [frame], recording: "rec_01", labels: review.persons,
                                      zone: { _, j in z[j] }, membership: { _, j in CourtMembershipPass.membership(z[j]) })
        XCTAssertEqual(court.halfCorrect, 2); XCTAssertEqual(court.halfTotal, 2)
        XCTAssertEqual(court.falseIn, 0); XCTAssertEqual(court.notPlayingTotal, 1)
        XCTAssertEqual(court.playersOut + court.playersUnknown, 0); XCTAssertEqual(court.playersTotal, 3)
        XCTAssertEqual(court.serversOut, 0); XCTAssertEqual(court.serversTotal, 1)
        XCTAssertEqual(court.duplicatesIn, 1, "a split box on the court still counts in")
        // A lane that lets everyone in and loses nobody: one false in.
        let lane = CourtReview.score(source: "lane", confirmed: false, frames: [frame], recording: "rec_01", labels: review.persons,
                                     zone: { _, _ in nil }, membership: { _, _ in .inside })
        XCTAssertEqual(lane.falseIn, 1)
        XCTAssertEqual(lane.halfTotal, 0, "no zones, no half accuracy")
        let d = CourtReview.detection(frames: [frame], recording: "rec_01", labels: review.persons, missed: review.missed)
        XCTAssertEqual(d, CourtReview.Detection(frames: 1, nearFound: 2, nearMissed: 1, farFound: 1, farMissed: 0))
        XCTAssertEqual(CourtReview.sample([frame], count: 3, avoid: [700]).count, 0, "a frame within 2 s of an earlier audit frame is left out")
    }

    // MARK: The assembler

    func testAssemblerUsesAConfirmedCourtAndOldLinesStillDecode() throws {
        var f = CourtCalibrationFile.new(for: binding())
        try f.confirm(segment: 0, geometry: layout(), startedFrom: "manual", baseline: nil, by: "o", net: nil, spec: .indoor, format: nil, now: Date())
        var asm = PlayerFrameAssembler(excluded: [], lane: nil, court: .confirmed(f))
        var d = PlayerDetections()
        d.persons = [.init(box: standing(0.5, 0.25), conf: 0.9, pose: nil), .init(box: standing(0.02, 0.3), conf: 0.9, pose: nil)]
        let frame = asm.add(PlayerVisionExtractor.RawFrame(t: 1, interval: "a", skipped: nil, detections: d, thumb: Array(repeating: 0.5, count: 32 * 18),
                                                           ms: [:], image: nil))
        XCTAssertEqual(frame.persons.map { $0.zone?.zone }, [.nearCourt, .outsideCourt])
        XCTAssertEqual(frame.persons.map(\.court), [.inside, .outside])
        var old = try JSONEncoder().encode(frame.persons[0])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json["zone"] = nil
        old = try JSONSerialization.data(withJSONObject: json)
        XCTAssertNil(try JSONDecoder().decode(PlayerFeatures.Person.self, from: old).zone, "a line from before P2 decodes")
    }

    // MARK: The Court Check page (remote confirmation)

    private func pageRow(_ decision: String, geometry: CourtLayout?, decoded: String = "file:copy", at time: String = "2026-11-12T18:04:05.123Z") throws -> String {
        let g = try geometry.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "null"
        return """
        {"recordingId":"rec_01","segment":0,"binding":{"sourceFingerprint":"file:orig","decodedFingerprint":"\(decoded)","frameWidth":960,"frameHeight":540,"orientation":1},
         "setup":{"surface":"indoor","format":"6v6","markings":"lines","answeredAt":"2026-11-12T18:00:00.000Z"},
         "decision":"\(decision)","geometry":\(g),"startedFrom":"net_guided_v1","decidedAt":"\(time)","decidedBy":"u_owner","note":null}
        """
    }

    private func export(_ rows: [String]) throws -> CourtWebImport.Export {
        let text = #"{"artifact":"https://claude.ai/artifact/test","courts":["# + rows.joined(separator: ",") + "]}"
        return try JSONDecoder().decode(CourtWebImport.Export.self, from: Data(text.utf8))
    }

    func testTheOwnersPageConfirmationIsEvidenceAndDraftsOrOtherFootageAreNot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("court-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CourtCalibrationStore(experiment: dir)
        var f = CourtCalibrationFile.new(for: CourtCalibrationFile.Binding(recording(decoded: "file:copy")))
        f.segments[0].proposals = [proposal(layout())]
        try store.save(f)
        let recs = [recording(decoded: "file:copy")]
        let moved = layout().moving(.nearLeft, to: 0.12, 0.1)

        // A draft is never applied; a row made on other footage is refused; neither writes anything.
        let before = try Data(contentsOf: store.url("rec_01"))
        var out = try CourtWebImport.apply(export([pageRow("draft", geometry: moved)]), experiment: dir, recordings: recs, dryRun: false)
        XCTAssertEqual(out.map(\.applied), [false])
        out = try CourtWebImport.apply(export([pageRow("confirmed", geometry: moved, decoded: "file:other")]), experiment: dir, recordings: recs, dryRun: false)
        XCTAssertEqual(out.map(\.applied), [false])
        XCTAssertEqual(try Data(contentsOf: store.url("rec_01")), before)
        XCTAssertEqual(store.confirmedLookup(for: CourtCalibrationFile.Binding(recs[0])).unusable, "court calibration not confirmed by a person")

        // The owner's Confirm: recorded as the page's, at the time it was pressed, and used as evidence.
        out = try CourtWebImport.apply(export([pageRow("confirmed", geometry: moved)]), experiment: dir, recordings: recs, dryRun: false)
        XCTAssertEqual(out.map(\.applied), [true])
        let c = try XCTUnwrap(try store.load("rec_01")?.confirmed(at: 10))
        XCTAssertEqual(c.method, CourtConfirmation.webMethod)
        XCTAssertEqual(c.geometry, moved)
        XCTAssertEqual(c.adjustedRoles, ["nearLeft"], "measured against the proposal it started from")
        XCTAssertEqual(c.confirmedAt, CourtWebImport.date("2026-11-12T18:04:05.123Z"))
        XCTAssertEqual(c.format, "6v6")
        XCTAssertNil(store.confirmedLookup(for: CourtCalibrationFile.Binding(recs[0])).unusable)
        // Importing the same export again changes nothing.
        let after = try Data(contentsOf: store.url("rec_01"))
        out = try CourtWebImport.apply(export([pageRow("confirmed", geometry: moved)]), experiment: dir, recordings: recs, dryRun: false)
        XCTAssertEqual(out.map(\.detail), ["already imported"])
        XCTAssertEqual(try Data(contentsOf: store.url("rec_01")), after)

        // Marking the view as not one court later takes it out of use and keeps the confirmation in history.
        out = try CourtWebImport.apply(export([pageRow("unknown_view", geometry: nil, at: "2026-11-12T19:00:00Z")]), experiment: dir, recordings: recs, dryRun: false)
        XCTAssertEqual(out.map(\.applied), [true])
        let g = try XCTUnwrap(try store.load("rec_01")?.segments.first)
        XCTAssertEqual(g.status, .unknownView)
        XCTAssertEqual(g.history.last?.method, CourtConfirmation.webMethod)
    }
}
