//
//  PilotDraw.swift
//  RallyLab
//
//  The 24-rally calibration pilot (D-004; EVENT_BOUNDARY_REVIEW_PROTOCOL.md §3, §6, §7):
//  the frozen draw and the audit of its results.
//
//  `--pilot-freeze` builds the pool (every development recording with all rallies
//  marked, the withheld closure refused as everywhere else), runs the pipeline once on
//  each (an exposure, recorded first), turns every legacy mark into a candidate with the
//  strata it can fill (short, long, far-end serve, auto-from-track start, selector-flagged
//  ambiguity, hard case), draws 8 per surface with a fixed seed — spreading over
//  independent recording groups — fixes each rally's evaluation window
//  [legacyStart − 5 s, legacyEnd + 5 s] and the blind-repeat set of 8, and writes the
//  record with the label-file hashes, the split-manifest hashes and the frozen raw and
//  padded predictions, before anyone looks at a frame. A record is never overwritten: a
//  new draw is a new file that names the one it supersedes.
//
//  `--boundary-audit` reads the latest record and the pool's rallyevents.json files and
//  writes boundary_audit.csv: one row per event (legacy time, reviewed interval, width,
//  flags, annotator, tool, the second review and its delta, adjudication, window
//  exceeded), with the per-surface offsets, the ambiguity rate and the repeat agreement
//  by platform pair (the Mac-vs-iPhone comparison on identical source frames). Reads only.
//

import CryptoKit
import Foundation

enum PilotDraw {
    static let size = 24
    static let perSurface = 8
    static let repeatCount = 8
    static let windowPad = 5.0
    static let shortMax = 4.0
    static let longMin = 12.0
    /// A hard case: the pipeline's serve contact and the legacy start disagree by more than this.
    static let hardCaseGap = 1.0
    /// Selector-flagged ambiguity: the ball seen in fewer than this share of the processed frames in
    /// the first second after the legacy start, or the mark within a second of the file's edge.
    static let ambiguousBallShare = 1.0 / 3
    /// Adjudication: a second review differing from the first by more than this (protocol §6).
    static let adjudicationGap = 0.1
    /// The strata per surface, in draw order (protocol §3).
    static let strata = ["short", "short", "long", "long", "farEnd", "autoFromTrack", "ambiguous", "hardCase"]
    /// What the attributes needing the pipeline's predictions are called in a dry run.
    static let predictionStrata: Set<String> = ["farEnd", "ambiguous", "hardCase"]

    // MARK: - Record

    struct Serve: Codable, Equatable {
        var toss: Double?
        var contact: Double
        var end: Double
        var approaching: Bool
    }

    struct Predictions: Codable, Equatable {
        /// The pipeline's decided rallies before padding (what the raw-boundary scorer compares).
        var clipsRaw: [[Double]]
        /// The clips the run itself cut (padded and joined as production does).
        var clipsPadded: [[Double]]
        var serves: [Serve]
    }

    struct PoolVideo: Codable, Equatable {
        var name: String
        var split: String
        var surface: String
        /// The independent recording group (clip card, alias group, uploader — transitively).
        var group: String
        var durationSec: Double?
        var marks: Int
        var labelsSHA256: String
        var predictions: Predictions?
        /// The recording's camera setup applied to the configuration, and the SHA-256 of the effective config.
        var cameraSetup: String?
        var effectiveConfigSHA256: String?
    }

    struct Candidate: Codable, Equatable {
        var video: String
        var surface: String
        var group: String
        var legacyIndex: Int
        var legacyStart: Double
        var legacyEnd: Double
        var legacyKind: String?
        /// The strata this rally can fill.
        var attributes: [String]
        var serveContact: Double?
        var serveApproaching: Bool?
        var ballSeenAtStart: Double?

        var duration: Double { legacyEnd - legacyStart }
    }

    struct Selected: Codable, Equatable {
        var video: String
        var legacyIndex: Int
        var surface: String
        var group: String
        var stratum: String
        /// When the stratum had no candidate left: the rally drawn in its place, and from which stratum pool.
        var substitutedFor: String?
        var legacyStart: Double
        var legacyEnd: Double
        /// [start, end] of the evaluation window, frozen from legacy information alone.
        var window: [Double]
        var repeatReview: Bool

        /// What the apps need of it (the shared blind rule, the phone's copy of the draw).
        var pilotWindow: PilotWindow {
            PilotWindow(video: video, legacyIndex: legacyIndex, legacyStart: legacyStart, legacyEnd: legacyEnd, window: window, stratum: stratum, repeatReview: repeatReview)
        }
    }

    struct Record: Codable, Equatable {
        var id: String
        var createdAt: String
        var project: String
        var seed: UInt64
        var status: String = "frozen"
        var annotationVersion: String = EventReview.annotationVersion
        var manifestHashes: DatasetSplitManifest.Hashes
        var model: String
        /// Content identities of the models actually used (name → digest of the model file or package), and the
        /// effective configuration as a reproducible snapshot with its SHA-256; per-recording camera overrides are
        /// on each pool video. Nothing here is implied by the split-manifest hashes.
        var modelDigests: [String: String] = [:]
        var configSnapshot: String = ""
        var configSHA256: String = ""
        var pool: [PoolVideo]
        var candidates: [Candidate]
        var selection: [Selected]
        /// Strata that could not be filled even by substitution, as "surface/stratum".
        var unfilled: [String]
        var supersedes: String?
        var dryRun: Bool
        var note: String?
    }

    enum Failure: LocalizedError {
        case exists([String])
        case noPool
        case unreadableLabels(String, String)

        var errorDescription: String? {
            switch self {
            case .exists(let names): return "a frozen pilot record exists already (\(names.joined(separator: ", "))); a new draw needs --new-draw and is recorded as superseding it"
            case .noPool: return "no eligible recording with every rally marked"
            case .unreadableLabels(let v, let why): return "\(v): rallylabels.json unreadable (\(why)) — nothing is drawn until it is read"
            }
        }
    }

    // MARK: - Pool

    struct PoolEntry {
        let session: VideoSession
        let marks: [RallyMarkRecord]
        let labelsSHA256: String
        let group: String
    }

    /// The pool: every session with all rallies marked that the Stage 1 review would open (the withheld
    /// closure refused by name, path and content), with its legacy marks read strictly — an unreadable
    /// label file fails the draw rather than shrinking the pool.
    static func pool(root: URL) throws -> [PoolEntry] {
        let withheld = try EventReview.withheldNames(in: root)
        let sessions = try DatasetStore(root: root).loadSessionsStrict()
        let groupOf = groups(root: root, sessions: sessions)
        var out: [PoolEntry] = []
        for s in sessions.sorted(by: { $0.name < $1.name }) where s.ralliesMarked == true {
            if withheld.contains(s.name) { continue }
            if try EventReview.refusal(of: s, root: root, sessions: sessions) != nil { continue }
            let url = RallyMarkModel.labelsURL(for: s.sourceURL)
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw Failure.unreadableLabels(s.name, error.localizedDescription) }
            let marks: [RallyMarkRecord]
            do { marks = try JSONDecoder().decode([RallyMarkRecord].self, from: data) } catch { throw Failure.unreadableLabels(s.name, error.localizedDescription) }
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            out.append(PoolEntry(session: s, marks: marks, labelsSHA256: sha, group: groupOf[s.name] ?? s.name))
        }
        guard !out.isEmpty else { throw Failure.noPool }
        return out
    }

    /// Independent recording groups: the manifest's alias group (shared file, confirmed source / session /
    /// venue), the clip card (`_v2`… variants of one recording) and the uploader, joined transitively.
    static func groups(root: URL, sessions: [VideoSession]) -> [String: String] {
        let sources = ReservedVideos.sources(in: root)
        let alias = ReservedVideos.groups(over: sources)
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            return r
        }
        func union(_ a: String, _ b: String) {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        for s in sessions {
            union(s.name, s.name)
            union(s.name, "alias:" + (alias[s.name] ?? s.name))
            union(s.name, "card:" + card(of: s.name))
            if let u = sources[s.name]?.uploader, !u.isEmpty { union(s.name, "uploader:" + u) }
        }
        var out: [String: String] = [:]
        var members: [String: [String]] = [:]
        for s in sessions { members[find(s.name), default: []].append(s.name) }
        for names in members.values { let id = names.min()!; for n in names { out[n] = id } }
        return out
    }

    /// The clip card a session name belongs to: the name without a trailing `_vN`.
    static func card(of name: String) -> String {
        guard let r = name.range(of: #"_v\d+$"#, options: .regularExpression) else { return name }
        return String(name[..<r.lowerBound])
    }

    // MARK: - Candidates

    struct Evidence {
        let duration: Double
        let predictions: Predictions
        /// (time, ball seen) per processed frame.
        let ball: [(t: Double, seen: Bool)]
    }

    /// Every legacy mark of a recording as a candidate with the strata it can fill. Without evidence (a dry
    /// run), the prediction-based strata are not judged.
    static func candidates(_ entry: PoolEntry, evidence: Evidence?) -> [Candidate] {
        let name = entry.session.name
        let surface = ClipID.surface(of: name)?.rawValue ?? "unknown"
        let tracks = (entry.session.tracks ?? []).filter(\.done)
        return entry.marks.enumerated().compactMap { i, m in
            if let k = m.kind, k != .rally { return nil }
            var attributes: [String] = []
            let duration = m.endTime - m.startTime
            if duration < shortMax { attributes.append("short") }
            if duration > longMin { attributes.append("long") }
            if tracks.contains(where: { nearTrack(m.startTime, $0.start, $0.start - TrackedRally.margin) && nearTrack(m.endTime, $0.end, $0.end + TrackedRally.margin) }) {
                attributes.append("autoFromTrack")
            }
            var serveContact: Double?, approaching: Bool?, seen: Double?
            if let e = evidence {
                let serve = e.predictions.serves.filter { $0.contact >= m.startTime - 3 && $0.contact <= m.endTime }.min { abs($0.contact - m.startTime) < abs($1.contact - m.startTime) }
                serveContact = serve?.contact
                approaching = serve?.approaching
                if serve?.approaching == true { attributes.append("farEnd") }
                let frames = e.ball.filter { $0.t >= m.startTime && $0.t < m.startTime + 1 }
                seen = frames.isEmpty ? 0 : Double(frames.filter(\.seen).count) / Double(frames.count)
                if seen! < ambiguousBallShare || m.startTime < 1 || m.endTime > e.duration - 1 { attributes.append("ambiguous") }
                if let c = serveContact, abs(c - m.startTime) > hardCaseGap { attributes.append("hardCase") }
            }
            return Candidate(video: name, surface: surface, group: entry.group, legacyIndex: i, legacyStart: m.startTime, legacyEnd: m.endTime,
                             legacyKind: m.kind?.rawValue, attributes: attributes, serveContact: serveContact, serveApproaching: approaching, ballSeenAtStart: seen)
        }
    }

    private static func nearTrack(_ t: Double, _ a: Double, _ b: Double) -> Bool { abs(t - a) <= 0.05 || abs(t - b) <= 0.05 }

    // MARK: - Draw

    /// A small deterministic generator (SplitMix64): the same seed and candidates give the same draw anywhere.
    struct Generator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 8 per surface in the strata's order; within a stratum, among the candidates whose recording group has
    /// the fewest rallies drawn so far (so every group of the surface has one before any has two), one at
    /// random. An empty stratum is filled from any remaining candidate of the surface (recorded as a
    /// substitution); a surface with nothing left leaves the slot unfilled. Then the repeat set.
    static func draw(_ candidates: [Candidate], durations: [String: Double], seed: UInt64) -> (selection: [Selected], unfilled: [String]) {
        var rng = Generator(seed: seed)
        var selection: [Selected] = []
        var unfilled: [String] = []
        var drawnPerGroup: [String: Int] = [:]
        let surfaces = Array(Set(candidates.map(\.surface))).sorted()
        func taken(_ c: Candidate) -> Bool { selection.contains { $0.video == c.video && $0.legacyIndex == c.legacyIndex } }
        func pick(from pool: [Candidate]) -> Candidate? {
            guard !pool.isEmpty else { return nil }
            let fewest = pool.map { drawnPerGroup[$0.group] ?? 0 }.min()!
            let spread = pool.filter { (drawnPerGroup[$0.group] ?? 0) == fewest }.sorted { ($0.video, $0.legacyIndex) < ($1.video, $1.legacyIndex) }
            return spread.shuffled(using: &rng).first
        }
        for surface in surfaces {
            let mine = candidates.filter { $0.surface == surface }
            for stratum in strata {
                let eligible = mine.filter { $0.attributes.contains(stratum) && !taken($0) }
                var substituted: String?
                var chosen = pick(from: eligible)
                if chosen == nil {
                    chosen = pick(from: mine.filter { !taken($0) })
                    substituted = chosen == nil ? nil : stratum
                }
                guard let c = chosen else { unfilled.append("\(surface)/\(stratum)"); continue }
                drawnPerGroup[c.group, default: 0] += 1
                let d = durations[c.video] ?? .infinity
                selection.append(Selected(video: c.video, legacyIndex: c.legacyIndex, surface: c.surface, group: c.group,
                                          stratum: substituted == nil ? stratum : "any", substitutedFor: substituted,
                                          legacyStart: c.legacyStart, legacyEnd: c.legacyEnd,
                                          window: [max(0, c.legacyStart - windowPad), min(d, c.legacyEnd + windowPad)], repeatReview: false))
            }
        }
        for i in Array(selection.indices).shuffled(using: &rng).prefix(repeatCount) { selection[i].repeatReview = true }
        return (selection, unfilled)
    }

    // MARK: - Identities (the freeze-first gate)

    /// A model's content digest: a package or compiled model directory canonically, a single file by SHA-256.
    static func digest(ofModel url: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        return isDir.boolValue ? DatasetSplitManifest.canonicalDigest(ofDirectory: url) : DatasetSplitManifest.sha256(of: url)
    }

    /// Every stored property of the configuration as `label=value`, sorted: the same settings give the same text.
    static func snapshot(of config: ProcessorConfig) -> String {
        Mirror(reflecting: config).children.compactMap { child -> String? in
            guard let label = child.label else { return nil }
            return "\(label)=\(String(describing: child.value))"
        }.sorted().joined(separator: "\n")
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Files

    static func directory(in root: URL) -> URL { root.appendingPathComponent("manifests/pilot", isDirectory: true) }

    static func existing(in root: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory(in: root), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-pilot.json") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func latest(in root: URL) throws -> Record? {
        guard let url = existing(in: root).last else { return nil }
        let decoder = JSONDecoder()
        return try decoder.decode(Record.self, from: Data(contentsOf: url))
    }

    /// Writes the record (never over an existing one) and its readable twin. Returns both paths.
    static func write(_ record: Record, in root: URL, stamp: String) throws -> (json: URL, md: URL) {
        let dir = directory(in: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = dir.appendingPathComponent("\(stamp)-pilot.json")
        let md = dir.appendingPathComponent("\(stamp)-pilot.md")
        guard !FileManager.default.fileExists(atPath: json.path) else { throw Failure.exists([json.lastPathComponent]) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: json, options: .withoutOverwriting)
        try markdown(record).data(using: .utf8)!.write(to: md, options: .withoutOverwriting)
        return (json, md)
    }

    static func markdown(_ r: Record) -> String {
        var md = "# \(r.id) — frozen 24-rally pilot draw\(r.dryRun ? " (DRY RUN: nothing frozen)" : "")\n\n"
        md += "- created: \(r.createdAt) · project: \(r.project) · seed: \(r.seed) · status: \(r.status)\n"
        md += "- manifest hashes: project.json `\(r.manifestHashes.projectJson ?? "?")` · sessions `\(r.manifestHashes.sessions ?? "?")` · validation.json `\(r.manifestHashes.validationJson ?? "?")`\n"
        md += "- model: \(r.model)\n"
        for (name, digest) in r.modelDigests.sorted(by: { $0.key < $1.key }) { md += "- model digest: \(name) `\(digest)`\n" }
        md += "- effective config sha256 `\(r.configSHA256)` (\(r.configSnapshot.split(separator: "\n").count) settings; per-recording camera overrides in the pool table)\n"
        if let s = r.supersedes { md += "- supersedes: \(s)\n" }
        if let n = r.note { md += "- note: \(n)\n" }
        md += "\n## Pool (\(r.pool.count) recordings, \(r.candidates.count) candidate rallies)\n\n| Recording | Split | Surface | Group | Marks | Duration | labels sha256 | Predictions | Camera | config sha256 |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for v in r.pool {
            md += "| \(v.name) | \(v.split) | \(v.surface) | \(v.group) | \(v.marks) | \(v.durationSec.map { String(format: "%.1f s", $0) } ?? "?") | `\(v.labelsSHA256.prefix(16))` | \(v.predictions.map { "\($0.clipsRaw.count) raw / \($0.clipsPadded.count) padded clips, \($0.serves.count) serves" } ?? "none") | \(v.cameraSetup ?? "—") | `\(v.effectiveConfigSHA256?.prefix(16) ?? "—")` |\n"
        }
        md += "\n## Selection (\(r.selection.count) of \(size); \(r.selection.filter(\.repeatReview).count) in the blind-repeat set)\n\n| # | Recording | Legacy # | Surface | Group | Stratum | Legacy start → end | Window | Repeat |\n|---|---|---|---|---|---|---|---|---|\n"
        for (i, s) in r.selection.enumerated() {
            md += "| \(i + 1) | \(s.video) | \(s.legacyIndex) | \(s.surface) | \(s.group) | \(s.stratum)\(s.substitutedFor.map { " (for \($0))" } ?? "") | \(BoundaryEditor.clock(s.legacyStart)) → \(BoundaryEditor.clock(s.legacyEnd)) | \(BoundaryEditor.clock(s.window[0]))–\(BoundaryEditor.clock(s.window[1])) | \(s.repeatReview ? "yes" : "") |\n"
        }
        if !r.unfilled.isEmpty { md += "\nUnfilled strata: \(r.unfilled.joined(separator: ", "))\n" }
        md += "\n## Strata available per surface\n\n| Surface | " + strataNames.joined(separator: " | ") + " | any |\n|---|" + strataNames.map { _ in "---|" }.joined() + "---|\n"
        for surface in Array(Set(r.candidates.map(\.surface))).sorted() {
            let mine = r.candidates.filter { $0.surface == surface }
            md += "| \(surface) | " + strataNames.map { s in String(mine.filter { $0.attributes.contains(s) }.count) }.joined(separator: " | ") + " | \(mine.count) |\n"
        }
        return md
    }

    static var strataNames: [String] { Array(NSOrderedSet(array: strata)) as! [String] }

    // MARK: - Audit

    struct AuditRow: Equatable {
        var video: String
        var surface: String
        var stratum: String
        var legacyIndex: Int
        var rallyId: String
        var kind: String
        var event: String
        var legacyTime: Double
        var earliest: Double?
        var latest: Double?
        var width: Double?
        var visibility: String
        var flags: String
        var edge: String
        var annotator: String
        var tool: String
        var reviewedAt: String
        var secondAnnotator: String
        var secondMethod: String
        var secondTool: String
        var secondEarliest: Double?
        var secondLatest: Double?
        /// Midpoint of the second review minus the first's, seconds.
        var secondDelta: Double?
        var adjudication: Bool
        /// The primary review was edited after this second review (`second_review_before_edit`): kept as evidence
        /// in the CSV, left out of every agreement figure until a new repeat is recorded against the current review.
        var secondStale: Bool = false
        var windowExceeded: Bool
        var status: String

        static let header = "video,surface,stratum,legacy_index,rally_id,kind,event,legacy_time,reviewed_earliest,reviewed_latest,width,visibility,flags,edge,annotator,tool,reviewed_at,second_annotator,second_method,second_tool,second_earliest,second_latest,second_delta,adjudication,second_review_stale,window_exceeded,status"

        var csv: String {
            func f(_ v: Double?) -> String { v.map { String(format: "%.3f", $0) } ?? "" }
            func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            return [video, surface, stratum, String(legacyIndex), rallyId, kind, event, f(legacyTime), f(earliest), f(latest), f(width), visibility, q(flags), edge,
                    q(annotator), q(tool), reviewedAt, q(secondAnnotator), secondMethod, q(secondTool), f(secondEarliest), f(secondLatest), f(secondDelta),
                    adjudication ? "1" : "0", secondStale ? "1" : "0", windowExceeded ? "1" : "0", status].joined(separator: ",")
        }
    }

    struct Audit {
        var rows: [AuditRow]
        var summary: [String]
        var csv: String { ([AuditRow.header] + rows.map(\.csv)).joined(separator: "\n") + "\n" }
    }

    /// One row per primary event of every selected rally, from the pool's records (reads only). A selected
    /// rally not yet reviewed is a row with `status = not_reviewed`; a reviewed rally is matched by its legacy
    /// link (`legacyIndex`), else by overlap with the legacy mark.
    static func audit(_ record: Record, root: URL, sessions: [VideoSession]) throws -> Audit {
        let withheld = try EventReview.withheldNames(in: root)
        var rows: [AuditRow] = []
        var files: [String: EventReview.File?] = [:]
        for s in record.selection {
            if withheld.contains(s.video) { rows.append(blank(s, status: "withheld_now")); continue }
            guard let session = sessions.first(where: { $0.name == s.video }) else { rows.append(blank(s, status: "not_in_project")); continue }
            if files[s.video] == nil {
                let url = EventReview.url(forVideo: session.sourceURL)
                files[s.video] = FileManager.default.fileExists(atPath: url.path) ? (try? EventReview.read(url)) : nil
            }
            guard let file = files[s.video]! else { rows.append(blank(s, status: FileManager.default.fileExists(atPath: EventReview.url(forVideo: session.sourceURL).path) ? "record_unreadable" : "not_reviewed")); continue }
            // The same identity check as opening the recording: a record for another recording, or for footage that
            // has been replaced, is reported, never counted.
            if EventReview.identityProblem(of: file, for: session) != nil { rows.append(blank(s, status: "record_not_this_recording")); continue }
            // The same pairing the blind rule uses on both devices: the reviewed rally overlapping the legacy interval most
            // (independent of how either device numbered its legacy marks).
            guard let r = PilotBlind.answer(to: s.pilotWindow, in: file) else { rows.append(blank(s, status: "not_reviewed")); continue }
            for (event, legacy, first, second) in [("contact", s.legacyStart, r.contact, r.secondReview?.contact), ("dead", s.legacyEnd, r.dead, r.secondReview?.dead)] {
                let mid = first.map { ($0.earliest + $0.latest) / 2 }
                let mid2 = second.map { ($0.earliest + $0.latest) / 2 }
                let delta = (mid != nil && mid2 != nil) ? mid2! - mid! : nil
                let exceeded = first.map { $0.earliest < s.window[0] - 1e-9 || $0.latest > s.window[1] + 1e-9 } ?? false
                rows.append(AuditRow(video: s.video, surface: s.surface, stratum: s.stratum, legacyIndex: s.legacyIndex, rallyId: r.rallyId.uuidString, kind: r.kind.rawValue,
                                     event: event, legacyTime: legacy, earliest: first?.earliest, latest: first?.latest, width: first.map { $0.latest - $0.earliest },
                                     visibility: first?.visibility.rawValue ?? "", flags: r.flags.joined(separator: " "), edge: r.edge?.rawValue ?? "",
                                     annotator: r.annotator, tool: r.tool ?? "", reviewedAt: r.reviewedAt,
                                     secondAnnotator: r.secondReview?.annotator ?? "", secondMethod: r.secondReview?.method ?? "", secondTool: r.secondReview?.tool ?? "",
                                     secondEarliest: second?.earliest, secondLatest: second?.latest, secondDelta: delta,
                                     adjudication: delta.map { abs($0) > adjudicationGap } ?? false,
                                     secondStale: r.secondReview != nil && r.flags.contains("second_review_before_edit"), windowExceeded: exceeded,
                                     status: first == nil ? "unresolved" : "reviewed"))
            }
        }
        return Audit(rows: rows, summary: summarise(rows, record: record))
    }


    private static func blank(_ s: Selected, status: String) -> AuditRow {
        AuditRow(video: s.video, surface: s.surface, stratum: s.stratum, legacyIndex: s.legacyIndex, rallyId: "", kind: "", event: "", legacyTime: s.legacyStart,
                 earliest: nil, latest: nil, width: nil, visibility: "", flags: "", edge: "", annotator: "", tool: "", reviewedAt: "",
                 secondAnnotator: "", secondMethod: "", secondTool: "", secondEarliest: nil, secondLatest: nil, secondDelta: nil,
                 adjudication: false, windowExceeded: false, status: status)
    }

    /// The protocol's figures: per surface and event, the legacy offset (legacy − reviewed midpoint: median and
    /// spread), the ambiguity share, the repeat agreement by method and platform pair, adjudications.
    static func summarise(_ rows: [AuditRow], record: Record) -> [String] {
        var out: [String] = []
        let reviewed = rows.filter { $0.status == "reviewed" }
        out.append("\(record.selection.count) rallies selected · \(Set(reviewed.map(\.rallyId)).count) reviewed · \(rows.filter { $0.status == "not_reviewed" }.count / 1) not yet reviewed (rows) · \(reviewed.filter(\.windowExceeded).count) window_exceeded")
        func stats(_ v: [Double]) -> String {
            guard !v.isEmpty else { return "—" }
            let s = v.sorted()
            return String(format: "median %+.3f s (IQR %+.3f…%+.3f, n=%d)", quantile(s, 0.5), quantile(s, 0.25), quantile(s, 0.75), v.count)
        }
        for surface in Array(Set(reviewed.map(\.surface))).sorted() + ["all"] {
            let mine = surface == "all" ? reviewed : reviewed.filter { $0.surface == surface }
            for event in ["contact", "dead"] {
                let e = mine.filter { $0.event == event && $0.earliest != nil }
                let offsets = e.map { $0.legacyTime - ($0.earliest! + $0.latest!) / 2 }
                let ambiguous = e.filter { ($0.width ?? 0) > EventReview.ambiguityThreshold + 1e-9 }.count
                out.append("\(surface) \(event): legacy − reviewed \(stats(offsets)) · ambiguous \(ambiguous)/\(e.count)")
            }
        }
        // A second review that predates an edit of the primary review compares two different annotations: it stays
        // in the CSV, not in agreement.
        let stale = reviewed.filter { $0.secondDelta != nil && $0.secondStale }
        if !stale.isEmpty { out.append("\(stale.count) event(s) with a second review older than an edit of the primary review: kept in the CSV, left out of agreement") }
        let repeats = reviewed.filter { $0.secondDelta != nil && !$0.secondStale }
        let pairs = Dictionary(grouping: repeats) { r in "\(r.secondMethod) · \(platform(r.tool)) → \(platform(r.secondTool))" }
        for (pair, rs) in pairs.sorted(by: { $0.key < $1.key }) {
            let deltas = rs.map { abs($0.secondDelta!) }
            out.append("repeat [\(pair)]: \(rs.count) events · |delta| \(stats(deltas)) · within \(adjudicationGap) s: \(deltas.filter { $0 <= adjudicationGap }.count)/\(deltas.count) · adjudication \(rs.filter(\.adjudication).count)")
        }
        if repeats.isEmpty { out.append("no second reviews recorded yet") }
        return out
    }

    /// The platform a review was committed on; "unknown" for a record that kept no per-rally tool.
    /// The q-quantile of sorted values by linear interpolation (q = 0.5 is the median: the mean of the two middle
    /// values for an even count).
    static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let pos = q * Double(sorted.count - 1), lo = Int(pos.rounded(.down)), hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    static func platform(_ tool: String) -> String {
        tool.hasPrefix("Labeler") ? "iPhone" : tool.hasPrefix("RallyLab") ? "Mac" : (tool.isEmpty ? "unknown" : tool)
    }
}
