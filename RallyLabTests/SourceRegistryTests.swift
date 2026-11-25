//
//  SourceRegistryTests.swift
//  RallyLabTests
//
//  The source index (RallyLab 2.0, phase 1) is built from project.json, the
//  sessions, validation.json and the ledger, infers nothing, opens no video
//  file, and says which recordings are admitted, withheld, pending or
//  unidentified — with exact duplicates (one file on two cards) and
//  same-source variants (one confirmed sourceId, two files) named.
//

import XCTest
@testable import RallyLab

final class SourceRegistryTests: XCTestCase {
    private var root: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-11-02T20:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try DatasetStore(root: root).prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    static func video(_ id: String?, fingerprint: String?, sourceId: String? = nil, sessionId: String? = nil, venueId: String? = nil,
                      kind: ClipSource.Kind = .file, uploader: String = "", license: String = "Own footage") -> ClipSource {
        ClipSource(kind: kind, origin: kind == .link ? "https://youtu.be/\(id ?? "x")" : "/nowhere/\(id ?? "x").mov", start: 0, length: 300,
                   license: license, title: "", uploader: uploader, clipFile: "/nowhere/cut/\(id ?? "x").mp4", fetchedAt: Date(timeIntervalSince1970: 0),
                   videoId: id, frames: nil, fingerprint: fingerprint, sourceId: sourceId, sessionId: sessionId, venueId: venueId)
    }

    static func clip(_ id: String, number: Int, environment: String = "Beach", camera: String = "End line, ground level", videos: [ClipSource]) -> PlannedClip {
        var c = PlannedClip(id: id, number: number, environment: environment, camera: camera, lighting: "Sunny", orientation: "Landscape", ball: "Any", notes: "")
        c.videos = videos
        return c
    }

    /// Two cards: A with one video, B with the same file again (an exact duplicate) and another cut of a confirmed
    /// source; a tester card; a card with a video not sampled yet; plus sessions, one with no card at all.
    func fixtureProject() -> Project {
        Project(name: "Fixture", createdAt: now, framesPerRally: 2, clips: [
            Self.clip("bch_a", number: 1, videos: [Self.video(nil, fingerprint: "file:aaa", sourceId: "src-a")]),
            Self.clip("bch_b", number: 2, videos: [
                Self.video(nil, fingerprint: "file:aaa"),                              // same file as bch_a
                Self.video("bch_b_v2", fingerprint: "file:bbb", sourceId: "src-a"),   // another cut of src-a
            ]),
            Self.clip("grs_t", number: 3, environment: "Grass", videos: [Self.video(nil, fingerprint: "file:ttt", uploader: "tester", license: "tester contribution")]),
            Self.clip("ind_p", number: 4, environment: "Indoor", videos: [Self.video(nil, fingerprint: "file:ppp")]),   // no session: pending
            Self.clip("ind_h", number: 5, environment: "Indoor", videos: [Self.video(nil, fingerprint: "file:hhh", venueId: "venue-1")]),   // lineage holdout
            Self.clip("ind_h2", number: 6, environment: "Indoor", videos: [Self.video(nil, fingerprint: "file:h2", venueId: "venue-1")]),  // its alias by venue
        ])
    }

    private func session(_ name: String, split: String = "train", marked: Bool? = nil, tracks: [TrackedRally] = []) -> VideoSession {
        var s = VideoSession(name: name, sourcePath: "/nowhere/\(name).mov", split: split, addedAt: now, frames: [])
        s.ralliesMarked = marked
        s.tracks = tracks.isEmpty ? nil : tracks
        return s
    }

    static func rally(done: Bool, machine: Bool = false, isRally: Bool? = nil, checked: Bool = true) -> TrackedRally {
        let box = TrackCandidate(rect: CGRect(x: 0.4, y: 0.4, width: 0.02, height: 0.02), confidence: 0.9)
        let points = (0..<5).map { i in TrackPoint(time: Double(i) / 30, state: .visible, origin: machine ? .auto : .user, box: box, reviewed: checked, unsure: false) }
        var r = TrackedRally(id: UUID(), start: 0, end: 4.0 / 30, points: points, candidates: points.map { _ in [box] }, done: done)
        r.machine = machine ? true : nil
        r.isRally = isRally
        return r
    }

    func inputs(validation: PipelineTuner.ValidationSet? = PipelineTuner.ValidationSet(tune: ["bch_b_v2"], holdout: [], lineageHoldout: ["ind_h"]),
                exposure: [String: [ExposureRecord]]? = ["bch_a": [ExposureRecord(kind: .trainingPackage, ref: "P1", date: nil, note: nil)]]) -> SourceRegistry.Inputs {
        SourceRegistry.Inputs(
            project: fixtureProject(),
            sessions: [session("bch_a", marked: true, tracks: [Self.rally(done: true), Self.rally(done: false, machine: true)]),
                       session("bch_b"), session("bch_b_v2", split: "val"), session("grs_t"), session("ind_h"), session("ind_h2"),
                       session("orphan")],
            validation: validation, exposure: exposure, problems: [],
            hashes: DatasetSplitManifest.Hashes(projectJson: "p", sessions: "s", validationJson: "v"), now: now)
    }

    // MARK: - Tests

    func testIdentityAndDuplicates() {
        let index = SourceRegistry.build(inputs())
        let by = index.byVideo
        XCTAssertEqual(by["bch_a"]?.identityKey, "src:src-a")
        XCTAssertEqual(by["bch_a"]?.identityConfidence, .confirmed)
        XCTAssertEqual(by["bch_b"]?.identityKey, "fp:file:aaa")
        XCTAssertEqual(by["bch_b"]?.identityConfidence, .inferred)
        XCTAssertEqual(by["orphan"]?.identityKey, "name:orphan")
        XCTAssertEqual(by["orphan"]?.identityConfidence, .unknown)
        XCTAssertEqual(by["bch_a"]?.duplicates, ["bch_b"], "one file on two cards")
        XCTAssertEqual(by["bch_b"]?.duplicates, ["bch_a"])
        XCTAssertEqual(by["bch_a"]?.sameSource, ["bch_b_v2"], "another cut of the confirmed source")
        XCTAssertEqual(by["bch_b_v2"]?.sameSource, ["bch_a"])
        XCTAssertEqual(by["bch_a"]?.aliasGroup, by["bch_b"]?.aliasGroup)
        XCTAssertEqual(by["bch_a"]?.aliasGroup, by["bch_b_v2"]?.aliasGroup, "shared file and shared source make one group")
        XCTAssertNotEqual(by["bch_a"]?.aliasGroup, by["grs_t"]?.aliasGroup)
        XCTAssertNil(by["orphan"]?.aliasGroup)
    }

    func testAdmissionAndSplits() {
        let index = SourceRegistry.build(inputs())
        let by = index.byVideo
        XCTAssertEqual(by["bch_a"]?.admission, .admitted)
        XCTAssertEqual(by["bch_a"]?.split, .train)
        XCTAssertEqual(by["bch_b_v2"]?.split, .tune)
        XCTAssertEqual(by["ind_p"]?.admission, .pendingIngest)
        XCTAssertEqual(by["ind_p"]?.hasSession, false)
        XCTAssertEqual(by["orphan"]?.admission, .unidentified)
        XCTAssertEqual(by["ind_h"]?.admission, .withheld)
        XCTAssertEqual(by["ind_h"]?.split, .lineageHoldout)
        XCTAssertEqual(by["ind_h"]?.reservedAs, "listed")
        XCTAssertEqual(by["ind_h2"]?.admission, .withheld, "an alias by confirmed venue is withheld with it")
        XCTAssertEqual(by["ind_h2"]?.split, .lineageHoldout)
        XCTAssertEqual(by["ind_h2"]?.reservedAs, "alias")
        XCTAssertEqual(index.count(.admitted), 4)
        XCTAssertEqual(index.count(.withheld), 2)
        XCTAssertEqual(index.sources.count, 8)
        XCTAssertEqual(by["grs_t"]?.license, "tester contribution")
        XCTAssertEqual(by["grs_t"]?.uploader, "tester")
    }

    func testAnnotationCountsAndExposure() {
        let index = SourceRegistry.build(inputs())
        let a = index.byVideo["bch_a"]!
        XCTAssertTrue(a.ralliesMarked)
        XCTAssertEqual(a.humanLabeledRallies, 1, "a pre-tracked rally nobody checked is not a person's label")
        XCTAssertEqual(a.machineRalliesAwaitingCheck, 1)
        XCTAssertEqual(a.exposure, ["training_package"])
        XCTAssertEqual(index.byVideo["bch_b"]?.exposure, [], "none on record")
        let unknown = SourceRegistry.build(inputs(exposure: nil))
        XCTAssertNil(unknown.byVideo["bch_a"]?.exposure, "a ledger that could not be read is unknown, never none")
    }

    func testFootagePropertiesReachTheIndexAndADerivativeOfAWithheldRecordingIsQuarantined() {
        var i = inputs()
        let now = "2026-11-02T20:00:00Z"
        let replay = FootageProperties.Span(id: UUID(), start: 83, end: 85, traits: [.slowMotion], origin: .confirmed, confidence: nil, source: "BW", note: nil, at: now, by: "BW", rejectedAt: nil)
        i.properties = [
            "bch_a": FootageProperties.File(video: "bch_a", recordingType: .continuous, spans: [replay], updatedAt: now),
            // grs_t is a highlight cut from the lineage-holdout recording, named by its confirmed venue alias's video id.
            "grs_t": FootageProperties.File(video: "grs_t", derivedFrom: .init(parent: "ind_h", relation: .highlight, note: nil), updatedAt: now),
            "bch_b": FootageProperties.File(video: "bch_b", derivedFrom: .init(parent: "fp:file:hhh", relation: .crop, note: nil), updatedAt: now),
        ]
        i.unreadableProperties = ["bch_b_v2": "broken json"]
        let index = SourceRegistry.build(i)
        let by = index.byVideo
        XCTAssertEqual(by["bch_a"]?.recordingType, .continuous)
        XCTAssertEqual(by["bch_a"]?.eligibility[.rallyClassifier].level, .restricted)
        XCTAssertEqual(by["bch_a"]?.eligibility[.netDetector].level, .standard)
        XCTAssertEqual(by["bch_a"]?.eligibility.fullVideoNegatives.level, .restricted)
        XCTAssertEqual(by["grs_t"]?.admission, .quarantined, "a derivative of a withheld recording is not admitted")
        XCTAssertEqual(by["grs_t"]?.derivedFrom, "ind_h")
        XCTAssertEqual(by["grs_t"]?.eligibility[.ballDetector].level, .quarantined)
        XCTAssertEqual(by["bch_b"]?.admission, .quarantined, "the parent named by its file fingerprint is a withheld recording's")
        XCTAssertEqual(by["bch_b_v2"]?.admission, .quarantined, "an unreadable footage-properties record quarantines the recording")
        XCTAssertEqual(by["orphan"]?.eligibility[.netDetector].level, .quarantined, "unidentified")
        XCTAssertEqual(by["ind_h"]?.eligibility[.netDetector].level, .ineligible, "withheld")
        XCTAssertEqual(by["ind_p"]?.eligibility[.netDetector].level, .notAssessed, "pending ingest")
        XCTAssertEqual(index.count(.quarantined), 3)
    }

    /// Codex on #134 (b03c5fe): a derivative of a derivative of a withheld recording was admitted (only the
    /// immediate parent was checked), and a footage-properties record was used by name after the recording
    /// had been replaced under the same id. Derivations are followed through every generation, by video id
    /// and by identity key, ending at a cycle; an ancestor whose record can't be used leaves the ancestry
    /// unknown, which quarantines too. A record for another fingerprint than the card's is not used at all.
    func testDerivationsAreFollowedThroughEveryGenerationAndARecordOfAnotherFileIsNotUsed() {
        let now = "2026-11-02T20:00:00Z"
        func derived(_ video: String, from parent: String, fingerprint: String? = nil) -> FootageProperties.File {
            FootageProperties.File(video: video, sourceFingerprint: fingerprint, derivedFrom: .init(parent: parent, relation: .highlight, note: nil), updatedAt: now)
        }
        var i = inputs()
        i.properties = [
            "grs_t": derived("grs_t", from: "ind_h"),            // withheld original
            "bch_b": derived("bch_b", from: "grs_t"),            // second generation
            "orphan": derived("orphan", from: "bch_b"),          // third
            "ind_p": derived("ind_p", from: "fp:file:ttt"),      // grs_t by its fingerprint, then up the chain
            "bch_a": derived("bch_a", from: "bch_b_v2"),         // a cycle between two admitted recordings
            "bch_b_v2": derived("bch_b_v2", from: "bch_a"),
        ]
        let by = SourceRegistry.build(i).byVideo
        for (video, generations) in [("grs_t", 1), ("bch_b", 2), ("orphan", 3), ("ind_p", 3)] {
            XCTAssertEqual(by[video]?.admission, .quarantined, "\(video): \(generations) generation(s) from ind_h")
            XCTAssertTrue(by[video]?.admissionReason?.contains("withheld recording ind_h") == true, by[video]?.admissionReason ?? "nil")
            for m in TrainingEligibility.Model.allCases { XCTAssertEqual(by[video]?.eligibility[m].level, .quarantined, "\(video) \(m.rawValue)") }
            XCTAssertEqual(by[video]?.eligibility.fullVideoNegatives.level, .quarantined, video)
        }
        XCTAssertEqual(by["bch_a"]?.admission, .admitted, "a cycle with nothing withheld in it ends the walk")
        XCTAssertEqual(by["bch_b_v2"]?.admission, .admitted)

        // Codex on #134 (c5c3555): a reserved name validation.json lists that has no card or session any more is
        // still withheld (the closure keeps listed names), so a derivative of it is quarantined. A parent that is
        // neither in the project nor reserved cannot be checked: the ancestry is unverified and the derivative is
        // quarantined too (owner, 2026-11-03: an unresolvable parent is not verified provenance).
        var g = inputs(validation: PipelineTuner.ValidationSet(tune: ["bch_b_v2"], holdout: ["old"], lineageHoldout: ["ind_h", "gone"]))
        g.properties = ["bch_b": derived("bch_b", from: "gone"), "ind_p": derived("ind_p", from: "old"),
                        "bch_a": derived("bch_a", from: "bch_b"), "grs_t": derived("grs_t", from: "elsewhere")]
        let gone = SourceRegistry.build(g).byVideo
        XCTAssertNil(gone["gone"], "the fixture has no card or session for it")
        XCTAssertEqual(gone["bch_b"]?.admission, .quarantined, "derived from a listed lineage-holdout name that left the project")
        XCTAssertTrue(gone["bch_b"]?.admissionReason?.contains("withheld recording gone") == true, gone["bch_b"]?.admissionReason ?? "nil")
        XCTAssertEqual(gone["ind_p"]?.admission, .quarantined, "derived from a legacy-holdout name that left the project")
        XCTAssertEqual(gone["bch_a"]?.admission, .quarantined, "two generations from it")
        XCTAssertEqual(gone["grs_t"]?.admission, .quarantined, "a parent outside the project and not reserved: unverified")
        XCTAssertTrue(gone["grs_t"]?.admissionReason?.contains("elsewhere, which is not in the project and not reserved") == true, gone["grs_t"]?.admissionReason ?? "nil")
        // The same two generations down: the unresolvable parent of an ancestor is found by the walk.
        var h = inputs()
        h.properties = ["grs_t": derived("grs_t", from: "elsewhere"), "bch_b": derived("bch_b", from: "grs_t")]
        XCTAssertEqual(SourceRegistry.build(h).byVideo["bch_b"]?.admission, .quarantined)

        // An ancestor whose record can't be read: the ancestry is unknown, not clear.
        var j = inputs()
        j.properties = ["bch_b": derived("bch_b", from: "grs_t")]
        j.unreadableProperties = ["grs_t": "broken json"]
        let unknown = SourceRegistry.build(j).byVideo
        XCTAssertEqual(unknown["bch_b"]?.admission, .quarantined)
        XCTAssertTrue(unknown["bch_b"]?.admissionReason?.contains("ancestry cannot be established") == true, unknown["bch_b"]?.admissionReason ?? "nil")
        XCTAssertTrue(unknown["grs_t"]?.admissionReason?.contains("unreadable: broken json") == true, unknown["grs_t"]?.admissionReason ?? "nil")

        // A record of another file: nothing of it is used, and the recording is quarantined until it is characterised again.
        var k = inputs()
        let continuous = FootageProperties.File(video: "bch_a", sourceFingerprint: "file:old", recordingType: .continuous, recordingTypeBy: "BW", recordingTypeAt: now,
                                                spans: [], derivedFrom: .init(parent: "ind_h", relation: .crop, note: nil), updatedAt: now)
        var current = continuous; current.sourceFingerprint = "file:aaa"; current.derivedFrom = nil
        var unidentified = continuous; unidentified.video = "orphan"; unidentified.sourceFingerprint = "file:zzz"; unidentified.derivedFrom = nil
        k.properties = ["bch_a": continuous, "bch_b_v2": { var f = current; f.video = "bch_b_v2"; f.sourceFingerprint = "file:bbb"; return f }(), "orphan": unidentified]
        let replaced = SourceRegistry.build(k).byVideo
        XCTAssertEqual(replaced["bch_a"]?.admission, .quarantined, "the record is the old file's")
        XCTAssertTrue(replaced["bch_a"]?.admissionReason?.contains("recorded for file:old") == true, replaced["bch_a"]?.admissionReason ?? "nil")
        XCTAssertEqual(replaced["bch_a"]?.recordingType, .unknown, "the old file's recording type is not carried forward")
        XCTAssertNil(replaced["bch_a"]?.derivedFrom, "nor its derivation")
        for m in TrainingEligibility.Model.allCases { XCTAssertEqual(replaced["bch_a"]?.eligibility[m].level, .quarantined, m.rawValue) }
        XCTAssertEqual(replaced["bch_a"]?.eligibility.fullVideoNegatives.level, .quarantined)
        XCTAssertEqual(replaced["bch_b_v2"]?.recordingType, .continuous, "a record for the card's own fingerprint is used")
        XCTAssertEqual(replaced["bch_b_v2"]?.eligibility[.netDetector].level, .standard)
        XCTAssertEqual(replaced["orphan"]?.admission, .quarantined, "a record with a fingerprint for a recording that has none cannot be tied to it")
        XCTAssertTrue(replaced["orphan"]?.admissionReason?.contains("no fingerprint") == true, replaced["orphan"]?.admissionReason ?? "nil")
    }

    func testNoValidationFileMeansNothingWithheld() {
        let index = SourceRegistry.build(inputs(validation: nil))
        XCTAssertEqual(index.count(.withheld), 0)
        XCTAssertEqual(index.byVideo["ind_h"]?.admission, .admitted)
    }

    func testLoadReadsTheProjectStrictly() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(fixtureProject()).write(to: root.appendingPathComponent("project.json"))
        let store = DatasetStore(root: root)
        try store.save(session("bch_a", marked: true))
        try store.save(session("ind_h"))
        try #"{"tune":[],"holdout":[],"lineageHoldout":["ind_h"]}"#.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
        try ExposureLog.record(videos: ["bch_a"], kind: .rallyScoring, ref: "R1", note: nil, in: root)
        let index = try SourceRegistry.load(root: root, now: now)
        XCTAssertEqual(index.project, "Fixture")
        XCTAssertEqual(index.byVideo["bch_a"]?.exposure, ["rally_scoring"])
        XCTAssertEqual(index.byVideo["ind_h"]?.admission, .withheld)
        XCTAssertEqual(index.byVideo["ind_h2"]?.admission, .withheld, "a card video with no session is still withheld by alias")
        XCTAssertEqual(index.byVideo["ind_h2"]?.hasSession, false)
        XCTAssertNotNil(index.hashes.projectJson)
        XCTAssertTrue(index.problems.isEmpty)
        // A damaged ledger: the index is built, exposure unknown, the problem said.
        try "{broken".write(to: ExposureLog.url(in: root), atomically: true, encoding: .utf8)
        let damaged = try SourceRegistry.load(root: root, now: now)
        XCTAssertNil(damaged.byVideo["bch_a"]?.exposure)
        XCTAssertEqual(damaged.problems.count, 1)
        // A damaged project.json: no index at all (identities unknown).
        try "{".write(to: root.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SourceRegistry.load(root: root, now: now))
        // Written and read back.
        let url = SourceRegistry.url(in: root, stamp: "test")
        try SourceRegistry.write(index, to: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(SourceRegistry.Index.self, from: Data(contentsOf: url)), index)
    }
}
