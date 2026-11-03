//
//  TrainingEligibilityTests.swift
//  RallyLabTests
//
//  The footage-properties record and the per-model eligibility policy (owner
//  direction of 2026-11-02 on edited footage): the record is read strictly
//  and written atomically; nothing is assessed without a record; a confirmed
//  trait applies the direction's table per model; a proposal restricts and
//  never clears, and never establishes eligibility (Codex on #134: an unknown
//  recording stays not assessed under proposals alone); an unknown trait
//  quarantines; withheld is ineligible; edited or uncertain time never yields
//  ordinary full-video negatives.
//

import XCTest
@testable import RallyLab

final class TrainingEligibilityTests: XCTestCase {
    private var root: URL!
    private let now = "2026-11-02T20:00:00Z"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("te-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func span(_ traits: [FootageProperties.Trait], _ origin: FootageProperties.Origin = .confirmed, start: Double? = nil, end: Double? = nil, rejected: Bool = false) -> FootageProperties.Span {
        FootageProperties.Span(id: UUID(), start: start, end: end, traits: traits, origin: origin, confidence: origin == .proposed ? 0.7 : nil,
                               source: origin == .proposed ? "scanner r1" : "BW", note: nil, at: now, by: "BW", rejectedAt: rejected ? now : nil)
    }

    private func file(_ type: FootageProperties.RecordingType = .unknown, _ spans: [FootageProperties.Span] = [], derivedFrom: FootageProperties.Derivation? = nil) -> FootageProperties.File {
        FootageProperties.File(video: "v", sourceFingerprint: "file:abc", recordingType: type, recordingTypeBy: type == .unknown ? nil : "BW", recordingTypeAt: type == .unknown ? nil : now,
                               spans: spans, derivedFrom: derivedFrom, updatedAt: now)
    }

    private func assess(_ f: FootageProperties.File?, admission: SourceRegistry.Admission = .admitted) -> TrainingEligibility.Assessment {
        TrainingEligibility.assess(admission: admission, properties: f)
    }

    // MARK: - Record

    func testRecordRoundTripStrictReadAndValidation() throws {
        let store = FootageProperties.Store(root: root)
        XCTAssertNil(try store.load("v"))
        let f = file(.edited, [span([.slowMotion, .digitalZoom], start: 83, end: 85.5), span([.replay], .proposed, start: 142, end: 157)],
                     derivedFrom: .init(parent: "src:youtube:abc", relation: .highlight, note: nil))
        try store.save(f)
        XCTAssertEqual(try store.load("v"), f)
        let all = try store.loadAll()
        XCTAssertEqual(all.records["v"], f)
        XCTAssertTrue(all.unreadable.isEmpty)
        // Another schema, an empty span, a span that ends before it starts: refused whole.
        let url = FootageProperties.url(in: root, video: "v")
        try #"{"schemaVersion":2,"video":"v","updatedAt":"t"}"#.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load("v")) { XCTAssertEqual($0 as? FootageProperties.Failure, .unsupportedVersion(2)) }
        var bad = file(.continuous, [span([.replay], start: 10, end: 5)])
        XCTAssertThrowsError(try store.save(bad))
        bad = file(.continuous, [span([], start: 1, end: 2)])
        XCTAssertThrowsError(try store.save(bad))
        try "{broken".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load("v"))
        let damaged = try store.loadAll()
        XCTAssertNil(damaged.records["v"])
        XCTAssertNotNil(damaged.unreadable["v"], "an unreadable record is named, never read as none")
        // A record under one name that names another video is not that recording's.
        try FootageProperties.Store(root: root).save(file(.continuous))
        try FileManager.default.moveItem(at: FootageProperties.url(in: root, video: "v"), to: FootageProperties.url(in: root, video: "w"))
        XCTAssertNotNil(try store.loadAll().unreadable["w"])
    }

    // MARK: - Policy

    func testNothingIsAssessedWithoutARecord() {
        let a = assess(nil)
        for m in TrainingEligibility.Model.allCases { XCTAssertEqual(a[m].level, .notAssessed, m.rawValue) }
        XCTAssertEqual(a.fullVideoNegatives.level, .notAssessed)
        let unknown = assess(file(.unknown))
        XCTAssertEqual(unknown[.rallyClassifier].level, .notAssessed, "a record with nothing confirmed is still unknown")
        XCTAssertEqual(unknown.fullVideoNegatives.level, .notAssessed, "declared completion is not evidence of uninterrupted real time")
    }

    func testContinuousConfirmedIsStandardEverywhere() {
        let a = assess(file(.continuous, [span([.fixedCamera, .normalSpeed])]))
        for m in TrainingEligibility.Model.allCases { XCTAssertEqual(a[m].level, .standard, m.rawValue) }
        XCTAssertEqual(a.fullVideoNegatives.level, .standard)
    }

    func testSlowMotionReplayAndCutsFollowTheTable() {
        let a = assess(file(.continuous, [span([.slowMotion], start: 83, end: 85), span([.replay], start: 142, end: 157)]))
        XCTAssertEqual(a[.rallyClassifier].level, .restricted)
        XCTAssertEqual(a[.ballDetector].level, .restricted)
        XCTAssertTrue(a[.ballDetector].reasons.contains { $0.contains("single frames only") })
        XCTAssertEqual(a[.netDetector].level, .standard, "net geometry is per frame: slow motion and replays are fine when the label is valid")
        XCTAssertEqual(a.fullVideoNegatives.level, .restricted, "a replay is not live-play timing")
        let cut = assess(file(.continuous, [span([.cameraAngleChange], start: 100, end: 100.1)]))
        XCTAssertEqual(cut[.rallyClassifier].level, .restricted)
        XCTAssertEqual(cut[.ballDetector].level, .restricted)
        XCTAssertEqual(cut[.netDetector].level, .standard)
        XCTAssertEqual(cut.fullVideoNegatives.level, .restricted, "a cut is not a rally transition")
    }

    func testDeadTimeRemovedKeepsPositivesAndForbidsNegatives() {
        let a = assess(file(.continuous, [span([.deadTimeRemoved])]))
        XCTAssertEqual(a[.rallyClassifier].level, .standard)
        XCTAssertEqual(a[.ballDetector].level, .standard)
        XCTAssertEqual(a[.netDetector].level, .standard)
        XCTAssertEqual(a.fullVideoNegatives.level, .restricted)
        XCTAssertTrue(a.fullVideoNegatives.reasons.contains { $0.contains("dead time removed") })
    }

    func testEditedRecordingWithoutSpansRestrictsTemporalModelsAndNegatives() {
        let a = assess(file(.edited))
        XCTAssertEqual(a[.rallyClassifier].level, .restricted)
        XCTAssertEqual(a[.ballDetector].level, .restricted)
        XCTAssertEqual(a[.netDetector].level, .standard)
        XCTAssertEqual(a.fullVideoNegatives.level, .restricted)
    }

    func testCameraTraits() {
        let hand = assess(file(.continuous, [span([.handheld])]))
        XCTAssertEqual(hand[.netDetector].level, .restricted, "as the Net labels tab skips handheld recordings")
        XCTAssertEqual(hand[.ballDetector].level, .restricted)
        let pan = assess(file(.continuous, [span([.normalPanning])]))
        for m in TrainingEligibility.Model.allCases { XCTAssertEqual(pan[m].level, .standard, m.rawValue) }
        let zoom = assess(file(.continuous, [span([.digitalZoom], start: 10, end: 20)]))
        XCTAssertEqual(zoom[.netDetector].level, .restricted)
        XCTAssertTrue(zoom[.ballDetector].reasons.contains { $0.contains("crop") })
        XCTAssertEqual(zoom.fullVideoNegatives.level, .standard, "a zoom does not change the time structure")
    }

    func testProposalsRestrictButNeverClearOrQuarantine() {
        let proposed = assess(file(.continuous, [span([.replay], .proposed, start: 1, end: 5)]))
        XCTAssertEqual(proposed[.rallyClassifier].level, .restricted)
        XCTAssertTrue(proposed[.rallyClassifier].reasons.allSatisfy { $0.hasPrefix("proposed, unconfirmed") })
        XCTAssertEqual(proposed.fullVideoNegatives.level, .restricted)
        let unknownProposed = assess(file(.continuous, [span([.unknown], .proposed)]))
        XCTAssertEqual(unknownProposed[.ballDetector].level, .restricted, "a proposal cannot quarantine")
        let unknownConfirmed = assess(file(.continuous, [span([.unknown])]))
        XCTAssertEqual(unknownConfirmed[.ballDetector].level, .quarantined)
        XCTAssertEqual(unknownConfirmed.fullVideoNegatives.level, .quarantined)
        let rejected = assess(file(.continuous, [span([.replay], .proposed, start: 1, end: 5, rejected: true)]))
        XCTAssertEqual(rejected[.rallyClassifier].level, .standard, "a rejected proposal counts for nothing")
        XCTAssertEqual(rejected.fullVideoNegatives.level, .standard)
    }

    /// Codex on #134 (d6a41b7): with the recording type unknown, a proposed `fixedCamera` or
    /// `normalSpeed` span turned every model's verdict from not assessed to standard. A proposal
    /// never establishes eligibility: only a confirmed recording type does. Proposed restrictions
    /// are kept on record under the unassessed verdict, a rejected proposal counts for nothing,
    /// a confirmed unknown trait still quarantines, and the unmarked time of a recording nobody
    /// confirmed continuous is never ordinary negatives, whatever a scanner proposes.
    func testProposalsNeverEstablishEligibilityOfAnUnknownRecording() {
        let models = TrainingEligibility.Model.allCases
        // The reproduced case: a proposal of a trait that imposes nothing.
        for trait in [FootageProperties.Trait.fixedCamera, .normalSpeed, .normalPanning] {
            let a = assess(file(.unknown, [span([trait], .proposed, start: 0, end: 60)]))
            for m in models {
                XCTAssertEqual(a[m].level, .notAssessed, "\(trait.rawValue) proposed on an unknown recording: \(m.rawValue)")
                XCTAssertTrue(a[m].reasons.contains { $0.contains("recording type not confirmed") }, a[m].reasons.joined(separator: "; "))
            }
            XCTAssertEqual(a.fullVideoNegatives.level, .notAssessed, "proposed continuity is not evidence of uninterrupted real time")
        }
        // A proposed restriction is recorded but still establishes nothing.
        let replay = assess(file(.unknown, [span([.replay], .proposed, start: 1, end: 5)]))
        for m in models {
            XCTAssertEqual(replay[m].level, .notAssessed, m.rawValue)
        }
        XCTAssertTrue(replay[.rallyClassifier].reasons.contains { $0.hasPrefix("proposed, unconfirmed") }, "the proposed restriction travels with the verdict")
        XCTAssertEqual(replay.fullVideoNegatives.level, .notAssessed)
        XCTAssertTrue(replay.fullVideoNegatives.reasons.contains { $0.contains("proposed, unconfirmed") })
        let deadTime = assess(file(.unknown, [span([.deadTimeRemoved], .proposed)]))
        XCTAssertEqual(deadTime.fullVideoNegatives.level, .notAssessed, "a proposed dead-time cut neither clears nor assesses")
        // A confirmed span alone does not confirm the recording type: still not assessed, the restriction kept.
        let handheld = assess(file(.unknown, [span([.handheld])]))
        for m in models {
            XCTAssertEqual(handheld[m].level, .notAssessed, m.rawValue)
            XCTAssertTrue(handheld[m].reasons.contains { $0.contains("handheld") })
        }
        // A confirmed unknown trait is known to be wrong: quarantined, for every model and for negatives.
        let unknownTrait = assess(file(.unknown, [span([.unknown])]))
        for m in models { XCTAssertEqual(unknownTrait[m].level, .quarantined, m.rawValue) }
        XCTAssertEqual(unknownTrait.fullVideoNegatives.level, .quarantined)
        let proposedUnknown = assess(file(.unknown, [span([.unknown], .proposed)]))
        for m in models { XCTAssertEqual(proposedUnknown[m].level, .notAssessed, "a proposal cannot quarantine: \(m.rawValue)") }
        // A rejected proposal counts for nothing: the verdict is the bare unknown one.
        let rejected = assess(file(.unknown, [span([.fixedCamera], .proposed, rejected: true), span([.replay], .proposed, start: 1, end: 5, rejected: true)]))
        XCTAssertEqual(rejected, assess(file(.unknown)))
        // A person's confirmation establishes eligibility; a proposal of a harmless trait then changes nothing,
        // a proposed restriction restricts (never clears), and a confirmed restriction applies the table.
        let confirmed = assess(file(.continuous, [span([.fixedCamera], .proposed, start: 0, end: 60)]))
        for m in models { XCTAssertEqual(confirmed[m].level, .standard, m.rawValue) }
        XCTAssertEqual(confirmed.fullVideoNegatives.level, .standard)
        let confirmedWithProposal = assess(file(.continuous, [span([.replay], .proposed, start: 1, end: 5)]))
        XCTAssertEqual(confirmedWithProposal[.rallyClassifier].level, .restricted)
        XCTAssertEqual(confirmedWithProposal[.ballDetector].level, .restricted)
        XCTAssertEqual(confirmedWithProposal[.netDetector].level, .standard)
        let edited = assess(file(.edited, [span([.fixedCamera], .proposed)]))
        XCTAssertEqual(edited[.rallyClassifier].level, .restricted)
        XCTAssertEqual(edited[.netDetector].level, .standard)
        XCTAssertEqual(edited.fullVideoNegatives.level, .restricted)
    }

    func testAdmissionOverridesTheFootage() {
        let f = file(.continuous, [span([.fixedCamera])])
        XCTAssertEqual(assess(f, admission: .withheld)[.ballDetector].level, .ineligible)
        XCTAssertEqual(assess(f, admission: .withheld).fullVideoNegatives.level, .ineligible)
        XCTAssertEqual(assess(f, admission: .quarantined)[.netDetector].level, .quarantined)
        XCTAssertEqual(assess(f, admission: .unidentified)[.netDetector].level, .quarantined)
        XCTAssertEqual(assess(f, admission: .pendingIngest)[.netDetector].level, .notAssessed)
        XCTAssertEqual(TrainingEligibility.assess(admission: .admitted, properties: f, unreadableReason: "broken")[.rallyClassifier].level, .quarantined)
    }

    func testVerdictsCombineToTheWorse() {
        let a = TrainingEligibility.Verdict(level: .standard, reasons: [])
        let b = TrainingEligibility.Verdict(level: .restricted, reasons: ["r"])
        let c = TrainingEligibility.Verdict(level: .quarantined, reasons: ["q"])
        XCTAssertEqual(a.combined(b).level, .restricted)
        XCTAssertEqual(b.combined(c).level, .quarantined)
        XCTAssertEqual(c.combined(b).reasons, ["q", "r"])
        // Not assessed is resolved only by something known to be wrong; a restriction folded into it is kept as a reason.
        let unknown = TrainingEligibility.Verdict.notAssessed("x")
        XCTAssertEqual(unknown.combined(b), TrainingEligibility.Verdict(level: .notAssessed, reasons: ["x", "r"]))
        XCTAssertEqual(b.combined(unknown), TrainingEligibility.Verdict(level: .notAssessed, reasons: ["r", "x"]))
        XCTAssertEqual(unknown.combined(a).level, .notAssessed)
        XCTAssertEqual(unknown.combined(c), c)
        XCTAssertEqual(c.combined(unknown), c)
        XCTAssertEqual(unknown.combined(TrainingEligibility.Verdict(level: .ineligible, reasons: ["w"])).level, .ineligible)
        XCTAssertTrue(TrainingEligibility.Level.restricted < .quarantined && TrainingEligibility.Level.quarantined < .ineligible)
    }
}
