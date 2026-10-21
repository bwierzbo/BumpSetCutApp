//
//  ServeReport.swift
//  RallyLab
//
//  How well the serve is found (ServeDetector), against the validation
//  videos' marked rallies (pipeline_tuning/validation.json, the tuner's
//  cached evidence): for each marked rally, whether the clip the pipeline
//  cut around it has a serve, and how far that serve starts from the mark.
//  Then what starting each clip at its serve (less a lead-in) would score,
//  by the tuner's measure. Nothing is applied.
//
//  Headless: RallyLab --project <name> --serve-report [--verbose]
//

import Foundation

enum ServeReport {

    /// Lead-ins tried before the serve, seconds.
    static let leadIns = [0.5, 1.0, 1.5, 2.0]

    @MainActor
    static func run(sampler: SamplerModel, detector: ServeDetector = ServeDetector(), verbose: Bool,
                    log: @escaping (String) -> Void) async -> Bool {
        let cache = sampler.datasetRoot.appendingPathComponent("pipeline_tuning/evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let set: PipelineTuner.ValidationSet
        do {
            guard let loaded = try PipelineTuner.ValidationSet.loadStrict(from: sampler.datasetRoot) else {
                log("❌ No pipeline_tuning/validation.json.")
                return false
            }
            set = loaded
        } catch {
            log("❌ \(error.localizedDescription)")
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
        let videos = PipelineTuner.videos(set.tune + set.holdout, sampler: sampler, log: log)
        let base = PipelineTuner.Settings(config: ProcessorConfig())
        let threshold = base.config.heatmapModel.flatMap { HeatmapBallDetector(modelURL: $0) }.map { Double($0.threshold) } ?? 0.5
        let key = PipelineTuner.detectionKey(base, knobs: PipelineTuner.detectionKnobs(modelThreshold: threshold))
        log("\(videos.count) videos with every rally marked")
        do { try ExposureLog.record(videos: Set(videos.map(\.session.name)), kind: .rallyScoring, ref: "--serve-report", note: nil, in: sampler.datasetRoot) } catch {
            log("❌ \(error.localizedDescription)")
            return false
        }

        var errors: [Double] = [], contactErrors: [Double] = []
        var rallies = 0, served = 0, tosses = 0, falseServes = 0
        var today = PipelineTuner.Score()
        var anchored = [PipelineTuner.Score](repeating: PipelineTuner.Score(), count: leadIns.count)
        for v in videos {
            guard let pass = await PipelineTuner.pass(v, base, key: key, cache: cache) else { log("  ⚠️ \(v.session.name): couldn't process"); continue }
            let frames = ServeDetector.Frame.from(pass.evidence)
            let clips = PipelineTuner.clips(pass, base)
            // Each decided rally's serve (the decision before padding and joining):
            // the one it started on, else the detector's search around its start.
            let decided = EvidenceReplayer.decidedRallies(evidence: pass.evidence, duration: pass.duration, config: base.config,
                                                          minRallySec: base.minRallySec, padded: false)
            let starts = decided.map(\.range.start)
            let serves = decided.compactMap { $0.serve ?? detector.serve(in: frames, rallyStart: $0.range.start) }
            today.add(clips: clips, truth: v.truth)
            // A clip starts at its first rally's serve, less the lead-in.
            for (n, lead) in leadIns.enumerated() {
                let moved = clips.map { c in
                    serves.first { $0.contact >= c.start && $0.contact <= c.end }.map { Interval(start: max(0, $0.start - lead), end: c.end) } ?? c
                }
                anchored[n].add(clips: moved, truth: v.truth)
            }
            if verbose { log("\(v.session.name):") }
            var matched = Set<Double>()
            for t in v.truth {
                rallies += 1
                guard let s = serves.filter({ abs($0.start - t.start) <= 3 }).min(by: { abs($0.start - t.start) < abs($1.start - t.start) }) else {
                    if verbose {
                        let nearest = starts.min { abs($0 - t.start) < abs($1 - t.start) }.map { String(format: "decided start %+.1f s away", $0 - t.start) } ?? "no decided start"
                        log(String(format: "  %6.1f  no serve within 3 s · ", t.start) + nearest)
                    }
                    continue
                }
                matched.insert(s.contact)
                served += 1
                errors.append(s.start - t.start)
                contactErrors.append(s.contact - t.start)
                if s.toss != nil { tosses += 1 }
                if verbose {
                    log(String(format: "  %6.1f  serve: toss %@ · contact %6.2f · end %6.2f (%@) · start %+.2f s from the mark",
                               t.start, s.toss.map { String(format: "%6.2f", $0) } ?? "  —   ", s.contact, s.end,
                               s.approaching ? "toward" : "away", s.start - t.start))
                }
            }
            let unmatched = serves.filter { !matched.contains($0.contact) }
            falseServes += unmatched.count
            if verbose, !unmatched.isEmpty {
                log("  serves away from any mark: " + unmatched.map { String(format: "%.1f", $0.contact) }.joined(separator: ", "))
            }
        }
        guard rallies > 0 else { log("❌ No marked rallies."); return false }
        func share(_ e: [Double], _ f: (Double) -> Bool) -> String { String(format: "%.0f%%", 100 * Double(e.filter(f).count) / Double(max(e.count, 1))) }
        func spread(_ name: String, _ e: [Double]) {
            guard !e.isEmpty else { return }
            let sorted = e.sorted()
            log(String(format: "%@ − marked start: median %+.2f s · within 0.5 s %@ · within 1 s %@ · more than 1 s early %@ · more than 1 s late %@",
                       name, sorted[sorted.count / 2], share(e) { abs($0) <= 0.5 }, share(e) { abs($0) <= 1 }, share(e) { $0 < -1 }, share(e) { $0 > 1 }))
        }
        log("")
        log("\(rallies) marked rallies · a serve found within 3 s of \(served) (\(Int((100 * Double(served) / Double(rallies)).rounded()))%) · \(falseServes) serves away from any mark")
        log("toss seen in \(tosses) of \(served)")
        spread("serve start (toss, else contact)", errors)
        spread("contact", contactErrors)
        log("clips as today:            \(today.line)")
        for (n, lead) in leadIns.enumerated() {
            log(String(format: "start at the serve − %.1f s: ", lead) + anchored[n].line)
        }
        return true
    }
}
