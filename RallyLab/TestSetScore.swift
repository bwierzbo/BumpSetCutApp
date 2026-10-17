//
//  TestSetScore.swift
//  RallyLab
//
//  Scores multi-frame ball models on the test set — the val clips' checked
//  frames, exported by --package-multiframe --val-only — the way training
//  scores them: a peak within 4 px of a ball at 512 wide. With it: ranges
//  from redrawing the videos, court splits, a threshold sweep, head-to-head
//  odds, localisation error, small-ball recall and the fires in dead time.
//
//  Each model's peaks are kept per export under <project>/scores/<export>/
//  <model>.json, so a new model is scored alone and joins the ones before
//  it; scores.json and comparison.html (the models side by side) go beside
//  them. Headless: RallyLab --project <name> --score-heat [model…] [--export <folder>]
//

import CoreGraphics
import Foundation
import ImageIO

enum TestSetScore {
    static let thresholds: [Float] = (1...9).map { Float($0) / 10 }
    /// A peak this close to a ball (px at 512 wide) finds it…
    static let tau = 4.0
    /// …and this close to a hidden ball is neither a find nor a false alarm.
    static let occludedTau = 16.0
    static let scenes = ["bch": "beach", "grs": "grass", "ind": "indoor"]
    static let courts = ["beach", "grass", "indoor"]

    /// One frame to score, in the window it sits most centrally in.
    struct Job {
        let clip: String
        let frames: [String]
        let index: Int
        let dead: Bool
        let balls: [[Double]]
        let occluded: [Double]?
        let portrait: Bool
        let time: Double
    }

    /// A model's peaks on every job, at each threshold.
    struct ModelResult: Codable {
        struct Item: Codable {
            let clip: String
            let frame: String
            let dead: Bool
            let time: Double
            let balls: [[Double]]
            let occluded: [Double]?
            /// Per threshold: [x, y, confidence], normalised, as the labels are.
            let peaks: [[[Double]]]
        }
        let model: String
        let export: String
        let ms: Double
        let items: [Item]
    }

    /// What the comparison page and the leaderboard show.
    struct Scores: Codable {
        struct Court: Codable {
            var f1: Double, p: Double, r: Double
            var tp: Int, fp: Int, fn: Int
            var lo: Double, hi: Double
            var clips: Int
        }
        struct Row: Codable {
            var name: String
            var p: Double, r: Double, f1: Double
            var tp: Int, fp: Int, fn: Int
            var lo: Double, hi: Double
            var beach: Court, grass: Court, indoor: Court
            var tau: [String: Double]
            var sweep: [[Double]]
            var err_median: Double?
            var occluded: [Int]
            var size: [String: [Int]]
            var empty: [Int]
            var deadfire: [Int]
        }
        struct Clip: Codable {
            var scene: String
            var balls: Int
            var f1: [Double]
        }
        var export: String
        var names: [String]
        var ms: [Double]
        var thresholds: [Double]
        var frames: Int, labelled: Int, balls: Int, dead: Int
        var clips: [String: Clip]
        var models: [Row]
        var ballVideos: Int
        var ballVideosByCourt: String
        var beats: [[Double]]
    }

    // MARK: - Jobs

    /// One job per labelled val frame (and per dead-time frame), each with
    /// the window it sits most centrally in.
    static func jobs(export: URL) throws -> [Job] {
        let text = try String(contentsOf: export.appendingPathComponent("windows.jsonl"), encoding: .utf8)
        var best: [String: (job: Job, distance: Int)] = [:]
        for line in text.split(separator: "\n") {
            guard let w = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  w["split"] as? String == "val",
                  let frames = w["frames"] as? [String], let size = w["size"] as? [Int], size.count == 2,
                  let clip = w["clip"] as? String, let target = w["target"] as? Int,
                  let time = (w["time"] as? NSNumber)?.doubleValue else { continue }
            let portrait = size[1] > size[0]
            if w["dead"] as? Bool == true {
                best["dead:" + frames[target]] = (Job(clip: clip, frames: frames, index: target, dead: true, balls: [],
                                                      occluded: nil, portrait: portrait, time: time), 0)
                continue
            }
            let occluded = w["occluded"] as? [Any] ?? []
            var labels: [[[Double]]?] = (w["labels"] as? [Any])?.map { $0 as? [[Double]] } ?? []
            if labels.isEmpty {
                labels = Array(repeating: nil, count: frames.count)
                labels[target] = w["balls"] as? [[Double]] ?? []
            }
            for (i, balls) in labels.enumerated() {
                guard let balls else { continue }
                let distance = abs(i - target), key = "lab:" + frames[i]
                if let have = best[key], have.distance <= distance { continue }
                best[key] = (Job(clip: clip, frames: frames, index: i, dead: false, balls: balls,
                                 occluded: i < occluded.count ? occluded[i] as? [Double] : nil,
                                 portrait: portrait, time: time + Double(i - target) / 30), distance)
            }
        }
        return best.values.map(\.job).sorted { ($0.clip, $0.time) < ($1.clip, $1.time) }
    }

    // MARK: - Running a model

    /// The model's peaks on every job it can see whole, and its ms a window.
    static func run(model url: URL, name: String, jobs: [Job], export: URL,
                    progress: (Int, Int) -> Void) -> ModelResult? {
        guard let detector = HeatmapBallDetector(modelURL: url) else { return nil }
        var items: [ModelResult.Item] = []
        var ms = 0.0, runs = 0
        // Jobs come in clip and time order, so one job's frames are mostly the
        // last job's: keep the last few dozen decoded, as the model sees them.
        var recent: [String: HeatmapBallDetector.Frame] = [:]
        var recentOrder: [String] = []
        func frame(_ path: String) -> HeatmapBallDetector.Frame? {
            if let f = recent[path] { return f }
            guard let source = CGImageSourceCreateWithURL(export.appendingPathComponent(path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let f = detector.frame(image) else { return nil }
            recent[path] = f
            recentOrder.append(path)
            if recentOrder.count > 48 { recent.removeValue(forKey: recentOrder.removeFirst()) }
            return f
        }
        for (n, job) in jobs.enumerated() {
            autoreleasepool {
                let start = job.index - detector.seq / 2
                guard start >= 0, start + detector.seq <= job.frames.count else { return }
                var frames: [HeatmapBallDetector.Frame] = []
                for i in start..<start + detector.seq {
                    guard let f = frame(job.frames[i]) else { return }
                    frames.append(f)
                }
                let began = Date()
                guard let result = detector.detect(in: frames, target: detector.seq / 2) else { return }
                ms += Date().timeIntervalSince(began) * 1000
                runs += 1
                let portrait = frames[detector.seq / 2].portrait
                let peaks = thresholds.map { blobs(result.heat, detector.width, detector.height, $0, portrait: portrait) }
                items.append(.init(clip: job.clip, frame: job.frames[job.index], dead: job.dead, time: job.time,
                                   balls: job.balls, occluded: job.occluded, peaks: peaks))
            }
            if n % 200 == 0 { progress(n, jobs.count) }
        }
        return ModelResult(model: name, export: export.lastPathComponent, ms: ms / Double(max(1, runs)), items: items)
    }

    /// Blobs of the heat at `threshold`: 8-connected, two pixels or more,
    /// their centroids normalised and turned back upright for portrait.
    private static func blobs(_ heat: [Float], _ w: Int, _ h: Int, _ threshold: Float, portrait: Bool) -> [[Double]] {
        var seen = [Bool](repeating: false, count: w * h)
        var out: [[Double]] = []
        for s in 0..<(w * h) where !seen[s] && heat[s] >= threshold {
            var stack = [s]
            seen[s] = true
            var sx = 0.0, sy = 0.0, n = 0
            var best: Float = 0
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                sx += Double(x); sy += Double(y); n += 1; best = max(best, heat[i])
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let j = ny * w + nx
                        if !seen[j] && heat[j] >= threshold { seen[j] = true; stack.append(j) }
                    }
                }
            }
            guard n >= 2 else { continue }
            let mx = (sx / Double(n) + 0.5) / Double(w), my = (sy / Double(n) + 0.5) / Double(h)
            let (x, y) = portrait ? (my, 1 - mx) : (mx, my)
            out.append([x, y, Double(best)])
        }
        return out
    }

    // MARK: - Cache

    static func cacheFile(model: String, export: URL, scores: URL) -> URL {
        scores.appendingPathComponent(export.lastPathComponent, isDirectory: true).appendingPathComponent("\(model).json")
    }

    static func cached(model: String, export: URL, scores: URL) -> ModelResult? {
        (try? Data(contentsOf: cacheFile(model: model, export: export, scores: scores)))
            .flatMap { try? JSONDecoder().decode(ModelResult.self, from: $0) }
    }

    static func store(_ result: ModelResult, export: URL, scores: URL) throws {
        let file = cacheFile(model: result.model, export: export, scores: scores)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(result).write(to: file, options: .atomic)
    }

    // MARK: - Scoring

    private struct Match {
        var tp = 0, fp = 0, fn = 0
        var errors: [Double] = []
        var occludedHits = 0
        var missed: [[Double]] = []
    }

    private static func distance(_ a: [Double], _ b: [Double]) -> Double {
        ((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1])).squareRoot() * 512
    }

    /// Training's rule: each peak takes the nearest unmatched ball within
    /// `tau`; near a hidden ball it counts for nothing; otherwise it's false.
    private static func match(_ peaks: [[Double]], _ balls: [[Double]], _ occluded: [Double]?, tau: Double) -> Match {
        var m = Match()
        var unmatched = balls
        var hidden = occluded.map { [$0] } ?? []
        for p in peaks {
            if let k = unmatched.indices.min(by: { distance(p, unmatched[$0]) < distance(p, unmatched[$1]) }),
               distance(p, unmatched[k]) <= tau {
                m.errors.append(distance(p, unmatched[k]))
                unmatched.remove(at: k)
                m.tp += 1
                continue
            }
            if let k = hidden.indices.min(by: { distance(p, hidden[$0]) < distance(p, hidden[$1]) }),
               distance(p, hidden[k]) <= occludedTau {
                hidden.remove(at: k)
                m.occludedHits += 1
            } else {
                m.fp += 1
            }
        }
        m.fn = unmatched.count
        m.missed = unmatched
        return m
    }

    private struct Counts { var tp = 0, fp = 0, fn = 0 }

    private static func f1(_ c: Counts) -> (p: Double, r: Double, f1: Double) {
        let p = Double(c.tp) / Double(max(1, c.tp + c.fp)), r = Double(c.tp) / Double(max(1, c.tp + c.fn))
        return (p, r, 2 * p * r / max(1e-9, p + r))
    }

    private static func total(_ per: [String: Counts], _ clips: [String]) -> Counts {
        clips.reduce(into: Counts()) { s, c in
            guard let t = per[c] else { return }
            s.tp += t.tp; s.fp += t.fp; s.fn += t.fn
        }
    }

    /// SplitMix64: the same redraws every time, so ranges are comparable run to run.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
    }

    /// The models side by side, on the frames every one of them scored.
    static func score(_ results: [ModelResult]) -> Scores {
        let export = results.first?.export ?? ""
        // Align on the frames all models have.
        var common = Set(results.first?.items.map(\.frame) ?? [])
        for r in results.dropFirst() { common.formIntersection(r.items.map(\.frame)) }
        let aligned: [[ModelResult.Item]] = results.map { r in
            r.items.filter { common.contains($0.frame) }.sorted { ($0.clip, $0.time, $0.frame) < ($1.clip, $1.time, $1.frame) }
        }
        let items = aligned.first ?? []
        let n = results.count
        let thresholds = Self.thresholds.map { Double($0) }
        let t5 = Self.thresholds.firstIndex(of: 0.5) ?? 4

        func perClip(_ m: Int, threshold ti: Int, tau: Double, court: String? = nil) -> [String: Counts] {
            var per: [String: Counts] = [:]
            for (k, it) in items.enumerated() where !it.dead {
                if let court, scenes[String(it.clip.prefix(3))] != court { continue }
                let r = match(aligned[m][k].peaks[ti], it.balls, it.occluded, tau: tau)
                per[it.clip, default: Counts()].tp += r.tp
                per[it.clip, default: Counts()].fp += r.fp
                per[it.clip, default: Counts()].fn += r.fn
            }
            return per
        }

        let clips = Set(items.filter { !$0.dead && !$0.balls.isEmpty }.map(\.clip)).sorted()
        var rng = Seeded(state: 0)
        let boots: [[String]] = (0..<2000).map { _ in clips.map { _ in clips.randomElement(using: &rng)! } }
        let pers = (0..<n).map { perClip($0, threshold: t5, tau: tau) }

        var scores = Scores(export: export, names: results.map(\.model), ms: results.map(\.ms), thresholds: thresholds,
                            frames: items.count, labelled: items.filter { !$0.dead }.count,
                            balls: items.filter { !$0.dead }.reduce(0) { $0 + $1.balls.count },
                            dead: items.filter(\.dead).count, clips: [:], models: [], ballVideos: clips.count,
                            ballVideosByCourt: "", beats: [])
        for c in clips {
            scores.clips[c] = Scores.Clip(scene: scenes[String(c.prefix(3))] ?? "?",
                                          balls: items.filter { $0.clip == c && !$0.dead }.reduce(0) { $0 + $1.balls.count },
                                          f1: (0..<n).map { (f1(total(pers[$0], [c])).f1 * 1000).rounded() / 1000 })
        }
        var byCourt: [String: Int] = [:]
        for c in clips { byCourt[scenes[String(c.prefix(3))] ?? "?", default: 0] += 1 }
        scores.ballVideosByCourt = byCourt.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")

        for m in 0..<n {
            let per = pers[m]
            let all = total(per, clips), overall = f1(all)
            let bs = boots.map { f1(total(per, $0)).f1 }.sorted()
            func court(_ name: String) -> Scores.Court {
                let cs = clips.filter { scenes[String($0.prefix(3))] == name }
                let c = total(per, cs), s = f1(c)
                let sb = (0..<1000).map { _ in f1(total(per, cs.map { _ in cs.randomElement(using: &rng) ?? "" })).f1 }.sorted()
                return Scores.Court(f1: s.f1, p: s.p, r: s.r, tp: c.tp, fp: c.fp, fn: c.fn,
                                    lo: sb.isEmpty ? 0 : sb[50], hi: sb.isEmpty ? 0 : sb[949], clips: cs.count)
            }
            var row = Scores.Row(name: results[m].model, p: overall.p, r: overall.r, f1: overall.f1,
                                 tp: all.tp, fp: all.fp, fn: all.fn, lo: bs[100], hi: bs[1899],
                                 beach: court("beach"), grass: court("grass"), indoor: court("indoor"),
                                 tau: [:], sweep: [], err_median: nil, occluded: [0, 0], size: [:], empty: [0, 0], deadfire: [0, 0])
            for t in [2.0, 4.0, 8.0] {
                row.tau[String(Int(t))] = f1(total(perClip(m, threshold: t5, tau: t), clips)).f1
            }
            row.sweep = thresholds.indices.map { ti in
                let s = f1(total(perClip(m, threshold: ti, tau: tau), clips))
                return [s.p, s.r, s.f1]
            }
            var errors: [Double] = []
            var sizes: [String: [Int]] = [:]
            for (k, it) in items.enumerated() {
                let peaks = aligned[m][k].peaks[t5]
                if it.dead {
                    row.deadfire[0] += peaks.isEmpty ? 0 : 1
                    row.deadfire[1] += 1
                    continue
                }
                let r = match(peaks, it.balls, it.occluded, tau: tau)
                errors += r.errors
                if it.occluded != nil { row.occluded[0] += r.occludedHits; row.occluded[1] += 1 }
                if it.balls.isEmpty && it.occluded == nil {
                    row.empty[0] += peaks.isEmpty ? 0 : 1
                    row.empty[1] += 1
                }
                for b in it.balls where b.count >= 4 {
                    let d = max(b[2] * 512, b[3] * 288)
                    let bucket = d < 6 ? "small (<6 px)" : d < 10 ? "medium (6–10 px)" : "large (10+ px)"
                    sizes[bucket, default: [0, 0]][1] += 1
                    if !r.missed.contains(b) { sizes[bucket, default: [0, 0]][0] += 1 }
                }
            }
            errors.sort()
            row.err_median = errors.isEmpty ? nil : errors[errors.count / 2]
            row.size = sizes
            scores.models.append(row)
        }
        scores.beats = (0..<n).map { a in
            (0..<n).map { c in
                Double(boots.filter { f1(total(pers[a], $0)).f1 > f1(total(pers[c], $0)).f1 }.count) / Double(boots.count)
            }
        }
        return scores
    }

    // MARK: - Reports

    /// The table the headless command prints.
    static func lines(_ s: Scores) -> [String] {
        var out: [String] = []
        for r in s.models {
            let best = r.sweep.indices.max { r.sweep[$0][2] < r.sweep[$1][2] } ?? 0
            out.append(String(format: "%@  F1 %.3f [%.3f–%.3f]  P %.3f R %.3f | beach %.3f grass %.3f indoor %.3f | best th %.1f F1 %.3f | 2/8 px %.3f/%.3f err %.2f | empty %d/%d dead %d/%d",
                              r.name.padding(toLength: 44, withPad: " ", startingAt: 0), r.f1, r.lo, r.hi, r.p, r.r,
                              r.beach.f1, r.grass.f1, r.indoor.f1, s.thresholds[best], r.sweep[best][2],
                              r.tau["2"] ?? 0, r.tau["8"] ?? 0, r.err_median ?? 0,
                              r.empty[0], r.empty[1], r.deadfire[0], r.deadfire[1]))
        }
        out.append("ms a window: " + zip(s.names, s.ms).map { String(format: "%@ %.0f", $0, $1) }.joined(separator: " · "))
        return out
    }

    /// comparison.html: the models side by side, from the page template.
    static func page(_ s: Scores) throws -> String {
        guard let url = Bundle.main.url(forResource: "BallFaceoff", withExtension: "html") else {
            throw NSError(domain: "TestSetScore", code: 1, userInfo: [NSLocalizedDescriptionKey: "BallFaceoff.html isn't in the app"])
        }
        let shapes = ["circle", "triangle", "square", "pentagon", "diamond", "hexagon", "cross", "plus", "star"]
        let models: [[String: String]] = s.names.enumerated().map { i, name in
            ["name": name, "note": "", "color": "--m\(i % shapes.count)", "shape": shapes[i % shapes.count]]
        }
        let encoder = JSONEncoder()
        let data = try encoder.encode(s)
        let payload = "{\"scores\":" + String(decoding: data, as: UTF8.self)
            + ",\"items\":[],\"counts\":{\"disagree\":0,\"allmissed\":0,\"allfound\":0}}"
        let modelsJSON = String(decoding: try JSONSerialization.data(withJSONObject: models), as: UTF8.self)
        return try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "__MODELS__", with: modelsJSON)
            .replacingOccurrences(of: "__DATA__", with: payload)
    }
}
