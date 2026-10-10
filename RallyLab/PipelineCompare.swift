//
//  PipelineCompare.swift
//  RallyLab
//
//  Does the multi-frame model make the real pipeline better? Runs the full
//  processing pipeline on a video twice — YOLO alone, then YOLO + the
//  multi-frame model — and scores both against what you've labeled:
//
//  - your tracked rallies' frames: did the pipeline have a detection on
//    your ball, and was the rally's selected track on it?
//  - your tracked rallies: is each inside a decided rally, and how far are
//    that rally's ends from it? (A tracked rally's range is where you
//    tracked, not a hand-set boundary — read the ends as a guide.)
//  - the whole video: how many rallies each finds (more can mean new false
//    ones; full rally labels — .rallylabels.json — score that properly).
//
//  Headless: RallyLab --project <name> --pipeline-compare <multi-frame model> <clip> [<clip>…]
//

import AVFoundation
import Foundation

enum PipelineCompare {

    struct Run {
        var rallies: [(start: Double, end: Double)] = []
        var labeled = 0, detected = 0, onTrack = 0
        var tracked = 0, covered = 0
        var startError: [Double] = [], endError: [Double] = []
        var heatOnlyDetections = 0
        var seconds = 0.0
    }

    @MainActor
    static func run(session: VideoSession, heatModel: URL, base: ProcessorConfig = ProcessorConfig()) async -> (Run, Run)? {
        // YOLO against YOLO + multi-frame, whatever the app's default finder is.
        var withHeat = base
        withHeat.heatmapModel = heatModel
        withHeat.heatmapOnly = false
        var off = base
        off.heatmapModel = nil
        off.heatmapOnly = false
        return await run(session: session, a: off, b: withHeat)
    }

    /// The pipeline with config `a`, then `b`, scored the same way.
    @MainActor
    static func run(session: VideoSession, a: ProcessorConfig, b: ProcessorConfig) async -> (Run, Run)? {
        let video = URL(fileURLWithPath: session.sourcePath)
        guard FileManager.default.fileExists(atPath: video.path) else { return nil }
        let rotation = await StoredRotation.of(video: video)
        let tracks = (session.tracks ?? []).filter(\.done)
        guard let first = await process(video, config: a, tracks: tracks, rotation: rotation),
              let second = await process(video, config: b, tracks: tracks, rotation: rotation) else { return nil }
        return (first, second)
    }

    @MainActor
    private static func process(_ video: URL, config: ProcessorConfig, tracks: [TrackedRally],
                                rotation: StoredRotation?) async -> Run? {
        let processor = VideoProcessor()
        processor.config = config
        processor.collectFrameEvidence = true
        let started = Date()
        var segments: [RallySegment] = []
        do {
            segments = try await processor.processVideo(video, videoId: UUID()).rallySegments
        } catch ProcessingError.noRalliesDetected {
            segments = []
        } catch {
            print("❌ \(video.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
        var run = Run()
        run.seconds = Date().timeIntervalSince(started)
        run.rallies = segments.map { ($0.startTime, $0.endTime) }
        let evidence = processor.frameEvidence
        run.heatOnlyDetections = evidence.reduce(0) { $0 + $1.detections.filter(\.fromHeatmap).count }
        let times = evidence.map(\.time)

        for rally in tracks {
            // Ball: every frame you saw it, against the evidence frame at that time.
            for point in rally.points where point.state == .visible {
                guard let box = point.box?.rect else { continue }
                let stored = rotation?.storedBox(box) ?? box   // evidence is in the stored frame
                guard let i = nearest(point.time, in: times), abs(times[i] - point.time) < 0.02 else { continue }
                run.labeled += 1
                let e = evidence[i]
                let size = max(stored.width, stored.height, 0.012)
                func near(_ p: CGPoint) -> Bool { hypot(p.x - stored.midX, (p.y - stored.midY) * 9 / 16) < size }
                if e.detections.contains(where: { !$0.isOffCourt && near(CGPoint(x: $0.bbox.midX, y: $0.bbox.midY)) }) {
                    run.detected += 1
                }
                if let tp = e.trackPoint, near(tp) { run.onTrack += 1 }
            }
            // Rally: where the ball was in play in your track.
            let seen = rally.points.filter { $0.state == .visible }.map(\.time)
            guard let first = seen.first, let last = seen.last, last > first else { continue }
            run.tracked += 1
            let overlapping = segments.filter { min($0.endTime, last) - max($0.startTime, first) > 0 }
            let overlap = overlapping.reduce(0) { $0 + min($1.endTime, last) - max($1.startTime, first) }
            if overlap >= 0.5 * (last - first), let s = overlapping.first, let e = overlapping.last {
                run.covered += 1
                run.startError.append(s.startTime - first)
                run.endError.append(e.endTime - last)
            }
        }
        return run
    }

    private static func nearest(_ t: Double, in times: [Double]) -> Int? {
        guard !times.isEmpty else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 && abs(times[lo - 1] - t) < abs(times[lo] - t) ? lo - 1 : lo
    }

    static func describe(_ r: Run) -> String {
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "—" : String(format: "%.0f%%", 100 * Double(a) / Double(b)) }
        func median(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "—" }
            let s = v.sorted()
            return String(format: "%+.1fs", s[s.count / 2])
        }
        return "ball detected on \(pct(r.detected, r.labeled)) of \(r.labeled) labeled frames · track on it \(pct(r.onTrack, r.labeled))"
            + " · tracked rallies inside a rally \(r.covered)/\(r.tracked) (start \(median(r.startError)), end \(median(r.endError)))"
            + " · \(r.rallies.count) rallies in the video"
            + (r.heatOnlyDetections > 0 ? " · \(r.heatOnlyDetections) multi-frame-only detections" : "")
            + String(format: " · %.0fs", r.seconds)
    }
}
