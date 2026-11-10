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
            guard let match = try ReservedVideos.match(url, root: project) else {
                // No session is over this video — but a card of the project names it (its sessions folder or
                // this session is missing or renamed): its cuts are unknown, not none (Codex on #139).
                if let card = try cardNaming(url, in: project) { throw SessionUnavailable(video: card, project: project.lastPathComponent) }
                continue
            }
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

    /// Why the video cannot be exported: its pass is not known to be complete. nil when it is. A video no
    /// project knows cannot prove its pass complete (D-002: the session is the record); an unreadable project
    /// throws.
    static func exportRefusal(forVideo url: URL, projectRoots: [URL]? = nil) throws -> String? {
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

    /// The project video `url` is by its card (project.json, read strictly): the cut file's path or name, or the
    /// file's content against the card's fingerprint. nil when no card names it.
    static func cardNaming(_ url: URL, in project: URL) throws -> String? {
        let sources = try EventReview.projectSourcesStrict(in: project)
        let path = url.standardizedFileURL.path, base = url.lastPathComponent
        lazy var print: String? = ProjectsModel.fileFingerprint(atPath: path)
        for (name, source) in sources.sorted(by: { $0.key < $1.key }) {
            let cut = URL(fileURLWithPath: source.clipFile)
            if cut.standardizedFileURL.path == path || cut.lastPathComponent == base || base.hasPrefix(name + ".") { return name }
            if let mine = print, ReservedVideos.effectiveFingerprint(source) == mine { return name }
        }
        return nil
    }

    static func write(_ export: Export, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(export).write(to: url, options: .atomic)
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
            // The marks by kind, the session's cuts, and the pass complete — or no export (fails closed).
            let truth: RallyTruth
            do {
                if let why = try TrainingDataExporter.exportRefusal(forVideo: video) {
                    log("❌ \(video.lastPathComponent): \(why). Not exported.")
                    allSucceeded = false
                    continue
                }
                guard let session = try TrainingDataExporter.session(forVideo: video), let read = try RallyTruth.of(session) else {
                    log("❌ \(video.lastPathComponent): the marks can't be read beside the video. Not exported.")
                    allSucceeded = false
                    continue
                }
                truth = read
            } catch {
                log("❌ \(video.lastPathComponent): the project can't be read — \(error.localizedDescription) Not exported.")
                allSucceeded = false
                continue
            }
            if !truth.cuts.isEmpty { log("  \(video.lastPathComponent): cut ranges left out (D-030)") }
            log("▸ \(video.lastPathComponent): running pipeline (\(truth.positives.count) rallies, \(truth.excluded.count) excluded missed-serve/other marks"
                + (truth.positives.isEmpty ? " — negative-only" : "") + ")…")
            let processor = VideoProcessor()
            processor.config = ProcessorConfig()   // production defaults = the baseline being challenged
            processor.collectFrameEvidence = true
            do {
                _ = try await processor.analyzeVideo(video)
            } catch ProcessingError.noRalliesDetected {
                // Zero predictions is a valid outcome; evidence was still captured.
            } catch {
                log("❌ \(video.lastPathComponent): pipeline failed: \(error.localizedDescription)")
                allSucceeded = false
                continue
            }

            let evidence = processor.frameEvidence
            let duration = processor.lastVideoDurationSec
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
                try TrainingDataExporter.write(export, to: outURL)
                log("✅ \(outURL.lastPathComponent): \(export.frames.count) frames, \(export.labels.count) rallies, \(export.excluded.count) excluded spans, \(export.baselineRaw.count) baseline rallies")
            } catch {
                log("❌ \(video.lastPathComponent): write failed: \(error.localizedDescription)")
                allSucceeded = false
            }
        }
        return allSucceeded
    }
}
