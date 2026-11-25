//
//  CourtNetCalibration.swift
//  BumpSetCut
//
//  A recording's court and net calibration (court_net_calibration_v1): where the court's
//  ground lines (CourtLayout, six points) and the physical net (NetQuad, four corners) lie
//  in the upright, Vision-normalised frame. The two are separate shapes with separate
//  confirmations: a net can be confirmed with no court, and the reverse.
//
//  A file is bound to the video it was made on — the recording's id, the file's
//  fingerprint, its upright frame size, orientation and length — and a file that no longer
//  matches is stale: shown, never used.
//
//  A file holds segments, each a stretch of the recording with one camera view. For the
//  court and for the net a segment keeps every automatic proposal as it was made, the
//  person's working draft, and — only when a person pressed Confirm — the confirmation:
//  the geometry as confirmed, what it started from, which points the person moved, when,
//  by whom and in which tool. A proposal is never a confirmation and never replaces one; a
//  confirmation that is replaced or withdrawn moves to history. A segment whose view is
//  not one stable court view holds no confirmation.
//

import Foundation

enum CourtNetCalibrationV1 {
    static let schemaVersion = "court_net_calibration_v1"
    /// Every point: the upright frame, x and y as fractions of its width and height, origin bottom-left.
    static let coordinateSpace = "upright_vision_normalized"
    /// What a draft or confirmation started from when a person placed it from nothing.
    static let manual = "manual"
    /// What a draft started from when it reopens the segment's own confirmation.
    static let confirmation = "confirmation"
}

/// A shape a person confirms: the court's ground points or the net's corners.
protocol CalibrationGeometry: Codable, Equatable, Sendable {
    static var pointNames: [String] { get }
    /// Every reason the shape can't be used; empty when it can.
    var problems: [String] { get }
    /// The points that differ from other's.
    func changedPoints(from other: Self) -> [String]
}

extension CourtLayout: CalibrationGeometry {
    static var pointNames: [String] { Role.allCases.map(\.rawValue) }
    func changedPoints(from other: CourtLayout) -> [String] { changedRoles(from: other).map(\.rawValue) }
}

extension NetQuad: CalibrationGeometry {
    static let pointNames = ["topLeft", "topRight", "bottomRight", "bottomLeft"]

    var problems: [String] {
        let corners = [topLeft, topRight, bottomRight, bottomLeft]
        var out: [String] = []
        for (name, c) in zip(Self.pointNames, corners) where !((0...1).contains(c.x) && (0...1).contains(c.y)) {
            out.append("the net's \(name) corner is outside the frame")
        }
        if !CourtLayout.isConvex(corners.map { ($0.x, $0.y) }) {
            out.append("the net's corners cross, fold or lie on one line")
        } else if !isUsable {
            out.append("the net is too small to use")
        }
        return out
    }

    func changedPoints(from other: NetQuad) -> [String] {
        let mine = [topLeft, topRight, bottomRight, bottomLeft], theirs = [other.topLeft, other.topRight, other.bottomRight, other.bottomLeft]
        return zip(Self.pointNames, zip(mine, theirs)).filter { abs($0.1.0.x - $0.1.1.x) > 1e-6 || abs($0.1.0.y - $0.1.1.y) > 1e-6 }.map(\.0)
    }
}

/// What a method offered, kept as it was made. Never used until a person confirms a geometry.
struct CalibrationProposal<Geometry: CalibrationGeometry>: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Found in the picture (lines, a net) by a detector.
        case detection
        /// Worked out from assumptions (court size, an assumed camera), not found in the picture.
        case estimate
    }
    /// What made it, with its version (net_guided_v1, court_lines_v1, combined_v1, a model's name).
    var method: String
    var kind: Kind
    var geometry: Geometry
    /// 0–1, the method's own score; not a probability.
    var confidence: Double
    /// What the proposal assumed or could not see.
    var uncertainty: [String]
    var createdAt: Date
}

/// A person's Confirm.
struct CalibrationConfirmation<Geometry: CalibrationGeometry>: Codable, Equatable, Sendable {
    /// The geometry as the person confirmed it.
    var geometry: Geometry
    /// A proposal's method, "manual", "confirmation" (an earlier one, edited) or "segment N" (another view's, reused).
    var startedFrom: String
    /// The geometry it started from, as it was before the person touched it; nil when placed from nothing.
    var baseline: Geometry?
    /// The points the person moved or re-marked against the baseline (every point when placed from nothing).
    var adjustedPoints: [String]
    var confirmedAt: Date
    var confirmedBy: String
    /// The tool the person confirmed in.
    var tool: String
}

/// The court, or the net, of one camera view.
struct CalibrationPart<Geometry: CalibrationGeometry>: Codable, Equatable, Sendable {
    var proposals: [CalibrationProposal<Geometry>] = []
    var draft: Geometry?
    var draftStartedFrom: String?
    var draftBaseline: Geometry?
    var confirmation: CalibrationConfirmation<Geometry>?
    /// Earlier confirmations, replaced by a later one or withdrawn with the view.
    var history: [CalibrationConfirmation<Geometry>] = []

    /// Where an editor opens, in order: the draft; the confirmation; the latest detection; the latest estimate;
    /// nothing (the person places every point).
    var startingPoint: (geometry: Geometry?, startedFrom: String, baseline: Geometry?) {
        if let draft { return (draft, draftStartedFrom ?? CourtNetCalibrationV1.manual, draftBaseline) }
        if let confirmation { return (confirmation.geometry, CourtNetCalibrationV1.confirmation, confirmation.geometry) }
        if let p = proposals.last(where: { $0.kind == .detection }) ?? proposals.last(where: { $0.kind == .estimate }) {
            return (p.geometry, p.method, p.geometry)
        }
        return (nil, CourtNetCalibrationV1.manual, nil)
    }
}

struct CalibrationSegment: Codable, Equatable, Sendable, Identifiable {
    enum View: String, Codable, Sendable {
        /// One camera view of the court that holds still.
        case stable
        /// Not a stable court view (a pan, a zoom, a cut away, no court in the picture).
        case unsuitable = "not_stable_court_view"
        /// The person can't tell.
        case unknown
    }
    var id: Int
    var validFromSec: Double
    var validToSec: Double
    var view: View
    var court = CalibrationPart<CourtLayout>()
    var net = CalibrationPart<NetQuad>()
    /// Seconds into the recording of the frame the person last worked on.
    var frameTimeSec: Double?
    var note: String?
    /// When the person last said what the view is.
    var viewDecidedAt: Date?

    func contains(_ t: Double) -> Bool { t >= validFromSec && t < validToSec }
}

/// Where a recording's calibration stands, for a status line.
enum CalibrationStatus: String, Sendable {
    case notCalibrated, draft, courtConfirmed, netConfirmed, bothConfirmed
    /// No camera view of the recording is a stable court view.
    case unsuitable
    /// Made for another file or frame, or its camera views stand differently: a person has to look.
    case needsReview
}

enum CourtNetCalibrationError: LocalizedError, Equatable {
    case invalid([String])
    case unusableGeometry([String])
    case nothingToConfirm
    case notStableView
    case unreadable(String)
    case wouldDropConfirmation
    var errorDescription: String? {
        switch self {
        case .invalid(let p): return "The calibration is malformed: " + p.joined(separator: "; ")
        case .unusableGeometry(let p): return "This can't be confirmed: " + p.joined(separator: "; ")
        case .nothingToConfirm: return "There is nothing placed to confirm."
        case .notStableView: return "This part of the video is not marked as a stable court view."
        case .unreadable(let why): return "The saved calibration can't be read: \(why)"
        case .wouldDropConfirmation: return "Saving would lose a confirmation already on file."
        }
    }
}

struct CourtNetCalibrationFile: Codable, Equatable, Sendable {
    typealias Part<G: CalibrationGeometry> = WritableKeyPath<CalibrationSegment, CalibrationPart<G>>

    var schemaVersion: String
    var coordinateSpace: String
    var recordingId: String
    /// The video file's identity (FileFingerprint).
    var sourceFingerprint: String
    /// The upright frame, pixels.
    var frameWidth: Int
    var frameHeight: Int
    /// The orientation that turns the stored frames upright (CGImagePropertyOrientation's raw value).
    var orientation: UInt32
    var durationSec: Double
    /// The person's answers about the court (nil until asked).
    var setup: CourtSetup?
    var segments: [CalibrationSegment]

    /// The video as it is now.
    struct Binding: Equatable, Sendable {
        var recordingId: String
        var sourceFingerprint: String
        var frameWidth: Int
        var frameHeight: Int
        var orientation: UInt32
        var durationSec: Double
    }

    var binding: Binding {
        Binding(recordingId: recordingId, sourceFingerprint: sourceFingerprint, frameWidth: frameWidth, frameHeight: frameHeight,
                orientation: orientation, durationSec: durationSec)
    }

    static func new(for b: Binding) -> CourtNetCalibrationFile {
        CourtNetCalibrationFile(schemaVersion: CourtNetCalibrationV1.schemaVersion, coordinateSpace: CourtNetCalibrationV1.coordinateSpace,
                                recordingId: b.recordingId, sourceFingerprint: b.sourceFingerprint, frameWidth: b.frameWidth,
                                frameHeight: b.frameHeight, orientation: b.orientation, durationSec: b.durationSec, setup: nil,
                                segments: [CalibrationSegment(id: 0, validFromSec: 0, validToSec: b.durationSec, view: .stable)])
    }

    /// Why this file doesn't describe the video as it is now; nil when it does.
    func staleReason(for b: Binding) -> String? {
        if schemaVersion != CourtNetCalibrationV1.schemaVersion { return "schema \(schemaVersion), not \(CourtNetCalibrationV1.schemaVersion)" }
        if coordinateSpace != CourtNetCalibrationV1.coordinateSpace { return "coordinates are \(coordinateSpace)" }
        if recordingId != b.recordingId { return "made for another recording" }
        if sourceFingerprint != b.sourceFingerprint { return "the video file changed" }
        if frameWidth != b.frameWidth || frameHeight != b.frameHeight || orientation != b.orientation {
            return "the frame changed (\(frameWidth)×\(frameHeight) o\(orientation) → \(b.frameWidth)×\(b.frameHeight) o\(b.orientation))"
        }
        if abs(durationSec - b.durationSec) > Self.timeTolerance { return "the video's length changed" }
        return nil
    }

    private static let timeTolerance = 0.05

    /// Every reason the file is malformed; empty when it is sound. Segments tile the recording in order, and a
    /// confirmation is a usable geometry on a stable view.
    var problems: [String] {
        var out: [String] = []
        if schemaVersion != CourtNetCalibrationV1.schemaVersion { out.append("schema \(schemaVersion)") }
        if coordinateSpace != CourtNetCalibrationV1.coordinateSpace { out.append("coordinates \(coordinateSpace)") }
        if !Self.isSafeId(recordingId) { out.append("the recording id can't name a file") }
        if sourceFingerprint.isEmpty { out.append("no source fingerprint") }
        if frameWidth <= 0 || frameHeight <= 0 { out.append("frame \(frameWidth)×\(frameHeight)") }
        if !(durationSec > 0) { out.append("length \(durationSec) s") }
        if segments.isEmpty { out.append("no segments") }
        if Set(segments.map(\.id)).count != segments.count { out.append("segment ids repeat") }
        var cursor = 0.0
        for g in segments {
            if abs(g.validFromSec - cursor) > 1e-6 || !(g.validToSec > g.validFromSec) {
                out.append("segment \(g.id) spans \(g.validFromSec)–\(g.validToSec) s where \(cursor) s was expected")
            }
            cursor = g.validToSec
            if g.view != .stable, g.court.confirmation != nil || g.net.confirmation != nil {
                out.append("segment \(g.id) holds a confirmation but is not a stable view")
            }
            for p in g.court.confirmation?.geometry.problems ?? [] { out.append("segment \(g.id) court: \(p)") }
            for p in g.net.confirmation?.geometry.problems ?? [] { out.append("segment \(g.id) net: \(p)") }
        }
        if !segments.isEmpty, abs(cursor - durationSec) > 1e-6 { out.append("segments end at \(cursor) s, the recording at \(durationSec) s") }
        return out
    }

    /// Letters, digits, "-", "_" and "." only, not starting with a dot: a name, never a path.
    static func isSafeId(_ id: String) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)) }
    }

    private func index(of id: Int) throws -> Int {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { throw CourtNetCalibrationError.invalid(["no segment \(id)"]) }
        return i
    }

    // MARK: Reading

    /// The confirmed geometry in force at t; nil when the view there is not stable or nothing is confirmed.
    func confirmed<G>(_ part: KeyPath<CalibrationSegment, CalibrationPart<G>>, at t: Double) -> CalibrationConfirmation<G>? {
        guard let g = segments.first(where: { $0.contains(t) }), g.view == .stable, let c = g[keyPath: part].confirmation,
              c.geometry.problems.isEmpty else { return nil }
        return c
    }

    /// Where the calibration stands for the video as it is now.
    func status(for b: Binding) -> CalibrationStatus {
        if staleReason(for: b) != nil || !problems.isEmpty { return .needsReview }
        let stable = segments.filter { $0.view == .stable }
        guard !stable.isEmpty else { return .unsuitable }
        let each = Set(stable.map { g -> CalibrationStatus in
            switch (g.court.confirmation != nil, g.net.confirmation != nil) {
            case (true, true): return .bothConfirmed
            case (true, false): return .courtConfirmed
            case (false, true): return .netConfirmed
            case (false, false): return g.court.draft != nil || g.net.draft != nil ? .draft : .notCalibrated
            }
        })
        return each.count == 1 ? each.first! : .needsReview
    }

    // MARK: Changing

    /// Keeps a proposal with the segment. It changes neither the draft nor the confirmation.
    mutating func add<G>(_ proposal: CalibrationProposal<G>, to part: Part<G>, segment id: Int) throws {
        let i = try index(of: id)
        segments[i][keyPath: part].proposals.append(proposal)
    }

    /// The person's working geometry: saved as placed, usable or not. baseline is what it started from, untouched.
    mutating func saveDraft<G>(_ geometry: G, of part: Part<G>, segment id: Int, startedFrom: String, baseline: G?) throws {
        let i = try index(of: id)
        segments[i][keyPath: part].draft = geometry
        segments[i][keyPath: part].draftStartedFrom = startedFrom
        segments[i][keyPath: part].draftBaseline = baseline
    }

    /// Start over: the draft goes; a confirmation stays in force.
    mutating func discardDraft<G>(of part: Part<G>, segment id: Int) throws {
        let i = try index(of: id)
        segments[i][keyPath: part].draft = nil
        segments[i][keyPath: part].draftStartedFrom = nil
        segments[i][keyPath: part].draftBaseline = nil
    }

    /// The person's Confirm: the draft becomes the segment's confirmation, the one before it history. The only
    /// way a geometry becomes confirmed.
    mutating func confirm<G>(_ part: Part<G>, segment id: Int, by person: String, tool: String, now: Date) throws {
        let i = try index(of: id)
        guard segments[i].view == .stable else { throw CourtNetCalibrationError.notStableView }
        let p = segments[i][keyPath: part]
        guard let geometry = p.draft else { throw CourtNetCalibrationError.nothingToConfirm }
        let problems = geometry.problems
        guard problems.isEmpty else { throw CourtNetCalibrationError.unusableGeometry(problems) }
        if let old = p.confirmation { segments[i][keyPath: part].history.append(old) }
        segments[i][keyPath: part].confirmation = CalibrationConfirmation(
            geometry: geometry, startedFrom: p.draftStartedFrom ?? CourtNetCalibrationV1.manual, baseline: p.draftBaseline,
            adjustedPoints: p.draftBaseline.map { geometry.changedPoints(from: $0) } ?? G.pointNames,
            confirmedAt: Self.wholeSeconds(now), confirmedBy: person, tool: tool)
        try discardDraft(of: part, segment: id)
    }

    /// What the person says the view is. A view that is not stable keeps no confirmation: they move to history.
    mutating func setView(_ view: CalibrationSegment.View, segment id: Int, note: String?, at: Date) throws {
        let i = try index(of: id)
        if view != .stable {
            if let old = segments[i].court.confirmation { segments[i].court.history.append(old) }
            if let old = segments[i].net.confirmation { segments[i].net.history.append(old) }
            segments[i].court.confirmation = nil
            segments[i].net.confirmation = nil
        }
        segments[i].view = view
        segments[i].note = note
        segments[i].viewDecidedAt = Self.wholeSeconds(at)
    }

    /// The camera changed at t: the segment holding t becomes two. The second starts with nothing confirmed; with
    /// reuse, the first's confirmed (or drafted) court and net are its drafts — a starting point for the new view,
    /// never a confirmation. False when t is within the tolerance of the segment's ends.
    mutating func split(at t: Double, reuse: Bool) -> Bool {
        guard let i = segments.firstIndex(where: { $0.contains(t) }), t - segments[i].validFromSec > Self.timeTolerance,
              segments[i].validToSec - t > Self.timeTolerance else { return false }
        let first = segments[i]
        var second = CalibrationSegment(id: (segments.map(\.id).max() ?? 0) + 1, validFromSec: t, validToSec: first.validToSec, view: .stable)
        if reuse {
            second.court = Self.reused(first.court, from: first.id)
            second.net = Self.reused(first.net, from: first.id)
        }
        segments[i].validToSec = t
        segments.insert(second, at: i + 1)
        return true
    }

    private static func reused<G>(_ part: CalibrationPart<G>, from id: Int) -> CalibrationPart<G> {
        guard let geometry = part.confirmation?.geometry ?? part.draft else { return CalibrationPart() }
        return CalibrationPart(draft: geometry, draftStartedFrom: "segment \(id)", draftBaseline: geometry)
    }

    /// Dates are written to the second; one kept finer in memory would not equal itself read back.
    private static func wholeSeconds(_ d: Date) -> Date { Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down)) }
}
