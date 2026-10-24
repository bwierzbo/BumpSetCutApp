//
//  MultiFramePackage.swift
//  RallyLab
//
//  A training package for multi-frame heatmap detectors (TrackNet / WASB /
//  VballNet family). Those models see a short run of consecutive frames,
//  so every reviewed frame goes in with the frames around it, pulled from
//  its source video: `span` on each side, about 1/30 s apart whatever the
//  video's frame rate (a 60 fps clip contributes every other frame), so
//  motion looks the same to the model across clips. Only the reviewed
//  frame in the middle is labeled; the trainer scores only that frame.
//
//  Frames are written as the video stores them — portrait phone video
//  sideways — because that's what the app's pipeline sees, and boxes are
//  turned to match. Frames shared by overlapping windows are written once.
//
//    <dataset>/exports/<name>-multiframe-<yyyyMMdd-HHmm>/
//      windows.jsonl  README.txt  summary.json
//      frames/<clip>/<microseconds>.jpg
//    <dataset>/exports/<name>-multiframe-<yyyyMMdd-HHmm>.zip
//
//  Rallies you've tracked and marked done in the Track tab go in too,
//  densely: a window centred on every other frame, with a label for every
//  frame in it ("labels": [] = no ball, null = not labeled). A ball hidden
//  for a moment between two sightings (behind a player, the net) is still
//  there: "occluded" gives where it must be, straight between them, so the
//  trainer can tell it from a ball that's gone.
//
//  Pre-tracked rallies (PreTracker — the model's own, in train videos) go
//  in the same way, with their sure frames (MachineLabels) as labels too:
//  "pseudo" says which frames' labels are the model's, which the trainer
//  uses with --pseudo (weighed less) and leaves unlabeled without it.
//
//  Videos with every rally marked also give dead-time windows ("dead": true,
//  no labels), well away from any rally: where the app runs the model on
//  the whole video but no rally is on, scored as how often it fires there.
//
//  windows.jsonl, one line per window:
//    {"clip", "split", "time", "size": [w, h], "frames": [2·span+1 paths],
//     "target": span, "balls": [[cx, cy, w, h], …],      (fractions, top-down)
//     "labels": [[[cx, cy, w, h], …] or null, …],      (tracked rallies only)
//     "occluded": [[cx, cy, w, h] or null, …],         (tracked, when any is hidden between sightings)
//     "pseudo": [true or false, …],                    (pre-tracked, when any frame's label is the model's)
//     "dead": true}                                    (dead-time windows only)
//
//  Frames are written whole (a `.part` file moved into place) and every
//  frame a window needs is written or the export fails naming it: nothing
//  is skipped quietly. One exception, on record rather than fatal: an HEVC
//  leading picture the decoder cannot produce however it is asked
//  (`Undecodable`) is journaled with its error and left out together with
//  every window that needed it, counted in summary.json; no frame stands in
//  for it. An export cut short — the volume it writes to or
//  reads from goes away, which is noticed within seconds and is final —
//  leaves only frames/ behind, and can be completed with `resume:` the same
//  folder: the run's identity (settings, sources, planned moments) must
//  match the journal written beside the folder (ExportJournal), and a frame
//  already there is reused only once it is proven — its bytes hash to what
//  the journal says was written, or, for a frame the journal does not know,
//  its bytes are identical to the frame regenerated now from the video.
//  windows.jsonl, README.txt and summary.json are written only after every
//  clip's folder has been listed and found complete; the exposure ledger
//  only after the package has passed every check it is given.
//

import AVFoundation
import CoreGraphics
import Foundation

enum MultiFramePackage {

    /// Frames each side of the labeled one: 8 → 17-frame windows, enough for
    /// a 9-frame model with the labeled frame anywhere in its input.
    static let span = 8
    /// Neighbours are about this far apart in time, whatever the clip's fps.
    static let frameRate = 30.0
    /// Frames are scaled down to fit this on their long side — enough for
    /// the trainer's --size 1024. A package only for 512 training can be
    /// written at 512: a quarter of the disk (pre-tracked rallies make many
    /// frames).
    static let longSide: CGFloat = 1024
    /// In a tracked rally, a window is centred on every this-many frames.
    static let trackStride = 2
    /// A hidden ball is placed between sightings this close together (s).
    static let occludedGap = 0.6
    /// Dead-time windows: this often, at least `deadMargin` from any rally.
    static let deadStep = 3.0
    static let deadMargin = 1.5

    struct Summary: Codable {
        let name: String
        let createdAt: Date
        let clips: Int
        let trainWindows: Int
        let valWindows: Int
        /// Of those, windows from tracked rallies (every frame labeled).
        var trackedWindows: Int = 0
        /// Dead-time windows, from videos with every rally marked.
        var deadWindows: Int = 0
        /// Pre-tracked rallies, and their sure frames labeled by the model.
        var machineRallies: Int = 0
        var machineFrames: Int = 0
        let balls: Int
        let noBallWindows: Int
        let frames: Int
        /// Clips whose reviewed frames couldn't go in because the video is gone.
        let missingVideos: [String]
        let framesWithoutVideo: Int
        /// Reviewed frames too close to the start or end of their video.
        let framesAtEdges: Int
        /// Planned frames the decoder could not produce — HEVC leading pictures (`Undecodable`;
        /// D-024) — left out, each with every window that needed it. Which, per clip: `undecodable`.
        var undecodableFrames: Int = 0
        var windowsLeftOutUndecodable: Int = 0
        var undecodable: [UndecodableReport] = []
        /// Present when the export completed an earlier, interrupted one (`resume:`).
        var resume: ResumeReport? = nil
    }

    /// One clip's frames the decoder could not produce, and what went with them.
    struct UndecodableReport: Codable, Equatable {
        var clip: String
        var split: String
        /// The frames by file-name key (presentation time in µs), sorted.
        var frames: [Int64]
        var windowsLeftOut: Int
        var trackedWindowsLeftOut: Int
        var sampledWindowsLeftOut: Int
        var deadWindowsLeftOut: Int
        /// Frames carrying a person's label that the clip's windows would have shown, and how many of
        /// those are now in no window at all (a label in a left-out window is still trained on when
        /// another window shows the frame).
        var labelsPlanned: Int
        var labelsLeftOut: Int
        var error: String
        var reason: String
    }

    /// A planned frame the decoder cannot produce. One kind is left out of the package — on
    /// record in the journal and the summary, with every window that needed it — instead of
    /// stopping the export: an HEVC *leading picture*. In a recording with open groups of
    /// pictures (iPhone HEVC), the few frames displayed just before a key frame are coded after
    /// it and predicted from the group before it; asked for one on its own, the frame-accurate
    /// image generator answers `Cannot Decode` (AVFoundation −11821) every time, from a shared
    /// or a fresh decoder, from a local or a mounted copy (`bch_ele_sun_land_self_01`,
    /// 2026-10-24; reproduced on a synthetic x265 clip, RallyLabTests/Fixtures). Nothing else
    /// is left out: another codec, another error, a fresh decoder that fails differently, a run
    /// of undecodable frames longer than leading pictures come in, or one not bounded on both
    /// sides by frames that decode (a damaged clip loses the rest of its group of pictures) all
    /// stop the export as before, naming the frame. D-022 as amended by D-024.
    enum Undecodable {
        /// Leading pictures per key frame: three, sometimes four, in iPhone HEVC recordings; the
        /// x265 fixture gives four. A longer run is not that.
        static let maxRun = 4
        static let decodeFailed = AVError.Code.decodeFailed.rawValue   // −11821, "Cannot Decode"

        enum Verdict: Equatable {
            case leftOut(reason: String)
            case fatal(String)
        }

        static func describe(_ error: NSError) -> String { "\(error.domain) \(error.code) \(error.localizedDescription)" }
        static func isDecodeFailure(_ error: NSError) -> Bool { error.domain == AVFoundationErrorDomain && error.code == decodeFailed }

        /// Why the frame is not even a candidate, before its neighbours are looked at; nil when it is.
        /// `error`: what the export's decoder said after its bounded retries; `fresh`: what a decoder
        /// created for this one question said.
        static func refusal(codec: CMVideoCodecType, error: NSError, fresh: NSError) -> String? {
            guard codec == kCMVideoCodecType_HEVC else { return "the clip is \(fourCC(codec)), not HEVC; only HEVC leading pictures are left out" }
            guard isDecodeFailure(error) else { return "not a decode failure: \(describe(error))" }
            guard isDecodeFailure(fresh) else { return "a fresh decoder failed differently: \(describe(fresh))" }
            return nil
        }

        /// `run`: consecutive video frames the fresh decoder cannot produce, this one included;
        /// `boundedBefore` / `boundedAfter`: the frame right before / after that run decodes.
        static func verdict(run: Int, boundedBefore: Bool, boundedAfter: Bool, fresh: NSError) -> Verdict {
            guard run <= maxRun else {
                return .fatal("\(run) consecutive frames cannot be decoded; leading pictures come at most \(maxRun) before a key frame, so the clip is damaged or not supported")
            }
            guard boundedBefore, boundedAfter else {
                return .fatal("the run of undecodable frames is not bounded by frames that decode on both sides (it reaches the clip's \(boundedBefore ? "end" : "start"))")
            }
            return .leftOut(reason: "HEVC leading picture: one of \(run) consecutive frame(s) before a key frame that the frame-accurate decoder cannot produce "
                            + "(\(describe(fresh))), bounded by frames that decode; left out with every window that needs it (D-024)")
        }

        static func fourCC(_ codec: CMVideoCodecType) -> String {
            let bytes = [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xFF) }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// What `judgeUndecodable` found for a frame the export's decoder gave up on.
    private enum Judgement {
        /// A fresh decoder produced it after all: written like any other frame.
        case decoded(CGImage)
        case leftOut(reason: String, fresh: String, run: Int)
        case fatal(String)
    }

    /// What a resumed export found in the folder and did with it.
    struct ResumeReport: Codable, Equatable {
        struct ClipReport: Codable, Equatable {
            var clip: String
            var planned: Int
            var retainedByJournal: Int
            var retainedByRegeneration: Int
            var replaced: Int
            var toWrite: Int
        }
        var from: String
        /// What the journal beside the folder said, or "none" for a folder from before journals.
        var journal: String
        /// No journal: every retained frame was proven by regeneration.
        var legacy: Bool
        /// The journal's run identity matched what this export would do.
        var identityVerified: Bool
        /// Frames already in the folder, validated and kept: by the journal's hash, or by byte-identical regeneration.
        var framesRetained: Int
        var retainedByJournal: Int
        var retainedByRegeneration: Int
        /// Frames in the folder that were not whole, planned, or identical to their regeneration; replaced, listed here (up to 50).
        var framesReplaced: Int
        var replaced: [String]
        /// Frames written by this run (replacements not included).
        var framesWritten: Int
        /// Leftover `.part` files (a write cut short) removed; never frames.
        var partialFilesRemoved: Int
        var clips: [ClipReport]
    }

    enum PackageError: LocalizedError, ExportIO.Final {
        case nothingReviewed, noVideos, noValidation, zipFailed
        case nameTaken(String)
        /// A frame a window needs could not be produced (decoded or written) after every retry.
        case frameFailed(clip: String, frame: String, detail: String)
        /// After writing, a clip's folder does not hold exactly the frames the plan needs.
        case folderIncomplete(clip: String, detail: String)
        var errorDescription: String? {
            switch self {
            case .nameTaken(let name): return "A package named \(name) already exists (folder or zip). Nothing is overwritten: wait a minute or move it away."
            case .nothingReviewed: return "No reviewed frames yet — review some before packaging."
            case .noVideos: return "None of the reviewed frames' videos are on this Mac — the frames around each one come from the video."
            case .noValidation: return "No reviewed frames from a val clip whose video is here. Set a clip with its video to Val."
            case .zipFailed: return "The package folder was written, but zipping it failed."
            case .frameFailed(let clip, let frame, let detail): return "\(clip): frame \(frame) could not be exported (\(detail)). No frame is skipped; nothing is finished. Fix the cause and resume with --resume."
            case .folderIncomplete(let clip, let detail): return "\(clip): the frames folder is not what the plan needs after writing (\(detail)). Nothing is finished."
            }
        }
    }

    enum ResumeError: LocalizedError, Equatable, ExportIO.Final {
        case notAFolder(String)
        /// The folder holds something other than frames/: a finished package, or not a package at all.
        case notResumable(String, found: [String])
        case strayClipFolder(String)
        case unexpectedFile(String)
        /// More torn frames in one clip than an interruption leaves; the folder is not trusted.
        case tooManyInvalid(clip: String, count: Int, limit: Int)
        /// The journal's run identity is not what this export would do now.
        case identityMismatch([String])
        /// The journal says the export reached a state that is not resumed into.
        case wrongState(String)

        var errorDescription: String? {
            switch self {
            case .notAFolder(let p): return "--resume \(p) is not a folder."
            case .notResumable(let p, let found): return "\(p) is not an unfinished package (found \(found.joined(separator: ", "))): only a folder holding frames/ alone — an export cut short — can be resumed. A finished package is never written into."
            case .strayClipFolder(let p): return "\(p) is not a clip this export packages. Nothing is removed; nothing is written."
            case .unexpectedFile(let p): return "\(p) is not a frame this export writes. Nothing is removed; nothing is written."
            case .tooManyInvalid(let clip, let n, let limit): return "\(clip): more than \(limit) retained frames (\(n) found before stopping) are not whole, planned and identical to their regeneration; an interruption leaves at most \(limit), so the folder is not trusted. Nothing is reused, nothing is changed."
            case .identityMismatch(let d): return "The journal's run is not this export: \(d.prefix(8).joined(separator: "; "))\(d.count > 8 ? " … (\(d.count) differences)" : ""). Nothing is reused, nothing is changed."
            case .wrongState(let st): return "The journal says the export reached \(st); only an interrupted export is resumed. Nothing is changed."
            }
        }
    }

    /// Torn frames an interruption can leave in one clip folder; more means the folder is not an export's.
    static let maxInvalidPerClip = 8

    private struct Window: Encodable {
        let clip: String
        let split: String
        let time: Double
        let size: [Int]
        let frames: [String]
        let target: Int
        let balls: [[Double]]
        var labels: [[[Double]]?]? = nil
        var occluded: [[Double]?]? = nil
        var dead: Bool? = nil
        var pseudo: [Bool]? = nil
    }

    /// `unreviewed`: every labeled frame of a finished rally is a label, not
    /// only the ones checked in annotation review — for a quick look at where
    /// the footage gets, never for a training round.
    /// `valOnly`: just the val clips, and no zip — the test set for scoring
    /// models on this Mac, in minutes rather than the hour the train clips
    /// take. Returns the folder; otherwise the zip.
    /// `beforeZip`: run on the finished folder before it is zipped (a
    /// lineage package's preflight, LineagePackage). If it throws, the
    /// folder is removed and the error is rethrown: no package exists.
    /// A package name is never reused: an existing folder or zip of the same
    /// name (two exports in one minute) is an error, so a rejected export can
    /// never leave an older zip next to its own failed record.
    /// The reviewed sampled frames of a session: what the exporter labels from them.
    static func reviewedFrames(_ session: VideoSession) -> [FrameRecord] {
        session.frames.filter { $0.keep && $0.reviewed && $0.source != "file" }
    }

    /// Whether the exporter would take anything from this session: reviewed frames, a
    /// ready track, or rally marks for dead time. Such a session needs its video.
    static func contributes(_ session: VideoSession) -> Bool {
        !reviewedFrames(session).isEmpty || !readyTracks(session).isEmpty || session.ralliesMarked == true
    }

    /// The exporter whose frame files a journal describes. "1" wrote no journal (the run
    /// interrupted on 2026-10-22); "2" journals and resumes.
    static let exporterVersion = "2"
    static let jpegQuality = 0.85

    /// `exportsDir`: where the package folder and zip go; the project's `exports/` when nil.
    /// `resume`: the folder of an export that was cut short (frames/ and nothing else), to be
    /// completed in place; its name is the package name and its parent the exports folder.
    /// `identity`: what the caller adds to the run identity (a lineage package: manifest hashes,
    /// the eligible and withheld closure). `note`: progress lines for the log.
    /// `machineLabels`: whether a pre-tracked train rally's sure frames (MachineLabels.trusted) are
    /// labels, flagged `pseudo` for `--pseudo` training. False for a lineage package: people's
    /// labels only, so the package carries no model-written label by construction, not only
    /// by the preflight's refusal.
    static func export(sessions: [VideoSession], store: DatasetStore, name: String, unreviewed: Bool = false, valOnly: Bool = false,
                       machineLabels: Bool = true, longSide: CGFloat = longSide, exportsDir: URL? = nil, resume: URL? = nil,
                       identity: [String: String] = [:], beforeZip: ((URL) throws -> Void)? = nil, now: Date = Date(),
                       note: (@Sendable (String) -> Void)? = nil,
                       progress: @escaping @Sendable (Int, Int) -> Void) async throws -> (output: URL, summary: Summary) {
        try await run(sessions: sessions, store: store, name: name, unreviewed: unreviewed, valOnly: valOnly, machineLabels: machineLabels,
                      longSide: longSide, exportsDir: exportsDir, resume: resume, identity: identity, inspectOnly: false, beforeZip: beforeZip,
                      now: now, note: note, progress: progress)
    }

    /// Reads an interrupted export without changing it: what its journal says, whether the run
    /// identity still holds, and which frames would be reused, regenerated or replaced.
    static func inspectResume(sessions: [VideoSession], store: DatasetStore, resume: URL, unreviewed: Bool = false, valOnly: Bool = false,
                              machineLabels: Bool = true, longSide: CGFloat = longSide, identity: [String: String] = [:],
                              note: (@Sendable (String) -> Void)? = nil) async throws -> ResumeReport {
        let result = try await run(sessions: sessions, store: store, name: resume.lastPathComponent, unreviewed: unreviewed, valOnly: valOnly,
                                   machineLabels: machineLabels, longSide: longSide, exportsDir: nil, resume: resume, identity: identity,
                                   inspectOnly: true, beforeZip: nil, now: Date(), note: note) { _, _ in }
        return result.summary.resume!
    }

    /// One clip's share of the export, settled before anything is written: the frames it
    /// needs (by presentation time), the windows those frames make, and the clip's identity.
    private struct ClipPlan {
        let session: VideoSession
        let clipDir: String
        let clip: ClipFrames
        var needed: [Int64: CMTime] = [:]
        var windows: [(FrameRecord, [CMTime])] = []
        var tracked: [(time: Double, times: [CMTime], labels: [TrackPoint?], occluded: [CGRect?], pseudo: [Bool])] = []
        var dead: [(time: Double, times: [CMTime])] = []
        var edges = 0
        var machineRallies = 0
        var machineFrames = 0
        var identity: ExportJournal.Identity.Clip
        var safeName: String { String(clipDir.dropFirst("frames/".count)) }
    }

    private static func plan(_ session: VideoSession, frames: [FrameRecord], longSide: CGFloat, unreviewed: Bool, machineLabels: Bool) async throws -> ClipPlan {
        let video = URL(fileURLWithPath: session.sourcePath)
        let clip = try await ClipFrames(video: video, longSide: longSide)
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: session.sourcePath)   // follows the dataset's link
        guard let fingerprint = ProjectsModel.fileFingerprint(atPath: session.sourcePath) else {
            throw PackageError.frameFailed(clip: session.name, frame: "(video)", detail: "the video can't be fingerprinted")
        }
        var p = ClipPlan(session: session, clipDir: "frames/\(DatasetStore.safeName(session.name))", clip: clip,
                         identity: .init(name: session.name, split: session.split == "val" ? "val" : "train", sourcePath: session.sourcePath,
                                         sourceFingerprint: fingerprint, sourceBytes: (attributes[.size] as? NSNumber)?.int64Value ?? -1,
                                         sourceModified: ExportJournal.Writer.stamp((attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)),
                                         sidecarSha256: nil, plannedKeysSha256: "", plannedKeys: 0))
        for frame in frames {
            guard let times = clip.window(around: frame.time) else { p.edges += 1; continue }
            p.windows.append((frame, times))
            for t in times { p.needed[ClipFrames.key(t)] = t }
        }
        // Tracked rallies: a window on every `trackStride`-th labeled frame.
        for rally in Self.readyTracks(session) {
            // Only frames checked in annotation review are labels — and, when
            // `machineLabels` allows, a pre-tracked rally's sure ones, marked as
            // the model's; the rest are still frames the model sees around them.
            // In a val video only what a person checked: the score is
            // people's labels, never the model's own.
            let val = session.split == "val"
            let sure = (val || !machineLabels) ? [] : MachineLabels.trusted(rally)
            let labeled = rally.points.indices.filter { rally.points[$0].isChecked || (!val && unreviewed) || sure.contains($0) }
            let key = { (pt: TrackPoint) in ClipFrames.key(CMTime(seconds: pt.time, preferredTimescale: 600_000)) }
            let byKey = Dictionary(labeled.map { (key(rally.points[$0]), rally.points[$0]) }, uniquingKeysWith: { a, _ in a })
            let machine = Set(sure.map { key(rally.points[$0]) })
            let occluded = Dictionary(Self.occluded(rally, unreviewed: unreviewed && !val).map { (key($0.point), $0.box) },
                                      uniquingKeysWith: { a, _ in a })
            if rally.isMachine { p.machineRallies += 1; p.machineFrames += sure.count }
            for i in labeled where i % Self.trackStride == 0 && rally.points[i].state != .unknown {
                let point = rally.points[i]
                guard let times = clip.window(around: point.time, exact: true) else { p.edges += 1; continue }
                p.tracked.append((point.time, times, times.map { byKey[ClipFrames.key($0)] }, times.map { occluded[ClipFrames.key($0)] },
                                  times.map { machine.contains(ClipFrames.key($0)) }))
                for t in times { p.needed[ClipFrames.key(t)] = t }
            }
        }
        // Dead time: only where every rally is marked, so "no rally" is known.
        if session.ralliesMarked == true {
            let sidecar = RallyMarkModel.labelsURL(for: video)
            if fm.fileExists(atPath: sidecar.path) { p.identity.sidecarSha256 = DatasetSplitManifest.sha256(of: sidecar) ?? "unreadable" }
            let marks = RallyMarkModel.load(sidecar)
            for t in stride(from: Self.deadMargin, to: clip.duration - Self.deadMargin, by: Self.deadStep)
            where !marks.contains(where: { t > $0.start - Self.deadMargin && t < $0.end + Self.deadMargin }) {
                guard let times = clip.window(around: t) else { continue }
                p.dead.append((t, times))
                for t in times { p.needed[ClipFrames.key(t)] = t }
            }
        }
        p.identity.plannedKeys = p.needed.count
        p.identity.plannedKeysSha256 = ExportJournal.sha256(Data(p.needed.keys.sorted().map(String.init).joined(separator: "\n").utf8))
        return p
    }

    private static func run(sessions: [VideoSession], store: DatasetStore, name: String, unreviewed: Bool, valOnly: Bool, machineLabels: Bool,
                            longSide: CGFloat, exportsDir: URL?, resume: URL?, identity extra: [String: String], inspectOnly: Bool, beforeZip: ((URL) throws -> Void)?,
                            now: Date, note: (@Sendable (String) -> Void)?,
                            progress: @escaping @Sendable (Int, Int) -> Void) async throws -> (output: URL, summary: Summary) {
        let fm = FileManager.default
        // Final-test recordings (D-002) never enter a package, train or val.
        let finalTest = try PipelineTuner.ValidationSet.finalTestNames(in: store.root)
        let sessions = sessions.filter { !finalTest.contains($0.name) }
        let all: [(VideoSession, [FrameRecord])] = sessions.map { ($0, Self.reviewedFrames($0)) }.filter { Self.contributes($0.0) }
        let reviewed = valOnly ? all.filter { $0.0.split == "val" } : all
        guard !reviewed.isEmpty else { throw PackageError.nothingReviewed }
        let usable = reviewed.filter { fm.fileExists(atPath: $0.0.sourcePath) }
        let missing = reviewed.filter { !fm.fileExists(atPath: $0.0.sourcePath) }
        guard !usable.isEmpty else { throw PackageError.noVideos }
        guard usable.contains(where: { $0.0.split == "val" }) else { throw PackageError.noValidation }

        let packageName: String
        let exports: URL
        if let resume {
            packageName = resume.lastPathComponent
            exports = resume.deletingLastPathComponent()
        } else {
            let stamp = DateFormatter()
            stamp.dateFormat = "yyyyMMdd-HHmm"
            packageName = "\(DatasetStore.safeName(name))\(unreviewed ? "-unreviewed" : "")\(valOnly ? "-val" : "")-multiframe-\(stamp.string(from: now))"
            exports = exportsDir ?? store.root.appendingPathComponent("exports", isDirectory: true)
        }
        let dir = exports.appendingPathComponent(packageName, isDirectory: true)
        let zip = exports.appendingPathComponent("\(packageName).zip")
        let journalURL = ExportJournal.url(forPackage: dir)
        // The journal is read first: it says whether the run ever reached "finished", which decides what the folder may hold.
        var journaled: ExportJournal.Contents?
        if resume != nil, fm.fileExists(atPath: journalURL.path) { journaled = try ExportJournal.read(journalURL, forPackage: packageName) }
        let unfinished = journaled.map { $0.state == .interrupted || $0.state == .preflightFailed } ?? false
        // Completion files a run was cut short while writing: shed only once the folder has otherwise
        // qualified and, below, the run identity has been verified.
        var stale: [String] = []
        if resume != nil {
            stale = try Self.checkResumable(dir, zip: zip, clipFolders: Set(usable.map { DatasetStore.safeName($0.0.name) }), unfinishedByJournal: unfinished)
            if let journaled, !unfinished { throw ResumeError.wrongState(journaled.state.rawValue) }
        } else {
            guard !fm.fileExists(atPath: dir.path), !fm.fileExists(atPath: zip.path), !fm.fileExists(atPath: journalURL.path)
            else { throw PackageError.nameTaken(packageName) }
        }

        // Everything that decides the frame files, settled now: the plan of every clip and the run identity.
        var plans: [ClipPlan] = []
        for (session, frames) in usable { plans.append(try await Self.plan(session, frames: frames, longSide: longSide, unreviewed: unreviewed, machineLabels: machineLabels)) }
        let identity = ExportJournal.Identity(exporter: exporterVersion, longSide: Double(longSide), quality: jpegQuality, span: span, frameRate: frameRate,
                                              trackStride: trackStride, deadStep: deadStep, deadMargin: deadMargin, unreviewed: unreviewed,
                                              valOnly: valOnly, machineLabels: machineLabels, extra: extra,
                                              clips: Dictionary(uniqueKeysWithValues: plans.map { ($0.safeName, $0.identity) }))

        // The journal: read and matched when resuming, started otherwise. An interrupted export
        // from before journals (a "legacy" folder) has none: nothing in it is trusted without regeneration.
        var resumed = ResumeReport(from: packageName, journal: "none", legacy: resume != nil, identityVerified: false, framesRetained: 0,
                                   retainedByJournal: 0, retainedByRegeneration: 0, framesReplaced: 0, replaced: [], framesWritten: 0,
                                   partialFilesRemoved: 0, clips: [])
        if let contents = journaled {
            let differences = identity.differences(from: contents.identity)
            guard differences.isEmpty else { throw ResumeError.identityMismatch(differences) }
            if !inspectOnly { for leftover in stale { try fm.removeItem(at: dir.appendingPathComponent(leftover)) } }
            resumed.journal = "version \(contents.version), started \(contents.startedAt), state \(contents.state.rawValue), \(contents.frames.values.reduce(0) { $0 + $1.count }) frames journaled"
                + (contents.tornTail ? ", last line torn" : "")
            resumed.legacy = false
            resumed.identityVerified = true
        }
        var writer: ExportJournal.Writer?
        var createdJournal = false
        if !inspectOnly {
            if resume == nil { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            if let journaled {
                writer = try ExportJournal.Writer(appendingTo: journalURL, after: journaled.validLength)
                try writer?.state(.inProgress, note: "resumed", now: now)
            } else {
                writer = try ExportJournal.Writer(creating: journalURL, package: packageName, identity: identity, now: now)
                createdJournal = true
                try writer?.state(.inProgress, note: resume == nil ? nil : "resumed without a journal (legacy partial): every retained frame regenerated and compared", now: now)
            }
        }
        // The package folder as it is now; a vanished mount leaves a different folder at this path.
        let outputAnchor = try ExportIO.Anchor(path: dir.path)
        var closed = false
        var refused = false
        defer {
            if let writer, !closed {
                if createdJournal && refused {
                    // A refusal changes nothing, so the journal this run started goes too: it would otherwise
                    // freeze a wrong identity (the wrong --long-side, say) over a folder it never touched.
                    try? writer.close()
                    try? fm.removeItem(at: journalURL)
                } else {   // an error on the way out: say so while the journal can still be written
                    try? writer.state(.interrupted)
                    try? writer.close()
                }
            }
        }

        let total = plans.reduce(0) { $0 + $1.windows.count }
        var done = 0
        var lines: [String] = []
        var counts = (train: 0, val: 0, balls: 0, empty: 0, frames: 0, edges: 0, tracked: 0, dead: 0, machineRallies: 0, machineFrames: 0,
                      undecodable: 0, windowsLeftOut: 0)
        var undecodableReports: [UndecodableReport] = []
        var expectedFiles: [(folder: URL, keys: Set<Int64>)] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        // Phase 1, resuming: every clip's retained frames are judged before any is repaired or any
        // frame written, so a refusal — a folder that is not this export's — leaves every clip as it was.
        var retainedByClip: [String: Retained] = [:]
        if resume != nil {
            do {
                for p in plans {
                    let clipURL = dir.appendingPathComponent(p.clipDir, isDirectory: true)
                    try outputAnchor.verify()
                    let anchors = [outputAnchor, try ExportIO.Anchor(path: p.session.sourcePath)]
                    let lost = VolumeWatch(anchors: anchors, generator: p.clip.generator)
                    defer { lost.stop() }
                    let retained = fm.fileExists(atPath: clipURL.path)
                        ? try await Self.validateRetained(in: clipURL, plan: p, journal: journaled?.frames[p.safeName] ?? [:], anchors: anchors, watch: lost)
                        : Retained()
                    retainedByClip[p.safeName] = retained
                    resumed.framesRetained += retained.byJournal + retained.byRegeneration
                    resumed.retainedByJournal += retained.byJournal
                    resumed.retainedByRegeneration += retained.byRegeneration
                    resumed.framesReplaced += retained.invalid.count
                    resumed.replaced += retained.invalid.prefix(max(0, 50 - resumed.replaced.count)).map { "\(p.clipDir)/\($0).jpg" }
                    resumed.partialFilesRemoved += retained.partials.count
                    let toWrite = p.needed.count - retained.byJournal - retained.byRegeneration - retained.invalid.count   // absent altogether
                    resumed.clips.append(.init(clip: p.session.name, planned: p.needed.count, retainedByJournal: retained.byJournal,
                                               retainedByRegeneration: retained.byRegeneration, replaced: retained.invalid.count, toWrite: toWrite))
                    note?("  \(p.session.name): \(p.needed.count) planned, \(retained.byJournal) kept by journal, \(retained.byRegeneration) kept after regeneration"
                          + (retained.invalid.isEmpty ? "" : ", \(retained.invalid.count) to replace") + ", \(toWrite) to write")
                }
            } catch {
                refused = error is ResumeError
                throw error
            }
        }
        if inspectOnly {
            var summary = Summary(name: packageName, createdAt: now, clips: usable.count, trainWindows: 0, valWindows: 0, balls: 0, noBallWindows: 0,
                                  frames: 0, missingVideos: missing.map(\.0.name).sorted(), framesWithoutVideo: missing.reduce(0) { $0 + $1.1.count },
                                  framesAtEdges: plans.reduce(0) { $0 + $1.edges })
            summary.resume = resumed
            closed = true
            return (dir, summary)
        }

        // Phase 2: clip by clip, repair what phase 1 judged, write what is missing, verify, journal.
        for p in plans {
            let session = p.session, clip = p.clip, clipDir = p.clipDir, needed = p.needed
            let clipURL = dir.appendingPathComponent(clipDir, isDirectory: true)
            counts.edges += p.edges; counts.machineRallies += p.machineRallies; counts.machineFrames += p.machineFrames
            try outputAnchor.verify()
            try await ExportIO.retrying("creating \(clipDir)", anchors: [outputAnchor]) {
                try fm.createDirectory(at: clipURL, withIntermediateDirectories: true)
            }
            // The video file itself (through the dataset's link), so a footage mount that drops is noticed.
            let anchors = [outputAnchor, try ExportIO.Anchor(path: session.sourcePath)]
            let lost = VolumeWatch(anchors: anchors, generator: clip.generator)
            defer { lost.stop() }

            var written = Set<Int64>()
            var sizes: [Int64: Int] = [:]
            if let retained = retainedByClip[p.safeName] {
                written = retained.kept
                sizes = retained.sizes
                try await Self.repairRetained(in: clipURL, plan: p, retained: retained, anchors: anchors, writer: writer)
                written.formUnion(retained.invalid)
                for key in retained.invalid { sizes[key] = retained.replacementSizes[key] }
            }

            // Every needed frame not yet in the folder is decoded and written whole, or the export fails naming it.
            let toWrite = needed.filter { !written.contains($0.key) }.values.sorted { $0 < $1 }
            var undecoded: [CMTime] = []
            var produced = 0
            // (An empty request would never finish: the generator's sequence ends only after a result.)
            if !toWrite.isEmpty {
                for await result in clip.generator.images(for: toWrite) {
                    if let error = lost.error { throw error }
                    let key = ClipFrames.key(result.requestedTime)
                    guard let image = try? result.image else { undecoded.append(result.requestedTime); continue }
                    sizes[key] = try await Self.write(image, key: key, in: clipURL, plan: p, anchors: anchors, writer: writer)
                    written.insert(key)
                    produced += 1
                    if produced % 50 == 0 { for a in anchors { try a.verify() } }
                }
            }
            if let error = lost.error { throw error }
            // A frame the batch could not decode is asked for again on its own, a bounded number of
            // times. One that still fails is judged (`judgeUndecodable`): an HEVC leading picture is
            // left out on record; anything else stops the export, naming the frame.
            var leftOut = Set<Int64>()
            var leftOutError = "", leftOutReason = ""
            for time in undecoded {
                let key = ClipFrames.key(time)
                var image: CGImage?
                var lastError: NSError?
                do {
                    image = try await ExportIO.retrying("decoding \(session.name) frame \(key)", anchors: anchors) {
                        do { return try await clip.generator.image(at: time).image } catch { lastError = error as NSError; throw error }
                    }
                } catch let failure as ExportIO.Failure {
                    guard case .gaveUp(_, let attempts, let detail) = failure, let error = lastError else { throw failure }
                    switch try await Self.judgeUndecodable(at: time, error: error, plan: p, anchors: anchors) {
                    case .decoded(let fresh):
                        image = fresh
                    case .fatal(let why):
                        throw PackageError.frameFailed(clip: session.name, frame: "\(key).jpg", detail: "\(detail); \(why)")
                    case .leftOut(let reason, let fresh, let run):
                        leftOut.insert(key); leftOutError = fresh; leftOutReason = reason
                        try writer?.append(.undecodable(clip: p.safeName, key: key, time: time.seconds, error: fresh, attempts: attempts + 1, run: run,
                                                        reason: reason, at: ExportJournal.Writer.stamp(Date())))
                        try writer?.flush()
                        note?("  ⚠️ \(session.name): frame \(key).jpg left out — \(reason)")
                    }
                }
                guard let image else { continue }
                sizes[key] = try await Self.write(image, key: key, in: clipURL, plan: p, anchors: anchors, writer: writer)
                written.insert(key)
            }
            resumed.framesWritten += produced + undecoded.count - leftOut.count
            // The folder must now hold exactly the plan's frames but the ones left out, each the size that was written or validated.
            try await Self.verifyFolder(clipURL, clipDir: clipDir, clip: session.name, sizes: sizes, anchors: anchors)
            try writer?.append(.clipComplete(clip: p.safeName, frames: needed.count - leftOut.count))
            try writer?.flush()
            expectedFiles.append((clipURL, Set(needed.keys).subtracting(leftOut)))
            counts.frames += needed.count - leftOut.count

            let split = session.split == "val" ? "val" : "train"
            func stored(_ box: CGRect) -> [Double] {
                let s = clip.rotation?.storedBox(box) ?? box
                // Vision boxes are bottom-up; the trainer reads top-down.
                return [s.midX, 1 - s.midY, s.width, s.height].map { Double($0) }
            }
            // Whether every frame of a window is in the folder. A window needing a frame left out as
            // undecodable is left out itself (no frame stands in for another); a frame neither
            // written nor on record is a plan violation and stops the export.
            var windowsLeftOut = (tracked: 0, sampled: 0, dead: 0)
            var labelsPlanned = Set<Int64>(), labelsKept = Set<Int64>()
            func shown(_ keys: [Int64]) throws -> Bool {
                if keys.contains(where: leftOut.contains) { return false }
                if let key = keys.first(where: { !written.contains($0) }) {
                    throw PackageError.frameFailed(clip: session.name, frame: "\(key).jpg", detail: "needed by a window but not written")
                }
                return true
            }
            for (time, times, labels, occluded, pseudo) in p.tracked {
                let keys = times.map(ClipFrames.key)
                let perFrame: [[[Double]]?] = labels.map { point in
                    switch point?.state {
                    case .visible: return point?.box.map { [stored($0.rect)] }
                    case .hidden: return []
                    default: return nil
                    }
                }
                let labeled = Swift.zip(keys, perFrame).filter { $0.1 != nil }.map(\.0)   // (`zip` here is the package's zip file)
                labelsPlanned.formUnion(labeled)
                guard try shown(keys) else { windowsLeftOut.tracked += 1; continue }
                labelsKept.formUnion(labeled)
                let balls = perFrame[span] ?? []
                var window = Window(clip: session.name, split: split, time: time,
                                    size: [Int(clip.outputSize.width), Int(clip.outputSize.height)],
                                    frames: keys.map { "\(clipDir)/\($0).jpg" }, target: span, balls: balls)
                window.labels = perFrame
                if occluded.contains(where: { $0 != nil }) { window.occluded = occluded.map { $0.map(stored) } }
                if pseudo.contains(true) { window.pseudo = pseudo }
                lines.append(String(decoding: try encoder.encode(window), as: UTF8.self))
                if split == "val" { counts.val += 1 } else { counts.train += 1 }
                counts.tracked += 1
                counts.balls += balls.count
                if balls.isEmpty { counts.empty += 1 }
            }
            for (time, times) in p.dead {
                let keys = times.map(ClipFrames.key)
                guard try shown(keys) else { windowsLeftOut.dead += 1; continue }
                var window = Window(clip: session.name, split: split, time: time,
                                    size: [Int(clip.outputSize.width), Int(clip.outputSize.height)],
                                    frames: keys.map { "\(clipDir)/\($0).jpg" }, target: span, balls: [])
                window.dead = true
                lines.append(String(decoding: try encoder.encode(window), as: UTF8.self))
                counts.dead += 1
            }
            for (frame, times) in p.windows {
                defer { done += 1; progress(done, total) }
                let keys = times.map(ClipFrames.key)
                labelsPlanned.insert(keys[span])
                guard try shown(keys) else { windowsLeftOut.sampled += 1; continue }
                labelsKept.insert(keys[span])
                let balls = frame.boxes.map { stored($0.rect) }
                let window = Window(clip: session.name, split: split, time: frame.time,
                                    size: [Int(clip.outputSize.width), Int(clip.outputSize.height)],
                                    frames: keys.map { "\(clipDir)/\($0).jpg" }, target: span, balls: balls)
                lines.append(String(decoding: try encoder.encode(window), as: UTF8.self))
                if split == "val" { counts.val += 1 } else { counts.train += 1 }
                counts.balls += balls.count
                if balls.isEmpty { counts.empty += 1 }
            }
            if !leftOut.isEmpty {
                let windows = windowsLeftOut.tracked + windowsLeftOut.sampled + windowsLeftOut.dead
                undecodableReports.append(UndecodableReport(clip: session.name, split: split, frames: leftOut.sorted(), windowsLeftOut: windows,
                                                            trackedWindowsLeftOut: windowsLeftOut.tracked, sampledWindowsLeftOut: windowsLeftOut.sampled,
                                                            deadWindowsLeftOut: windowsLeftOut.dead, labelsPlanned: labelsPlanned.count,
                                                            labelsLeftOut: labelsPlanned.subtracting(labelsKept).count, error: leftOutError, reason: leftOutReason))
                counts.undecodable += leftOut.count
                counts.windowsLeftOut += windows
                note?("  ⚠️ \(session.name): \(leftOut.count) frame(s) left out as undecodable with \(windows) window(s) "
                      + "(\(windowsLeftOut.tracked) tracked, \(windowsLeftOut.sampled) sampled, \(windowsLeftOut.dead) dead-time); "
                      + "\(labelsPlanned.subtracting(labelsKept).count) of \(labelsPlanned.count) labeled frames now in no window")
            }
        }
        var summary = Summary(name: packageName, createdAt: now, clips: usable.count,
                              trainWindows: counts.train, valWindows: counts.val, balls: counts.balls,
                              noBallWindows: counts.empty, frames: counts.frames,
                              missingVideos: missing.map(\.0.name).sorted(),
                              framesWithoutVideo: missing.reduce(0) { $0 + $1.1.count },
                              framesAtEdges: counts.edges)
        summary.trackedWindows = counts.tracked
        summary.deadWindows = counts.dead
        summary.machineRallies = counts.machineRallies
        summary.machineFrames = counts.machineFrames
        summary.undecodableFrames = counts.undecodable
        summary.windowsLeftOutUndecodable = counts.windowsLeftOut
        summary.undecodable = undecodableReports
        if resume != nil { summary.resume = resumed }
        guard counts.val > 0 else { throw PackageError.noValidation }

        // Completion, verified before anything that says "finished" is written: the package
        // folder is still the one this export started in, and every clip folder — listed again
        // now, not remembered from when it was written — holds exactly the frames the plan needs.
        try outputAnchor.verify()
        for (folder, keys) in expectedFiles {
            let clip = folder.lastPathComponent
            let listed = try await ExportIO.retrying("listing frames/\(clip)", anchors: [outputAnchor]) { try Self.frameFiles(in: folder, clipDir: "frames/\(clip)") }
            let names = Set(listed.keys)
            let want = Set(keys.map { "\($0).jpg" })
            guard names == want, listed.values.allSatisfy({ $0 > 0 }) else {
                throw PackageError.folderIncomplete(clip: clip, detail: "\(want.subtracting(names).count) frame(s) missing, \(names.subtracting(want).count) unexpected, "
                                                    + "\(listed.values.filter { $0 == 0 }.count) empty")
            }
        }
        try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("windows.jsonl"), atomically: true, encoding: .utf8)
        try readme(summary).write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
        let summaryEncoder = JSONEncoder()
        summaryEncoder.dateEncodingStrategy = .iso8601
        summaryEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try summaryEncoder.encode(summary).write(to: dir.appendingPathComponent("summary.json"))
        if let beforeZip {
            do { try beforeZip(dir) } catch {
                if resume != nil {
                    // The folder was preserved for resumption; it stays so: frames kept, only what says "finished" goes.
                    for f in completionFiles { try? fm.removeItem(at: dir.appendingPathComponent(f)) }
                    try? writer?.state(.preflightFailed, note: error.localizedDescription)
                } else {
                    try? fm.removeItem(at: dir)
                    try? writer?.close()
                    try? fm.removeItem(at: journalURL)
                }
                closed = true
                throw error
            }
            try writer?.state(.preflightPassed)
        }
        // Exposure is recorded once the package is complete and has passed every check it is given — never for a
        // folder that failed or was cut short. The row is keyed by package, so a resumed run never doubles it.
        try ExposureLog.record(videos: Set(usable.map { $0.0.name }), kind: .trainingPackage, ref: packageName,
                               note: valOnly ? "val-only multi-frame export (test set)" : "multi-frame package", in: store.root)
        if valOnly {
            try writer?.state(.finalized); try writer?.close(); closed = true
            return (dir, summary)
        }
        guard try TrainingPackage.zipFolder(dir, to: zip) else { throw PackageError.zipFailed }
        try writer?.state(.finalized); try writer?.close(); closed = true
        return (zip, summary)
    }

    // MARK: - Writing, resuming, verifying

    /// The files an export writes once its frames are complete; rebuilt from the plan every time.
    static let completionFiles = ["windows.jsonl", "README.txt", "summary.json"]

    /// A folder can be resumed into only when it is an export cut short: `frames/` and nothing
    /// else (no windows.jsonl, summary, README, record or zip — a finished package is never
    /// written into), and every clip folder in it is one this export packages. One exception,
    /// only when the journal confirms the run never reached its preflight: completion files a
    /// run was cut short while writing are tolerated and returned, to be shed by the caller once
    /// the run identity has been verified too (they are regenerated from the plan) — the record
    /// and the zip, which only a finished run writes, never. Nothing is removed here.
    private static func checkResumable(_ dir: URL, zip: URL, clipFolders: Set<String>, unfinishedByJournal: Bool) throws -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { throw ResumeError.notAFolder(dir.path) }
        var entries = try fm.contentsOfDirectory(atPath: dir.path).filter { $0 != ".DS_Store" }
        if fm.fileExists(atPath: zip.path) { entries.append(zip.lastPathComponent) }
        let stale = unfinishedByJournal ? entries.filter(completionFiles.contains) : []
        entries.removeAll(where: stale.contains)
        guard entries == ["frames"] else { throw ResumeError.notResumable(dir.path, found: (entries + stale).sorted()) }
        let frames = dir.appendingPathComponent("frames", isDirectory: true)
        guard fm.fileExists(atPath: frames.path, isDirectory: &isDir), isDir.boolValue else { throw ResumeError.notResumable(dir.path, found: ["frames (a file)"]) }
        for entry in try fm.contentsOfDirectory(atPath: frames.path) where entry != ".DS_Store" {
            guard clipFolders.contains(entry) else { throw ResumeError.strayClipFolder("frames/\(entry)") }
        }
        return stale
    }

    /// Encodes `image` and writes it whole as `<key>.jpg`, retrying transient I/O errors while
    /// the volumes are still there; then journals it. Returns the bytes written.
    private static func write(_ image: CGImage, key: Int64, in clipURL: URL, plan: ClipPlan, anchors: [ExportIO.Anchor], writer: ExportJournal.Writer?) async throws -> Int {
        guard let data = SamplerImageTools.jpegData(image, quality: jpegQuality) else {
            throw PackageError.frameFailed(clip: plan.session.name, frame: "\(key).jpg", detail: "JPEG encoding failed")
        }
        try await Self.put(data, key: key, in: clipURL, plan: plan, anchors: anchors, writer: writer)
        return data.count
    }

    private static func put(_ data: Data, key: Int64, in clipURL: URL, plan: ClipPlan, anchors: [ExportIO.Anchor], writer: ExportJournal.Writer?) async throws {
        do {
            try await ExportIO.retrying("writing \(plan.session.name) frame \(key).jpg", anchors: anchors) {
                try ExportIO.writeWhole(data, to: clipURL.appendingPathComponent("\(key).jpg"))
            }
        } catch let failure as ExportIO.Failure {
            guard case .gaveUp(_, _, let detail) = failure else { throw failure }
            throw PackageError.frameFailed(clip: plan.session.name, frame: "\(key).jpg", detail: detail)
        }
        try writer?.append(.frame(clip: plan.safeName, key: key, sha256: ExportJournal.sha256(data), bytes: data.count))
    }

    /// The frame files of a clip folder by name with their sizes. Anything that is not a frame
    /// of this export is refused: the folder must be this export's own.
    private static func frameFiles(in clipURL: URL, clipDir: String, partials: Bool = false) throws -> [String: Int] {
        let fm = FileManager.default
        var out: [String: Int] = [:]
        for entry in try fm.contentsOfDirectory(at: clipURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) {
            let name = entry.lastPathComponent
            if name == ".DS_Store" { continue }
            let values = try entry.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if partials, name.hasSuffix(".jpg" + ExportIO.partialSuffix) { out[name] = values.fileSize ?? 0; continue }
            // A frame's name is its key as this export writes it: no other spelling of the same
            // number (a leading zero, a sign) is a frame, so no two names can mean one moment.
            guard values.isRegularFile == true, name.hasSuffix(".jpg"), let key = Int64(name.dropLast(4)), String(key) == name.dropLast(4) else {
                throw ResumeError.unexpectedFile("\(clipDir)/\(name)")
            }
            out[name] = values.fileSize ?? 0
        }
        return out
    }

    private struct Retained {
        /// Frames proven and kept: by the journal's hash, or by byte-identical regeneration.
        var kept: Set<Int64> = []
        var sizes: [Int64: Int] = [:]
        var byJournal = 0
        var byRegeneration = 0
        /// Frames proven by regeneration, to be journaled when the run writes.
        var proven: [Int64: (sha256: String, bytes: Int)] = [:]
        /// Frames in the folder that were not whole, planned and identical to their regeneration: to be replaced.
        var invalid: [Int64] = []
        var replacementSizes: [Int64: Int] = [:]
        /// Leftover `.part` files: to be removed.
        var partials: [String] = []
    }

    /// What of the plan is already in the folder and can be trusted — read-only. Each file is
    /// read; its name must be a frame the plan needs; it is kept when its bytes hash to what
    /// the journal says this run wrote and it is a whole JPEG of the planned size — or, for a
    /// frame the journal does not know (a legacy folder, or the frames after the journal's last
    /// line), when its bytes are identical to the frame regenerated now from the video with this
    /// export's settings: the strongest proof available that it is this source at this moment,
    /// scaled and encoded this way. Anything else is a torn or foreign file, judged as found:
    /// more than a few in one clip means the folder is not this export's, and nothing is reused.
    private static func validateRetained(in clipURL: URL, plan p: ClipPlan, journal: [Int64: (sha256: String, bytes: Int)],
                                         anchors: [ExportIO.Anchor], watch: VolumeWatch) async throws -> Retained {
        let clipDir = p.clipDir
        let listed = try await ExportIO.retrying("listing \(clipDir)", anchors: anchors) {
            try frameFiles(in: clipURL, clipDir: clipDir, partials: true)
        }
        var result = Retained()
        let expected = (Int(p.clip.outputSize.width), Int(p.clip.outputSize.height))
        // Frames the journal cannot vouch for, waiting to be compared with their regeneration —
        // judged in the order they were found, a batch at a time (`validationBatch`).
        var pending: [(key: Int64, time: CMTime, data: Data, whole: Bool)] = []
        func judge() async throws {
            guard !pending.isEmpty else { return }
            let fresh = try await Self.regenerate(pending.map { (key: $0.key, time: $0.time) }, plan: p, anchors: anchors, watch: watch)
            for frame in pending {
                guard let regenerated = fresh[frame.key] else {   // `regenerate` answers every key or throws
                    throw PackageError.frameFailed(clip: p.session.name, frame: "\(frame.key).jpg", detail: "not regenerated")
                }
                if frame.whole, regenerated == frame.data {
                    result.kept.insert(frame.key); result.sizes[frame.key] = frame.data.count; result.byRegeneration += 1
                    result.proven[frame.key] = (ExportJournal.sha256(frame.data), frame.data.count)
                } else {
                    result.invalid.append(frame.key)
                    result.replacementSizes[frame.key] = regenerated.count
                    // Judged as they are found: a folder that is not this export's is refused before the rest is decoded.
                    guard result.invalid.count <= maxInvalidPerClip else { throw ResumeError.tooManyInvalid(clip: p.session.name, count: result.invalid.count, limit: maxInvalidPerClip) }
                }
            }
            pending.removeAll(keepingCapacity: true)
        }
        for name in listed.keys.sorted() {
            if let error = watch.error { throw error }
            if name.hasSuffix(ExportIO.partialSuffix) { result.partials.append(name); continue }
            let key = Int64(name.dropLast(4))!
            guard let time = p.needed[key] else { throw ResumeError.unexpectedFile("\(clipDir)/\(name)") }
            let data = try await ExportIO.retrying("reading \(clipDir)/\(name)", anchors: anchors) { try Data(contentsOf: clipURL.appendingPathComponent(name)) }
            let whole: Bool
            if case .valid(let w, let h) = ExportIO.inspectFrame(data), (w, h) == expected { whole = true } else { whole = false }
            if whole, let known = journal[key], known.bytes == data.count, known.sha256 == ExportJournal.sha256(data) {
                result.kept.insert(key); result.sizes[key] = data.count; result.byJournal += 1
                continue
            }
            pending.append((key, time, data, whole))
            if pending.count == validationBatch { try await judge() }
        }
        try await judge()
        return result
    }

    /// How many retained frames are regenerated in one request while validating. The frames of
    /// a window are consecutive, so one request decodes forward from a key frame once instead of
    /// seeking back to it for every frame; the batch also bounds what is held in memory at once
    /// (this many stored frames and their regenerations).
    static let validationBatch = 64

    /// The frames at `moments`, regenerated from the video with this export's settings, by key.
    /// Asked for together in time order; each answer is matched to its own requested moment by
    /// that moment, whatever order the answers come in; an answer for a moment not asked for, or
    /// a second answer for one, stops the export. A moment the request could not decode — or
    /// did not answer, as after a cancelled generator — is asked for again on its own, with the
    /// same bounded retries as before. Every key is answered, or an error is thrown.
    private static func regenerate(_ moments: [(key: Int64, time: CMTime)], plan p: ClipPlan, anchors: [ExportIO.Anchor], watch: VolumeWatch) async throws -> [Int64: Data] {
        let wanted = Dictionary(uniqueKeysWithValues: moments)
        var out: [Int64: Data] = [:]
        var answered = Set<Int64>()
        if !moments.isEmpty {   // (an empty request would never finish)
            for await result in p.clip.generator.images(for: moments.map(\.time).sorted { $0 < $1 }) {
                if let error = watch.error { throw error }
                let key = ClipFrames.key(result.requestedTime)
                guard wanted[key] != nil, answered.insert(key).inserted else {
                    throw PackageError.frameFailed(clip: p.session.name, frame: "\(key).jpg", detail: "the generator answered a moment that was not asked for, or answered one twice")
                }
                guard let image = try? result.image, let data = SamplerImageTools.jpegData(image, quality: jpegQuality) else { continue }
                out[key] = data
            }
        }
        if let error = watch.error { throw error }
        for (key, time) in moments where out[key] == nil {
            out[key] = try await Self.regenerate(key: key, at: time, plan: p, anchors: anchors)
        }
        return out
    }

    /// Judges a planned frame the export's decoder could not produce after its bounded retries
    /// (`Undecodable`). The volumes are checked first — a lost mount is never "undecodable". A
    /// decoder created for this one question is asked for the frame: an answer is the frame.
    /// Otherwise the frame is a candidate only for an HEVC clip and a decode failure from both
    /// decoders, and only when the run of consecutive undecodable frames it sits in (walked frame
    /// by frame with the fresh decoder) is short enough for leading pictures and bounded on both
    /// sides by frames that decode. A neighbour that fails with anything but a decode failure stops
    /// the export. Verdicts that keep the export going are fatal errors named for the frame. The
    /// fresh decoder is watched like the export's own (`VolumeWatch`): a mount that goes while it
    /// is asked is a lost volume within seconds, never an "undecodable" frame or a network timeout.
    private static func judgeUndecodable(at time: CMTime, error: NSError, plan p: ClipPlan, anchors: [ExportIO.Anchor]) async throws -> Judgement {
        for anchor in anchors { try anchor.verify() }
        let fresh = try await p.clip.freshGenerator()
        let watch = VolumeWatch(anchors: anchors, generator: fresh)
        defer { watch.stop() }
        func lost() throws { if let error = watch.error { throw error } }
        let freshError: NSError
        do { let image = try await fresh.image(at: time).image; try lost(); return .decoded(image) } catch { try lost(); freshError = error as NSError }
        if let why = Undecodable.refusal(codec: p.clip.codec, error: error, fresh: freshError) { return .fatal(why) }
        func decodes(_ t: CMTime) async throws -> Bool {
            do { _ = try await fresh.image(at: t).image; try lost(); return true } catch {
                try lost()
                let e = error as NSError
                guard Undecodable.isDecodeFailure(e) else {
                    throw PackageError.frameFailed(clip: p.session.name, frame: "\(ClipFrames.key(t)).jpg", detail: "a neighbouring frame failed differently: \(Undecodable.describe(e))")
                }
                return false
            }
        }
        var run = 1, boundedBefore = false, boundedAfter = false
        var t = time
        while run <= Undecodable.maxRun, let previous = p.clip.adjacent(to: t, by: -1) {
            if try await decodes(previous) { boundedBefore = true; break }
            run += 1; t = previous
        }
        t = time
        while run <= Undecodable.maxRun, let next = p.clip.adjacent(to: t, by: 1) {
            if try await decodes(next) { boundedAfter = true; break }
            run += 1; t = next
        }
        switch Undecodable.verdict(run: run, boundedBefore: boundedBefore, boundedAfter: boundedAfter, fresh: freshError) {
        case .fatal(let why): return .fatal(why)
        case .leftOut(let reason): return .leftOut(reason: reason, fresh: Undecodable.describe(freshError), run: run)
        }
    }

    private static func regenerate(key: Int64, at time: CMTime, plan p: ClipPlan, anchors: [ExportIO.Anchor]) async throws -> Data {
        try await ExportIO.retrying("decoding \(p.session.name) frame \(key)", anchors: anchors) { () throws -> Data in
            guard let image = try? await p.clip.generator.image(at: time).image, let data = SamplerImageTools.jpegData(image, quality: jpegQuality)
            else { throw CocoaError(.fileReadCorruptFile) }
            return data
        }
    }

    /// Applies what `validateRetained` judged, once every clip has been judged: leftover `.part`
    /// files go, torn or foreign frames are replaced by their regeneration, and frames proven by
    /// regeneration are journaled so the next resume need not decode them again.
    private static func repairRetained(in clipURL: URL, plan p: ClipPlan, retained: Retained, anchors: [ExportIO.Anchor], writer: ExportJournal.Writer?) async throws {
        let fm = FileManager.default
        for name in retained.partials {
            try await ExportIO.retrying("removing \(p.clipDir)/\(name)", anchors: anchors) { try fm.removeItem(at: clipURL.appendingPathComponent(name)) }
        }
        for (key, proof) in retained.proven.sorted(by: { $0.key < $1.key }) {
            try writer?.append(.frame(clip: p.safeName, key: key, sha256: proof.sha256, bytes: proof.bytes))
        }
        for key in retained.invalid {
            let fresh = try await Self.regenerate(key: key, at: p.needed[key]!, plan: p, anchors: anchors)
            guard fresh.count == retained.replacementSizes[key] else {
                throw PackageError.frameFailed(clip: p.session.name, frame: "\(key).jpg", detail: "regenerated differently twice; the video is not stable")
            }
            try await Self.put(fresh, key: key, in: clipURL, plan: p, anchors: anchors, writer: writer)
        }
        try writer?.flush()
    }

    /// After a clip is written: the folder holds exactly the frames in `sizes`, each with the
    /// size that was written or validated.
    private static func verifyFolder(_ clipURL: URL, clipDir: String, clip: String, sizes: [Int64: Int], anchors: [ExportIO.Anchor]) async throws {
        let listed = try await ExportIO.retrying("listing \(clipDir)", anchors: anchors) { try frameFiles(in: clipURL, clipDir: clipDir) }
        let want = Dictionary(uniqueKeysWithValues: sizes.map { ("\($0.key).jpg", $0.value) })
        guard listed == want else {
            let missing = Set(want.keys).subtracting(listed.keys).count
            let extra = Set(listed.keys).subtracting(want.keys).count
            let wrong = want.filter { listed[$0.key] != nil && listed[$0.key] != $0.value }.count
            throw PackageError.folderIncomplete(clip: clip, detail: "\(missing) missing, \(extra) unexpected, \(wrong) with another size than written")
        }
    }

    /// Watches the volumes while a clip's frames are generated: checks every few seconds and,
    /// when one is gone, stops the generator so the export fails within seconds, not when the
    /// network times out. `error` is set when it tripped.
    final class VolumeWatch: @unchecked Sendable {
        private let lock = NSLock()
        private var failure: Error?
        private var task: Task<Void, Never>?

        fileprivate init(anchors: [ExportIO.Anchor], generator: AVAssetImageGenerator, every seconds: TimeInterval = 10) {
            task = Task.detached { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    if Task.isCancelled { return }
                    do { for anchor in anchors { try anchor.verify() } } catch {
                        self?.trip(error)
                        generator.cancelAllCGImageGeneration()
                        return
                    }
                }
            }
        }

        private func trip(_ error: Error) { lock.lock(); failure = error; lock.unlock() }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
        func stop() { task?.cancel() }
    }

    /// Hidden frames of `rally` between two sightings at most `occludedGap`
    /// apart, with where the ball must be: straight between them (upright,
    /// Vision-normalised), when that's in the picture.
    static func occluded(_ rally: TrackedRally, unreviewed: Bool) -> [(point: TrackPoint, box: CGRect)] {
        let seen = rally.points.filter { $0.state == .visible && $0.box != nil && ($0.isChecked || unreviewed) }
        guard seen.count >= 2 else { return [] }
        var result: [(TrackPoint, CGRect)] = []
        var i = 0
        for point in rally.points where point.state == .hidden && (point.isChecked || unreviewed) {
            while i + 1 < seen.count && seen[i + 1].time < point.time { i += 1 }
            guard i + 1 < seen.count, seen[i].time < point.time, let a = seen[i].box?.rect, let b = seen[i + 1].box?.rect,
                  seen[i + 1].time - seen[i].time <= Self.occludedGap else { continue }
            let f = (point.time - seen[i].time) / (seen[i + 1].time - seen[i].time)
            let lerp = { (x: CGFloat, y: CGFloat) in x + (y - x) * f }
            let w = lerp(a.width, b.width), h = lerp(a.height, b.height)
            let box = CGRect(x: lerp(a.midX, b.midX) - w / 2, y: lerp(a.midY, b.midY) - h / 2, width: w, height: h)
            guard (0...1).contains(box.midX), (0...1).contains(box.midY) else { continue }
            result.append((point, box))
        }
        return result
    }

    /// Rallies tracked frame by frame and marked done, and pre-tracked ones
    /// not said to be no rally (in val, only their frames a person checked
    /// are labels).
    static func readyTracks(_ session: VideoSession) -> [TrackedRally] {
        (session.tracks ?? []).filter(\.isReady)
    }

    static func readme(_ s: Summary) -> String {
        """
        RallyLab multi-frame package — \(s.name)

        \(s.trainWindows) train + \(s.valWindows) val windows from \(s.clips) clips: each is a reviewed
        frame with the \(span) frames before and after it (about 1/\(Int(frameRate)) s apart), \(s.balls) balls,
        \(s.noBallWindows) windows with no ball. \(s.trackedWindows) of the windows are from rallies tracked frame by
        frame, with every frame labeled; in the rest only the middle frame is.
        \(s.deadWindows) dead-time windows (no rally on, from videos with every rally marked) aren't
        trained on: they score how often the model fires when no rally is on.
        \(s.machineRallies) rallies were pre-tracked by the model: \(s.machineFrames) of their frames are the
        model's own labels ("pseudo"), used with --pseudo.
        \(s.missingVideos.isEmpty ? "" : "\(s.framesWithoutVideo) reviewed frames from \(s.missingVideos.count) clips aren't here: their videos weren't on the Mac.\n")
        \(s.resume.map { "Completed from an export cut short: \($0.framesRetained) frames were already here and proven (\($0.retainedByJournal) by the journal's hashes, \($0.retainedByRegeneration) byte-identical to their regeneration), \($0.framesReplaced) replaced, \($0.framesWritten) written by the resumed run; details in summary.json.\n" } ?? "")
        \(s.undecodableFrames == 0 ? "" : "\(s.undecodableFrames) planned frames in \(s.undecodable.count) clips could not be decoded (HEVC leading pictures, which the frame-accurate decoder cannot produce on their own); they and the \(s.windowsLeftOutUndecodable) windows that needed them are left out — no frame stands in for another — and listed per clip in summary.json (\"undecodable\"; D-024).\n")
        Train it with scripts/desktop_training/train_heatmap_model.py — it reads windows.jsonl
        directly. See that script's header for the steps.

        """
    }
}

/// One video's frames, as stored, for pulling exact neighbouring frames.
private struct ClipFrames {
    let generator: AVAssetImageGenerator
    let rotation: StoredRotation?
    let outputSize: CGSize
    let duration: Double
    /// The video's codec (`kCMVideoCodecType_HEVC`, `_H264`, …), from the track's format description.
    let codec: CMVideoCodecType
    private let video: URL
    private let track: AVAssetTrack
    /// Video frames between neighbours in a window.
    private let step: Int
    /// The moments the video shows: the track's range in the asset's timeline. A clip trimmed
    /// in Photos keeps every frame it was recorded with and shortens it with an edit list; the
    /// sample cursor still walks the cut-off frames, but the generator gives no picture for a
    /// moment past this end (`Cannot Open`) and, for a moment that starts before the end but
    /// shows no frame of its own — the end is kept in the header's timescale, often 1 ms, and
    /// can sit a hair past the last frame's start plus its spacing — the last frame's picture
    /// again under another name. A frame is shown only when all of it fits before the end.
    private let playable: CMTimeRange

    init(video: URL, longSide: CGFloat) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.track = track
        self.video = video
        duration = try await asset.load(.duration).seconds
        playable = try await track.load(.timeRange)
        guard let format = try await track.load(.formatDescriptions).first else { throw CocoaError(.fileReadCorruptFile) }
        codec = CMFormatDescriptionGetMediaSubType(format)
        let fps = Double(try await track.load(.nominalFrameRate))
        step = max(1, Int((fps / MultiFramePackage.frameRate).rounded()))
        let natural = try await track.load(.naturalSize)
        let scale = min(1, longSide / max(natural.width, natural.height))
        outputSize = CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
        rotation = await StoredRotation.of(video: video)
        generator = Self.makeGenerator(asset: asset, outputSize: outputSize)
    }

    private static func makeGenerator(asset: AVAsset, outputSize: CGSize) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = false   // as stored, like the app's pipeline
        generator.maximumSize = outputSize
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    /// A generator of this clip's frames with the export's settings on a new asset object:
    /// nothing shared with `generator`, so an answer or a refusal is the decoder's, not a state's.
    func freshGenerator() async throws -> AVAssetImageGenerator {
        let asset = AVURLAsset(url: video)
        guard try await asset.loadTracks(withMediaType: .video).first != nil else { throw CocoaError(.fileReadCorruptFile) }
        return Self.makeGenerator(asset: asset, outputSize: outputSize)
    }

    /// File-name key for a frame: its presentation time in microseconds.
    static func key(_ time: CMTime) -> Int64 { Int64((time.seconds * 1_000_000).rounded()) }

    /// The moment of the video frame `count` frames from the frame at `time` (a frame's own
    /// presentation time) in presentation order, when the video shows it whole; nil at the
    /// clip's ends.
    func adjacent(to time: CMTime, by count: Int) -> CMTime? {
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: time), cursor.presentationTimeStamp == time,
              cursor.stepInPresentationOrder(byCount: Int64(count)) == Int64(count), shownWhole(cursor) else { return nil }
        return cursor.presentationTimeStamp
    }

    /// Whether the cursor's frame is shown whole: its end, in the header's own timescale (rounded
    /// towards the start, as a header rounds a duration), no later than the playable end.
    private func shownWhole(_ cursor: AVSampleCursor) -> Bool {
        let time = cursor.presentationTimeStamp
        let shown = CMTimeConvertScale(time + cursor.currentSampleDuration, timescale: playable.end.timescale, method: .roundTowardZero)
        return time >= playable.start && shown <= playable.end
    }

    /// Presentation times of the window around the frame showing at `seconds`
    /// — the frame the sampler extracted, which is the last one starting at or
    /// before that time — or nil if the video ends too soon on either side:
    /// the frames run out, or the window would reach a moment whose frame the
    /// video does not show whole (`playable`). The cursor's times are the
    /// moments the generator is then asked for, so they are what is held to
    /// that range.
    /// `exact`: `seconds` is a frame's own presentation time (a tracked
    /// rally's), which rounded to the sampler's 1/600 s could land a hair
    /// before the frame (59.94 fps) and centre the window on the one before.
    func window(around seconds: Double, exact: Bool = false) -> [CMTime]? {
        let t = exact ? TrackFrameStore.request(seconds) : CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: t) else { return nil }
        if cursor.presentationTimeStamp > t, cursor.stepInPresentationOrder(byCount: -1) != -1 { return nil }
        var times: [CMTime] = []
        for offset in -MultiFramePackage.span...MultiFramePackage.span {
            let want = Int64(offset * step)
            guard let c = cursor.copy() as? AVSampleCursor, c.stepInPresentationOrder(byCount: want) == want, shownWhole(c) else { return nil }
            times.append(c.presentationTimeStamp)
        }
        return times
    }
}
