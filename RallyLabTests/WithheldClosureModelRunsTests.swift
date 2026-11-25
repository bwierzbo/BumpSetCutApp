//
//  WithheldClosureModelRunsTests.swift
//  RallyLabTests
//
//  No routine model run goes into the withheld closure (owner, 2026-11-12
//  §5C): the legacy holdout (validation.json `holdout`) and every alias of
//  it are refused like the final test and the lineage holdout — by the one
//  admission, the per-recording admissions of the Label, Track and Sampler
//  tabs, the score against YOLO and the test-set scoring, the render,
//  pre-tracking and its check, the detector evaluation, both packages, the
//  single-video tabs, the sampling of a new file or of the project's own
//  clip, and the project dataset (images/, labels/) the Sampler writes.
//  Refused before any model runs and with no ledger row; an
//  ordinary recording is still admitted and recorded; and marking, typing
//  and boxing a withheld recording by hand still work.
//

import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RallyLab

@MainActor
final class WithheldClosureModelRunsTests: XCTestCase {

    private var base: URL!
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private let F = DatasetSplitManifestTests.self

    private let reservedPhrase = "reserved as final_test (D-002)"
    private let withheldPhrase = "withheld — a lineage or legacy holdout, or an alias of one (D-017)"

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rl-closure-\(UUID().uuidString)")
        root = base.appendingPathComponent("P", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("footage"), withIntermediateDirectories: true)
        try DatasetStore(root: root).prepare()
        suite = "RallyLabTests.WithheldClosureModelRuns.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixture

    private func writeValidation(_ text: String) throws {
        try text.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
    }

    private func ledger() throws -> [String] { try ExposureLog.readStrict(in: root).map { "\($0.video) \($0.kind.rawValue) \($0.ref)" } }
    private var ledgerExists: Bool { FileManager.default.fileExists(atPath: ExposureLog.url(in: root).path) }
    private func session(_ name: String) throws -> VideoSession { try XCTUnwrap(try DatasetStore(root: root).loadSessionsStrict().first { $0.name == name }) }

    /// A video file of its own bytes (so its fingerprint is its own), under footage/.
    private func footage(_ name: String, seed: Int) throws -> URL {
        let url = base.appendingPathComponent("footage/\(name).mp4")
        try Data((0..<5000).map { UInt8(($0 * (seed + 2) + seed) % 251) }).write(to: url)
        return url
    }

    private func writeJPEG(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 54, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 54))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    /// A project of six recordings, each with a footage file, a card, a session with its pass complete, one
    /// reviewed frame and an empty marks sidecar: `l` the lineage holdout and `a` its alias (a shared confirmed
    /// sourceId); `h` the legacy holdout (a val recording, as the live ones are) and `g` its alias; `t` an
    /// ordinary train recording and `v` an ordinary val one.
    @discardableResult
    private func makeProject() throws -> [String: URL] {
        var videos: [String: URL] = [:]
        var clips: [PlannedClip] = []
        let sourceIds = ["l": "camera-roll-1", "a": "camera-roll-1", "h": "camera-roll-2", "g": "camera-roll-2"]
        for (i, name) in ["l", "a", "h", "g", "t", "v"].enumerated() {
            let url = try footage(name, seed: i)
            videos[name] = url
            let split = ["h", "v"].contains(name) ? "val" : "train"
            let frame = FrameRecord(id: UUID(), file: "images/\(split)/\(name)_0.jpg", time: 1, source: "rally:0", boxes: [], keep: true, reviewed: true)
            try writeJPEG(to: root.appendingPathComponent(frame.file))
            var session = VideoSession(name: name, sourcePath: url.path, split: split, addedAt: F.day, frames: [frame])
            session.ralliesMarked = true
            try DatasetStore(root: root).save(session)
            try Data("[]".utf8).write(to: RallyMarkModel.labelsURL(for: url))
            var source = F.source(name, fingerprint: try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: url.path)), sourceId: sourceIds[name])
            source.clipFile = url.path
            clips.append(F.clip(name, split: split, videos: [source]))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: "P", createdAt: F.day, framesPerRally: 40, clips: clips)).write(to: root.appendingPathComponent("project.json"))
        try writeValidation(#"{"tune":[],"holdout":["h"],"finalTest":[],"lineageHoldout":["l"]}"#)
        return videos
    }

    private func sampler() -> SamplerModel { SamplerModel(defaults: defaults, root: root) }

    private func copy(of video: URL) throws -> URL {
        let copy = base.appendingPathComponent("footage/renamed copy.mp4")
        try FileManager.default.copyItem(at: video, to: copy)
        return copy
    }

    // MARK: - The one admission

    func testTheClosuresAreTheFinalTestsAndTheWholeWithheldOne() throws {
        try makeProject()
        let closures = try ScoringExposure.Closures(in: root)
        XCTAssertEqual(closures.reserved, ["a", "l"])
        XCTAssertEqual(closures.withheld, ["a", "g", "h", "l"], "the legacy holdout and its alias with the reserved")
        XCTAssertEqual(closures.standing(of: "l"), reservedPhrase)
        XCTAssertEqual(closures.standing(of: "h"), withheldPhrase)
        XCTAssertEqual(closures.standing(of: "g"), withheldPhrase, "an alias of the legacy holdout")
        XCTAssertNil(closures.standing(of: "t"))
        XCTAssertEqual(closures.admitted(try DatasetStore(root: root).loadSessionsStrict()).map(\.name).sorted(), ["t", "v"])
    }

    func testAdmissionRefusesTheLegacyHoldoutAndItsAliasAndRecordsNothing() throws {
        try makeProject()
        XCTAssertThrowsError(try ScoringExposure.admit(["t", "h", "g", "l"], kind: .testSetScoring, ref: "export-1", note: nil, root: root)) {
            XCTAssertEqual($0 as? ScoringExposure.Withheld, ScoringExposure.Withheld(reserved: ["l"], withheld: ["g", "h"]))
            XCTAssertEqual($0.localizedDescription, "l is \(reservedPhrase); g, h are \(withheldPhrase) — no model is run over withheld footage.")
        }
        for name in ["h", "g"] {
            XCTAssertThrowsError(try ScoringExposure.admit([name], kind: .ballPath, ref: "x", note: nil, root: root), name) {
                XCTAssertEqual($0 as? ScoringExposure.Withheld, ScoringExposure.Withheld(reserved: [], withheld: [name]))
            }
        }
        XCTAssertFalse(ledgerExists, "nothing of a refused run is recorded — not even the recordings that would have been admitted")
        try ScoringExposure.admit(["t", "v"], kind: .testSetScoring, ref: "export-1", note: nil, root: root)
        XCTAssertEqual(try ledger(), ["t test_set_scoring export-1", "v test_set_scoring export-1"])
    }

    // MARK: - Label, Track and Sampler tabs (per-recording admissions)

    func testBallPathTrackTabAndClickToBoxRefuseTheLegacyHoldout() throws {
        try makeProject()
        let admissions: [(String, (String) -> String?)] = [
            ("ball path", { BallPathBuilder.admission(of: $0, in: self.root) }),
            ("Track tab", { TrackLabelModel.modelAdmission(of: $0, in: self.root) }),
            ("Sampler click-to-box", { SamplerModel.snapAdmission(of: $0, in: self.root) }),
        ]
        for (what, admission) in admissions {
            for name in ["h", "g"] { XCTAssertEqual(admission(name)?.contains("\(name) is \(withheldPhrase)"), true, "\(what): \(name)") }
            XCTAssertEqual(admission("l")?.contains("l is \(reservedPhrase)"), true, "\(what): the final-test wording stays")
        }
        XCTAssertFalse(ledgerExists, "a refused recording leaves no ledger row")
        for (what, admission) in admissions { XCTAssertNil(admission("t"), what) }
        XCTAssertEqual(try ledger(), ["t ball_path BallPathBuilder", "t pre_tracking RallyLab Track tab", "t pre_tracking RallyLab Sampler review"])
        // The reservations unreadable: nothing is cleared.
        try writeValidation(#"{"tune":[],"holdout":["h"]"#)
        for (what, admission) in admissions { XCTAssertEqual(admission("v")?.hasPrefix("❌"), true, what) }
        XCTAssertEqual(try ledger().count, 3)
    }

    // MARK: - An admission does not outlive the reservations it was made under

    private let ordinary = #"{"tune":[],"holdout":["h"],"finalTest":[],"lineageHoldout":["l"]}"#
    private let tListed = #"{"tune":[],"holdout":["h","t"],"finalTest":[],"lineageHoldout":["l"]}"#

    /// One click on the frame under review, waited for; the status it leaves.
    private func click(_ sampler: SamplerModel) async throws -> String {
        sampler.snapBox(at: CGPoint(x: 0.5, y: 0.5))
        while sampler.snapping != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        return sampler.status
    }

    func testAClickToBoxAdmittedOnceIsRefusedWhenItsRecordingBecomesWithheld() async throws {
        try makeProject()
        let sampler = sampler()
        let projects = ProjectsModel(sampler: sampler, defaults: defaults, restoreLastProject: false)
        projects.open(root)
        XCTAssertNotNil(projects.opening, projects.status)
        sampler.openSession(try session("t"))
        while sampler.isLoadingSession { try await Task.sleep(nanoseconds: 20_000_000) }
        // Admitted: the use is on the ledger, once, however many clicks ask.
        let row = ["t pre_tracking RallyLab Sampler review"]
        XCTAssertNil(sampler.snapRefusal())
        XCTAssertNil(sampler.snapRefusal())
        XCTAssertEqual(try ledger(), row)

        // Listed in validation.json while the session stays open: the next click runs no model.
        try writeValidation(tListed)
        XCTAssertEqual(sampler.snapRefusal()?.contains("t is \(withheldPhrase)"), true)
        var status = try await click(sampler)
        XCTAssertTrue(status.contains("t is \(withheldPhrase)"), status)
        XCTAssertFalse(status.contains("(detector"), "the box was placed without the model: \(status)")
        XCTAssertEqual(try session("t").frames.first?.boxes.count, 1, "and still placed")
        XCTAssertEqual(try ledger(), row, "no row for a run that did not happen")
        // Closing and reopening the same session brings no admission back.
        sampler.closeSession()
        sampler.openSession(try session("t"))
        while sampler.isLoadingSession { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(sampler.snapRefusal())

        // The listing withdrawn: admitted again, on the row it already has.
        try writeValidation(ordinary)
        XCTAssertNil(sampler.snapRefusal())
        XCTAssertEqual(try ledger(), row)

        // Made an alias of the legacy holdout by a provenance change (project.json): the next click runs no model.
        XCTAssertTrue(projects.setProvenance(videoId: "t", sourceId: "camera-roll-2", sessionId: nil, venueId: nil))
        XCTAssertEqual(try ScoringExposure.Closures(in: root).standing(of: "t"), withheldPhrase, "the fixture: t now shares h's confirmed sourceId")
        XCTAssertEqual(sampler.snapRefusal()?.contains("t is \(withheldPhrase)"), true)
        status = try await click(sampler)
        XCTAssertTrue(status.contains("t is \(withheldPhrase)"), status)
        XCTAssertFalse(status.contains("(detector"), status)
        XCTAssertEqual(try ledger(), row)

        // Reservations that can't be read while it is open: refused, not waved through on the old answer.
        XCTAssertTrue(projects.setProvenance(videoId: "t", sourceId: "", sessionId: nil, venueId: nil))
        XCTAssertNil(sampler.snapRefusal())
        try writeValidation(#"{"tune":[],"holdout":["h"]"#)
        XCTAssertEqual(sampler.snapRefusal()?.hasPrefix("❌"), true)
        XCTAssertEqual(try ledger(), row)
    }

    func testTheTrackTabsDetectorsAreRefusedWhenTheOpenVideoBecomesWithheld() async throws {
        try makeProject()
        let sampler = sampler()
        let projects = ProjectsModel(sampler: sampler, defaults: defaults, restoreLastProject: false)
        projects.open(root)
        let tracker = TrackLabelModel(sampler: sampler)
        await tracker.openAndWait(sessionName: "t")
        let row = ["t pre_tracking RallyLab Track tab"]
        XCTAssertTrue(tracker.modelsAdmitted())
        XCTAssertTrue(tracker.modelsAdmitted())
        XCTAssertEqual(try ledger(), row)
        // Listed while the video stays open.
        try writeValidation(tListed)
        XCTAssertFalse(tracker.modelsAdmitted(), "auto-track, click-to-box and look-again all ask this first")
        XCTAssertTrue(tracker.status.contains("t is \(withheldPhrase)"), tracker.status)
        try writeValidation(ordinary)
        XCTAssertTrue(tracker.modelsAdmitted())
        // An alias by a provenance change while it stays open.
        XCTAssertTrue(projects.setProvenance(videoId: "t", sourceId: "camera-roll-2", sessionId: nil, venueId: nil))
        XCTAssertFalse(tracker.modelsAdmitted())
        XCTAssertTrue(tracker.status.contains("t is \(withheldPhrase)"), tracker.status)
        XCTAssertEqual(try ledger(), row, "nothing recorded for the refused runs")
    }

    func testKeptClosuresAreReadAgainWhenAnythingTheyAreReadFromChanges() throws {
        let videos = try makeProject()
        XCTAssertEqual(try ScoringExposure.Closures.current(in: root).withheld, ["a", "g", "h", "l"])
        // validation.json.
        try writeValidation(tListed)
        XCTAssertEqual(try ScoringExposure.Closures.current(in: root).withheld, ["a", "g", "h", "l", "t"])
        try writeValidation(ordinary)
        XCTAssertEqual(try ScoringExposure.Closures.current(in: root).withheld, ["a", "g", "h", "l"])
        // project.json: an older card `x` that stored no fingerprint — its identity is read from its origin file,
        // which is not there yet.
        let origin = base.appendingPathComponent("footage/original of x.mp4")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var project = try decoder.decode(Project.self, from: Data(contentsOf: root.appendingPathComponent("project.json")))
        var x = F.source("x", fingerprint: nil)
        x.origin = origin.path
        project.clips.append(F.clip("x", split: "train", videos: [x]))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(project).write(to: root.appendingPathComponent("project.json"))
        XCTAssertEqual(try ScoringExposure.Closures.current(in: root).withheld, ["a", "g", "h", "l"])
        // Neither JSON file changes from here on. The origin file appears, and it is the legacy holdout's
        // content: `x` is an alias now, and the kept answer must not say otherwise.
        try FileManager.default.copyItem(at: try XCTUnwrap(videos["h"]), to: origin)
        XCTAssertEqual(try ScoringExposure.Closures(in: root).withheld, ["a", "g", "h", "l", "x"], "the fixture: read fresh")
        XCTAssertEqual(try ScoringExposure.Closures.current(in: root).withheld, ["a", "g", "h", "l", "x"])
        var admission = ScoringExposure.OpenAdmission(ask: SamplerModel.snapAdmission)
        XCTAssertEqual(admission.refusal(of: "x", in: root)?.contains("x is \(withheldPhrase)"), true)
        // Its content changes to something of its own: an ordinary recording again, admitted and recorded.
        try Data((0..<4000).map { UInt8($0 % 199) }).write(to: origin)
        XCTAssertEqual(try ScoringExposure.Closures.current(in: root).withheld, ["a", "g", "h", "l"])
        XCTAssertNil(admission.refusal(of: "x", in: root))
        XCTAssertEqual(try ledger(), ["x pre_tracking RallyLab Sampler review"])
        // And back to the holdout's content while `x` stays "open": refused at the next ask, no new row.
        try FileManager.default.removeItem(at: origin)
        try FileManager.default.copyItem(at: try XCTUnwrap(videos["h"]), to: origin)
        XCTAssertEqual(admission.refusal(of: "x", in: root)?.contains("x is \(withheldPhrase)"), true)
        XCTAssertEqual(try ledger().count, 1)
        // Unreadable reservations are never kept as an answer.
        try writeValidation(#"{"tune":[],"holdout":["h"]"#)
        XCTAssertThrowsError(try ScoringExposure.Closures.current(in: root))
        XCTAssertThrowsError(try ScoringExposure.Closures.current(in: root))
    }

    // MARK: - Models tab: score against YOLO, test-set scoring, render, detector evaluation

    private func export(_ name: String, clips: [String]) throws -> URL {
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try clips.map { #"{"clip":"\#($0)","split":"val","size":[1920,1080],"frames":["frames/\#($0)/0.jpg"],"target":0,"time":1.0,"balls":[]}"# }
            .joined(separator: "\n").write(to: dir.appendingPathComponent("windows.jsonl"), atomically: true, encoding: .utf8)
        return dir
    }

    func testScoreAgainstYOLORefusesAPackageWithALegacyHoldoutClip() throws {
        try makeProject()
        let noModel = base.appendingPathComponent("none.mlpackage")
        func failure(_ package: URL) -> String? {
            guard case .failure(let failure) = HeatEvaluation.run(model: noModel, package: package, yolo: nil, cuts: ["h": [], "g": [], "v": []], root: root, progress: { _, _ in })
            else { return nil }
            return failure.message
        }
        for name in ["h", "g"] {
            let message = try XCTUnwrap(failure(try export("package-\(name)", clips: ["v", name])))
            XCTAssertTrue(message.contains("\(name) is \(withheldPhrase)"), message)
            XCTAssertFalse(message.contains("Couldn't load"), "stopped before the model: \(message)")
        }
        XCTAssertFalse(ledgerExists)
        let admitted = try XCTUnwrap(failure(try export("package-v", clips: ["v"])))
        XCTAssertTrue(admitted.contains("Couldn't load"), "an ordinary val clip goes on to the model: \(admitted)")
        XCTAssertEqual(try ledger(), ["v detector_evaluation score vs YOLO none on package-v"])
    }

    func testTestSetScoringRefusesAnExportWithALegacyHoldoutClip() async throws {
        try makeProject()
        let lab = HeatmapLab(sampler: sampler())
        var lines: [String] = []
        let refused = await lab.scoreTestSet(models: [], export: try export("P-val-multiframe-1", clips: ["v", "h"])) { lines.append($0) }
        XCTAssertFalse(refused)
        XCTAssertTrue(lines.contains { $0.hasPrefix("⛔") && $0.contains("h is \(withheldPhrase)") && $0.contains("Re-export the test set") }, "\(lines)")
        XCTAssertFalse(ledgerExists, "refused before the ledger and before any model")
        // The same export without the holdout is admitted: on the ledger before a model would run.
        _ = await lab.scoreTestSet(models: [], export: try export("P-val-multiframe-2", clips: ["v"])) { lines.append($0) }
        XCTAssertEqual(try ledger(), ["v test_set_scoring P-val-multiframe-2"])
    }

    func testRenderRefusesTheLegacyHoldout() async throws {
        try makeProject()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("models/heatmap/m.mlpackage"), withIntermediateDirectories: true)
        let lab = HeatmapLab(sampler: sampler())
        lab.reload()
        XCTAssertEqual(lab.selected?.name, "m")
        let rally = TrackedRally(id: UUID(), start: 0, end: 1, points: [], candidates: [], done: true)
        for name in ["h", "g"] {
            lab.renderVideo(session: name, rally: rally)
            XCTAssertEqual(lab.status, "⛔ \(name) is \(withheldPhrase) — not rendered.")
            XCTAssertFalse(lab.isBusy, "nothing was started")
        }
        XCTAssertFalse(ledgerExists)
        lab.renderVideo(session: "t", rally: rally)
        XCTAssertEqual(try ledger(), ["t detector_evaluation render m"], "an ordinary recording is admitted and recorded before the render")
        while lab.isBusy { try await Task.sleep(nanoseconds: 20_000_000) }   // the render itself fails on the empty model
    }

    func testDetectorEvaluationLeavesOutTheLegacyHoldoutsFrames() throws {
        try makeProject()
        let library = ModelLibrary(sampler: sampler())
        library.evaluateValOnly = false
        XCTAssertEqual(library.evaluationFrameCount, 2, "t and v: no frame of l, a, h or g")
        library.evaluateValOnly = true
        XCTAssertEqual(library.evaluationFrameCount, 1, "v alone: the legacy holdout is a val recording and is not scored")
        try writeValidation(#"{"tune":[],"holdout":["h"]"#)
        XCTAssertEqual(library.evaluationFrameCount, 0, "unreadable reservations: nothing is evaluated")
    }

    // MARK: - Pre-tracking and its check

    func testPreTrackingAndItsCheckLeaveOutTheWholeWithheldClosure() async throws {
        try makeProject()
        let sampler = sampler()
        let noModel = base.appendingPathComponent("none.mlpackage")
        var lines: [String] = []
        // Every train recording: l, a, g and t are train; only t is tracked.
        _ = await PreTracker.run(sampler: sampler, redo: false, model: noModel) { lines.append($0) }
        XCTAssertEqual(try ledger(), ["t pre_tracking none"])
        // Asked for by name: each withheld one is said, in its own words.
        lines = []
        _ = await PreTracker.run(sampler: sampler, only: ["h", "g", "l", "t"], redo: true, model: noModel) { lines.append($0) }
        XCTAssertTrue(lines.contains("⛔ h is \(withheldPhrase) — not pre-tracked."), "\(lines)")
        XCTAssertTrue(lines.contains("⛔ g is \(withheldPhrase) — not pre-tracked."), "\(lines)")
        XCTAssertTrue(lines.contains("⛔ l is \(reservedPhrase) — not pre-tracked."), "\(lines)")
        XCTAssertFalse(lines.contains { $0.contains("⛔ t ") })
        // Val recordings (a head start for the test set): h is val and is not tracked; v is.
        _ = await PreTracker.run(sampler: sampler, redo: false, val: true, model: noModel) { lines.append($0) }
        XCTAssertEqual(try ledger(), ["t pre_tracking none", "v pre_tracking none"])
        // The check scores sure frames on val recordings: never the legacy holdout.
        _ = await PreTracker.check(sampler: sampler, model: noModel) { lines.append($0) }
        XCTAssertEqual(try ledger(), ["t pre_tracking none", "v pre_tracking none", "v detector_evaluation --pretrack-check none"])
        XCTAssertTrue(try session("h").tracks?.isEmpty ?? true, "no machine track was written into the legacy holdout")
        // Unreadable reservations: nothing is tracked or checked, nothing recorded.
        try writeValidation(#"{"tune":[],"holdout":["h"]"#)
        lines = []
        _ = await PreTracker.run(sampler: sampler, redo: false, model: noModel) { lines.append($0) }
        let checks = await PreTracker.check(sampler: sampler, model: noModel) { lines.append($0) }
        XCTAssertTrue(checks.isEmpty)
        XCTAssertEqual(lines.filter { $0.hasPrefix("❌") }.count, 2, "\(lines)")
        XCTAssertEqual(try ledger().count, 3)
    }

    // MARK: - Packages

    func testNeitherPackageTakesTheLegacyHoldoutOrItsAlias() async throws {
        try makeProject()
        let store = DatasetStore(root: root)
        let h = try session("h"), g = try session("g"), t = try session("t")
        // Only withheld recordings offered: nothing is left to package.
        do {
            _ = try await TrainingPackage.export(sessions: [h, g], store: store, name: "P")
            XCTFail("a package was written from withheld recordings")
        } catch { XCTAssertEqual(error as? TrainingPackage.PackageError, .nothingReviewed, "\(error)") }
        do {
            _ = try await MultiFramePackage.export(sessions: [h, g], store: store, name: "P", progress: { _, _ in })
            XCTFail("a package was written from withheld recordings")
        } catch { guard case MultiFramePackage.PackageError.nothingReviewed = error else { return XCTFail("\(error)") } }
        // With an ordinary train recording beside them, the train one is taken and the legacy holdout — the only
        // val recording offered — is not: there is no val left.
        do {
            _ = try await TrainingPackage.export(sessions: [h, g, t], store: store, name: "P")
            XCTFail("the legacy holdout served as the package's val")
        } catch { XCTAssertEqual(error as? TrainingPackage.PackageError, .noValidation, "\(error)") }
        do {
            _ = try await MultiFramePackage.export(sessions: [h, g, t], store: store, name: "P", valOnly: false, progress: { _, _ in })
            XCTFail("the legacy holdout served as the package's val")
        } catch { guard case MultiFramePackage.PackageError.noValidation = error else { return XCTFail("\(error)") } }
        // The test set (a val-only export) is the val recordings less the legacy holdout: none of these.
        do {
            _ = try await MultiFramePackage.export(sessions: [h, g, t], store: store, name: "P", valOnly: true, progress: { _, _ in })
            XCTFail("the legacy holdout went into a test set")
        } catch { guard case MultiFramePackage.PackageError.nothingReviewed = error else { return XCTFail("\(error)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("exports").path), "nothing was written")
        // Unreadable reservations: no package at all.
        try writeValidation(#"{"tune":[],"holdout":["h"]"#)
        do {
            _ = try await TrainingPackage.export(sessions: [t], store: store, name: "P")
            XCTFail("packaged with the reservations unknown")
        } catch { XCTAssertTrue(error is PipelineTuner.ValidationSet.ReservationError, "\(error)") }
    }

    // MARK: - Single-video tabs (Pipeline, Compare, FSM, Net, debug video)

    func testSingleVideoTabsRefuseTheLegacyHoldoutByPathAndByContent() throws {
        let videos = try makeProject()
        let copy = try copy(of: try XCTUnwrap(videos["h"]))
        XCTAssertEqual(RallyLabModel.modelRunRefusal(for: videos["h"]!, root: root), "⛔ h is \(withheldPhrase) — no model is run over it.")
        XCTAssertEqual(RallyLabModel.modelRunRefusal(for: copy, root: root), "⛔ h is \(withheldPhrase) — no model is run over it.", "a copy, by content")
        XCTAssertEqual(RallyLabModel.modelRunRefusal(for: videos["g"]!, root: root), "⛔ g is \(withheldPhrase) — no model is run over it.", "an alias")
        XCTAssertEqual(RallyLabModel.modelRunRefusal(for: videos["l"]!, root: root), "⛔ l is \(reservedPhrase) — no model is run over it.")
        XCTAssertNil(RallyLabModel.modelRunRefusal(for: videos["t"]!, root: root))
        XCTAssertFalse(ledgerExists)
        // The FSM and Net tabs record their runs as the Pipeline tab does.
        try RallyLabModel.recordModelRun(videos["t"]!, kind: .rallyScoring, ref: "RallyLab FSM tab", root: root)
        try RallyLabModel.recordModelRun(videos["t"]!, kind: .netProposal, ref: "RallyLab Net tab", root: root)
        XCTAssertEqual(try ledger(), ["t rally_scoring RallyLab FSM tab", "t net_proposal RallyLab Net tab"])
    }

    // MARK: - The project dataset (images/, labels/, data.yaml)

    private func inDataset(_ file: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path) }
    private func parked(_ file: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent("excluded/\(file)").path) }
    private func label(_ file: String) -> String { file.replacingOccurrences(of: "images/", with: "labels/").replacingOccurrences(of: ".jpg", with: ".txt") }

    func testTheProjectDatasetLeavesOutEveryFrameOfAWithheldRecording() throws {
        try makeProject()
        let store = DatasetStore(root: root)
        // As in the live project: an unreviewed frame parked under excluded/ for a train recording that is
        // now withheld (`g`), for the lineage holdout (`l`) and for an ordinary train recording (`t`).
        for name in ["g", "l", "t"] {
            var session = try session(name)
            let frame = FrameRecord(id: UUID(), file: "images/train/\(name)_1.jpg", time: 2, source: "rally:0", boxes: [], keep: true, reviewed: false)
            try writeJPEG(to: root.appendingPathComponent("excluded/\(frame.file)"))
            session.frames.append(frame)
            try store.save(session)
        }
        let withheldFiles = ["images/train/l_0.jpg", "images/train/l_1.jpg", "images/train/a_0.jpg", "images/val/h_0.jpg", "images/train/g_0.jpg", "images/train/g_1.jpg"]
        func assertWithheldOut(_ when: String) {
            for file in withheldFiles {
                XCTAssertFalse(inDataset(file), "\(when): \(file) is in the dataset")
                XCTAssertFalse(inDataset(label(file)), "\(when): \(file) has a label")
                XCTAssertTrue(parked(file), "\(when): \(file) is kept under excluded/ for review")
            }
        }

        // "Every kept frame": the parked frames come back into images/ — except a withheld recording's.
        let sampler = sampler()
        sampler.reviewedOnly = false
        sampler.writeDataset()
        XCTAssertTrue(sampler.status.hasPrefix("Wrote 3 labels"), sampler.status)
        assertWithheldOut("every kept frame")
        for file in ["images/train/t_0.jpg", "images/train/t_1.jpg", "images/val/v_0.jpg"] {
            XCTAssertTrue(inDataset(file), file)
            XCTAssertTrue(inDataset(label(file)), file)
        }
        XCTAssertTrue(inDataset("data.yaml"))

        // Reviewed frames only: the same for the withheld; the ordinary recording's unreviewed frame is parked again.
        sampler.reviewedOnly = true
        sampler.writeDataset()
        XCTAssertTrue(sampler.status.hasPrefix("Wrote 2 labels"), sampler.status)
        assertWithheldOut("reviewed only")
        XCTAssertTrue(inDataset("images/train/t_0.jpg"))
        XCTAssertTrue(parked("images/train/t_1.jpg"))

        // The one writer refuses on its own, whoever calls it (a review edit, a cut, an ingest).
        let h = try XCTUnwrap(try session("h").frames.first), t = try XCTUnwrap(try session("t").frames.first)
        XCTAssertEqual(try store.writeLabels(for: [h], of: "h", reviewedOnly: false, cuts: []), 0)
        XCTAssertEqual(try store.writeLabels(for: [t], of: "t", reviewedOnly: false, cuts: []), 1)
        assertWithheldOut("written directly")

        // Reservations that can't be read: nothing is written or moved.
        try writeValidation(#"{"tune":[],"holdout":["h"]"#)
        sampler.reviewedOnly = false
        sampler.writeDataset()
        XCTAssertTrue(sampler.status.hasPrefix("Couldn't write the dataset"), sampler.status)
        XCTAssertThrowsError(try store.writeLabels(for: [t], of: "t", reviewedOnly: false, cuts: []))
        assertWithheldOut("reservations unreadable")
        XCTAssertTrue(parked("images/train/t_1.jpg"), "not brought back while the reservations are unknown")

        // The reservations as they are now, not as they were: with the legacy holdout no longer listed, it and
        // its alias are ordinary recordings again and their frames come back; the lineage holdout's do not.
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":[],"lineageHoldout":["l"]}"#)
        sampler.writeDataset()
        XCTAssertTrue(sampler.status.hasPrefix("Wrote 6 labels"), sampler.status)
        for file in ["images/val/h_0.jpg", "images/train/g_0.jpg", "images/train/g_1.jpg"] { XCTAssertTrue(inDataset(file), file) }
        for file in ["images/train/l_0.jpg", "images/train/l_1.jpg", "images/train/a_0.jpg"] { XCTAssertFalse(inDataset(file), file) }
    }

    // MARK: - Sampling: a new file, and the project's own clip

    func testSamplingRefusesTheLegacyHoldoutAsANewFileAndAsAProjectClip() async throws {
        let videos = try makeProject()
        let copy = try copy(of: try XCTUnwrap(videos["h"]))
        XCTAssertEqual(try SamplerModel.ingestRefusal(of: copy, root: root), "renamed copy.mp4 is h, \(withheldPhrase) — not sampled.")
        XCTAssertNotNil(try SamplerModel.ingestRefusal(of: videos["g"]!, root: root), "an alias, by path")
        for name in ["h", "g"] { XCTAssertEqual(try SamplerModel.ingestRefusal(ofClip: name, root: root)?.hasPrefix("\(name) is \(withheldPhrase)"), true) }
        XCTAssertEqual(try SamplerModel.ingestRefusal(ofClip: "l", root: root)?.hasPrefix("l is \(reservedPhrase)"), true)
        XCTAssertNil(try SamplerModel.ingestRefusal(ofClip: "t", root: root))
        XCTAssertNil(try SamplerModel.ingestRefusal(of: try footage("new", seed: 11), root: root))

        // The queue: a dropped copy, and the project's own clip queued under its card's name, both fail before
        // the pipeline runs, and the legacy holdout's session is as it was.
        let before = try session("h")
        let sampler = sampler()
        sampler.enqueue([copy])
        sampler.enqueueClip(try XCTUnwrap(videos["h"]), sessionName: "h", split: "val", framesPerRally: 40)
        while sampler.queue.contains(where: { !$0.isFinished }) { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(sampler.queue.count, 2)
        for job in sampler.queue {
            guard case .failed(let why) = job.state else { XCTFail("\(job.state)"); continue }
            XCTAssertTrue(why.contains("h, \(withheldPhrase)") || why.contains("h is \(withheldPhrase)"), why)
        }
        XCTAssertEqual(try session("h"), before)
        XCTAssertEqual(try DatasetStore(root: root).loadSessionsStrict().count, 6, "no session was made")
        // Unreadable reservations: neither is cleared.
        try writeValidation(#"{"tune":[],"holdout":["h"]"#)
        XCTAssertThrowsError(try SamplerModel.ingestRefusal(ofClip: "t", root: root))
        XCTAssertThrowsError(try SamplerModel.ingestRefusal(of: videos["t"]!, root: root))
    }

    func testRePullAndMoveOfTheLegacyHoldoutAreRefusedBeforeItsSessionIsTouched() throws {
        try makeProject()
        let sampler = sampler()
        let projects = ProjectsModel(sampler: sampler, defaults: defaults, restoreLastProject: false)
        projects.open(root)
        XCTAssertNotNil(projects.opening, projects.status)
        let before = try session("h")
        for name in ["h", "g"] {
            XCTAssertFalse(projects.repull(name, in: name), name)
            XCTAssertTrue(projects.status.hasPrefix("⛔ \(name) is \(withheldPhrase)"), projects.status)
            projects.moveVideo(name, from: name, to: "t")
            XCTAssertTrue(projects.status.hasPrefix("⛔ \(name) is \(withheldPhrase)"), projects.status)
            XCTAssertTrue(projects.moving.isEmpty)
        }
        XCTAssertTrue(sampler.queue.isEmpty, "nothing was queued for sampling")
        XCTAssertEqual(try session("h"), before, "the session was not deleted for a re-pull that never ran")
        XCTAssertEqual(projects.project?.clips.first { $0.id == "h" }?.videos.count, 1, "the video is still on its card")
        XCTAssertEqual(projects.project?.clips.first { $0.id == "t" }?.videos.count, 1)
    }

    // MARK: - Manual annotation still works on the legacy holdout

    func testMarkingTypingAndProvenanceOfTheLegacyHoldoutStillWork() throws {
        let videos = try makeProject()
        let sampler = sampler()
        let projects = ProjectsModel(sampler: sampler, defaults: defaults, restoreLastProject: false)
        projects.open(root)
        let opening = try XCTUnwrap(projects.opening)
        let h = try session("h")
        // The rally-marking pass writes the marks.
        let marker = RallyMarkModel(sampler: sampler)
        marker.mark(start: 2, end: 6, session: h)
        marker.mark(start: 9, end: 14, session: h)
        XCTAssertEqual(RallyMarkModel.marks(in: h).map(\.start), [2, 9])
        XCTAssertEqual(try RallyTruth.marks(inSidecarOf: videos["h"]!)?.count, 2)
        // The footage-type confirmation is written.
        let record = try FootageTypeConfirmation.confirm(.continuous, video: "h", under: opening, projects: projects, by: "test")
        XCTAssertEqual(record.recordingType, .continuous)
        // The provenance can be edited.
        XCTAssertTrue(projects.setProvenance(videoId: "h", sourceId: nil, sessionId: nil, venueId: "beach-9"))
        XCTAssertEqual(try ReservedVideos.sources(in: root)["h"]?.venueId, "beach-9")
        XCTAssertFalse(ledgerExists, "none of it is a model run")
    }

    func testAFrameOfTheLegacyHoldoutIsBoxedByHandWithoutTheModel() async throws {
        try makeProject()
        let sampler = sampler()
        sampler.openSession(try session("h"))
        while sampler.isLoadingSession { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(sampler.selected, "the holdout's frame opens for review")
        sampler.snapBox(at: CGPoint(x: 0.5, y: 0.5))
        while sampler.snapping != nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(try session("h").frames.first?.boxes.count, 1, "the box is placed and saved")
        XCTAssertFalse(inDataset("images/val/h_0.jpg"), "the edit does not write the holdout's frame into the project dataset")
        XCTAssertFalse(inDataset("labels/val/h_0.txt"))
        XCTAssertTrue(parked("images/val/h_0.jpg"), "it is parked, where review still finds it")
        XCTAssertNotNil(sampler.selected)
        XCTAssertTrue(sampler.status.contains("h is \(withheldPhrase)"), sampler.status)
        XCTAssertFalse(sampler.status.contains("(detector"), "placed from the outline or as a ball-sized box: \(sampler.status)")
        XCTAssertFalse(ledgerExists, "no model ran, so nothing is recorded")
    }
}
