//
//  LineagePackageTests.swift
//  RallyLabTests
//
//  A lineage package (D-017/D-018) is chosen from the manifest, never
//  contains a reserved recording or anything sharing its identity, and its
//  preflight fails on any protected clip, frame or stray file.
//

import XCTest
@testable import RallyLab

final class LineagePackageTests: XCTestCase {

    private typealias F = DatasetSplitManifestTests

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("l2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// The base fixture plus a lineage-holdout recording and its same-session training neighbour.
    private func lineageInputs() -> DatasetSplitManifest.Inputs {
        let clips = [
            F.clip("bch_l", split: "val", videos: [F.source("bch_l", uploader: "", fingerprint: "file:L", sessionId: "2026-10-03", venueId: "beach-x")]),
            F.clip("bch_n", split: "train", videos: [F.source("bch_n", uploader: "", fingerprint: "file:N", sessionId: "2026-10-03", venueId: "beach-x")]),
        ]
        let sessions = [F.session("bch_l", split: "val"), F.session("bch_n", split: "train", marked: true)]
        let validation = PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2"], lineageHoldout: ["bch_l"])
        return F.inputs(validation: validation, extraClips: clips, extraSessions: sessions)
    }

    /// As `--package-l2` does: the withheld closure is validation.json's reserved names plus
    /// `holdout`, expanded over every project video (ReservedVideos.lineageWithheldNames).
    private func planned(_ inputs: DatasetSplitManifest.Inputs, withheldClosure: Set<String>? = nil) throws -> LineagePackage.Plan {
        let manifest = try DatasetSplitManifest.build(inputs)
        let audit = DatasetAudit.run(manifest: manifest, now: F.day)
        let sources = Dictionary(uniqueKeysWithValues: (inputs.project?.clips ?? []).flatMap { c in c.videos.map { (c.videoId(of: $0), $0) } })
        let named = (inputs.validation?.reservedAsListed ?? []).union(inputs.validation?.holdout ?? [])
        let closure = ReservedVideos.closure(of: named, over: sources)
        return try LineagePackage.plan(manifest: manifest, audit: audit, withheldClosure: withheldClosure ?? closure, generator: "test", now: F.day)
    }

    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func window(_ clip: String, _ split: String, _ frames: [String]) -> String {
        "{\"clip\":\"\(clip)\",\"split\":\"\(split)\",\"time\":1.0,\"size\":[960,540],\"frames\":[\(frames.map { "\"\($0)\"" }.joined(separator: ","))],\"target\":0,\"balls\":[]}"
    }

    /// A package with one train clip `t` (two frames) and one val clip `v` (one frame).
    private func writeCleanPackage() throws -> URL {
        let dir = root.appendingPathComponent("Fixture-L2-multiframe-20261021-2000")
        try write("t-frame-1", to: "\(dir.lastPathComponent)/frames/t/1000.jpg")
        try write("t-frame-2", to: "\(dir.lastPathComponent)/frames/t/2000.jpg")
        try write("v-frame-1", to: "\(dir.lastPathComponent)/frames/v/1000.jpg")
        try write([window("t", "train", ["frames/t/1000.jpg", "frames/t/2000.jpg"]), window("v", "val", ["frames/v/1000.jpg"])].joined(separator: "\n") + "\n",
                  to: "\(dir.lastPathComponent)/windows.jsonl")
        try write("readme", to: "\(dir.lastPathComponent)/README.txt")
        try write("{}", to: "\(dir.lastPathComponent)/summary.json")
        return dir
    }

    private func plan(eligible: [(String, String)], withheld: [String]) -> LineagePackage.Plan {
        LineagePackage.Plan(lineage: "L2", project: "Fixture", createdAt: F.day, generator: "test",
                            manifestHashes: .init(projectJson: "p", sessions: "s", validationJson: "v"),
                            audit: .init(hard: 0, soft: 0, info: 0),
                            withheld: withheld.map { .init(video: $0, split: .lineageHoldout, reservedAs: "listed", aliasGroup: $0, identities: []) },
                            eligible: eligible.map { .init(video: $0.0, split: $0.1 == "train" ? .train : .devVal, packageSplit: $0.1,
                                                           aliasGroup: $0.0, identities: [], reviewedFrames: 1, ralliesMarked: false) })
    }

    private func failed(_ p: LineagePackage.Preflight) -> Set<String> { Set(p.checks.filter { !$0.passed }.map(\.name)) }

    // MARK: - Plan

    func testPlanWithholdsEveryReservedSplitIncludingAliasesAndLegacyHoldout() throws {
        let plan = try planned(lineageInputs())
        XCTAssertEqual(plan.withheldNames, ["bch_l", "bch_n", "bch_a_v2"], "listed lineage holdout, its session alias, and the legacy holdout")
        XCTAssertEqual(plan.withheld.first { $0.video == "bch_n" }?.reservedAs, "alias")
        XCTAssertEqual(plan.withheld.first { $0.video == "bch_a_v2" }?.split, .legacyHoldout)
        XCTAssertEqual(Set(plan.eligible.filter { $0.packageSplit == "train" }.map(\.video)), ["bch_b", "grs_c"])
        XCTAssertEqual(Set(plan.eligible.filter { $0.packageSplit == "val" }.map(\.video)), ["bch_a", "bch_a_v3", "grs_c_v2"], "tune and dev_val both go to the package's val side")
        XCTAssertTrue(plan.withheld.first { $0.video == "bch_n" }!.identities.contains("ses:2026-10-03"))
        XCTAssertEqual(plan.audit.hard, 0)
        XCTAssertTrue(LineagePackage.markdown(plan).contains("| bch_n | lineage_holdout | alias |"))
    }

    func testPlanRefusesAHardLeak() throws {
        let extra = F.clip("ind_dup", environment: "Indoor", split: "train",
                           videos: [F.source("ind_dup", fingerprint: "youtube:A1")])   // same file as bch_a (val)
        let inputs = F.inputs(extraClips: [extra], extraSessions: [F.session("ind_dup", split: "train")])
        XCTAssertThrowsError(try planned(inputs)) { error in
            guard case LineagePackage.PlanError.hardLeak(let n)? = error as? LineagePackage.PlanError else { return XCTFail("\(error)") }
            XCTAssertGreaterThan(n, 0)
        }
    }

    func testPlanRefusesWhenValidationAndManifestDisagree() throws {
        // validation.json (read on its own) reserves a recording the manifest would package.
        XCTAssertThrowsError(try planned(lineageInputs(), withheldClosure: ["bch_l", "bch_n", "bch_b"])) { error in
            XCTAssertEqual(error as? LineagePackage.PlanError, .reservedButEligible(["bch_b"]))
        }
    }

    func testSessionlessLegacyHoldoutStillWithholdsItsAliasSession() throws {
        // `ghost` is in validation.json `holdout` but has no dataset session, so the manifest has no row
        // for it and the audit cannot see it; its project video shares a confirmed venue with the
        // training session bch_z. The withheld closure (project-wide identities) must catch bch_z.
        let clips = [
            F.clip("ghost", split: "val", videos: [F.source("ghost", uploader: "", fingerprint: "file:G", venueId: "beach-ghost")]),
            F.clip("bch_z", split: "train", videos: [F.source("bch_z", uploader: "", fingerprint: "file:Z", venueId: "beach-ghost")]),
        ]
        let validation = PipelineTuner.ValidationSet(tune: ["bch_a"], holdout: ["bch_a_v2", "ghost"])
        let inputs = F.inputs(validation: validation, extraClips: clips, extraSessions: [F.session("bch_z", split: "train")])
        let manifest = try DatasetSplitManifest.build(inputs)
        XCTAssertEqual(manifest.videos.first { $0.video == "bch_z" }?.split, .train, "the manifest alone would package it")
        XCTAssertFalse(DatasetAudit.run(manifest: manifest, now: F.day).hasHardLeak, "and the audit alone cannot see the sessionless holdout")
        XCTAssertThrowsError(try planned(inputs)) { error in
            XCTAssertEqual(error as? LineagePackage.PlanError, .reservedButEligible(["bch_z"]))
        }
    }

    func testPlanRefusesASharedIdentityBetweenEligibleAndWithheld() throws {
        var manifest = try DatasetSplitManifest.build(lineageInputs())
        // Legacy holdout is not expanded by the reservation closure, so a confirmed venue it shares
        // with a training recording has to be caught by the plan's own closure check.
        for i in manifest.videos.indices where ["bch_a_v2", "bch_b"].contains(manifest.videos[i].video) {
            manifest.videos[i].venueId = .confirmed("beach-shared")
        }
        let empty = DatasetAudit(createdAt: F.day, manifestHashes: manifest.hashes, findings: [])
        XCTAssertThrowsError(try LineagePackage.plan(manifest: manifest, audit: empty, withheldClosure: ["bch_l", "bch_n"], generator: "test", now: F.day)) { error in
            XCTAssertEqual(error as? LineagePackage.PlanError, .sharedIdentity(eligible: "bch_b", withheld: "bch_a_v2", identity: "ven:beach-shared"))
        }
    }

    func testPlanNeedsBothSides() throws {
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: [], holdout: []))
        inputs.sessions = inputs.sessions.map { F.session($0.name, split: "train") }
        let clips = inputs.project!.clips.map { var c = $0; c.split = "train"; return c }
        inputs.project?.clips = clips
        XCTAssertThrowsError(try planned(inputs)) { XCTAssertEqual($0 as? LineagePackage.PlanError, .noVal) }
    }

    // MARK: - Preflight

    func testPreflightPassesACleanPackageAndHashesEveryFile() throws {
        let dir = try writeCleanPackage()
        let p = try LineagePackage.preflight(packageDir: dir, plan: plan(eligible: [("t", "train"), ("v", "val")], withheld: ["w"]),
                                             protectedHashes: ["0000"], now: F.day)
        XCTAssertTrue(p.passed, p.checks.filter { !$0.passed }.map(\.detail).joined(separator: "; "))
        XCTAssertEqual(p.files.map(\.path), ["README.txt", "frames/t/1000.jpg", "frames/t/2000.jpg", "frames/v/1000.jpg", "summary.json", "windows.jsonl"])
        XCTAssertEqual(p.digest, DatasetSplitManifest.canonicalDigest(ofDirectory: dir), "the package digest is the manifest's canonical directory digest")
        XCTAssertEqual(p.files.first { $0.path == "frames/t/1000.jpg" }?.sha256, DatasetSplitManifest.sha256(of: dir.appendingPathComponent("frames/t/1000.jpg")))
        XCTAssertEqual(p.clips, [.init(clip: "t", packageSplit: "train", windows: 1, frames: 2), .init(clip: "v", packageSplit: "val", windows: 1, frames: 1)])
        XCTAssertNotNil(p.windowsSha256)
        let record = LineagePackage.Record(plan: plan(eligible: [("t", "train"), ("v", "val")], withheld: ["w"]), preflight: p)
        let url = root.appendingPathComponent("record.json")
        try LineagePackage.write(record, to: url)
        let back = try LineagePackage.read(from: url)
        XCTAssertEqual(back.preflight.files, p.files)
        XCTAssertEqual(back.plan.withheldNames, ["w"])
        XCTAssertTrue(LineagePackage.markdown(p).contains("PASSED"))
    }

    func testDigestIsStableOnceTheRecordIsEmbedded() throws {
        let dir = try writeCleanPackage()
        let thePlan = plan(eligible: [("t", "train"), ("v", "val")], withheld: ["w"])
        let before = try LineagePackage.preflight(packageDir: dir, plan: thePlan, protectedHashes: [], now: F.day)
        try LineagePackage.write(.init(plan: thePlan, preflight: before), to: dir.appendingPathComponent(LineagePackage.recordFile))
        let after = try LineagePackage.preflight(packageDir: dir, plan: thePlan, protectedHashes: [], now: F.day)
        XCTAssertTrue(after.passed, "the embedded record is an allowed file")
        XCTAssertEqual(after.digest, before.digest, "the record is never hashed into its own digest, so verification after export matches")
        XCTAssertEqual(after.files, before.files)
        // The documented verification: the canonical digest of the folder with l2-manifest.json removed.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(LineagePackage.recordFile))
        XCTAssertEqual(DatasetSplitManifest.canonicalDigest(ofDirectory: dir), before.digest)
    }

    func testPreflightFailsOnAWindowFromAWithheldClip() throws {
        let dir = try writeCleanPackage()
        try write("w-frame", to: "\(dir.lastPathComponent)/frames/w/1000.jpg")
        let lines = try String(contentsOf: dir.appendingPathComponent("windows.jsonl"), encoding: .utf8)
        try write(lines + window("w", "train", ["frames/w/1000.jpg"]) + "\n", to: "\(dir.lastPathComponent)/windows.jsonl")
        let p = try LineagePackage.preflight(packageDir: dir, plan: plan(eligible: [("t", "train"), ("v", "val")], withheld: ["w"]), protectedHashes: [])
        XCTAssertFalse(p.passed)
        XCTAssertEqual(failed(p), ["windows-clips-eligible", "windows-clips-not-withheld", "frame-paths-eligible", "no-stray-files", "frame-dirs-have-windows"])
    }

    func testPreflightFailsOnAStrayFrameFolderEvenWithoutAWindow() throws {
        let dir = try writeCleanPackage()
        try write("w-frame", to: "\(dir.lastPathComponent)/frames/w/1000.jpg")
        try write("note", to: "\(dir.lastPathComponent)/notes.txt")
        let p = try LineagePackage.preflight(packageDir: dir, plan: plan(eligible: [("t", "train"), ("v", "val")], withheld: ["w"]), protectedHashes: [])
        XCTAssertEqual(failed(p), ["no-stray-files", "frame-dirs-have-windows"])
        XCTAssertTrue(p.checks.first { $0.name == "no-stray-files" }!.detail.contains("frames/w/1000.jpg"))
        XCTAssertTrue(p.checks.first { $0.name == "no-stray-files" }!.detail.contains("notes.txt"))
    }

    func testPreflightFailsOnProtectedContentUnderAnyName() throws {
        let dir = try writeCleanPackage()
        let protected = DatasetSplitManifest.sha256(of: dir.appendingPathComponent("frames/t/2000.jpg"))!
        let p = try LineagePackage.preflight(packageDir: dir, plan: plan(eligible: [("t", "train"), ("v", "val")], withheld: ["w"]), protectedHashes: [protected])
        XCTAssertEqual(failed(p), ["no-protected-content"])
        XCTAssertTrue(p.checks.first { $0.name == "no-protected-content" }!.detail.contains("frames/t/2000.jpg"))
    }

    func testPreflightFailsOnWrongSplitMissingFrameAndOneSidedPackage() throws {
        let dir = try writeCleanPackage()
        try write([window("t", "val", ["frames/t/1000.jpg", "frames/t/3000.jpg"]), window("v", "val", ["frames/v/1000.jpg"])].joined(separator: "\n") + "\n",
                  to: "\(dir.lastPathComponent)/windows.jsonl")
        let p = try LineagePackage.preflight(packageDir: dir, plan: plan(eligible: [("t", "train"), ("v", "val")], withheld: ["w"]), protectedHashes: [])
        XCTAssertEqual(failed(p), ["windows-clips-eligible", "frame-files-exist", "both-splits-present"])
    }

    func testPreflightFailsOnAModelWrittenLabel() throws {
        let dir = try writeCleanPackage()
        let pseudo = window("t", "train", ["frames/t/1000.jpg", "frames/t/2000.jpg"]).replacingOccurrences(of: "\"balls\":[]", with: "\"balls\":[],\"pseudo\":[false,true]")
        try write([pseudo, window("v", "val", ["frames/v/1000.jpg"])].joined(separator: "\n") + "\n", to: "\(dir.lastPathComponent)/windows.jsonl")
        try write("{\"machineFrames\": 3}", to: "\(dir.lastPathComponent)/summary.json")
        let p = try LineagePackage.preflight(packageDir: dir, plan: plan(eligible: [("t", "train"), ("v", "val")], withheld: ["w"]), protectedHashes: [])
        XCTAssertEqual(failed(p), ["no-machine-labels"])
        XCTAssertTrue(p.checks.first { $0.name == "no-machine-labels" }!.detail.contains("t"))
        XCTAssertTrue(p.checks.first { $0.name == "no-machine-labels" }!.detail.contains("machineFrames 3"))
    }

    func testPreflightRefusesAMalformedOrMissingWindowsFile() throws {
        let dir = try writeCleanPackage()
        try write("{\"clip\":\"t\"}\n", to: "\(dir.lastPathComponent)/windows.jsonl")
        XCTAssertThrowsError(try LineagePackage.preflight(packageDir: dir, plan: plan(eligible: [("t", "train")], withheld: []), protectedHashes: [])) {
            XCTAssertEqual($0 as? LineagePackage.PreflightError, .malformedWindow(1))
        }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("windows.jsonl"))
        XCTAssertThrowsError(try LineagePackage.preflight(packageDir: dir, plan: plan(eligible: [("t", "train")], withheld: []), protectedHashes: [])) {
            XCTAssertEqual($0 as? LineagePackage.PreflightError, .noWindows(dir.path))
        }
    }

    func testProtectedFrameHashesCoverKeptAndParkedFrames() throws {
        let store = DatasetStore(root: root)
        try write("kept", to: "images/val/w_0001_000.jpg")
        try write("parked", to: "excluded/images/val/w_0002_000.jpg")
        try write("other", to: "images/train/t_0001_000.jpg")
        func frame(_ file: String) -> FrameRecord { FrameRecord(id: UUID(), file: file, time: 1, source: "random", boxes: [], keep: true, reviewed: false) }
        var w = F.session("w", split: "val"); w.frames = [frame("images/val/w_0001_000.jpg"), frame("images/val/w_0002_000.jpg")]
        var t = F.session("t", split: "train"); t.frames = [frame("images/train/t_0001_000.jpg")]
        let hashes = try LineagePackage.protectedFrameHashes(sessions: [w, t], withheld: ["w"], store: store)
        XCTAssertEqual(hashes, [DatasetSplitManifest.sha256(of: root.appendingPathComponent("images/val/w_0001_000.jpg"))!,
                                DatasetSplitManifest.sha256(of: root.appendingPathComponent("excluded/images/val/w_0002_000.jpg"))!])
    }

    func testProtectedFrameHashesAbortWhenAFrameIsMissingOrUnreadable() throws {
        let store = DatasetStore(root: root)
        try write("kept", to: "images/val/w_0001_000.jpg")
        func frame(_ file: String) -> FrameRecord { FrameRecord(id: UUID(), file: file, time: 1, source: "random", boxes: [], keep: true, reviewed: false) }
        var w = F.session("w", split: "val"); w.frames = [frame("images/val/w_0001_000.jpg"), frame("images/val/w_0002_000.jpg")]
        // Missing on both the kept and the parked path.
        XCTAssertThrowsError(try LineagePackage.protectedFrameHashes(sessions: [w], withheld: ["w"], store: store)) {
            XCTAssertEqual($0 as? LineagePackage.PreflightError, .protectedFrameUnreadable(root.appendingPathComponent("excluded/images/val/w_0002_000.jpg").path))
        }
        // Present but unreadable (a folder where the image should be).
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images/val/w_0002_000.jpg"), withIntermediateDirectories: true)
        XCTAssertThrowsError(try LineagePackage.protectedFrameHashes(sessions: [w], withheld: ["w"], store: store)) {
            XCTAssertEqual($0 as? LineagePackage.PreflightError, .protectedFrameUnreadable(root.appendingPathComponent("images/val/w_0002_000.jpg").path))
        }
        // Not withheld: its frames are not required.
        XCTAssertEqual(try LineagePackage.protectedFrameHashes(sessions: [w], withheld: [], store: store), [])
    }
}
