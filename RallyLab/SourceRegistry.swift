//
//  SourceRegistry.swift
//  RallyLab
//
//  RallyLab 2.0, phase 1: one view of every recording the project knows —
//  who it is, where it came from, which split and reservation it is under,
//  whether it was admitted into the dataset, and what it has been used for.
//  It is an index, built from the files that own each fact and rebuildable
//  from them at any time: identity and provenance from project.json
//  (ClipSource: fingerprint, sourceId / sessionId / venueId, origin, licence),
//  presence and annotation counts from sessions/<video>.json, reservations
//  from pipeline_tuning/validation.json through the same closure every guard
//  uses (ReservedVideos), exposure from the ledger (ExposureLog). It owns
//  nothing: nothing reads the index to decide what may be trained, scored or
//  reviewed, and nothing here infers an identity — a recording whose owner
//  confirmed no sourceId is identified by its file fingerprint and said so.
//  No video file is opened to build it.
//

import Foundation

enum SourceRegistry {
    static let schemaVersion = 1

    enum IdentityConfidence: String, Codable, Sendable {
        /// The owner confirmed the original recording (ClipSource.sourceId, D-009/D-015).
        case confirmed
        /// The file's content fingerprint (or a link's video id): the same file, not necessarily the same recording.
        case inferred
        /// Nothing identifies it but its name.
        case unknown
    }

    /// Whether the recording may be worked on. Only `admitted` recordings get labeling tasks that can run.
    enum Admission: String, Codable, Sendable, CaseIterable {
        /// In the dataset and not reserved: eligible for annotation and development use.
        case admitted
        /// Reserved (final test, candidates, lineage holdout, legacy holdout) or aliased to a reserved recording.
        case withheld
        /// On a project card but not sampled into the dataset yet (no session).
        case pendingIngest = "pending_ingest"
        /// In the dataset with no file identity: cannot be checked against reservations by content.
        case unidentified
        /// Held back by an intake decision pending review (phase 2 intake writes these; none exist yet).
        case quarantined
        /// Refused by an intake decision (phase 2; none exist yet).
        case rejected
    }

    struct Source: Codable, Equatable, Identifiable, Sendable {
        var id: String { video }
        /// The dataset session name and video id.
        var video: String
        var clipId: String?
        var surface: String?
        var camera: String?
        var originKind: String?
        var uploader: String?
        var license: String?
        var pulledFrom: String?
        var fingerprint: String?
        /// `src:<sourceId>` when confirmed, else `fp:<fingerprint>`, else `name:<video>`.
        var identityKey: String
        var identityConfidence: IdentityConfidence
        var sourceId: String?
        var sessionId: String?
        var venueId: String?
        /// ReservedVideos.groups: shared file or confirmed identity, transitively; the group's smallest name.
        var aliasGroup: String?
        /// Other videos with the same file fingerprint: the same file cut again, or a copy.
        var duplicates: [String]
        /// Other videos with the same confirmed sourceId but another file: another cut or encoding of one recording.
        var sameSource: [String]
        var split: DatasetSplit
        /// "listed" or "alias" when reserved (final test, candidates, lineage holdout); nil otherwise.
        var reservedAs: String?
        var admission: Admission
        var admissionReason: String?
        var hasSession: Bool
        var frames: Int
        var reviewedFrames: Int
        /// The legacy "marked every rally" declaration on the session (a declaration, not verified coverage).
        var ralliesMarked: Bool
        var humanLabeledRallies: Int
        var machineRalliesAwaitingCheck: Int
        /// Exposure kinds on record (ledger and seed); nil when the ledger could not be read — unknown, not none.
        var exposure: [String]?
        /// The footage's recording type as a person confirmed it (FootageProperties); unknown without a record.
        var recordingType: FootageProperties.RecordingType
        /// The original this recording derives from, when recorded (FootageProperties.Derivation.parent).
        var derivedFrom: String?
        /// What each model may use of it, and whether its unmarked time may be ordinary negatives (TrainingEligibility).
        var eligibility: TrainingEligibility.Assessment
    }

    struct Index: Codable, Equatable, Sendable {
        var schemaVersion: Int = SourceRegistry.schemaVersion
        var project: String
        var createdAt: Date
        var hashes: DatasetSplitManifest.Hashes
        var sources: [Source]
        /// Inputs that could not be read; the index is still built from the rest, and says so.
        var problems: [String]

        var byVideo: [String: Source] { Dictionary(sources.map { ($0.video, $0) }, uniquingKeysWith: { a, _ in a }) }
        var groups: Int { Set(sources.compactMap(\.aliasGroup)).count + sources.filter { $0.aliasGroup == nil }.count }
        func count(_ admission: Admission) -> Int { sources.filter { $0.admission == admission }.count }
    }

    /// Everything `build` reads, so it runs on fixtures without a project folder.
    struct Inputs {
        var project: Project?
        var sessions: [VideoSession]
        var validation: PipelineTuner.ValidationSet?
        /// Exposure by video (ExposureLog rows and seed); nil when the ledger could not be read.
        var exposure: [String: [ExposureRecord]]?
        /// Footage properties by video (FootageProperties.Store.loadAll); a video whose record could not be read
        /// is in `unreadableProperties` with the reason and is quarantined.
        var properties: [String: FootageProperties.File] = [:]
        var unreadableProperties: [String: String] = [:]
        var problems: [String] = []
        var hashes: DatasetSplitManifest.Hashes
        var now: Date
    }

    // MARK: - Build (pure)

    static func build(_ inputs: Inputs) -> Index {
        var cards: [String: (clip: PlannedClip, source: ClipSource)] = [:]
        for clip in inputs.project?.clips ?? [] {
            for source in clip.videos { cards[DatasetStore.safeName(clip.videoId(of: source))] = (clip, source) }
        }
        let sources = cards.mapValues(\.source)
        let validation = inputs.validation
        let tune = Set(validation?.tune ?? []), holdout = Set(validation?.holdout ?? [])
        let expanded = validation.map { ReservedVideos.expanded($0, sources: sources) } ?? ([], [], [])
        let listedReserved = validation?.reservedAsListed ?? []
        // The one withheld closure every guard uses (ReservedVideos.lineageWithheldNames): listed reservations and
        // the legacy holdout, expanded through every project video's identities.
        let withheld = listedReserved.union(holdout).isEmpty ? Set<String>() : ReservedVideos.closure(of: listedReserved.union(holdout), over: sources)
        let groupOf = ReservedVideos.groups(over: sources)
        let byFingerprint = Dictionary(grouping: sources.compactMap { name, s in ReservedVideos.effectiveFingerprint(s).map { ($0, name) } }, by: \.0).mapValues { $0.map(\.1) }
        let bySourceId = Dictionary(grouping: sources.compactMap { name, s in s.sourceId.flatMap { $0.isEmpty ? nil : ($0, name) } }, by: \.0).mapValues { $0.map(\.1) }
        let sessionsByName = Dictionary(inputs.sessions.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let names = Set(cards.keys).union(sessionsByName.keys)

        let out = names.sorted().map { name -> Source in
            let card = cards[name]
            let session = sessionsByName[name]
            let fingerprint = card.flatMap { ReservedVideos.effectiveFingerprint($0.source) }
            let sourceId = card?.source.sourceId.flatMap { $0.isEmpty ? nil : $0 }
            let (key, confidence): (String, IdentityConfidence)
            if let sourceId { (key, confidence) = ("src:" + sourceId, .confirmed) }
            else if let fingerprint { (key, confidence) = ("fp:" + fingerprint, .inferred) }
            else { (key, confidence) = ("name:" + name, .unknown) }

            let unreserved: DatasetSplit
            if holdout.contains(name) { unreserved = .legacyHoldout }
            else if tune.contains(name) { unreserved = .tune }
            else if session?.split == "val" { unreserved = .devVal }
            else { unreserved = .train }
            let split: DatasetSplit
            if expanded.finalTest.contains(name) { split = .finalTest }
            else if expanded.lineageHoldout.contains(name) { split = .lineageHoldout }
            else if expanded.candidates.contains(name) { split = .finalTestCandidate }
            else { split = unreserved }
            let reservedAs: String? = split.isReserved && split != .legacyHoldout ? (listedReserved.contains(name) ? "listed" : "alias") : nil

            let props = inputs.properties[name]
            let parentWithheld: String? = props?.derivedFrom.flatMap { d in
                let parent = d.parent
                if withheld.contains(parent) || withheld.contains(DatasetStore.safeName(parent)) { return parent }
                // The parent named by identity: any withheld video carrying that confirmed source or fingerprint.
                return withheld.first { w in
                    guard let s = sources[w] else { return false }
                    if let id = s.sourceId, !id.isEmpty, parent == "src:" + id { return true }
                    if let fp = ReservedVideos.effectiveFingerprint(s), parent == "fp:" + fp { return true }
                    return false
                }
            }
            let admission: Admission
            var reason: String?
            if withheld.contains(name) {
                admission = .withheld
                reason = split == .legacyHoldout ? "legacy holdout (validation.json holdout)"
                    : holdout.contains(name) ? "legacy holdout (validation.json holdout)"
                    : reservedAs == "listed" ? "\(split.rawValue), listed in validation.json"
                    : reservedAs == "alias" ? "\(split.rawValue), an alias of a listed recording"
                    : "aliased to a withheld recording (shared file or confirmed identity)"
            } else if let parent = parentWithheld {
                admission = .quarantined
                reason = "derived from withheld recording \(parent) (recorded in its footage properties; the guard closure does not yet follow derivations — phase 3)"
            } else if let why = inputs.unreadableProperties[name] {
                admission = .quarantined
                reason = "footage-properties record unreadable: \(why)"
            } else if session == nil {
                admission = .pendingIngest
                reason = "on card \(card?.clip.id ?? "?") with no dataset session"
            } else if fingerprint == nil {
                admission = .unidentified
                reason = card == nil ? "no project card (no origin, licence or fingerprint on record)" : "no file fingerprint on record"
            } else {
                admission = .admitted
            }

            let tracks = session?.tracks ?? []
            return Source(
                video: name, clipId: card?.clip.id,
                surface: card.map { $0.clip.environment.lowercased() } ?? ClipID.surface(of: name)?.rawValue,
                camera: card?.clip.camera,
                originKind: card?.source.kind.rawValue,
                uploader: card.flatMap { $0.source.uploader.isEmpty ? nil : $0.source.uploader },
                license: card.flatMap { $0.source.license.isEmpty ? nil : $0.source.license },
                pulledFrom: card?.clip.pulledFrom,
                fingerprint: fingerprint,
                identityKey: key, identityConfidence: confidence,
                sourceId: sourceId,
                sessionId: card?.source.sessionId.flatMap { $0.isEmpty ? nil : $0 },
                venueId: card?.source.venueId.flatMap { $0.isEmpty ? nil : $0 },
                aliasGroup: groupOf[name],
                duplicates: fingerprint.flatMap { byFingerprint[$0] }?.filter { $0 != name }.sorted() ?? [],
                sameSource: sourceId.flatMap { bySourceId[$0] }?.filter { other in
                    other != name && (sources[other].flatMap(ReservedVideos.effectiveFingerprint) != fingerprint)
                }.sorted() ?? [],
                split: split, reservedAs: reservedAs,
                admission: admission, admissionReason: reason,
                hasSession: session != nil,
                frames: session?.frames.count ?? 0,
                reviewedFrames: session?.reviewedCount ?? 0,
                ralliesMarked: session?.ralliesMarked ?? false,
                humanLabeledRallies: tracks.filter(LineagePackage.isHumanLabeled).count,
                machineRalliesAwaitingCheck: tracks.filter(\.awaitsRallyCheck).count,
                exposure: inputs.exposure.map { Array(Set(($0[name] ?? []).map(\.kind.rawValue))).sorted() },
                recordingType: props?.recordingType ?? .unknown,
                derivedFrom: props?.derivedFrom?.parent,
                eligibility: TrainingEligibility.assess(admission: admission, properties: props, unreadableReason: inputs.unreadableProperties[name]))
        }
        return Index(project: inputs.project?.name ?? "", createdAt: inputs.now, hashes: inputs.hashes, sources: out, problems: inputs.problems)
    }

    // MARK: - Reading a project

    enum LoadError: LocalizedError {
        case projectUnreadable(String)
        var errorDescription: String? {
            switch self { case .projectUnreadable(let why): return "project.json exists but can't be read, so the recordings' identities are unknown; no index is built: \(why)" }
        }
    }

    /// The project's inputs, strictly where identity depends on it: an unreadable project.json, sessions folder or
    /// validation.json throws (identities and reservations unknown); an unreadable exposure ledger is reported in
    /// `problems` and the index carries no exposure (unknown, never none). No video file is opened.
    static func inputs(root: URL, now: Date = Date()) throws -> Inputs {
        var project: Project?
        let projectURL = root.appendingPathComponent("project.json")
        if FileManager.default.fileExists(atPath: projectURL.path) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            do { project = try decoder.decode(Project.self, from: Data(contentsOf: projectURL)) } catch { throw LoadError.projectUnreadable(error.localizedDescription) }
        }
        let sessions = try DatasetStore(root: root).loadSessionsStrict()
        let validation = try PipelineTuner.ValidationSet.loadStrict(from: root)
        var problems: [String] = []
        var exposure: [String: [ExposureRecord]]?
        do {
            var found: [String: [ExposureRecord]] = [:]
            for row in try ExposureLog.readStrict(in: root) + ExposureLog.readSeedStrict(in: root) {
                found[row.video, default: []].append(ExposureRecord(kind: row.kind, ref: row.ref, date: row.date, note: row.note))
            }
            exposure = found
        } catch {
            problems.append("exposure ledger not read (exposure unknown for every recording): \(error.localizedDescription)")
        }
        let (properties, unreadable) = try FootageProperties.Store(root: root).loadAll()
        for (name, why) in unreadable.sorted(by: { $0.key < $1.key }) { problems.append("footage-properties record for \(name) not read (the recording is quarantined): \(why)") }
        let hashes = DatasetSplitManifest.Hashes(
            projectJson: DatasetSplitManifest.sha256(of: projectURL),
            sessions: DatasetSplitManifest.canonicalDigest(ofDirectory: root.appendingPathComponent("sessions", isDirectory: true)),
            validationJson: DatasetSplitManifest.sha256(of: PipelineTuner.ValidationSet.file(in: root)))
        return Inputs(project: project, sessions: sessions, validation: validation, exposure: exposure, properties: properties, unreadableProperties: unreadable,
                      problems: problems, hashes: hashes, now: now)
    }

    static func load(root: URL, now: Date = Date()) throws -> Index {
        build(try inputs(root: root, now: now))
    }

    // MARK: - Files

    /// Where `--source-index` writes the index: a rebuildable report, never read back as authority.
    static func url(in root: URL, stamp: String) -> URL {
        root.appendingPathComponent("manifests", isDirectory: true).appendingPathComponent("source-index-\(stamp).json")
    }

    static func write(_ index: Index, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(index).write(to: url, options: .atomic)
    }

    /// One line per admission state and a line per source, for the terminal.
    static func summaryLines(_ index: Index) -> [String] {
        var out: [String] = []
        out.append("Sources: \(index.sources.count) in \(index.groups) alias groups — " + Admission.allCases.map { "\($0.rawValue) \(index.count($0))" }.joined(separator: " · "))
        let confirmed = index.sources.filter { $0.identityConfidence == .confirmed }.count
        let inferred = index.sources.filter { $0.identityConfidence == .inferred }.count
        out.append("Identity: \(confirmed) confirmed · \(inferred) inferred from the file · \(index.sources.count - confirmed - inferred) unknown")
        let dups = index.sources.filter { !$0.duplicates.isEmpty }.count
        let same = index.sources.filter { !$0.sameSource.isEmpty }.count
        out.append("Duplicates: \(dups) share a file with another video · \(same) share a confirmed source with another file")
        let characterised = index.sources.filter { $0.recordingType != .unknown || $0.eligibility.fullVideoNegatives.level != .notAssessed }.count
        for model in TrainingEligibility.Model.allCases {
            let levels = Dictionary(grouping: index.sources, by: { $0.eligibility[model].level }).mapValues(\.count)
            out.append("Eligibility, \(model.rawValue): " + [TrainingEligibility.Level.standard, .restricted, .quarantined, .ineligible, .notAssessed].map { "\($0.rawValue) \(levels[$0] ?? 0)" }.joined(separator: " · "))
        }
        out.append("Footage characterised (footage-properties record): \(characterised) of \(index.sources.count); derivatives recorded: \(index.sources.filter { $0.derivedFrom != nil }.count)")
        for p in index.problems { out.append("⚠️ \(p)") }
        return out
    }
}
