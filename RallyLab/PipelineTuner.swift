//
//  PipelineTuner.swift
//  RallyLab
//
//  Finds the pipeline settings that cut the validation videos closest to
//  their marked rallies. Two levels:
//   · detection settings (the multi-frame model's threshold, the ballistics
//     gate) need the video run again — each one tried is a pass over the
//     videos, cached on disk so a pass is never run twice;
//   · rally settings (timing, joining, sky ball, above-net, the rally-score
//     gate) replay from a pass's recorded evidence in milliseconds, so for
//     every detection setting tried, thousands of them are searched.
//  Detection settings move one at a time, one step up or down, kept when
//  the best rally settings on them score better (rounds of that).
//
//  The score is what a user gets: the padded clips against the marked
//  rallies. Missing a rally costs more than dead time — a second of rally
//  lost costs as much as `deadTimeCost`⁻¹ seconds of clip with no rally in
//  it (false clips are all dead time). Padding is the app's choice, not
//  searched.
//
//  The videos are split (pipeline_tuning/validation.json): settings are
//  searched on "tune" only, and "holdout" says whether they're better on
//  footage they weren't chosen on. Only videos with every rally marked
//  count. Nothing is applied: the report says what to change.
//
//  Headless: RallyLab --project <name> --tune-pipeline [--replay-only] [--rounds n]
//

import CryptoKit
import Foundation

enum PipelineTuner {

    /// Seconds of dead clip worth one second of rally (see the header).
    static let deadTimeCost = 0.25
    /// A detection step is kept only when it beats the best by this much.
    static let minGain = 0.003
    /// A rally setting goes back to today's value when the result loses less than this without it.
    static let pruneTolerance = 0.001

    // MARK: - Settings

    /// What's searched: the processor's config and the decider's shortest
    /// rally, which isn't part of it.
    struct Settings {
        var config: ProcessorConfig
        var minRallySec = 1.1653
    }

    /// One searched setting, read and written through `Settings`.
    struct Knob {
        let name: String
        let get: (Settings) -> Double
        let set: (inout Settings, Double) -> Void
        /// Rally knobs: searched between these. Detection knobs: the values
        /// stepped through, in order.
        let values: [Double]
        var isInt = false, isBool = false

        init(_ name: String, _ get: @escaping (Settings) -> Double, _ set: @escaping (inout Settings, Double) -> Void,
             _ values: [Double], isInt: Bool = false, isBool: Bool = false) {
            self.name = name
            self.get = get
            self.set = set
            self.values = values
            self.isInt = isInt
            self.isBool = isBool
        }
    }

    /// Replayed from evidence. Ranges are the inspector's sliders.
    static let rallyKnobs: [Knob] = [
        Knob("startBuffer", { $0.config.startBuffer }, { $0.config.startBuffer = $1 }, [0, 1.5]),
        Knob("endTimeout", { $0.config.endTimeout }, { $0.config.endTimeout = $1 }, [0.3, 3]),
        Knob("projDropGracePeriod", { Double($0.config.projDropGracePeriod) }, { $0.config.projDropGracePeriod = Int($1.rounded()) }, [0, 8], isInt: true),
        Knob("minRallySec", { $0.minRallySec }, { $0.minRallySec = $1 }, [0.5, 6]),
        Knob("minGapToMerge", { $0.config.minGapToMerge }, { $0.config.minGapToMerge = $1 }, [0, 2]),
        Knob("minSegmentLength", { $0.config.minSegmentLength }, { $0.config.minSegmentLength = $1 }, [0, 4]),
        Knob("skyBallTimeout", { $0.config.skyBallTimeout }, { $0.config.skyBallTimeout = $1 }, [0.8, 5]),
        Knob("skyBallTopThreshold", { Double($0.config.skyBallTopThreshold) }, { $0.config.skyBallTopThreshold = CGFloat($1) }, [0.5, 0.95]),
        Knob("enableAboveNetRequirement", { $0.config.enableAboveNetRequirement ? 1 : 0 }, { $0.config.enableAboveNetRequirement = $1 >= 0.5 }, [0, 1], isBool: true),
        Knob("aboveNetMarginY", { Double($0.config.aboveNetMarginY) }, { $0.config.aboveNetMarginY = CGFloat($1) }, [0, 0.2]),
        Knob("aboveNetArcProminence", { Double($0.config.aboveNetArcProminence) }, { $0.config.aboveNetArcProminence = CGFloat($1) }, [0.01, 0.15]),
        Knob("enableRallyScoreGate", { $0.config.enableRallyScoreGate ? 1 : 0 }, { $0.config.enableRallyScoreGate = $1 >= 0.5 }, [0, 1], isBool: true),
        Knob("rallyScoreMinConfidence", { $0.config.rallyScoreMinConfidence }, { $0.config.rallyScoreMinConfidence = $1 }, [0, 1]),
    ]

    /// Need the video run again. `heatmapThreshold`'s values are filled in
    /// around the model's own (see `detectionKnobs(modelThreshold:)`).
    static func detectionKnobs(modelThreshold: Double) -> [Knob] {
        let around = [-0.2, -0.15, -0.1, -0.05, 0, 0.05, 0.1, 0.15].map { ((modelThreshold + $0) * 100).rounded() / 100 }.filter { $0 > 0.05 && $0 < 0.95 }
        return [
            Knob("heatmapThreshold", { $0.config.heatmapThreshold ?? modelThreshold }, { $0.config.heatmapThreshold = $1 }, around),
            Knob("minGravitySignature", { $0.config.minGravitySignature }, { $0.config.minGravitySignature = $1 }, [0.1, 0.2, 0.3, 0.4, 0.5]),
            Knob("parabolaMinR2", { $0.config.parabolaMinR2 }, { $0.config.parabolaMinR2 = $1 }, [0.7, 0.75, 0.8, 0.85, 0.9]),
            Knob("projectileWindowSec", { $0.config.projectileWindowSec }, { $0.config.projectileWindowSec = $1 }, [0.5, 0.6, 0.7452, 0.9, 1.05]),
            Knob("minProjectileSpanY", { Double($0.config.minProjectileSpanY) }, { $0.config.minProjectileSpanY = CGFloat($1) }, [0.02, 0.03, 0.04, 0.06, 0.08]),
            Knob("minCurvatureMagnitude", { Double($0.config.minCurvatureMagnitude) }, { $0.config.minCurvatureMagnitude = CGFloat($1) }, [0.002, 0.003, 0.004, 0.006, 0.008]),
        ]
    }

    // MARK: - Videos

    struct ValidationSet: Codable {
        var tune: [String]
        var holdout: [String]
        /// Recordings reserved as the independent final test (D-002): never
        /// packaged, scored or tuned on until promotion. Absent in older files.
        var finalTest: [String]
        /// Provisional final-test candidates (D-015 §2): protected exactly like
        /// `finalTest` while their provenance is verified, but not yet the
        /// final test. Promotion moves a name from here to `finalTest`.
        var finalTestCandidates: [String]
        /// Model-lineage holdout (D-017): recordings with recorded historical exposure that are
        /// withheld from every training, tuning, selection and development-time scoring use from
        /// the cut-over on, so a model lineage started after the cut can be evaluated on them.
        /// Protected exactly like `finalTest`; never the independent final test.
        var lineageHoldout: [String]

        init(tune: [String], holdout: [String], finalTest: [String] = [], finalTestCandidates: [String] = [], lineageHoldout: [String] = []) {
            self.tune = tune
            self.holdout = holdout
            self.finalTest = finalTest
            self.finalTestCandidates = finalTestCandidates
            self.lineageHoldout = lineageHoldout
        }

        private enum CodingKeys: String, CodingKey { case tune, holdout, finalTest, finalTestCandidates, lineageHoldout }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tune = try c.decode([String].self, forKey: .tune)
            holdout = try c.decode([String].self, forKey: .holdout)
            finalTest = try c.decodeIfPresent([String].self, forKey: .finalTest) ?? []
            finalTestCandidates = try c.decodeIfPresent([String].self, forKey: .finalTestCandidates) ?? []
            lineageHoldout = try c.decodeIfPresent([String].self, forKey: .lineageHoldout) ?? []
        }

        /// Every reserved name as listed (final test, provisional candidates, lineage holdout).
        var reservedAsListed: Set<String> { Set(finalTest).union(finalTestCandidates).union(lineageHoldout) }

        enum ReservationError: LocalizedError {
            case unreadable(URL)
            var errorDescription: String? {
                switch self {
                case .unreadable(let file):
                    return "\(file.path) exists but can't be read, so the final-test reservations are unknown. Fix the file before packaging, scoring, tuning or pre-tracking."
                }
            }
        }

        static func file(in datasetRoot: URL) -> URL { datasetRoot.appendingPathComponent("pipeline_tuning/validation.json") }

        /// The file as written, nil when there is none (a project from before
        /// tuning). A file that exists but won't decode throws: the reserved
        /// set is then unknown, and callers must not treat that as "none".
        static func loadStrict(from datasetRoot: URL) throws -> ValidationSet? {
            let file = file(in: datasetRoot)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            guard let data = try? Data(contentsOf: file),
                  let set = try? JSONDecoder().decode(ValidationSet.self, from: data) else { throw ReservationError.unreadable(file) }
            return set
        }

        /// Sessions that must stay out of every package, score run, tuning
        /// and pre-tracking (D-002): the listed names and their aliases (same
        /// file or confirmed identity under another session name). Fails
        /// closed: unreadable file → throws.
        static func finalTestNames(in datasetRoot: URL) throws -> Set<String> {
            try ReservedVideos.reservedNames(in: datasetRoot)
        }

        static func load(from datasetRoot: URL) -> ValidationSet? {
            (try? Data(contentsOf: datasetRoot.appendingPathComponent("pipeline_tuning/validation.json")))
                .flatMap { try? JSONDecoder().decode(ValidationSet.self, from: $0) }
        }
    }

    struct Video {
        let session: VideoSession
        let truth: [Interval]
        var surface: String { String(session.name.prefix(3)) }
    }

    /// A video run with one detection setting: what the replay needs.
    struct Pass {
        let video: Video
        let evidence: [VideoProcessor.FrameEvidence]
        let duration: Double
        /// The clips the run itself cut, to check the replay matches it.
        let clips: [Interval]
    }

    // MARK: - Score

    struct Score {
        var rallies = 0, missed = 0, cutShort = 0, falseClips = 0
        var covered = 0.0, rallyTime = 0.0, deadTime = 0.0

        /// Share of rally time inside clips, less the dead time's cost.
        var value: Double {
            guard rallies > 0, rallyTime > 0 else { return 0 }
            return covered / rallyTime - PipelineTuner.deadTimeCost * deadTime / rallyTime
        }

        mutating func add(clips: [Interval], truth: [Interval]) {
            let merged = Self.union(clips)
            for t in truth {
                let length = max(0, t.end - t.start)
                guard length > 0 else { continue }
                let inside = merged.reduce(0) { $0 + RallyCutScore.overlap($1, t) }
                rallies += 1
                rallyTime += length
                covered += inside
                if inside < 0.5 * length { missed += 1 } else if inside < 0.95 * length { cutShort += 1 }
            }
            let truthUnion = Self.union(truth)
            for c in merged {
                deadTime += (c.end - c.start) - truthUnion.reduce(0) { $0 + RallyCutScore.overlap(c, $1) }
            }
            falseClips += clips.filter { c in !truth.contains { RallyCutScore.overlap(c, $0) > 0 } }.count
        }

        static func + (a: Score, b: Score) -> Score {
            Score(rallies: a.rallies + b.rallies, missed: a.missed + b.missed, cutShort: a.cutShort + b.cutShort,
                  falseClips: a.falseClips + b.falseClips, covered: a.covered + b.covered,
                  rallyTime: a.rallyTime + b.rallyTime, deadTime: a.deadTime + b.deadTime)
        }

        var line: String {
            guard rallyTime > 0 else { return "no marked rallies" }
            return String(format: "score %.3f · %d rallies: %d missed, %d cut short · %.0f%% of rally time kept · %.1f s dead time a rally · %d false clips",
                          value, rallies, missed, cutShort, 100 * covered / rallyTime, deadTime / Double(max(rallies, 1)), falseClips)
        }

        private static func union(_ intervals: [Interval]) -> [Interval] {
            var out: [Interval] = []
            for i in intervals.sorted(by: { $0.start < $1.start }) {
                if let last = out.last, i.start <= last.end {
                    out[out.count - 1] = Interval(start: last.start, end: max(last.end, i.end))
                } else {
                    out.append(i)
                }
            }
            return out
        }
    }

    static func clips(_ pass: Pass, _ settings: Settings) -> [Interval] {
        EvidenceReplayer.decidedRanges(evidence: pass.evidence, duration: pass.duration, config: settings.config,
                                       minRallySec: settings.minRallySec, padded: true)
    }

    static func score(_ passes: [Pass], _ settings: Settings) -> Score {
        passes.reduce(Score()) { total, pass in
            var s = Score()
            s.add(clips: clips(pass, settings), truth: pass.video.truth)
            return total + s
        }
    }

    // MARK: - Rally search

    /// The best rally settings on these passes, starting from `start`:
    /// random tries over every knob's range, then small moves around the
    /// best few. Deterministic (fixed seed), so a rerun finds the same.
    static func searchRally(_ passes: [Pass], from start: Settings, tries: Int = 1500, refine: Int = 500) async -> (Settings, Score) {
        var rng = SeededGenerator(seed: 0xB5C)
        func random(_ base: Settings) -> Settings {
            var s = base
            for k in rallyKnobs {
                var v = Double.random(in: k.values[0]...k.values[1], using: &rng)
                if k.isBool { v = v >= 0.5 ? 1 : 0 } else if k.isInt { v = v.rounded() }
                k.set(&s, v)
            }
            return s
        }
        func nudge(_ base: Settings) -> Settings {
            var s = base
            for k in rallyKnobs where Double.random(in: 0...1, using: &rng) < 0.4 {
                let span = k.values[1] - k.values[0]
                var v = k.isBool ? (k.get(s) >= 0.5 ? 0 : 1)
                    : min(k.values[1], max(k.values[0], k.get(s) + Double.random(in: -0.1...0.1, using: &rng) * span))
                if k.isInt { v = v.rounded() }
                k.set(&s, v)
            }
            return s
        }
        func evaluate(_ candidates: [Settings]) async -> [(Settings, Score)] {
            await withTaskGroup(of: (Int, Score).self) { group in
                for (i, c) in candidates.enumerated() { group.addTask { (i, score(passes, c)) } }
                var out = [(Settings, Score)?](repeating: nil, count: candidates.count)
                for await (i, s) in group { out[i] = (candidates[i], s) }
                return out.compactMap { $0 }
            }
        }
        var ranked = await evaluate([start] + (0..<tries).map { _ in random(start) })
        ranked.sort { $0.1.value > $1.1.value }
        let parents = ranked.prefix(10).map(\.0)
        let children = (0..<refine).map { nudge(parents[$0 % parents.count]) }
        ranked += await evaluate(children)
        // Put back every knob the result doesn't need: random search moves
        // knobs that make no difference here, and each needless change is a
        // guess about footage the set doesn't have.
        let top = ranked.max { $0.1.value < $1.1.value }!
        var (best, bestScore) = top
        var reverted = true
        while reverted {
            reverted = false
            for k in rallyKnobs where abs(k.get(best) - k.get(start)) > 1e-9 {
                var s = best
                k.set(&s, k.get(start))
                let candidate = score(passes, s)
                if candidate.value > top.1.value - pruneTolerance { (best, bestScore, reverted) = (s, candidate, true) }
            }
        }
        return (best, bestScore)
    }

    // MARK: - Passes (cached)

    /// The detection settings a pass depends on, as a short key.
    static func detectionKey(_ settings: Settings, knobs: [Knob]) -> String {
        let text = knobs.map { "\($0.name)=\($0.get(settings))" }.joined(separator: ";")
            + ";model=\(settings.config.heatmapModel?.lastPathComponent ?? "-");only=\(settings.config.heatmapOnly)"
            + ";yolo=\(settings.config.ballModel.rawValue);rot=\(settings.config.applyVideoRotation)"
        return SHA256.hash(data: Data(text.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    static func pass(_ video: Video, _ settings: Settings, key: String, cache: URL) async -> Pass? {
        let file = cache.appendingPathComponent("\(video.session.name)__\(key).evidence")
        if let stored = EvidenceFile.load(file) {
            return Pass(video: video, evidence: stored.frames, duration: stored.duration, clips: stored.clips)
        }
        let processor = VideoProcessor()
        processor.config = settings.config.withCamera(of: video.session)
        processor.collectFrameEvidence = true
        var segments: [RallySegment] = []
        do {
            segments = try await processor.processVideo(URL(fileURLWithPath: video.session.sourcePath), videoId: UUID()).rallySegments
        } catch ProcessingError.noRalliesDetected {
            segments = []
        } catch {
            return nil
        }
        let clips = segments.map { Interval(start: $0.startTime, end: $0.endTime) }
        let pass = Pass(video: video, evidence: processor.frameEvidence, duration: processor.lastVideoDurationSec, clips: clips)
        EvidenceFile.save(pass, to: file)
        return pass
    }

    /// The named videos with every rally marked, with their marks.
    @MainActor
    static func videos(_ names: [String], sampler: SamplerModel, log: (String) -> Void) -> [Video] {
        names.compactMap { name in
            guard let session = sampler.sessions.first(where: { $0.name == name }) else { log("  ⚠️ \(name): not in the project"); return nil }
            guard session.ralliesMarked == true,
                  let labels = try? JSONDecoder().decode([LabeledRally].self, from: Data(contentsOf: RallyMarkModel.labelsURL(for: URL(fileURLWithPath: session.sourcePath))))
            else { log("  · \(name): not every rally marked yet — left out"); return nil }
            return Video(session: session, truth: labels.map { Interval(start: $0.startTime, end: $0.endTime) })
        }
    }

    // MARK: - Run

    @MainActor
    static func run(sampler: SamplerModel, replayOnly: Bool, rounds: Int, log: @escaping (String) -> Void) async -> Bool {
        let dir = sampler.datasetRoot.appendingPathComponent("pipeline_tuning", isDirectory: true)
        let cache = dir.appendingPathComponent("evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        guard let set = ValidationSet.load(from: sampler.datasetRoot) else {
            log("❌ No \(dir.lastPathComponent)/validation.json (lists the tune and holdout videos).")
            return false
        }
        let reserved: Set<String>
        do { reserved = try ReservedVideos.reservedNames(in: sampler.datasetRoot) } catch {
            log("❌ \(error.localizedDescription)")
            return false
        }
        let clash = (set.tune + set.holdout).filter { reserved.contains($0) }   // listed names and their aliases
        guard clash.isEmpty else {
            log("❌ Reserved final-test videos are also listed as tune/holdout: \(clash.joined(separator: ", ")). Fix validation.json (D-002).")
            return false
        }
        let tune = videos(set.tune, sampler: sampler, log: log), holdout = videos(set.holdout, sampler: sampler, log: log)
        log("Tune: \(tune.count) of \(set.tune.count) videos · holdout: \(holdout.count) of \(set.holdout.count)")
        guard tune.count >= 2 else { log("❌ Mark every rally in at least 2 tune videos first."); return false }
        // Logged before the first pass, so a run that is quit or crashes is still on record (D-002).
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let reportName = "report-\(stamp).md"
        do {
            try ExposureLog.record(videos: Set(tune.map(\.session.name)), kind: .pipelineTune, ref: reportName, note: "settings searched on", in: sampler.datasetRoot)
            try ExposureLog.record(videos: Set(holdout.map(\.session.name)), kind: .pipelineHoldout, ref: reportName, note: "reported, not searched on", in: sampler.datasetRoot)
        } catch {
            log("❌ \(error.localizedDescription)")
            return false
        }

        var base = Settings(config: ProcessorConfig())
        let modelThreshold = base.config.heatmapModel.flatMap { HeatmapBallDetector(modelURL: $0) }.map { Double($0.threshold) } ?? 0.5
        let detection = detectionKnobs(modelThreshold: modelThreshold)
        log("Ball finder: \(base.config.heatmapOnly ? "multi-frame only" : "YOLO + multi-frame") (\(base.config.heatmapModel?.lastPathComponent ?? "none"), threshold \(modelThreshold))")

        // One detection setting: run (or load) every tune video, then the
        // best rally settings on them.
        var passCount = 0
        func evaluate(_ settings: Settings, label: String) async -> (passes: [Pass], best: Settings, score: Score)? {
            let key = detectionKey(settings, knobs: detection)
            var passes: [Pass] = []
            for v in tune {
                let started = Date()
                guard let p = await pass(v, settings, key: key, cache: cache) else { log("  ⚠️ \(v.session.name): couldn't process"); continue }
                let took = Date().timeIntervalSince(started)
                if took > 2 { passCount += 1; log(String(format: "    ran %@ in %.0f s", v.session.name, took)) }
                passes.append(p)
            }
            guard !passes.isEmpty else { return nil }
            let (best, score) = await searchRally(passes, from: settings)
            log("  \(label): \(score.line)")
            return (passes, best, score)
        }

        log("Current settings…")
        guard let current = await evaluate(base, label: "current detection, best rally settings") else { return false }
        // The replay must cut what the pipeline cut, or the search tunes something else
        // (within a few frames: stored times are rounded).
        let mismatched = current.passes.filter { p in
            let replayed = clips(p, base)
            return replayed.count != p.clips.count || zip(replayed, p.clips).contains { abs($0.start - $1.start) > 0.2 || abs($0.end - $1.end) > 0.2 }
        }
        for p in mismatched {
            func list(_ c: [Interval]) -> String { c.map { String(format: "%.1f–%.1f", $0.start, $0.end) }.joined(separator: " ") }
            log("  ⚠️ replay doesn't match the pipeline on \(p.video.session.name) — rally-setting results there are approximate")
            log("     pipeline: \(list(p.clips))")
            log("     replay:   \(list(clips(p, base)))")
        }
        let currentScore = score(current.passes, base)
        log("  current settings as they are: \(currentScore.line)")

        var best = current
        if !replayOnly {
            for round in 1...max(1, rounds) {
                log("Round \(round) of detection settings…")
                var improved = false
                for knob in detection {
                    let now = knob.get(best.best)
                    guard let at = knob.values.firstIndex(where: { abs($0 - now) < 1e-6 }) ?? knob.values.indices.min(by: { abs(knob.values[$0] - now) < abs(knob.values[$1] - now) }) else { continue }
                    for step in [at - 1, at + 1] where knob.values.indices.contains(step) {
                        var trial = best.best
                        knob.set(&trial, knob.values[step])
                        guard let result = await evaluate(trial, label: "\(knob.name) \(now) → \(knob.values[step])") else { continue }
                        if result.score.value > best.score.value + minGain {
                            best = result
                            improved = true
                            log("    ✓ kept")
                            break
                        }
                    }
                }
                if !improved { log("  No detection change helped — done."); break }
            }
        }

        // Holdout: the settings found, against today's, on videos they weren't chosen on.
        log("Holdout…")
        var holdoutNow = Score(), holdoutBest = Score()
        var bySurface: [String: (now: Score, best: Score)] = [:]
        let keyNow = detectionKey(base, knobs: detection), keyBest = detectionKey(best.best, knobs: detection)
        for v in holdout {
            guard let pNow = await pass(v, base, key: keyNow, cache: cache),
                  let pBest = await pass(v, best.best, key: keyBest, cache: cache) else { log("  ⚠️ \(v.session.name): couldn't process"); continue }
            let a = score([pNow], base), b = score([pBest], best.best)
            holdoutNow = holdoutNow + a
            holdoutBest = holdoutBest + b
            let s = bySurface[v.surface] ?? (Score(), Score())
            bySurface[v.surface] = (s.now + a, s.best + b)
        }

        var report: [String] = ["# Pipeline tuning — \(sampler.datasetRoot.lastPathComponent), \(Date().formatted(date: .abbreviated, time: .shortened))", ""]
        report.append("Score = share of rally time inside clips − \(deadTimeCost) × dead time ÷ rally time (padded clips, as users get them).")
        report.append("Tune videos: \(tune.map(\.session.name).joined(separator: ", "))")
        report.append("Holdout videos: \(holdout.map(\.session.name).joined(separator: ", "))")
        report.append("Detection passes run: \(passCount)")
        report.append("")
        report.append("## Tune")
        report.append("- today's settings: \(currentScore.line)")
        report.append("- found: \(best.score.line)")
        report.append("")
        report.append("## Holdout (not searched on)")
        report.append("- today's settings: \(holdoutNow.line)")
        report.append("- found: \(holdoutBest.line)")
        for (surface, s) in bySurface.sorted(by: { $0.key < $1.key }) {
            report.append("  - \(surface): today \(String(format: "%.3f", s.now.value)) → found \(String(format: "%.3f", s.best.value)) (\(s.best.rallies) rallies)")
        }
        report.append("")
        report.append("## Changes (nothing applied)")
        var changes = 0
        for k in detection + rallyKnobs {
            let a = k.get(base), b = k.get(best.best)
            guard abs(a - b) > 1e-6 else { continue }
            changes += 1
            report.append(String(format: "- %@: %@ → %@", k.name, format(a, k), format(b, k)))
        }
        if changes == 0 { report.append("- none: today's settings are already the best found") }
        for line in report { log(line) }
        let file = dir.appendingPathComponent(reportName)
        try? report.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        log("Report: \(file.path)")
        return true
    }

    private static func format(_ v: Double, _ k: Knob) -> String {
        k.isBool ? (v >= 0.5 ? "on" : "off") : k.isInt ? String(Int(v)) : String(format: "%.4g", v)
    }
}

// MARK: - Evidence on disk

/// A pass's evidence, kept to what the replay reads (the selected track
/// only, the net once), compressed. Regenerable: delete the folder to rerun.
private struct EvidenceFile: Codable {
    struct Frame: Codable {
        let t: Double
        let ball: Bool, proj: Bool
        let track: [Double]?        // x, y
        let dets: [[Double]]        // x, y, w, h, confidence, off-court (0/1)
        let sel: [Double]?          // selected candidate: x, y, ball size
    }
    let duration: Double
    let clips: [[Double]]
    let net: [Double]?              // x, y, w, h, confidence
    let netFrom: Double?
    let frames: [Frame]

    static func save(_ pass: PipelineTuner.Pass, to url: URL) {
        let firstNet = pass.evidence.first { $0.detectedNet != nil }
        let file = EvidenceFile(
            duration: pass.duration,
            clips: pass.clips.map { [$0.start, $0.end] },
            net: firstNet?.detectedNet.map { [$0.box.minX, $0.box.minY, $0.box.width, $0.box.height, $0.confidence].map { Double($0) } },
            netFrom: firstNet?.time,
            frames: pass.evidence.map { e in
                let sel = e.candidates.first { $0.isSelected }
                return Frame(t: e.time, ball: e.hasBall, proj: e.isProjectile,
                             track: e.trackPoint.map { [Double($0.x), Double($0.y)] },
                             dets: e.detections.map { [$0.bbox.minX, $0.bbox.minY, $0.bbox.width, $0.bbox.height].map { Double($0) } + [Double($0.confidence), $0.isOffCourt ? 1 : 0] },
                             sel: sel.map { [Double($0.point.x), Double($0.point.y), Double($0.ballSize)] })
            })
        guard let data = try? JSONEncoder().encode(file),
              let packed = try? (data as NSData).compressed(using: .lzfse) else { return }
        try? (packed as Data).write(to: url, options: .atomic)
    }

    static func load(_ url: URL) -> (frames: [VideoProcessor.FrameEvidence], duration: Double, clips: [Interval])? {
        guard let packed = try? Data(contentsOf: url),
              let data = try? (packed as NSData).decompressed(using: .lzfse),
              let file = try? JSONDecoder().decode(EvidenceFile.self, from: data as Data) else { return nil }
        let net = file.net.map { DetectedNet(box: CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]), confidence: $0[4]) }
        let frames = file.frames.map { f in
            VideoProcessor.FrameEvidence(
                time: f.t, hasBall: f.ball, isProjectile: f.proj,
                detections: f.dets.map { VideoProcessor.BallDetection(bbox: CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]),
                                                                       confidence: Float($0[4]), isOffCourt: $0[5] != 0) },
                trackPoint: f.track.map { CGPoint(x: $0[0], y: $0[1]) },
                rSquared: nil, gravitySignature: nil, movementType: nil, rejectionReason: nil,
                candidates: f.sel.map { s in
                    [VideoProcessor.TrackCandidate(id: UUID(), point: CGPoint(x: s[0], y: s[1]), score: 0, isProjectile: f.proj,
                                                   isSelected: true, isCourtExcluded: false, ballSize: CGFloat(s[2]), roiRadius: 0,
                                                   rSquared: nil, gravitySignature: nil, movementType: nil, rejectionReason: nil)]
                } ?? [],
                detectedNet: (file.netFrom.map { f.t >= $0 } ?? false) ? net : nil)
        }
        return (frames, file.duration, file.clips.map { Interval(start: $0[0], end: $0[1]) })
    }
}

/// SplitMix64: the same random tries every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
