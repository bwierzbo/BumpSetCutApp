//
//  RallyClassifierExporterTests.swift
//  RallyLabTests
//
//  The rally-classifier dataset (rally_classifier_dataset_v1, labels rally_activity_truth_v2): a synthetic project
//  on disk, synthetic detector evidence, the whole operation — guards, plan, steps, labels, baseline, preflight, the
//  repository's validator, the ledger — and every refusal: a closure that proves nothing, a stale manifest, a
//  withheld or shared identity, an unconfirmed footage type, missing footage, a validator that refuses or can't
//  run, a ledger that can't be written. Trusted negatives (G7): unmarked time is NON_RALLY only inside an interval
//  the recording's audit record says clean and that is still unmarked — a record that is absent, void, of edited
//  footage or unreadable gives none. Evidence reuse: a sealed dataset's steps and clips, taken only where proven.
//  The matched baseline r0_no_net_rule. Nothing here runs the detector on a real video.
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
        /// The card's registered fingerprint, when not the link's own.
        var fingerprint: String? = nil
        /// The uploader, when not one of its own.
        var uploader: String? = nil
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
    private func project(_ specs: [Spec], withheld: [String] = ["bch_w"], withheldSessionId: String? = nil, withheldFingerprint: String? = nil,
                         manifest: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("footage"), withIntermediateDirectories: true)
        let store = DatasetStore(root: root)
        try store.prepare()
        var clips: [PlannedClip] = []
        let all = specs + withheld.map { Spec(name: $0, split: "val", sessionId: withheldSessionId, fingerprint: withheldFingerprint) }
        for (n, s) in all.enumerated() {
            try Data("footage of \(s.name)".utf8).write(to: footage(s.name))
            let src = ClipSource(kind: .link, origin: "https://youtu.be/\(s.name)", start: 0, length: 60, license: "permission",
                                 title: s.name, uploader: s.uploader ?? "up\(n)", clipFile: footage(s.name).path, fetchedAt: F.day,
                                 videoId: s.name, frames: nil, fingerprint: s.fingerprint ?? "youtube:\(s.name)", sourceId: nil, sessionId: s.sessionId, venueId: nil)
            clips.append(PlannedClip(id: s.name, number: n + 1, environment: s.name.hasPrefix("grs") ? "Grass" : s.name.hasPrefix("ind") ? "Indoor" : "Beach",
                                     camera: "End line, raised", lighting: "Sun", orientation: "Landscape", ball: "Beach", notes: "",
                                     split: s.split, videos: [src], pulledFrom: nil))
            var session = VideoSession(name: s.name, sourcePath: footage(s.name).path, split: s.split, addedAt: F.day, frames: [])
            session.ralliesMarked = s.marked ? true : nil
            session.cuts = s.cuts
            try store.save(session)
            try JSONEncoder().encode(s.marks).write(to: RallyMarkModel.labelsURL(for: footage(s.name)))
            if let type = s.type {
                try FootageProperties.Store(root: root).save(FootageProperties.File(video: s.name, sourceFingerprint: s.fingerprint ?? "youtube:\(s.name)", recordingType: type,
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
                                                 hashes: .current(of: root), generator: "test", now: now)
        let manifest = try DatasetSplitManifest.build(inputs)
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifest.write(to: manifestURL)
    }

    private var manifestURL: URL { root.appendingPathComponent("manifests/manifest.json") }

    private func options(_ name: String = "Fixture-rc-1", resume: URL? = nil, validator: URL? = nil, python: String = "python3") -> X.Options {
        var o = X.Options(name: name, out: out, resume: resume, validator: validator ?? self.validator, codeSha: String(repeating: "a", count: 40),
                          binarySha: String(repeating: "c", count: 64), tool: "test", now: now)
        o.python = python
        o.duration = { _ in 60 }        // the fixture's footage is not a video: its duration is the synthetic evidence's
        return o
    }

    /// A later export (`minutes` after the fixture's time: its own plan and report), taking evidence from `source`.
    private func reusing(_ source: URL, as name: String, minutes: Double = 1) -> X.Options {
        var o = options(name)
        o.reuseEvidenceFrom = source
        o.now = now.addingTimeInterval(minutes * 60)
        return o
    }

    // MARK: - Fixture: the negative-coverage audit

    /// The fixture's unmarked intervals at a Spec's default marks, in ticks (60 s): what a draw holds for it.
    private let unmarked: [(Int, Int)] = [(0, 3000), (7200, 12000), (18600, 20400), (21600, 24000), (28800, 36000)]

    private enum Look {
        case clean, unreviewed
        case found(CoverageAudit.FindingKind)
    }

    /// A frozen draw holding `name` with the fixture's unmarked intervals, and its audit record beside the footage:
    /// one first review per interval as `looks` says (a clean one played whole at 2×). Returns the record's URL.
    @discardableResult
    private func audit(_ name: String, _ looks: [Look] = [.clean, .clean, .clean, .clean, .clean], reviewedAt: String = "2026-11-14T12:30:00Z",
                       mutate: (inout CoverageAudit.File) -> Void = { _ in }) throws -> URL {
        let content = try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: footage(name).path))
        let drawId = "20261114-120000"
        let draw: [String: Any] = [
            "schemaVersion": CoverageAudit.drawVersion, "drawId": drawId, "dataset": ["name": "Fixture-rc-0", "timescale": 600],
            "recordings": [["recordingId": name, "groupId": name, "contentFingerprint": content, "marksSha256": "marks-at-the-draw", "durationTicks": 36000,
                            "intervals": unmarked.enumerated().map { ["index": $0.offset, "startTick": $0.element.0, "endTick": $0.element.1] },
                            "repeatIndices": [Int]()] as [String: Any]],
        ]
        let draws = CoverageAudit.drawsDirectory(in: root)
        try FileManager.default.createDirectory(at: draws, withIntermediateDirectories: true)
        let drawURL = draws.appendingPathComponent("\(drawId)-\(name)-draw.json")
        try JSONSerialization.data(withJSONObject: draw, options: [.sortedKeys]).write(to: drawURL)
        var file = CoverageAudit.File(recordingId: name, sourceFingerprint: content, drawId: drawId, drawSha256: try XCTUnwrap(DatasetSplitManifest.sha256(of: drawURL)),
                                      datasetName: "Fixture-rc-0", marksSha256: "marks-at-the-review", tool: "test")
        for (i, look) in looks.enumerated() {
            var findings: [CoverageAudit.Finding] = []
            switch look {
            case .unreviewed: continue
            case .clean: break
            case .found(let kind): findings = [CoverageAudit.Finding(kind: kind, note: kind == .uncertain ? "occluded" : nil)]
            }
            file.intervals.append(CoverageAudit.Review(index: i, startTick: unmarked[i].0, endTick: unmarked[i].1, verdict: findings.isEmpty ? .clean : .notClean,
                                                       reviewer: "BW", reviewedAt: reviewedAt, playedAllAtMaxRate: 2, findings: findings))
        }
        mutate(&file)
        let url = CoverageAudit.url(forVideo: footage(name))
        try CoverageAudit.write(file, to: url)
        return url
    }

    /// A dataset's steps for one recording: the tick, the label, and the time and feature columns as written.
    private func steps(_ dataset: URL, _ name: String) throws -> [(tick: Int, y: Int, evidence: String)] {
        try String(contentsOf: dataset.appendingPathComponent("steps/\(name).jsonl"), encoding: .utf8).split(separator: "\n").map { line in
            let step = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let tickAt = try XCTUnwrap(line.range(of: ",\"tick\":")), open = try XCTUnwrap(line.range(of: ",\"f\":[")), close = try XCTUnwrap(line.range(of: "],\"y\":"))
            return (try XCTUnwrap(step["tick"] as? Int), try XCTUnwrap(step["y"] as? Int), String(line[..<tickAt.lowerBound]) + "|" + String(line[open.upperBound..<close.lowerBound]))
        }
    }

    /// The label of the step nearest `second` (the steps are 1/30 s apart).
    private func label(_ steps: [(tick: Int, y: Int, evidence: String)], at second: Double) throws -> X.State {
        let tick = X.tick(second)
        return try XCTUnwrap(X.State(rawValue: try XCTUnwrap(steps.min { abs($0.tick - tick) < abs($1.tick - tick) }).y))
    }

    private func recording(_ dataset: URL, _ name: String) throws -> [String: Any] {
        let recs = try XCTUnwrap(try json(dataset.appendingPathComponent("dataset-manifest.json"))["recordings"] as? [[String: Any]])
        return try XCTUnwrap(recs.first { $0["recordingId"] as? String == name })
    }

    private func audit(of rec: [String: Any]) throws -> [String: Any] { try XCTUnwrap((rec["coverage"] as? [String: Any])?["audit"] as? [String: Any]) }

    private func cleanIntervals(_ rec: [String: Any]) throws -> [[Int]] {
        try XCTUnwrap(try audit(of: rec)["cleanIntervals"] as? [[String: Int]]).map { [$0["startTick"] ?? -1, $0["endTick"] ?? -1] }
    }

    /// The export report written at `stamp` (the fixture's time unless a later export).
    private func report(_ stamp: String = "20261107-180000") throws -> [String: Any] {
        try json(root.appendingPathComponent("manifests/rally-classifier/\(stamp)-export.json"))
    }

    private func negativesNote(_ report: [String: Any], _ name: String) throws -> String? {
        let rows = try XCTUnwrap((report["negatives"] as? [String: Any])?["recordings"] as? [[String: Any]])
        return try XCTUnwrap(rows.first { $0["video"] as? String == name })["note"] as? String
    }

    /// 60 s at 30 Hz: the ball in flight inside the rallies (a bouncing arc above the net), nothing between — every
    /// detection the multi-frame model's, which loaded (`detector`), unless `yolo` says otherwise.
    /// `lowRally`: the rally (by index) whose ball bounces, arc after arc, without once rising above the net's top.
    private func evidence(duration: Double = 60, detector: URL? = ProcessorConfig().heatmapModel, yolo: Bool = false, lowRally: Int? = nil) -> X.Evidence {
        let net = DetectedNet(box: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.1), confidence: 0.8)
        var frames: [VideoProcessor.FrameEvidence] = []
        var t = 0.0
        while t < duration {
            let rally = rallyTimes.firstIndex { $0.0 <= t && t < $0.1 }
            let inRally = rally != nil
            let y = (rally == lowRally && inRally ? 0.15 : 0.7) + 0.2 * abs(sin(t * .pi))
            let point = CGPoint(x: 0.5, y: y)
            let detection = VideoProcessor.BallDetection(bbox: CGRect(x: 0.49, y: y - 0.01, width: 0.02, height: 0.02), confidence: 0.9, isOffCourt: false,
                                                         fromHeatmap: !yolo)
            let candidate = VideoProcessor.TrackCandidate(id: UUID(), point: point, score: 1, isProjectile: true, isSelected: true, isCourtExcluded: false,
                                                          ballSize: 0.02, roiRadius: 0.05, rSquared: 0.95, gravitySignature: 0.8, movementType: nil, rejectionReason: nil)
            frames.append(VideoProcessor.FrameEvidence(time: t, hasBall: inRally, isProjectile: inRally, detections: inRally ? [detection] : [],
                                                       trackPoint: inRally ? point : nil, rSquared: inRally ? 0.95 : nil, gravitySignature: inRally ? 0.8 : nil,
                                                       movementType: nil, rejectionReason: nil, candidates: inRally ? [candidate] : [], detectedNet: net, upright: true))
            t += 1.0 / 30
        }
        return X.Evidence(frames: frames, duration: duration, frameRate: 30, aspect: 16.0 / 9, detector: detector)
    }

    /// The evidence source, counting the recordings it was asked for.
    private final class Calls { var names: [String] = [] }

    private func source(_ calls: Calls, failing: String? = nil, before: (() throws -> Void)? = nil, evidence given: X.Evidence? = nil) -> X.EvidenceSource {
        let ev = given ?? evidence()
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
        try audit("bch_a")          // every unmarked interval of bch_a reviewed clean; bch_c has no audit record
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
        // The detector is named by the model package the build compiled, not by the compiled model in the app.
        let detector = try XCTUnwrap(m["detector"] as? [String: String])
        XCTAssertEqual(detector["name"], "ball_heat")
        XCTAssertEqual(detector["canonicalDigest"], String(try XCTUnwrap(X.modelSourceDigest(named: "ball_heat")).prefix(16)))
        let withheld = try XCTUnwrap(m["withheld"] as? [String: Any])
        XCTAssertEqual(withheld["names"] as? [String], ["bch_w"])
        let withheldFile = try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: footage("bch_w").path))
        XCTAssertEqual(withheld["fingerprints"] as? [String], [withheldFile, "youtube:bch_w"].sorted(), "the card's identity and the file's content")
        let variants = try XCTUnwrap((m["baseline"] as? [String: Any])?["variants"] as? [[String: Any]])
        XCTAssertEqual(variants.map { $0["name"] as? String }, ["r0", "r0_prime", "r0_no_net_rule"])
        XCTAssertEqual(m["schemaVersion"] as? String, "rally_classifier_dataset_v1")
        XCTAssertEqual((m["labelSchema"] as? [String: Any])?["version"] as? String, "rally_activity_truth_v2")
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

        // Trusted negatives: bch_a's come from its audit record (its cut at 0.3–1.0 s splits the first clean interval);
        // bch_c, continuous and declared complete but never audited, has none.
        XCTAssertEqual(try audit(of: a)["state"] as? String, "audited_clean")
        XCTAssertEqual(try audit(of: a)["auditSha256"] as? String, DatasetSplitManifest.sha256(of: CoverageAudit.url(forVideo: footage("bch_a"))))
        XCTAssertEqual(try audit(of: a)["drawId"] as? String, "20261114-120000")
        XCTAssertEqual(try cleanIntervals(a), [[0, 180], [600, 3000], [7200, 12000], [18600, 20400], [21600, 24000], [28800, 36000]])
        XCTAssertEqual((a["labelProvenance"] as? [String: Any])?["method"] as? String, "declared_audited")
        XCTAssertEqual(try audit(of: c)["state"] as? String, "none")
        XCTAssertTrue(try audit(of: c)["auditSha256"] is NSNull)
        XCTAssertEqual((c["labelCounts"] as? [String: Int])?["NON_RALLY"], 0, "a declaration alone gives no negative")
        XCTAssertGreaterThan((c["labelCounts"] as? [String: Int])?["UNKNOWN"] ?? 0, 0)
        XCTAssertEqual((c["labelProvenance"] as? [String: Any])?["method"] as? String, "legacy_declared")
        // The evidence's own identity, for a later export to prove a reuse from.
        let made = try XCTUnwrap(a["evidence"] as? [String: Any])
        XCTAssertEqual(made["sourceFingerprint"] as? String, ProjectsModel.fileFingerprint(atPath: footage("bch_a").path))
        XCTAssertEqual(made["codeSha"] as? String, String(repeating: "a", count: 40))
        XCTAssertTrue(a["evidenceReusedFrom"] is NSNull)
        // The validator read the audit record itself, through the project.
        XCTAssertEqual(((report["info"] as? [String: Any])?["negatives"] as? [String: Any])?["auditRecordsChecked"] as? Int, 1)
        // The export report: seconds trusted against seconds unmarked, per recording and in all, and the groups.
        let exported = try self.report()
        let negatives = try XCTUnwrap(exported["negatives"] as? [String: Any])
        XCTAssertEqual(negatives["groupsWithTrustedNegatives"] as? [String], ["bch_a"])
        XCTAssertEqual(negatives["groups"] as? Int, 3)
        let rowA = try XCTUnwrap((negatives["recordings"] as? [[String: Any]])?.first { $0["video"] as? String == "bch_a" })
        XCTAssertEqual(try XCTUnwrap(rowA["trustedNegativeSec"] as? Double), 31.3, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(rowA["unmarkedSec"] as? Double), 31.3, accuracy: 1e-9)
        XCTAssertNil(try negativesNote(exported, "bch_a"))
        XCTAssertEqual(try negativesNote(exported, "bch_c"), "no coverage-audit record: positives only")
        XCTAssertTrue(try XCTUnwrap(try negativesNote(exported, "grs_b")).contains("no coverage-audit record"))
        let text = try String(contentsOf: root.appendingPathComponent("manifests/rally-classifier/20261107-180000-export.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("groups contributing negatives: 1 of 3") && text.contains("The detector ran on every recording"), text)

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

    func testACopyOfWithheldFootageUnderAnotherCardIsLeftOutByContent() async throws {
        // grs_b's card and name are its own, but its original is the withheld bch_w's video, byte for byte.
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val")])
        try FileManager.default.removeItem(at: footage("grs_b"))
        try FileManager.default.copyItem(at: footage("bch_w"), to: footage("grs_b"))
        let calls = Calls()
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
        XCTAssertEqual(result.recordings, ["bch_a"])
        XCTAssertEqual(calls.names, ["bch_a"], "the copy is left out in the plan, before the detector runs on it")
        let left = try XCTUnwrap(result.leftOut.first { $0.video == "grs_b" })
        XCTAssertTrue(left.reason.contains("withheld") && left.reason.contains("content"), left.reason)
        XCTAssertEqual(Set(try ledger().map(\.video)), ["bch_a"])
    }

    func testARecordingRegisteredAsWithheldFootageIsLeftOutThoughItsFileWasReencoded() async throws {
        // grs_b's card was registered with the withheld bch_w's file fingerprint; its own file has since been replaced
        // by other bytes (a re-encode of the same footage), so its content matches nothing. The card's identity
        // still does: the plan leaves it out, where once only the preflight caught it, after every recording ran.
        let probe = base.appendingPathComponent("probe.mp4")
        try Data("footage of bch_w".utf8).write(to: probe)
        let withheldContent = try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: probe.path))
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val", fingerprint: withheldContent)])
        XCTAssertEqual(ProjectsModel.fileFingerprint(atPath: footage("bch_w").path), withheldContent)
        XCTAssertNotEqual(ProjectsModel.fileFingerprint(atPath: footage("grs_b").path), withheldContent)
        let calls = Calls()
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
        XCTAssertEqual(result.recordings, ["bch_a"])
        XCTAssertEqual(calls.names, ["bch_a"], "left out in the plan, never processed")
        let left = try XCTUnwrap(result.leftOut.first { $0.video == "grs_b" })
        XCTAssertTrue(left.reason.contains("withheld") && left.reason.contains("fingerprint"), left.reason)
        XCTAssertEqual(Set(try ledger().map(\.video)), ["bch_a"])
    }

    func testAWithheldRecordingWhoseVideoCantBeReachedStopsThePlan() async throws {
        // 2026-11-09: the footage share stalled, so the withheld recording's video link could not be followed. It was
        // skipped, the card's registered fingerprint (no longer its bytes) still passed as a `file:` identity, and a
        // byte copy of the withheld footage under another card went into the plan. Unreachable is not "not here".
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val")], withheldFingerprint: "file:registered-before-a-re-encode")
        let fm = FileManager.default
        try fm.removeItem(at: footage("grs_b"))
        try fm.copyItem(at: footage("bch_w"), to: footage("grs_b"))
        try fm.removeItem(at: footage("bch_w"))
        let share = base.appendingPathComponent("unreachable-share/bch_w.mp4").path
        try fm.createSymbolicLink(atPath: footage("bch_w").path, withDestinationPath: share)
        let calls = Calls()
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
            XCTFail("planned without the withheld recording's content identity")
        } catch let f as X.Failure {
            guard case .unreadable(let why) = f else { return XCTFail("\(f)") }
            XCTAssertTrue(why.contains("bch_w") && why.contains(footage("bch_w").path), why)
        }
        XCTAssertEqual(calls.names, [], "stopped before any recording ran")
        XCTAssertFalse(fm.fileExists(atPath: out.appendingPathComponent(".staging-Fixture-rc-1").path))
        XCTAssertEqual(try ledger(), [])
    }

    func testThePlanAndThePreflightShareOneWithheldIdentityRule() {
        let w = X.Withheld(names: ["bch_w"], sourceIds: ["src:w"], fingerprints: ["file:w", "youtube:w"])
        XCTAssertEqual(X.withheldIdentity(name: "bch_w", sourceId: nil, fingerprint: nil, content: nil, in: w), "name")
        XCTAssertEqual(X.withheldIdentity(name: "a", sourceId: "src:w", fingerprint: nil, content: nil, in: w), "sourceId")
        XCTAssertEqual(X.withheldIdentity(name: "a", sourceId: "src:a", fingerprint: "file:w", content: "file:a", in: w), "fingerprint")
        XCTAssertEqual(X.withheldIdentity(name: "a", sourceId: nil, fingerprint: "youtube:a", content: "file:w", in: w), "content")
        XCTAssertNil(X.withheldIdentity(name: "a", sourceId: "src:a", fingerprint: "youtube:a", content: "file:a", in: w))
    }

    func testAGroupAcrossSplitsIsRefusedBeforeAnyVideoIsProcessed() async throws {
        // Same uploader: one group (contract §6), which the audit calls soft but the validator refuses across splits.
        try project([Spec(name: "bch_a", uploader: "Same Person"), Spec(name: "grs_b", split: "val", uploader: "Same Person"), Spec(name: "bch_c")])
        let calls = Calls()
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
            XCTFail("exported a group split across two splits")
        } catch let f as X.Failure {
            guard case .groupAcrossSplits(let g) = f else { return XCTFail("\(f)") }
            XCTAssertEqual(g.count, 1)
            XCTAssertTrue(g[0].contains("bch_a") && g[0].contains("grs_b") && !g[0].contains("bch_c"), g[0])
        }
        XCTAssertEqual(calls.names, [], "refused at the plan, before the detector ran")
        XCTAssertEqual(try ledger(), [])
        XCTAssertEqual(X.groupsAcrossSplits([(video: "a", group: "a", split: "train"), (video: "b", group: "a", split: "train")]), [])
    }

    func testAWithheldRecordingWhoseVideoIsNotHereStopsTheRun() async throws {
        // Without the withheld recording's file, a copy of it could not be recognised: nothing is exported.
        try project([Spec(name: "bch_a")])
        try FileManager.default.removeItem(at: footage("bch_w"))
        let calls = Calls()
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
            XCTFail("exported without the withheld recording's content identity")
        } catch let f as X.Failure {
            guard case .unreadable(let why) = f else { return XCTFail("\(f)") }
            XCTAssertTrue(why.contains("bch_w"), why)
        }
        XCTAssertEqual(calls.names, [])
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

    func testARunCutShortInItsFirstRecordingCanBeResumed() async throws {
        // 2026-11-09: the share failed a read in the first recording, before any journal was written, and every
        // --resume was refused ("no readable journal") although the run said to resume.
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val")])
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls(), failing: "bch_a"))
            XCTFail("the detector failed and the export went on")
        } catch {}
        let staging = out.appendingPathComponent(".staging-Fixture-rc-1", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path + ".journal.json"), "the journal exists with the staging folder")
        let second = Calls()
        var o = options(resume: staging)
        o.now = now.addingTimeInterval(60)
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: o, evidence: source(second))
        XCTAssertEqual(second.names, ["bch_a", "grs_b"])
        XCTAssertEqual(result.reused, [])
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

    func testAResumeRunsARecordingAgainWhenItsFootageWasReplaced() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val")])
        _ = try? await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls(), failing: "grs_b"))
        // bch_a's original is replaced under the same path between the cut-short run and the resume.
        try Data("another file of bch_a, re-downloaded".utf8).write(to: footage("bch_a"))
        let second = Calls()
        var o = options(resume: out.appendingPathComponent(".staging-Fixture-rc-1", isDirectory: true))
        o.now = now.addingTimeInterval(60)
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: o, evidence: source(second))
        XCTAssertEqual(second.names.sorted(), ["bch_a", "grs_b"], "the replaced file's evidence is made again")
        XCTAssertEqual(result.reused, [])
    }

    func testAResumeIsRefusedFromAnotherExecutable() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val")])
        _ = try? await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls(), failing: "grs_b"))
        var o = options(resume: out.appendingPathComponent(".staging-Fixture-rc-1", isDirectory: true))
        o.binarySha = String(repeating: "d", count: 64)     // the same commit, another build
        o.now = now.addingTimeInterval(60)
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: o, evidence: source(Calls()))
            XCTFail("resumed from another build")
        } catch let f as X.Failure {
            guard case .resumeMismatch = f else { return XCTFail("\(f)") }
        }
    }

    // MARK: - The detector the evidence came from

    func testEvidenceFromAFallbackDetectorIsRefused() async throws {
        try project([Spec(name: "bch_a")])
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls(), evidence: evidence(detector: nil)))
            XCTFail("exported evidence of a detector that did not load")
        } catch let f as X.Failure {
            guard case .detectorNotUsed = f else { return XCTFail("\(f)") }
        }
        XCTAssertEqual(try ledger(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("Fixture-rc-1").path))
    }

    func testAYOLODetectionInTheEvidenceIsRefused() async throws {
        try project([Spec(name: "bch_a")])
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls(), evidence: evidence(yolo: true)))
            XCTFail("exported YOLO detections under the multi-frame model's name")
        } catch let f as X.Failure {
            guard case .detectorNotUsed = f else { return XCTFail("\(f)") }
        }
        XCTAssertEqual(try ledger(), [])
    }

    func testThisBuildRecordsItsRevisionAndCarriesItsValidator() throws {
        // The Record Source Revision phase ran for the RallyLab.app hosting these tests.
        let revision = try XCTUnwrap(X.buildRevision(), "source-revision.txt missing from the app bundle")
        XCTAssertTrue(revision.count == 40 || revision.hasSuffix("-dirty"), revision)
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "validate_dataset", withExtension: "py"))
        XCTAssertEqual(try Data(contentsOf: bundled), try Data(contentsOf: validator), "the validator built into the app is this tree's")
        XCTAssertNotNil(X.executableSha256())
    }

    func testThisBuildRecordsTheModelPackageItsDetectorWasCompiledFrom() throws {
        // What the build phase wrote for the app hosting these tests is the digest of this tree's package: the same
        // for every build of it, where the compiled model in the app is not.
        let recorded = try XCTUnwrap(X.modelSourceDigest(named: "ball_heat"), "model-source-digests.txt has no ball_heat")
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("BumpSetCut/Resources/ML/ball_heat.mlpackage", isDirectory: true)
        let files = try XCTUnwrap(DatasetSplitManifest.canonicalFileHashes(ofDirectory: package)).filter { !$0.path.hasSuffix(".DS_Store") }
        XCTAssertFalse(files.isEmpty)
        XCTAssertEqual(recorded, DatasetSplitManifest.canonicalDigest(lines: files.map { ($0.path, $0.sha256) }))
        let compiled = try XCTUnwrap(ProcessorConfig().heatmapModel)
        XCTAssertNotEqual(recorded, DatasetSplitManifest.canonicalDigest(ofDirectory: compiled), "the compiled model is not what names the detector")
    }

    func testAModelsDigestIsReadFromTheBuildsRecordOrNotAtAll() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        XCTAssertEqual(X.modelSourceDigest(named: "ball_heat", in: "ball_heat \(a)\nnet \(b)\n"), a)
        XCTAssertEqual(X.modelSourceDigest(named: "net", in: "ball_heat \(a)\nnet \(b)\n"), b)
        XCTAssertNil(X.modelSourceDigest(named: "ball", in: "ball_heat \(a)\n"), "a name is the whole name")
        XCTAssertNil(X.modelSourceDigest(named: "ball_heat", in: ""), "no record")
        XCTAssertNil(X.modelSourceDigest(named: "ball_heat", in: "ball_heat \(a)\nball_heat \(b)\n"), "two lines for one model")
        XCTAssertNil(X.modelSourceDigest(named: "ball_heat", in: "ball_heat \(a.dropLast())\n"), "not a digest")
        XCTAssertNil(X.modelSourceDigest(named: "ball_heat", in: "ball_heat \(a.uppercased())\n"), "not as the build writes one")
        XCTAssertNil(X.modelSourceDigest(named: "ball_heat", in: "ball_heat \(a) extra\n"))
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
                              trusted: [CoverageAudit.Span(startTick: 6500, endTick: 16000)], ignoreTicks: ignore)
        XCTAssertEqual(X.state(7000, l), .activeRally)
        XCTAssertEqual(X.state(6100, l), .transition)
        XCTAssertEqual(X.state(12500, l), .excluded)
        XCTAssertEqual(X.state(11900, l), .transition, "the band around an excluded span's edge")
        XCTAssertEqual(X.state(15000, l), .nonRally, "inside a trusted interval")
        XCTAssertEqual(X.state(16000, l), .unknown, "a trusted interval is half-open")
        XCTAssertEqual(X.state(17000, l), .unknown, "unmarked and outside every trusted interval")
        var unknown = l
        unknown.trusted = []
        XCTAssertEqual(X.state(15000, unknown), .unknown)
        XCTAssertEqual(X.state(7000, unknown), .activeRally)
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

    // MARK: - Trusted negatives (G7)

    func testOnlyAnIntervalReviewedCleanSuppliesNegatives() async throws {
        try project([Spec(name: "bch_a")])
        // 0–5 s clean; 12–20 s holds a missed rally; 31–34 s not reviewed yet; 36–40 s clean; 48–60 s uncertain.
        try audit("bch_a", [.clean, .found(.missedRally), .unreviewed, .clean, .found(.uncertain)])
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        let labels = try steps(result.dataset, "bch_a")
        XCTAssertEqual(try label(labels, at: 2), .nonRally, "inside an interval reviewed clean")
        XCTAssertEqual(try label(labels, at: 4.8), .transition, "the ignore band around a rally's start is unchanged")
        XCTAssertEqual(try label(labels, at: 8), .activeRally)
        XCTAssertEqual(try label(labels, at: 16), .unknown, "an interval with a finding is not clean")
        XCTAssertEqual(try label(labels, at: 32.5), .unknown, "an interval nobody reviewed")
        XCTAssertEqual(try label(labels, at: 35), .excluded)
        XCTAssertEqual(try label(labels, at: 38), .nonRally)
        XCTAssertEqual(try label(labels, at: 55), .unknown, "an uncertain interval")
        let rec = try recording(result.dataset, "bch_a")
        XCTAssertEqual(try cleanIntervals(rec), [[0, 3000], [21600, 24000]])
        XCTAssertEqual(try audit(of: rec)["state"] as? String, "contaminated", "a missed rally outranks the intervals still open")
        XCTAssertEqual(try audit(of: rec)["findings"] as? [String: Int], ["missed_rally": 1, "uncertain": 1])
        XCTAssertEqual((rec["labelProvenance"] as? [String: Any])?["method"] as? String, "declared_audited")
        // Every NON_RALLY step lies in one of the two clean intervals.
        XCTAssertTrue(labels.filter { $0.y == X.State.nonRally.rawValue }.allSatisfy { (0..<3000).contains($0.tick) || (21600..<24000).contains($0.tick) })
    }

    func testMarksChangedAfterTheReviewTrustOnlyWhatWasReviewedCleanAndIsStillUnmarked() async throws {
        try project([Spec(name: "bch_a")])
        try audit("bch_a")      // every interval between the marks as they were, reviewed clean
        // Afterwards the first rally is shortened to end at 10 s (10–12 s was under the mark at the review) and a rally
        // is marked at 14–16 s, inside the interval reviewed clean.
        let marks = [RallyMarkRecord(startTime: 5, endTime: 10, kind: .rally, contacts: nil), RallyMarkRecord(startTime: 14, endTime: 16, kind: .rally, contacts: nil),
                     RallyMarkRecord(startTime: 20, endTime: 31, kind: nil, contacts: nil), RallyMarkRecord(startTime: 34, endTime: 36, kind: .missedServe, contacts: nil),
                     RallyMarkRecord(startTime: 40, endTime: 48, kind: .rally, contacts: nil)]
        try JSONEncoder().encode(marks).write(to: RallyMarkModel.labelsURL(for: footage("bch_a")))
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        let labels = try steps(result.dataset, "bch_a")
        XCTAssertEqual(try label(labels, at: 11), .unknown, "unmarked now, but under a mark when the interval was reviewed: in no clean interval")
        XCTAssertEqual(try label(labels, at: 13), .nonRally, "a part of a clean interval is clean")
        XCTAssertEqual(try label(labels, at: 15), .activeRally)
        XCTAssertEqual(try label(labels, at: 18), .nonRally)
        let rec = try recording(result.dataset, "bch_a")
        XCTAssertEqual(try cleanIntervals(rec), [[0, 3000], [7200, 8400], [9600, 12000], [18600, 20400], [21600, 24000], [28800, 36000]],
                       "(the time unmarked now) ∩ (the intervals reviewed clean)")
        XCTAssertEqual(X.trustedSpans(clean: [CoverageAudit.Span(startTick: 7200, endTick: 12000)],
                                      marks: marks, cuts: [],
                                      durationTicks: 9000),
                       [CoverageAudit.Span(startTick: 7200, endTick: 8400)], "and inside the recording")
    }

    func testAVoidAuditRecordIsTreatedAsAbsentAndTheReportSaysWhy() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "bch_c"), Spec(name: "bch_d"), Spec(name: "bch_e"), Spec(name: "bch_ok")])
        // bch_a: a record of another file (the footage was replaced after the review).
        try audit("bch_a") { $0.sourceFingerprint = "file:the-file-that-was-reviewed" }
        // bch_c: not valid — a clean verdict on an interval that was not played whole.
        let invalid = try audit("bch_c")
        var raw = try json(invalid)
        var reviews = try XCTUnwrap(raw["intervals"] as? [[String: Any]])
        reviews[0]["playedAllAtMaxRate"] = nil
        raw["intervals"] = reviews
        try JSONSerialization.data(withJSONObject: raw).write(to: invalid)
        // bch_d: its draw is not in the project as the record hashed it.
        try audit("bch_d")
        try Data("{}".utf8).write(to: CoverageAudit.drawsDirectory(in: root).appendingPathComponent("20261114-120000-bch_d-draw.json"))
        // bch_e: another recording's record, copied beside it.
        try FileManager.default.copyItem(at: try audit("bch_ok"), to: CoverageAudit.url(forVideo: footage("bch_e")))

        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        XCTAssertEqual(result.recordings.sorted(), ["bch_a", "bch_c", "bch_d", "bch_e", "bch_ok"], "a void record is no error: positives only")
        let exported = try report()
        for (name, why) in [("bch_a", "not the one that was reviewed"), ("bch_c", "not valid"), ("bch_d", "its draw"), ("bch_e", "bch_ok's record")] {
            let rec = try recording(result.dataset, name)
            XCTAssertEqual((rec["labelCounts"] as? [String: Int])?["NON_RALLY"], 0, name)
            XCTAssertEqual(try audit(of: rec)["state"] as? String, "none", name)
            XCTAssertEqual(try cleanIntervals(rec), [], name)
            XCTAssertEqual((rec["labelProvenance"] as? [String: Any])?["method"] as? String, "legacy_declared", name)
            let note = try XCTUnwrap(try negativesNote(exported, name), name)
            XCTAssertTrue(note.contains("void") && note.contains(why), note)
        }
        XCTAssertGreaterThan((try recording(result.dataset, "bch_ok")["labelCounts"] as? [String: Int])?["NON_RALLY"] ?? 0, 0)
        XCTAssertEqual((exported["negatives"] as? [String: Any])?["groupsWithTrustedNegatives"] as? [String], ["bch_ok"])
    }

    func testAnAuditRecordThatCantBeReadStopsThatRecordingAndIsNeverTakenAsNoAudit() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "bch_c"), Spec(name: "bch_ok")])
        try Data("half a rec".utf8).write(to: CoverageAudit.url(forVideo: footage("bch_a")))
        var newer = try json(try audit("bch_c"))
        newer["annotationVersion"] = "coverage_audit_v3"       // a record of a later build: not half-read
        try JSONSerialization.data(withJSONObject: newer).write(to: CoverageAudit.url(forVideo: footage("bch_c")))
        let calls = Calls()
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(calls))
        XCTAssertEqual(result.recordings, ["bch_ok"])
        XCTAssertEqual(calls.names, ["bch_ok"], "the detector never ran on a recording whose record could not be read")
        XCTAssertEqual(result.leftOut.map(\.video).sorted(), ["bch_a", "bch_c"])
        XCTAssertTrue(result.leftOut.allSatisfy { $0.reason.contains("coverage-audit record can't be read") && $0.reason.contains("not taken as no audit") }, "\(result.leftOut)")
        XCTAssertEqual(Set(try ledger().map(\.video)), ["bch_ok"])
    }

    func testEditedFootageSuppliesNoNegativeWhateverItsAuditRecordSays() async throws {
        try project([Spec(name: "grs_b", type: .edited), Spec(name: "bch_ok")])
        try audit("grs_b")
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        let rec = try recording(result.dataset, "grs_b")
        XCTAssertEqual((rec["eligibility"] as? [String: Any])?["fullVideoNegatives"] as? String, "restricted")
        XCTAssertEqual((rec["labelCounts"] as? [String: Int])?["NON_RALLY"], 0)
        XCTAssertEqual(try cleanIntervals(rec), [])
        XCTAssertEqual(try audit(of: rec)["state"] as? String, "audited_clean", "what the record says is told; none of it is used")
        XCTAssertEqual((rec["labelProvenance"] as? [String: Any])?["method"] as? String, "legacy_declared")
        XCTAssertTrue(try XCTUnwrap(try negativesNote(try report(), "grs_b")).contains("not eligible for full-video negatives"))
    }

    func testEditedFootageFoundByTheAuditSuppliesNothingUntilTheTypeIsConfirmedAgain() async throws {
        try project([Spec(name: "bch_a")])
        // The type was confirmed continuous on 7 November; on the 14th the audit found a replay in 12–20 s.
        try audit("bch_a", [.clean, .found(.editedFootage), .clean, .clean, .clean])
        let first = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        var rec = try recording(first.dataset, "bch_a")
        XCTAssertEqual((rec["labelCounts"] as? [String: Int])?["NON_RALLY"], 0)
        XCTAssertEqual(try cleanIntervals(rec), [])
        XCTAssertEqual(try audit(of: rec)["state"] as? String, "audited_clean")
        XCTAssertEqual(try audit(of: rec)["findings"] as? [String: Int], ["edited_footage": 1])
        XCTAssertTrue(try XCTUnwrap(try negativesNote(try report(), "bch_a")).contains("found edited footage"))
        // A person confirms the type again after the finding: the clean intervals count (the replay's own never does).
        try FootageProperties.Store(root: root).save(FootageProperties.File(video: "bch_a", sourceFingerprint: "youtube:bch_a", recordingType: .continuous,
                                                                            recordingTypeBy: "BW", recordingTypeAt: "2026-11-15T09:00:00Z", updatedAt: "2026-11-15T09:00:00Z"))
        var later = options("Fixture-rc-2")
        later.now = now.addingTimeInterval(60)
        let second = try await X.export(projectDir: root, manifestURL: manifestURL, options: later, evidence: source(Calls()))
        rec = try recording(second.dataset, "bch_a")
        XCTAssertEqual(try cleanIntervals(rec), [[0, 3000], [18600, 20400], [21600, 24000], [28800, 36000]])
        XCTAssertGreaterThan((rec["labelCounts"] as? [String: Int])?["NON_RALLY"] ?? 0, 0)
    }

    func testARecordingWithAStage1BoundaryRecordIsStillLeftOut() async throws {
        // The Stage 1 path is as it was: this exporter reads declared marks only, so such a recording is not exported
        // (and no audit record is read for it).
        try project([Spec(name: "bch_a"), Spec(name: "bch_s")])
        try Data("{}".utf8).write(to: EventReview.url(forVideo: footage("bch_s")))
        try Data("not a record".utf8).write(to: CoverageAudit.url(forVideo: footage("bch_s")))
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        XCTAssertEqual(result.recordings, ["bch_a"])
        XCTAssertTrue(try XCTUnwrap(result.leftOut.first { $0.video == "bch_s" }).reason.contains("Stage 1 boundary record"))
    }

    // MARK: - The matched baseline (A10)

    func testTheMatchedBaselineHoldsTheClipTheAboveNetRuleDropsAndEveryR0ClipUnchanged() async throws {
        try project([Spec(name: "bch_a")])
        // The second rally's ball never rises above the net's top: arc after arc below it, which the rule drops.
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls(), evidence: evidence(lowRally: 1)))
        let m = try json(result.dataset.appendingPathComponent("dataset-manifest.json"))
        let variants = try XCTUnwrap((m["baseline"] as? [String: Any])?["variants"] as? [[String: Any]])
        let r0 = try XCTUnwrap(variants.first { $0["name"] as? String == "r0" }), matched = try XCTUnwrap(variants.first { $0["name"] as? String == "r0_no_net_rule" })
        XCTAssertEqual(r0["configSha256"] as? String, m["pipelineConfigSha256"] as? String, "r0 stays the committed decider: the primary baseline")
        XCTAssertNotEqual(matched["configSha256"] as? String, r0["configSha256"] as? String, "its own config hash")
        XCTAssertEqual(matched["settings"] as? NSDictionary, r0["settings"] as? NSDictionary, "r0's settings: only the rule differs")
        var off = ProcessorConfig()
        off.enableAboveNetRequirement = false
        XCTAssertEqual(matched["configSha256"] as? String, off.canonicalSHA256)
        XCTAssertEqual(X.variant(named: "r0_no_net_rule")?.config.canonicalSHA256, off.canonicalSHA256)

        let file = try JSONDecoder().decode(X.BaselineFile.self, from: Data(contentsOf: result.dataset.appendingPathComponent("baseline/bch_a.json")))
        let kept = try XCTUnwrap(file.variants["r0"]), all = try XCTUnwrap(file.variants["r0_no_net_rule"])
        func overlapsSecondRally(_ c: X.BaselineClip) -> Bool { c.startTick < X.tick(31) && X.tick(20) < c.endTick }
        XCTAssertFalse(kept.isEmpty)
        XCTAssertFalse(kept.contains(where: overlapsSecondRally), "r0 lacks the clip the rule dropped")
        XCTAssertEqual(all.filter(overlapsSecondRally).count, 1, "the matched baseline holds it")
        XCTAssertTrue(kept.allSatisfy(all.contains), "every r0 clip is in the no-rule variant unchanged")
        XCTAssertEqual(all.count, kept.count + 1)
        // Without a rally the rule drops, the two variants hold the same clips.
        var plain = options("Fixture-rc-2")
        plain.now = now.addingTimeInterval(60)
        let same = try await X.export(projectDir: root, manifestURL: manifestURL, options: plain, evidence: source(Calls()))
        let both = try JSONDecoder().decode(X.BaselineFile.self, from: Data(contentsOf: same.dataset.appendingPathComponent("baseline/bch_a.json")))
        XCTAssertEqual(both.variants["r0"], both.variants["r0_no_net_rule"])
    }

    // MARK: - Evidence reuse

    func testASealedDatasetsEvidenceIsReusedWhereProvenAndTheLabelsAreMadeNow() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val", type: .edited)])
        let first = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        let sealed = try XCTUnwrap(DatasetSplitManifest.canonicalFileHashes(ofDirectory: first.dataset)).map { "\($0.path) \($0.sha256)" }
        let before = try steps(first.dataset, "bch_a")
        XCTAssertFalse(before.contains { $0.y == X.State.nonRally.rawValue }, "no audit yet: no negative")

        // Since then: bch_a was audited, and a rally was marked inside 12–20 s.
        try audit("bch_a")
        var marks = Spec(name: "bch_a").marks
        marks.append(RallyMarkRecord(startTime: 14, endTime: 16, kind: .rally, contacts: nil))
        try JSONEncoder().encode(marks).write(to: RallyMarkModel.labelsURL(for: footage("bch_a")))
        let calls = Calls()
        let second = try await X.export(projectDir: root, manifestURL: manifestURL, options: reusing(first.dataset, as: "Fixture-rc-2"), evidence: source(calls))
        XCTAssertEqual(calls.names, [], "the detector ran on nothing")
        XCTAssertEqual(second.evidenceReused, ["bch_a", "grs_b"])

        // The times and feature columns are the source's, text for text; the labels are of the project as it is now.
        let after = try steps(second.dataset, "bch_a")
        XCTAssertEqual(after.map(\.evidence), before.map(\.evidence))
        XCTAssertEqual(after.map(\.tick), before.map(\.tick))
        XCTAssertEqual(try label(after, at: 15), .activeRally)
        XCTAssertEqual(try label(before, at: 15), .unknown)
        XCTAssertEqual(try label(after, at: 2), .nonRally)
        XCTAssertEqual(try Data(contentsOf: second.dataset.appendingPathComponent("baseline/bch_a.json")), try Data(contentsOf: first.dataset.appendingPathComponent("baseline/bch_a.json")))

        // The record of it: whose evidence, the proof, and the commit whose detector made it.
        let rec = try recording(second.dataset, "bch_a"), source = try recording(first.dataset, "bch_a")
        let from = try XCTUnwrap(rec["evidenceReusedFrom"] as? [String: Any])
        XCTAssertEqual(from["dataset"] as? String, "Fixture-rc-1")
        XCTAssertEqual(from["manifestSha256"] as? String, first.manifestSha256)
        XCTAssertEqual(from["digest"] as? String, first.digest)
        XCTAssertEqual(from["stepsSha256"] as? String, source["stepsSha256"] as? String)
        XCTAssertEqual(from["baselineSha256"] as? String, source["baselineSha256"] as? String)
        XCTAssertEqual(from["identityProof"] as? String, "manifest")
        XCTAssertEqual(from["sourceFingerprint"] as? String, ProjectsModel.fileFingerprint(atPath: footage("bch_a").path))
        XCTAssertEqual(from["pipelineConfigSha256"] as? String, ProcessorConfig().canonicalSHA256)
        XCTAssertEqual(rec["evidence"] as? NSDictionary, source["evidence"] as? NSDictionary)
        XCTAssertNotEqual(rec["stepsSha256"] as? String, source["stepsSha256"] as? String, "the labels changed, so the file did")
        for key in ["durationSec", "frameRateNominal", "aspect", "upright", "net", "stepCount"] { XCTAssertEqual(rec[key] as? NSObject, source[key] as? NSObject, key) }

        // The validator compared the reused evidence with the source itself; the source was only read.
        let validation = try json(root.appendingPathComponent("manifests/rally-classifier/20261107-180100-validation.json"))
        XCTAssertEqual(validation["ok"] as? Bool, true, "\(validation["errors"] ?? "")")
        let checked = try XCTUnwrap((validation["info"] as? [String: Any])?["evidence"] as? [String: Any])
        XCTAssertEqual(checked["reused"] as? Int, 2)
        XCTAssertEqual(checked["checkedAgainstSource"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(DatasetSplitManifest.canonicalFileHashes(ofDirectory: first.dataset)).map { "\($0.path) \($0.sha256)" }, sealed, "the sealed dataset is untouched")
        let exported = try report("20261107-180100")
        XCTAssertEqual(((exported["evidence"] as? [String: Any])?["source"] as? [String: Any])?["digest"] as? String, first.digest)
        XCTAssertEqual((exported["evidence"] as? [String: Any])?["reused"] as? [String], ["bch_a", "grs_b"])
        // Both exports are on the ledger; the second names its own dataset.
        XCTAssertEqual(Set(try ledger().map(\.ref)), ["--export-rally-classifier-dataset Fixture-rc-1", "--export-rally-classifier-dataset Fixture-rc-2"])
    }

    /// A copy of `dataset` as one written before the manifest carried `evidence` (rc-v1-20261112's shape), under its own name.
    private func withoutEvidenceFields(_ dataset: URL) throws -> URL {
        let copy = base.appendingPathComponent("before-evidence/\(dataset.lastPathComponent)", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dataset, to: copy)
        try rewriteManifest(copy) { m in
            m["recordings"] = (m["recordings"] as? [[String: Any]])?.map { r in
                var r = r
                r["evidence"] = nil
                r["evidenceReusedFrom"] = nil
                return r
            }
        }
        return copy
    }

    private func rewriteManifest(_ dataset: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = dataset.appendingPathComponent("dataset-manifest.json")
        var m = try json(url)
        change(&m)
        try JSONSerialization.data(withJSONObject: m, options: [.sortedKeys]).write(to: url)
    }

    func testADatasetWrittenBeforeTheManifestCarriedTheFileIsProvenThroughItsExportsJournal() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "bch_c")])
        let first = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        let old = try withoutEvidenceFields(first.dataset)
        // The marks of bch_a changed since; nothing else did. The journal's key, recomputed with the marks hash the
        // source recorded, still opens: the file, its path, the cuts, the footage properties and the camera are the same.
        var marks = Spec(name: "bch_a").marks
        marks.append(RallyMarkRecord(startTime: 14, endTime: 16, kind: .rally, contacts: nil))
        try JSONEncoder().encode(marks).write(to: RallyMarkModel.labelsURL(for: footage("bch_a")))
        // bch_c's footage type was confirmed again since: its key no longer opens, so its file is not proven.
        try FootageProperties.Store(root: root).save(FootageProperties.File(video: "bch_c", sourceFingerprint: "youtube:bch_c", recordingType: .continuous,
                                                                            recordingTypeBy: "BW", recordingTypeAt: "2026-11-15T09:00:00Z", updatedAt: "2026-11-15T09:00:00Z"))
        let calls = Calls()
        let second = try await X.export(projectDir: root, manifestURL: manifestURL, options: reusing(old, as: "Fixture-rc-2"), evidence: source(calls))
        XCTAssertEqual(calls.names, ["bch_c"], "the detector ran on the one recording whose file was not proven")
        XCTAssertEqual(second.evidenceReused, ["bch_a"])
        let from = try XCTUnwrap(try recording(second.dataset, "bch_a")["evidenceReusedFrom"] as? [String: Any])
        XCTAssertEqual(from["identityProof"] as? String, "journal")
        XCTAssertEqual((try recording(second.dataset, "bch_a")["evidence"] as? [String: Any])?["codeSha"] as? String, String(repeating: "a", count: 40), "the source's generator made it")
        XCTAssertTrue(try recording(second.dataset, "bch_c")["evidenceReusedFrom"] is NSNull)
        let run = try XCTUnwrap(((try report("20261107-180100")["evidence"] as? [String: Any])?["detectorRun"] as? [[String: Any]])?.first)
        XCTAssertEqual(run["video"] as? String, "bch_c")
        XCTAssertTrue((run["reason"] as? String ?? "").contains("journal's key does not match"), "\(run)")

        // Without that export's journal nothing proves the file: the detector runs on both.
        try FileManager.default.removeItem(at: root.appendingPathComponent("manifests/rally-classifier/Fixture-rc-1-journal.json"))
        let third = Calls()
        _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: reusing(old, as: "Fixture-rc-3", minutes: 2), evidence: source(third))
        XCTAssertEqual(third.names, ["bch_a", "bch_c"])
    }

    func testEvidenceIsNotReusedForARecordingWhoseProofFails() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "bch_c"), Spec(name: "bch_d"), Spec(name: "bch_e")])
        let first = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        // A copy of the sealed dataset in which bch_c's steps are not the bytes its manifest hashes, and bch_d is missing.
        let copy = base.appendingPathComponent("copy/Fixture-rc-1", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: first.dataset, to: copy)
        let tampered = copy.appendingPathComponent("steps/bch_c.jsonl")
        try (try Data(contentsOf: tampered) + Data("\n".utf8)).write(to: tampered)
        try FileManager.default.removeItem(at: copy.appendingPathComponent("steps/bch_d.jsonl"))
        try FileManager.default.removeItem(at: copy.appendingPathComponent("baseline/bch_d.json"))
        try rewriteManifest(copy) { m in m["recordings"] = (m["recordings"] as? [[String: Any]])?.filter { $0["recordingId"] as? String != "bch_d" } }
        // bch_a's footage was replaced since the source was made; bch_e's file now reports another duration.
        try Data("another file of bch_a, re-downloaded".utf8).write(to: footage("bch_a"))
        var o = reusing(copy, as: "Fixture-rc-2")
        o.duration = { $0.name == "bch_e" ? 61 : 60 }
        let calls = Calls()
        let second = try await X.export(projectDir: root, manifestURL: manifestURL, options: o, evidence: source(calls))
        XCTAssertEqual(calls.names, ["bch_a", "bch_c", "bch_d", "bch_e"], "each ran the detector, as without the option")
        XCTAssertEqual(second.evidenceReused, [])
        let runs = try XCTUnwrap((try report("20261107-180100")["evidence"] as? [String: Any])?["detectorRun"] as? [[String: String]])
        let why = Dictionary(uniqueKeysWithValues: runs.map { ($0["video"] ?? "", $0["reason"] ?? "") })
        XCTAssertTrue(why["bch_a"]?.contains("content fingerprint") == true, "\(why)")
        XCTAssertTrue(why["bch_c"]?.contains("does not hash") == true, "\(why)")
        XCTAssertTrue(why["bch_d"]?.contains("not in Fixture-rc-1") == true, "\(why)")
        XCTAssertTrue(why["bch_e"]?.contains("duration") == true, "\(why)")
        XCTAssertTrue(try recording(second.dataset, "bch_a")["evidenceReusedFrom"] is NSNull)
    }

    func testADatasetWhoseEvidenceIsNotThisBuildsIsRefusedWholeBeforeAnyVideoIsRead() async throws {
        try project([Spec(name: "bch_a")])
        var narrow = options()
        narrow.variants = ["r0", "r0_prime"]        // as rc-v1-20261112 was exported
        let first = try await X.export(projectDir: root, manifestURL: manifestURL, options: narrow, evidence: source(Calls()))
        func refused(_ o: X.Options, _ expect: String, line: UInt = #line) async {
            let calls = Calls()
            do {
                _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: o, evidence: source(calls))
                XCTFail("reused evidence that is not this build's", line: line)
            } catch let f as X.Failure {
                guard case .reuseRefused(let why) = f else { return XCTFail("\(f)", line: line) }
                XCTAssertTrue(why.contains(expect), why, line: line)
            } catch { XCTFail("\(error)", line: line) }
            XCTAssertEqual(calls.names, [], line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(".staging-\(o.name)").path), line: line)
        }
        // A variant the source lacks can't be made from it: the dataset stores clips, not the frames they are replayed from.
        await refused(reusing(first.dataset, as: "Fixture-rc-2"), "no baseline variant r0_no_net_rule")
        // With the source's own variants the same reuse goes through.
        var same = reusing(first.dataset, as: "Fixture-rc-2")
        same.variants = ["r0", "r0_prime"]
        let calls = Calls()
        let second = try await X.export(projectDir: root, manifestURL: manifestURL, options: same, evidence: source(calls))
        XCTAssertEqual(calls.names, [])
        XCTAssertEqual(second.evidenceReused, ["bch_a"])

        // Another detector, config, feature schema or dataset schema; no manifest; the folder being written.
        func changed(_ label: String, _ change: (inout [String: Any]) -> Void) throws -> X.Options {
            let copy = base.appendingPathComponent("\(label)/Fixture-rc-1", isDirectory: true)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: first.dataset, to: copy)
            try rewriteManifest(copy, change)
            var o = reusing(copy, as: "Fixture-rc-3", minutes: 2)
            o.variants = ["r0", "r0_prime"]
            return o
        }
        let detector = try changed("detector") { $0["detector"] = ["name": "ball_heat", "canonicalDigest": "0000000000000000"] }
        await refused(detector, "detector")
        let config = try changed("config") { $0["pipelineConfigSha256"] = String(repeating: "0", count: 64) }
        await refused(config, "another pipeline config")
        let features = try changed("features") { m in
            var schema = m["featureSchema"] as? [String: Any] ?? [:]
            schema["version"] = "rcf_v0"
            m["featureSchema"] = schema
        }
        await refused(features, "feature schema")
        let schema = try changed("schema") { $0["schemaVersion"] = "rally_classifier_dataset_v0" }
        await refused(schema, "schemaVersion")
        let variantConfig = try changed("variant-config") { m in
            var block = m["baseline"] as? [String: Any] ?? [:]
            block["variants"] = (block["variants"] as? [[String: Any]])?.map { v in
                var v = v
                if v["name"] as? String == "r0_prime" { v["configSha256"] = String(repeating: "1", count: 64) }
                return v
            }
            m["baseline"] = block
        }
        await refused(variantConfig, "no baseline variant r0_prime")
        var none = reusing(base.appendingPathComponent("no-such-dataset"), as: "Fixture-rc-3", minutes: 2)
        none.variants = ["r0", "r0_prime"]
        await refused(none, "no readable dataset-manifest.json")
        var itself = reusing(out.appendingPathComponent("Fixture-rc-3"), as: "Fixture-rc-3", minutes: 2)
        itself.variants = ["r0", "r0_prime"]
        await refused(itself, "the dataset being written")
    }

    func testAResumeMustBeGivenTheSameEvidenceSource() async throws {
        try project([Spec(name: "bch_a"), Spec(name: "grs_b", split: "val")])
        let first = try await X.export(projectDir: root, manifestURL: manifestURL, options: options(), evidence: source(Calls()))
        // A reuse cut short in grs_b (its file was replaced, so the detector ran on it — and failed).
        try Data("another file of grs_b".utf8).write(to: footage("grs_b"))
        _ = try? await X.export(projectDir: root, manifestURL: manifestURL, options: reusing(first.dataset, as: "Fixture-rc-2"), evidence: source(Calls(), failing: "grs_b"))
        let staging = out.appendingPathComponent(".staging-Fixture-rc-2", isDirectory: true)
        var without = options("Fixture-rc-2", resume: staging)
        without.now = now.addingTimeInterval(120)
        do {
            _ = try await X.export(projectDir: root, manifestURL: manifestURL, options: without, evidence: source(Calls()))
            XCTFail("resumed a reuse without its source")
        } catch let f as X.Failure {
            guard case .resumeMismatch = f else { return XCTFail("\(f)") }
        }
        var with = reusing(first.dataset, as: "Fixture-rc-2", minutes: 3)
        with.resume = staging
        let calls = Calls()
        let result = try await X.export(projectDir: root, manifestURL: manifestURL, options: with, evidence: source(calls))
        XCTAssertEqual(calls.names, ["grs_b"])
        XCTAssertEqual(result.reused, ["bch_a"], "kept from the run cut short")
        XCTAssertEqual(result.evidenceReused, ["bch_a"], "and still recorded as the source's evidence")
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

    func testAServeDatedIntoThePreviousRallysTailGivesOverlappingRawsTheValidatorAccepts() async throws {
        // The decider dates the second rally back to its serve at 14 s, before the first raw rally closed at 15 s.
        let builder = SegmentBuilder(config: ProcessorConfig())
        func t(_ s: Double) -> CMTime { CMTimeMakeWithSeconds(s, preferredTimescale: 600) }
        builder.observe(isActive: true, at: t(10))
        builder.observe(isActive: false, at: t(15))
        builder.observe(isActive: true, at: t(16), rallyStart: t(14))
        builder.observe(isActive: false, at: t(20))
        let built = builder.finalizeWithRaw(until: t(60))
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built[0].parts.map { [$0.start.seconds, CMTimeRangeGetEnd($0).seconds] }, [[10, 15], [14, 20]], "in order by start, overlapping")

        // The validator takes such a clip (in order by start) and still refuses raws out of order.
        let script = """
        import sys, json, os, tempfile
        sys.path.insert(0, sys.argv[1]); import validate_dataset as v
        def run(raws):
            d = os.path.join(tempfile.mkdtemp(), "ds"); v.write_synthetic(d)
            m = json.load(open(os.path.join(d, "dataset-manifest.json"))); rec = m["recordings"][0]
            bp = os.path.join(d, rec["baselineFile"]); b = json.load(open(bp))
            clip = b["variants"]["r0"][0]; s, e = clip["startTick"], clip["endTick"]
            clip["rawSpans"] = [{"startTick": s + a, "endTick": s + z} for a, z in raws]
            json.dump(b, open(bp, "w")); rec["baselineSha256"] = v.sha256_file(bp)
            json.dump(m, open(os.path.join(d, "dataset-manifest.json"), "w"))
            return [x for x in v.validate(d).errors if "rawSpans" in x]
        print(json.dumps([run([(10, 40), (30, 60)]), run([(30, 60), (10, 40)])]))
        """
        let run = await ToolEnvironment.run("python3", ["-c", script, validator.deletingLastPathComponent().path])
        let out = try XCTUnwrap(run.lines.last.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [[String]] }, run.lines.joined(separator: "\n"))
        XCTAssertEqual(out[0], [], "overlapping raws in order by start are valid")
        XCTAssertEqual(out[1].count, 1, "raws out of order are not")
        XCTAssertTrue(out[1].first?.contains("time order") ?? false, "\(out[1])")
    }
}
