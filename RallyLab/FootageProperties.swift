//
//  FootageProperties.swift
//  RallyLab
//
//  What a recording's footage is like, span by span (owner direction of
//  2026-11-02, "Edited Footage, Camera Motion, and Training Eligibility"):
//  whether the camera is fixed, pans, is handheld or zooms digitally;
//  whether the time is real — normal speed, slow motion, a replay, a montage,
//  a cut between angles, dead time removed; or unknown. Traits coexist, and
//  are recorded for the stretch they apply to (or the whole recording). A
//  span is a *proposal* until a person confirms it; a rejected proposal
//  stays on file and counts for nothing. The recording's type (continuous,
//  edited, unknown) is a person's call too. Where a recording is a
//  derivative of another (a highlight, a crop, a slow-motion replay, another
//  camera of the same match), `derivedFrom` names the original, so the
//  derivative chain is one lineage for split isolation.
//
//  One file per recording: <project>/footage-properties/<video>.json, read
//  strictly (another schema or an invalid record is refused whole) and
//  written atomically. Nothing here changes an annotation, a split or a
//  reservation; TrainingEligibility reads it to say what each model may use.
//  No detector writes it yet (phase 2): this is the record and its rules.
//

import Foundation

enum FootageProperties {
    static let schemaVersion = 1

    enum Trait: String, Codable, CaseIterable, Sendable {
        // Camera
        case fixedCamera = "fixed_camera"
        case normalPanning = "normal_panning"
        case aggressivePanning = "aggressive_panning"
        case handheld
        case digitalZoom = "digital_zoom"
        case cameraAngleChange = "camera_angle_change"
        // Time
        case normalSpeed = "normal_speed"
        case slowMotion = "slow_motion"
        case replay
        case montage
        case deadTimeRemoved = "dead_time_removed"
        // Other
        case overlays
        /// The person could not tell: quarantined until someone can.
        case unknown

        /// Changes the recording's time structure: no temporal window may be built inside or across it.
        var breaksTime: Bool { [.slowMotion, .replay, .montage, .cameraAngleChange].contains(self) }
    }

    enum Origin: String, Codable, Sendable {
        /// A detector or a person's unconfirmed note: restricts, never clears.
        case proposed
        /// A person confirmed it.
        case confirmed
    }

    enum RecordingType: String, Codable, Sendable { case continuous, edited, unknown }

    /// A stretch of the recording (seconds; nil start/end = from the beginning / to the end) and what it is.
    struct Span: Codable, Equatable, Identifiable, Sendable {
        var id: UUID
        var start: Double?
        var end: Double?
        var traits: [Trait]
        var origin: Origin
        /// 0…1 when a detector proposed it.
        var confidence: Double?
        /// What proposed it (a detector and its run) or who entered it.
        var source: String?
        var note: String?
        var at: String
        var by: String
        /// A person rejected the proposal: kept on file, counts for nothing.
        var rejectedAt: String?

        var isActive: Bool { rejectedAt == nil }
        var isWholeRecording: Bool { start == nil && end == nil }
    }

    /// The original this recording was made from, when known.
    struct Derivation: Codable, Equatable, Sendable {
        enum Relation: String, Codable, Sendable { case highlight, crop, slowMotionReplay = "slow_motion_replay", otherCamera = "other_camera", reencode, other }
        /// The original's video id, or its identity key (`src:…` / `fp:…`) when it is not in the project.
        var parent: String
        var relation: Relation
        var note: String?
    }

    struct File: Codable, Equatable, Sendable {
        var schemaVersion: Int = FootageProperties.schemaVersion
        var video: String
        var sourceFingerprint: String?
        var recordingType: RecordingType = .unknown
        var recordingTypeBy: String?
        var recordingTypeAt: String?
        var spans: [Span] = []
        var derivedFrom: Derivation?
        var updatedAt: String

        init(video: String, sourceFingerprint: String? = nil, recordingType: RecordingType = .unknown, recordingTypeBy: String? = nil, recordingTypeAt: String? = nil,
             spans: [Span] = [], derivedFrom: Derivation? = nil, updatedAt: String) {
            self.video = video; self.sourceFingerprint = sourceFingerprint; self.recordingType = recordingType
            self.recordingTypeBy = recordingTypeBy; self.recordingTypeAt = recordingTypeAt; self.spans = spans; self.derivedFrom = derivedFrom; self.updatedAt = updatedAt
        }

        private enum CodingKeys: String, CodingKey { case schemaVersion, video, sourceFingerprint, recordingType, recordingTypeBy, recordingTypeAt, spans, derivedFrom, updatedAt }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
            guard schemaVersion == FootageProperties.schemaVersion else { throw Failure.unsupportedVersion(schemaVersion) }
            video = try c.decode(String.self, forKey: .video)
            sourceFingerprint = try c.decodeIfPresent(String.self, forKey: .sourceFingerprint)
            recordingType = try c.decodeIfPresent(RecordingType.self, forKey: .recordingType) ?? .unknown
            recordingTypeBy = try c.decodeIfPresent(String.self, forKey: .recordingTypeBy)
            recordingTypeAt = try c.decodeIfPresent(String.self, forKey: .recordingTypeAt)
            spans = try c.decodeIfPresent([Span].self, forKey: .spans) ?? []
            derivedFrom = try c.decodeIfPresent(Derivation.self, forKey: .derivedFrom)
            updatedAt = try c.decode(String.self, forKey: .updatedAt)
            try FootageProperties.validate(self)
        }

        /// Spans that count: not rejected.
        var activeSpans: [Span] { spans.filter(\.isActive) }
        func traits(_ origin: Origin) -> Set<Trait> { Set(activeSpans.filter { $0.origin == origin }.flatMap(\.traits)) }
    }

    enum Failure: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case invalid(String)
        case unreadable(URL, String)
        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let v): return "footage-properties record is schema \(v); this build reads \(FootageProperties.schemaVersion)."
            case .invalid(let why): return "footage-properties record is not valid: \(why)"
            case .unreadable(let url, let why): return "\(url.path) exists but can't be read; the recording's footage properties are unknown, not none: \(why)"
            }
        }
    }

    static func validate(_ file: File) throws {
        var ids = Set<UUID>()
        for s in file.spans {
            guard ids.insert(s.id).inserted else { throw Failure.invalid("span \(s.id) appears twice") }
            guard !s.traits.isEmpty else { throw Failure.invalid("span \(s.id) has no trait") }
            if let a = s.start, let b = s.end { guard b > a else { throw Failure.invalid("span \(s.id) is empty (\(a)–\(b))") } }
            if let a = s.start { guard a >= 0 else { throw Failure.invalid("span \(s.id) starts before the recording") } }
            if let c = s.confidence { guard (0...1).contains(c) else { throw Failure.invalid("span \(s.id) confidence \(c) is not in 0…1") } }
        }
    }

    // MARK: - Files

    static func directory(in root: URL) -> URL { root.appendingPathComponent("footage-properties", isDirectory: true) }
    static func url(in root: URL, video: String) -> URL { directory(in: root).appendingPathComponent("\(DatasetStore.safeName(video)).json") }

    struct Store: Sendable {
        let root: URL

        /// The recording's record, nil when there is none; one that exists but can't be read throws.
        func load(_ video: String) throws -> File? {
            let url = FootageProperties.url(in: root, video: video)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw Failure.unreadable(url, error.localizedDescription) }
            do { return try JSONDecoder().decode(File.self, from: data) } catch let f as Failure { throw f } catch { throw Failure.unreadable(url, error.localizedDescription) }
        }

        /// Every record by video; a record that can't be read is returned by name in `unreadable` with its reason,
        /// so a caller can fail closed for that recording and go on with the rest.
        func loadAll() throws -> (records: [String: File], unreadable: [String: String]) {
            let dir = FootageProperties.directory(in: root)
            guard FileManager.default.fileExists(atPath: dir.path) else { return ([:], [:]) }
            let files: [URL]
            do { files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) } catch { throw Failure.unreadable(dir, error.localizedDescription) }
            var records: [String: File] = [:]
            var unreadable: [String: String] = [:]
            for url in files where url.pathExtension == "json" {
                let name = url.deletingPathExtension().lastPathComponent
                do {
                    let data = try Data(contentsOf: url)
                    let file = try JSONDecoder().decode(File.self, from: data)
                    guard DatasetStore.safeName(file.video) == name else { unreadable[name] = "the record names \(file.video), not \(name)"; continue }
                    records[name] = file
                } catch {
                    unreadable[name] = error.localizedDescription
                }
            }
            return (records, unreadable)
        }

        func save(_ file: File) throws {
            try FootageProperties.validate(file)
            try FileManager.default.createDirectory(at: FootageProperties.directory(in: root), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(file).write(to: FootageProperties.url(in: root, video: file.video), options: .atomic)
        }
    }
}
