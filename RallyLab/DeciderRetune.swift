//
//  DeciderRetune.swift
//  RallyLab
//
//  A bounded retune of the rally decider's joining and padding for one ball
//  detector (owner, 2026-10-31 §2): the plan — the two models, the tune and
//  evaluation pools, the candidate grid, the objective — is a JSON file frozen
//  in the experiment record before anything runs. Every pool recording is
//  checked against the final-test reservation and the lineage-withheld
//  closure, must have every rally marked, and no recording group may sit in
//  both pools. The detector runs once per recording per model (the tuner's
//  evidence cache); every candidate is a replay of the decision from that
//  evidence. Settings are chosen on the tune pool only and the chosen settings
//  are then replayed on the evaluation pool — development evidence, not
//  independent validation: these recordings are in both models' training
//  packages and have been scored before.
//
//  Every marked rally lands in exactly one class against the delivered
//  (padded, joined) clips: preserved (matched one-to-one, ≥ the plan's share
//  of it inside the clips), clipped (matched, less of it inside), merged (a
//  clip covering more than half of it and of another rally), split (two or
//  more clips each covering more than half a second of it), partial (a clip
//  touches it, none matches), missed (no clip touches it). Clips that touch
//  no rally are false clips; clip time outside every rally is dead time. Raw
//  boundaries — each delivered clip's raw decided span, from the same replay
//  (a joined clip's is the union of what it joined) — are reported beside the
//  padded ones; a second replay with no padding would segment differently.
//
//  Headless: RallyLab --project <name> --retune-decider <plan.json> --out <dir> [--passes-only]
//

import CryptoKit
import Foundation

enum DeciderRetune {

    // MARK: - Plan

    struct Plan: Codable, Equatable {
        /// The experiment record's ID; part of the ledger ref.
        var id: String
        /// Multi-frame model names (the project's models/heatmap folder): the shipped baseline and the candidate.
        var baselineModel: String
        var candidateModel: String
        /// Settings are chosen on `tune` and then replayed on `eval`; the pools must not share a recording group.
        var tune: [String]
        var eval: [String]
        /// The candidate settings: every combination of the listed values, knobs not listed staying as committed.
        var grid: Grid
        var objective: Objective
        /// A rally is preserved when at least this share of it is inside the delivered clips.
        var preservedShare: Double
        /// The decider's shortest rally (not in ProcessorConfig; the pipeline's own value).
        var minRallySec: Double

        struct Grid: Codable, Equatable {
            var preroll: [Double]?
            var postroll: [Double]?
            var minGapToMerge: [Double]?
            var minSegmentLength: [Double]?
            var endTimeout: [Double]?
            var startBuffer: [Double]?
            var skyBallTimeout: [Double]?
        }

        /// Objective per rally: (preserved − mergedRallyCost × merged − falseClipCost × false clips) / rallies
        /// − deadTimeCost × dead time / rally time. Higher is better.
        struct Objective: Codable, Equatable {
            var mergedRallyCost: Double
            var falseClipCost: Double
            var deadTimeCost: Double
        }

        static func load(_ url: URL) throws -> Plan {
            try JSONDecoder().decode(Plan.self, from: Data(contentsOf: url))
        }
    }

    /// One candidate: the knobs it sets, by name, applied to a config.
    struct Candidate: Equatable, Codable {
        var values: [String: Double]

        func apply(to config: ProcessorConfig) -> ProcessorConfig {
            var c = config
            for (name, v) in values {
                switch name {
                case "preroll": c.preroll = v
                case "postroll": c.postroll = v
                case "minGapToMerge": c.minGapToMerge = v
                case "minSegmentLength": c.minSegmentLength = v
                case "endTimeout": c.endTimeout = v
                case "startBuffer": c.startBuffer = v
                case "skyBallTimeout": c.skyBallTimeout = v
                default: break
                }
            }
            return c
        }

        var label: String {
            values.keys.sorted().map { "\($0)=\(String(format: "%.4g", values[$0]!))" }.joined(separator: " ")
        }
    }

    /// Every combination of the grid's values, in a fixed order (first knob slowest).
    static func candidates(_ grid: Plan.Grid) -> [Candidate] {
        let axes: [(String, [Double])] = [
            ("preroll", grid.preroll ?? []), ("postroll", grid.postroll ?? []), ("minGapToMerge", grid.minGapToMerge ?? []),
            ("minSegmentLength", grid.minSegmentLength ?? []), ("endTimeout", grid.endTimeout ?? []),
            ("startBuffer", grid.startBuffer ?? []), ("skyBallTimeout", grid.skyBallTimeout ?? []),
        ].filter { !$0.1.isEmpty }
        var out: [Candidate] = [Candidate(values: [:])]
        for (name, values) in axes {
            out = out.flatMap { base in values.map { v in var c = base; c.values[name] = v; return c } }
        }
        return out
    }

    // MARK: - Accounting

    struct Account: Codable, Equatable {
        var rallies = 0, preserved = 0, clipped = 0, merged = 0, split = 0, partial = 0, missed = 0
        var clips = 0, falseClips = 0
        /// Marks closed with N (a serve nothing followed: into the net, long, wide): in the classes above like
        /// every mark, and counted here on their own — a one-second flight is under the decider's shortest rally
        /// and the shortest clip, so the pipeline misses most by design.
        var missedServeMarks = 0, missedServeMarksMissed = 0
        var rallyTime = 0.0, covered = 0.0, deadTime = 0.0
        /// Delivered clip − marked rally, over one-to-one matches (IoU ≥ 0.3).
        var startErrors: [Double] = [], endErrors: [Double] = []
        /// The same for the clips' raw decided spans (the same segments, before padding).
        var rawStartErrors: [Double] = [], rawEndErrors: [Double] = []

        static func + (a: Account, b: Account) -> Account {
            Account(rallies: a.rallies + b.rallies, preserved: a.preserved + b.preserved, clipped: a.clipped + b.clipped,
                    merged: a.merged + b.merged, split: a.split + b.split, partial: a.partial + b.partial, missed: a.missed + b.missed,
                    clips: a.clips + b.clips, falseClips: a.falseClips + b.falseClips,
                    missedServeMarks: a.missedServeMarks + b.missedServeMarks, missedServeMarksMissed: a.missedServeMarksMissed + b.missedServeMarksMissed,
                    rallyTime: a.rallyTime + b.rallyTime, covered: a.covered + b.covered, deadTime: a.deadTime + b.deadTime,
                    startErrors: a.startErrors + b.startErrors, endErrors: a.endErrors + b.endErrors,
                    rawStartErrors: a.rawStartErrors + b.rawStartErrors, rawEndErrors: a.rawEndErrors + b.rawEndErrors)
        }

        func objective(_ o: Plan.Objective) -> Double {
            guard rallies > 0, rallyTime > 0 else { return 0 }
            return (Double(preserved) - o.mergedRallyCost * Double(merged) - o.falseClipCost * Double(falseClips)) / Double(rallies)
                - o.deadTimeCost * deadTime / rallyTime
        }

        var within1s: Int { zip(startErrors, endErrors).filter { abs($0) <= 1 && abs($1) <= 1 }.count }

        static func median(_ v: [Double]) -> Double? {
            guard !v.isEmpty else { return nil }
            let s = v.sorted()
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }
    }

    /// The accounting of one video: `clips` delivered (padded, joined), `raw` their raw decided spans, `truth` the
    /// marks, `kinds` each mark's kind in the same order (nil when the mark has none).
    static func account(clips: [Interval], raw: [Interval], truth: [Interval], kinds: [RallyKind?], preservedShare: Double) -> Account {
        var a = Account()
        a.rallies = truth.count
        a.clips = clips.count
        let clipUnion = union(clips), truthUnion = union(truth)
        let matched = RallySegmentationScorer.score(predicted: clips, groundTruth: truth,
                                                    config: ScoringConfig(iouMatchThreshold: 0.3, boundaryToleranceSec: 1.0))
        let matchedTruth: [Interval] = matched.matches.map { $0.truth }
        func coversMostOf(_ c: Interval, _ t: Interval) -> Bool { overlap(c, t) > 0.5 * (t.end - t.start) }
        // A clip that covers more than half of two or more rallies merges them.
        let mergingClips: [Interval] = clips.filter { c in
            var covered = 0
            for t in truth where coversMostOf(c, t) { covered += 1 }
            return covered >= 2
        }
        for (index, t) in truth.enumerated() {
            let length = max(0, t.end - t.start)
            a.rallyTime += length
            let missedServeMark = index < kinds.count && kinds[index] == .missedServe
            if missedServeMark { a.missedServeMarks += 1 }
            var inside = 0.0
            for c in clipUnion { inside += overlap(c, t) }
            a.covered += inside
            var touching = 0, overHalfSecond = 0
            for c in clips where overlap(c, t) > 0 {
                touching += 1
                if overlap(c, t) > 0.5 { overHalfSecond += 1 }
            }
            if touching == 0 {
                a.missed += 1
                if missedServeMark { a.missedServeMarksMissed += 1 }
            } else if mergingClips.contains(where: { coversMostOf($0, t) }) {
                a.merged += 1
            } else if overHalfSecond >= 2 {
                a.split += 1
            } else if matchedTruth.contains(t) {
                if length > 0, inside >= preservedShare * length { a.preserved += 1 } else { a.clipped += 1 }
            } else {
                a.partial += 1
            }
        }
        for c in clipUnion {
            var insideTruth = 0.0
            for t in truthUnion { insideTruth += overlap(c, t) }
            a.deadTime += (c.end - c.start) - insideTruth
        }
        for c in clips where !truth.contains(where: { overlap(c, $0) > 0 }) { a.falseClips += 1 }
        for m in matched.matches {
            a.startErrors.append(m.pred.start - m.truth.start)
            a.endErrors.append(m.pred.end - m.truth.end)
        }
        let rawMatched = RallySegmentationScorer.score(predicted: raw, groundTruth: truth,
                                                       config: ScoringConfig(iouMatchThreshold: 0.3, boundaryToleranceSec: 1.0))
        for m in rawMatched.matches {
            a.rawStartErrors.append(m.pred.start - m.truth.start)
            a.rawEndErrors.append(m.pred.end - m.truth.end)
        }
        return a
    }

    static func overlap(_ a: Interval, _ b: Interval) -> Double { max(0, min(a.end, b.end) - max(a.start, b.start)) }

    /// One replay: the delivered clips and, for each, its raw decided span — the same segments, so joining and
    /// the minimum length (which act on padded ranges) apply to both alike.
    static func replay(evidence: [VideoProcessor.FrameEvidence], duration: Double, config: ProcessorConfig, minRallySec: Double) -> (clips: [Interval], raw: [Interval]) {
        let rallies = EvidenceReplayer.decidedRallies(evidence: evidence, duration: duration, config: config, minRallySec: minRallySec, padded: true)
        return (rallies.map(\.range), rallies.map(\.raw))
    }

    static func union(_ intervals: [Interval]) -> [Interval] {
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

    // MARK: - Recording groups

    /// Recording groups over the manifest's videos: one clip card, one uploader, one alias group, or a shared
    /// confirmed source, session or venue put two videos in one group (transitively) — `_v2`… variants and
    /// same-channel videos are not independent evidence. Video → group ID (the smallest name in the group).
    static func groups(_ videos: [ManifestVideo]) -> [String: String] {
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            return r
        }
        func join(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var byKey: [String: String] = [:]
        for v in videos {
            parent[v.video] = parent[v.video] ?? v.video
            var keys: [String] = []
            if let c = v.clipId, !c.isEmpty { keys.append("clip:" + c) }
            if let u = v.uploader?.trimmingCharacters(in: .whitespaces), !u.isEmpty { keys.append("up:" + u) }
            if let g = v.aliasGroup, !g.isEmpty { keys.append("grp:" + g) }
            if let s = v.sourceId.value, !s.isEmpty { keys.append("src:" + s) }
            if let s = v.sessionId.value, !s.isEmpty { keys.append("ses:" + s) }
            if let s = v.venueId.value, !s.isEmpty { keys.append("ven:" + s) }
            for k in keys {
                if let other = byKey[k] { join(other, v.video) } else { byKey[k] = v.video }
            }
        }
        return Dictionary(uniqueKeysWithValues: videos.map { ($0.video, find($0.video)) })
    }

    /// Why the plan can't run as written, or nil. Checked before anything is recorded or run.
    static func planRefusal(_ plan: Plan, reserved: Set<String>, withheld: Set<String>, groups: [String: String]) -> String? {
        let pool = plan.tune + plan.eval
        if plan.tune.isEmpty || plan.eval.isEmpty { return "the plan needs both a tune and an eval pool" }
        if Set(pool).count != pool.count { return "a recording is listed twice: \(Set(pool.filter { n in pool.filter { $0 == n }.count > 1 }).sorted())" }
        for n in pool {
            if let why = ScoringExposure.refusal(n, reserved: reserved, withheld: withheld) { return why }
        }
        let tuneGroups = Set(plan.tune.compactMap { groups[$0] }), evalGroups = Set(plan.eval.compactMap { groups[$0] })
        let straddling = tuneGroups.intersection(evalGroups)
        if !straddling.isEmpty { return "recording group(s) in both pools: \(straddling.sorted()) — settings would be evaluated on recordings they were chosen with" }
        if candidates(plan.grid).isEmpty { return "the grid lists no values" }
        return nil
    }

    // MARK: - Run

    struct Condition: Codable {
        var label: String
        var model: String
        var candidate: Candidate
        var perVideo: [String: Account]
    }

    struct Report: Codable {
        var plan: Plan
        var planSHA256: String
        var models: [String: String]           // name → package digest
        var ledgerRefs: [String: [String]]      // model → distinct refs (one per camera reading)
        var groups: [String: String]            // video → group
        var splits: [String: String]            // video → manifest split
        var parityMismatches: [String]          // "<model> <video>" where the replay at committed settings differs from the pass
        /// For each mismatch: the pass's own clips and the replay's, and the largest boundary difference (s).
        var parityDetails: [ParityDetail]

        struct ParityDetail: Codable {
            var model: String, video: String
            var pass: [[Double]], replay: [[Double]]
            var maxBoundaryDifference: Double
        }
        var gridRows: [GridRow]
        var chosen: Candidate?
        var conditions: [Condition]
        var passesOnly: Bool
        var startedAt: String, finishedAt: String

        struct GridRow: Codable { var candidate: Candidate; var tune: Account; var objective: Double }

        enum CodingKeys: String, CodingKey {
            case plan, planSHA256, models, ledgerRefs, groups, splits, parityMismatches, parityDetails, gridRows, chosen, conditions, passesOnly, startedAt, finishedAt
        }
    }

    @MainActor
    static func run(plan planURL: URL, out: URL, passesOnly: Bool, projects: ProjectsModel, models: (String) -> URL?,
                    log: @escaping (String) -> Void) async -> Bool {
        let started = iso(Date())
        guard let root = projects.projectDir else { log("❌ No project folder."); return false }
        let plan: Plan
        let planData: Data
        do { planData = try Data(contentsOf: planURL); plan = try JSONDecoder().decode(Plan.self, from: planData) } catch {
            log("❌ \(planURL.path): \(error.localizedDescription)"); return false
        }
        let planSHA = SHA256.hash(data: planData).map { String(format: "%02x", $0) }.joined()
        guard !FileManager.default.fileExists(atPath: out.path) else { log("❌ \(out.path) exists; name a new folder."); return false }

        // Eligibility: the reservation and the withheld closure, every rally marked, groups apart.
        let reserved: Set<String>, withheld: Set<String>
        do {
            reserved = try ReservedVideos.reservedNames(in: root)
            withheld = try ReservedVideos.lineageWithheldNames(in: root)
        } catch { log("❌ \(error.localizedDescription)"); return false }
        let manifest: DatasetSplitManifest
        do {
            guard let m = try DatasetSplitManifest.readStrict(from: NetInventory.manifestURL(in: root)) else {
                log("❌ No manifests/manifest.json: write the split manifest first (--manifest)."); return false
            }
            manifest = m
        } catch { log("❌ \(error.localizedDescription)"); return false }
        let groups = groups(manifest.videos)
        let splits = Dictionary(uniqueKeysWithValues: manifest.videos.map { ($0.video, "\($0.split)") })
        if let why = planRefusal(plan, reserved: reserved, withheld: withheld, groups: groups) { log("❌ Plan refused: \(why)"); return false }
        let pool = plan.tune + plan.eval
        for n in pool where groups[n] == nil { log("❌ \(n) is not in the split manifest."); return false }
        var videos: [String: PipelineTuner.Video] = [:]
        for v in PipelineTuner.videos(pool, sampler: projects.sampler, log: log) { videos[v.session.name] = v }
        // Each mark's kind, in the marks' order (the same file and order PipelineTuner.videos read the times from).
        var kinds: [String: [RallyKind?]] = [:]
        for v in videos.values {
            let file = RallyMarkModel.labelsURL(for: URL(fileURLWithPath: v.session.sourcePath))
            guard let data = try? Data(contentsOf: file), let marks = try? JSONDecoder().decode([RallyMarkRecord].self, from: data),
                  marks.count == v.truth.count else { log("❌ \(v.session.name): the marks' kinds can't be read beside their times."); return false }
            kinds[v.session.name] = marks.map(\.kind)
        }
        let unmarked = pool.filter { videos[$0] == nil }
        guard unmarked.isEmpty else { log("❌ Not every rally is marked (or not in the project): \(unmarked.joined(separator: ", "))"); return false }
        log("Plan \(plan.id) (sha256 \(planSHA.prefix(16))): tune \(plan.tune.count) recordings in \(Set(plan.tune.compactMap { groups[$0] }).count) groups · eval \(plan.eval.count) in \(Set(plan.eval.compactMap { groups[$0] }).count) groups · \(candidates(plan.grid).count) candidates")
        for n in pool { log("  \(n): \(splits[n] ?? "?") · group \(groups[n] ?? "?") · \(videos[n]?.truth.count ?? 0) rallies") }

        // The two models: their configs, digests and ledger refs; exposure recorded before any pass (D-002).
        var configs: [String: ProcessorConfig] = [:], digests: [String: String] = [:]
        for name in [plan.baselineModel, plan.candidateModel] {
            guard let url = models(name) else { log("❌ No multi-frame model \(name)."); return false }
            var config = ProcessorConfig()
            config.heatmapModel = url
            config.heatmapOnly = true
            config.applyVideoRotation = false
            configs[name] = config
            guard let digest = DatasetSplitManifest.canonicalDigest(ofDirectory: url) else { log("❌ \(url.path) can't be digested."); return false }
            digests[name] = digest
        }
        // One row per recording per model, with the config it is processed with (its camera position applied, as
        // the pass applies it) — every row before any pass runs.
        var refs: [String: [String]] = [:]   // model → distinct refs
        for name in [plan.baselineModel, plan.candidateModel] {
            var seen = Set<String>()
            for n in pool {
                let effective = configs[name]!.withCamera(of: videos[n]!.session)
                do {
                    let ref = try ScoringExposure.ref(command: "--retune-decider \(plan.id)", config: effective)
                    try ExposureLog.record(videos: [n], kind: .rallyScoring, ref: ref,
                                           note: ScoringExposure.note(config: effective) + "; plan \(plan.id) sha256 \(planSHA.prefix(16))", in: root)
                    seen.insert(ref)
                } catch { log("❌ \(error.localizedDescription)"); return false }
            }
            refs[name] = seen.sorted()
            for ref in seen.sorted() { log("ledger: \(ref)") }
        }

        // Passes: once per recording per model, cached by the tuner's key.
        let cache = root.appendingPathComponent("pipeline_tuning/evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var passes: [String: [String: PipelineTuner.Pass]] = [:]   // model → video → pass
        var mismatches: [String] = []
        var details: [Report.ParityDetail] = []
        for name in [plan.candidateModel, plan.baselineModel] {
            let config = configs[name]!
            let threshold = HeatmapBallDetector(modelURL: config.heatmapModel!).map { Double($0.threshold) } ?? 0.5
            let settings = PipelineTuner.Settings(config: config, minRallySec: plan.minRallySec)
            let key = PipelineTuner.detectionKey(settings, knobs: PipelineTuner.detectionKnobs(modelThreshold: threshold))
            log("\(name): passes (key \(key))…")
            for n in pool {
                let started = Date()
                guard let p = await PipelineTuner.pass(videos[n]!, settings, key: key, cache: cache) else { log("❌ \(n): couldn't process"); return false }
                let took = Date().timeIntervalSince(started)
                log(String(format: "  %@ %@ %.0f s · %d clips", n, took > 2 ? "ran" : "cached", took, p.clips.count))
                passes[name, default: [:]][n] = p
                // The replay at the committed settings must cut what the pass cut, or candidates measure something else.
                let replayed = replay(evidence: p.evidence, duration: p.duration, config: config, minRallySec: plan.minRallySec).clips
                let largest = zip(replayed, p.clips).map { max(abs($0.start - $1.start), abs($0.end - $1.end)) }.max() ?? 0
                if replayed.count != p.clips.count || largest > 0.2 {
                    mismatches.append("\(name) \(n)")
                    details.append(Report.ParityDetail(model: name, video: n, pass: p.clips.map { [$0.start, $0.end] },
                                                       replay: replayed.map { [$0.start, $0.end] }, maxBoundaryDifference: largest))
                    func list(_ c: [Interval]) -> String { c.map { String(format: "%.1f–%.1f", $0.start, $0.end) }.joined(separator: " ") }
                    log("  ⚠️ replay at the committed settings differs from the pass on \(n): \(p.clips.count) vs \(replayed.count) clips, largest boundary difference \(String(format: "%.1f", largest)) s")
                    log("     pipeline: \(list(p.clips))")
                    log("     replay:   \(list(replayed))")
                }
            }
        }

        func account(_ model: String, _ video: String, _ candidate: Candidate) -> Account {
            let p = passes[model]![video]!
            let config = candidate.apply(to: configs[model]!)
            let (clips, raw) = replay(evidence: p.evidence, duration: p.duration, config: config, minRallySec: plan.minRallySec)
            return Self.account(clips: clips, raw: raw, truth: p.video.truth, kinds: kinds[video] ?? [], preservedShare: plan.preservedShare)
        }
        func condition(_ label: String, _ model: String, _ candidate: Candidate) -> Condition {
            Condition(label: label, model: model, candidate: candidate,
                      perVideo: Dictionary(uniqueKeysWithValues: pool.map { ($0, account(model, $0, candidate)) }))
        }

        let committed = Candidate(values: [:])
        var gridRows: [Report.GridRow] = []
        var chosen: Candidate?
        var conditions = [condition("L1 committed", plan.baselineModel, committed), condition("L2 committed", plan.candidateModel, committed)]
        if !passesOnly {
            // The search: every candidate on the tune pool only, ranked by the objective; ties → the first in grid order.
            for c in candidates(plan.grid) {
                let tune = plan.tune.map { account(plan.candidateModel, $0, c) }.reduce(Account(), +)
                gridRows.append(Report.GridRow(candidate: c, tune: tune, objective: tune.objective(plan.objective)))
            }
            let best = gridRows.enumerated().max { a, b in a.element.objective < b.element.objective || (a.element.objective == b.element.objective && a.offset > b.offset) }!
            chosen = best.element.candidate
            log("Chosen on tune: \(best.element.candidate.label) → objective \(String(format: "%.4f", best.element.objective)) (committed: \(String(format: "%.4f", gridRows.first { $0.candidate == committed }?.objective ?? plan.tune.map { account(plan.candidateModel, $0, committed) }.reduce(Account(), +).objective(plan.objective)))")
            conditions.append(condition("L2 chosen", plan.candidateModel, best.element.candidate))
        }

        let report = Report(plan: plan, planSHA256: planSHA, models: digests, ledgerRefs: refs, groups: groups.filter { pool.contains($0.key) },
                            splits: splits.filter { pool.contains($0.key) }, parityMismatches: mismatches, parityDetails: details, gridRows: gridRows, chosen: chosen,
                            conditions: conditions, passesOnly: passesOnly, startedAt: started, finishedAt: iso(Date()))
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try planData.write(to: out.appendingPathComponent("plan.json"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: out.appendingPathComponent("report.json"))
            try markdown(report, pool: pool).write(to: out.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        } catch { log("❌ \(error.localizedDescription)"); return false }
        log("Report: \(out.path)")
        return true
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    // MARK: - Report

    static func line(_ a: Account) -> String {
        func med(_ v: [Double]) -> String { Account.median(v).map { String(format: "%+.1f", $0) } ?? "—" }
        return "\(a.rallies) | \(a.preserved) | \(a.clipped) | \(a.merged) | \(a.split) | \(a.partial) | \(a.missed) | \(a.clips) | \(a.falseClips) | "
            + String(format: "%.1f", a.rallies > 0 ? a.deadTime / Double(a.rallies) : 0) + " | \(med(a.startErrors)) / \(med(a.endErrors)) | \(med(a.rawStartErrors)) / \(med(a.rawEndErrors)) | \(a.within1s) | \(a.missedServeMarks) (\(a.missedServeMarksMissed))"
    }

    static let header = "| condition | rallies | preserved | clipped | merged | split | partial | missed | clips | false | dead s/rally | start/end (padded) | start/end (raw) | both within 1 s | missed-serve marks (of them missed) |\n|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"

    static func markdown(_ r: Report, pool: [String]) -> String {
        var md: [String] = ["# Decider retune — \(r.plan.id)", "",
                            "Plan sha256 `\(r.planSHA256)` · started \(r.startedAt) · finished \(r.finishedAt)" + (r.passesOnly ? " · **passes only: no search run**" : ""), ""]
        md.append("Models: " + r.models.map { "`\($0.key)` digest `\($0.value.prefix(16))…`" }.sorted().joined(separator: "; "))
        md.append("Ledger refs: " + r.ledgerRefs.sorted { $0.key < $1.key }.map { "\($0.key): " + $0.value.map { "`\($0)`" }.joined(separator: ", ") }.joined(separator: "; "))
        md.append("Tune: \(r.plan.tune.joined(separator: ", ")) · Eval: \(r.plan.eval.joined(separator: ", "))")
        md.append("Replay parity at the committed settings: " + (r.parityMismatches.isEmpty ? "every pass matches its replay within 0.2 s" : "**mismatch on \(r.parityMismatches.count) of \(r.conditions.first.map { $0.perVideo.count * 2 } ?? 0) passes** (details below)"))
        if !r.parityDetails.isEmpty {
            md.append(""); md.append("| model | recording | pipeline clips | replay clips | largest boundary difference |"); md.append("|---|---|---|---|---|")
            func list(_ c: [[Double]]) -> String { c.map { String(format: "%.1f–%.1f", $0[0], $0[1]) }.joined(separator: " ") }
            for d in r.parityDetails {
                md.append("| \(d.model) | \(d.video) | \(list(d.pass)) | \(list(d.replay)) | \(String(format: "%.1f", d.maxBoundaryDifference)) s |")
            }
        }
        md.append("")
        md.append("Objective per rally = (preserved − \(r.plan.objective.mergedRallyCost) × merged − \(r.plan.objective.falseClipCost) × false clips) / rallies − \(r.plan.objective.deadTimeCost) × dead time / rally time; preserved = matched one-to-one with ≥ \(Int(r.plan.preservedShare * 100)) % inside the clips.")
        md.append("")
        for (title, names) in [("Tune pool (settings chosen here)", r.plan.tune), ("Evaluation pool (not used to choose; development evidence)", r.plan.eval)] {
            md.append("## \(title)"); md.append(""); md.append(header)
            for c in r.conditions {
                let a = names.compactMap { c.perVideo[$0] }.reduce(Account(), +)
                md.append("| \(c.label) \(c.candidate.values.isEmpty ? "" : "(\(c.candidate.label))") | \(line(a)) | objective \(String(format: "%.4f", a.objective(r.plan.objective))) |")
            }
            md.append("")
            // Per surface and per group, each condition.
            let surfaces = Dictionary(grouping: names) { String($0.prefix(3)) }
            md.append("### By surface"); md.append(""); md.append(header)
            for (s, ns) in surfaces.sorted(by: { $0.key < $1.key }) {
                for c in r.conditions {
                    let a = ns.compactMap { c.perVideo[$0] }.reduce(Account(), +)
                    md.append("| \(s) · \(c.label) | \(line(a)) |")
                }
            }
            md.append("")
            let byGroup = Dictionary(grouping: names) { r.groups[$0] ?? $0 }
            md.append("### By recording group (\(byGroup.count))"); md.append(""); md.append(header)
            for (g, ns) in byGroup.sorted(by: { $0.key < $1.key }) {
                for c in r.conditions {
                    let a = ns.compactMap { c.perVideo[$0] }.reduce(Account(), +)
                    md.append("| \(g) (\(ns.count)) · \(c.label) | \(line(a)) |")
                }
            }
            md.append("")
            md.append("### Per recording"); md.append(""); md.append(header)
            for n in names {
                for c in r.conditions {
                    if let a = c.perVideo[n] { md.append("| \(n) (\(r.splits[n] ?? "?")) · \(c.label) | \(line(a)) |") }
                }
            }
            md.append("")
        }
        if !r.gridRows.isEmpty {
            md.append("## Grid on the tune pool (\(r.gridRows.count) candidates, best first)"); md.append("")
            md.append("| candidate | objective | preserved | clipped | merged | split | partial | missed | clips | false | dead s/rally |"); md.append("|---|---|---|---|---|---|---|---|---|---|---|")
            for row in r.gridRows.sorted(by: { $0.objective > $1.objective }).prefix(40) {
                let a = row.tune
                md.append("| \(row.candidate.values.isEmpty ? "committed" : row.candidate.label) | \(String(format: "%.4f", row.objective)) | \(a.preserved) | \(a.clipped) | \(a.merged) | \(a.split) | \(a.partial) | \(a.missed) | \(a.clips) | \(a.falseClips) | \(String(format: "%.1f", a.rallies > 0 ? a.deadTime / Double(a.rallies) : 0)) |")
            }
            md.append("")
        }
        return md.joined(separator: "\n")
    }
}
