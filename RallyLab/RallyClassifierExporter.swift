//
//  RallyClassifierExporter.swift
//  RallyLab
//
//  The training/evaluation dataset of the learned temporal rally classifier,
//  `rally_classifier_dataset_v1` (docs/ml-roadmap/RALLY_CLASSIFIER_DATASET_CONTRACT.md),
//  for one project — the plan of docs/ml-roadmap/RALLY_CLASSIFIER_DATA_READINESS_PLAN §3.
//  One operation does all of it, so a new caller cannot skip a guard or the ledger:
//
//   1. the split manifest as written, its hashes checked against the project as it is
//      now (a stale manifest is refused), and the leakage audit run on it: no hard finding;
//   2. the withheld closure (ReservedVideos.lineageWithheldNames, the one withheld rule);
//      an empty closure is refused, and no candidate may be in it or share an identity
//      or alias group with a withheld recording (LineagePackage.isolation) — before any
//      video is opened;
//   3. the plan: development-split recordings whose pass is complete, each admitted
//      (SourceRegistry) and eligible for the rally classifier (TrainingEligibility, through
//      the registry); the rest listed with why. Written first, never overwritten;
//   4. the marks read through RallyTruth (a rally is kind `rally` or none; missed serves
//      and other marks are excluded spans; cuts are cut ranges), the footage type and the
//      time-breaking spans from the footage-properties record as the registry admitted it;
//   5. per recording, the detector's evidence (VideoProcessor live, the committed config
//      with the card's camera) as steps (rcf_v1, causal) with the contract's labels, and
//      the committed decider's clips per baseline variant with their pre-merge raw spans;
//   6. staging, file hashes, the manifest last; a Swift preflight and then the repository's
//      validator (`scripts/rally_classifier/validate_dataset.py`), which must pass — no
//      python3, no dataset;
//   7. the exposure ledger (`training_package`) for every packaged recording, and only
//      then the move into place.
//
//  A failure before the manifest is written (a recording's evidence, a write) leaves the
//  staging folder and its journal so `--resume` keeps the finished recordings (their files
//  re-hashed); a failure from the manifest on (preflight, validator, ledger) removes them.
//  No ledger row is written for a dataset that did not pass. The coverage-audit gate (G7)
//  proposed on PR #138 is not applied: each recording carries `coverage.state`, and the
//  gate would layer on it.
//

import AVFoundation
import CryptoKit
import Foundation

enum RallyClassifierExporter {
    static let schemaVersion = "rally_classifier_dataset_v1"
    static let featureVersion = "rcf_v1"
    static let labelVersion = "rally_activity_truth_v1"
    static let replayer = "EvidenceReplayer.decidedRallies"
    static let timescale = 600
    /// A gap between processed frames longer than this breaks the segment.
    static let gapSec = 0.5
    static let boundaryIgnoreSec = 0.5
    static let samplingHzNominal = 30
    /// RallyDecider's production minimum rally.
    static let minRallySec = 1.1653
    static let ledgerRef = "--export-rally-classifier-dataset"

    /// The rcf_v1 columns, in order (contract §4.1): name and whether the column may be null.
    static let features: [(name: String, nullable: Bool)] = [
        ("dt", true), ("has_ball", false), ("n_court_dets", false), ("n_dets", false), ("max_conf", true),
        ("ball_y_any", true), ("is_projectile", false), ("sel_x", true), ("sel_y", true), ("sel_size", true),
        ("r2", true), ("grav", true), ("n_cands", false), ("n_cands_proj", false), ("n_cands_rejected", false),
        ("y_above_net", true), ("serve_emitted", false), ("serve_contact_offset", true),
    ]

    /// The label states (contract §5) and their loss weights.
    enum State: Int, CaseIterable {
        case nonRally = 0, activeRally = 1, transition = 2, unknown = 3, excluded = 4, nonRallyActivity = 5
        var name: String {
            switch self {
            case .nonRally: return "NON_RALLY"
            case .activeRally: return "ACTIVE_RALLY"
            case .transition: return "TRANSITION"
            case .unknown: return "UNKNOWN"
            case .excluded: return "EXCLUDED"
            case .nonRallyActivity: return "NON_RALLY_ACTIVITY"
            }
        }
        var weight: Double { [.nonRally, .activeRally, .nonRallyActivity].contains(self) ? 1 : 0 }
    }

    // MARK: - Baseline variants

    /// A decider variant the baseline is replayed at: `r0` the committed config (the benchmark), `r0_prime` the
    /// D-029 settings (reference only; the preregistration's R0′).
    struct Variant {
        var name: String
        var config: ProcessorConfig
    }

    static let variantNames = ["r0", "r0_prime"]

    static func variant(named name: String) -> Variant? {
        switch name {
        case "r0": return Variant(name: name, config: ProcessorConfig())
        case "r0_prime":
            var c = ProcessorConfig()
            c.minGapToMerge = 0
            c.postroll = 1.0
            c.preroll = 2.0
            c.minSegmentLength = 1.5
            return Variant(name: name, config: c)
        default: return nil
        }
    }

    // MARK: - Inputs and outputs

    /// What a recording's evidence is: every processed frame, the duration, the asset's frame rate and upright aspect,
    /// and the multi-frame model the detector actually ran (nil when it ran without one — a fallback to YOLO).
    struct Evidence {
        var frames: [VideoProcessor.FrameEvidence]
        var duration: Double
        var frameRate: Double
        var aspect: Double
        var detector: URL?
    }

    /// The detector run over one recording at a config (the live pipeline in production; synthetic in tests).
    typealias EvidenceSource = (VideoSession, ProcessorConfig) async throws -> Evidence

    struct Options {
        /// The dataset's name: its folder.
        var name: String
        /// The folder that receives `<name>` (and the staging folder while it is written).
        var out: URL
        var variants: [String] = RallyClassifierExporter.variantNames
        /// A staging folder of a run cut short (`<out>/.staging-<name>`): its verified recordings are kept.
        var resume: URL? = nil
        /// `scripts/rally_classifier/validate_dataset.py`.
        var validator: URL
        var python = "python3"
        /// The commit the exporter was built from (`buildRevision`).
        var codeSha: String
        /// The running executable's SHA-256 (`executableSha256`): part of a resume's identity, with the commit.
        var binarySha: String
        /// What wrote it (the app's version).
        var tool: String
        var now = Date()
    }

    struct LeftOut: Codable, Equatable {
        var video: String
        var reason: String
    }

    struct Check: Codable, Equatable {
        var name: String
        var passed: Bool
        var detail: String
    }

    struct Result {
        var dataset: URL
        /// The registry's canonical digest of every file but the manifest.
        var digest: String
        var manifestSha256: String
        var recordings: [String]
        var leftOut: [LeftOut]
        var reused: [String]
        var plan: URL
        var report: URL
    }

    enum Failure: LocalizedError, Equatable {
        case badName(String)
        case exists(URL)
        case stagingExists(URL)
        case resumeMismatch(String)
        case noManifest(URL)
        case staleManifest(String)
        case emptyClosure
        case badVariants(String)
        case detectorUnknown(String)
        case detectorNotUsed(String)
        case noCodeSha
        case planExists(URL)
        case footageMissing([String])
        case noRecordings
        case unreadable(String)
        case preflightFailed([String])
        case validatorUnavailable(String)
        case validationFailed([String])

        var errorDescription: String? {
            switch self {
            case .badName(let n): return "\(n) is not a dataset name: letters, digits, '-', '_' and '.', not starting with '.'."
            case .exists(let u): return "\(u.path) already exists; a dataset is never overwritten."
            case .stagingExists(let u): return "\(u.path) holds an earlier run cut short: give it to --resume, or remove it."
            case .resumeMismatch(let why): return "The folder given to --resume is not this dataset's staging folder: \(why)."
            case .noManifest(let u): return "No split manifest at \(u.path)."
            case .staleManifest(let why): return "The split manifest is not the project's current one (\(why)); rebuild it before exporting."
            case .emptyClosure: return "The withheld closure is empty (no validation.json reservations): an empty closure proves nothing, so no dataset is written."
            case .badVariants(let why): return "Baseline variants: \(why)."
            case .detectorUnknown(let why): return "The detector can't be identified: \(why)."
            case .detectorNotUsed(let why): return "The evidence is not the dataset's detector's: \(why). Nothing of it is exported (the staging folder is kept for --resume once the model loads)."
            case .noCodeSha: return "The commit or the executable the exporter was built as is unknown; no dataset is written without them."
            case .planExists(let u): return "\(u.path) already exists; run again."
            case .footageMissing(let v): return "The original of \(v.count) recording(s) to export is not on this Mac (\(v.joined(separator: ", "))): bring the footage back and run again (the plan is written)."
            case .noRecordings: return "No recording is eligible for the dataset (see the plan)."
            case .unreadable(let why): return why
            case .preflightFailed(let c): return "Preflight failed: \(c.joined(separator: ", ")). The staging folder was removed."
            case .validatorUnavailable(let why): return "The dataset validator could not run (\(why)); the dataset is not written unvalidated. The staging folder was removed."
            case .validationFailed(let e): return "The dataset validator refused the dataset: \(e.prefix(5).joined(separator: "; "))\(e.count > 5 ? " (+\(e.count - 5) more)" : ""). The staging folder was removed."
            }
        }
    }

    // MARK: - The operation

    /// Writes the dataset `options.name` into `options.out` from the project at `projectDir`, with the split
    /// manifest at `manifestURL` (written by `--manifest` / buildManifest just before). Every guard, the plan, the
    /// validation and the ledger are here; the caller only supplies the evidence and the paths.
    static func export(projectDir: URL, manifestURL: URL, options: Options, evidence: EvidenceSource,
                       log: (String) -> Void = { _ in }) async throws -> Result {
        let fm = FileManager.default
        let name = options.name
        guard isSafeName(name) else { throw Failure.badName(name) }
        guard !options.codeSha.isEmpty, !options.binarySha.isEmpty else { throw Failure.noCodeSha }
        let final = options.out.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: final.path) else { throw Failure.exists(final) }
        let staging = options.resume ?? options.out.appendingPathComponent(".staging-\(name)", isDirectory: true)
        let journalURL = URL(fileURLWithPath: staging.path + ".journal.json")
        if options.resume == nil {
            guard !fm.fileExists(atPath: staging.path), !fm.fileExists(atPath: journalURL.path) else { throw Failure.stagingExists(staging) }
        } else {
            guard staging.deletingLastPathComponent().standardizedFileURL.path == options.out.standardizedFileURL.path,
                  staging.lastPathComponent == ".staging-\(name)" else { throw Failure.resumeMismatch("expected \(options.out.appendingPathComponent(".staging-\(name)").path)") }
        }

        // Variants: r0 required, names known and unique.
        var variants: [Variant] = []
        for v in options.variants {
            guard let variant = variant(named: v) else { throw Failure.badVariants("unknown variant \(v) (known: \(variantNames.joined(separator: ", ")))") }
            guard !variants.contains(where: { $0.name == v }) else { throw Failure.badVariants("\(v) given twice") }
            variants.append(variant)
        }
        guard variants.contains(where: { $0.name == "r0" }) else { throw Failure.badVariants("r0 (the committed decider, H1's benchmark) is required") }

        // The committed config and its detector: one detector per dataset, the multi-frame model.
        let config = ProcessorConfig()
        guard config.heatmapOnly, let model = config.heatmapModel else { throw Failure.detectorUnknown("the committed config does not run the multi-frame model alone") }
        guard let modelDigest = DatasetSplitManifest.canonicalDigest(ofDirectory: model) else { throw Failure.detectorUnknown("\(model.path) can't be read") }
        let detector = Detector(name: model.deletingPathExtension().lastPathComponent, canonicalDigest: String(modelDigest.prefix(16)))
        let configSha = config.canonicalSHA256

        // 1. The split manifest, current, and its audit.
        guard let manifest = try DatasetSplitManifest.readStrict(from: manifestURL) else { throw Failure.noManifest(manifestURL) }
        let current = currentHashes(projectDir)
        for (label, have, now) in [("project.json", manifest.hashes.projectJson, current.projectJson),
                                   ("sessions", manifest.hashes.sessions, current.sessions),
                                   ("validation.json", manifest.hashes.validationJson, current.validationJson)] {
            guard let have, let now else { throw Failure.staleManifest("\(label) has no hash") }
            guard have == now else { throw Failure.staleManifest("\(label) changed since it was built") }
        }
        guard let manifestSha = DatasetSplitManifest.sha256(of: manifestURL) else { throw Failure.noManifest(manifestURL) }
        let audit = DatasetAudit.run(manifest: manifest, now: options.now)

        // 2. The withheld closure and the isolation, before any video is read.
        let closure = try ReservedVideos.lineageWithheldNames(in: projectDir)
        guard !closure.isEmpty else { throw Failure.emptyClosure }
        let (_, isolated) = try LineagePackage.isolation(manifest: manifest, audit: audit, withheldClosure: closure)
        let sources = ReservedVideos.sources(in: projectDir)
        let withheld = Withheld(names: closure.sorted(),
                                sourceIds: Set(closure.compactMap { sources[$0]?.sourceId }.filter { !$0.isEmpty }).sorted(),
                                fingerprints: Set(closure.compactMap { sources[$0].flatMap(ReservedVideos.effectiveFingerprint) }).sorted())

        // 3. The plan.
        let registry = try SourceRegistry.load(root: projectDir, now: options.now)
        let ledger: [DatasetSplitManifest.ExposureLogRow]
        do { ledger = try ExposureLog.readStrict(in: projectDir) + ExposureLog.readSeedStrict(in: projectDir) } catch { throw Failure.unreadable(error.localizedDescription) }
        let properties = try FootageProperties.Store(root: projectDir).loadAll().records
        let sessions = Dictionary(try DatasetStore(root: projectDir).loadSessionsStrict().map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = Dictionary(manifest.videos.map { ($0.video, $0) }, uniquingKeysWith: { a, _ in a })
        let bySource = registry.byVideo

        // By content, as the L2 package checks it: every identity a withheld recording's video can have on disk
        // (LineagePackage.protectedSourceFingerprints — a withheld recording with no file here can't be recognised and
        // stops the run). The closure the dataset carries holds these too, so the preflight and the validator check
        // them again; the plan below leaves out any recording that matches one, before a video is processed.
        let protectedContent: Set<String>
        do { protectedContent = try LineagePackage.protectedSourceFingerprints(sessions: Array(sessions.values), withheld: closure, sources: sources) }
        catch { throw Failure.unreadable(error.localizedDescription) }
        let withheldFull = Withheld(names: withheld.names, sourceIds: withheld.sourceIds,
                                    fingerprints: Set(withheld.fingerprints).union(protectedContent).sorted())

        var planned: [Planned] = []
        var leftOut: [LeftOut] = []
        var missing: [String] = []
        for e in isolated.sorted(by: { $0.video < $1.video }) {
            func out(_ why: String) { leftOut.append(LeftOut(video: e.video, reason: why)) }
            guard [.train, .devVal, .tune].contains(e.split) else { out("split \(e.split.rawValue) is not a development split"); continue }
            guard e.ralliesMarked else { out("the pass is not complete (not every rally marked): what lies outside the marks is unknown"); continue }
            guard let source = bySource[e.video] else { out("not in the source registry"); continue }
            guard source.admission == .admitted else { out("admission \(source.admission.rawValue)" + (source.admissionReason.map { ": \($0)" } ?? "")); continue }
            let verdict = source.eligibility[.rallyClassifier]
            guard [.standard, .restricted].contains(verdict.level) else { out("rally classifier: \(verdict.level.rawValue) — \(verdict.reasons.joined(separator: "; "))"); continue }
            guard let session = sessions[e.video], let row = rows[e.video] else { out("no dataset session"); continue }
            let video = URL(fileURLWithPath: session.sourcePath)
            if fm.fileExists(atPath: EventReview.url(forVideo: video).path) {
                out("has a Stage 1 boundary record: this exporter version reads legacy declared marks only (stage1_complete is not written yet)"); continue
            }
            let marksURL = RallyMarkModel.labelsURL(for: video)
            let records: [RallyMarkRecord]
            do {
                guard fm.fileExists(atPath: marksURL.path) else { out("no rally marks beside the video"); continue }
                records = try JSONDecoder().decode([RallyMarkRecord].self, from: Data(contentsOf: marksURL))
            } catch { out("rally marks unreadable: \(error.localizedDescription)"); continue }
            let cuts = session.cutRanges
            let truth = RallyTruth(marks: records.map { RallyTruth.Mark(start: $0.startTime, end: $0.endTime, kind: $0.kind) }, cuts: cuts, complete: true)
            // A rally mark inside non-footage is an error (contract §5), never trimmed into a shorter rally.
            if let bad = records.first(where: { r in RallyTruth.isRally(r.kind) && cuts.contains { $0.start < r.endTime && r.startTime < $0.end } }) {
                out("rally \(clockText(bad.startTime))–\(clockText(bad.endTime)) overlaps a cut range: a rally mark inside non-footage"); continue
            }
            let rallies = truth.pieces.filter { RallyTruth.isRally($0.kind) }
            if let overlap = zip(rallies, rallies.dropFirst()).first(where: { $1.start < $0.end }) {
                out("rallies \(clockText(overlap.0.start)) and \(clockText(overlap.1.start)) overlap"); continue
            }
            // The original's content identity as it is now, so a resume never keeps evidence of a file since replaced.
            guard fm.fileExists(atPath: session.sourcePath), let content = ProjectsModel.fileFingerprint(atPath: session.sourcePath) else { missing.append(e.video); continue }
            // Withheld footage under this recording's card, by any identity the preflight checks: the fingerprint the
            // card was registered with (a re-encoded original has new bytes but the same footage), the confirmed
            // source, or the original's content. Left out here, so it is never processed and refused only at the end.
            if let match = withheldIdentity(name: e.video, sourceId: confirmedSourceId(row), fingerprint: row.fingerprint, content: content, in: withheldFull) {
                let why = "the same footage as a withheld recording (its \(match) is one of the withheld identities): fix the split before it can be exported"
                log("⚠️ \(e.video): \(why)")
                out(why); continue
            }
            planned.append(Planned(video: e.video, session: session, row: row, source: source, records: records, truth: truth,
                                   marksSha256: DatasetSplitManifest.sha256(of: marksURL) ?? "", properties: properties[e.video], fileFingerprint: content))
        }

        let stamp = stampFormatter.string(from: options.now)
        let records = projectDir.appendingPathComponent("manifests/rally-classifier", isDirectory: true)
        let planURL = records.appendingPathComponent("\(stamp)-plan.json")
        guard !fm.fileExists(atPath: planURL.path) else { throw Failure.planExists(planURL) }
        try fm.createDirectory(at: records, withIntermediateDirectories: true)
        let plan = PlanFile(schemaVersion: schemaVersion, dataset: name, project: manifest.project, createdAt: iso(options.now),
                            manifestSha256: manifestSha, splitManifest: manifest.hashes, auditHard: 0,
                            withheld: withheld, included: planned.map(\.video), footageMissing: missing.sorted(), leftOut: leftOut)
        try encode(plan).write(to: planURL, options: .withoutOverwriting)
        try planMarkdown(plan).write(to: records.appendingPathComponent("\(stamp)-plan.md"), atomically: true, encoding: .utf8)
        log("✅ plan: \(planned.count) recording(s) to export, \(leftOut.count) left out, \(missing.count) without footage → \(planURL.path)")
        guard missing.isEmpty else { throw Failure.footageMissing(missing.sorted()) }
        guard !planned.isEmpty else { throw Failure.noRecordings }

        let closureURL = records.appendingPathComponent("\(stamp)-closure.json")
        try encode(withheldFull).write(to: closureURL, options: .withoutOverwriting)

        // Groups (contract §6): same card, alias group, uploader, confirmed source/session/venue, or fingerprint —
        // the card's or the file's (one video under two names is one group).
        let groups = groupIds(planned.map(\.row), content: Dictionary(planned.map { ($0.video, $0.fileFingerprint) }, uniquingKeysWith: { a, _ in a }))

        // 4–5. Evidence, steps, baseline — into staging, journaled per recording.
        let identity = JournalIdentity(dataset: name, codeSha: options.codeSha, binarySha: options.binarySha, pipelineConfigSha256: configSha, detector: detector,
                                       variants: variants.map { VariantDTO(name: $0.name, configSha256: $0.config.canonicalSHA256, settings: Settings($0.config)) })
        var journal = Journal(identity: identity, recordings: [:])
        if options.resume != nil {
            guard fm.fileExists(atPath: staging.path), let data = try? Data(contentsOf: journalURL), let read = try? JSONDecoder().decode(Journal.self, from: data) else {
                throw Failure.resumeMismatch("no readable journal at \(journalURL.path)")
            }
            guard read.identity == identity else { throw Failure.resumeMismatch("it was written with another code, config, detector or variant set") }
            journal = read
        }
        try fm.createDirectory(at: staging.appendingPathComponent("steps"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("baseline"), withIntermediateDirectories: true)
        var recordingsOut: [Recording] = []
        var reused: [String] = []
        for (i, p) in planned.enumerated() {
            let key = inputKey(p)
            let exposure = ledger.filter { $0.video == p.video }.map { ExposureDTO(date: $0.date, kind: $0.kind.rawValue, ref: $0.ref) }
            if let done = journal.recordings[p.video], done.inputKey == key,
               DatasetSplitManifest.sha256(of: staging.appendingPathComponent(done.record.stepsFile)) == done.record.stepsSha256,
               DatasetSplitManifest.sha256(of: staging.appendingPathComponent(done.record.baselineFile)) == done.record.baselineSha256 {
                var r = done.record
                r.groupId = groups[p.video] ?? p.video
                r.split = p.row.split.rawValue
                r.exposure = exposure
                recordingsOut.append(r)
                reused.append(p.video)
                log("  [\(i + 1)/\(planned.count)] \(p.video): kept from the run cut short (files verified)")
                continue
            }
            log("  [\(i + 1)/\(planned.count)] \(p.video): running the detector…")
            let ev = try await evidence(p.session, config.withCamera(of: p.session))
            // The evidence must be the named detector's alone: the model loaded (no fallback to YOLO), every detection its own.
            guard ev.detector?.standardizedFileURL.path == model.standardizedFileURL.path else {
                throw Failure.detectorNotUsed("\(p.video): the multi-frame model \(model.lastPathComponent) did not load for it (the pipeline fell back)")
            }
            if let yolo = ev.frames.first(where: { $0.detections.contains { !$0.fromHeatmap } }) {
                throw Failure.detectorNotUsed("\(p.video): a detection at \(clockText(yolo.time)) is not the multi-frame model's")
            }
            let built = try build(p, evidence: ev, variants: variants, config: config, groupId: groups[p.video] ?? p.video, exposure: exposure)
            let stepsURL = staging.appendingPathComponent(built.record.stepsFile)
            let baselineURL = staging.appendingPathComponent(built.record.baselineFile)
            try built.steps.write(to: stepsURL, options: .atomic)
            try built.baseline.write(to: baselineURL, options: .atomic)
            var record = built.record
            record.stepsSha256 = DatasetSplitManifest.sha256(of: stepsURL) ?? ""
            record.baselineSha256 = DatasetSplitManifest.sha256(of: baselineURL) ?? ""
            recordingsOut.append(record)
            journal.recordings[p.video] = JournalEntry(inputKey: key, record: record)
            try encode(journal).write(to: journalURL, options: .atomic)
            log("    \(record.stepCount) steps · " + State.allCases.map { "\($0.name) \(record.labelCounts[$0.name] ?? 0)" }.joined(separator: " · "))
        }

        // 6–7. From the manifest on, a failure leaves nothing: no folder, no journal, no ledger row.
        func discard() {
            try? fm.removeItem(at: staging)
            try? fm.removeItem(at: journalURL)
        }
        do {
            // Files of recordings no longer in the plan (a resumed folder) are not this dataset's.
            let referenced = Set(recordingsOut.flatMap { [$0.stepsFile, $0.baselineFile] })
            for dir in ["steps", "baseline"] {
                for f in (try? fm.contentsOfDirectory(atPath: staging.appendingPathComponent(dir).path)) ?? [] where !referenced.contains("\(dir)/\(f)") {
                    try fm.removeItem(at: staging.appendingPathComponent(dir).appendingPathComponent(f))
                }
            }
            let manifestOut = DatasetManifest(
                schemaVersion: schemaVersion, createdAt: iso(options.now),
                generator: Generator(tool: options.tool, codeSha: options.codeSha), project: manifest.project,
                splitManifest: SplitHashes(projectJson: manifest.hashes.projectJson ?? "", sessions: manifest.hashes.sessions ?? "",
                                           validationJson: manifest.hashes.validationJson ?? "", manifestJson: manifestSha),
                withheld: withheldFull, detector: detector, pipelineConfigSha256: configSha, timescale: timescale,
                samplingHzNominal: samplingHzNominal, featureSchema: FeatureSchema(), labelSchema: LabelSchema(),
                baseline: BaselineBlock(replayer: replayer, variants: identity.variants), recordings: recordingsOut)
            let manifestFile = staging.appendingPathComponent("dataset-manifest.json")
            try encode(manifestOut, pretty: true).write(to: manifestFile, options: .atomic)

            // Preflight (Swift), then the validator.
            let checks = preflight(staging: staging, manifest: manifestOut, closure: closure, registry: bySource,
                                   content: Dictionary(planned.map { ($0.video, $0.fileFingerprint) }, uniquingKeysWith: { a, _ in a }),
                                   protectedContent: protectedContent)
            let failed = checks.filter { !$0.passed }
            guard failed.isEmpty else { throw Failure.preflightFailed(failed.map { "\($0.name) (\($0.detail))" }) }
            let validation = await validate(staging: staging, closure: closureURL, options: options)
            try validation.raw.write(to: records.appendingPathComponent("\(stamp)-validation.json"), options: .atomic)
            switch validation.outcome {
            case .unavailable(let why): throw Failure.validatorUnavailable(why)
            case .refused(let errors): throw Failure.validationFailed(errors)
            case .passed: break
            }
            guard let files = DatasetSplitManifest.canonicalFileHashes(ofDirectory: staging) else { throw Failure.unreadable("the staged dataset can't be re-read") }
            let digest = DatasetSplitManifest.canonicalDigest(lines: files.filter { $0.path != "dataset-manifest.json" }.map { ($0.path, $0.sha256) })
            guard let datasetManifestSha = DatasetSplitManifest.sha256(of: manifestFile) else { throw Failure.unreadable("the staged manifest can't be re-read") }

            // The ledger, then the move.
            try ExposureLog.record(videos: Set(recordingsOut.map(\.recordingId)), kind: .trainingPackage, ref: "\(ledgerRef) \(name)",
                                   note: "\(schemaVersion) digest \(digest.prefix(16)); detector \(detector.name)@\(detector.canonicalDigest)",
                                   in: projectDir, now: options.now)
            try fm.moveItem(at: staging, to: final)
            let journalCopy = records.appendingPathComponent("\(name)-journal.json")
            try? fm.removeItem(at: journalCopy)
            try? fm.moveItem(at: journalURL, to: journalCopy)
            let report = ExportReport(dataset: name, path: final.path, digest: digest, manifestSha256: datasetManifestSha, splitManifest: manifestOut.splitManifest,
                                      detector: detector, pipelineConfigSha256: configSha, codeSha: options.codeSha, binarySha: options.binarySha,
                                      recordings: recordingsOut.map(\.recordingId),
                                      reused: reused, leftOut: leftOut, preflight: checks,
                                      labelCounts: Dictionary(State.allCases.map { s in (s.name, recordingsOut.reduce(0) { $0 + ($1.labelCounts[s.name] ?? 0) }) }, uniquingKeysWith: +))
            let reportURL = records.appendingPathComponent("\(stamp)-export.json")
            try encode(report, pretty: true).write(to: reportURL, options: .atomic)
            try reportMarkdown(report).write(to: records.appendingPathComponent("\(stamp)-export.md"), atomically: true, encoding: .utf8)
            return Result(dataset: final, digest: digest, manifestSha256: datasetManifestSha, recordings: recordingsOut.map(\.recordingId),
                          leftOut: leftOut, reused: reused, plan: planURL, report: reportURL)
        } catch {
            if !fm.fileExists(atPath: final.path) { discard() }
            throw error
        }
    }

    // MARK: - Planning helpers

    /// Which of a recording's identities is a withheld one — its name, confirmed sourceId, card fingerprint or its
    /// original's content fingerprint — or nil. The plan leaves such a recording out; the preflight refuses one that
    /// got through anyway. One rule for both, so the plan can't pass what the preflight then refuses.
    static func withheldIdentity(name: String, sourceId: String?, fingerprint: String?, content: String?, in w: Withheld) -> String? {
        if w.names.contains(name) { return "name" }
        if let sourceId, w.sourceIds.contains(sourceId) { return "sourceId" }
        if let fingerprint, w.fingerprints.contains(fingerprint) { return "fingerprint" }
        if let content, w.fingerprints.contains(content) { return "content" }
        return nil
    }

    /// A manifest row's sourceId when a person confirmed it; an inferred one identifies nothing.
    static func confirmedSourceId(_ row: ManifestVideo) -> String? { row.sourceId.origin == .confirmed ? row.sourceId.value : nil }

    struct Planned {
        var video: String
        var session: VideoSession
        var row: ManifestVideo
        var source: SourceRegistry.Source
        var records: [RallyMarkRecord]
        var truth: RallyTruth
        var marksSha256: String
        var properties: FootageProperties.File?
        /// The original's content fingerprint read at planning (ProjectsModel.fileFingerprint).
        var fileFingerprint: String
    }

    static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) }
    }

    static func currentHashes(_ dir: URL) -> DatasetSplitManifest.Hashes {
        DatasetSplitManifest.Hashes(
            projectJson: DatasetSplitManifest.sha256(of: dir.appendingPathComponent("project.json")),
            sessions: DatasetSplitManifest.canonicalDigest(ofDirectory: dir.appendingPathComponent("sessions", isDirectory: true)),
            validationJson: DatasetSplitManifest.sha256(of: PipelineTuner.ValidationSet.file(in: dir)))
    }

    /// Recording groups over the planned rows: same card, alias group, uploader, confirmed sourceId / sessionId /
    /// venueId, or file fingerprint, transitively; a group is named by its smallest recording.
    static func groupIds(_ rows: [ManifestVideo], content: [String: String] = [:]) -> [String: String] {
        var parent = Dictionary(uniqueKeysWithValues: rows.map { ($0.video, $0.video) })
        func find(_ x: String) -> String { var r = x; while parent[r] != r { r = parent[r]! }; return r }
        var owner: [String: String] = [:]
        for r in rows {
            var keys: [String] = []
            if let c = r.clipId { keys.append("card:" + c) }
            if let g = r.aliasGroup { keys.append("alias:" + g) }
            if let u = r.uploader, !u.isEmpty { keys.append("uploader:" + u) }
            if let f = r.fingerprint { keys.append("fp:" + f) }
            if let f = content[r.video] { keys.append("fp:" + f) }
            for (k, v) in [("src:", r.sourceId), ("ses:", r.sessionId), ("ven:", r.venueId)] where v.origin == .confirmed {
                if let value = v.value, !value.isEmpty { keys.append(k + value) }
            }
            for k in keys {
                if let o = owner[k] { parent[find(r.video)] = find(o) } else { owner[k] = r.video }
            }
        }
        var members: [String: [String]] = [:]
        for r in rows { members[find(r.video), default: []].append(r.video) }
        var out: [String: String] = [:]
        for names in members.values { let id = names.min()!; for n in names { out[n] = id } }
        return out
    }

    /// What a recording's files are made from: if it is the same, a resumed run keeps them.
    static func inputKey(_ p: Planned) -> String {
        struct Key: Encodable {
            var video: String
            var fingerprint: String?
            var fileFingerprint: String
            var sourcePath: String
            var marksSha256: String
            var cuts: [CutRange]
            var properties: FootageProperties.File?
            var eligibility: TrainingEligibility.Assessment
            var recordingType: String
            var camera: String
        }
        let key = Key(video: p.video, fingerprint: p.row.fingerprint, fileFingerprint: p.fileFingerprint, sourcePath: p.session.sourcePath, marksSha256: p.marksSha256,
                      cuts: p.session.cutRanges, properties: p.properties, eligibility: p.source.eligibility,
                      recordingType: p.source.recordingType.rawValue, camera: ProcessorConfig().withCamera(of: p.session).canonicalSHA256)
        let data = (try? encode(key)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - One recording

    struct Built {
        var record: Recording
        var steps: Data
        var baseline: Data
    }

    /// The labels' inputs for one recording, in ticks (contract §5).
    struct LabelInputs {
        var rallies: [RallyDTO]
        var excluded: [SpanDTO]
        var cuts: [SpanDTO]
        var timeBreaking: [TimeBreakingDTO]
        var nonRallyActivity: [SpanDTO]
        var negatives: Bool
        var ignoreTicks: Int
    }

    static func tick(_ seconds: Double) -> Int { Int((seconds * Double(timescale)).rounded(.toNearestOrEven)) }

    /// The contract's §5 rule: EXCLUDED > TRANSITION > ACTIVE_RALLY > NON_RALLY_ACTIVITY > NON_RALLY > UNKNOWN.
    static func state(_ tick: Int, _ l: LabelInputs) -> State {
        func inside(_ s: Int, _ e: Int) -> Bool { s <= tick && tick < e }
        if l.cuts.contains(where: { inside($0.startTick, $0.endTick) }) || l.timeBreaking.contains(where: { inside($0.startTick, $0.endTick) })
            || l.excluded.contains(where: { inside($0.startTick, $0.endTick) }) { return .excluded }
        for r in l.rallies {
            let hs = max(l.ignoreTicks, r.contactUncertaintyTicks ?? 0), he = max(l.ignoreTicks, r.deadUncertaintyTicks ?? 0)
            if abs(tick - r.startTick) < hs || abs(tick - r.endTick) < he { return .transition }
        }
        if l.excluded.contains(where: { abs(tick - $0.startTick) < l.ignoreTicks || abs(tick - $0.endTick) < l.ignoreTicks }) { return .transition }
        if l.rallies.contains(where: { inside($0.startTick, $0.endTick) }) { return .activeRally }
        if l.nonRallyActivity.contains(where: { inside($0.startTick, $0.endTick) }) { return .nonRallyActivity }
        return l.negatives ? .nonRally : .unknown
    }

    /// A boundary of a cut range or a time-breaking span in `(prev, tick]`: the segment breaks there.
    static func crossesNonFootage(_ prev: Int, _ tick: Int, _ l: LabelInputs) -> Bool {
        let spans = l.cuts.map { ($0.startTick, $0.endTick) } + l.timeBreaking.map { ($0.startTick, $0.endTick) }
        return spans.contains { s, e in (prev < s && s <= tick) || (prev < e && e <= tick) }
    }

    /// The rcf_v1 row of one processed frame (contract §4.1). Unit columns are clamped to [0, 1] (a fit's r² can
    /// fall below 0); a non-finite reading is null.
    static func featureRow(_ f: VideoProcessor.FrameEvidence, previous: Double?, net: DetectedNet?, serve: (emitted: Bool, offset: Double?)) -> [Double?] {
        func unit(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil } }
        func finite(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
        let selected = f.candidates.first { $0.isSelected }
        let selY = f.trackPoint.map { Double($0.y) }
        let sel = unit(selY)
        return [
            previous.map { f.time - $0 },
            f.hasBall ? 1 : 0,
            Double(f.detections.filter { !$0.isOffCourt }.count),
            Double(f.detections.count),
            unit(f.detections.map { Double($0.confidence) }.max()),
            unit(EvidenceReplayer.ballHeight(f).map(Double.init)),
            f.isProjectile ? 1 : 0,
            unit(f.trackPoint.map { Double($0.x) }),
            sel,
            f.trackPoint == nil ? nil : finite(selected.map { max(0, Double($0.ballSize)) }),
            unit(f.rSquared),
            unit(f.gravitySignature),
            Double(f.candidates.count),
            Double(f.candidates.filter(\.isProjectile).count),
            Double(f.candidates.filter { $0.rejectionReason != nil }.count),
            net.flatMap { n in sel.map { $0 - Double(n.box.maxY) } },
            serve.emitted ? 1 : 0,
            serve.emitted ? max(0, serve.offset ?? 0) : nil,
        ]
    }

    /// The serves ServeWatch settles, step by step, fed exactly as the pipeline and the replayer feed it (the frame's
    /// on-court balls): at each step whether one was emitted there and how far back its contact lies (the latest).
    static func serveEmissions(_ frames: [VideoProcessor.FrameEvidence]) -> [(emitted: Bool, offset: Double?)] {
        var watch = ServeWatch()
        return frames.map { f in
            let serves = watch.add(.init(t: f.time, balls: f.detections.filter { !$0.isOffCourt }.map(\.bbox)))
            guard let latest = serves.map(\.contact).max() else { return (false, nil) }
            return (true, f.time - latest)
        }
    }

    static func build(_ p: Planned, evidence ev: Evidence, variants: [Variant], config: ProcessorConfig, groupId: String,
                      exposure: [ExposureDTO]) throws -> Built {
        let durationTicks = tick(ev.duration)
        // Frames in presentation order; a frame at a time already seen is dropped (the steps' times strictly increase).
        var frames: [VideoProcessor.FrameEvidence] = []
        for f in ev.frames.sorted(by: { $0.time < $1.time }) where f.time.isFinite && (frames.last.map { f.time > $0.time } ?? true) { frames.append(f) }
        let net = frames.lazy.compactMap(\.detectedNet).first

        // Truth, in ticks.
        let rallies: [RallyDTO] = p.truth.pieces.filter { RallyTruth.isRally($0.kind) }.map { m in
            let record = p.records.first { $0.startTime == m.start && $0.endTime == m.end && RallyTruth.isRally($0.kind) }
            // The serve contact starts the rally when one was marked (contacts[0], a serve), else the mark's start.
            let contact = record?.contacts?.first.flatMap { $0.kind == .serve && $0.time >= m.start && $0.time < m.end ? $0.time : nil }
            return RallyDTO(rallyId: nil, startTick: tick(contact ?? m.start), endTick: tick(m.end), kind: "rally",
                            provenance: m.kind == nil ? "legacy_nil_kind" : "legacy_declared", contactUncertaintyTicks: nil, deadUncertaintyTicks: nil)
        }.filter { $0.startTick < $0.endTick }
        let excluded = p.truth.pieces.filter { !RallyTruth.isRally($0.kind) }.compactMap { m -> SpanDTO? in
            let s = tick(m.start), e = tick(m.end)
            return s < e ? SpanDTO(startTick: s, endTick: e, kind: (m.kind ?? .other).rawValue) : nil
        }
        let cuts = p.truth.cuts.compactMap { c -> SpanDTO? in
            let s = tick(c.start), e = tick(c.end)
            return s < e ? SpanDTO(startTick: s, endTick: e, kind: nil) : nil
        }
        var timeBreaking: [TimeBreakingDTO] = []
        for span in p.properties?.activeSpans ?? [] {
            let s = max(0, tick(span.start ?? 0)), e = min(durationTicks, span.end.map(tick) ?? durationTicks)
            guard s < e else { continue }
            for trait in span.traits where trait.breaksTime {
                timeBreaking.append(TimeBreakingDTO(startTick: s, endTick: e, trait: trait.rawValue, origin: span.origin.rawValue))
            }
        }
        let negatives = p.source.eligibility.fullVideoNegatives.level == .standard
        let labels = LabelInputs(rallies: rallies, excluded: excluded, cuts: cuts, timeBreaking: timeBreaking, nonRallyActivity: [],
                                 negatives: negatives, ignoreTicks: tick(boundaryIgnoreSec))

        // Steps.
        let emissions = serveEmissions(frames)
        var counts = Dictionary(uniqueKeysWithValues: State.allCases.map { ($0.name, 0) })
        var text = ""
        text.reserveCapacity(frames.count * 160)
        var previous: (t: Double, tick: Int)?
        var seg = 0
        for (i, f) in frames.enumerated() {
            let k = tick(f.time)
            if let prev = previous, f.time - prev.t > gapSec || crossesNonFootage(prev.tick, k, labels) { seg += 1 }
            let y = state(k, labels)
            counts[y.name, default: 0] += 1
            let row = featureRow(f, previous: previous?.t, net: net, serve: emissions[i])
            text += "{\"t\":\(number(f.time)),\"tick\":\(k),\"seg\":\(seg),\"f\":[" + zip(features, row).map { feature, v in
                guard let v else { return "null" }
                return feature.nullable ? number(v) : String(Int(v))
            }.joined(separator: ",") + "],\"y\":\(y.rawValue),\"w\":\(y.weight == 1 ? "1.0" : "0.0")}\n"
            previous = (f.time, k)
        }

        // Baseline: the committed decider (and the variants) on the full evidence as the pipeline produced it — not
        // the steps, which drop a frame at a time already seen — with each clip's pre-merge raws.
        var baseline: [String: [BaselineClip]] = [:]
        for v in variants {
            let clips = EvidenceReplayer.decidedRallies(evidence: ev.frames, duration: ev.duration, config: v.config.withCamera(of: p.session),
                                                        minRallySec: minRallySec, padded: true)
            baseline[v.name] = clips.map { c in
                BaselineClip(rawSpans: c.parts.map { BaselineSpan(startTick: tick($0.start), endTick: tick($0.end)) }.filter { $0.startTick < $0.endTick },
                             startTick: tick(c.range.start), endTick: tick(c.range.end), serveContactTick: c.serve.map { tick($0.contact) })
            }
        }
        let baselineData = try encode(BaselineFile(recordingId: p.video, variants: baseline))

        let verdict = p.source.eligibility[.rallyClassifier]
        let negativesVerdict = p.source.eligibility.fullVideoNegatives
        let reasons = verdict.reasons + negativesVerdict.reasons.filter { !verdict.reasons.contains($0) }
        let row = p.row
        let record = Recording(
            recordingId: p.video, sourceId: confirmedSourceId(row), fingerprint: row.fingerprint,
            groupId: groupId, split: row.split.rawValue, fold: nil, surface: row.surface, camera: row.camera, orientation: row.orientation,
            originKind: row.originKind, uploader: row.uploader, durationSec: ev.duration, frameRateNominal: ev.frameRate, vfr: nil,
            aspect: ev.aspect, upright: frames.first?.upright ?? config.applyVideoRotation,
            net: net.map { NetDTO(x: Double($0.box.minX), y: Double($0.box.minY), w: Double($0.box.width), h: Double($0.box.height), confidence: $0.confidence) },
            recordingType: p.source.recordingType.rawValue,
            eligibility: EligibilityDTO(rallyClassifier: verdict.level.rawValue, fullVideoNegatives: negativesVerdict.level.rawValue, reasons: reasons),
            restrictedUse: verdict.level == .restricted,
            coverage: CoverageDTO(state: "declared_complete", verifiedCoverageSec: nil),
            labelProvenance: ProvenanceDTO(method: "legacy_declared", marksSha256: p.marksSha256, rallyEventsSha256: nil),
            rallies: rallies, excludedSpans: excluded, cutRanges: cuts.map { SpanDTO(startTick: $0.startTick, endTick: $0.endTick, kind: nil) },
            timeBreakingSpans: timeBreaking, nonRallyActivitySpans: [], exposure: exposure,
            stepsFile: "steps/\(p.video).jsonl", stepsSha256: "", stepCount: frames.count, labelCounts: counts,
            baselineFile: "baseline/\(p.video).json", baselineSha256: "")
        return Built(record: record, steps: Data(text.utf8), baseline: baselineData)
    }

    /// A finite number as JSON (Swift's shortest round-trip text, which Python reads back to the same double).
    static func number(_ v: Double) -> String { v.isFinite ? "\(v)" : "null" }

    // MARK: - Preflight and validation

    /// `content`: each exported recording's original by content fingerprint; `protectedContent`: every identity a
    /// withheld recording's video can have on disk (LineagePackage.protectedSourceFingerprints).
    static func preflight(staging: URL, manifest: DatasetManifest, closure: Set<String>, registry: [String: SourceRegistry.Source],
                          content: [String: String], protectedContent: Set<String>) -> [Check] {
        var checks: [Check] = []
        func check(_ name: String, _ problems: [String], _ ok: String) {
            checks.append(Check(name: name, passed: problems.isEmpty, detail: problems.isEmpty ? ok : problems.prefix(5).joined(separator: "; ")))
        }
        let recs = manifest.recordings
        let referenced = Set(recs.flatMap { [$0.stepsFile, $0.baselineFile] }).union(["dataset-manifest.json"])
        let files = DatasetSplitManifest.canonicalFileHashes(ofDirectory: staging)
        check("files-readable", files == nil ? ["the staged folder can't be read"] : [], "every file read")
        let present = Dictionary((files ?? []).map { ($0.path, $0.sha256) }, uniquingKeysWith: { a, _ in a })
        check("no-stray-file", present.keys.filter { !referenced.contains($0) }.sorted(), "only the manifest and the referenced files")
        var hashProblems: [String] = []
        var countProblems: [String] = []
        for r in recs {
            if present[r.stepsFile] != r.stepsSha256 { hashProblems.append(r.stepsFile) }
            if present[r.baselineFile] != r.baselineSha256 { hashProblems.append(r.baselineFile) }
            let lines = (try? Data(contentsOf: staging.appendingPathComponent(r.stepsFile)))?.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } ?? -1
            if lines != r.stepCount { countProblems.append("\(r.recordingId): \(lines) lines, stepCount \(r.stepCount)") }
            if r.labelCounts.values.reduce(0, +) != r.stepCount { countProblems.append("\(r.recordingId): labelCounts sum ≠ stepCount") }
        }
        check("hashes", hashProblems, "every steps and baseline file matches its hash")
        check("counts", countProblems, "step and label counts match the files")
        let w = manifest.withheld
        check("closure", w.names.isEmpty ? ["empty"] : (w.closureSha256 == closureSha256(w) ? [] : ["closureSha256 does not match"]),
              "\(w.names.count) names, \(w.sourceIds.count) sourceIds, \(w.fingerprints.count) fingerprints")
        let fps = Set(w.fingerprints)
        check("no-withheld-recording", recs.compactMap { r in
            if closure.contains(r.recordingId) { return "\(r.recordingId) (name)" }
            return withheldIdentity(name: r.recordingId, sourceId: r.sourceId, fingerprint: r.fingerprint, content: nil, in: w).map { "\(r.recordingId) (\($0))" }
        }, "no recording, source or file of the closure")
        check("sources-not-protected", recs.compactMap { r in
            guard let f = content[r.recordingId] else { return "\(r.recordingId): its original has no content fingerprint" }
            return protectedContent.contains(f) || fps.contains(f) ? "\(r.recordingId): its original is a withheld recording's video" : nil
        }, "every exported recording's original is fingerprinted and matches none of the \(protectedContent.count) withheld identities")
        check("admitted-and-eligible", recs.compactMap { r in
            guard let s = registry[r.recordingId] else { return "\(r.recordingId) not in the registry" }
            guard s.admission == .admitted else { return "\(r.recordingId) \(s.admission.rawValue)" }
            return [.standard, .restricted].contains(s.eligibility[.rallyClassifier].level) ? nil : "\(r.recordingId) \(s.eligibility[.rallyClassifier].level.rawValue)"
        }, "every recording admitted and eligible for the rally classifier")
        return checks
    }

    enum ValidationOutcome: Equatable { case passed, refused([String]), unavailable(String) }

    /// `validate_dataset.py <staging> --withheld <closure> --json`: the repository's validator, the contract's backstop.
    static func validate(staging: URL, closure: URL, options: Options) async -> (outcome: ValidationOutcome, raw: Data) {
        guard FileManager.default.fileExists(atPath: options.validator.path) else { return (.unavailable("\(options.validator.path) not found"), Data()) }
        let run = await ToolEnvironment.run(options.python, ["-I", options.validator.path, staging.path, "--withheld", closure.path, "--json"])
        let text = run.lines.joined(separator: "\n")
        guard let start = text.firstIndex(of: "{"), let data = String(text[start...]).data(using: .utf8),
              let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let ok = report["ok"] as? Bool else {
            return (.unavailable("\(options.python) exited \(run.status): \(run.lines.suffix(3).joined(separator: " "))"), Data(text.utf8))
        }
        guard ok, run.status == 0 else { return (.refused(report["errors"] as? [String] ?? ["exit \(run.status)"]), data) }
        return (.passed, data)
    }

    /// The closure's hash as the validator computes it: SHA-256 of `json.dumps({names, sourceIds, fingerprints} sorted,
    /// sort_keys=True, separators=(",", ":"))` — ASCII-escaped like Python's default.
    static func closureSha256(_ w: Withheld) -> String {
        func list(_ a: [String]) -> String { "[" + a.sorted().map(pythonString).joined(separator: ",") + "]" }
        let text = "{\"fingerprints\":\(list(w.fingerprints)),\"names\":\(list(w.names)),\"sourceIds\":\(list(w.sourceIds))}"
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A string as Python's `json.dumps` writes it (ensure_ascii).
    static func pythonString(_ s: String) -> String {
        var out = "\""
        for unit in s.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20..<0x7F: out.unicodeScalars.append(Unicode.Scalar(unit)!)
            default: out += String(format: "\\u%04x", unit)
            }
        }
        return out + "\""
    }

    // MARK: - Files

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    static func encode<T: Encodable>(_ value: T, pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func planMarkdown(_ p: PlanFile) -> String {
        var md = "# Rally-classifier dataset plan — \(p.dataset)\n\n"
        md += "Project \(p.project) · \(p.createdAt) · split manifest `\(p.manifestSha256.prefix(16))` · withheld closure \(p.withheld.names.count) names\n\n"
        md += "## To export (\(p.included.count))\n\n" + p.included.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        if !p.footageMissing.isEmpty { md += "## Footage not on this Mac (\(p.footageMissing.count)) — nothing is written until it is\n\n" + p.footageMissing.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        md += "## Left out (\(p.leftOut.count))\n\n| Recording | Why |\n|---|---|\n" + p.leftOut.map { "| \($0.video) | \($0.reason) |" }.joined(separator: "\n") + "\n"
        return md
    }

    static func reportMarkdown(_ r: ExportReport) -> String {
        var md = "# Rally-classifier dataset — \(r.dataset)\n\n"
        md += "| Identity | |\n|---|---|\n| Folder | `\(r.path)` |\n| Digest | `\(r.digest)` |\n| Manifest SHA-256 | `\(r.manifestSha256)` |\n"
        md += "| Detector | \(r.detector.name) `\(r.detector.canonicalDigest)` |\n| Config SHA-256 | `\(r.pipelineConfigSha256)` |\n| Code | `\(r.codeSha)` |\n| Executable SHA-256 | `\(r.binarySha)` |\n\n"
        md += "Recordings: \(r.recordings.count)" + (r.reused.isEmpty ? "" : " (\(r.reused.count) kept from a run cut short)") + " · left out: \(r.leftOut.count)\n\n"
        md += "Steps by label: " + State.allCases.map { "\($0.name) \(r.labelCounts[$0.name] ?? 0)" }.joined(separator: " · ") + "\n\n"
        md += "| Preflight check | Passed | Detail |\n|---|---|---|\n" + r.preflight.map { "| \($0.name) | \($0.passed ? "yes" : "NO") | \($0.detail) |" }.joined(separator: "\n") + "\n"
        return md
    }

    // MARK: - The contract's shapes

    @propertyWrapper
    struct Null<T: Codable & Equatable>: Codable, Equatable {
        var wrappedValue: T?
        init(wrappedValue: T?) { self.wrappedValue = wrappedValue }
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            wrappedValue = c.decodeNil() ? nil : try c.decode(T.self)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            if let v = wrappedValue { try c.encode(v) } else { try c.encodeNil() }
        }
    }

    struct Withheld: Codable, Equatable {
        var names: [String]
        var sourceIds: [String]
        var fingerprints: [String]
        var closureSha256: String

        init(names: [String], sourceIds: [String], fingerprints: [String]) {
            self.names = names; self.sourceIds = sourceIds; self.fingerprints = fingerprints
            self.closureSha256 = ""
            self.closureSha256 = RallyClassifierExporter.closureSha256(self)
        }
    }

    struct Detector: Codable, Equatable {
        var name: String
        var canonicalDigest: String
    }

    struct Settings: Codable, Equatable {
        var prerollSec: Double
        var postrollSec: Double
        var joinSec: Double
        var minSegmentSec: Double
        var servePrimedStart: Bool
        init(_ c: ProcessorConfig) {
            prerollSec = c.preroll; postrollSec = c.postroll; joinSec = c.minGapToMerge; minSegmentSec = c.minSegmentLength; servePrimedStart = c.servePrimedStart
        }
    }

    struct VariantDTO: Codable, Equatable {
        var name: String
        var configSha256: String
        var settings: Settings
    }

    struct BaselineBlock: Codable, Equatable {
        var replayer: String
        var variants: [VariantDTO]
    }

    struct Generator: Codable, Equatable {
        var tool: String
        var codeSha: String
    }

    struct SplitHashes: Codable, Equatable {
        var projectJson: String
        var sessions: String
        var validationJson: String
        var manifestJson: String
    }

    struct FeatureDTO: Codable, Equatable {
        var name: String
        var nullable: Bool
        var kind: String
        var lookaheadSec: Double
    }

    struct FeatureSchema: Codable, Equatable {
        var version = RallyClassifierExporter.featureVersion
        var features = RallyClassifierExporter.features.map { FeatureDTO(name: $0.name, nullable: $0.nullable, kind: "raw", lookaheadSec: 0) }
    }

    struct LabelSchema: Codable, Equatable {
        var version = RallyClassifierExporter.labelVersion
        var states = Dictionary(uniqueKeysWithValues: State.allCases.map { ($0.name, $0.rawValue) })
        var weights = Dictionary(uniqueKeysWithValues: State.allCases.map { (String($0.rawValue), $0.weight) })
        var boundaryIgnoreSec = RallyClassifierExporter.boundaryIgnoreSec
    }

    struct NetDTO: Codable, Equatable {
        var x: Double
        var y: Double
        var w: Double
        var h: Double
        var confidence: Double
    }

    struct EligibilityDTO: Codable, Equatable {
        var rallyClassifier: String
        var fullVideoNegatives: String
        var reasons: [String]
    }

    struct CoverageDTO: Codable, Equatable {
        var state: String
        @Null var verifiedCoverageSec: Double?
    }

    struct ProvenanceDTO: Codable, Equatable {
        var method: String
        var marksSha256: String
        @Null var rallyEventsSha256: String?
    }

    struct RallyDTO: Codable, Equatable {
        @Null var rallyId: String?
        var startTick: Int
        var endTick: Int
        var kind: String
        var provenance: String
        @Null var contactUncertaintyTicks: Int?
        @Null var deadUncertaintyTicks: Int?
    }

    struct SpanDTO: Codable, Equatable {
        var startTick: Int
        var endTick: Int
        /// The excluded span's kind; absent on a cut range.
        var kind: String?
    }

    struct TimeBreakingDTO: Codable, Equatable {
        var startTick: Int
        var endTick: Int
        var trait: String
        var origin: String
    }

    struct ExposureDTO: Codable, Equatable {
        @Null var date: String?
        var kind: String
        var ref: String
    }

    struct Recording: Codable, Equatable {
        var recordingId: String
        @Null var sourceId: String?
        @Null var fingerprint: String?
        var groupId: String
        var split: String
        @Null var fold: Int?
        @Null var surface: String?
        @Null var camera: String?
        @Null var orientation: String?
        @Null var originKind: String?
        @Null var uploader: String?
        var durationSec: Double
        var frameRateNominal: Double
        @Null var vfr: Bool?
        var aspect: Double
        var upright: Bool
        @Null var net: NetDTO?
        var recordingType: String
        var eligibility: EligibilityDTO
        var restrictedUse: Bool
        var coverage: CoverageDTO
        var labelProvenance: ProvenanceDTO
        var rallies: [RallyDTO]
        var excludedSpans: [SpanDTO]
        var cutRanges: [SpanDTO]
        var timeBreakingSpans: [TimeBreakingDTO]
        var nonRallyActivitySpans: [SpanDTO]
        var exposure: [ExposureDTO]
        var stepsFile: String
        var stepsSha256: String
        var stepCount: Int
        var labelCounts: [String: Int]
        var baselineFile: String
        var baselineSha256: String
    }

    struct DatasetManifest: Codable, Equatable {
        var schemaVersion: String
        var createdAt: String
        var generator: Generator
        var project: String
        var splitManifest: SplitHashes
        var withheld: Withheld
        var detector: Detector
        var pipelineConfigSha256: String
        var timescale: Int
        var samplingHzNominal: Int
        var featureSchema: FeatureSchema
        var labelSchema: LabelSchema
        var baseline: BaselineBlock
        var recordings: [Recording]
    }

    struct BaselineSpan: Codable, Equatable {
        var startTick: Int
        var endTick: Int
    }

    struct BaselineClip: Codable, Equatable {
        var rawSpans: [BaselineSpan]
        var startTick: Int
        var endTick: Int
        @Null var serveContactTick: Int?
    }

    struct BaselineFile: Codable, Equatable {
        var recordingId: String
        var variants: [String: [BaselineClip]]
    }

    struct PlanFile: Codable, Equatable {
        var schemaVersion: String
        var dataset: String
        var project: String
        var createdAt: String
        var manifestSha256: String
        var splitManifest: DatasetSplitManifest.Hashes
        var auditHard: Int
        var withheld: Withheld
        var included: [String]
        var footageMissing: [String]
        var leftOut: [LeftOut]
    }

    struct JournalIdentity: Codable, Equatable {
        var dataset: String
        var codeSha: String
        var binarySha: String
        var pipelineConfigSha256: String
        var detector: Detector
        var variants: [VariantDTO]
    }

    struct JournalEntry: Codable, Equatable {
        var inputKey: String
        var record: Recording
    }

    struct Journal: Codable, Equatable {
        var identity: JournalIdentity
        var recordings: [String: JournalEntry]
    }

    struct ExportReport: Codable, Equatable {
        var dataset: String
        var path: String
        var digest: String
        var manifestSha256: String
        var splitManifest: SplitHashes
        var detector: Detector
        var pipelineConfigSha256: String
        var codeSha: String
        var binarySha: String
        var recordings: [String]
        var reused: [String]
        var leftOut: [LeftOut]
        var preflight: [Check]
        var labelCounts: [String: Int]
    }

    // MARK: - The live detector

    /// The pipeline over the recording's original, evidence collected — as `--export-training-data` runs it.
    static func liveEvidence(_ session: VideoSession, _ config: ProcessorConfig) async throws -> Evidence {
        let url = URL(fileURLWithPath: session.sourcePath)
        let processor = VideoProcessor()
        processor.config = config
        processor.collectFrameEvidence = true
        do { _ = try await processor.processVideo(url, videoId: UUID()) } catch ProcessingError.noRalliesDetected {
            // No rally is a result; the evidence is still there.
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.unreadable("\(session.name): no video track") }
        let rate = try await track.load(.nominalFrameRate)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let upright = config.applyVideoRotation ? size.applying(transform) : size
        let aspect = abs(upright.height) > 0 ? abs(upright.width) / abs(upright.height) : 0
        return Evidence(frames: processor.frameEvidence, duration: processor.lastVideoDurationSec, frameRate: Double(rate), aspect: Double(aspect),
                        detector: processor.loadedHeatmapModel)
    }

    /// The commit this RallyLab build was compiled from (the Record Source Revision build phase writes
    /// `source-revision.txt` into the app at build time): 40 hex, `-dirty` when the tree had changes; nil when the build
    /// recorded none.
    static func buildRevision(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "source-revision", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let sha = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = sha.hasSuffix("-dirty") ? String(sha.dropLast(6)) : sha
        guard hex.count == 40, hex.allSatisfy(\.isHexDigit) else { return nil }
        return sha
    }

    /// SHA-256 of the running executable: the binary itself, so two builds of one dirty tree are told apart.
    static func executableSha256(in bundle: Bundle = .main) -> String? {
        bundle.executableURL.flatMap { DatasetSplitManifest.sha256(of: $0) }
    }
}
