//
//  WithheldConsumerGuardsTests.swift
//  RallyLabTests
//
//  Consumers that ran a model or the pipeline on a project recording without
//  honouring the reservations (D-002, D-017): the project's identities read
//  strictly, the training-data export, the debug video, the score against
//  YOLO, the Track tab's detectors and the sampler's ingest of a new file.
//  Each refuses a withheld recording in its shared function, records an
//  admitted use before a model runs, and refuses when the reservations or
//  the project can't be read.
//

import XCTest
@testable import RallyLab

final class WithheldConsumerGuardsTests: XCTestCase {

    private var base: URL!
    private var root: URL!
    private let F = DatasetSplitManifestTests.self

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rl-guards-\(UUID().uuidString)")
        root = base.appendingPathComponent("P", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("footage"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func writeValidation(_ text: String) throws {
        try text.write(to: PipelineTuner.ValidationSet.file(in: root), atomically: true, encoding: .utf8)
    }

    private func ledger() throws -> [DatasetSplitManifest.ExposureLogRow] { try ExposureLog.readStrict(in: root) }
    private var ledgerExists: Bool { FileManager.default.fileExists(atPath: ExposureLog.url(in: root).path) }

    /// A video file of its own bytes (so its fingerprint is its own), under footage/.
    private func footage(_ name: String, seed: Int) throws -> URL {
        let url = base.appendingPathComponent("footage/\(name).mp4")
        try Data((0..<5000).map { UInt8(($0 * (seed + 2) + seed) % 251) }).write(to: url)
        return url
    }

    /// A project of four recordings, each with a card, a session with its pass complete and an empty marks
    /// sidecar: `l` the lineage holdout, `a` a train card sharing a confirmed sourceId with it (an alias),
    /// `h` the legacy holdout, `t` an ordinary train recording.
    private func makeProject() throws -> [String: URL] {
        var videos: [String: URL] = [:]
        var clips: [PlannedClip] = []
        for (i, name) in ["l", "a", "h", "t"].enumerated() {
            let url = try footage(name, seed: i)
            videos[name] = url
            var session = VideoSession(name: name, sourcePath: url.path, split: "train", addedAt: F.day, frames: [])
            session.ralliesMarked = true
            try DatasetStore(root: root).save(session)
            try Data("[]".utf8).write(to: RallyMarkModel.labelsURL(for: url))
            var source = F.source(name, fingerprint: try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: url.path)),
                                  sourceId: ["l", "a"].contains(name) ? "camera-roll-1" : nil)
            source.clipFile = url.path
            clips.append(F.clip(name, split: "train", videos: [source]))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: "P", createdAt: F.day, framesPerRally: 40, clips: clips)).write(to: root.appendingPathComponent("project.json"))
        try writeValidation(#"{"tune":[],"holdout":["h"],"finalTest":[],"lineageHoldout":["l"]}"#)
        return videos
    }

    private final class Runs { var count = 0 }

    private var emptyExport: TrainingDataExporter.Export {
        TrainingDataExporter.makeExport(videoName: "v.mp4", duration: 10, evidence: [], truth: RallyTruth(marks: [], cuts: [], complete: true), baselineRaw: [])
    }

    // MARK: - 1. project.json is read strictly

    func testUnreadableProjectFileThrowsInsteadOfShrinkingTheAliasClosure() throws {
        let video = try footage("z", seed: 9)
        try writeValidation(#"{"tune":[],"holdout":["b"],"finalTest":["z"]}"#)
        try Data("{not json".utf8).write(to: root.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try ReservedVideos.sources(in: root)) { error in
            XCTAssertTrue(error is ReservedVideos.ProjectUnreadable, "\(error)")
            XCTAssertTrue(error.localizedDescription.contains("project.json"), "the file is named: \(error.localizedDescription)")
            XCTAssertTrue(error.localizedDescription.contains("nothing is cleared"), error.localizedDescription)
        }
        XCTAssertThrowsError(try ReservedVideos.reservedNames(in: root)) { XCTAssertTrue($0 is ReservedVideos.ProjectUnreadable, "\($0)") }
        XCTAssertThrowsError(try ReservedVideos.lineageWithheldNames(in: root)) { XCTAssertTrue($0 is ReservedVideos.ProjectUnreadable, "\($0)") }
        XCTAssertThrowsError(try ReservedVideos.match(video, root: root)) { XCTAssertTrue($0 is ReservedVideos.ProjectUnreadable, "\($0)") }
        XCTAssertThrowsError(try PipelineTuner.ValidationSet.finalTestNames(in: root), "every reader of the reservations stops")
        // A project.json that decodes as JSON but is no project is unreadable too.
        try Data("[]".utf8).write(to: root.appendingPathComponent("project.json"))
        XCTAssertThrowsError(try ReservedVideos.reservedNames(in: root))
    }

    func testMissingProjectFileStillGivesTheListedNames() throws {
        try writeValidation(#"{"tune":[],"holdout":["b"],"finalTest":["z"]}"#)
        XCTAssertTrue(try ReservedVideos.sources(in: root).isEmpty, "a dataset with no project.json has no cards")
        XCTAssertEqual(try ReservedVideos.reservedNames(in: root), ["z"])
        XCTAssertEqual(try ReservedVideos.lineageWithheldNames(in: root), ["b", "z"])
        XCTAssertNil(try ReservedVideos.match(try footage("other", seed: 3), root: root))
    }

    // MARK: - 2. Training-data export

    func testWithheldRecordingsAreNotExportedAsTrainingData() async throws {
        let videos = try makeProject()
        // A byte copy of the lineage holdout under another name, outside the project: the same recording.
        let copy = base.appendingPathComponent("footage/renamed copy.mp4")
        try FileManager.default.copyItem(at: try XCTUnwrap(videos["l"]), to: copy)
        let runs = Runs()
        for (what, video) in [("the lineage holdout", videos["l"]!), ("an alias sharing its confirmed sourceId", videos["a"]!),
                              ("the legacy holdout", videos["h"]!), ("a copy of the lineage holdout", copy)] {
            XCTAssertNotNil(try TrainingDataExporter.exportRefusal(forVideo: video, projectRoots: [root]), what)
            let exported = await HeadlessTrainingExport.export(video, projectRoots: [root]) { _ in runs.count += 1; return ([], 10) }
            XCTAssertFalse(exported, what)
            XCTAssertThrowsError(try TrainingDataExporter.admit(video: video, projectRoots: [root]), what) { XCTAssertTrue($0 is TrainingDataExporter.Withheld, "\($0)") }
            // The sidecar's one writer refuses on its own, whoever calls it (the Pipeline tab's export).
            XCTAssertThrowsError(try TrainingDataExporter.write(emptyExport, forVideo: video, projectRoots: [root]), what) {
                XCTAssertTrue($0 is TrainingDataExporter.Withheld, "\($0)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: TrainingDataExporter.exportURL(for: video).path), "\(what): no sidecar")
        }
        XCTAssertEqual(runs.count, 0, "the pipeline never ran over a withheld recording")
        XCTAssertFalse(ledgerExists, "a refused export leaves no ledger row")
    }

    func testAnAdmittedExportIsOnTheLedgerBeforeThePipelineRuns() async throws {
        let videos = try makeProject()
        let video = try XCTUnwrap(videos["t"])
        let runs = Runs()
        var rowsAtRun: [DatasetSplitManifest.ExposureLogRow] = []
        let exported = await HeadlessTrainingExport.export(video, projectRoots: [root]) { _ in
            runs.count += 1
            rowsAtRun = (try? ExposureLog.readStrict(in: self.root)) ?? []
            return ([], 10)
        }
        XCTAssertTrue(exported)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(rowsAtRun.map(\.video), ["t"], "recorded before the run started")
        let rows = try ledger()
        XCTAssertEqual(rows.count, 1, "the write's own admission is the same use, not a second row")
        XCTAssertEqual(rows.first?.kind, .trainingPackage)
        XCTAssertEqual(rows.first?.ref, "training-data export t.trainingdata.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: TrainingDataExporter.exportURL(for: video).path))
        // A file no project knows keeps its behaviour at the writer: written, no ledger it belongs to.
        let stray = try footage("stray", seed: 7)
        try TrainingDataExporter.write(emptyExport, forVideo: stray, projectRoots: [root])
        XCTAssertTrue(FileManager.default.fileExists(atPath: TrainingDataExporter.exportURL(for: stray).path))
        XCTAssertEqual(try ledger().count, 1)
    }

    /// A second project, `Q`, whose only card is `name`: registered with `video`'s content, cut file elsewhere,
    /// and no session over it. `validation` is its validation.json.
    private func makeSecondProject(card name: String, of video: URL, validation: String) throws -> URL {
        let other = base.appendingPathComponent("Q", isDirectory: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("pipeline_tuning"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        var source = F.source(name, fingerprint: try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: video.path)))
        source.clipFile = "/gone/\(name).mp4"
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: "Q", createdAt: F.day, framesPerRally: 40, clips: [F.clip(name, split: "train", videos: [source])]))
            .write(to: other.appendingPathComponent("project.json"))
        try validation.write(to: PipelineTuner.ValidationSet.file(in: other), atomically: true, encoding: .utf8)
        return other
    }

    func testARecordingWithheldInAnotherProjectByACardWithNoSessionIsNotExported() async throws {
        // `t` is an ordinary train recording of P with its pass complete. Q knows the same file by a card
        // only (its session is missing) and withholds it.
        let video = try XCTUnwrap(try makeProject()["t"])
        let runs = Runs()
        for (what, validation) in [("lineage holdout", #"{"tune":[],"holdout":[],"finalTest":[],"lineageHoldout":["q"]}"#),
                                   ("final test", #"{"tune":[],"holdout":[],"finalTest":["q"]}"#),
                                   ("legacy holdout", #"{"tune":[],"holdout":["q"],"finalTest":[]}"#)] {
            let other = try makeSecondProject(card: "q", of: video, validation: validation)
            XCTAssertNotNil(try TrainingDataExporter.exportRefusal(forVideo: video, projectRoots: [root, other]), what)
            XCTAssertThrowsError(try TrainingDataExporter.admit(video: video, projectRoots: [root, other]), what) { XCTAssertTrue($0 is TrainingDataExporter.Withheld, "\($0)") }
            XCTAssertThrowsError(try TrainingDataExporter.write(emptyExport, forVideo: video, projectRoots: [root, other]), what)
            let exported = await HeadlessTrainingExport.export(video, projectRoots: [root, other]) { _ in runs.count += 1; return ([], 10) }
            XCTAssertFalse(exported, what)
            try FileManager.default.removeItem(at: other)
        }
        XCTAssertEqual(runs.count, 0)
        XCTAssertFalse(ledgerExists, "refused before anything was recorded in the project that does not withhold it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: TrainingDataExporter.exportURL(for: video).path))

        // The same card not withheld: exported, and the use is on both projects' ledgers, under each one's name.
        let other = try makeSecondProject(card: "q", of: video, validation: #"{"tune":[],"holdout":[],"finalTest":[]}"#)
        try TrainingDataExporter.admit(video: video, projectRoots: [root, other])
        XCTAssertEqual(try ledger().map(\.video), ["t"])
        XCTAssertEqual(try ExposureLog.readStrict(in: other).map(\.video), ["q"])
    }

    func testTheAppsExportAsksTheOpenProjectAndEveryProjectRallyLabKnows() throws {
        _ = try makeProject()
        let video = try footage("elsewhere", seed: 9)
        let other = try makeSecondProject(card: "q", of: video, validation: #"{"tune":[],"holdout":[],"finalTest":[]}"#)
        let suite = "rl-guards-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([other.path], forKey: "RallyLab.projects")
        let roots = try TrainingDataExporter.projectRoots(withOpen: root, defaults: defaults).map(\.path)
        XCTAssertEqual(roots.first, root.standardizedFileURL.path, "the open project first")
        XCTAssertTrue(roots.contains(other.standardizedFileURL.path), "and the remembered one")
        XCTAssertEqual(Set(roots).count, roots.count)
        // A remembered project that is not there: its reservations are unknown, nothing is exported.
        try FileManager.default.removeItem(at: other)
        XCTAssertThrowsError(try TrainingDataExporter.projectRoots(withOpen: root, defaults: defaults))
    }

    func testUnreadableReservationsOrLedgerRefuseTheTrainingExport() async throws {
        let videos = try makeProject()
        let video = try XCTUnwrap(videos["t"])
        let runs = Runs()
        // The ledger can't be written (a file where its folder must be): no run, no sidecar.
        try "".write(to: root.appendingPathComponent("manifests"), atomically: true, encoding: .utf8)
        let unrecorded = await HeadlessTrainingExport.export(video, projectRoots: [root]) { _ in runs.count += 1; return ([], 10) }
        XCTAssertFalse(unrecorded)
        XCTAssertThrowsError(try TrainingDataExporter.write(emptyExport, forVideo: video, projectRoots: [root]))
        try FileManager.default.removeItem(at: root.appendingPathComponent("manifests"))
        // validation.json truncated: the reservations are unknown.
        try writeValidation(#"{"tune":[],"holdout":["h"],"finalTest":[]"#)
        XCTAssertThrowsError(try TrainingDataExporter.exportRefusal(forVideo: video, projectRoots: [root]))
        let unknown = await HeadlessTrainingExport.export(video, projectRoots: [root]) { _ in runs.count += 1; return ([], 10) }
        XCTAssertFalse(unknown)
        XCTAssertThrowsError(try TrainingDataExporter.write(emptyExport, forVideo: video, projectRoots: [root]))
        // project.json unreadable beside readable reservations: the aliases are unknown.
        try writeValidation(#"{"tune":[],"holdout":["h"],"finalTest":[],"lineageHoldout":["l"]}"#)
        try Data("{not json".utf8).write(to: root.appendingPathComponent("project.json"))
        let unidentified = await HeadlessTrainingExport.export(video, projectRoots: [root]) { _ in runs.count += 1; return ([], 10) }
        XCTAssertFalse(unidentified)
        XCTAssertEqual(runs.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TrainingDataExporter.exportURL(for: video).path))
        XCTAssertFalse(ledgerExists)
    }

    // MARK: - 3a. Debug video (the Pipeline tab's refusal and ledger row)

    func testDebugVideoRefusalAndLedgerRowAreThePipelineTabs() throws {
        let videos = try makeProject()
        let copy = base.appendingPathComponent("footage/renamed copy.mp4")
        try FileManager.default.copyItem(at: try XCTUnwrap(videos["l"]), to: copy)
        XCTAssertTrue(RallyLabModel.finalTestRefusal(for: copy, root: root)?.contains("reserved") == true, "a copy of a reserved recording, by content")
        XCTAssertNil(RallyLabModel.finalTestRefusal(for: videos["t"]!, root: root))
        try RallyLabModel.recordRallyScoring(videos["t"]!, ref: "RallyLab debug video", root: root)
        XCTAssertEqual(try ledger().map { "\($0.video) \($0.kind.rawValue) \($0.ref)" }, ["t rally_scoring RallyLab debug video"])
        try Data("{not json".utf8).write(to: root.appendingPathComponent("project.json"))
        XCTAssertNotNil(RallyLabModel.finalTestRefusal(for: videos["t"]!, root: root), "an unreadable project refuses every video")
    }

    // MARK: - 3b. Score vs YOLO

    private func package(clip: String) throws -> URL {
        let package = base.appendingPathComponent("package-\(clip)", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try #"{"clip":"\#(clip)","split":"val","size":[1920,1080],"frames":["frames/0.jpg"],"target":0,"balls":[]}"#
            .write(to: package.appendingPathComponent("windows.jsonl"), atomically: true, encoding: .utf8)
        return package
    }

    private func evaluationFailure(clip: String) throws -> String? {
        let noModel = base.appendingPathComponent("none.mlpackage")
        switch HeatEvaluation.run(model: noModel, package: try package(clip: clip), yolo: nil, cuts: [clip: []], root: root, progress: { _, _ in }) {
        case .success: return nil
        case .failure(let failure): return failure.message
        }
    }

    func testScoreAgainstYOLORefusesAPackageWithAReservedClip() throws {
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["z"]}"#)
        let message = try XCTUnwrap(try evaluationFailure(clip: "z"))
        XCTAssertTrue(message.contains("reserved final-test clips (z)"), message)
        XCTAssertFalse(ledgerExists, "a refused run leaves no ledger row")
    }

    func testScoreAgainstYOLOIsOnTheLedgerBeforeAModelIsLoaded() throws {
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["z"]}"#)
        // No model at that path: the run stops there — after the admission, which is the point.
        let message = try XCTUnwrap(try evaluationFailure(clip: "a"))
        XCTAssertTrue(message.contains("Couldn't load"), message)
        let rows = try ledger()
        XCTAssertEqual(rows.map(\.video), ["a"])
        XCTAssertEqual(rows.first?.kind, .detectorEvaluation)
        XCTAssertEqual(rows.first?.ref, "score vs YOLO none on package-a")
    }

    func testScoreAgainstYOLORefusesWhenTheReservationsCantBeRead() throws {
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["z"]"#)   // truncated
        let message = try XCTUnwrap(try evaluationFailure(clip: "a"))
        XCTAssertFalse(message.contains("Couldn't load"), "stopped before the model: \(message)")
        XCTAssertFalse(ledgerExists)
    }

    func testAdmissionRefusesAnyReservedNameAndRecordsTheRest() throws {
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["z"]}"#)
        XCTAssertThrowsError(try ScoringExposure.admit(["a", "z"], kind: .testSetScoring, ref: "export-1", note: nil, root: root)) {
            XCTAssertEqual($0 as? ScoringExposure.Reserved, ScoringExposure.Reserved(names: ["z"]))
        }
        XCTAssertFalse(ledgerExists, "nothing of a refused run is recorded")
        try ScoringExposure.admit(["a", "b"], kind: .testSetScoring, ref: "export-1", note: "models: m", root: root)
        XCTAssertEqual(try ledger().map(\.video), ["a", "b"])
    }

    // MARK: - 3c. Track tab detectors

    func testTrackTabModelsRefuseAReservedRecording() throws {
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":["z"]}"#)
        let why = try XCTUnwrap(TrackLabelModel.modelAdmission(of: "z", in: root))
        XCTAssertTrue(why.contains("reserved"), why)
        XCTAssertFalse(ledgerExists)
        XCTAssertNil(TrackLabelModel.modelAdmission(of: "a", in: root))
        let rows = try ledger()
        XCTAssertEqual(rows.map(\.video), ["a"])
        XCTAssertEqual(rows.first?.kind, .preTracking)
        XCTAssertEqual(rows.first?.ref, "RallyLab Track tab")
    }

    func testTrackTabModelsRefuseAnAliasAndAnUnreadableProject() throws {
        _ = try makeProject()
        XCTAssertNotNil(TrackLabelModel.modelAdmission(of: "a", in: root), "an alias of the lineage holdout is reserved")
        try Data("{not json".utf8).write(to: root.appendingPathComponent("project.json"))
        XCTAssertNotNil(TrackLabelModel.modelAdmission(of: "t", in: root), "the aliases are unknown: nothing is cleared")
        XCTAssertFalse(ledgerExists)
    }

    // MARK: - 3d. Sampler ingest of a new file

    func testSamplerRefusesANewFileThatIsAReservedRecording() throws {
        let videos = try makeProject()
        let copy = base.appendingPathComponent("footage/renamed copy.mp4")
        try FileManager.default.copyItem(at: try XCTUnwrap(videos["l"]), to: copy)
        XCTAssertTrue(try SamplerModel.ingestRefusal(of: copy, root: root)?.contains("reserved") == true, "by content")
        XCTAssertNotNil(try SamplerModel.ingestRefusal(of: videos["a"]!, root: root), "an alias, by path")
        XCTAssertNil(try SamplerModel.ingestRefusal(of: try footage("new", seed: 8), root: root), "a file that matches nothing goes on")
        XCTAssertNil(try SamplerModel.ingestRefusal(of: copy, root: base.appendingPathComponent("no-project")), "a dataset that is no project reserves nothing")
        try writeValidation(#"{"tune":[],"holdout":[],"finalTest":[],"lineageHoldout":["l"]"#)   // truncated
        XCTAssertThrowsError(try SamplerModel.ingestRefusal(of: copy, root: root))
    }

    func testAReservedCardWithNoSessionIsStillTheProjectsRecording() throws {
        // The lineage holdout's session is gone (removed or renamed); its card is still in project.json.
        let videos = try makeProject()
        try FileManager.default.removeItem(at: root.appendingPathComponent("sessions/l.json"))
        let video = try XCTUnwrap(videos["l"])
        let copy = base.appendingPathComponent("footage/renamed copy.mp4")
        try FileManager.default.copyItem(at: video, to: copy)
        XCTAssertEqual(try ReservedVideos.match(video, root: root), .init(session: "l", reserved: true, withheld: true), "the card's own cut file")
        XCTAssertEqual(try ReservedVideos.match(copy, root: root), .init(session: "l", reserved: true, withheld: true), "a copy, by content")
        XCTAssertNotNil(try SamplerModel.ingestRefusal(of: video, root: root), "not sampled into a new session")
        XCTAssertNotNil(try SamplerModel.ingestRefusal(of: copy, root: root))
        XCTAssertNotNil(RallyLabModel.finalTestRefusal(for: copy, root: root), "nor run through the pipeline")
        XCTAssertThrowsError(try TrainingDataExporter.admit(video: copy, projectRoots: [root])) { XCTAssertTrue($0 is TrainingDataExporter.Withheld, "\($0)") }
        // An unreserved card with no session is the project's too: matched, not reserved.
        try FileManager.default.removeItem(at: root.appendingPathComponent("sessions/t.json"))
        XCTAssertEqual(try ReservedVideos.match(videos["t"]!, root: root), .init(session: "t", reserved: false, withheld: false))
        XCTAssertNil(try SamplerModel.ingestRefusal(of: videos["t"]!, root: root))
    }

    func testASessionOfAnotherNameOverALegacyHoldoutCardsFileIsStillTheLegacyHoldout() async throws {
        // The legacy holdout's own session is gone; a session with no card of its own (`other`) sits over the
        // card's cut file. The file is the legacy holdout's recording: `other` is in no closure, and matching
        // it first would clear the recording for export.
        let video = try XCTUnwrap(try makeProject()["h"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("sessions/h.json"))
        var other = VideoSession(name: "other", sourcePath: video.path, split: "train", addedAt: F.day, frames: [])
        other.ralliesMarked = true
        try DatasetStore(root: root).save(other)
        XCTAssertFalse(try ReservedVideos.lineageWithheldNames(in: root).contains("other"), "the fixture: no card links the session into the closure")
        XCTAssertEqual(try ReservedVideos.match(video, root: root), .init(session: "h", reserved: false, withheld: true))
        let copy = base.appendingPathComponent("footage/renamed copy.mp4")
        try FileManager.default.copyItem(at: video, to: copy)
        XCTAssertEqual(try ReservedVideos.match(copy, root: root), .init(session: "h", reserved: false, withheld: true), "a copy, by content")
        let runs = Runs()
        for file in [video, copy] {
            XCTAssertThrowsError(try TrainingDataExporter.admit(video: file, projectRoots: [root])) { XCTAssertTrue($0 is TrainingDataExporter.Withheld, "\($0)") }
            XCTAssertThrowsError(try TrainingDataExporter.write(emptyExport, forVideo: file, projectRoots: [root]))
            let exported = await HeadlessTrainingExport.export(file, projectRoots: [root]) { _ in runs.count += 1; return ([], 10) }
            XCTAssertFalse(exported)
            XCTAssertFalse(FileManager.default.fileExists(atPath: TrainingDataExporter.exportURL(for: file).path))
        }
        XCTAssertEqual(runs.count, 0, "the pipeline never ran over it")
        XCTAssertFalse(ledgerExists)
        // The lineage holdout the same way: a session of another name over its card's file is reserved.
        let lineage = try XCTUnwrap(try makeProject()["l"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("sessions/l.json"))
        try DatasetStore(root: root).save(VideoSession(name: "other2", sourcePath: lineage.path, split: "train", addedAt: F.day, frames: []))
        XCTAssertEqual(try ReservedVideos.match(lineage, root: root), .init(session: "l", reserved: true, withheld: true))
    }

    @MainActor
    func testSamplerQueueFailsTheJobBeforeThePipelineRuns() async throws {
        let videos = try makeProject()
        let copy = base.appendingPathComponent("footage/renamed copy.mp4")
        try FileManager.default.copyItem(at: try XCTUnwrap(videos["l"]), to: copy)
        let suite = "WithheldConsumerGuardsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sampler = SamplerModel(defaults: defaults, root: root)
        sampler.enqueue([copy])
        while sampler.queue.contains(where: { !$0.isFinished }) { try await Task.sleep(nanoseconds: 20_000_000) }
        guard case .failed(let why) = try XCTUnwrap(sampler.queue.first).state else { return XCTFail("\(String(describing: sampler.queue.first?.state))") }
        XCTAssertTrue(why.contains("reserved as final_test"), why)
        XCTAssertEqual(try DatasetStore(root: root).loadSessionsStrict().map(\.name).sorted(), ["a", "h", "l", "t"], "no session was made for it")
    }
}
