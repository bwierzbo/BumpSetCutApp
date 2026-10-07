//
//  TrackFinder.swift
//  RallyLab (macOS and iPhone)
//
//  The ball's candidates on each frame of a rally, as the Track tab and the
//  iPhone's tracking both find them: YOLO's boxes, plus the multi-frame
//  model's peaks merged in. TrackSolver then picks the path through them.
//

import CoreGraphics
import Foundation

enum TrackFinder {

    /// The multi-frame model's peaks on every frame — run on overlapping
    /// windows of the frames in order (HeatmapWindows, as the pipeline runs
    /// it), each frame answered from a window with frames both sides —
    /// merged with YOLO's candidates: one at the same spot raises that
    /// candidate's confidence; one YOLO didn't have is added. It sees motion,
    /// so it adds blurred and far balls and skips still ones. A frame that
    /// couldn't be read stands in with the one before it.
    /// A multi-frame peak with no YOLO candidate at the spot counts this much.
    static let heatAloneWeight = 0.6

    static func addHeatmapCandidates(_ heat: HeatmapBallDetector, grays: [HeatmapBallDetector.Frame?],
                                     to found: inout [[TrackCandidate]]) {
        var windows = HeatmapWindows(detector: heat)
        var answers: [[HeatmapBallDetector.Peak]] = []
        var last: HeatmapBallDetector.Frame?
        for gray in grays {
            guard let frame = gray ?? last ?? grays.lazy.compactMap({ $0 }).first else { answers.append([]); continue }
            last = frame
            answers += windows.push(frame)
        }
        answers += windows.finish()
        for (i, peaks) in answers.enumerated() where found.indices.contains(i) {
            for peak in peaks {
                let c = CGPoint(x: peak.rect.midX, y: peak.rect.midY)
                let near = found[i].indices.first { k in
                    let r = found[i][k].rect
                    return hypot(r.midX - c.x, (r.midY - c.y) * 9 / 16) < max(r.width, 0.012)
                }
                if let k = near {
                    found[i][k].confidence = 1 - (1 - found[i][k].confidence) * (1 - Double(peak.confidence))
                } else {
                    // On its own it's less sure: picked when it fits the path, not
                    // over "hidden" (it can carry a ball on through an occlusion).
                    found[i].append(TrackCandidate(rect: peak.rect, confidence: Double(peak.confidence) * heatAloneWeight))
                }
            }
        }
    }
}
