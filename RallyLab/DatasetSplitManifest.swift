//
//  DatasetSplitManifest.swift
//  RallyLab
//
//  The versioned record of which video sits in which split and what it has
//  already been used for (decisions D-002, D-009). Built from project.json,
//  the dataset sessions and pipeline_tuning/validation.json; written by
//  `RallyLab --project <name> --manifest` to <project>/manifests/ and
//  committed under docs/ml-roadmap/manifests/<project>/.
//
//  Nothing here infers provenance: `sourceId`, `sessionId` and `venueId` are
//  "confirmed" only when the owner set them in project.json. A fingerprint
//  (YouTube ID, or size + hash of a local file) identifies the same *file*
//  and is reported as `inferred_fingerprint`, never promoted to confirmed.
//

import CryptoKit
import Foundation

/// The five-way split the manifest reports. The dataset itself still only
/// knows "train" and "val"; the rest comes from validation.json.
enum DatasetSplit: String, Codable, CaseIterable {
    case train
    case devVal = "dev_val"
    case tune
    case legacyHoldout = "legacy_holdout"
    case finalTestCandidate = "final_test_candidate"
    case finalTest = "final_test"

    /// Splits a model or the tuner must never have seen before the final test.
    var isReserved: Bool { self == .legacyHoldout || self == .finalTest || self == .finalTestCandidate }

    static let definitions: [String: String] = [
        DatasetSplit.train.rawValue:
            "Detector training (dataset split \"train\").",
        DatasetSplit.devVal.rawValue:
            "Development validation: dataset split \"val\" and not listed in pipeline_tuning/validation.json. Used for model selection; not unseen.",
        DatasetSplit.tune.rawValue:
            "validation.json `tune`: pipeline settings are searched on these. Also in the detector's val split.",
        DatasetSplit.legacyHoldout.rawValue:
            "validation.json `holdout`: frozen recordings (D-002) with recorded prior exposure (test-set scoring, tuner reports). Not an unseen final test.",
        DatasetSplit.finalTestCandidate.rawValue:
            "validation.json `finalTestCandidates`: provisional final-test recordings (D-015 §2). Protected exactly like final_test while venue/session provenance and prior exposure are verified; NOT yet the final test.",
        DatasetSplit.finalTest.rawValue:
            "validation.json `finalTest`: verified recordings with no recorded exposure, reserved until promotion. Excluded from packages, scoring and tuning.",
    ]
}

/// An identity the owner confirmed, one the file's fingerprint suggests, or nothing.
struct ProvenanceValue: Codable, Equatable {
    enum Origin: String, Codable {
        case confirmed
        case inferredFingerprint = "inferred_fingerprint"
        case unknown
    }

    var value: String?
    var origin: Origin

    static let unknown = ProvenanceValue(value: nil, origin: .unknown)
    static func confirmed(_ value: String) -> ProvenanceValue { .init(value: value, origin: .confirmed) }
    static func inferred(_ fingerprint: String) -> ProvenanceValue { .init(value: fingerprint, origin: .inferredFingerprint) }
}

/// One use a video has been put to. A video with any record is not unseen.
struct ExposureRecord: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case trainingPackage = "training_package"
        case testSetScoring = "test_set_scoring"
        case pipelineTune = "pipeline_tuning_tune"
        case pipelineHoldout = "pipeline_tuning_holdout"
        /// The rally pipeline was run on the video and scored against its marks
        /// (--score-rallies, --diagnose-rallies, --render-pipeline, --serve-report, the RallyLab Pipeline/Compare tabs).
        case rallyScoring = "rally_scoring"
        /// A detector was evaluated on the video's reviewed frames (ModelLibrary evaluate, --pretrack-check).
        case detectorEvaluation = "detector_evaluation"
        /// A model wrote machine tracks into the video (--pretrack).
        case preTracking = "pre_tracking"
        /// The pipeline ran over the whole video to save where it saw the ball (BallPathBuilder,
        /// for marking in the Label / Live-tag tabs).
        case ballPath = "ball_path"
    }

    var kind: Kind
    /// The artefact: a package or score-export name, or the validation file.
    var ref: String
    /// ISO-8601 date when known.
    var date: String?
    var note: String?
}

struct ManifestVideo: Codable, Equatable {
    /// The dataset session name (also the video ID in project.json).
    var video: String
    var clipId: String?
    var surface: String?
    var camera: String?
    var lighting: String?
    var orientation: String?
    var uploader: String?
    /// "link" or "file"; the origin itself (URL or local path) stays in project.json.
    var originKind: String?
    var fingerprint: String?
    var sourceId: ProvenanceValue
    var sessionId: ProvenanceValue
    var venueId: ProvenanceValue
    /// The dataset's own split, "train" or "val".
    var datasetSplit: String
    /// The card's pinned split, or nil when the dataset chose per video.
    var cardSplit: String?
    var split: DatasetSplit
    /// The split this video would have without any reservation overlay
    /// (train / dev_val / tune / legacy_holdout); nil when equal to `split`.
    var unreservedSplit: DatasetSplit?
    /// "listed" when validation.json names this video; "alias" when it is
    /// reserved only because it shares a file or confirmed identity with a
    /// listed one; nil when not reserved.
    var reservedAs: String?
    /// Alias group over the whole project.json (shared file fingerprint or
    /// confirmed sourceId / sessionId / venueId, transitively, including
    /// project videos that have no dataset session): the smallest video
    /// name in the group. nil for a session with no project video.
    var aliasGroup: String?
    var ralliesMarked: Bool
    var frames: Int
    var reviewedFrames: Int
    var addedAt: Date
    var exposure: [ExposureRecord]
}

struct DatasetSplitManifest: Codable {
    static let currentSchemaVersion = 1

    struct Hashes: Codable, Equatable {
        /// SHA-256 of project.json.
        var projectJson: String?
        /// Canonical directory digest of sessions/ (see `canonicalDigest`).
        var sessions: String?
        /// SHA-256 of pipeline_tuning/validation.json.
        var validationJson: String?
    }

    var schemaVersion: Int
    var project: String
    var createdAt: Date
    /// What wrote it: the app's build or the code commit.
    var generator: String
    var hashes: Hashes
    var splitDefinitions: [String: String]
    var videos: [ManifestVideo]

    enum BuildError: LocalizedError, Equatable {
        case finalTestExposed([String])

        var errorDescription: String? {
            switch self {
            case .finalTestExposed(let names):
                return "Listed as final_test but already exposed: \(names.joined(separator: ", ")). A final-test recording must have no training, scoring or tuning history."
            }
        }
    }

    /// Everything `build` reads, so it can run on fixtures without a project folder.
    struct Inputs {
        var project: Project?
        var sessions: [VideoSession]
        var validation: PipelineTuner.ValidationSet?
        /// The file identity of a video, nil when the file is unreachable and the link has none.
        var fingerprint: (ClipSource) -> String?
        /// The manifest written last time; its exposure records carry forward.
        var previous: DatasetSplitManifest?
        /// Exposure found in artefacts (score runs, exported packages, the seed file), by video.
        var discovered: [String: [ExposureRecord]]
        var hashes: Hashes
        var generator: String
        var now: Date
    }

    static func build(_ inputs: Inputs) throws -> DatasetSplitManifest {
        var cards: [String: (clip: PlannedClip, source: ClipSource)] = [:]
        for clip in inputs.project?.clips ?? [] {
            for source in clip.videos {
                cards[clip.videoId(of: source)] = (clip, source)
            }
        }
        let tune = Set(inputs.validation?.tune ?? [])
        let holdout = Set(inputs.validation?.holdout ?? [])
        // Reservations name recordings: expand the listed names to their aliases here, so the
        // manifest can also say what each video was before the overlay and why it is reserved.
        let sources = Dictionary(uniqueKeysWithValues: cards.map { ($0.key, $0.value.source) })
        let listedFinal = Set(inputs.validation?.finalTest ?? [])
        let listedCandidates = Set(inputs.validation?.finalTestCandidates ?? []).subtracting(listedFinal)
        let finalTest = ReservedVideos.closure(of: listedFinal, over: sources)
        let candidates = ReservedVideos.closure(of: listedCandidates, over: sources).subtracting(finalTest)
        let groupOf = ReservedVideos.groups(over: sources)
        // Project videos with no dataset session never get a row, but their history still belongs
        // to their alias group (e.g. an exposed video whose session was removed from the dataset).
        let sessionNames = Set(inputs.sessions.map(\.name))
        var sessionless: [String: [String]] = [:]   // group id → sessionless member names
        for (name, group) in groupOf where !sessionNames.contains(name) { sessionless[group, default: []].append(name) }
        func inheritedExposure(forGroup group: String?) -> Set<ExposureRecord> {
            var out = Set<ExposureRecord>()
            for m in (group.flatMap { sessionless[$0] } ?? []).sorted() {
                for r in (previous[m] ?? []) + (inputs.discovered[m] ?? []) {
                    out.insert(ExposureRecord(kind: r.kind, ref: r.ref, date: r.date, note: (r.note.map { $0 + "; " } ?? "") + "via sessionless alias \(m)"))
                }
            }
            return out
        }
        let previous = Dictionary(uniqueKeysWithValues: (inputs.previous?.videos ?? []).map { ($0.video, $0.exposure) })
        // A moved or renamed video keeps its history: the previous manifest is also joined by file fingerprint.
        var previousByPrint: [String: Set<ExposureRecord>] = [:]
        for v in inputs.previous?.videos ?? [] {
            if let print = v.fingerprint { previousByPrint[print, default: []].formUnion(v.exposure) }
        }

        var exposed: [String] = []
        let videos = inputs.sessions.sorted { $0.name < $1.name }.map { session -> ManifestVideo in
            let card = cards[session.name]
            let unreserved: DatasetSplit
            if holdout.contains(session.name) { unreserved = .legacyHoldout }
            else if tune.contains(session.name) { unreserved = .tune }
            else if session.split == "val" { unreserved = .devVal }
            else { unreserved = .train }
            let split: DatasetSplit
            if finalTest.contains(session.name) { split = .finalTest }
            else if candidates.contains(session.name) { split = .finalTestCandidate }
            else { split = unreserved }
            let reservedAs: String? = split.isReserved && split != .legacyHoldout
                ? (listedFinal.contains(session.name) || listedCandidates.contains(session.name) ? "listed" : "alias") : nil

            var exposure = Set(previous[session.name] ?? [])
            exposure.formUnion(inputs.discovered[session.name] ?? [])
            if let source = card?.source, let print = inputs.fingerprint(source) { exposure.formUnion(previousByPrint[print] ?? []) }
            exposure.formUnion(inheritedExposure(forGroup: groupOf[session.name]))
            if tune.contains(session.name) {
                exposure.insert(ExposureRecord(kind: .pipelineTune, ref: "pipeline_tuning/validation.json", date: nil, note: nil))
            }
            if holdout.contains(session.name) {
                exposure.insert(ExposureRecord(kind: .pipelineHoldout, ref: "pipeline_tuning/validation.json", date: nil, note: nil))
            }
            if split == .finalTest, !exposure.isEmpty { exposed.append(session.name) }

            let sourceId: ProvenanceValue
            if let confirmed = card?.source.sourceId, !confirmed.isEmpty { sourceId = .confirmed(confirmed) }
            else if let source = card?.source, let print = inputs.fingerprint(source) { sourceId = .inferred(print) }
            else { sourceId = .unknown }

            return ManifestVideo(
                video: session.name,
                clipId: card?.clip.id,
                surface: card.map { $0.clip.environment.lowercased() } ?? ClipID.surface(of: session.name)?.rawValue,
                camera: card?.clip.camera,
                lighting: card?.clip.lighting,
                orientation: card?.clip.orientation,
                uploader: card.flatMap { $0.source.uploader.isEmpty ? nil : $0.source.uploader },
                originKind: card?.source.kind.rawValue,
                fingerprint: card.flatMap { inputs.fingerprint($0.source) },
                sourceId: sourceId,
                sessionId: card?.source.sessionId.flatMap { $0.isEmpty ? nil : ProvenanceValue.confirmed($0) } ?? ProvenanceValue.unknown,
                venueId: card?.source.venueId.flatMap { $0.isEmpty ? nil : ProvenanceValue.confirmed($0) } ?? ProvenanceValue.unknown,
                datasetSplit: session.split,
                cardSplit: card?.clip.split,
                split: split,
                unreservedSplit: split == unreserved ? nil : unreserved,
                reservedAs: reservedAs,
                aliasGroup: groupOf[session.name],
                ralliesMarked: session.ralliesMarked ?? false,
                frames: session.frames.count,
                reviewedFrames: session.reviewedCount,
                addedAt: session.addedAt,
                exposure: exposure.sorted { ($0.kind.rawValue, $0.ref) < ($1.kind.rawValue, $1.ref) })
        }
        guard exposed.isEmpty else { throw BuildError.finalTestExposed(exposed.sorted()) }

        return DatasetSplitManifest(schemaVersion: currentSchemaVersion,
                                    project: inputs.project?.name ?? "",
                                    createdAt: inputs.now,
                                    generator: inputs.generator,
                                    hashes: inputs.hashes,
                                    splitDefinitions: DatasetSplit.definitions,
                                    videos: videos)
    }

    // MARK: - Exposure found in the project folder

    /// Exposure recorded by artefacts RallyLab can read without the footage:
    /// scores/<export>/scores.json (which clips a test-set run scored),
    /// exports/<folder>/windows.jsonl (which clips a package holds; zipped
    /// packages are not opened), and manifests/exposure-seed.json (uses the
    /// implementer recorded by hand, each with a note saying where from).
    enum DiscoveryError: LocalizedError {
        case unreadable(URL)
        var errorDescription: String? {
            switch self {
            case .unreadable(let dir):
                return "\(dir.path) exists but can't be listed, so the exposure it holds is unknown. Fix access to it before building a manifest or reserving anything."
            }
        }
    }

    /// The directory's entries; [] when it does not exist; throws when it
    /// exists but can't be listed (history unknown is not history empty).
    private static func entries(of dir: URL, keys: [URLResourceKey] = []) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        do { return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) }
        catch { throw DiscoveryError.unreadable(dir) }
    }

    static func discoverExposure(in projectDir: URL) throws -> [String: [ExposureRecord]] {
        var found: [String: Set<ExposureRecord>] = [:]
        func add(_ video: String, _ record: ExposureRecord) { found[video, default: []].insert(record) }

        let scores = projectDir.appendingPathComponent("scores", isDirectory: true)
        for export in try entries(of: scores) {
            let file = export.appendingPathComponent("scores.json")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let clips = json["clips"] as? [String: Any] else { continue }
            let date = isoDay(of: file)
            for clip in clips.keys {
                add(clip, ExposureRecord(kind: .testSetScoring, ref: export.lastPathComponent, date: date, note: nil))
            }
        }

        let exports = projectDir.appendingPathComponent("exports", isDirectory: true)
        for folder in try entries(of: exports, keys: [.isDirectoryKey]) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let windows = folder.appendingPathComponent("windows.jsonl")
            guard let text = try? String(contentsOf: windows, encoding: .utf8) else { continue }
            let date = isoDay(of: windows)
            var seen: [String: String] = [:]
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let clip = json["clip"] as? String else { continue }
                if seen[clip] == nil { seen[clip] = json["split"] as? String ?? "?" }
            }
            for (clip, split) in seen {
                add(clip, ExposureRecord(kind: .trainingPackage, ref: folder.lastPathComponent, date: date, note: "windows.jsonl split=\(split)"))
            }
        }

        // Single-frame (YOLO) packages keep a manifest.csv (image,clip,split,…).
        for folder in try entries(of: exports, keys: [.isDirectoryKey]) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let csv = folder.appendingPathComponent("manifest.csv")
            guard let text = try? String(contentsOf: csv, encoding: .utf8) else { continue }
            let date = isoDay(of: csv)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
            guard let header = lines.next()?.split(separator: ",").map(String.init),
                  let clipCol = header.firstIndex(of: "clip") else { continue }
            let splitCol = header.firstIndex(of: "split")
            var seen: [String: String] = [:]
            for line in lines {
                let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                guard cols.indices.contains(clipCol) else { continue }
                if seen[cols[clipCol]] == nil { seen[cols[clipCol]] = splitCol.flatMap { cols.indices.contains($0) ? cols[$0] : nil } ?? "?" }
            }
            for (clip, split) in seen {
                add(clip, ExposureRecord(kind: .trainingPackage, ref: folder.lastPathComponent, date: date, note: "manifest.csv split=\(split)"))
            }
        }

        // Uses that predate the log and leave marks in the project itself: machine tracks
        // written by a pre-tracking model, and the tuner's / serve report's cached detection passes.
        for session in try DatasetStore(root: projectDir).loadSessionsStrict() {
            let machine = (session.tracks ?? []).filter(\.isMachine)
            if !machine.isEmpty {
                let latest = machine.compactMap(\.updatedAt).max()
                add(session.name, ExposureRecord(kind: .preTracking, ref: "session tracks (machine)",
                                                 date: latest.map(isoDay), note: "\(machine.count) machine track(s) in sessions/\(session.name).json; model not recorded"))
            }
        }
        let evidence = projectDir.appendingPathComponent("pipeline_tuning/evidence", isDirectory: true)
        for file in try entries(of: evidence) where file.pathExtension == "evidence" {
            // <session>__<detection key>.evidence — the session name itself may contain "__", so split at the LAST separator.
            let name = file.deletingPathExtension().lastPathComponent
            guard let sep = name.range(of: "__", options: .backwards) else { continue }
            add(String(name[..<sep.lowerBound]), ExposureRecord(kind: .rallyScoring, ref: "pipeline_tuning/evidence", date: isoDay(of: file),
                                                               note: "cached detection pass (tuner or serve report)"))
        }

        // The log every export, score run and tuning round appends to (survives deleted artefacts),
        // and the hand-written seed for artefacts that predate the log.
        for row in try ExposureLog.readStrict(in: projectDir) + ExposureLog.readSeedStrict(in: projectDir) {
            add(row.video, ExposureRecord(kind: row.kind, ref: row.ref, date: row.date, note: row.note))
        }

        return found.mapValues { Array($0) }
    }

    struct ExposureLogRow: Codable, Equatable {
        var video: String
        var kind: ExposureRecord.Kind
        var ref: String
        var date: String?
        var note: String?
    }

    private static func isoDay(of file: URL) -> String? {
        guard let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
        return isoDay(date)
    }

    private static func isoDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    // MARK: - Hashes

    static func sha256(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The same digest as the shell's
    /// `find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256`:
    /// one `<sha256>  ./<relative path>` line per regular file in byte order,
    /// then SHA-256 of those lines. Identical trees give identical digests;
    /// a renamed or added file changes it.
    static func canonicalDigest(ofDirectory dir: URL) -> String? {
        let fm = FileManager.default
        // Path-based enumeration yields paths relative to `dir`, whatever
        // symlinks (e.g. /var → /private/var) sit above it.
        guard let enumerator = fm.enumerator(atPath: dir.path) else { return nil }
        var paths: [String] = []
        while let rel = enumerator.nextObject() as? String {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.appendingPathComponent(rel).path, isDirectory: &isDir), !isDir.boolValue else { continue }
            paths.append("./" + rel)
        }
        paths.sort { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        var lines = ""
        for path in paths {
            let file = dir.appendingPathComponent(String(path.dropFirst(2)))
            guard let hash = sha256(of: file) else { return nil }
            lines += "\(hash)  \(path)\n"
        }
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Files

    enum ReadError: LocalizedError {
        case unreadable(URL)
        var errorDescription: String? {
            switch self {
            case .unreadable(let file):
                return "\(file.path) exists but can't be decoded. It may be the only record of past exposure: restore or repair it before regenerating."
            }
        }
    }

    /// The manifest written last time, nil when there is none. Throws when the
    /// file exists but won't decode, so a damaged record is never overwritten.
    static func readStrict(from file: URL) throws -> DatasetSplitManifest? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file),
              let manifest = try? decoder.decode(DatasetSplitManifest.self, from: data) else { throw ReadError.unreadable(file) }
        return manifest
    }

    /// Lenient reader for display; never use it to decide what to overwrite.
    static func read(from file: URL) -> DatasetSplitManifest? { (try? readStrict(from: file)) ?? nil }

    func write(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }

    // MARK: - Summary

    func markdownSummary() -> String {
        let surfaces = Array(Set(videos.compactMap(\.surface))).sorted()
        var md = "# Dataset split manifest — \(project)\n\n"
        md += "Created \(ISO8601DateFormatter().string(from: createdAt)) by \(generator). Schema \(schemaVersion).\n\n"
        md += "Hashes: project.json `\(hashes.projectJson.map { String($0.prefix(16)) } ?? "—")` · sessions/ `\(hashes.sessions.map { String($0.prefix(16)) } ?? "—")` · validation.json `\(hashes.validationJson.map { String($0.prefix(16)) } ?? "—")`\n\n"
        md += "## Videos by split and surface\n\n| Split | " + surfaces.joined(separator: " | ") + " | Total |\n|---|" + surfaces.map { _ in "---|" }.joined() + "---|\n"
        for split in DatasetSplit.allCases {
            let rows = videos.filter { $0.split == split }
            guard !rows.isEmpty || split == .finalTest else { continue }
            md += "| \(split.rawValue) | " + surfaces.map { s in String(rows.filter { $0.surface == s }.count) }.joined(separator: " | ") + " | \(rows.count) |\n"
        }
        md += "\n" + DatasetSplit.allCases.map { "- **\($0.rawValue)** — \(DatasetSplit.definitions[$0.rawValue] ?? "")" }.joined(separator: "\n") + "\n"
        md += "\n## Exposure\n\n| Kind | Videos | Artefacts |\n|---|---|---|\n"
        for kind in ExposureRecord.Kind.allCases {
            let rows = videos.filter { $0.exposure.contains { $0.kind == kind } }
            let refs = Set(videos.flatMap { $0.exposure.filter { $0.kind == kind }.map(\.ref) }).sorted()
            md += "| \(kind.rawValue) | \(rows.count) | \(refs.joined(separator: ", ")) |\n"
        }
        let unexposed = videos.filter { $0.exposure.isEmpty }
        md += "\nVideos with no recorded exposure: \(unexposed.count)" + (unexposed.isEmpty ? "" : " (" + unexposed.map(\.video).joined(separator: ", ") + ")") + "\n"
        md += "\n## Provenance\n\n| Field | confirmed | inferred from fingerprint | unknown |\n|---|---|---|---|\n"
        for (name, path) in [("sourceId", \ManifestVideo.sourceId), ("sessionId", \ManifestVideo.sessionId), ("venueId", \ManifestVideo.venueId)] {
            let values = videos.map { $0[keyPath: path].origin }
            md += "| \(name) | \(values.filter { $0 == .confirmed }.count) | \(values.filter { $0 == .inferredFingerprint }.count) | \(values.filter { $0 == .unknown }.count) |\n"
        }
        md += "\n## Videos\n\n| Video | Split | Surface | Card | Card split | Uploader | sourceId | Exposure |\n|---|---|---|---|---|---|---|---|\n"
        for v in videos {
            let source = v.sourceId.value.map { "\($0) (\(v.sourceId.origin.rawValue))" } ?? "unknown"
            let exposure = v.exposure.isEmpty ? "none" : Set(v.exposure.map(\.kind.rawValue)).sorted().joined(separator: ", ")
            md += "| \(v.video) | \(v.split.rawValue) | \(v.surface ?? "?") | \(v.clipId ?? "—") | \(v.cardSplit ?? "auto") | \(v.uploader ?? "—") | \(source) | \(exposure) |\n"
        }
        return md
    }
}

/// Append-only record of what each video has been used for, written at the
/// moment of use (package export, test-set scoring, a tuning round) so the
/// manifest's exposure history does not depend on the artefact surviving.
/// `manifests/exposure-seed.json` is the hand-written counterpart for uses
/// that predate the log; `manifests/exposure-log.json` is this one.
enum ExposureLog {
    static func url(in projectDir: URL) -> URL { projectDir.appendingPathComponent("manifests/exposure-log.json") }
    static func seedURL(in projectDir: URL) -> URL { projectDir.appendingPathComponent("manifests/exposure-seed.json") }

    enum LogError: LocalizedError {
        case unreadable(URL)
        case notWritten(URL, String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let file):
                return "\(file.path) exists but can't be decoded. It holds exposure history that must not be lost: restore it (git, Time Machine) or repair it by hand before anything is packaged, scored or reserved."
            case .notWritten(let file, let why):
                return "Exposure could not be recorded in \(file.path) (\(why)). The operation is treated as failed so no use goes unrecorded; free space or fix permissions and run it again."
            }
        }
    }

    /// Uses parked while the main log was unreadable (see `record`).
    static func sidecarURLs(in projectDir: URL) -> [URL] {
        let dir = projectDir.appendingPathComponent("manifests", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("exposure-log.unmerged-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The log plus every parked sidecar, [] when there is none of either.
    /// Throws when any of them exists but won't decode: history is unknown,
    /// and nothing may treat that as "none".
    static func readStrict(in projectDir: URL) throws -> [DatasetSplitManifest.ExposureLogRow] {
        try rows(at: url(in: projectDir)) + sidecarURLs(in: projectDir).flatMap { try rows(at: $0) }
    }
    static func readSeedStrict(in projectDir: URL) throws -> [DatasetSplitManifest.ExposureLogRow] { try rows(at: seedURL(in: projectDir)) }
    /// Lenient reader for display only; never use it to decide what is unseen.
    static func read(in projectDir: URL) -> [DatasetSplitManifest.ExposureLogRow] { (try? readStrict(in: projectDir)) ?? [] }

    private static func rows(at file: URL) throws -> [DatasetSplitManifest.ExposureLogRow] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        guard let data = try? Data(contentsOf: file),
              let rows = try? JSONDecoder().decode([DatasetSplitManifest.ExposureLogRow].self, from: data) else { throw LogError.unreadable(file) }
        return rows
    }

    /// A video renamed (moved to another card) keeps its history: every row
    /// under the old name is duplicated under the new one. Old rows stay, so
    /// an older manifest still joins. Fails the same way `record` does.
    /// Throws when the history can't be read or written; the caller must then
    /// keep the old session rather than lose its record.
    static func rename(_ old: String, to new: String, in projectDir: URL, now: Date = Date()) throws {
        guard old != new else { return }
        let rows = try readStrict(in: projectDir) + readSeedStrict(in: projectDir)
        let grouped = Dictionary(grouping: rows.filter { $0.video == old }, by: \.kind)
        for (kind, group) in grouped {
            for row in group {
                try record(videos: [new], kind: kind, ref: row.ref, note: (row.note.map { $0 + "; " } ?? "") + "carried from \(old)", in: projectDir, now: now)
            }
        }
    }

    /// Append one use for each video (duplicates of an identical row are dropped).
    /// An unreadable existing log is never overwritten — the new rows go to a
    /// sidecar instead, so nothing is lost either way. A write failure throws:
    /// a use that can't be recorded must fail the operation that caused it,
    /// or the video could later pass as unseen.
    static func record(videos: Set<String>, kind: ExposureRecord.Kind, ref: String, note: String?, in projectDir: URL, now: Date = Date()) throws {
        guard !videos.isEmpty else { return }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        let date = f.string(from: now)
        var all: [DatasetSplitManifest.ExposureLogRow]
        var target = url(in: projectDir)
        var mergedSidecars: [URL] = []
        do {
            // Fold any parked sidecars back into the main log while it is readable.
            all = try rows(at: target)
            for sidecar in sidecarURLs(in: projectDir) {
                for row in try rows(at: sidecar) where !all.contains(where: { $0.video == row.video && $0.kind == row.kind && $0.ref == row.ref }) { all.append(row) }
                mergedSidecars.append(sidecar)
            }
        } catch {
            // Keep the damaged file untouched; park this use beside it (discovery reads sidecars too).
            target = projectDir.appendingPathComponent("manifests/exposure-log.unmerged-\(Int(now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
            all = []
            mergedSidecars = []
            FileHandle.standardError.write(Data("❌ \(error.localizedDescription) This use is written to \(target.lastPathComponent) instead.\n".utf8))
        }
        for video in videos.sorted() {
            let row = DatasetSplitManifest.ExposureLogRow(video: video, kind: kind, ref: ref, date: date, note: note)
            if !all.contains(where: { $0.video == row.video && $0.kind == row.kind && $0.ref == row.ref }) { all.append(row) }
        }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(all).write(to: target, options: .atomic)
            for sidecar in mergedSidecars { try? FileManager.default.removeItem(at: sidecar) }
        } catch {
            throw LogError.notWritten(target, error.localizedDescription)
        }
    }
}
