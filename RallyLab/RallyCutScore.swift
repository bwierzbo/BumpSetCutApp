//
//  RallyCutScore.swift
//  RallyLab
//
//  How good is rally cutting on the videos you've fully marked (Track tab →
//  Rally Times → "Whole video marked")? Runs the real pipeline on each and
//  scores the clips a user would get against your rally times: found,
//  missed, false, merged (one clip spanning several rallies) and split (one
//  rally cut in pieces), and how far starts and ends are off.
//
//  Then replays just the rally decision from the recorded evidence — no
//  detection, milliseconds a video — over settings for how clips are padded
//  and joined, to show what each would do. With a handful of videos that's
//  a hint, not a tuning: more marked videos make it trustworthy.
//
//  Headless: RallyLab --project <name> --score-rallies [clip…]
//

import Foundation

enum RallyCutScore {

    struct Video {
        let name: String
        let truth: [Interval]
        let evidence: [VideoProcessor.FrameEvidence]
        let duration: Double
        let clips: [Interval]
    }

    struct Tally {
        var truth = 0, clips = 0, found = 0, falseClips = 0, missed = 0, merged = 0, split = 0
        var startErrors: [Double] = [], endErrors: [Double] = []

        mutating func add(clips: [Interval], truth: [Interval], iou: Double = 0.3) {
            self.truth += truth.count
            self.clips += clips.count
            let r = RallySegmentationScorer.score(predicted: clips, groundTruth: truth,
                                                 config: ScoringConfig(iouMatchThreshold: iou, boundaryToleranceSec: 1.0))
            found += r.truePositives
            falseClips += r.unmatchedPredictions.filter { c in !truth.contains { overlap(c, $0) > 0 } }.count
            missed += r.unmatchedGroundTruth.filter { t in !clips.contains { overlap($0, t) > 0 } }.count
            merged += clips.filter { c in truth.filter { overlap(c, $0) > 0.5 * ($0.end - $0.start) }.count >= 2 }.count
            split += truth.filter { t in clips.filter { overlap($0, t) > 0.5 } .count >= 2 }.count
            for m in r.matches {
                startErrors.append(m.pred.start - m.truth.start)
                endErrors.append(m.pred.end - m.truth.end)
            }
        }

        var line: String {
            func med(_ v: [Double]) -> String {
                guard !v.isEmpty else { return "—" }
                let s = v.sorted()
                return String(format: "%+.1fs", s[s.count / 2])
            }
            let within = zip(startErrors, endErrors).filter { abs($0) <= 1 && abs($1) <= 1 }.count
            return "\(found)/\(truth) rallies found · \(missed) missed · \(falseClips) false clips · \(merged) merged clips · \(split) split"
                + " · start \(med(startErrors)) end \(med(endErrors)) (median) · both ends within 1 s: \(within)/\(max(found, 0))"
        }
    }

    static func overlap(_ a: Interval, _ b: Interval) -> Double { max(0, min(a.end, b.end) - max(a.start, b.start)) }

    @MainActor
    static func process(_ session: VideoSession) async -> Video? {
        let video = URL(fileURLWithPath: session.sourcePath)
        guard let data = try? Data(contentsOf: RallyMarkModel.labelsURL(for: video)),
              let labels = try? JSONDecoder().decode([LabeledRally].self, from: data) else { return nil }
        let processor = VideoProcessor()
        processor.config = ProcessorConfig()
        processor.collectFrameEvidence = true
        var segments: [RallySegment] = []
        do {
            segments = try await processor.processVideo(video, videoId: UUID()).rallySegments
        } catch ProcessingError.noRalliesDetected {
            segments = []
        } catch {
            print("❌ \(session.name): \(error.localizedDescription)")
            return nil
        }
        return Video(name: session.name, truth: labels.map { Interval(start: $0.startTime, end: $0.endTime) },
                     evidence: processor.frameEvidence, duration: processor.lastVideoDurationSec,
                     clips: segments.map { Interval(start: $0.startTime, end: $0.endTime) })
    }

    /// The decision replayed from evidence with `config`'s padding and joining.
    static func replay(_ v: Video, config: ProcessorConfig) -> [Interval] {
        EvidenceReplayer.decidedRanges(evidence: v.evidence, duration: v.duration, config: config,
                                       minRallySec: 1.1653, padded: true)
    }

    static func report(_ videos: [Video], log: (String) -> Void) {
        var all = Tally()
        for v in videos {
            var t = Tally()
            t.add(clips: v.clips, truth: v.truth)
            all.add(clips: v.clips, truth: v.truth)
            log("  \(v.name): \(t.line)")
        }
        log("  ALL (\(videos.count) videos): \(all.line)")

        // Replayed: today's settings first (should match the pipeline), then variants.
        let base = ProcessorConfig()
        var variants: [(String, ProcessorConfig)] = [("today: preroll \(base.preroll)s, postroll \(base.postroll)s, join gaps ≤ \(base.minGapToMerge)s", base)]
        for preroll in [0.5, 1.0, 2.0] {
            for join in [0.0, 0.5, 1.35] {
                for postroll in [0.5, 1.0] {
                    var c = base
                    c.preroll = preroll; c.minGapToMerge = join; c.postroll = postroll
                    variants.append(("preroll \(preroll)s, postroll \(postroll)s, join gaps ≤ \(join)s", c))
                }
            }
        }
        log("\n  Replayed decisions (same detections), pooled over the videos:")
        var rows: [(String, Tally)] = []
        for (label, config) in variants {
            var t = Tally()
            for v in videos { t.add(clips: replay(v, config: config), truth: v.truth) }
            rows.append((label, t))
        }
        log("    " + rows[0].0 + " → " + rows[0].1.line)
        for (label, t) in rows.dropFirst().sorted(by: { ($0.1.found - $0.1.merged - $0.1.falseClips) > ($1.1.found - $1.1.merged - $1.1.falseClips) }) {
            log("    " + label + " → " + t.line)
        }
    }
}
