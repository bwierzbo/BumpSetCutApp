//
//  PreTracker.swift
//  RallyLab
//
//  Self-training, step one: the model tracks rallies on its own. In each
//  train video, up to `perVideo` of the rallies you marked or the Sampler
//  found (spread through the video) are tracked the way the Track tab does
//  it — YOLO and the newest multi-frame model propose, TrackSolver picks
//  the path — and saved as pre-tracked rallies. Their sure frames
//  (MachineLabels) train as machine labels; the rest go to annotation
//  review, on the phone or here. Val videos are left alone: val stays
//  people's labels, so the score stays honest.
//
//  Run it again after training a better model with `redo`: the rallies
//  already pre-tracked are tracked again, around the frames people have
//  checked since.
//
//  `check` measures sure frames against the rallies people tracked in val
//  videos: how often a sure frame's ball is within 4 px (at the trainer's
//  512 wide) of the person's, and what share of their balls are sure — at
//  a few cut-offs, to choose MachineLabels'.
//

import AVFoundation
import Foundation

@MainActor
enum PreTracker {

    /// Pre-tracked rallies per video, at most: ~3 × 76 train videos is ~70k
    /// frames — a 512 package of a few GB, and about a third of the frames
    /// for review (measured 2026-10-10). Raise it with --per-video once
    /// that's reviewed or the disk has room.
    static let perVideo = 3
    /// A rally the path finds the ball on less of than this isn't kept: most
    /// likely not a rally (a time-out the Sampler took for one), or footage
    /// the model can't follow yet — either way, not worth reviewing.
    static let minFound = 0.4

    struct Report {
        var videos = 0, rallies = 0, redone = 0, dropped = 0, frames = 0, sure = 0, toReview = 0
    }

    /// `only`: these videos (session names); empty, every train video.
    static func run(sampler: SamplerModel, only: [String] = [], perVideo: Int = perVideo, redo: Bool,
                    log: (String) -> Void) async -> Report {
        var report = Report()
        guard let heat = TrackLabelModel.newestHeatModel(in: sampler.datasetRoot) else {
            log("No multi-frame model in this project (Models tab, or desktop.sh fetch) — pre-tracking needs one.")
            return report
        }
        log("Multi-frame model: \(heat.deletingPathExtension().lastPathComponent)")
        let yolo = sampler.prelabelModel
        let sessions = sampler.sessions.filter {
            $0.split != "val" && FileManager.default.fileExists(atPath: $0.sourcePath) && (only.isEmpty || only.contains($0.name))
        }
        for (n, session) in sessions.enumerated() {
            let video = AVURLAsset(url: URL(fileURLWithPath: session.sourcePath))
            guard let track = try? await video.loadTracks(withMediaType: .video).first,
                  let fps = try? await track.load(.nominalFrameRate) else {
                log("\(session.name): couldn't read the video.")
                continue
            }
            let step = max(1, Int((Double(fps) / TrackLabelModel.frameRate).rounded()))
            var tracks = session.tracks ?? []
            var changed = false

            if redo {
                for i in tracks.indices where tracks[i].isMachine && tracks[i].isRally != false {
                    let times = tracks[i].points.map(\.time)
                    guard let found = await TrackLabelModel.candidates(video: video, times: times, model: yolo, heatModel: heat,
                                                                       frames: nil, progress: { _ in }) else { return report }
                    tracks[i].candidates = found
                    tracks[i].points = TrackSolver.solve(tracks[i])   // people's frames stay as they are
                    report.redone += 1
                    changed = true
                }
            }

            let rallies = TrackLabelModel.markedAndFound(session)
            let open = TrackLabelModel.untracked(rallies.marked + rallies.found, tracks: tracks)
            // One said not to be a rally stays (so its time isn't picked
            // again) but doesn't count toward the video's pre-tracked rallies.
            let wanted = max(0, perVideo - tracks.filter { $0.isMachine && $0.isRally != false }.count)
            var added = 0
            for span in spread(open, count: wanted) {
                guard let times = TrackLabelModel.frameTimes(track: track, step: step, start: max(0, span.start - TrackedRally.margin),
                                                             end: span.end + TrackedRally.margin), times.count > 2 * MachineLabels.reach,
                      let found = await TrackLabelModel.candidates(video: video, times: times, model: yolo, heatModel: heat,
                                                                   frames: nil, progress: { _ in }) else { continue }
                // Cut from rally times a person marked: a rally, no need to ask.
                var rally = TrackedRally(id: UUID(), start: times.first!, end: times.last!,
                                         points: times.map { TrackPoint(time: $0, state: .unknown, origin: .auto, box: nil) },
                                         candidates: found, done: false, machine: true,
                                         isRally: rallies.marked.contains(span) ? true : nil)
                rally.points = TrackSolver.solve(rally)
                let seen = Double(rally.points.filter { $0.state == .visible }.count) / Double(rally.points.count)
                guard seen >= minFound else { report.dropped += 1; continue }
                tracks.append(rally)
                added += 1
                changed = true
            }
            if changed {
                tracks.sort { $0.start < $1.start }
                sampler.setTracks(tracks, session: session.name)
            }
            report.videos += 1
            report.rallies += added
            let machine = tracks.filter { $0.isMachine && $0.isRally != false }
            let frames = machine.reduce(0) { $0 + $1.points.count }
            let sure = machine.reduce(0) { $0 + MachineLabels.trusted($1).count }
            let review = AnnotationReview.items(machine.map { (session.name, $0) }, kinds: [.crop, .noBall, .unsure]).count
            report.frames += frames
            report.sure += sure
            report.toReview += review
            log("[\(n + 1)/\(sessions.count)] \(session.name): \(added) new · \(machine.count) pre-tracked rallies, "
                + "\(frames) frames, \(sure) sure, \(review) to review")
        }
        return report
    }

    /// `count` of `rallies`, evenly through the list (so through the video).
    static func spread(_ rallies: [LabelRally], count: Int) -> [LabelRally] {
        guard count > 0, !rallies.isEmpty else { return [] }
        guard rallies.count > count else { return rallies }
        return (0..<count).map { rallies[Int((Double($0) + 0.5) * Double(rallies.count) / Double(count))] }
    }

    // MARK: - Checking the cut-offs

    /// For each cut-off pair: sure frames, how many of them are right (the
    /// person's ball within 4 px at 512), and the person's checked balls.
    struct Check {
        let minConfidence: Double
        let maxOffArc: Double
        let reach: Int
        var sure = 0, right = 0, wrongNoBall = 0, people = 0
        /// Frames the path found a ball on at all (the most that could be sure).
        var found = 0
        var precision: Double { Double(right) / Double(max(sure, 1)) }
        var coverage: Double { Double(right) / Double(max(people, 1)) }
    }

    static let confidences = [0.4, 0.5, 0.6, 0.7, 0.8]
    static let offArcs = [0.006, 0.01]
    static let reaches = [1, 2, 3]
    /// The trainer's match radius, in pixels at its 512 wide.
    static let tolerance = 4.0

    static func check(sampler: SamplerModel, log: (String) -> Void) async -> [Check] {
        var checks = reaches.flatMap { r in confidences.flatMap { c in offArcs.map { Check(minConfidence: c, maxOffArc: $0, reach: r) } } }
        guard let heat = TrackLabelModel.newestHeatModel(in: sampler.datasetRoot) else {
            log("No multi-frame model in this project — nothing to check.")
            return []
        }
        log("Multi-frame model: \(heat.deletingPathExtension().lastPathComponent)")
        let yolo = sampler.prelabelModel
        for session in sampler.sessions where session.split == "val" && FileManager.default.fileExists(atPath: session.sourcePath) {
            let people = (session.tracks ?? []).filter { $0.done && !$0.isMachine }
            guard !people.isEmpty else { continue }
            let video = AVURLAsset(url: URL(fileURLWithPath: session.sourcePath))
            guard let track = try? await video.loadTracks(withMediaType: .video).first,
                  let natural = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { continue }
            let upright = natural.applying(transform)
            let (w, h) = (abs(upright.width), abs(upright.height))
            for theirs in people {
                let times = theirs.points.map(\.time)
                guard let found = await TrackLabelModel.candidates(video: video, times: times, model: yolo, heatModel: heat,
                                                                   frames: nil, progress: { _ in }) else { return checks }
                var mine = TrackedRally(id: UUID(), start: theirs.start, end: theirs.end,
                                        points: times.map { TrackPoint(time: $0, state: .unknown, origin: .auto, box: nil) },
                                        candidates: found, done: false, machine: true)
                mine.points = TrackSolver.solve(mine)
                let balls = theirs.points.filter { $0.isChecked && $0.state == .visible && $0.box != nil }.count
                for k in checks.indices {
                    checks[k].people += balls
                    checks[k].found += mine.points.indices.filter { mine.points[$0].state == .visible && theirs.points[$0].isChecked }.count
                    for i in MachineLabels.trusted(mine, minConfidence: checks[k].minConfidence, maxOffArc: checks[k].maxOffArc,
                                                   reach: checks[k].reach) {
                        let person = theirs.points[i]
                        guard person.isChecked else { continue }   // nobody looked: can't say
                        checks[k].sure += 1
                        guard person.state == .visible, let a = person.box?.rect, let b = mine.points[i].box?.rect else {
                            checks[k].wrongNoBall += 1
                            continue
                        }
                        let px = hypot((a.midX - b.midX) * w, (a.midY - b.midY) * h) / max(w, h) * 512
                        if px <= tolerance { checks[k].right += 1 }
                    }
                }
            }
            log("\(session.name): \(people.count) rallies checked")
        }
        return checks
    }
}
