//
//  PlayerFeaturesRun.swift
//  RallyLab
//
//  `RallyLab --player-lab-run <experiment> --source-project <project> --plan <plan.json> --run <name>`:
//  the player-feasibility research run (Phase P0, docs/ml-roadmap/PLAYER_POSE_FEASIBILITY_P0_2026-11-08.md).
//  It works in a separate **experiment folder** and only reads the source project: nothing
//  of the source project — sessions, marks, splits, footage properties, manifests, the
//  exposure ledger — is ever written, and the project is never opened by ProjectsModel
//  (which can rewrite derived files). One operation holds every guard, so no caller can
//  skip them:
//
//   1. the plan is bounded: at most `maxRecordings` recordings, intervals of at most
//      `maxIntervalSec`, `maxTotalSec` in all, a sampling rate of at most `maxHz` —
//      a pilot, never bulk processing;
//   2. the source project's split manifest as written (current — a stale one is refused,
//      never rebuilt here — and audited: no hard finding) and the withheld closure
//      (ReservedVideos.lineageWithheldNames ∪ reservedNames; an empty closure is refused):
//      a planned recording in it, sharing an identity or alias group with it
//      (LineagePackage.isolation), or outside a development split is refused — before
//      any video is opened;
//   3. each recording admitted (SourceRegistry) and eligible for the rally classifier
//      (TrainingEligibility: standard or restricted), whose features these would be;
//   4. footage: the recording's local scrub proxy (the originals sit on the footage share,
//      which is not touched) is copied byte for byte into the experiment's footage/ and
//      only the copy is decoded; by content, no copy may be a withheld recording's, known
//      from project.json and from the withheld recordings' own local proxies (hashed, never
//      decoded); a withheld recording whose content can't be recognised here stops the run;
//   5. the experiment's own exposure ledger (`<experiment>/manifests/exposure-log.json`,
//      kind `detector_evaluation`) for every planned recording, before the first frame is
//      decoded — the source project's ledger is not written (owner, 2026-11-08);
//   6. per recording, the plan's detector (Apple Vision; the research RTMDet + RTMPose models read from
//      <experiment>/models/rtm; or RF-DETR Small/Medium with Vision pose or the RF-DETR keypoint preview, from <experiment>/models/rfdetr) through its tiling on the sampled frames off the main actor, the assembler, the
//      frame lines; overlays and the audit sample in diagnostics/; the manifest last, then
//      the staging folder moved to `<experiment>/runs/<name>`.
//
//  No model is trained. The Player Lab window (PlayerLabView) reads the run folders.
//

import CryptoKit
import Foundation

enum PlayerFeaturesRun {
    static let maxRecordings = 12
    static let maxIntervalSec = 60.0
    static let maxTotalSec = 600.0
    static let maxHz = 10.0
    static let developmentSplits: Set<DatasetSplit> = [.train, .devVal, .tune]

    struct Plan: Codable, Equatable {
        struct Item: Codable, Equatable {
            var recordingId: String
            var intervals: [PlayerFeatures.Interval]
        }
        var hz: Double = 5
        /// `scrub_proxy`: the recording's local scrub proxy, copied into the experiment. The only source: an original
        /// would be read from the footage share.
        var source: String = "scrub_proxy"
        /// Every n-th sampled frame gets an overlay.
        var overlayEvery: Int = 5
        /// Overlay frames per interval put in the audit sample.
        var auditPerInterval: Int = 2
        var recordings: [Item]
        /// `vision` (default: Apple Vision, the P0 baseline), `rtm` (RTMDet + RTMPose from `<experiment>/models/rtm`,
        /// research only), `rfdetr-small` / `rfdetr-medium` (RF-DETR from `<experiment>/models/rfdetr`, Apache-2.0
        /// checkpoints, with Vision pose on each person's crop) or `rfdetr-keypoint` (RF-DETR keypoint preview: people and joints in one pass). Optional so a plan written before it existed still reads.
        var detector: String?
        /// Columns and rows of overlapping tiles (default 1×1: the whole frame).
        var tiles: [Int]?
        var tileOverlap: Double?
        /// The person score (RTMDet or RF-DETR sigmoid) a detection needs (default 0.3); Vision ignores it.
        var minScore: Double?

        var detectorName: String { detector ?? "vision" }
        static let detectors = ["vision", "rtm"] + RFDETRPlayerDetector.Size.allCases.map { "rfdetr-\($0.rawValue)" }
        var tiling: PlayerTiling { PlayerTiling(cols: tiles?.first ?? 1, rows: tiles?.dropFirst().first ?? 1, overlap: tileOverlap ?? 0.15) }
        var personMinScore: Double { minScore ?? 0.3 }
    }

    enum Failure: LocalizedError, Equatable {
        case badName(String)
        case planInvalid([String])
        case noManifest
        case staleManifest(String)
        case sourceIsExperiment
        case copyMismatch(String)
        case emptyClosure
        case refused([String])
        case protectedContentUnknown(String)
        case withheldContent([String])
        case exists(String)
        case write(String)

        var errorDescription: String? {
            switch self {
            case .badName(let n): return "\(n) is not a usable run name (letters, digits, - _ . only)."
            case .planInvalid(let e): return "The plan is refused: " + e.joined(separator: "; ")
            case .noManifest: return "The source project has no split manifest (manifests/manifest.json); this run never builds one."
            case .staleManifest(let why): return "The source project's split manifest is stale (\(why)); this run never rebuilds it in the source project."
            case .sourceIsExperiment: return "The experiment folder is, or is inside, the source project: an experiment never writes into the project it reads."
            case .copyMismatch(let n): return "The copy of \(n)'s scrub proxy differs from its source: nothing is decoded."
            case .emptyClosure: return "The withheld closure is empty: nothing proves a withheld recording is kept out, so nothing is read."
            case .refused(let r): return "Refused before any video was opened: " + r.joined(separator: "; ")
            case .protectedContentUnknown(let n): return "Withheld recording \(n) can't be recognised by content on this Mac (no stored file fingerprint and no local copy to compare with): nothing is read."
            case .withheldContent(let r): return "The file to decode is a withheld recording's: " + r.joined(separator: ", ")
            case .exists(let p): return "\(p) exists already: choose another run name."
            case .write(let why): return "Writing failed: \(why)"
            }
        }
    }

    /// The bounded-pilot rules, before anything is read.
    static func validate(_ plan: Plan) -> [String] {
        var e: [String] = []
        if plan.recordings.isEmpty { e.append("no recordings") }
        if plan.recordings.count > maxRecordings { e.append("\(plan.recordings.count) recordings > \(maxRecordings)") }
        if !(plan.hz > 0 && plan.hz <= maxHz) { e.append("hz \(plan.hz) outside (0, \(maxHz)]") }
        if plan.source != "scrub_proxy" { e.append("source \(plan.source): only scrub_proxy is supported (originals are on the footage share)") }
        if plan.overlayEvery < 1 { e.append("overlayEvery must be ≥ 1") }
        if !Plan.detectors.contains(plan.detectorName) { e.append("detector \(plan.detectorName) is not one of \(Plan.detectors.joined(separator: ", "))") }
        if let t = plan.tiles, t.count != 2 || !t.allSatisfy({ (1...4).contains($0) }) { e.append("tiles must be [columns, rows], each 1–4") }
        if !(0..<0.5).contains(plan.tiling.overlap) { e.append("tileOverlap must be in [0, 0.5)") }
        if !(0...1).contains(plan.personMinScore) { e.append("minScore must be in [0, 1]") }
        if Set(plan.recordings.map(\.recordingId)).count != plan.recordings.count { e.append("a recording is listed twice") }
        var total = 0.0
        for r in plan.recordings {
            if r.intervals.isEmpty { e.append("\(r.recordingId): no intervals") }
            if Set(r.intervals.map(\.name)).count != r.intervals.count { e.append("\(r.recordingId): interval names repeat") }
            for i in r.intervals {
                let len = i.endSec - i.startSec
                if !(i.startSec >= 0 && len > 0) { e.append("\(r.recordingId)/\(i.name): empty or negative interval") }
                if len > maxIntervalSec { e.append("\(r.recordingId)/\(i.name): \(len) s > \(maxIntervalSec) s") }
                if !RallyClassifierExporter.isSafeName(i.name) { e.append("\(r.recordingId)/\(i.name): unsafe interval name") }
                total += max(0, len)
            }
            for (a, b) in zip(r.intervals.sorted { $0.startSec < $1.startSec }, r.intervals.sorted { $0.startSec < $1.startSec }.dropFirst()) where b.startSec < a.endSec {
                e.append("\(r.recordingId): \(a.name) and \(b.name) overlap")
            }
        }
        if total > maxTotalSec { e.append("\(total) s of video in all > \(maxTotalSec) s") }
        return e
    }

    /// Steps 2–3 on already-loaded facts: which planned recordings may be read, or every reason not.
    static func admissionRefusals(planned: [String], closure: Set<String>, eligible: [LineagePackage.Eligible],
                                  registry: [String: SourceRegistry.Source], sessions: Set<String>) -> [String] {
        let byName = Dictionary(eligible.map { ($0.video, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [String] = []
        for name in planned {
            if closure.contains(name) { out.append("\(name) is withheld (D-002/D-017 closure)"); continue }
            guard let e = byName[name] else { out.append("\(name) is not an isolated development recording in the split manifest"); continue }
            guard developmentSplits.contains(e.split) else { out.append("\(name): split \(e.split.rawValue) is not a development split"); continue }
            guard let s = registry[name] else { out.append("\(name) is not in the source registry"); continue }
            guard s.admission == .admitted else { out.append("\(name): admission \(s.admission.rawValue)"); continue }
            let v = s.eligibility[.rallyClassifier]
            guard [.standard, .restricted].contains(v.level) else { out.append("\(name): rally classifier \(v.level.rawValue) — \(v.reasons.joined(separator: "; "))"); continue }
            guard sessions.contains(name) else { out.append("\(name) has no dataset session"); continue }
        }
        return out
    }

    /// The excluded time of a recording on the tick base: cut ranges and footage-properties spans whose trait breaks time
    /// (proposed spans exclude exactly like confirmed ones; rejected ones count for nothing).
    static func excludedSpans(cuts: [CutRange], properties: FootageProperties.File?, durationSec: Double) -> (cuts: [PlayerFeatures.TickSpan], breaks: [PlayerFeatures.TickSpan]) {
        let c = cuts.map { PlayerFeatures.TickSpan(startTick: PlayerFeatures.tick($0.start), endTick: PlayerFeatures.tick($0.end), kind: "cut") }
        let b = (properties?.activeSpans ?? []).filter { $0.traits.contains(where: \.breaksTime) }.map {
            PlayerFeatures.TickSpan(startTick: PlayerFeatures.tick($0.start ?? 0), endTick: PlayerFeatures.tick($0.end ?? durationSec), kind: "time_break")
        }
        return (c, b)
    }

    static func exclusion(at t: Double, in spans: [PlayerFeatures.TickSpan]) -> String? {
        let k = PlayerFeatures.tick(t)
        return spans.first { $0.startTick <= k && k < $0.endTick }?.kind
    }

    struct Result {
        var folder: URL
        var manifestSha256: String
        var frames: Int
    }

    private static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func experimentFootage(_ experiment: URL, _ recording: String) -> URL {
        experiment.appendingPathComponent("footage", isDirectory: true).appendingPathComponent("\(recording).mp4")
    }

    @discardableResult
    static func run(sourceProject projectDir: URL, experiment: URL, name: String, plan: Plan, codeSha: String, tool: String,
                    now: Date = Date(), log: @escaping @Sendable (String) -> Void) async throws -> Result {
        let fm = FileManager.default
        guard RallyClassifierExporter.isSafeName(name) else { throw Failure.badName(name) }
        let problems = validate(plan)
        guard problems.isEmpty else { throw Failure.planInvalid(problems) }
        let src = projectDir.standardizedFileURL.resolvingSymlinksInPath().path, exp = experiment.standardizedFileURL.resolvingSymlinksInPath().path
        guard exp != src, !exp.hasPrefix(src + "/"), !src.hasPrefix(exp + "/") else { throw Failure.sourceIsExperiment }
        let out = experiment.appendingPathComponent("runs", isDirectory: true)
        let final = out.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: final.path) else { throw Failure.exists(final.path) }

        // 2. Manifest (as written), audit, closure, isolation — before any video is opened.
        let manifestURL = projectDir.appendingPathComponent("manifests/manifest.json")
        guard let manifest = try DatasetSplitManifest.readStrict(from: manifestURL) else { throw Failure.noManifest }
        let current = RallyClassifierExporter.currentHashes(projectDir)
        for (label, have, nowHash) in [("project.json", manifest.hashes.projectJson, current.projectJson),
                                       ("sessions", manifest.hashes.sessions, current.sessions),
                                       ("validation.json", manifest.hashes.validationJson, current.validationJson)] {
            guard let have, let nowHash, have == nowHash else { throw Failure.staleManifest("\(label) changed since it was built") }
        }
        let closure = try ReservedVideos.lineageWithheldNames(in: projectDir).union(try ReservedVideos.reservedNames(in: projectDir))
        guard !closure.isEmpty else { throw Failure.emptyClosure }
        let leakage = DatasetAudit.run(manifest: manifest, now: now)
        let (_, eligible) = try LineagePackage.isolation(manifest: manifest, audit: leakage, withheldClosure: closure)
        let registry = try SourceRegistry.load(root: projectDir, now: now).byVideo
        let sessionsList = try DatasetStore(root: projectDir).loadSessionsStrict()
        let sessions = Dictionary(sessionsList.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let planned = plan.recordings.map(\.recordingId)
        let refusals = admissionRefusals(planned: planned, closure: closure, eligible: eligible, registry: registry, sessions: Set(sessions.keys))
        guard refusals.isEmpty else { throw Failure.refused(refusals) }

        // 4. Footage: the local proxy, copied; the content check on the copies.
        let sources = ReservedVideos.sources(in: projectDir)
        func proxy(_ session: VideoSession) -> URL { ScrubProxy.url(for: URL(fileURLWithPath: session.sourcePath), in: projectDir) }
        var protected = Set<String>()
        for w in closure.sorted() {
            var mine = Set<String>()
            if let f = sources[w]?.fingerprint, f.hasPrefix("file:") { mine.insert(f) }
            if let s = sessions[w], fm.fileExists(atPath: proxy(s).path), let f = ProjectsModel.fileFingerprint(atPath: proxy(s).path) { mine.insert(f) }
            // A withheld recording with no session has no proxy; its stored file identity is what a copy would match.
            guard !mine.isEmpty || sessions[w] == nil else { throw Failure.protectedContentUnknown(w) }
            protected.formUnion(mine)
        }
        var missing: [String] = []
        for name in planned where !fm.fileExists(atPath: proxy(sessions[name]!).path) { missing.append("\(name): no local scrub proxy") }
        guard missing.isEmpty else { throw Failure.refused(missing) }
        let sourcePrints = Dictionary(uniqueKeysWithValues: planned.map { ($0, ProjectsModel.readFileFingerprint(atPath: proxy(sessions[$0]!).path) ?? "") })
        let copies = planned.filter { protected.contains(sourcePrints[$0]!) }
        guard copies.isEmpty else { throw Failure.withheldContent(copies) }
        var decodeFiles: [String: (url: URL, fingerprint: String)] = [:]
        do { try fm.createDirectory(at: experiment.appendingPathComponent("footage", isDirectory: true), withIntermediateDirectories: true) }
        catch { throw Failure.write(error.localizedDescription) }
        for name in planned {
            let copy = experimentFootage(experiment, name)
            if ProjectsModel.readFileFingerprint(atPath: copy.path) != sourcePrints[name] {
                try? fm.removeItem(at: copy)
                do { try fm.copyItem(at: proxy(sessions[name]!), to: copy) } catch { throw Failure.write(error.localizedDescription) }
            }
            // The whole file, not the head-and-tail fingerprint: the copy must be the proxy.
            guard let a = DatasetSplitManifest.sha256(of: copy), a == DatasetSplitManifest.sha256(of: proxy(sessions[name]!)) else { throw Failure.copyMismatch(name) }
            decodeFiles[name] = (copy, sourcePrints[name]!)
        }

        // 5. The ledger, before the first frame.
        let detector: PlayerDetector
        let detectorRef: String
        do {
            let models = experiment.appendingPathComponent("models", isDirectory: true)
            if plan.detectorName == "rtm" {
                detector = try await RTMPlayerDetector(models: models.appendingPathComponent("rtm", isDirectory: true), minScore: plan.personMinScore)
                detectorRef = "rtmdet-m+rtmpose-m"
            } else if plan.detectorName.hasPrefix("rfdetr-"),
                      let size = RFDETRPlayerDetector.Size(rawValue: String(plan.detectorName.dropFirst("rfdetr-".count))) {
                detector = try await RFDETRPlayerDetector(models: models.appendingPathComponent("rfdetr", isDirectory: true), size: size,
                                                          minScore: plan.personMinScore)
                detectorRef = size == .keypoint ? "rfdetr-keypoint-preview" : "rfdetr-\(size.rawValue)+vision-pose-r1"
            } else {
                detector = VisionPlayerDetector()
                detectorRef = "vision-rect-r2+pose-r1"
            }
        } catch { throw Failure.refused(["the \(plan.detectorName) detector can't be loaded: \(error.localizedDescription)"]) }
        let tiling = plan.tiling
        let ref = "\(PlayerFeatures.ledgerRef) \(name) \(detectorRef) tiles=\(tiling.cols)x\(tiling.rows) \(plan.hz)Hz \(plan.source)"
        try ExposureLog.record(videos: Set(planned), kind: .detectorEvaluation, ref: ref,
                               note: "player-feasibility research P0 (D-034, proposed): Apple Vision people and pose on sampled frames of \(manifest.project); not training, not rally scoring; the source project's ledger is not written (owner, 2026-11-08)",
                               in: experiment, now: now)
        log("✅ experiment ledger: \(planned.count) recording(s) recorded as detector_evaluation (\(ref)) in \(ExposureLog.url(in: experiment).path)")

        // 6. Extraction.
        let staging = out.appendingPathComponent(".staging-\(name)", isDirectory: true)
        try? fm.removeItem(at: staging)
        let framesDir = staging.appendingPathComponent("features/frames", isDirectory: true)
        let overlaysDir = staging.appendingPathComponent("diagnostics/overlays", isDirectory: true)
        do {
            try fm.createDirectory(at: framesDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: overlaysDir, withIntermediateDirectories: true)
        } catch { throw Failure.write(error.localizedDescription) }

        let netLabels = (try? NetLabelStore(projectDir: projectDir).load()) ?? [:]
        let properties = try FootageProperties.Store(root: projectDir).loadAll().records
        let manifestRows = Dictionary(manifest.videos.map { ($0.video, $0) }, uniquingKeysWith: { a, _ in a })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var recordings: [PlayerFeatures.Recording] = []
        var summary: [PlayerFeaturesSummary.Stats] = []
        var runtime: [[String: Any]] = []
        var audit: [String] = ["recording,interval,tick,t,overlay,persons,in_court,poses,unmatched_poses,visible_on_court_players,detected_on_court_players,missed_on_court_players,false_on_court_detections,off_court_detections,identity_switches_vs_previous_sampled,poses_plausible,reviewer,notes"]
        var totalFrames = 0
        let usageStart = PlayerRunUsage.now()

        for item in plan.recordings {
            let session = sessions[item.recordingId]!, src = registry[item.recordingId]!, row = manifestRows[item.recordingId]
            let file = decodeFiles[item.recordingId]!
            let facts = try await PlayerVisionExtractor.facts(of: file.url)
            let (cuts, breaks) = excludedSpans(cuts: session.cutRanges, properties: properties[item.recordingId], durationSec: facts.durationSec)
            let net: PlayerFeatures.NetGeometry? = netLabels[item.recordingId].map { l in
                let q = l.corners ?? NetQuad(rect: CGRect(x: l.box.x, y: l.box.y, width: l.box.w, height: l.box.h))
                return PlayerFeatures.NetGeometry(corners: q.points.map { [Double($0.x), Double($0.y)] },
                                                  origin: l.corners == nil ? "person_label_box_only" : "person_label", labelFingerprint: l.fingerprint)
            }
            let (lane, laneWhy) = PlayerCourtLane.make(net: net, camera: src.camera, recordingFingerprint: sources[item.recordingId]?.fingerprint)
            var assembler = PlayerFrameAssembler(excluded: cuts + breaks, lane: lane)
            var lines = Data()
            var frameCount = 0
            var assembled: [PlayerFeatures.Frame] = []
            let recOverlays = overlaysDir.appendingPathComponent(item.recordingId, isDirectory: true)
            try fm.createDirectory(at: recOverlays, withIntermediateDirectories: true)
            var rectMs: [Double] = [], poseMs: [Double] = []
            let wallStart = Date()
            for interval in item.intervals.sorted(by: { $0.startSec < $1.startSec }) {
                guard interval.endSec <= facts.durationSec + 1e-6 else { throw Failure.planInvalid(["\(item.recordingId)/\(interval.name) ends after the recording (\(facts.durationSec) s)"]) }
                let every = plan.overlayEvery
                let excludedTime = cuts + breaks
                let raws = try await Task.detached(priority: .userInitiated) {
                    try await PlayerVisionExtractor.run(url: file.url, facts: facts, interval: interval, hz: plan.hz, detector: detector, tiling: tiling,
                                                        excluded: { exclusion(at: $0, in: excludedTime) }, wantsImage: { $0 % every == 0 })
                }.value
                var overlaid: [(PlayerFeatures.Frame, String)] = []
                for raw in raws {
                    let frame = assembler.add(raw)
                    assembled.append(frame)
                    lines.append(try encoder.encode(frame))
                    lines.append(0x0A)
                    frameCount += 1
                    if let r = frame.ms["rect"] { rectMs.append(r) }
                    if let p = frame.ms["pose"] { poseMs.append(p) }
                    if let image = raw.image, let jpeg = PlayerOverlay.render(image, frame: frame, recording: item.recordingId, net: net, lane: lane) {
                        let fileName = "\(interval.name)_\(frame.tick).jpg"
                        try jpeg.write(to: recOverlays.appendingPathComponent(fileName))
                        overlaid.append((frame, "diagnostics/overlays/\(item.recordingId)/\(fileName)"))
                    }
                }
                // The audit sample: evenly spaced overlay frames, deterministic.
                let n = min(plan.auditPerInterval, overlaid.count)
                for j in 0..<n {
                    let (f, path) = overlaid[(2 * j + 1) * overlaid.count / (2 * n)]
                    audit.append([item.recordingId, interval.name, "\(f.tick)", String(format: "%.3f", f.t), path, "\(f.persons.count)",
                                  "\(f.scene.inCourt)", "\(f.persons.filter { $0.pose != nil }.count)", "\(f.unmatchedPoses.count)",
                                  "", "", "", "", "", "", "", "", ""].joined(separator: ","))
                }
                log("   \(item.recordingId)/\(interval.name): \(raws.count) sampled frames")
            }
            let framesName = "frames/\(item.recordingId).jsonl"
            try lines.write(to: staging.appendingPathComponent("features/\(framesName)"))
            totalFrames += frameCount
            let elig = src.eligibility
            recordings.append(PlayerFeatures.Recording(
                recordingId: item.recordingId, groupId: src.aliasGroup ?? item.recordingId, split: (row?.split ?? src.split).rawValue,
                surface: src.surface, camera: src.camera, cardOrientation: row?.orientation, sourceId: src.sourceId,
                fingerprint: sources[item.recordingId]?.fingerprint,
                decoded: PlayerFeatures.DecodedFile(kind: plan.source, fileName: file.url.lastPathComponent, fingerprint: file.fingerprint,
                                                    width: facts.uprightWidth, height: facts.uprightHeight, orientation: facts.orientation.rawValue,
                                                    nominalFrameRate: facts.nominalFrameRate, durationSec: facts.durationSec),
                aspect: facts.uprightHeight > 0 ? Double(facts.uprightWidth) / Double(facts.uprightHeight) : 0,
                recordingType: src.recordingType.rawValue,
                eligibility: Dictionary(uniqueKeysWithValues: TrainingEligibility.Model.allCases.map { ($0.rawValue, elig[$0].level.rawValue) }),
                eligibilityReasons: elig[.rallyClassifier].reasons, net: net, courtUnknownReason: laneWhy,
                cutRanges: cuts, timeBreakingSpans: breaks, intervals: item.intervals.sorted { $0.startSec < $1.startSec },
                framesFile: framesName, framesSha256: sha256Hex(lines), frameCount: frameCount))
            summary += PlayerFeaturesSummary.recording(recordings[recordings.count - 1], frames: assembled)
            func pct(_ v: [Double], _ q: Double) -> Any { PlayerFeaturesSummary.quantile(v, q) ?? NSNull() }
            runtime.append(["recording": item.recordingId, "frames": frameCount, "wallSec": Date().timeIntervalSince(wallStart),
                            "rectMsMedian": pct(rectMs, 0.5), "rectMsP95": pct(rectMs, 0.95),
                            "poseMsMedian": pct(poseMs, 0.5), "poseMsP95": pct(poseMs, 0.95)])
            log("✅ \(item.recordingId): \(frameCount) frames\(laneWhy.map { " · court unknown: \($0)" } ?? "")")
        }
        let usage = PlayerRunUsage.now().since(usageStart)

        let withheldNames = closure.sorted()
        let withheldSourceIds = Set(closure.compactMap { sources[$0]?.sourceId }.filter { !$0.isEmpty }).sorted()
        let withheldPrints = protected.union(closure.compactMap { sources[$0]?.fingerprint }).sorted()
        let closureText = (withheldNames + ["--"] + withheldSourceIds + ["--"] + withheldPrints).joined(separator: "\n")
        let manifestOut = PlayerFeatures.Manifest(
            schemaVersion: PlayerFeatures.schemaVersion, createdAt: RallyClassifierExporter.iso(now),
            generator: ["tool": tool, "codeSha": codeSha, "run": name, "decoded": plan.source, "sourceProject": projectDir.path,
                        "experiment": experiment.path, "ledger": ExposureLog.url(in: experiment).path],
            project: manifest.project,
            splitManifest: ["projectJson": manifest.hashes.projectJson ?? "", "sessions": manifest.hashes.sessions ?? "",
                            "validationJson": manifest.hashes.validationJson ?? "", "manifestJson": DatasetSplitManifest.sha256(of: manifestURL) ?? ""],
            withheld: PlayerFeatures.Withheld(names: withheldNames, sourceIds: withheldSourceIds, fingerprints: withheldPrints,
                                              closureSha256: sha256Hex(Data(closureText.utf8))),
            timescale: PlayerFeatures.timescale, coordinateSpace: PlayerFeatures.coordinateSpace, jointNames: PlayerFeatures.jointNames,
            detector: detector.described.merging(tiling.described) { a, _ in a },
            sampling: ["hz": "\(plan.hz)", "rule": "first decoded frame at or after start + k/hz (presentation timestamps), never the same frame twice",
                       "tick": "round(t * 600)"],
            tracker: PlayerTracker.Settings().described.merging(PlayerFrameAssembler.Settings().described) { a, _ in a },
            court: PlayerCourtLane.Settings().described, derived: PlayerDerivedFeatures.Settings().described,
            recordings: recordings)
        do {
            let diagnostics = staging.appendingPathComponent("diagnostics", isDirectory: true)
            try Data((audit.joined(separator: "\n") + "\n").utf8).write(to: diagnostics.appendingPathComponent("audit-sample.csv"))
            let runtimeDoc: [String: Any] = ["recordings": runtime, "process": usage.dictionary, "frames": totalFrames,
                                             "gpu": "not measured: per-process GPU utilisation needs powermetrics (root), not used",
                                             "host": ProcessInfo.processInfo.hostName, "activeProcessors": ProcessInfo.processInfo.activeProcessorCount]
            try RallyClassifierExporter.encode(summary, pretty: true).write(to: diagnostics.appendingPathComponent("summary.json"))
            try JSONSerialization.data(withJSONObject: runtimeDoc, options: [.prettyPrinted, .sortedKeys]).write(to: diagnostics.appendingPathComponent("runtime.json"))
            let data = try RallyClassifierExporter.encode(manifestOut, pretty: true)
            try data.write(to: staging.appendingPathComponent("features/player-features-manifest.json"))
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: final)
            return Result(folder: final, manifestSha256: sha256Hex(data), frames: totalFrames)
        } catch { throw Failure.write(error.localizedDescription) }
    }
}

/// Process CPU time and peak memory, from getrusage.
struct PlayerRunUsage {
    var userSec: Double
    var systemSec: Double
    var maxResidentBytes: Int
    var wall: Date

    static func now() -> PlayerRunUsage {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func sec(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return PlayerRunUsage(userSec: sec(u.ru_utime), systemSec: sec(u.ru_stime), maxResidentBytes: Int(u.ru_maxrss), wall: Date())
    }

    func since(_ start: PlayerRunUsage) -> PlayerRunUsage {
        PlayerRunUsage(userSec: userSec - start.userSec, systemSec: systemSec - start.systemSec, maxResidentBytes: maxResidentBytes,
                       wall: Date(timeIntervalSince1970: wall.timeIntervalSince(start.wall)))
    }

    var dictionary: [String: Any] {
        let wallSec = wall.timeIntervalSince1970
        return ["cpuUserSec": userSec, "cpuSystemSec": systemSec, "wallSec": wallSec,
                "cpuCoresBusyMean": wallSec > 0 ? (userSec + systemSec) / wallSec : 0,
                "peakResidentMB": Double(maxResidentBytes) / 1_048_576,
                "note": "process-wide: includes Vision's CPU work; peak resident is the process maximum (ru_maxrss), not this run's increment"]
    }
}
