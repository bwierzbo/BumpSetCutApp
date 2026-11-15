//
//  StaleManifestConsumersTests.swift
//  RallyLabTests
//
//  Consumers that pick, group or split recordings by a split manifest or a
//  package written earlier (D-036 §5): the decider retune and the net dataset.
//  A manifest counts only while it is of the project as it is now; a manifest
//  written before a provenance change — a recording newly withheld, two
//  recordings confirmed as one — is refused, and so is one that is missing or
//  unreadable. A pool recording the manifest can't vouch for, or that is a
//  withheld recording's footage under another card, is never scored, and a
//  refused run writes no ledger row. The net dataset records the manifest and
//  the closure it was exported against, and leaves out a withheld recording's
//  footage by every identity.
//

import AVFoundation
import XCTest
@testable import RallyLab

@MainActor
final class StaleManifestConsumersTests: XCTestCase {

    private typealias F = DatasetSplitManifestTests
    private typealias X = RallyClassifierExporter

    private var base: URL!
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("rl-stale-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("P", isDirectory: true)
        for folder in ["pipeline_tuning", "sessions", "manifests"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("footage"), withIntermediateDirectories: true)
        suite = "RallyLabTests.StaleManifestConsumers.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - Fixture

    private struct Card {
        var name: String
        /// Which bytes the video holds; two cards with one seed hold the same footage.
        var seed: Int
        var sourceId: String? = nil
        /// The fingerprint the card was registered with, when not its own video's (a cut registered from a cut, D-036).
        var stored: String? = nil
    }

    private func footage(_ name: String) -> URL { base.appendingPathComponent("footage/\(name).mp4") }

    private var manifestURL: URL { NetInventory.manifestURL(in: root) }
    private var ledgerExists: Bool { FileManager.default.fileExists(atPath: ExposureLog.url(in: root).path) }

    /// Six recordings, each with a video of its own bytes, a card, a session with its pass complete and an empty
    /// marks sidecar: `l` the lineage holdout, `h` the legacy holdout, and four train recordings `t1`…`t4`.
    private let cards = [Card(name: "l", seed: 0), Card(name: "h", seed: 1), Card(name: "t1", seed: 2), Card(name: "t2", seed: 3),
                         Card(name: "t3", seed: 4), Card(name: "t4", seed: 5)]

    private func writeProject(_ cards: [Card]) throws {
        var clips: [PlannedClip] = []
        for (i, card) in cards.enumerated() {
            let url = footage(card.name)
            try Data((0..<5000).map { UInt8(($0 * (card.seed + 2) + card.seed) % 251) }).write(to: url)
            var session = VideoSession(name: card.name, sourcePath: url.path, split: "train", addedAt: F.day, frames: [])
            session.ralliesMarked = true
            try DatasetStore(root: root).save(session)
            try Data("[]".utf8).write(to: RallyMarkModel.labelsURL(for: url))
            var source = F.source(card.name, uploader: "up\(i)", fingerprint: try card.stored ?? XCTUnwrap(ProjectsModel.fileFingerprint(atPath: url.path)),
                                  sourceId: card.sourceId)
            source.clipFile = url.path
            clips.append(F.clip(card.name, split: "train", videos: [source]))
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Project(name: "P", createdAt: F.day, framesPerRally: 40, clips: clips)).write(to: root.appendingPathComponent("project.json"))
    }

    private func writeValidation(lineage: [String] = ["l"], holdout: [String] = ["h"]) throws {
        try JSONSerialization.data(withJSONObject: ["tune": [String](), "holdout": holdout, "finalTest": [String](), "lineageHoldout": lineage])
            .write(to: PipelineTuner.ValidationSet.file(in: root))
    }

    /// The split manifest as `--manifest` writes it: from the files as they are now, every video read by content
    /// unless `unread` names it.
    private func writeManifest(unread: Set<String> = []) throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let project = try decoder.decode(Project.self, from: Data(contentsOf: root.appendingPathComponent("project.json")))
        let inputs = DatasetSplitManifest.Inputs(
            project: project, sessions: try DatasetStore(root: root).loadSessionsStrict(), validation: try PipelineTuner.ValidationSet.loadStrict(from: root),
            fingerprint: { $0.fingerprint },
            content: { session in
                guard !unread.contains(session.name) else { return .absent }
                return ProjectsModel.fileFingerprint(atPath: session.sourcePath).map { .read($0) } ?? .unreadable
            },
            previous: nil, discovered: [:], hashes: .current(of: root), generator: "test", now: F.day)
        try DatasetSplitManifest.build(inputs).write(to: manifestURL)
    }

    private func plan(tune: [String] = ["t1", "t2"], eval: [String] = ["t3", "t4"]) -> DeciderRetune.Plan {
        DeciderRetune.Plan(id: "EXP-test", baselineModel: "l1", candidateModel: "l2", tune: tune, eval: eval,
                           grid: .init(preroll: [1], postroll: nil, minGapToMerge: nil, minSegmentLength: nil, endTimeout: nil, startBuffer: nil, skyBallTimeout: nil),
                           objective: .init(mergedRallyCost: 0.5, falseClipCost: 0.25, deadTimeCost: 0.25), preservedShare: 0.95, minRallySec: 1.1653)
    }

    private func refusal(_ plan: DeciderRetune.Plan, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try DeciderRetune.admit(plan, root: root)
            XCTFail("admitted", file: file, line: line)
            return ""
        } catch { return error.localizedDescription }
    }

    // MARK: - The decider retune

    func testACurrentManifestAdmitsThePlan() throws {
        try writeProject(cards); try writeValidation(); try writeManifest()
        let admission = try DeciderRetune.admit(plan(), root: root)
        XCTAssertEqual(admission.groups["t1"], "t1")
        XCTAssertEqual(admission.splits["t3"], "train")
        XCTAssertEqual(admission.splits["l"], "lineageHoldout")
    }

    func testAManifestWrittenBeforeARecordingWasWithheldIsRefusedAndSoIsTheRecordingAfterwards() throws {
        try writeProject(cards); try writeValidation(); try writeManifest()
        // t3 becomes a lineage holdout after the manifest was written: the manifest still calls it train.
        try writeValidation(lineage: ["l", "t3"])
        XCTAssertEqual(try DatasetSplitManifest.readStrict(from: manifestURL)?.videos.first { $0.video == "t3" }?.split, .train)
        let stale = refusal(plan())
        XCTAssertTrue(stale.contains("not the project's current one"), stale)
        XCTAssertTrue(stale.contains("validation.json changed"), stale)
        XCTAssertTrue(stale.contains("--manifest --audit-dataset"), "the refusal says how to refresh: \(stale)")
        // Written again, the manifest is current — and the recording is withheld.
        try writeManifest()
        let withheld = refusal(plan())
        XCTAssertTrue(withheld.contains("t3") && withheld.contains("not scored"), withheld)
        XCTAssertNoThrow(try DeciderRetune.admit(plan(eval: ["t4"]), root: root), "the rest of the pool is still usable")
    }

    func testAProvenanceChangeInTheProjectMakesTheManifestStale() throws {
        try writeProject(cards); try writeValidation(); try writeManifest()
        // The D-036 correction: t2 is confirmed as the lineage holdout's recording (one sourceId on both cards).
        var corrected = cards
        corrected[0].sourceId = "IMG_0823"; corrected[3].sourceId = "IMG_0823"
        try writeProject(corrected)
        let stale = refusal(plan())
        XCTAssertTrue(stale.contains("project.json changed"), stale)
        try writeManifest()
        let withheld = refusal(plan())
        XCTAssertTrue(withheld.contains("t2") && withheld.contains("not scored"), "an alias of the holdout: \(withheld)")
    }

    func testTwoRecordingsConfirmedAsOneAfterTheManifestAreNotTunedAndEvaluatedApart() throws {
        try writeProject(cards); try writeValidation(); try writeManifest()
        XCTAssertNoThrow(try DeciderRetune.admit(plan(), root: root), "apart by the manifest as written")
        // A grouping-only correction (D-036 §4): t1 and t3 are one original. Neither is withheld.
        var corrected = cards
        corrected[2].sourceId = "IMG_3014"; corrected[4].sourceId = "IMG_3014"
        try writeProject(corrected)
        XCTAssertTrue(refusal(plan()).contains("project.json changed"), "the old groups are not used")
        try writeManifest()
        XCTAssertTrue(refusal(plan()).contains("both pools"), "one group can't be tuned on and evaluated on")
    }

    func testAMissingOrUnreadableManifestOrProjectRefuses() throws {
        try writeProject(cards); try writeValidation()
        XCTAssertThrowsError(try DeciderRetune.admit(plan(), root: root)) {
            XCTAssertEqual($0 as? DatasetSplitManifest.CurrencyError, .missing(manifestURL))
            XCTAssertTrue($0.localizedDescription.contains("--manifest --audit-dataset"), $0.localizedDescription)
        }
        try Data("{not a manifest".utf8).write(to: manifestURL)
        XCTAssertThrowsError(try DeciderRetune.admit(plan(), root: root)) { XCTAssertTrue($0 is DatasetSplitManifest.ReadError, "\($0)") }
        // A manifest that records no hash of an input can't be verified, whatever it says.
        try writeManifest()
        var unhashed = try XCTUnwrap(try DatasetSplitManifest.readStrict(from: manifestURL))
        unhashed.hashes.sessions = nil
        try unhashed.write(to: manifestURL)
        XCTAssertTrue(refusal(plan()).contains("records no hash of sessions"))
        // A session changed after the manifest: the manifest's rows are another state's.
        try writeManifest()
        var session = try XCTUnwrap(try DatasetStore(root: root).loadSessionsStrict().first { $0.name == "t1" })
        session.cuts = [CutRange(start: 1, end: 2)]
        try DatasetStore(root: root).save(session)
        XCTAssertTrue(refusal(plan()).contains("sessions changed"))
        // Reservations that can't be read are unknown, not none.
        try writeManifest()
        try Data("{".utf8).write(to: PipelineTuner.ValidationSet.file(in: root))
        XCTAssertThrowsError(try DeciderRetune.admit(plan(), root: root))
    }

    func testAManifestFromBeforeValidationJSONExistedIsStaleOnceItDoes() throws {
        try writeProject(cards); try writeManifest()
        XCTAssertNoThrow(try DeciderRetune.admit(plan(), root: root), "no reservations then, none now: current")
        try writeValidation()
        XCTAssertTrue(refusal(plan()).contains("validation.json was added"))
        try writeManifest()
        try FileManager.default.removeItem(at: PipelineTuner.ValidationSet.file(in: root))
        XCTAssertTrue(refusal(plan()).contains("is gone"))
    }

    /// D-036: a train card registered with one file's fingerprint whose video is byte for byte the lineage
    /// holdout's. No name, sourceId or stored fingerprint connects the two; the content the manifest read does.
    func testAPoolRecordingThatIsAWithheldRecordingsFootageIsRefusedByContent() throws {
        var copies = cards
        copies[3] = Card(name: "t2", seed: 0, stored: "file:5000:the-file-it-was-registered-from")
        try writeProject(copies); try writeValidation(); try writeManifest()
        XCTAssertFalse(try ReservedVideos.lineageWithheldNames(in: root).contains("t2"), "not withheld by any card identity")
        let why = refusal(plan())
        XCTAssertTrue(why.contains("t2 shares fp:") && why.contains("withheld l"), why)
        XCTAssertNoThrow(try DeciderRetune.admit(plan(tune: ["t1"]), root: root))
    }

    /// The same for two recordings neither of which is withheld (D-036 §1's train-with-train pairs): one piece of
    /// footage under two cards is one recording group, so it is not tuned on under one name and evaluated on under the other.
    func testTheSameFootageUnderTwoCardsIsOneGroup() throws {
        var copies = cards
        copies[4] = Card(name: "t3", seed: 2, stored: "file:5000:another-file-it-was-registered-from")   // t1's bytes
        try writeProject(copies); try writeValidation(); try writeManifest()
        XCTAssertTrue(refusal(plan()).contains("both pools"))
        XCTAssertEqual(try DeciderRetune.admit(plan(tune: ["t1", "t3"], eval: ["t2", "t4"]), root: root).groups["t3"], "t1")
    }

    func testAPoolRecordingTheManifestCouldNotIdentifyIsRefused() throws {
        try writeProject(cards); try writeValidation(); try writeManifest(unread: ["t4"])
        let unread = refusal(plan())
        XCTAssertTrue(unread.contains("t4's video was not read") && unread.contains("absent"), unread)
        XCTAssertTrue(unread.contains("--manifest --audit-dataset"), unread)
        // A row with no file identity at all.
        try writeManifest()
        var manifest = try XCTUnwrap(try DatasetSplitManifest.readStrict(from: manifestURL))
        let i = try XCTUnwrap(manifest.videos.firstIndex { $0.video == "t1" })
        manifest.videos[i].fingerprint = nil; manifest.videos[i].contentFingerprint = nil
        try manifest.write(to: manifestURL)
        XCTAssertTrue(refusal(plan()).contains("t1 has no file identity"))
        // A recording with no row.
        manifest.videos.remove(at: i)
        try manifest.write(to: manifestURL)
        XCTAssertTrue(refusal(plan()).contains("t1 is not in the split manifest"))
    }

    /// The whole command: a run refused for a stale manifest, or for a recording withheld since its pass was
    /// cached, scores nothing — no report folder, no ledger row, the cached pass left as it was.
    func testARefusedRunScoresNothingAndWritesNoLedgerRow() async throws {
        try writeProject(cards); try writeValidation()
        let projects = ProjectsModel(sampler: SamplerModel(defaults: defaults, root: base.appendingPathComponent("empty")), defaults: defaults, restoreLastProject: false)
        projects.open(root)
        XCTAssertEqual(projects.projectDir?.path, root.standardizedFileURL.path)
        try writeManifest()
        // A pass cached for t3 while it was a tune recording.
        let cache = root.appendingPathComponent("pipeline_tuning/evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let cached = cache.appendingPathComponent("t3__abcdef012345.evidence")
        try Data("a cached pass".utf8).write(to: cached)
        let planURL = base.appendingPathComponent("plan.json")
        try JSONEncoder().encode(plan()).write(to: planURL)
        let out = base.appendingPathComponent("report", isDirectory: true)
        var lines: [String] = []
        var modelsAsked = 0
        func run() async -> Bool {
            lines = []
            return await DeciderRetune.run(plan: planURL, out: out, passesOnly: true, projects: projects, models: { _ in modelsAsked += 1; return nil }) { lines.append($0) }
        }

        // t3 is withheld after the manifest was written.
        try writeValidation(lineage: ["l", "t3"])
        var ok = await run()
        XCTAssertFalse(ok)
        XCTAssertTrue(lines.contains { $0.contains("not the project's current one") && $0.contains("--manifest --audit-dataset") }, "\(lines)")
        // The manifest written again: the plan names a withheld recording.
        try writeManifest()
        ok = await run()
        XCTAssertFalse(ok)
        XCTAssertTrue(lines.contains { $0.contains("Plan refused") && $0.contains("t3") && $0.contains("not scored") }, "\(lines)")

        XCTAssertEqual(modelsAsked, 0, "refused before any model is looked up")
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no report")
        XCTAssertFalse(ledgerExists, "a refused run is not a use: no ledger row")
        XCTAssertEqual(try Data(contentsOf: cached), Data("a cached pass".utf8))
    }

    // MARK: - Training from a package (the Plan page, the Models tab)

    /// A package folder in the project's exports: a plain multi-frame export, or with `lineage` the record a
    /// lineage package carries.
    private func package(_ name: String, lineage: Bool = false) throws -> URL {
        let folder = root.appendingPathComponent("exports/\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"clip":"t1","split":"train"}"#.utf8).write(to: folder.appendingPathComponent("windows.jsonl"))
        if lineage { try Data("{}".utf8).write(to: folder.appendingPathComponent(LineagePackage.recordFile)) }
        return folder
    }

    private func planModel() -> TrainingPlanModel {
        let plan = TrainingPlanModel(library: ModelLibrary(sampler: SamplerModel(defaults: defaults, root: root)))
        plan.reload()
        return plan
    }

    private var exports: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("exports").path)) ?? []).sorted()
    }

    /// Codex on #180: the Plan page exported a plain multi-frame package, recorded the round, and only then met
    /// the trainer's refusal. A round now trains from a lineage package or is refused first.
    func testAPlanRoundWithoutALineagePackageIsRefusedBeforeAnythingIsExportedOrRecorded() async throws {
        try writeProject(cards); try writeValidation(); try writeManifest()
        let plain = try package("P-multiframe-20261112-0900")
        let plan = planModel()
        let round = TrainingPlan.rounds[0]
        plan.train(round, progress: PlanProgress(videos: [], round: round))
        XCTAssertFalse(plan.isRunning, "refused at once: nothing to wait for")
        XCTAssertTrue(plan.status.contains("Round 1 not started") && plan.status.contains("--package-l2") && plan.status.contains("D-018"), plan.status)
        XCTAssertTrue(plan.history.isEmpty, "no round recorded")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("training_plan.json").path))
        XCTAssertEqual(exports, ["P-multiframe-20261112-0900"], "nothing exported")
        XCTAssertFalse(plan.library.isBusy); XCTAssertNil(plan.library.lastMultiFramePackage)
        // The same rule wherever a package is handed to the desktop: the Models tab, a round carried on.
        let lab = plan.library.heatmaps
        let started = await lab.startDesktopRun(package: plain, arguments: ["--size", "512"])
        XCTAssertNil(started)
        XCTAssertTrue(lab.desktopLine.contains("P-multiframe-20261112-0900 is not a lineage package") && lab.desktopLine.contains("--package-l2"), lab.desktopLine)
        lab.reload()
        lab.trainOnDesktop(size: 512)
        XCTAssertFalse(lab.desktopBusy)
        XCTAssertTrue(lab.desktopLine.contains("No lineage package"), lab.desktopLine)
    }

    func testAPlanRoundThatCannotStartIsNotRecordedAndALineagePackageIsTheOneChosen() async throws {
        // No split manifest: the withheld closure can't be written, so nothing may start (and nothing here reaches the desktop).
        try writeProject(cards); try writeValidation()
        _ = try package("P-val-multiframe-20261112-0900")            // a test set: later in the list by name, not a lineage package
        let lineage = try package("P-L2-multiframe-20261021-1917", lineage: true)
        let plan = planModel()
        plan.library.heatmaps.reload()
        XCTAssertEqual(plan.library.heatmaps.lineagePackage?.lastPathComponent, "P-L2-multiframe-20261021-1917")
        XCTAssertNil(HeatmapLab.trainingRefusal(package: lineage))
        let round = TrainingPlan.rounds[0]
        plan.train(round, progress: PlanProgress(videos: [], round: round))
        while plan.isRunning { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(plan.status.contains("Round 1 not started") && plan.status.contains("No split manifest"), plan.status)
        XCTAssertTrue(plan.history.isEmpty, "a round that did not start is not on record")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("training_plan.json").path))
        XCTAssertFalse(plan.library.heatmaps.desktopBusy)
        XCTAssertEqual(exports, ["P-L2-multiframe-20261021-1917", "P-val-multiframe-20261112-0900"])
    }

    // MARK: - The net dataset

    private func closure(names: [String] = ["l"], sourceIds: [String] = [], fingerprints: [String] = []) -> X.Withheld {
        X.Withheld(names: names, sourceIds: sourceIds, fingerprints: fingerprints)
    }

    func testTheNetExportLeavesOutAWithheldRecordingsFootageByEveryIdentity() {
        func src(_ v: String, fp: String = "fp-own", sourceId: String? = nil) -> NetDatasetExport.Source {
            NetDatasetExport.Source(video: v, clip: v, camera: "Tripod / corner", url: URL(fileURLWithPath: "/nowhere/\(v).mp4"), fingerprint: fp,
                                    sourceId: sourceId, cuts: [])
        }
        let sources = [src("a_ok"), src("b_same_source", sourceId: "IMG_0823"), src("c_registered_from_the_holdouts_file", fp: "file:holdout-video"),
                       src("d_holds_the_holdouts_video", fp: "fp-d"), src("e_unreadable", fp: "fp-e"), src("f_unlabeled"), src("l", fp: "fp-l")]
        let labels = Dictionary(uniqueKeysWithValues: sources.filter { $0.video != "f_unlabeled" }.map { ($0.video, NetLabelsTests.label(fingerprint: $0.fingerprint!)) })
        let withheld = closure(sourceIds: ["IMG_0823"], fingerprints: ["file:holdout-original", "file:holdout-video"])
        var read: [String] = []
        let plan = NetDatasetExport.plan(labels: labels, sources: sources, withheld: withheld) { s in
            read.append(s.video)
            return ["a_ok": "file:a", "b_same_source": "file:b", "c_registered_from_the_holdouts_file": "file:c", "d_holds_the_holdouts_video": "file:holdout-video"][s.video]
        }
        XCTAssertEqual(plan.export.map(\.video), ["a_ok"])
        XCTAssertEqual(plan.export.first?.contentFingerprint, "file:a", "the entry carries what its video is")
        XCTAssertEqual(plan.skipped, [.init(video: "b_same_source", reason: NetDatasetExport.withheldFootage("sourceId")),
                                      .init(video: "c_registered_from_the_holdouts_file", reason: NetDatasetExport.withheldFootage("fingerprint")),
                                      .init(video: "d_holds_the_holdouts_video", reason: NetDatasetExport.withheldFootage("content")),
                                      .init(video: "e_unreadable", reason: NetDatasetExport.videoNotRead),
                                      .init(video: "f_unlabeled", reason: "unlabeled"),
                                      .init(video: "l", reason: "withheld")])
        XCTAssertEqual(read, ["a_ok", "b_same_source", "c_registered_from_the_holdouts_file", "d_holds_the_holdouts_video", "e_unreadable"],
                       "a withheld or unlabeled recording's video is never read")
    }

    func testTheProjectClosureIsOfTheProjectAsItIsNowOrNothing() throws {
        var withSource = cards
        withSource[0].sourceId = "IMG_0823"
        try writeProject(withSource); try writeValidation()
        XCTAssertThrowsError(try X.ProjectClosure.current(in: root)) { XCTAssertEqual($0 as? DatasetSplitManifest.CurrencyError, .missing(manifestURL)) }
        try writeManifest()
        let closure = try X.ProjectClosure.current(in: root)
        XCTAssertEqual(closure.withheld.names, ["h", "l"])
        XCTAssertEqual(closure.withheld.sourceIds, ["IMG_0823"])
        XCTAssertEqual(Set(closure.withheld.fingerprints), Set(try ["h", "l"].map { try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: footage($0).path)) }))
        XCTAssertEqual(closure.withheld.closureSha256, X.closureSha256(closure.withheld))
        let now = DatasetSplitManifest.Hashes.current(of: root)
        XCTAssertEqual(closure.splitManifest, X.SplitHashes(now, manifestJson: try XCTUnwrap(DatasetSplitManifest.sha256(of: manifestURL))))
        XCTAssertNotNil(now.validationJson)

        // The file a trainer is given: the closure's lists at the top level, as --withheld reads them, and the hashes.
        let file = try XCTUnwrap(try JSONSerialization.jsonObject(with: closure.file(project: "P", now: F.day)) as? [String: Any])
        XCTAssertEqual(file["names"] as? [String], ["h", "l"])
        XCTAssertEqual(file["sourceIds"] as? [String], ["IMG_0823"])
        XCTAssertEqual((file["fingerprints"] as? [String])?.count, 2)
        XCTAssertEqual(file["closureSha256"] as? String, closure.withheld.closureSha256)
        XCTAssertEqual((file["splitManifest"] as? [String: String])?["projectJson"], now.projectJson)
        XCTAssertEqual((file["splitManifest"] as? [String: String])?["validationJson"], now.validationJson)
        XCTAssertEqual(file["project"] as? String, "P")
        XCTAssertEqual(file["createdAt"] as? String, "2026-10-20T00:00:00Z")

        // A recording withheld after the manifest: no closure, so no package and no closure file, until it is rebuilt.
        try writeValidation(lineage: ["l", "t3"])
        XCTAssertThrowsError(try X.ProjectClosure.current(in: root)) {
            XCTAssertEqual($0 as? DatasetSplitManifest.CurrencyError, .stale("validation.json changed since it was built"))
        }
        try writeManifest()
        XCTAssertEqual(try X.ProjectClosure.current(in: root).withheld.names, ["h", "l", "t3"])
        // Nothing withheld proves nothing.
        try writeValidation(lineage: [], holdout: [])
        try writeManifest()
        XCTAssertThrowsError(try X.ProjectClosure.current(in: root)) { XCTAssertEqual($0 as? X.Failure, .emptyClosure) }
    }

    /// A 1 s H.264 clip of one colour.
    private func video(_ name: String, width: Int = 320, height: Int = 180, shade: UInt8) async throws -> URL {
        let url = footage(name)
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let pixels = buffer
            else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels)!, Int32(shade), CVPixelBufferGetBytesPerRow(pixels) * height)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            guard adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    func testTheNetDatasetRecordsTheManifestAndTheClosureItWasExportedAgainst() async throws {
        let a = try await video("a", shade: 60), copy = try await video("copy", shade: 200)
        let aPrint = try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: a.path)), copyPrint = try XCTUnwrap(ProjectsModel.fileFingerprint(atPath: copy.path))
        func label(_ fingerprint: String) -> NetLabel {
            NetLabel(time: 0.5, box: NetLabelsTests.box, corners: NetQuad(rect: NetLabelsTests.box.rect), proposed: false, adjusted: false,
                     reviewedAt: F.day, frameWidth: 320, frameHeight: 180, fingerprint: fingerprint)
        }
        // `copy` is registered under a fingerprint of its own and holds a withheld recording's video.
        let sources = [NetDatasetExport.Source(video: "a", clip: "a", camera: "Tripod", url: a, fingerprint: aPrint, sourceId: "IMG_1", cuts: []),
                       NetDatasetExport.Source(video: "copy", clip: "copy", camera: "Tripod", url: copy, fingerprint: "file:1:registered", cuts: [])]
        let closure = X.ProjectClosure(splitManifest: try XCTUnwrap(X.SplitHashes(.init(projectJson: "p", sessions: "s", validationJson: "v"), manifestJson: "m")),
                                       withheld: self.closure(fingerprints: [copyPrint]))
        let dir = base.appendingPathComponent("net-dataset", isDirectory: true)
        let written = try await NetDatasetExport.write(labels: ["a": label(aPrint), "copy": label("file:1:registered")], sources: sources, closure: closure,
                                                       project: "P", to: dir)
        XCTAssertEqual(written.entries.map(\.video), ["a"])
        XCTAssertEqual(written.skipped, [.init(video: "copy", reason: NetDatasetExport.withheldFootage("content"))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("images/copy.jpg").path), "no frame of it is written")

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(NetDatasetExport.Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("net-dataset.json")))
        XCTAssertEqual(record.splitManifest, closure.splitManifest)
        XCTAssertEqual(record.withheld, closure.withheld)
        XCTAssertEqual(record.entries.first?.sourceId, "IMG_1")
        XCTAssertEqual(record.entries.first?.fingerprint, aPrint)
        XCTAssertEqual(record.entries.first?.contentFingerprint, aPrint)

        // A record from before packages carried provenance still reads — as one without any.
        var old = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("net-dataset.json"))) as? [String: Any])
        old["splitManifest"] = nil; old["withheld"] = nil
        old["entries"] = (old["entries"] as? [[String: Any]])?.map { $0.filter { !["sourceId", "contentFingerprint"].contains($0.key) } }
        let before = try decoder.decode(NetDatasetExport.Manifest.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(before.splitManifest); XCTAssertNil(before.withheld); XCTAssertNil(before.entries.first?.contentFingerprint)
    }
}
