//
//  RallyClassifierExporterTests.swift
//  RallyLabTests
//
//  The rally-classifier dataset (rally_classifier_dataset_v1): a synthetic project on disk, synthetic detector
//  evidence, the whole operation — guards, plan, steps, labels, baseline, preflight, the repository's validator,
//  the ledger — and every refusal: a closure that proves nothing, a stale manifest, a withheld or shared identity,
//  an unconfirmed footage type, missing footage, a validator that refuses or can't run, a ledger that can't be
//  written. Nothing here runs the detector on a real video.
//

import CoreGraphics
import CoreMedia
import XCTest
@testable import RallyLab

final class RallyClassifierExporterTests: XCTestCase {

    private typealias X = RallyClassifierExporter
    private typealias F = DatasetSplitManifestTests

    private var base: URL!
    private var root: URL!
    private var out: URL!
    private let now = ISO8601DateFormatter().date(from: "2026-11-07T18:00:00Z")!
    private let at = "2026-11-07T17:00:00Z"
    /// The repository's validator, in this source tree.
    private let validator = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/rally_classifier/validate_dataset.py")

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rcx-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Fixture", isDirectory: true)
        out = base.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("manifests").path)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixture

    private struct Spec {
        var name: String
        var split = "train"
        var type: FootageProperties.RecordingType? = .continuous
        var marked = true
        var sessionId: String? = nil
        var spans: [FootageProperties.Span] = []
        var cuts: [CutRange]? = nil
        var marks: [RallyMarkRecord] = [
            RallyMarkRecord(startTime: 5, endTime: 12, kind: .rally, contacts: nil),
            RallyMarkRecord(startTime: 20, endTime: 31, kind: nil, contacts: nil),
            RallyMarkRecord(startTime: 34, endTime: 36, kind: .missedServe, contacts: nil),
            RallyMarkRecord(startTime: 40, endTime: 48, kind: .rally, contacts: nil),
        ]
    }

    private let rallyTimes: [(Double, Double)] = [(5, 12), (20, 31), (40, 48)]

    private func footage(_ name: String) -> URL { root.appendingPathComponent("footage/\(name).mp4") }

    /// A project on disk: a card and a session per recording, the footage file, its marks, its footage type; the
    /// withheld `bch_w` (lineage holdout) and whatever `validation` names; then the split manifest, as `--manifest` writes it.
    private func project(_ specs: [Spec], withheld: [String] = ["bch_w"], withheldSessionId: String? = nil, manifest: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        let store = DatasetStore(root: root)
        try store.prepare()
        var clips: [PlannedClip] = []
        let all = specs + withheld.map { Spec(name: $0, split: "val", sessionId: withheldSessionId) }
        for (n, s) in all.enumerated() {
            try Data("footage of \(s.name)".utf8).write(to: footage(s.name))
            let src = ClipSource(kind: .link, origin: "https://youtu.be/\(s.name)", start: 0, length: 60, license: "permission",
                                 title: s.name, uploader: "up\(n)", clipFile: footage(s.name).path, fetchedAt: F.day,
                                 videoId: s.name, frames: nil, fingerprint: "youtube:\(s.name)", sourceId: nil, sessionId: s.sessionId, venueId: nil)
            clips.append(PlannedClip(id: s.name, number: n + 1, environment: s.name.hasPrefix("grs") ? "Grass" : s.name.hasPrefix("ind") ? "Indoor" : "Beach",
                                     camera: "End line, raised", lighting: "Sun", orientation: "Landscape", ball: "Beach", notes: "",
                                     split: s.split, videos: [src], pulledFrom: nil))
            var session = VideoSession(name: s.name, sourcePath: footage(s.name).path, split: s.split, addedAt: F.day, frames: [])
            session.ralliesMarked = s.marked ? true : nil
            session.cuts = s.cuts
            try store.save(session)
            try JSONEncoder().encode(s.marks).write(to: RallyMarkModel.labelsURL(for: footage(s.name)))
            if let type = s.type {
                try FootageProperties.Store(root: root).save(FootageProperties.File(video: s.name, sourceFingerprint: "youtube:\(s.name)", recordingType: type,
                                                                                    recordingTypeBy: "BW", recordingTypeAt: at, spans: s.spans, updatedAt: at))
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: "Fixture", createdAt: F.day, framesPerRally: 2, clips: clips)).write(to: root.appendingPathComponent("project.json"))
        try fm.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["tune": [String](), "holdout": [String](), "lineageHoldout": withheld])
            .write(to: PipelineTuner.ValidationSet.file(in: root))
        if manifest { try writeManifest() }
    }

    private func writeManifest() throws {
        let sessions = try DatasetStore(root: root).loadSessionsStrict()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(contentsOf: root.appendingPathComponent("project.json")))
        let inputs = DatasetSplitManifest.Inputs(project: project, sessions: sessions, validation: try PipelineTuner.ValidationSet.loadStrict(from: root),
                                                 fingerprint: { $0.fingerprint }, previous: nil, discovered: [:],
                                                 hashes: X.currentHashes(root), generator: "test", now: now)
        let manifest = try DatasetSplitManifest.build(inputs)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifest.write(to: manifestURL)
    }

    private var manifestURL: URL { root.appendingPathComponent("manifests/manifest.json") }

    private func options(_ name: String = "Fixture-rc-1", resume: URL? = nil, validator: URL? = nil, python: String = "python3") -> X.Options {
        var o = X.Options(name: name, out: out, resume: resume, validator: validator ?? self.validator, codeSha: String(repeating: "a", count: 40), tool: "test", now: now)
        o.python = python
        return o
    }

    /// 60 s at 30 Hz: the ball in flight inside the rallies (a bouncing arc above the net), nothing between.
    private func evidence(duration: Double = 60) -> X.Evidence {
        let net = DetectedNet(box: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1), confidence: 0.8)
        var frames: [VideoProcessor.FrameEvidence] = []
        var t = 0.0
        while t < duration {
            let inRally = rallyTimes.contains { $0.0 <= t && t < $0.1 }
            let y = 0.7 + 0.2 * abs(sin(t * .pi))
            let point = CGPoint(x: 0.5, y: y)
            let detection = VideoProcessor.BallDetection(bbox: CGRect(x: 0.49, y: y - 0.01, width: 0.02, height: 0.02), confidence: 0.9, isOffCourt: false)
            let candidate = VideoProcessor.TrackCandidate(id: UUID(), point: point, score: 1, isProjectile: true, isSelected: true, isCourtExcluded: false,
                                                          ballSize: 0.02, roiRadius: 0.05, rSquared: 0.95, gravitySignature: 0.8, movementType: nil, rejectionReason: nil)
            frames.append(VideoProcessor.FrameEvidence(time: t, hasBall: inRally, isProjectile: inRally, detections: inRally ? [detection] : [],
                                                       trackPoint: inRally ? point : nil, rSquared: inRally ? 0.95 : nil, gravitySignature: inRally ? 0.8 : nil,
                                                       movementType: nil, rejectionReason: nil, candidates: inRally ? [candidate] : [], detectedNet: net, upright: true))
            t += 1.0 / 30
        }
        return X.Evidence(frames: frames, duration: duration, frameRate: 30, aspect: 16.0 / 9)
    }

    /// The evidence source, counting the recordings it was asked for.
    private final class Calls { var names: [String] = [] }

    private func source(_ calls: Calls, failing: String? = nil, before: (() throws -> Void)? = nil) -> X.EvidenceSource {
        let ev = evidence()
        return { session, _ in
            calls.names.append(session.name)
            try before?()
            if session.name == failing { throw X.Failure.unreadable("synthetic detector failure on \(session.name)") }
            return ev
        }
    }

    private func ledger() throws -> [DatasetSplitManifest.ExposureLogRow] { try ExposureLog.readStrict(in: root) }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    // MARK: - The whole operation

    func testASyntheticProjectExportsADatasetTheValidatorAccepts() async throws {
        let replay = FootageProperties.Span(id: UUID(), start: 50, end: 55, traits: [.replay], origin: .proposed, confidence: 0.7, source: "scan",
                                            note: nil, at: at, by: "scan", rejectedAt: nil)
        try project([Spec(name: "bch_a", cuts: [CutRange(start: 0.3, end: 1.0)]),
                     Spec(name: "grs_b", split: "val", type: .edited),
                     Spec(name: "bch_c", spans: [replay]),
                     Spec(name: "ind_u", type: nil)])
        let calls = Calls()
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
        XCTAssertEqual(result.recordings.sorted(), ["bch_a", "bch_c", "grs_b"])
        XCTAssertEqual(calls.names.sorted(), ["bch_a", "bch_c", "grs_b"], "the detector ran on the exported recordings only")
        XCTAssertEqual(result.leftOut.map(\.video), ["ind_u"], "an unconfirmed footage type is not assessed: left out")
        XCTAssertTrue(result.leftOut[0].reason.contains("not_assessed"), result.leftOut[0].reason)
        XCTAssertEqual(result.dataset, out.appendingPathComponent("Fixture-rc-1", isDirectory: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(".staging-Fixture-rc-1").path))

        // The validator ran and passed; run it again here (no --withheld) for its report.
        let report = try json(root.appendingPathComponent("manifests/rally-classifier/20261107-180000-validation.json"))
        XCTAssertEqual(report["ok"] as? Bool, true, "\(report["errors"] ?? "")")
        let again = await ToolEnvironment.run("python3", [validator.path, result.dataset.path])
        XCTAssertEqual(again.status, 0, again.lines.joined(separator: "\n"))

        // The manifest: the closure, the committed config as r0, both variants, the recordings as the contract has them.
        let m = try json(result.dataset.appendingPathComponent("dataset-manifest.json"))
        XCTAssertEqual(m["pipelineConfigSha256"] as? String, ProcessorConfig().canonicalSHA256)
        let withheld = try XCTUnwrap(m["withheld"] as? [String: Any])
        XCTAssertEqual(withheld["names"] as? [String], ["bch_w"])
        XCTAssertEqual(withheld["fingerprints"] as? [String], ["youtube:bch_w"])
        let variants = try XCTUnwrap((m["baseline"] as? [String: Any])?["variants"] as? [[String: Any]])
        XCTAssertEqual(variants.map { $0["name"] as? String }, ["r0", "r0_prime"])
        let recs = try XCTUnwrap(m["recordings"] as? [[String: Any]])
        let a = try XCTUnwrap(recs.first { $0["recordingId"] as? String == "bch_a" })
        XCTAssertTrue(a.keys.contains("sourceId") && a["sourceId"] is NSNull, "a null is written, not left out")
        XCTAssertEqual((a["eligibility"] as? [String: Any])?["fullVideoNegatives"] as? String, "standard")
        XCTAssertEqual((a["rallies"] as? [[String: Any]])?.map { $0["provenance"] as? String }, ["legacy_declared", "legacy_nil_kind", "legacy_declared"])
        XCTAssertEqual((a["excludedSpans"] as? [[String: Any]])?.map { $0["kind"] as? String }, ["missedServe"])
        XCTAssertEqual((a["cutRanges"] as? [[String: Any]])?.map { [$0["startTick"] as? Int, $0["endTick"] as? Int] }, [[180, 600]])
        let b = try XCTUnwrap(recs.first { $0["recordingId"] as? String == "grs_b" })
        XCTAssertEqual(b["restrictedUse"] as? Bool, true)
        XCTAssertEqual(((b["labelCounts"] as? [String: Int])?["NON_RALLY"]), 0, "an edited recording's unmarked time is UNKNOWN, never a negative")
        XCTAssertGreaterThan(((a["labelCounts"] as? [String: Int])?["NON_RALLY"]) ?? 0, 0)
        let c = try XCTUnwrap(recs.first { $0["recordingId"] as? String == "bch_c" })
        XCTAssertEqual((c["timeBreakingSpans"] as? [[String: Any]])?.map { $0["trait"] as? String }, ["replay"], "a proposed replay restricts like a confirmed one")

        // The ledger: one training_package row per exported recording, none for the rest.
        let rows = try ledger()
        XCTAssertEqual(Set(rows.filter { $0.kind == .trainingPackage }.map(\.video)), ["bch_a", "bch_c", "grs_b"])
        XCTAssertTrue(rows.allSatisfy { $0.ref == "--export-rally-classifier-dataset Fixture-rc-1" })
        // The plan was written first and is on record.
        let plan = try json(root.appendingPathComponent("manifests/rally-classifier/20261107-180000-plan.json"))
        XCTAssertEqual(plan["included"] as? [String], ["bch_a", "bch_c", "grs_b"])
    }

    func testEveryStoredBaselineClipIsReproducedByTheContractsPaddingFromItsPreMergeRaws() async throws {
        try project([Spec(name: "bch_a")])
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        let file = result.dataset.appendingPathComponent("baseline/bch_a.json")
        let script = """
        import json, sys, importlib.util
        spec = importlib.util.spec_from_file_location("v", sys.argv[1]); v = importlib.util.module_from_spec(spec); spec.loader.exec_module(v)
        m = json.load(open(sys.argv[2])); b = json.load(open(sys.argv[3]))
        rec = m["recordings"][0]; dur = round(rec["durationSec"] * 600)
        n = 0
        for var in m["baseline"]["variants"]:
            clips = b["variants"][var["name"]]
            raws = [(q["startTick"], q["endTick"]) for c in clips for q in c["rawSpans"]]
            port = v.pad_and_merge(raws, var["settings"], dur)
            want = [(c["startTick"], c["endTick"], [(q["startTick"], q["endTick"]) for q in c["rawSpans"]]) for c in clips]
            got = [(c["startTick"], c["endTick"], [(q["startTick"], q["endTick"]) for q in c["rawSpans"]]) for c in port]
            assert got == want, (var["name"], got, want)
            n += len(clips)
        print(n)
        """
        let scriptURL = base.appendingPathComponent("parity.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let run = await ToolEnvironment.run("python3", [scriptURL.path, validator.path, result.dataset.appendingPathComponent("dataset-manifest.json").path, file.path])
        XCTAssertEqual(run.status, 0, run.lines.joined(separator: "\n"))
        XCTAssertGreaterThan(Int(run.lines.last ?? "") ?? 0, 0, "the synthetic evidence gave the decider clips to compare")
    }

    // MARK: - Refusals before any video is read

    func testAnEmptyClosureIsRefusedAndNoVideoIsRead() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val")], withheld: [])
        let calls = Calls()
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
            XCTFail("exported with an empty closure")
        } catch let f as X.Failure { XCTAssertEqual(f, .emptyClosure) }
        XCTAssertEqual(calls.names, [])
        XCTAssertEqual(try ledger(), [])
    }

    func testAStaleManifestIsRefused() async throws {
        try project([Spec(name: "bch_a")])
        var s = try XCTUnwrap(try DatasetStore(root: root).loadSessionsStrict().first { $0.name == "bch_a" })
        s.cuts = [CutRange(start: 1, end: 2)]       // a session changed after the manifest was built
        try DatasetStore(root: root).save(s)
        let calls = Calls()
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
            XCTFail("exported from a stale manifest")
        } catch let f as X.Failure {
            guard case .staleManifest = f else { return XCTFail("\(f)") }
        }
        XCTAssertEqual(calls.names, [])
    }

    func testARecordingSharingAnIdentityWithAWithheldOneIsNeverExported() async throws {
        // bch_n shares a confirmed session with the withheld bch_w: it is withheld as its alias, and never read.
        try project([Spec(name: "bch_a"), Spec(name: "bch_n", sessionId: "2026-10-03")], withheldSessionId: "2026-10-03")
        let calls = Calls()
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
        XCTAssertEqual(result.recordings, ["bch_a"])
        XCTAssertFalse(calls.names.contains("bch_n"))
        let m = try json(result.dataset.appendingPathComponent("dataset-manifest.json"))
        XCTAssertEqual((m["withheld"] as? [String: Any])?["names"] as? [String], ["bch_n", "bch_w"])
    }

    func testTheIsolationRefusesASharedIdentityAndADisagreeingClosure() throws {
        // The shared guard (LineagePackage.isolation) on a manifest whose rows disagree with the closure.
        var inputs = F.inputs(validation: PipelineTuner.ValidationSet(tune: [], holdout: [], lineageHoldout: ["bch_b"]))
        inputs.sessions = inputs.sessions.map { s in var s = s; s.ralliesMarked = true; return s }
        let manifest = try DatasetSplitManifest.build(inputs)
        let audit = DatasetAudit.run(manifest: manifest, now: F.day)
        XCTAssertThrowsError(try LineagePackage.isolation(manifest: manifest, audit: audit, withheldClosure: ["bch_b", "grs_c"])) { error in
            XCTAssertEqual(error as? LineagePackage.PlanError, .reservedButEligible(["grs_c"]))
        }
        var shared = manifest
        if let i = shared.videos.firstIndex(where: { $0.video == "grs_c" }), let w = shared.videos.first(where: { $0.video == "bch_b" }) {
            shared.videos[i].fingerprint = w.fingerprint
        }
        XCTAssertThrowsError(try LineagePackage.isolation(manifest: shared, audit: audit, withheldClosure: ["bch_b"])) { error in
            guard case .sharedIdentity(let e, let w, _) = error as? LineagePackage.PlanError else { return XCTFail("\(error)") }
            XCTAssertEqual([e, w], ["grs_c", "bch_b"])
        }
    }

    func testMissingFootageIsRefusedAfterThePlanIsWritten() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val")])
        try FileManager.default.removeItem(at: footage("grs_b"))
        let calls = Calls()
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
            XCTFail("exported without footage")
        } catch let f as X.Failure { XCTAssertEqual(f, .footageMissing(["grs_b"])) }
        XCTAssertEqual(calls.names, [])
        let plan = try json(root.appendingPathComponent("manifests/rally-classifier/20261107-180000-plan.json"))
        XCTAssertEqual(plan["footageMissing"] as? [String], ["grs_b"])
    }

    func testRallyMarksInsideACutAreAnErrorTheRecordingIsLeftOut() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "bch_x", cuts: [CutRange(start: 10, end: 14)])])
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        XCTAssertEqual(result.recordings, ["bch_a"])
        XCTAssertTrue(result.leftOut.first { $0.video == "bch_x" }?.reason.contains("overlaps a cut range") == true)
    }

    // MARK: - Refusals at the end: nothing left behind, no ledger row

    func testAValidatorRefusalLeavesNoFolderAndNoLedgerRow() async throws {
        try project([Spec(name: "bch_a")])
        let fake = base.appendingPathComponent("refuse.py")
        try "import json; print(json.dumps({'ok': False, 'errors': ['synthetic refusal'], 'warnings': [], 'info': {}})); raise SystemExit(1)\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(validator: fake), evidence: source(Calls()))
            XCTFail("exported past a validator refusal")
        } catch let f as X.Failure { XCTAssertEqual(f, .validationFailed(["synthetic refusal"])) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "no dataset, no staging folder, no journal")
        XCTAssertEqual(try ledger(), [])
    }

    func testNoPythonMeansNoDataset() async throws {
        try project([Spec(name: "bch_a")])
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(python: "python3-not-installed"), evidence: source(Calls()))
            XCTFail("exported unvalidated")
        } catch let f as X.Failure {
            guard case .validatorUnavailable = f else { return XCTFail("\(f)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
        XCTAssertEqual(try ledger(), [])
    }

    func testALedgerThatCantBeWrittenFailsTheExportAndLeavesNoDataset() async throws {
        try project([Spec(name: "bch_a")])
        let manifests = root.appendingPathComponent("manifests")
        // Once the plan is written (the detector runs after it), the ledger's folder becomes read-only.
        let lock = { try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: manifests.path) }
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls(), before: lock))
            XCTFail("exported without a ledger row")
        } catch {
            XCTAssertTrue(error is ExposureLog.LogError, "\(error)")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: manifests.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
        XCTAssertEqual(try ledger(), [])
    }

    // MARK: - Resume

    func testARunCutShortKeepsItsFinishedRecordingsForResume() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val")])
        let first = Calls()
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(first, failing: "grs_b"))
            XCTFail("the detector failed and the export went on")
        } catch {}
        let staging = out.appendingPathComponent(".staging-Fixture-rc-1", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("steps/bch_a.jsonl").path))
        XCTAssertEqual(try ledger(), [], "nothing recorded for a dataset that does not exist")
        // A fresh run refuses the leftover; a resume keeps bch_a and runs grs_b only.
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
            XCTFail("overwrote a staging folder")
        } catch let f as X.Failure { XCTAssertEqual(f, .stagingExists(staging)) }
        let second = Calls()
        var o = options(resume: staging)
        o.now = now.addingTimeInterval(60)
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: o, evidence: source(second))
        XCTAssertEqual(second.names, ["grs_b"])
        XCTAssertEqual(result.reused, ["bch_a"])
        XCTAssertEqual(result.recordings, ["bch_a", "grs_b"])
    }

    func testAResumeIsRefusedWhenTheCodeChanged() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val")])
        _ = try? await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls(), failing: "grs_b"))
        let staging = out.appendingPathComponent(".staging-Fixture-rc-1", isDirectory: true)
        var o = options(resume: staging)
        o.codeSha = String(repeating: "b", count: 40)
        o.now = now.addingTimeInterval(60)
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: o, evidence: source(Calls()))
            XCTFail("resumed with other code")
        } catch let f as X.Failure {
            guard case .resumeMismatch = f else { return XCTFail("\(f)") }
        }
    }

    // MARK: - Steps, labels, segments, features

    func testTheFeatureRowMapsTheEvidence() {
        let net = DetectedNet(box: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1), confidence: 0.8)
        let selected = VideoProcessor.TrackCandidate(id: UUID(), point: CGPoint(x: 0.3, y: 0.75), score: 1, isProjectile: true, isSelected: true,
                                                     isCourtExcluded: false, ballSize: 0.03, roiRadius: 0.05, rSquared: -0.2, gravitySignature: 0.6,
                                                     movementType: nil, rejectionReason: nil)
        let other = VideoProcessor.TrackCandidate(id: UUID(), point: .zero, score: 0, isProjectile: false, isSelected: false, isCourtExcluded: true,
                                                  ballSize: 0.01, roiRadius: 0.05, rSquared: nil, gravitySignature: nil, movementType: nil, rejectionReason: "slow")
        let frame = VideoProcessor.FrameEvidence(
            time: 2.0, hasBall: true, isProjectile: true,
            detections: [.init(bbox: CGRect(x: 0.29, y: 0.74, width: 0.02, height: 0.02), confidence: 0.8, isOffCourt: false),
                         .init(bbox: CGRect(x: 0.9, y: 0.5, width: 0.02, height: 0.02), confidence: 0.95, isOffCourt: true)],
            trackPoint: CGPoint(x: 0.3, y: 0.75), rSquared: -0.2, gravitySignature: 0.6, movementType: nil, rejectionReason: nil,
            candidates: [selected, other], detectedNet: net, upright: true)
        let row = X.featureRow(frame, previous: 1.95, net: net, serve: (true, 1.2))
        XCTAssertEqual(row.count, X.features.count)
        XCTAssertEqual(row[0]!, 0.05, accuracy: 1e-9)                   // dt
        XCTAssertEqual(row[1], 1); XCTAssertEqual(row[2], 1); XCTAssertEqual(row[3], 2)
        XCTAssertEqual(row[4]!, 0.95, accuracy: 1e-6)                   // the raw peak of every kept detection
        XCTAssertEqual(row[5]!, 0.75, accuracy: 1e-9)                   // the decider's ballY: the selected track
        XCTAssertEqual(row[9]!, 0.03, accuracy: 1e-9)
        XCTAssertEqual(row[10], 0, "r² below 0 is clamped into the unit column")
        XCTAssertEqual(row[12], 2); XCTAssertEqual(row[13], 1); XCTAssertEqual(row[14], 1)
        XCTAssertEqual(row[15]!, 0.25, accuracy: 1e-6)                  // y − net top (0.5)
        XCTAssertEqual(row[16], 1); XCTAssertEqual(row[17], 1.2)
        // No track, no net, no serve: the nullable columns are null, the counts zero.
        let empty = VideoProcessor.FrameEvidence(time: 0, hasBall: false, isProjectile: false, detections: [], trackPoint: nil, rSquared: nil,
                                                 gravitySignature: nil, movementType: nil, rejectionReason: nil, candidates: [], detectedNet: nil)
        let blank = X.featureRow(empty, previous: nil, net: nil, serve: (false, nil))
        XCTAssertEqual(blank.map { $0 == nil }, [true, false, false, false, true, true, false, true, true, true, true, true, false, false, false, true, false, true])
    }

    func testLabelsFollowTheContractsPrecedenceAndASpanBetweenTwoFramesBreaksTheSegment() {
        let ignore = X.tick(X.boundaryIgnoreSec)
        let l = X.LabelInputs(rallies: [X.RallyDTO(rallyId: nil, startTick: 6000, endTick: 9000, kind: "rally", provenance: "legacy_declared",
                                                    contactUncertaintyTicks: nil, deadUncertaintyTicks: nil)],
                              excluded: [X.SpanDTO(startTick: 12000, endTick: 13000, kind: "missedServe")],
                              cuts: [X.SpanDTO(startTick: 20000, endTick: 20005, kind: nil)], timeBreaking: [], nonRallyActivity: [],
                              negatives: true, ignoreTicks: ignore)
        XCTAssertEqual(X.state(7000, l), .activeRally)
        XCTAssertEqual(X.state(6100, l), .transition)
        XCTAssertEqual(X.state(12500, l), .excluded)
        XCTAssertEqual(X.state(11900, l), .transition, "the band around an excluded span's edge")
        XCTAssertEqual(X.state(15000, l), .nonRally)
        var unknown = l
        unknown.negatives = false
        XCTAssertEqual(X.state(15000, unknown), .unknown)
        // A cut of 5 ticks falls between frames at 19990 and 20010: the boundary test breaks the segment.
        XCTAssertTrue(X.crossesNonFootage(19990, 20010, l))
        XCTAssertFalse(X.crossesNonFootage(20010, 20030, l))
    }

    func testTheClosureHashIsTheValidatorsAndTheConfigHashIsStable() async throws {
        let w = X.Withheld(names: ["b", "a"], sourceIds: ["src:é"], fingerprints: ["youtube:x"])
        let script = "import sys; sys.path.insert(0, sys.argv[1]); import validate_dataset as v; print(v.closure_sha256(['b','a'], ['src:\\u00e9'], ['youtube:x']))"
        let run = await ToolEnvironment.run("python3", ["-c", script, validator.deletingLastPathComponent().path])
        XCTAssertEqual(run.lines.last, w.closureSha256)
        XCTAssertEqual(ProcessorConfig().canonicalSHA256, ProcessorConfig().canonicalSHA256)
        var changed = ProcessorConfig()
        changed.minGapToMerge = 0
        XCTAssertNotEqual(changed.canonicalSHA256, ProcessorConfig().canonicalSHA256)
        XCTAssertEqual(X.variant(named: "r0_prime")?.config.canonicalSHA256 == ProcessorConfig().canonicalSHA256, false)
        XCTAssertTrue(ProcessorConfig().canonicalJSON.hasPrefix("{\"parabolaMinPoints\":4,"), ProcessorConfig().canonicalJSON)
        XCTAssertFalse(ProcessorConfig().canonicalJSON.contains("heatmapModel"))
    }

    // MARK: - The builder's pre-merge raws (C3)

    func testAMergedSegmentKeepsItsPreMergeRawsAndTheirCappedPreRoll() {
        let builder = SegmentBuilder(config: ProcessorConfig())
        func t(_ s: Double) -> CMTime { CMTimeMakeWithSeconds(s, preferredTimescale: 600) }
        builder.appendRaw(start: t(40.0), end: t(41.5))    // short: pre-roll capped at 0.5 s
        builder.appendRaw(start: t(43.5), end: t(45.0))    // short too; the padded gap is 1.0 s ≤ the join
        let built = builder.finalizeWithRaw(until: t(60))
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built[0].parts.map { [$0.start.seconds, CMTimeRangeGetEnd($0).seconds] }, [[40.0, 41.5], [43.5, 45.0]])
        XCTAssertEqual(built[0].padded.start.seconds, 39.5, accuracy: 1e-9, "padded from the short raw, not from the 5 s union (which would pre-roll 2 s)")
        XCTAssertEqual(built[0].raw.start.seconds, 40.0, accuracy: 1e-9)
        XCTAssertEqual(CMTimeRangeGetEnd(built[0].raw).seconds, 45.0, accuracy: 1e-9)
    }
}
