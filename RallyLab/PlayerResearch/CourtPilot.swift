//
//  CourtPilot.swift
//  RallyLab
//
//  `RallyLab --player-lab-court <experiment> --run <run> --report <name> [--propose] [--audit <csv>]`
//  (research P2, headless): for every recording of an existing Player Lab run —
//    1. with --propose, the automatic court proposals for each unreviewed segment, added to
//       the recording's calibration file (never a confirmation; a stale or unreadable file
//       is left alone and reported);
//    2. the players' zones on every frame of the run against, separately, each proposal
//       and the person-confirmed court when there is one — a proposal's zones are labelled
//       as unconfirmed in every output;
//    3. pictures: per recording a four-panel comparison (the frame; the proposals; the
//       confirmed court or "not reviewed"; the zones), each audited frame's zones, and the
//       line evidence the court-lines method saw.
//  It reads the run folder and the experiment's footage copies and writes only
//  `<experiment>/court-calibrations/` (proposals) and `<experiment>/court-evals/<name>/`.
//  No RallyLab project is opened, no detector runs, nothing is trained.
//

import AVFoundation
import CoreGraphics
import Foundation

enum CourtPilot {
    enum Failure: LocalizedError {
        case badName(String), exists(String), noRun(String)
        var errorDescription: String? {
            switch self {
            case .badName(let n): return "\(n) is not a usable report name (letters, digits, - _ . only)."
            case .exists(let p): return "\(p) exists already: choose another report name."
            case .noRun(let p): return "No Player Lab run at \(p)."
            }
        }
    }

    /// Zones per frame for one geometry source over a recording's frames.
    static func zones(_ frames: [PlayerFeatures.Frame], classifier: @escaping (Double) -> (classifier: CourtZoneClassifier, segment: Int)?) -> [[PersonZone]?] {
        var pass = CourtMembershipPass(classifier: classifier)
        var last: Int?
        return frames.map { f in
            if f.seg != last { pass.resetTracks(); last = f.seg }
            return f.masks.ran ? pass.zones(f.persons, at: f.t) : nil
        }
    }

    struct SourceStats: Codable, Equatable {
        var source: String
        var confirmed: Bool
        var frames: Int
        var perFrame: [String: Double]
        var inPlayPerFrame: Double
        var uncertainShare: Double
        /// Zone changes per track per 10 observations, before and after smoothing.
        var rawChangesPer10: Double
        var smoothedChangesPer10: Double
        var auditFrames: Int?
        /// Over audited frames: persons in play beyond the people the auditor counted on court (a floor on false "in").
        var auditExcessPerFrame: Double?
        /// Over audited frames: people the auditor counted on court beyond the persons in play.
        var auditShortfallPerFrame: Double?
    }

    static func stats(_ frames: [PlayerFeatures.Frame], _ zones: [[PersonZone]?], source: String, confirmed: Bool,
                      audit: [Int: Int]) -> SourceStats {
        var counts: [CourtZone: Int] = [:]
        var analysed = 0, inPlay = 0, uncertain = 0, observations = 0
        var lastRaw: [Int: CourtZone] = [:], lastZone: [Int: CourtZone] = [:]
        var rawChanges = 0, zoneChanges = 0, pairs = 0
        var excess = 0, shortfall = 0, audited = 0
        var lastSeg: Int?
        for (f, z) in zip(frames, zones) {
            if f.seg != lastSeg { lastRaw = [:]; lastZone = [:]; lastSeg = f.seg }
            guard let z else { continue }
            analysed += 1
            var framePlay = 0
            for (p, pz) in zip(f.persons, z) {
                if p.state == .confirmed {
                    counts[pz.zone, default: 0] += 1
                    observations += 1
                    if pz.uncertain { uncertain += 1 }
                    if pz.zone.isPlaying { inPlay += 1 }
                    if let r = lastRaw[p.track] { pairs += 1; if r != pz.raw { rawChanges += 1 }; if lastZone[p.track] != pz.zone { zoneChanges += 1 } }
                    lastRaw[p.track] = pz.raw
                    lastZone[p.track] = pz.zone
                }
                if pz.zone.isPlaying { framePlay += 1 }
            }
            if let visible = audit[f.tick] {
                audited += 1
                excess += max(0, framePlay - visible)
                shortfall += max(0, visible - framePlay)
            }
        }
        let n = Double(max(analysed, 1))
        return SourceStats(source: source, confirmed: confirmed, frames: analysed,
                           perFrame: Dictionary(uniqueKeysWithValues: CourtZone.allCases.map { ($0.rawValue, Double(counts[$0] ?? 0) / n) }),
                           inPlayPerFrame: Double(inPlay) / n, uncertainShare: observations > 0 ? Double(uncertain) / Double(observations) : 0,
                           rawChangesPer10: pairs > 0 ? 10 * Double(rawChanges) / Double(pairs) : 0,
                           smoothedChangesPer10: pairs > 0 ? 10 * Double(zoneChanges) / Double(pairs) : 0,
                           auditFrames: audit.isEmpty ? nil : audited,
                           auditExcessPerFrame: audited > 0 ? Double(excess) / Double(audited) : nil,
                           auditShortfallPerFrame: audited > 0 ? Double(shortfall) / Double(audited) : nil)
    }

    /// The audit CSV's visible on-court players per tick for a recording (columns `recording`, `tick`, `visible_on_court`).
    static func audit(_ url: URL?, recording: String) -> [Int: Int] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        // `\r\n` is one Character in Swift: split on any newline.
        let rows = text.split(whereSeparator: \.isNewline).map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        guard let head = rows.first, let r = head.firstIndex(of: "recording"), let t = head.firstIndex(of: "tick"),
              let v = head.firstIndex(of: "visible_on_court") else { return [:] }
        var out: [Int: Int] = [:]
        for row in rows.dropFirst() where row.count > max(r, t, v) && row[r] == recording {
            if let tick = Int(row[t]), let n = Int(row[v]) { out[tick] = n }
        }
        return out
    }

    struct RecordingReport: Codable {
        var recordingId: String
        var surface: String?
        var camera: String?
        var calibration: String
        var proposals: [ProposalSummary]
        var proposalNotes: [String]
        var sources: [SourceStats]
        var panel: String?
        var lines: String?
        var auditImages: [String]
        /// Against the person-confirmed court (nil until one exists): each proposal's point distances in pixels of the
        /// decoded frame, and what the person changed.
        var againstConfirmed: AgainstConfirmed? = nil
    }

    struct AgainstConfirmed: Codable {
        var startedFrom: String
        var adjustedRoles: [String]
        var confirmedBy: String
        /// method → role → pixels between the proposal's point and the confirmed one (both placed).
        var pointErrorPx: [String: [String: Double]]
        var meanErrorPx: [String: Double]
    }

    /// How far each proposal's points lie from the confirmed court's, in pixels of a `w` × `h` frame.
    static func against(_ c: CourtConfirmation, proposals: [CourtProposal], w: Int, h: Int) -> AgainstConfirmed {
        var errors: [String: [String: Double]] = [:], means: [String: Double] = [:]
        for p in proposals {
            var e: [String: Double] = [:]
            for r in CourtLayout.Role.allCases where p.geometry[r].status != .unknown && c.geometry[r].status != .unknown {
                e[r.rawValue] = hypot((p.geometry[r].x - c.geometry[r].x) * Double(w), (p.geometry[r].y - c.geometry[r].y) * Double(h))
            }
            errors[p.method.rawValue] = e
            if !e.isEmpty { means[p.method.rawValue] = e.values.reduce(0, +) / Double(e.count) }
        }
        return AgainstConfirmed(startedFrom: c.startedFrom, adjustedRoles: c.adjustedRoles, confirmedBy: c.confirmedBy, pointErrorPx: errors, meanErrorPx: means)
    }

    struct ProposalSummary: Codable {
        var method: String
        var confidence: Double
        var ms: Double
        var points: [String: String]
        var pointSources: [String: String]
        var uncertainty: [String]
        var geometry: CourtLayout
    }

    @discardableResult
    static func run(experiment: URL, runName: String, report: String, propose: Bool, auditCSV: URL?, codeSha: String?,
                    log: @escaping (String) -> Void) async throws -> URL {
        guard RallyClassifierExporter.isSafeName(report) else { throw Failure.badName(report) }
        let runDir = experiment.appendingPathComponent("runs/\(runName)", isDirectory: true)
        let manifestURL = runDir.appendingPathComponent("features/player-features-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw Failure.noRun(runDir.path) }
        let manifest = try JSONDecoder().decode(PlayerFeatures.Manifest.self, from: data)
        let out = experiment.appendingPathComponent("court-evals/\(report)", isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: out.path) else { throw Failure.exists(out.path) }
        for sub in ["panels", "zones", "lines", "audit"] { try fm.createDirectory(at: out.appendingPathComponent(sub), withIntermediateDirectories: true) }
        let store = CourtCalibrationStore(experiment: experiment)
        var reports: [RecordingReport] = []
        var csv = ["recording,interval,tick,t,source,track,state,foot,u,v,raw,zone,uncertain,why,lane_court"]

        for rec in manifest.recordings {
            let binding = CourtCalibrationFile.Binding(rec)
            let footage = PlayerFeaturesRun.experimentFootage(experiment, rec.recordingId)
            var file: CourtCalibrationFile
            var notes: [String] = []
            var calibration = "new"
            do {
                if let f = try store.load(rec.recordingId) {
                    if let why = f.staleReason(for: binding) {
                        log("⚠️ \(rec.recordingId): calibration is stale (\(why)) — left alone, not used")
                        reports.append(RecordingReport(recordingId: rec.recordingId, surface: rec.surface, camera: rec.camera, calibration: "stale: \(why)",
                                                       proposals: [], proposalNotes: [], sources: [], panel: nil, lines: nil, auditImages: []))
                        continue
                    }
                    file = f
                    calibration = "existing"
                } else { file = CourtCalibrationFile.new(for: binding) }
            } catch {
                log("⚠️ \(rec.recordingId): calibration unreadable (\(error.localizedDescription)) — left alone")
                reports.append(RecordingReport(recordingId: rec.recordingId, surface: rec.surface, camera: rec.camera, calibration: "unreadable",
                                               proposals: [], proposalNotes: [], sources: [], panel: nil, lines: nil, auditImages: []))
                continue
            }
            var linesImage: String?
            if propose {
                for i in file.segments.indices where file.segments[i].status == .unreviewed {
                    let s = file.segments[i]
                    let spec = file.setup?.spec ?? CourtSpec.standard(surface: rec.surface)
                    let o = try await CourtProposer.propose(footage: footage, net: rec.net, binding: binding, from: s.validFromSec, to: s.validToSec,
                                                            excluded: rec.cutRanges + rec.timeBreakingSpans, spec: spec, markings: file.setup?.markings,
                                                            experiment: experiment, ref: "--player-lab-court \(report) court proposals", codeSha: codeSha)
                    file.segments[i].proposals += o.proposals
                    notes += o.notes
                    if i == 0, let median = o.median, let img = linesPicture(median, evidence: o.evidence, proposals: o.proposals, frames: o.frameTimes.count),
                       let jpeg = PlayerOverlay.jpeg(img) {
                        linesImage = "lines/\(rec.recordingId).jpg"
                        try jpeg.write(to: out.appendingPathComponent(linesImage!))
                    }
                    log("   \(rec.recordingId) segment \(s.id): " + o.proposals.map { "\($0.method.rawValue) \(String(format: "%.2f", $0.confidence)) \(String(format: "%.0f", $0.ms)) ms" }.joined(separator: ", "))
                }
                try store.save(file)
            }

            // Frames of the run.
            let lines = try Data(contentsOf: runDir.appendingPathComponent("features").appendingPathComponent(rec.framesFile))
            let frames = try lines.split(separator: 0x0A).map { try JSONDecoder().decode(PlayerFeatures.Frame.self, from: Data($0)) }
            let auditTicks = audit(auditCSV, recording: rec.recordingId)
            let seg0 = file.segments.first { $0.status == .unreviewed || $0.status == .confirmed }
            var sources: [(name: String, confirmed: Bool, geometry: (Double) -> (CourtLayout, Int)?, spec: CourtSpec)] = []
            for p in seg0?.latestProposals ?? [] {
                let g = p.geometry, id = seg0!.id
                sources.append(("unconfirmed \(p.method.rawValue)", false, { t in file.segments.first { $0.contains(t) }?.id == id ? (g, id) : nil },
                                CourtSpec.standard(surface: rec.surface)))
            }
            let lookup = store.confirmedLookup(for: binding)
            if lookup.unusable == nil, let f = lookup.file {
                sources.append(("confirmed", true, { t in f.confirmed(at: t).map { c in (c.geometry, f.segments.first { $0.contains(t) }!.id) } },
                                f.segments.compactMap(\.confirmation).first?.spec ?? CourtSpec.standard(surface: rec.surface)))
            }
            var stats: [SourceStats] = []
            var zonesBySource: [String: [[PersonZone]?]] = [:]
            for s in sources {
                let spec = s.spec
                let z = zones(frames) { t in s.geometry(t).map { (CourtZoneClassifier(geometry: $0.0, spec: spec, settings: .init()), $0.1) } }
                zonesBySource[s.name] = z
                stats.append(Self.stats(frames, z, source: s.name, confirmed: s.confirmed, audit: auditTicks))
                for (f, fz) in zip(frames, z) {
                    guard let fz else { continue }
                    for (p, pz) in zip(f.persons, fz) {
                        csv.append([rec.recordingId, f.interval, "\(f.tick)", String(format: "%.3f", f.t), s.name, "\(p.track)", p.state.rawValue, pz.foot,
                                    pz.u.map { String(format: "%.4f", $0) } ?? "", pz.v.map { String(format: "%.4f", $0) } ?? "", pz.raw.rawValue,
                                    pz.zone.rawValue, pz.uncertain ? "1" : "0", pz.why.joined(separator: "|"), p.court.rawValue].joined(separator: ","))
                    }
                }
            }

            // Pictures.
            let display = sources.first { $0.confirmed } ?? sources.first { $0.name.hasSuffix(CourtProposal.Method.combined.rawValue) }
                ?? sources.first { $0.name.hasSuffix(CourtProposal.Method.courtLines.rawValue) } ?? sources.first
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: footage))
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            func picture(_ f: PlayerFeatures.Frame) async -> CGImage? { try? await gen.image(at: CMTime(seconds: f.t, preferredTimescale: 600)).image }
            var panelPath: String?
            let active = rec.intervals.first { $0.kind == .activePlay }?.name ?? rec.intervals.first?.name
            let activeFrames = frames.enumerated().filter { $0.element.interval == active && $0.element.masks.ran }
            if let (i, f) = activeFrames.isEmpty ? nil : activeFrames[activeFrames.count / 2], let image = await picture(f) {
                let z = display.flatMap { zonesBySource[$0.name]?[i] }
                if let panel = comparisonPanel(image, frame: f, recording: rec, segment: seg0, confirmedFile: lookup.unusable == nil ? lookup.file : nil,
                                               zones: z, zoneSource: display?.name), let jpeg = PlayerOverlay.jpeg(panel) {
                    panelPath = "panels/\(rec.recordingId).jpg"
                    try jpeg.write(to: out.appendingPathComponent(panelPath!))
                }
            }
            var auditImages: [String] = []
            for (i, f) in frames.enumerated() where auditTicks[f.tick] != nil && f.masks.ran {
                guard let image = await picture(f), let d = display, let g = d.geometry(f.t) else { continue }
                let z = zonesBySource[d.name]?[i]
                let banner = d.confirmed ? "confirmed court" : "UNCONFIRMED \(d.name.replacingOccurrences(of: "unconfirmed ", with: "")) — not reviewed by a person"
                if let composed = PlayerOverlay.compose(image, frame: f, recording: rec.recordingId, net: rec.net, lane: nil, options: .init(),
                                                        court: (g.0, d.spec, d.confirmed ? PlayerLabModel.courtColor(.confirmed) : PlayerLabModel.courtColor(.proposal), !d.confirmed),
                                                        zones: z?.map(Optional.some)),
                   let withBanner = bannered(composed, banner), let jpeg = PlayerOverlay.jpeg(withBanner) {
                    let path = "audit/\(rec.recordingId)_\(f.interval)_\(f.tick).jpg"
                    try jpeg.write(to: out.appendingPathComponent(path))
                    auditImages.append(path)
                }
            }
            let props = (seg0?.latestProposals ?? []).map { p in
                ProposalSummary(method: p.method.rawValue, confidence: p.confidence, ms: p.ms,
                                points: Dictionary(uniqueKeysWithValues: CourtLayout.Role.allCases.map { ($0.rawValue, p.geometry[$0].status.rawValue) }),
                                pointSources: p.pointSources, uncertainty: p.uncertainty, geometry: p.geometry)
            }
            let confirmedFirst = lookup.unusable == nil ? lookup.file?.segments.first { $0.confirmation?.method == CourtConfirmation.personMethod } : nil
            reports.append(RecordingReport(recordingId: rec.recordingId, surface: rec.surface, camera: rec.camera,
                                           calibration: lookup.unusable == nil ? "confirmed" : "\(calibration): \(lookup.unusable!)",
                                           proposals: props, proposalNotes: notes, sources: stats, panel: panelPath, lines: linesImage, auditImages: auditImages,
                                           againstConfirmed: confirmedFirst.flatMap { s in
                                               s.confirmation.map { against($0, proposals: s.latestProposals, w: rec.decoded.width, h: rec.decoded.height) }
                                           }))
            log("✅ \(rec.recordingId): " + stats.map { "\($0.source) in-play \(String(format: "%.2f", $0.inPlayPerFrame))/frame" }.joined(separator: " · "))
        }
        struct Report: Codable {
            var schema: String, createdAt: String, run: String, experiment: String, codeSha: String?, propose: Bool, audit: String?
            var settings: [String: String]
            var note: String
            var recordings: [RecordingReport]
        }
        let r = Report(schema: "court_pilot_v1", createdAt: RallyClassifierExporter.iso(Date()), run: runName, experiment: experiment.path, codeSha: codeSha,
                       propose: propose, audit: auditCSV?.path, settings: CourtZoneClassifier.Settings().described,
                       note: "A source named 'unconfirmed …' is an automatic proposal no person has reviewed: its zones are not evidence.",
                       recordings: reports)
        try RallyClassifierExporter.encode(r, pretty: true).write(to: out.appendingPathComponent("summary.json"))
        try Data((csv.joined(separator: "\n") + "\n").utf8).write(to: out.appendingPathComponent("zones/zones.csv"))
        return out
    }

    // MARK: - Pictures

    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func bannered(_ image: CGImage, _ text: String) -> CGImage? {
        guard let ctx = context(image.width, image.height) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        PlayerOverlay.text(text, at: CGPoint(x: 6, y: 6), size: 13, color: CGColor(red: 1, green: 0.85, blue: 0.3, alpha: 1), in: ctx)
        return ctx.makeImage()
    }

    /// The median picture with the line evidence in red and each proposal's court.
    static func linesPicture(_ median: CourtRGBImage, evidence: CourtProposer.LineEvidence?, proposals: [CourtProposal], frames: Int) -> CGImage? {
        guard let base = median.cgImage, let ctx = context(median.width, median.height) else { return nil }
        let w = CGFloat(median.width), h = CGFloat(median.height)
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let ev = evidence {
            ctx.setFillColor(CGColor(red: 1, green: 0.1, blue: 0.1, alpha: 0.75))
            for i in 0..<(ev.width * ev.height) where ev.response[i] > ev.threshold {
                ctx.fill(CGRect(x: CGFloat(i % ev.width), y: h - 1 - CGFloat(i / ev.width), width: 1, height: 1))
            }
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 0, alpha: 0.8))
            ctx.setLineWidth(1)
            for (a, b) in ev.found { ctx.move(to: CGPoint(x: a.x, y: h - a.y)); ctx.addLine(to: CGPoint(x: b.x, y: h - b.y)) }
            ctx.strokePath()
        }
        for p in proposals {
            PlayerOverlay.drawCourt(p.geometry, spec: .indoor, w: w, h: h, color: methodColor(p.method), dashed: true, ctx: ctx)
        }
        PlayerOverlay.text("median of \(frames) frames · red: line evidence · yellow: lines the search chose", at: CGPoint(x: 4, y: 4),
                           size: 10, color: CGColor(gray: 1, alpha: 1), in: ctx)
        return ctx.makeImage()
    }

    static func methodColor(_ m: CourtProposal.Method) -> CGColor {
        switch m {
        case .netGuided: return CGColor(red: 1, green: 0.55, blue: 0.1, alpha: 1)
        case .courtLines: return CGColor(red: 0.2, green: 0.9, blue: 1, alpha: 1)
        case .combined: return CGColor(red: 1, green: 0.3, blue: 0.9, alpha: 1)
        }
    }

    /// Four panels: the frame; the proposals; the confirmed court (or "not reviewed"); the zones.
    static func comparisonPanel(_ image: CGImage, frame f: PlayerFeatures.Frame, recording rec: PlayerFeatures.Recording, segment: CourtSegment?,
                                confirmedFile: CourtCalibrationFile?, zones: [PersonZone]?, zoneSource: String?) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = context(w * 2, h * 2) else { return nil }
        func panel(_ col: Int, _ row: Int, _ draw: (CGContext) -> Void, _ title: String) {
            guard let sub = context(w, h) else { return }
            sub.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            draw(sub)
            PlayerOverlay.text(title, at: CGPoint(x: 6, y: CGFloat(h) - 18), size: 12, color: CGColor(gray: 1, alpha: 1), in: sub)
            if let img = sub.makeImage() { ctx.draw(img, in: CGRect(x: col * w, y: (1 - row) * h, width: w, height: h)) }
        }
        let W = CGFloat(w), H = CGFloat(h)
        panel(0, 0, { _ in }, "\(rec.recordingId) · t=\(String(format: "%.1f", f.t)) s · original")
        panel(1, 0, { c in
            for p in segment?.latestProposals ?? [] {
                PlayerOverlay.drawCourt(p.geometry, spec: CourtSpec.standard(surface: rec.surface), w: W, h: H, color: methodColor(p.method), dashed: true, ctx: c)
            }
        }, "automatic: " + ((segment?.latestProposals ?? []).map { "\($0.method.label) \(String(format: "%.2f", $0.confidence))" }.joined(separator: " · ")) +
           "  (orange net-guided, cyan lines, magenta combined)")
        panel(0, 1, { c in
            if let cf = confirmedFile, let conf = cf.confirmed(at: f.t) {
                PlayerOverlay.drawCourt(conf.geometry, spec: conf.spec, w: W, h: H, color: PlayerLabModel.courtColor(.confirmed), dashed: false, ctx: c)
            } else {
                c.setFillColor(CGColor(gray: 0, alpha: 0.45)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
                PlayerOverlay.text("NOT REVIEWED — no person has confirmed this court", at: CGPoint(x: W * 0.12, y: H / 2), size: 18,
                                   color: CGColor(red: 1, green: 0.85, blue: 0.3, alpha: 1), in: c)
            }
        }, "person-confirmed court")
        panel(1, 1, { c in
            guard let zones, let composed = PlayerOverlay.compose(image, frame: f, recording: rec.recordingId, net: nil, lane: nil,
                                                                  options: { var o = PlayerOverlay.Options(); o.header = false; o.skeletons = false; return o }(),
                                                                  court: nil, zones: zones.map(Optional.some)) else { return }
            c.draw(composed, in: CGRect(x: 0, y: 0, width: W, height: H))
        }, "zones vs \(zoneSource ?? "no court")")
        return ctx.makeImage()
    }
}
