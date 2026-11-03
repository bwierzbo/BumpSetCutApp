//
//  TrainingEligibility.swift
//  RallyLab
//
//  What each model may use of a recording, from its admission state and its
//  footage properties (owner direction of 2026-11-02, §3 "Model-Specific
//  Eligibility"): standard, restricted (useful under the stated condition),
//  quarantined (excluded pending review), not assessed (nothing known yet —
//  an explicit unknown, never a pass), or ineligible (withheld). Judged per
//  model and, through the spans, per usable interval; the reasons travel
//  with the verdict. The rules are the direction's starting table, conservative,
//  and live here alone so a later controlled experiment can change them in one
//  place. A proposal nobody confirmed restricts and never clears; an unknown
//  trait a person confirmed quarantines. Separately: whether the recording's
//  unmarked time may serve as ordinary non-rally negatives (§4) — edited time
//  may not, and an unconfirmed recording type is not assessed, however complete
//  its marks are declared.
//

import Foundation

enum TrainingEligibility {
    enum Model: String, Codable, CaseIterable, Sendable {
        case rallyClassifier = "rally_classifier"
        case ballDetector = "ball_detector"
        case netDetector = "net_detector"
    }

    enum Level: String, Codable, Sendable, Comparable {
        case standard
        case restricted
        case quarantined
        case ineligible
        case notAssessed = "not_assessed"

        /// Worse wins when verdicts combine.
        private var severity: Int { [Level.standard, .restricted, .quarantined, .ineligible].firstIndex(of: self) ?? -1 }
        static func < (a: Level, b: Level) -> Bool { a.severity < b.severity }
    }

    struct Verdict: Codable, Equatable, Sendable {
        var level: Level
        var reasons: [String] = []

        static func notAssessed(_ why: String) -> Verdict { Verdict(level: .notAssessed, reasons: [why]) }

        /// This verdict with `other` folded in: the worse level, the reasons joined.
        func combined(_ other: Verdict) -> Verdict {
            if level == .notAssessed { return other }
            if other.level == .notAssessed { return self }
            return Verdict(level: max(level, other.level), reasons: reasons + other.reasons.filter { !reasons.contains($0) })
        }
    }

    struct Assessment: Codable, Equatable, Sendable {
        /// Keyed by `Model.rawValue`.
        var byModel: [String: Verdict]
        /// Whether unmarked time of a fully marked recording may be ordinary non-rally negatives.
        var fullVideoNegatives: Verdict

        subscript(_ model: Model) -> Verdict { byModel[model.rawValue] ?? .notAssessed("not assessed") }
    }

    // MARK: - The policy

    /// The direction's table, per trait and model. nil = standard (no restriction from this trait).
    static func rule(_ trait: FootageProperties.Trait, _ model: Model) -> (level: Level, reason: String)? {
        switch (trait, model) {
        case (.fixedCamera, _), (.normalPanning, _), (.normalSpeed, _): return nil
        case (.aggressivePanning, .netDetector): return (.restricted, "aggressive camera movement: conditional for the net")
        case (.aggressivePanning, _): return (.restricted, "aggressive camera movement: restricted initially")
        case (.handheld, _): return (.restricted, "handheld or unstable camera: restricted initially")
        case (.digitalZoom, .rallyClassifier): return (.restricted, "digital zoom/crop: conditional")
        case (.digitalZoom, .ballDetector): return (.restricted, "digital zoom/crop: eligible only where the crop's geometry and labels are validated; keep crop and scaling metadata")
        case (.digitalZoom, .netDetector): return (.restricted, "digital zoom/crop: the label must match the crop's geometry")
        case (.cameraAngleChange, .rallyClassifier), (.cameraAngleChange, .ballDetector): return (.restricted, "camera cut: no temporal window across it; a cut is not a rally transition")
        case (.cameraAngleChange, .netDetector): return nil
        case (.slowMotion, .rallyClassifier): return (.restricted, "slow motion: excluded from temporal training; not live-play timing")
        case (.slowMotion, .ballDetector): return (.restricted, "slow motion: single frames only in a dataset that supports single-frame supervision; no temporal window inside the span")
        case (.slowMotion, .netDetector): return nil
        case (.replay, .rallyClassifier): return (.restricted, "replay: the interval is excluded from temporal training")
        case (.replay, .ballDetector): return (.restricted, "replay: single frames only; no temporal window inside the span; not an independent example of its source")
        case (.replay, .netDetector): return nil
        case (.montage, .rallyClassifier), (.montage, .ballDetector): return (.restricted, "montage: no temporal window across its cuts; no ordinary dead time")
        case (.montage, .netDetector): return nil
        case (.deadTimeRemoved, _): return nil
        case (.overlays, .netDetector): return (.restricted, "heavy overlays or effects: conditional")
        case (.overlays, _): return (.restricted, "heavy overlays or effects: restricted")
        case (.unknown, _): return (.quarantined, "footage of unknown kind: quarantined pending review")
        }
    }

    /// Traits that make the recording's unmarked time unusable as ordinary non-rally negatives.
    static func negativesRule(_ trait: FootageProperties.Trait) -> String? {
        switch trait {
        case .deadTimeRemoved: return "dead time removed: missing dead time is not normal between-rally behaviour"
        case .montage: return "montage: cuts are not rally transitions"
        case .replay: return "replay: not live-play timing"
        case .slowMotion: return "slow motion: not live-play timing"
        case .cameraAngleChange: return "camera cut: not a rally transition"
        case .unknown: return "footage of unknown kind"
        default: return nil
        }
    }

    static func assess(admission: SourceRegistry.Admission, properties: FootageProperties.File?, unreadableReason: String? = nil) -> Assessment {
        func all(_ v: Verdict) -> Assessment { Assessment(byModel: Dictionary(uniqueKeysWithValues: Model.allCases.map { ($0.rawValue, v) }), fullVideoNegatives: v) }
        if let why = unreadableReason { return all(Verdict(level: .quarantined, reasons: ["footage-properties record unreadable: \(why)"])) }
        switch admission {
        case .withheld: return all(Verdict(level: .ineligible, reasons: ["withheld (D-017): never trained on"]))
        case .quarantined: return all(Verdict(level: .quarantined, reasons: ["admission: quarantined"]))
        case .rejected: return all(Verdict(level: .ineligible, reasons: ["admission: rejected"]))
        case .unidentified: return all(Verdict(level: .quarantined, reasons: ["no file identity: cannot be checked against the reservations by content"]))
        case .pendingIngest: return all(.notAssessed("not in the dataset yet"))
        case .admitted: break
        }
        guard let p = properties else { return all(.notAssessed("footage not characterised (no footage-properties record)")) }
        let confirmed = p.traits(.confirmed), proposed = p.traits(.proposed).subtracting(confirmed)
        var byModel: [String: Verdict] = [:]
        for model in Model.allCases {
            var v = Verdict(level: .standard)
            for t in confirmed.sorted(by: { $0.rawValue < $1.rawValue }) {
                if let r = rule(t, model) { v = v.combined(Verdict(level: r.level, reasons: [r.reason])) }
            }
            for t in proposed.sorted(by: { $0.rawValue < $1.rawValue }) {
                // A proposal restricts and never clears; it cannot quarantine on its own.
                if let r = rule(t, model) { v = v.combined(Verdict(level: .restricted, reasons: ["proposed, unconfirmed: \(r.reason)"])) }
            }
            if p.recordingType == .edited, model != .netDetector, v.level == .standard {
                v = v.combined(Verdict(level: .restricted, reasons: ["edited recording: temporal windows only within confirmed continuous spans"]))
            }
            if p.recordingType == .unknown, p.activeSpans.isEmpty, v.level == .standard { v = .notAssessed("recording type not confirmed and no span recorded") }
            byModel[model.rawValue] = v
        }
        var negatives: Verdict
        switch p.recordingType {
        case .continuous: negatives = Verdict(level: .standard, reasons: ["continuous recording (confirmed)"])
        case .edited: negatives = Verdict(level: .restricted, reasons: ["edited recording: no ordinary full-video negative sampling"])
        case .unknown: negatives = .notAssessed("recording type not confirmed: declared completion is not evidence of uninterrupted real time")
        }
        for t in confirmed.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let why = negativesRule(t) { negatives = negatives.combined(Verdict(level: t == .unknown ? .quarantined : .restricted, reasons: [why])) }
        }
        for t in proposed.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let why = negativesRule(t) { negatives = negatives.combined(Verdict(level: .restricted, reasons: ["proposed, unconfirmed: \(why)"])) }
        }
        return Assessment(byModel: byModel, fullVideoNegatives: negatives)
    }
}
