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
        /// The rallies (kind rally, or none — a legacy mark), outside the cuts and the excluded spans (RallyTruth).
        let truth: [Interval]
        /// The missed serves and "not a rally" marks, outside the cuts: excluded spans. `clips` are their pieces
        /// outside them too — one wholly inside is unscored, neither a hit nor a false clip (the scoring contract).
        var excluded: [Interval] = []
        let evidence: [VideoProcessor.FrameEvidence]
        let duration: Double
        let clips: [Interval]
        /// Each clip's serve, for the debug video.
        var serves: [ServeDetector.Serve] = []
        /// The recording's cut ranges (not footage; D-030): `truth` and `clips` are their
        /// pieces outside them, and a replay is masked the same way.
        var cuts: [CutRange] = []
    }

    struct Tally {
        var truth = 0, clips = 0, found = 0, falseClips = 0, missed = 0, merged = 0, split = 0
        /// Clips wholly inside a missed serve or a "not a rally" mark: unscored, neither hit nor false clip.
        var unscored = 0
        var startErrors: [Double] = [], endErrors: [Double] = []

        /// `clips` and `truth` as the video holds them (outside the cuts); `excluded` the missed-serve and other
        /// spans — each clip is scored on its pieces outside those, as one clip, and one with nothing outside is
        /// unscored (the scoring contract §2; a cut, unlike an excluded span, splits a clip).
        mutating func add(clips: [Interval], truth: [Interval], excluded: [Interval] = [], iou: Double = 0.3) {
            let (scored, unscoredHere) = clips.scorable(excluding: excluded)
            unscored += unscoredHere
            self.truth += truth.count
            self.clips += scored.count
            let r = MaskedMatch(scored, truth: truth, iou: iou)
            found += r.matches.count
            falseClips += r.unmatchedClips.filter { c in !truth.contains { c.overlap($0) > 0 } }.count
            missed += r.unmatchedTruth.filter { t in !scored.contains { $0.overlap(t) > 0 } }.count
            merged += scored.filter { c in truth.filter { c.overlap($0) > 0.5 * ($0.end - $0.start) }.count >= 2 }.count
            split += truth.filter { t in scored.filter { $0.overlap(t) > 0.5 }.count >= 2 }.count
            for m in r.matches {
                startErrors.append(m.clip.span.start - m.truth.start)
                endErrors.append(m.clip.span.end - m.truth.end)
            }
        }

        var line: String {
            func med(_ v: [Double]) -> String {
                guard !v.isEmpty else { return "—" }
                let s = v.sorted()
                return String(format: "%+.1fs", s[s.count / 2])
            }
            let within = zip(startErrors, endErrors).filter { abs($0) <= 1 && abs($1) <= 1 }.count
            return "\(found)/\(truth) rallies found · \(missed) missed · \(falseClips) false clips" + (unscored > 0 ? " · \(unscored) unscored (inside a missed serve)" : "") + " · \(merged) merged clips · \(split) split"
                + " · start \(med(startErrors)) end \(med(endErrors)) (median) · both ends within 1 s: \(within)/\(max(found, 0))"
        }
    }

    static func overlap(_ a: Interval, _ b: Interval) -> Double { max(0, min(a.end, b.end) - max(a.start, b.start)) }

    /// nil without readable marks, and for a recording whose pass is not complete: what lies outside its
    /// marks is unknown, not dead, so neither false clips nor dead time can be counted (RallyTruth). The truth
    /// is the rallies; the missed serves and other marks are excluded spans the replayed clips are masked with.
    @MainActor
    static func process(_ session: VideoSession, config: ProcessorConfig = ProcessorConfig()) async -> Video? {
        let video = URL(fileURLWithPath: session.sourcePath)
        if let why = RallyTruth.incompleteReason(session) { print("⏭ \(session.name): \(why)"); return nil }
        guard let truth = try? RallyTruth.of(session) else { return nil }
        let processor = VideoProcessor()
        processor.config = config
        processor.collectFrameEvidence = true
        var segments: [RallySegment] = []
        do {
            segments = try await processor.analyzeVideo(video).rallySegments
        } catch ProcessingError.noRalliesDetected {
            segments = []
        } catch {
            print("❌ \(session.name): \(error.localizedDescription)")
            return nil
        }
        let cuts = truth.cuts
        return Video(name: session.name, truth: truth.positiveIntervals, excluded: truth.excludedIntervals,
                     evidence: processor.frameEvidence, duration: processor.lastVideoDurationSec,
                     clips: segments.map { Interval(start: $0.startTime, end: $0.endTime) }.outside(cuts), serves: processor.serves,
                     cuts: cuts)
    }

    /// What the pipeline saw inside each marked rally: frames with a ball
    /// detected, detections dropped as off-court, frames the ballistics gate
    /// accepted as a projectile, and its most common reasons for rejecting.
    static func diagnose(_ v: Video, log: (String) -> Void) {
        for (n, r) in v.truth.enumerated() {
            let frames = v.evidence.filter { $0.time >= r.start && $0.time <= r.end }
            guard !frames.isEmpty else { log("    rally \(n + 1) \(clock(r.start))–\(clock(r.end)): no processed frames"); continue }
            let withBall = frames.filter { e in e.detections.contains { !$0.isOffCourt } }.count
            let onlyOffCourt = frames.filter { e in !e.detections.isEmpty && e.detections.allSatisfy(\.isOffCourt) }.count
            let projectile = frames.filter(\.isProjectile).count
            var reasons: [String: Int] = [:]
            for e in frames { if let why = e.rejectionReason { reasons[why, default: 0] += 1 } }
            let top = reasons.sorted { $0.value > $1.value }.prefix(2).map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            let found = v.clips.contains { overlap($0, r) > 0.3 * (r.end - r.start) }
            func pct(_ k: Int) -> String { String(format: "%.0f%%", 100 * Double(k) / Double(frames.count)) }
            log("    rally \(n + 1) \(clock(r.start))–\(clock(r.end)) \(found ? "FOUND" : "MISSED"): ball on \(pct(withBall)) of \(frames.count) frames"
                + " · only off-court \(pct(onlyOffCourt)) · projectile \(pct(projectile))" + (top.isEmpty ? "" : " · rejected: \(top)"))
        }
        if let net = v.evidence.last(where: { $0.detectedNet != nil })?.detectedNet {
            log(String(format: "    net box x %.2f–%.2f y %.2f–%.2f (conf %.2f)", net.box.minX, net.box.maxX, net.box.minY, net.box.maxY, net.confidence))
        } else {
            log("    no net found")
        }
    }

    private static func clock(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }

    /// The decision replayed from evidence with `config`'s padding and joining.
    static func replay(_ v: Video, config: ProcessorConfig) -> [Interval] {
        EvidenceReplayer.decidedRanges(evidence: v.evidence, duration: v.duration, config: config,
                                       minRallySec: 1.1653, padded: true).outside(v.cuts)
    }

    static func report(_ videos: [Video], log: (String) -> Void) {
        var all = Tally()
        for v in videos {
            var t = Tally()
            t.add(clips: v.clips, truth: v.truth, excluded: v.excluded)
            all.add(clips: v.clips, truth: v.truth, excluded: v.excluded)
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
            for v in videos { t.add(clips: replay(v, config: config), truth: v.truth, excluded: v.excluded) }
            rows.append((label, t))
        }
        log("    " + rows[0].0 + " → " + rows[0].1.line)
        for (label, t) in rows.dropFirst().sorted(by: { ($0.1.found - $0.1.merged - $0.1.falseClips) > ($1.1.found - $1.1.merged - $1.1.falseClips) }) {
            log("    " + label + " → " + t.line)
        }
    }
}
