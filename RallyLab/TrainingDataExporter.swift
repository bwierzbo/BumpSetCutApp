//
//  TrainingDataExporter.swift
//  RallyLab
//
//  Serializes a labeled session — per-frame pipeline evidence, hand-labeled
//  rally intervals, and the rule pipeline's raw decided intervals — to a
//  sidecar JSON (`video.trainingdata.json`) consumed by
//  scripts/train_rally_classifier.py to fit a trajectory-state classifier
//  offline and evaluate it against the rule-based decider.
//
//  Raw per-frame fields are exported (not derived window features) so the
//  Python side can iterate on feature engineering without re-running
//  detection here.
//

import CoreGraphics
import Foundation

enum TrainingDataExporter {

    /// One processed frame. Field names are kept short — a 20-minute video
    /// exports tens of thousands of rows.
    struct FrameRow: Codable {
        let t: Double           // PTS seconds
        let ball: Int           // any court-eligible detection this frame
        let proj: Int           // physics gate accepted the selected track
        let r2: Double?         // parabola fit quality (selected track)
        let grav: Double?       // gravity signature (selected track)
        let x: Double?          // selected track center (Vision-normalized)
        let y: Double?          // 1.0 = top of frame
        let size: Double?       // selected candidate ball size (√bbox area)
        let dets: Int           // kept detections
        let courtDets: Int      // detections inside the court bounds
        let conf: Double?       // max detection confidence
        let move: String?       // movement classification (airborne/carried/…)
        let rej: String?        // gate rejection reason (nil = accepted)
        let cands: Int          // candidate trajectories (multi-court pressure)
    }

    struct IntervalDTO: Codable {
        let start: Double
        let end: Double
    }

    struct Export: Codable {
        let schema: Int
        let video: String
        let duration: Double
        let netTopY: Double?    // Vision-normalized net box top (1 = frame top)
        let netBottomY: Double?
        let labels: [IntervalDTO]       // ground truth: the rallies (kind rally, or none — a legacy mark), outside the cuts
        let excluded: [IntervalDTO]     // the missed serves and "not a rally" marks, outside the cuts: excluded spans — no frame of them trains, a decision inside one is unscored (schema 2)
        let baselineRaw: [IntervalDTO]  // rule pipeline, raw decided boundaries, outside the cuts
        let cuts: [IntervalDTO]         // cut ranges (not footage; D-030): no frame inside, and the trainer masks its own decisions with them
        /// Every rally in the recording is marked, so every frame outside `labels`, `excluded` and `cuts` is not-rally time.
        /// Always true in an export this build writes: a recording whose pass is not complete is not exported.
        let complete: Bool
        let frames: [FrameRow]
    }

    /// Schema 2 (2026-11-04): `labels` are the rallies by kind, `excluded` the missed serves and other marks (the
    /// scoring contract's excluded spans), `complete` says the pass is finished. A schema-1 export decoded every
    /// mark as a rally; the trainer refuses one.
    static let schema = 2

    /// `truth`: the recording's marks and cut ranges read as RallyTruth — frames inside a cut are left out,
    /// labels, excluded spans and baseline rallies are taken outside the cuts (the frames inside an excluded span
    /// stay, for the trainer to mask). The pass must be complete: what lies outside the marks of an unfinished
    /// pass is unknown, not not-rally time.
    static func makeExport(
        videoName: String,
        duration: Double,
        evidence: [VideoProcessor.FrameEvidence],
        truth: RallyTruth,
        baselineRaw: [Interval]
    ) -> Export {
        precondition(truth.complete, "an export is written only for a complete marking pass")
        let cuts = truth.cuts
        // The net too comes from footage: a replay or intro inside a cut may show another view.
        let retained = evidence.filter { !cuts.contains($0.time) }
        let net = retained.lazy.compactMap { $0.detectedNet }.first
        let frames = retained.map { f -> FrameRow in
            let selected = f.candidates.first { $0.isSelected }
            return FrameRow(
                t: f.time,
                ball: f.hasBall ? 1 : 0,
                proj: f.isProjectile ? 1 : 0,
                r2: f.rSquared,
                grav: f.gravitySignature,
                x: f.trackPoint.map { Double($0.x) },
                y: f.trackPoint.map { Double($0.y) },
                size: selected.map { Double($0.ballSize) },
                dets: f.detections.count,
                courtDets: f.detections.filter { !$0.isOffCourt }.count,
                conf: f.detections.map { Double($0.confidence) }.max(),
                move: f.movementType?.rawValue,
                rej: f.rejectionReason,
                cands: f.candidates.count
            )
        }
        return Export(
            schema: Self.schema,
            video: videoName,
            duration: duration,
            netTopY: net.map { Double($0.box.maxY) },
            netBottomY: net.map { Double($0.box.minY) },
            labels: truth.positives.map { IntervalDTO(start: $0.start, end: $0.end) },
            excluded: truth.excluded.map { IntervalDTO(start: $0.start, end: $0.end) },
            baselineRaw: baselineRaw.outside(cuts).map { IntervalDTO(start: $0.start, end: $0.end) },
            cuts: cuts.map { IntervalDTO(start: $0.start, end: $0.end) },
            complete: true,
            frames: frames
        )
    }

    /// The project session over this video, if any project has one — the recording recognised as the
    /// Pipeline tab recognises it (`ReservedVideos.match`: by path, by name, or by the file's content, so a
    /// copy under another name is the same recording) over every project this Mac knows
    /// (`ProjectsModel.savedProjectRoots`: the remembered list, the last opened and the default location; a
    /// project may live anywhere). nil for a video no project knows. Throws when a project's sessions or
    /// reservations can't all be read: an unreadable session is an unknown session, not none, and nothing
    /// may go out as if its cuts were none or its pass complete (fails closed).
    static func session(forVideo url: URL, projectRoots: [URL]? = nil) throws -> VideoSession? {
        // A remembered project that is not there is unknown: the lookup throws, the export stops.
        for project in try projectRoots ?? ProjectsModel.savedProjectRoots() {
            let sessions = try DatasetStore(root: project).loadSessionsStrict()
            guard let match = try ReservedVideos.match(url, root: project) else { continue }
            // A card of the project names it but no session is over it (its sessions folder or this session
            // is missing or renamed): its cuts are unknown, not none (Codex on #139).
            guard let session = sessions.first(where: { $0.name == match.session }) else { throw SessionUnavailable(video: match.session, project: project.lastPathComponent) }
            return session
        }
        return nil
    }

    /// The cut ranges of the project session over this video (not footage; D-030). A video no project knows
    /// has no cuts, by construction; an unreadable project is unknown cuts, not none (throws).
    static func cutRanges(forVideo url: URL, projectRoots: [URL]? = nil) throws -> [CutRange] {
        try session(forVideo: url, projectRoots: projectRoots)?.cutRanges ?? []
    }

    /// Why the video cannot be exported: it is a withheld recording, or its pass is not known to be complete.
    /// nil when it can. A video no project knows cannot prove its pass complete (D-002: the session is the
    /// record); an unreadable project throws.
    static func exportRefusal(forVideo url: URL, projectRoots: [URL]? = nil) throws -> String? {
        if let withheld = try projectUses(ofVideo: url, projectRoots: projectRoots).refusal { return withheld }
        guard let session = try session(forVideo: url, projectRoots: projectRoots) else {
            return "no project session over it — whether every rally is marked can't be known, so what lies outside the marks is unknown, not not-rally time"
        }
        return RallyTruth.incompleteReason(session)
    }

    /// A project card names the recording — by its cut file's path or name, or by content — though no session is over it.
    struct SessionUnavailable: LocalizedError, Equatable {
        let video: String
        let project: String
        var errorDescription: String? { "\(project) knows \(video) but has no session over it (missing or renamed): its cut ranges can't be known" }
    }

    // MARK: - Withheld recordings and the exposure ledger (D-002, D-017)

    /// The recording is withheld from training: nothing of it is exported.
    struct Withheld: LocalizedError, Equatable {
        let reason: String
        var errorDescription: String? { "\(reason) — not exported as training data." }
    }

    /// Every project that knows this video (a recording can be a card of more than one project) with the name
    /// it has there, and why it may not be exported when one of them withholds it: reserved there — final test,
    /// a candidate or the lineage holdout, recognised as `ReservedVideos.match` recognises it, so a copy under
    /// another name is refused by content, and a card with no session over it is recognised too — or in that
    /// project's lineage-withheld closure (the legacy holdout too, and every alias; D-017), which `match` looks
    /// through before any video that is not withheld, so a session of another name over a legacy-holdout
    /// card's file is still that card's recording. Every project is asked, not only the first that knows the video: withheld in one is
    /// withheld. Throws when a project's reservations, cards or sessions can't be read (fails closed).
    private static func projectUses(ofVideo url: URL, projectRoots: [URL]?) throws -> (known: [(project: URL, name: String)], refusal: String?) {
        var known: [(project: URL, name: String)] = []
        for project in try projectRoots ?? ProjectsModel.savedProjectRoots() {
            guard let match = try ReservedVideos.match(url, root: project) else { continue }
            let name = match.session
            if match.reserved { return ([], "\(name) is reserved as final_test (D-002) in \(project.lastPathComponent)") }
            if match.withheld {
                return ([], "\(name) is withheld in \(project.lastPathComponent) — a lineage or legacy holdout, or an alias of one (D-017)")
            }
            known.append((project, name))
        }
        return (known, nil)
    }

    /// The projects an export from the app asks: the open one, whose session the marks came from, and every
    /// other project RallyLab knows — as the headless export asks them, so a recording withheld in another
    /// project is refused here too and its use is on that project's ledger. Throws when a remembered project
    /// is not there (its reservations are unknown; fails closed).
    static func projectRoots(withOpen open: URL?, defaults: UserDefaults = .standard) throws -> [URL] {
        var seen = Set<String>()
        return ((open.map { [$0] } ?? []) + (try ProjectsModel.savedProjectRoots(defaults: defaults)))
            .map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    /// Admits the video to a training-data export, or throws: `Withheld` for a withheld recording, and what the
    /// reservations or the ledger throw when they can't be read or written (fails closed). When this returns,
    /// the use is on the exposure ledger of every project that knows the video — the headless export calls it
    /// before the pipeline runs, so an interrupted run is on record, and `write` calls it again (the ledger keeps
    /// one row), so no caller can write a sidecar past it. A file no project knows is admitted with no row: there
    /// is no ledger it belongs to.
    static func admit(video url: URL, projectRoots: [URL]? = nil, now: Date = Date()) throws {
        let uses = try projectUses(ofVideo: url, projectRoots: projectRoots)
        if let refusal = uses.refusal { throw Withheld(reason: refusal) }
        for use in uses.known {
            try ExposureLog.record(videos: [use.name], kind: .trainingPackage, ref: "training-data export " + exportURL(for: url).lastPathComponent,
                                   note: "per-frame pipeline evidence and marks for the rally classifier trainer", in: use.project, now: now)
        }
    }

    /// Writes the video's export sidecar — once `admit` lets it: the one way a `.trainingdata.json` is written,
    /// so the Pipeline tab's export and the headless one pass the same refusal and leave the same ledger row.
    static func write(_ export: Export, forVideo videoURL: URL, projectRoots: [URL]? = nil) throws {
        try admit(video: videoURL, projectRoots: projectRoots)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(export).write(to: exportURL(for: videoURL), options: .atomic)
    }

    /// Sidecar path convention: `game.mov` → `game.trainingdata.json`.
    static func exportURL(for videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("trainingdata.json")
    }
}

// MARK: - Headless batch export

/// `RallyLab --export-training-data [path]` runs the full pipeline over every
/// labeled video (one with a `.rallylabels.json` sidecar) under `path` (a
/// directory or a single video; defaults to ~/Movies/RallyLab), writes each
/// export sidecar, and exits — so training data can be produced from the
/// command line without clicking through the UI.
enum HeadlessTrainingExport {

    static func runIfRequested() {
        guard let idx = CommandLine.arguments.firstIndex(of: "--export-training-data") else { return }
        let defaultDir = FileManager.default
            .urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RallyLab", isDirectory: true).path
        let next = CommandLine.arguments.indices.contains(idx + 1) ? CommandLine.arguments[idx + 1] : defaultDir
        let path = next.hasPrefix("--") ? defaultDir : next
        Task.detached {
            let ok = await run(path: path)
            exit(ok ? 0 : 1)
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    static func run(path: String) async -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            log("❌ No such path: \(path)")
            return false
        }

        // Labeled videos = every rallylabels sidecar with its video present.
        var videos: [URL] = []
        if isDir.boolValue {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for sidecar in contents where sidecar.lastPathComponent.hasSuffix(".rallylabels.json") {
                let base = sidecar.lastPathComponent.replacingOccurrences(of: ".rallylabels.json", with: "")
                if let video = contents.first(where: {
                    $0.deletingPathExtension().lastPathComponent == base
                        && !$0.lastPathComponent.hasSuffix(".json")
                }) {
                    videos.append(video)
                }
            }
        } else {
            videos = [URL(fileURLWithPath: path)]
        }

        guard !videos.isEmpty else {
            log("❌ No labeled videos (video + .rallylabels.json) found in \(path)")
            return false
        }
        log("Exporting training data for \(videos.count) labeled video(s)…")

        var allSucceeded = true
        for video in videos {
            if !(await export(video)) { allSucceeded = false }
        }
        return allSucceeded
    }

    /// The pipeline over one video: its frame evidence and its duration.
    typealias Pipeline = (URL) async throws -> (evidence: [VideoProcessor.FrameEvidence], duration: Double)

    /// The app's pipeline at production defaults — the baseline being challenged.
    static func pipeline(_ video: URL) async throws -> (evidence: [VideoProcessor.FrameEvidence], duration: Double) {
        let processor = VideoProcessor()
        processor.config = ProcessorConfig()
        processor.collectFrameEvidence = true
        do {
            _ = try await processor.analyzeVideo(video)
        } catch ProcessingError.noRalliesDetected {
            // Zero predictions is a valid outcome; evidence was still captured.
        }
        return (processor.frameEvidence, processor.lastVideoDurationSec)
    }

    /// One video's export: refused when it is withheld or its pass is not complete, on the exposure ledger
    /// before the pipeline runs over it, then the sidecar. False when nothing was exported. `pipeline` is the
    /// app's in RallyLab; a test's stand-in shows whether a run was started.
    static func export(_ video: URL, projectRoots: [URL]? = nil, pipeline: Pipeline = HeadlessTrainingExport.pipeline) async -> Bool {
        // The marks by kind, the session's cuts, and the pass complete — or no export (fails closed).
        let truth: RallyTruth
        do {
            if let why = try TrainingDataExporter.exportRefusal(forVideo: video, projectRoots: projectRoots) {
                log("❌ \(video.lastPathComponent): \(why). Not exported.")
                return false
            }
            guard let session = try TrainingDataExporter.session(forVideo: video, projectRoots: projectRoots), let read = try RallyTruth.of(session) else {
                log("❌ \(video.lastPathComponent): the marks can't be read beside the video. Not exported.")
                return false
            }
            truth = read
        } catch {
            log("❌ \(video.lastPathComponent): the project can't be read — \(error.localizedDescription) Not exported.")
            return false
        }
        // Running the pipeline over a project video is a use (D-002): on the ledger before the run starts,
        // and no run when it can't be recorded.
        do { try TrainingDataExporter.admit(video: video, projectRoots: projectRoots) } catch {
            log("❌ \(video.lastPathComponent): \(error.localizedDescription) Not exported.")
            return false
        }
        if !truth.cuts.isEmpty { log("  \(video.lastPathComponent): cut ranges left out (D-030)") }
        log("▸ \(video.lastPathComponent): running pipeline (\(truth.positives.count) rallies, \(truth.excluded.count) excluded missed-serve/other marks"
            + (truth.positives.isEmpty ? " — negative-only" : "") + ")…")
        let evidence: [VideoProcessor.FrameEvidence], duration: Double
        do { (evidence, duration) = try await pipeline(video) } catch {
            log("❌ \(video.lastPathComponent): pipeline failed: \(error.localizedDescription)")
            return false
        }
        let baseline = EvidenceReplayer.decidedRanges(
            evidence: evidence, duration: duration, config: ProcessorConfig(),
            minRallySec: 1.1653, padded: false)   // RallyDecider's production default
        let export = TrainingDataExporter.makeExport(
            videoName: video.lastPathComponent,
            duration: duration,
            evidence: evidence,
            truth: truth,
            baselineRaw: baseline)

        // A recording cut whole (every processed frame inside a cut) has nothing to train on. Its export is
        // written all the same — empty, which the trainer skips — so an earlier export with the frames in it
        // is replaced, never left for the next training run to read.
        if export.frames.isEmpty { log("⚠️ \(video.lastPathComponent): every frame lies inside a cut range (not footage) — an empty export replaces any earlier one") }
        let outURL = TrainingDataExporter.exportURL(for: video)
        do {
            try TrainingDataExporter.write(export, forVideo: video, projectRoots: projectRoots)
            log("✅ \(outURL.lastPathComponent): \(export.frames.count) frames, \(export.labels.count) rallies, \(export.excluded.count) excluded spans, \(export.baselineRaw.count) baseline rallies")
            return true
        } catch {
            log("❌ \(video.lastPathComponent): write failed: \(error.localizedDescription)")
            return false
        }
    }
}
