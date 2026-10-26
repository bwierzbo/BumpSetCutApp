//
//  EventInventory.swift
//  RallyLab
//
//  Read-only views of the Stage 1 review state (D-024): per recording, the legacy
//  marks in `<video>.rallylabels.json` (every one `legacy_unverified`, its origin
//  `legacy_unknown` — the file keeps no annotator, method or time), the reviewed
//  rallies, spans and coverage in `<video>.rallyevents.json`, and whether Stage 1 is
//  complete. Withheld recordings (the L2 closure, by name, path and content — the
//  same refusal as opening one) are listed as withheld with no times: their
//  sidecars are not even read. Nothing here writes a sidecar or a
//  ledger row; `--event-inventory` writes its report under manifests/, `--review-status`
//  prints the coverage table alone.
//

import Foundation

enum EventInventory {
    struct Recording: Codable, Equatable {
        var name: String
        var split: String
        var withheld: Bool
        var durationSec: Double?
        /// Legacy marks in rallylabels.json; all `legacy_unverified`, origin `legacy_unknown`.
        var legacyMarks: Int?
        var legacyFile: Bool
        var eventsFile: Bool
        var reviewedRallies: Int
        var withdrawnRallies: Int
        var spans: Int
        var coverageSec: Double
        /// Reviewed coverage over the duration, 0…1; nil when the duration is unknown (no events file yet).
        var coverageFraction: Double?
        var unknownGaps: Int
        var stage1Complete: Bool
        /// Why the events file beside the video is not this recording's record (another video's name,
        /// or content that changed since it was written, or an unreadable file); its figures are then not
        /// reported — nothing above is claimed for it.
        var recordProblem: String?
    }

    struct Report: Codable, Equatable {
        var createdAt: String
        var project: String
        var annotationVersion: String = EventReview.annotationVersion
        var manifestHashes: DatasetSplitManifest.Hashes
        var recordings: [Recording]
    }

    /// The inventory of every session in the project, withheld ones named but not read.
    static func build(root: URL, now: Date = Date()) throws -> Report {
        let withheld = try EventReview.withheldNames(in: root)
        let sessions = try DatasetStore(root: root).loadSessionsStrict()
        let hashes = DatasetSplitManifest.Hashes(
            projectJson: DatasetSplitManifest.sha256(of: root.appendingPathComponent("project.json")),
            sessions: DatasetSplitManifest.canonicalDigest(ofDirectory: root.appendingPathComponent("sessions", isDirectory: true)),
            validationJson: DatasetSplitManifest.sha256(of: root.appendingPathComponent("pipeline_tuning/validation.json")))
        var rows: [Recording] = []
        for s in sessions.sorted(by: { $0.name < $1.name }) {
            // The same guard as opening a recording: a session over a withheld recording's file or
            // content is withheld here too, and its sidecars are not read.
            let refused = try EventReview.refusal(of: s, root: root, sessions: sessions)
            if withheld.contains(s.name) || refused != nil {
                rows.append(Recording(name: s.name, split: s.split, withheld: true, durationSec: nil, legacyMarks: nil, legacyFile: false, eventsFile: false,
                                      reviewedRallies: 0, withdrawnRallies: 0, spans: 0, coverageSec: 0, coverageFraction: nil, unknownGaps: 0, stage1Complete: false, recordProblem: nil))
                continue
            }
            let legacyURL = RallyMarkModel.labelsURL(for: s.sourceURL)
            let legacyMarks = (try? Data(contentsOf: legacyURL)).flatMap { try? JSONDecoder().decode([RallyMarkRecord].self, from: $0) }?.count
            let eventsURL = EventReview.url(forVideo: s.sourceURL)
            var row = Recording(name: s.name, split: s.split, withheld: false, durationSec: nil, legacyMarks: legacyMarks,
                                legacyFile: FileManager.default.fileExists(atPath: legacyURL.path), eventsFile: false,
                                reviewedRallies: 0, withdrawnRallies: 0, spans: 0, coverageSec: 0, coverageFraction: nil, unknownGaps: 0, stage1Complete: false, recordProblem: nil)
            if FileManager.default.fileExists(atPath: eventsURL.path) {
                row.eventsFile = true
                // The same identity checks as opening the recording: a record for another video, or for
                // content that has since changed, reports nothing but the problem.
                let file: EventReview.File
                do { file = try EventReview.read(eventsURL) } catch { row.recordProblem = error.localizedDescription; rows.append(row); continue }
                if let problem = EventReview.identityProblem(of: file, for: s) { row.recordProblem = problem.localizedDescription; rows.append(row); continue }
                row.durationSec = file.durationSec
                row.reviewedRallies = file.rallies.filter { $0.reviewState == .reviewed }.count
                row.withdrawnRallies = file.rallies.filter { $0.reviewState == .withdrawn }.count
                row.spans = file.spans.count
                row.coverageSec = EventReview.union(file.coverage).reduce(0) { $0 + ($1.end - $1.start) }
                row.coverageFraction = min(1, row.coverageSec / file.durationSec)
                row.unknownGaps = EventReview.gaps(in: file).count
                row.stage1Complete = file.stage1Complete != nil
            }
            rows.append(row)
        }
        return Report(createdAt: EventReview.stamp(now), project: root.lastPathComponent, manifestHashes: hashes, recordings: rows)
    }

    /// Writes the report as JSON and CSV under `manifests/`, named by the stamp; returns both URLs.
    static func write(_ report: Report, in root: URL, stamp: String) throws -> (json: URL, csv: URL) {
        let dir = root.appendingPathComponent("manifests", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = dir.appendingPathComponent("event-inventory-\(stamp).json")
        let csv = dir.appendingPathComponent("event-inventory-\(stamp).csv")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: json, options: .atomic)
        var lines = ["name,split,withheld,legacyMarks,legacyUnverified,sourceMethod,eventsFile,reviewedRallies,withdrawnRallies,spans,coverageSec,coverageFraction,unknownGaps,stage1Complete,recordProblem"]
        for r in report.recordings {
            let marks = r.legacyMarks.map(String.init) ?? ""
            lines.append([r.name, r.split, r.withheld ? "yes" : "no", marks, marks, r.legacyMarks == nil ? "" : "legacy_unknown",
                          r.eventsFile ? "yes" : "no", String(r.reviewedRallies), String(r.withdrawnRallies), String(r.spans),
                          String(format: "%.3f", r.coverageSec), r.coverageFraction.map { String(format: "%.4f", $0) } ?? "",
                          String(r.unknownGaps), r.stage1Complete ? "yes" : "no",
                          (r.recordProblem ?? "").replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " ")].joined(separator: ","))
        }
        try (lines.joined(separator: "\n") + "\n").write(to: csv, atomically: true, encoding: .utf8)
        return (json, csv)
    }

    /// The coverage table, one line per recording, for a report or the terminal.
    static func statusLines(_ report: Report) -> [String] {
        var out: [String] = []
        let complete = report.recordings.filter(\.stage1Complete).count
        let started = report.recordings.filter { $0.eventsFile && !$0.stage1Complete && $0.recordProblem == nil }.count
        let invalid = report.recordings.filter { $0.recordProblem != nil }.count
        let withheld = report.recordings.filter(\.withheld).count
        let eligible = report.recordings.count - withheld
        out.append("Stage 1 review: \(complete) of \(eligible) eligible recordings complete, \(started) started, \(eligible - complete - started - invalid) not started"
                   + (invalid > 0 ? ", \(invalid) with a record that is not theirs" : "") + "; \(withheld) withheld (not reviewed)")
        for r in report.recordings {
            if r.withheld { out.append("  \(r.name): withheld"); continue }
            if let problem = r.recordProblem { out.append("  \(r.name) (\(r.split)): record not accepted — \(problem)"); continue }
            let cov = r.coverageFraction.map { String(format: "%3.0f %% reviewed", $0 * 100) } ?? "  0 % reviewed"
            let state = r.stage1Complete ? "complete" : (r.eventsFile ? "in progress, \(r.unknownGaps) unknown gap(s)" : "not started")
            let legacy = r.legacyMarks.map { "\($0) legacy mark(s), unverified" } ?? "no legacy marks"
            out.append("  \(r.name) (\(r.split)): \(cov) · \(r.reviewedRallies) rallies reviewed · \(r.spans) span(s) · \(state) · \(legacy)")
        }
        return out
    }
}
