//
//  CourtWebImport.swift
//  RallyLab
//
//  Brings the owner's court decisions from the private Court Check page (a claude.ai
//  artifact the owner opens on the phone) into `<experiment>/court-calibrations/`. The
//  page stores one document per segment; Claude exports them to a JSON file and this
//  applies them. Only a document whose decision is `confirmed`, `rejected` or
//  `unknown_view` is applied — a draft never is — and only to a calibration file still
//  bound to the footage the page showed. A confirmation keeps the time the owner pressed
//  Confirm and is recorded as `player_lab_web`.
//

import Foundation

enum CourtWebImport {
    struct Export: Decodable {
        /// The page's claude.ai URL.
        var artifact: String
        var courts: [Row]
    }

    struct Row: Decodable {
        struct Binding: Decodable {
            var sourceFingerprint: String?
            var decodedFingerprint: String
            var frameWidth: Int
            var frameHeight: Int
            var orientation: UInt32?
        }
        struct Setup: Decodable {
            var surface: String?
            var format: String?
            var markings: String?
            var answeredAt: String?
        }
        var recordingId: String
        var segment: Int
        var binding: Binding
        var setup: Setup?
        var decision: String
        var geometry: CourtLayout?
        var startedFrom: String?
        var decidedAt: String?
        /// The claude.ai viewer id of whoever pressed the button (the page only lets its owner write).
        var decidedBy: String?
        var note: String?
    }

    struct Outcome: Equatable {
        var recordingId: String
        var segment: Int
        var applied: Bool
        var detail: String
    }

    /// The page's ISO time, to the whole second — the precision a calibration file stores, so a re-import matches what it wrote.
    static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: s) }() {
            return Date(timeIntervalSince1970: d.timeIntervalSince1970.rounded(.down))
        }
        return nil
    }

    /// Applies every decided row to its calibration file (unless `dryRun`); never throws for one bad row — each gets an outcome.
    static func apply(_ export: Export, experiment: URL, recordings: [PlayerFeatures.Recording], dryRun: Bool) throws -> [Outcome] {
        let store = CourtCalibrationStore(experiment: experiment)
        var out: [Outcome] = []
        for row in export.courts.sorted(by: { ($0.recordingId, $0.segment) < ($1.recordingId, $1.segment) }) {
            func skip(_ why: String) { out.append(Outcome(recordingId: row.recordingId, segment: row.segment, applied: false, detail: why)) }
            guard ["confirmed", "rejected", "unknown_view"].contains(row.decision) else { skip("not decided (\(row.decision)) — left alone"); continue }
            guard let rec = recordings.first(where: { $0.recordingId == row.recordingId }) else { skip("not in this run"); continue }
            let binding = CourtCalibrationFile.Binding(rec)
            guard var file = try store.load(rec.recordingId) else { skip("no calibration file"); continue }
            if let why = file.staleReason(for: binding) { skip("calibration is stale (\(why)) — not applied"); continue }
            let b = row.binding
            guard b.sourceFingerprint == file.sourceFingerprint, b.decodedFingerprint == file.decodedFingerprint, b.frameWidth == file.frameWidth,
                  b.frameHeight == file.frameHeight, b.orientation.map({ $0 == file.orientation }) ?? true else {
                skip("the page showed other footage than the calibration's — not applied"); continue
            }
            guard let i = file.segments.firstIndex(where: { $0.id == row.segment }) else { skip("no segment \(row.segment)"); continue }
            guard let decidedAt = date(row.decidedAt) else { skip("no decision time — not applied"); continue }
            let seg = file.segments[i]
            let note = (row.note.map { $0 + " " } ?? "") + "(Court Check page \(export.artifact))"

            if let s = row.setup {
                let setup = CourtSetup(surface: s.surface.flatMap(CourtSetup.Surface.init(rawValue:)), format: s.format.flatMap(CourtSetup.Format.init(rawValue:)),
                                       markings: s.markings.flatMap(CourtSetup.Markings.init(rawValue:)), answeredAt: date(s.answeredAt) ?? decidedAt)
                if file.setup?.surface != setup.surface || file.setup?.format != setup.format || file.setup?.markings != setup.markings { file.setup = setup }
            }
            switch row.decision {
            case "confirmed":
                guard let g = row.geometry else { skip("confirmed without a court — not applied"); continue }
                if let c = seg.confirmation, c.method == CourtConfirmation.webMethod, c.confirmedAt == decidedAt, c.geometry == g {
                    skip("already imported"); continue
                }
                let baseline = seg.latestProposals.first { $0.method.rawValue == row.startedFrom }?.geometry
                let spec = file.setup?.spec ?? CourtSpec.standard(surface: rec.surface)
                do {
                    try file.confirm(segment: row.segment, geometry: g, startedFrom: row.startedFrom ?? "manual", baseline: baseline,
                                     by: "owner \(row.decidedBy ?? "unknown") on the Court Check page (\(export.artifact))", net: rec.net, spec: spec,
                                     format: file.setup?.format?.rawValue, now: decidedAt, method: CourtConfirmation.webMethod)
                } catch { skip(error.localizedDescription); continue }
            default:
                let status: CourtSegment.Status = row.decision == "rejected" ? .rejected : .unknownView
                if seg.status == status, seg.note == note { skip("already imported"); continue }
                file.set(segment: row.segment, status: status, note: note)
            }
            if !dryRun { try store.save(file) }
            out.append(Outcome(recordingId: row.recordingId, segment: row.segment, applied: true,
                               detail: row.decision + (dryRun ? " (dry run — not written)" : "")))
        }
        return out
    }

    /// The command: reads the run's recordings and the exported page documents, applies them, logs each outcome.
    static func run(experiment: URL, runName: String, exportFile: URL, dryRun: Bool, log: (String) -> Void) throws -> [Outcome] {
        let manifestURL = experiment.appendingPathComponent("runs/\(runName)/features/player-features-manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw CourtPilot.Failure.noRun(manifestURL.path) }
        let manifest = try JSONDecoder().decode(PlayerFeatures.Manifest.self, from: data)
        let export = try JSONDecoder().decode(Export.self, from: Data(contentsOf: exportFile))
        let outcomes = try apply(export, experiment: experiment, recordings: manifest.recordings, dryRun: dryRun)
        for o in outcomes { log("\(o.applied ? "✅" : "·") \(o.recordingId) segment \(o.segment): \(o.detail)") }
        return outcomes
    }
}
