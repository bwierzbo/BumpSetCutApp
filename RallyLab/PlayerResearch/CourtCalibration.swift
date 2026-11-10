//
//  CourtCalibration.swift
//  RallyLab
//
//  A recording's court calibrations (court_geometry_v1), one file per recording in the
//  experiment folder: `<experiment>/court-calibrations/<recordingId>.json`. Never in a
//  RallyLab project: the project's net labels, sessions, splits, footage properties and
//  ledger are not touched.
//
//  A file is bound to the file it was made on — the recording's identity (project.json's
//  fingerprint) and the decoded copy's fingerprint, its upright size and orientation — and
//  a file that no longer matches is `stale`: shown, never used.
//
//  A file holds segments, each a stretch of the recording with one stable camera view.
//  A segment keeps every automatic proposal as it was made (method, confidence, the
//  assumptions behind it), the person's working draft, and — only when a person pressed
//  Confirm — the confirmation: the geometry as confirmed, which proposal it started from,
//  which points the person moved, when and by whom. A proposal is never a confirmation; a
//  confirmed segment that is edited again keeps its earlier confirmation in `history`.
//  A segment the person marks `unknownView` (camera moved, cut, zoom) is never used.
//

import Foundation

struct CourtProposal: Codable, Equatable, Sendable {
    enum Method: String, Codable, Sendable, CaseIterable {
        /// From the net label alone: dimensions and an assumed camera (CourtProposer.netGuided).
        case netGuided = "net_guided_v1"
        /// From lines found on the ground in a median of several frames, the net only bounding the search.
        case courtLines = "court_lines_v1"
        /// Line evidence where it agrees with the net-guided estimate, the estimate elsewhere.
        case combined = "combined_v1"
        var label: String {
            switch self {
            case .netGuided: return "Net-guided"
            case .courtLines: return "Court lines"
            case .combined: return "Combined"
            }
        }
    }

    var method: Method
    var geometry: CourtLayout
    /// 0–1, the method's own score; not a probability.
    var confidence: Double
    /// What the proposal assumed or could not see.
    var uncertainty: [String]
    /// Which evidence placed each point (`line`, `net_label`, `assumed`), by role.
    var pointSources: [String: String]
    var inputs: [String: String]
    var frameTimes: [Double]
    var createdAt: Date
    var ms: Double
    var codeSha: String?
}

struct CourtConfirmation: Codable, Equatable, Sendable {
    static let personMethod = "player_lab_gui"
    static let scriptMethod = "player_lab_script"

    var geometry: CourtLayout
    /// The proposal it started from (`net_guided_v1`…), or `manual` when the person placed it from nothing.
    var startedFrom: String
    /// The roles the person moved or re-marked, against what it started from.
    var adjustedRoles: [String]
    var confirmedAt: Date
    var confirmedBy: String
    /// How: `player_lab_gui` (a person pressed Confirm — the only confirmation used as evidence) or `player_lab_script`
    /// (a scripted GUI test: recorded, never used).
    var method: String
    /// The net the geometry was checked against: the person net label's corners and the file it was made on.
    var net: PlayerFeatures.NetGeometry?
    var spec: CourtSpec
    var format: String?
}

struct CourtSegment: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable {
        /// Proposals and perhaps a draft; not confirmed: never used as evidence.
        case unreviewed
        case confirmed
        /// The person said the proposals are wrong and placed nothing.
        case rejected
        /// The view is not one stable court view (a cut, pan, zoom, replay): its players are `unknown`.
        case unknownView = "unknown_view"
    }
    var id: Int
    var validFromSec: Double
    var validToSec: Double
    var status: Status
    var proposals: [CourtProposal]
    var draft: CourtLayout?
    var draftStartedFrom: String?
    var confirmation: CourtConfirmation?
    /// Earlier confirmations of this segment, superseded by a later one or reopened.
    var history: [CourtConfirmation]
    var note: String?

    func contains(_ t: Double) -> Bool { t >= validFromSec && t < validToSec }

    /// The latest proposal of each method.
    var latestProposals: [CourtProposal] {
        CourtProposal.Method.allCases.compactMap { m in proposals.last { $0.method == m } }
    }
}

/// What the person says about the court, asked before proposing: it chooses the method and the court's size, and is
/// kept with the calibration as metadata — never as proof of where the court is.
struct CourtSetup: Codable, Equatable, Sendable {
    enum Surface: String, Codable, CaseIterable, Sendable { case beach, grass, indoor }
    enum Format: String, Codable, CaseIterable, Sendable { case twos = "2v2", fours = "4v4", sixes = "6v6" }
    enum Markings: String, Codable, CaseIterable, Sendable {
        /// Painted lines or flat tape on the ground: the line search runs.
        case lines
        /// Rope or cord: thin and raised; the line search runs and may miss it.
        case rope
        /// Nothing marks the court: the court is placed from the net and by hand.
        case none
        var label: String {
            switch self {
            case .lines: return "Painted lines or tape"
            case .rope: return "Rope or cord"
            case .none: return "Nothing marks it"
            }
        }
    }
    var surface: Surface?
    var format: Format?
    var markings: Markings?
    var answeredAt: Date?

    /// The court size the answers imply: 16 × 8 m for doubles and beach, 18 × 9 m for indoor and grass fours or sixes.
    var spec: CourtSpec? {
        guard let surface else { return nil }
        switch (surface, format) {
        case (.indoor, _): return .indoor
        case (.beach, _), (.grass, .twos?): return CourtSpec(widthM: 8, lengthM: 16, source: "\(surface.rawValue) \(format?.rawValue ?? "") 16 × 8 m (person's answers)")
        case (.grass, _): return CourtSpec(widthM: 9, lengthM: 18, source: "grass \(format?.rawValue ?? "") 18 × 9 m (person's answers)")
        }
    }
}

struct CourtCalibrationFile: Codable, Equatable, Sendable {
    var schemaVersion: String
    var recordingId: String
    /// project.json's identity of the original (`file:` / `youtube:`).
    var sourceFingerprint: String?
    /// The decoded copy's fingerprint (player_features_v1 `decoded.fingerprint`).
    var decodedFingerprint: String
    var frameWidth: Int
    var frameHeight: Int
    var orientation: UInt32
    var camera: String?
    var surface: String?
    var durationSec: Double
    /// The person's answers about the court (nil until asked).
    var setup: CourtSetup? = nil
    var segments: [CourtSegment]

    /// The recording as decoded now, from a run manifest.
    struct Binding: Equatable, Sendable {
        var recordingId: String
        var sourceFingerprint: String?
        var decodedFingerprint: String
        var frameWidth: Int
        var frameHeight: Int
        var orientation: UInt32
        var camera: String?
        var surface: String?
        var durationSec: Double

        init(recordingId: String, sourceFingerprint: String?, decodedFingerprint: String, frameWidth: Int, frameHeight: Int,
             orientation: UInt32, camera: String?, surface: String?, durationSec: Double) {
            self.recordingId = recordingId; self.sourceFingerprint = sourceFingerprint; self.decodedFingerprint = decodedFingerprint
            self.frameWidth = frameWidth; self.frameHeight = frameHeight; self.orientation = orientation
            self.camera = camera; self.surface = surface; self.durationSec = durationSec
        }

        init(_ r: PlayerFeatures.Recording) {
            recordingId = r.recordingId; sourceFingerprint = r.fingerprint; decodedFingerprint = r.decoded.fingerprint
            frameWidth = r.decoded.width; frameHeight = r.decoded.height; orientation = r.decoded.orientation
            camera = r.camera; surface = r.surface; durationSec = r.decoded.durationSec
        }
    }

    static func new(for b: Binding) -> CourtCalibrationFile {
        CourtCalibrationFile(schemaVersion: CourtGeometryV1.schemaVersion, recordingId: b.recordingId, sourceFingerprint: b.sourceFingerprint,
                             decodedFingerprint: b.decodedFingerprint, frameWidth: b.frameWidth, frameHeight: b.frameHeight,
                             orientation: b.orientation, camera: b.camera, surface: b.surface, durationSec: b.durationSec,
                             segments: [CourtSegment(id: 0, validFromSec: 0, validToSec: b.durationSec, status: .unreviewed, proposals: [],
                                                     draft: nil, draftStartedFrom: nil, confirmation: nil, history: [], note: nil)])
    }

    /// Why this file doesn't describe the recording as decoded now; nil when it does.
    func staleReason(for b: Binding) -> String? {
        if schemaVersion != CourtGeometryV1.schemaVersion { return "schema \(schemaVersion), not \(CourtGeometryV1.schemaVersion)" }
        if recordingId != b.recordingId { return "made for \(recordingId)" }
        if sourceFingerprint != b.sourceFingerprint { return "the recording's identity changed (\(sourceFingerprint ?? "none") → \(b.sourceFingerprint ?? "none"))" }
        if decodedFingerprint != b.decodedFingerprint { return "the decoded file changed" }
        if frameWidth != b.frameWidth || frameHeight != b.frameHeight || orientation != b.orientation {
            return "the frame changed (\(frameWidth)×\(frameHeight) o\(orientation) → \(b.frameWidth)×\(b.frameHeight) o\(b.orientation))"
        }
        return nil
    }

    /// Segments must be ordered, non-overlapping and inside the recording.
    var segmentProblems: [String] {
        var out: [String] = []
        let s = segments.sorted { $0.validFromSec < $1.validFromSec }
        for g in s where !(g.validFromSec >= 0 && g.validToSec > g.validFromSec && g.validToSec <= durationSec + 1e-6) {
            out.append("segment \(g.id) spans \(g.validFromSec)–\(g.validToSec) s outside 0–\(durationSec) s")
        }
        for (a, b) in zip(s, s.dropFirst()) where b.validFromSec < a.validToSec - 1e-9 { out.append("segments \(a.id) and \(b.id) overlap") }
        if Set(segments.map(\.id)).count != segments.count { out.append("segment ids repeat") }
        for g in segments where g.status == .confirmed && g.confirmation == nil { out.append("segment \(g.id) is confirmed with no confirmation") }
        for g in segments where g.status != .confirmed && g.confirmation != nil { out.append("segment \(g.id) holds a confirmation but is \(g.status.rawValue)") }
        return out
    }

    /// The person-confirmed geometry that covers time `t`, nil when none does (unreviewed, rejected, unknown view, or
    /// no segment there).
    func confirmed(at t: Double) -> CourtConfirmation? {
        guard let g = segments.first(where: { $0.contains(t) }), g.status == .confirmed, let c = g.confirmation,
              c.method == CourtConfirmation.personMethod, c.geometry.isUsable else { return nil }
        return c
    }

    /// Splits the segment holding `t` in two at `t`; the second half starts unreviewed with the first's proposals and,
    /// as its draft, the first's confirmed or drafted geometry (a starting point, not a confirmation).
    mutating func split(at t: Double) -> Bool {
        guard let i = segments.firstIndex(where: { $0.contains(t) }), t - segments[i].validFromSec > 0.05, segments[i].validToSec - t > 0.05 else { return false }
        var second = segments[i]
        second.id = (segments.map(\.id).max() ?? 0) + 1
        second.validFromSec = t
        second.status = .unreviewed
        second.draft = segments[i].confirmation?.geometry ?? segments[i].draft
        second.draftStartedFrom = segments[i].confirmation.map { _ in "segment \(segments[i].id) confirmation" } ?? segments[i].draftStartedFrom
        second.confirmation = nil
        second.history = []
        segments[i].validToSec = t
        segments.insert(second, at: i + 1)
        return true
    }
}

/// `<experiment>/court-calibrations/`: one file per recording. Read whole, written atomically; a file that exists but
/// can't be read is an error, never an empty calibration.
struct CourtCalibrationStore {
    let dir: URL

    init(experiment: URL) { dir = experiment.appendingPathComponent("court-calibrations", isDirectory: true) }

    func url(_ recordingId: String) -> URL { dir.appendingPathComponent("\(recordingId).json") }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }()

    func load(_ recordingId: String) throws -> CourtCalibrationFile? {
        let u = url(recordingId)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return try Self.decoder.decode(CourtCalibrationFile.self, from: Data(contentsOf: u))
    }

    func save(_ file: CourtCalibrationFile) throws {
        guard RallyClassifierExporter.isSafeName(file.recordingId) else { throw CocoaError(.fileWriteInvalidFileName) }
        let problems = file.segmentProblems
        guard problems.isEmpty else { throw CourtCalibrationError.invalid(problems) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.encoder.encode(file).write(to: url(file.recordingId), options: .atomic)
    }

    /// The confirmed geometry covering each time, for a recording as decoded now — or why there is none for the whole
    /// recording (no file, stale, unreadable). Readers that use geometry as evidence go through this.
    func confirmedLookup(for b: CourtCalibrationFile.Binding) -> (file: CourtCalibrationFile?, unusable: String?) {
        do {
            guard let f = try load(b.recordingId) else { return (nil, "no court calibration") }
            if let why = f.staleReason(for: b) { return (nil, "court calibration is stale: \(why)") }
            guard f.segmentProblems.isEmpty else { return (nil, "court calibration is malformed: \(f.segmentProblems.joined(separator: "; "))") }
            guard f.segments.contains(where: { $0.status == .confirmed && $0.confirmation?.method == CourtConfirmation.personMethod }) else {
                return (f, "court calibration not confirmed by a person")
            }
            return (f, nil)
        } catch { return (nil, "court calibration unreadable: \(error.localizedDescription)") }
    }
}

enum CourtCalibrationError: LocalizedError, Equatable {
    case invalid([String])
    case unusableGeometry([String])
    case stale(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let p): return "The court calibration is malformed: " + p.joined(separator: "; ")
        case .unusableGeometry(let p): return "The court can't be confirmed: " + p.joined(separator: "; ")
        case .stale(let why): return "The court calibration is for another file: \(why)"
        }
    }
}

extension CourtCalibrationFile {
    /// The person's Confirm: the draft becomes segment `id`'s confirmation. The only path to `confirmed`.
    mutating func confirm(segment id: Int, geometry: CourtLayout, startedFrom: String, baseline: CourtLayout?, by person: String,
                          net: PlayerFeatures.NetGeometry?, spec: CourtSpec, format: String?, now: Date,
                          method: String = CourtConfirmation.personMethod) throws {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { throw CourtCalibrationError.invalid(["no segment \(id)"]) }
        let problems = geometry.problems
        guard problems.isEmpty else { throw CourtCalibrationError.unusableGeometry(problems) }
        if let old = segments[i].confirmation { segments[i].history.append(old) }
        let adjusted = baseline.map { geometry.changedRoles(from: $0).map(\.rawValue) } ?? CourtLayout.Role.allCases.map(\.rawValue)
        segments[i].confirmation = CourtConfirmation(geometry: geometry, startedFrom: startedFrom, adjustedRoles: adjusted, confirmedAt: now,
                                                     confirmedBy: person, method: method, net: net, spec: spec, format: format)
        segments[i].status = .confirmed
        segments[i].draft = nil
        segments[i].draftStartedFrom = nil
    }

    /// Takes a segment out of use: rejected proposals, or a view that isn't one court. A confirmation moves to history.
    mutating func set(segment id: Int, status: CourtSegment.Status, note: String?) {
        guard let i = segments.firstIndex(where: { $0.id == id }), status != .confirmed else { return }
        if let old = segments[i].confirmation { segments[i].history.append(old) }
        segments[i].confirmation = nil
        segments[i].status = status
        segments[i].note = note
    }
}
