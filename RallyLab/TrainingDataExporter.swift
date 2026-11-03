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
        let labels: [IntervalDTO]       // ground truth (raw boundaries), outside the cuts
        let baselineRaw: [IntervalDTO]  // rule pipeline, raw decided boundaries, outside the cuts
        let cuts: [IntervalDTO]         // cut ranges (not footage; D-030): no frame inside, and the trainer masks its own decisions with them
        let frames: [FrameRow]
    }

    /// `cuts`: the recording's cut ranges (not footage; D-030) — frames inside them are left out,
    /// labels and baseline rallies are taken outside them.
    static func makeExport(
        videoName: String,
        duration: Double,
        evidence: [VideoProcessor.FrameEvidence],
        labels: [Interval],
        baselineRaw: [Interval],
        cuts: [CutRange] = []
    ) -> Export {
        let net = evidence.lazy.compactMap { $0.detectedNet }.first
        let frames = evidence.filter { !cuts.contains($0.time) }.map { f -> FrameRow in
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
            schema: 1,
            video: videoName,
            duration: duration,
            netTopY: net.map { Double($0.box.maxY) },
            netBottomY: net.map { Double($0.box.minY) },
            labels: labels.outside(cuts).map { IntervalDTO(start: $0.start, end: $0.end) },
            baselineRaw: baselineRaw.outside(cuts).map { IntervalDTO(start: $0.start, end: $0.end) },
            cuts: cuts.map { IntervalDTO(start: $0.start, end: $0.end) },
            frames: frames
        )
    }

    /// The cut ranges of the project session over this video, if any project has one — matched
    /// by the session's source path over every project this Mac knows (`ProjectsModel
    /// .savedProjectRoots`: the remembered list, the last opened and the default location; a
    /// project may live anywhere). A video no project knows has no cuts, by construction.
    /// Throws when a project's sessions can't all be read: an unreadable session is unknown
    /// cuts, not no cuts, and the export must not go out as if there were none (fails closed).
    static func cutRanges(forVideo url: URL, projectRoots: [URL] = ProjectsModel.savedProjectRoots()) throws -> [CutRange] {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        for project in projectRoots {
            for session in try DatasetStore(root: project).loadSessionsStrict() {
                let source = URL(fileURLWithPath: session.sourcePath).standardizedFileURL.resolvingSymlinksInPath().path
                if source == path || session.sourcePath == url.path { return session.cutRanges }
            }
        }
        return []
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
            let labelsURL = video.deletingPathExtension().appendingPathExtension("rallylabels.json")
            guard let labelData = try? Data(contentsOf: labelsURL),
                  let labeled = try? JSONDecoder().decode([LabeledRally].self, from: labelData),
                  !labeled.isEmpty else {
                log("⚠️ \(video.lastPathComponent): no decodable labels, skipping")
                continue
            }

            log("▸ \(video.lastPathComponent): running pipeline (\(labeled.count) labeled rallies)…")
            let processor = VideoProcessor()
            processor.config = ProcessorConfig()   // production defaults = the baseline being challenged
            processor.collectFrameEvidence = true
            do {
                _ = try await processor.processVideo(video, videoId: UUID())
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
            // Unknown cuts are not no cuts: a project whose sessions can't be read stops this video's export.
            let cuts: [CutRange]
            do { cuts = try TrainingDataExporter.cutRanges(forVideo: video) } catch {
                log("❌ \(video.lastPathComponent): the cut ranges can't be known — \(error.localizedDescription) Not exported.")
                allSucceeded = false
                continue
            }
            if !cuts.isEmpty { log("  \(video.lastPathComponent): \(String(format: "%.1f", cuts.seconds(within: duration))) s of cut ranges left out (D-030)") }

            let export = TrainingDataExporter.makeExport(
                videoName: video.lastPathComponent,
                duration: duration,
                evidence: evidence,
                labels: labeled.map { Interval(start: $0.startTime, end: $0.endTime) },
                baselineRaw: baseline,
                cuts: cuts)

            // A recording cut whole (every processed frame inside a cut) has nothing to train on. Its export is
            // written all the same — empty, which the trainer skips — so an earlier export with the frames in it
            // is replaced, never left for the next training run to read.
            if export.frames.isEmpty { log("⚠️ \(video.lastPathComponent): every frame lies inside a cut range (not footage) — an empty export replaces any earlier one") }
            let outURL = TrainingDataExporter.exportURL(for: video)
            do {
                try TrainingDataExporter.write(export, to: outURL)
                log("✅ \(outURL.lastPathComponent): \(export.frames.count) frames, \(export.labels.count) labels, \(export.baselineRaw.count) baseline rallies")
            } catch {
                log("❌ \(video.lastPathComponent): write failed: \(error.localizedDescription)")
                allSucceeded = false
            }
        }
        return allSucceeded
    }
}
