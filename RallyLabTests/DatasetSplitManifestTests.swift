//
//  DatasetSplitManifestTests.swift
//  RallyLabTests
//

import XCTest
@testable import RallyLab

final class DatasetSplitManifestTests: XCTestCase {

    // MARK: - Fixtures

    static let day = ISO8601DateFormatter().date(from: "2026-10-20T00:00:00Z")!

    static func source(_ videoId: String?, uploader: String = "Chan", fingerprint: String? = nil,
                       sourceId: String? = nil, sessionId: String? = nil, venueId: String? = nil) -> ClipSource {
        ClipSource(kind: .link, origin: "https://youtu.be/\(videoId ?? "x")", start: 0, length: 300, license: "permission",
                   title: "t", uploader: uploader, clipFile: "/f/\(videoId ?? "x").mp4", fetchedAt: day,
                   videoId: videoId, frames: nil, fingerprint: fingerprint,
                   sourceId: sourceId, sessionId: sessionId, venueId: venueId)
    }

    static func clip(_ id: String, environment: String = "Beach", split: String? = nil, videos: [ClipSource]) -> PlannedClip {
        PlannedClip(id: id, number: 1, environment: environment, camera: "Online", lighting: "Sun", orientation: "Landscape",
                    ball: "Beach", notes: "", split: split, videos: videos, pulledFrom: nil)
    }

    static func session(_ name: String, split: String, marked: Bool = false) -> VideoSession {
        VideoSession(name: name, sourcePath: "/f/\(name).mp4", split: split, addedAt: day, frames: [],
                     rejected: nil, tracks: nil, ralliesMarked: marked ? true : nil, syncedTrackIds: nil,
                     notRallies: nil, fittedTracks: nil, netBox: nil)
    }

    /// Two beach cards (one with three videos, split pinned val; one train),
    /// one grass card auto-split, validation.json naming tune and holdout.
    static func inputs(validation: PipelineTuner.ValidationSet? = PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2"]),
                       previous: DatasetSplitManifest? = nil,
                       discovered: [String: [ExposureRecord]] = [:],
                       extraClips: [PlannedClip] = [],
                       extraSessions: [VideoSession] = []) -> DatasetSplitManifest.Inputs {
        let project = Project(name: "Fixture", createdAt: day, framesPerRally: 40, clips: [
            clip("bch_a", split: "val", videos: [
                source("bch_a", fingerprint: "youtube:A1"),
                source("bch_a_v2", fingerprint: "youtube:A2"),
                source("bch_a_v3", fingerprint: "youtube:A3"),
            ]),
            clip("bch_b", split: "train", videos: [source("bch_b", uploader: "Other", fingerprint: "youtube:B1", sourceId: "src-B")]),
            clip("grs_c", environment: "Grass", split: nil, videos: [
                source("grs_c", uploader: "Grace", fingerprint: "youtube:C1"),
                source("grs_c_v2", uploader: "Grace", fingerprint: "youtube:C2"),
            ]),
        ] + extraClips)
        let sessions = [
            session("bch_a", split: "val", marked: true), session("bch_a_v2", split: "val", marked: true), session("bch_a_v3", split: "val"),
            session("bch_b", split: "train"),
            session("grs_c", split: "train"), session("grs_c_v2", split: "val"),
        ] + extraSessions
        return DatasetSplitManifest.Inputs(project: project, sessions: sessions, validation: validation,
                                           fingerprint: { $0.fingerprint }, previous: previous, discovered: discovered,
                                           hashes: .init(projectJson: "p", sessions: "s", validationJson: "v"),
                                           generator: "test", now: day)
    }

    private func video(_ name: String, in m: DatasetSplitManifest) -> ManifestVideo {
        m.videos.first { $0.video == name }!
    }

    // MARK: - Split derivation

    func testSplitsDeriveFromValidationAndDatasetSplit() throws {
        let m = try DatasetSplitManifest.build(Self.inputs())
        XCTAssertEqual(video("bch_a", in: m).split, .tune)
        XCTAssertEqual(video("bch_a_v2", in: m).split, .legacyHoldout)
        XCTAssertEqual(video("bch_a_v3", in: m).split, .devVal, "val but not in validation.json")
        XCTAssertEqual(video("bch_b", in: m).split, .train)
        XCTAssertEqual(video("grs_c_v2", in: m).split, .devVal)
        XCTAssertEqual(m.videos.map(\.video), m.videos.map(\.video).sorted(), "videos are written in name order")
    }

    func testTuneAndHoldoutMembershipIsRecordedAsExposure() throws {
        let m = try DatasetSplitManifest.build(Self.inputs())
        XCTAssertTrue(video("bch_a", in: m).exposure.contains { $0.kind == .pipelineTune })
        XCTAssertTrue(video("bch_a_v2", in: m).exposure.contains { $0.kind == .pipelineHoldout })
        XCTAssertTrue(video("bch_b", in: m).exposure.isEmpty)
    }

    func testFinalTestWithExposureIsRefused() {
        let validation = PipelineTuner.ValidationSet(tune: [], holdout: [], finalTest: ["bch_a_v3"])
        let discovered = ["bch_a_v3": [ExposureRecord(kind: .testSetScoring, ref: "Scratch-val-20261016", date: nil, note: nil)]]
        XCTAssertThrowsError(try DatasetSplitManifest.build(Self.inputs(validation: validation, discovered: discovered))) { error in
            XCTAssertEqual(error as? DatasetSplitManifest.BuildError, .finalTestExposed(["bch_a_v3"]))
        }
    }

    func testFinalTestWithoutExposureIsAccepted() throws {
        let validation = PipelineTuner.ValidationSet(tune: [], holdout: [], finalTest: ["bch_a_v3"])
        let m = try DatasetSplitManifest.build(Self.inputs(validation: validation))
        XCTAssertEqual(video("bch_a_v3", in: m).split, .finalTest)
        XCTAssertTrue(video("bch_a_v3", in: m).exposure.isEmpty)
    }

    // MARK: - Exposure carry-forward

    func testPreviousExposureCarriesForwardAndMergesWithDiscovered() throws {
        let previous = try DatasetSplitManifest.build(Self.inputs(discovered: [
            "bch_b": [ExposureRecord(kind: .trainingPackage, ref: "pkg-1", date: "2026-10-17", note: nil)],
        ]))
        XCTAssertEqual(video("bch_b", in: previous).exposure.count, 1)
        // The artefact is gone from disk next time; the record must survive via `previous`.
        let next = try DatasetSplitManifest.build(Self.inputs(previous: previous, discovered: [
            "bch_b": [ExposureRecord(kind: .testSetScoring, ref: "scores-2", date: nil, note: nil)],
        ]))
        let kinds = video("bch_b", in: next).exposure.map(\.kind)
        XCTAssertEqual(Set(kinds), [.trainingPackage, .testSetScoring])
        XCTAssertEqual(kinds.count, 2, "no duplicates")
    }

    // MARK: - Provenance

    func testProvenanceOriginsAreNeverPromoted() throws {
        let m = try DatasetSplitManifest.build(Self.inputs())
        let a = video("bch_a", in: m)
        XCTAssertEqual(a.sourceId, .inferred("youtube:A1"), "a fingerprint is a suggestion, not a confirmation")
        XCTAssertEqual(a.sessionId, .unknown)
        XCTAssertEqual(a.venueId, .unknown)
        let b = video("bch_b", in: m)
        XCTAssertEqual(b.sourceId, .confirmed("src-B"))
        XCTAssertEqual(b.cardSplit, "train", "pinned card split is reported")
        XCTAssertNil(video("grs_c", in: m).cardSplit, "auto card")
        XCTAssertEqual(video("grs_c", in: m).surface, "grass")
    }

    func testSessionWithoutCardStillAppears() throws {
        let m = try DatasetSplitManifest.build(Self.inputs(extraSessions: [Self.session("ind_orphan", split: "train")]))
        let orphan = video("ind_orphan", in: m)
        XCTAssertNil(orphan.clipId)
        XCTAssertEqual(orphan.surface, "indoor", "surface falls back to the ID prefix")
        XCTAssertEqual(orphan.sourceId, .unknown)
    }

    // MARK: - Round trip and digest

    func testManifestRoundTrips() throws {
        let m = try DatasetSplitManifest.build(Self.inputs())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("manifest.json")
        try m.write(to: file)
        let again = DatasetSplitManifest.read(from: file)
        XCTAssertEqual(again?.videos, m.videos)
        XCTAssertEqual(again?.schemaVersion, DatasetSplitManifest.currentSchemaVersion)
        XCTAssertTrue(m.markdownSummary().contains("| tune |"))
    }

    /// Same tree, same digest as the shell's
    /// `find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256`
    /// (computed 2026-10-21 for a.txt = "hello\n" and an empty sub/b.txt).
    func testCanonicalDigestMatchesShell() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hello\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        XCTAssertEqual(DatasetSplitManifest.canonicalDigest(ofDirectory: dir),
                       "6020adb0094dcf6652cde8fca8c0c55d0ff1f2aa20dba5b119ced05ce66b5ff3")
    }
}
