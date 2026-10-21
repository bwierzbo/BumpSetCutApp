//
//  DatasetAudit.swift
//  RallyLab
//
//  Leakage and provenance-quality checks over a DatasetSplitManifest
//  (decisions D-002, D-009; AGENTS.md rule 3). A *hard* finding means two
//  videos that share a recording (same file fingerprint) or a confirmed
//  sourceId / sessionId / venueId sit on different sides of a split
//  boundary; `--audit-dataset` exits non-zero on any. *Soft* findings are
//  grouping that might be a leak but isn't proven: the same clip card or
//  uploader, cards the dataset split per video. *Info*
//  is what the owner needs to decide: final-test candidates, provenance
//  still unconfirmed.
//

import Foundation

struct DatasetAudit: Codable {
    enum Severity: String, Codable, Comparable {
        case hard, soft, info
        private var rank: Int { self == .hard ? 0 : self == .soft ? 1 : 2 }
        static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    }

    struct Finding: Codable, Equatable {
        var severity: Severity
        var code: String
        var message: String
        var videos: [String]
    }

    var createdAt: Date
    var manifestHashes: DatasetSplitManifest.Hashes
    var findings: [Finding]

    var hasHardLeak: Bool { findings.contains { $0.severity == .hard } }

    // MARK: - Run

    static func run(manifest: DatasetSplitManifest, now: Date = Date()) -> DatasetAudit {
        var findings: [Finding] = []
        let videos = manifest.videos

        // Groups that prove a shared origin.
        findings += grouped(videos, code: "FP-SHARED", label: "same file fingerprint") { $0.fingerprint }
        findings += grouped(videos, code: "SOURCE-SHARED", label: "same confirmed sourceId") { $0.sourceId.origin == .confirmed ? $0.sourceId.value : nil }
        findings += grouped(videos, code: "SESSION-SHARED", label: "same confirmed sessionId") { $0.sessionId.origin == .confirmed ? $0.sessionId.value : nil }
        findings += grouped(videos, code: "VENUE-SHARED", label: "same confirmed venueId") { $0.venueId.origin == .confirmed ? $0.venueId.value : nil }
        // A card is a planned category (one channel/outing as the owner filed it), not confirmed
        // recording, session or venue identity (D-009): never more than soft.
        findings += grouped(videos, code: "CARD-SPLIT", label: "same clip card", cap: .soft) { $0.clipId }
        // An uploader is one channel, not one venue: never more than soft.
        findings += grouped(videos, code: "UPLOADER-SPLIT", label: "same uploader", cap: .soft) { $0.uploader }

        // Cards the dataset split video by video.
        let autoCards = Dictionary(grouping: videos.filter { $0.clipId != nil && $0.cardSplit == nil }, by: { $0.clipId! })
        for (card, rows) in autoCards.sorted(by: { $0.key < $1.key }) where rows.count > 1 {
            findings.append(Finding(severity: .soft, code: "CARD-AUTO",
                                    message: "Card \(card) has no pinned split; its \(rows.count) videos were split one by one (\(Set(rows.map(\.split.rawValue)).sorted().joined(separator: ", "))). Pin the card.",
                                    videos: rows.map(\.video).sorted()))
        }

        // Surface named by the card vs by the ID prefix.
        for v in videos {
            if let card = v.surface, let prefix = ClipID.surface(of: v.video)?.rawValue, card != prefix {
                findings.append(Finding(severity: .soft, code: "SURFACE-MISMATCH",
                                        message: "\(v.video): card says \(card), the ID prefix says \(prefix).", videos: [v.video]))
            }
        }

        // Videos the dataset has that project.json doesn't know.
        let orphans = videos.filter { $0.clipId == nil }.map(\.video)
        if !orphans.isEmpty {
            findings.append(Finding(severity: .soft, code: "ORPHAN-SESSION",
                                    message: "\(orphans.count) session(s) have no clip card in project.json, so no uploader, surface or provenance.", videos: orphans))
        }

        // Reserved splits must have been reserved for a reason.
        for v in videos where v.split == .legacyHoldout {
            if v.exposure.isEmpty {
                findings.append(Finding(severity: .info, code: "HOLDOUT-UNEXPOSED",
                                        message: "\(v.video) is legacy_holdout but has no recorded exposure; it may qualify as final_test (check its card and uploader below).", videos: [v.video]))
            }
        }

        // Final-test candidates: no exposure at all, and nothing of theirs in train.
        let trainCards = Set(videos.filter { $0.split == .train }.compactMap(\.clipId))
        let trainUploaders = Set(videos.filter { $0.split == .train }.compactMap(\.uploader))
        let trainPrints = Set(videos.filter { $0.split == .train }.compactMap(\.fingerprint))
        let candidates = videos.filter { $0.exposure.isEmpty && $0.split != .finalTest && $0.split != .train }
        let clean = candidates.filter { v in
            !(v.clipId.map(trainCards.contains) ?? false) && !(v.uploader.map(trainUploaders.contains) ?? false)
                && !(v.fingerprint.map(trainPrints.contains) ?? false)
        }
        let overlapping = candidates.filter { !clean.contains($0) }
        if !clean.isEmpty {
            findings.append(Finding(severity: .info, code: "FINAL-TEST-CANDIDATE",
                                    message: "\(clean.count) video(s) have no recorded exposure and share no card, uploader or file with train. Owner decision: confirm venue/session, then list in validation.json `finalTest`.",
                                    videos: clean.map(\.video).sorted()))
        }
        if !overlapping.isEmpty {
            findings.append(Finding(severity: .info, code: "FINAL-TEST-CANDIDATE-OVERLAP",
                                    message: "\(overlapping.count) video(s) have no recorded exposure but share a card, uploader or file with a train video; not independent as they stand.",
                                    videos: overlapping.map(\.video).sorted()))
        }
        if candidates.isEmpty {
            findings.append(Finding(severity: .info, code: "FINAL-TEST-NONE",
                                    message: "Every video has recorded exposure; an independent final test needs new recordings.", videos: []))
        }

        // Provenance quality.
        let unconfirmedSource = videos.filter { $0.sourceId.origin != .confirmed }.map(\.video)
        if !unconfirmedSource.isEmpty {
            let inferred = videos.filter { $0.sourceId.origin == .inferredFingerprint }.count
            findings.append(Finding(severity: .info, code: "PROVENANCE-SOURCE",
                                    message: "\(unconfirmedSource.count) video(s) have no confirmed sourceId (\(inferred) carry a file fingerprint as a suggestion, \(unconfirmedSource.count - inferred) nothing). Confirm with `--set-provenance <video> --source-id <id>`.",
                                    videos: unconfirmedSource))
        }
        let noSession = videos.filter { $0.sessionId.origin != .confirmed }.map(\.video)
        let noVenue = videos.filter { $0.venueId.origin != .confirmed }.map(\.video)
        if !noVenue.isEmpty {
            findings.append(Finding(severity: .info, code: "PROVENANCE-VENUE",
                                    message: "\(noVenue.count) video(s) have no confirmed venueId and \(noSession.count) no sessionId. Until set, grouping by venue is impossible and the uploader/card checks above are the only guard.",
                                    videos: noVenue))
        }

        // Reserved videos whose card or uploader also appears in train (already hard via CARD-SPLIT / soft via UPLOADER-SPLIT; say it plainly).
        for v in videos where v.split.isReserved {
            if let u = v.uploader, trainUploaders.contains(u) {
                findings.append(Finding(severity: .soft, code: "RESERVED-UPLOADER-IN-TRAIN",
                                        message: "\(v.video) (\(v.split.rawValue)) shares uploader \"\(u)\" with train videos; confirm it is a different venue/session.", videos: [v.video]))
            }
        }

        return DatasetAudit(createdAt: now, manifestHashes: manifest.hashes,
                            findings: findings.sorted { ($0.severity, $0.code, $0.videos.first ?? "") < ($1.severity, $1.code, $1.videos.first ?? "") })
    }

    /// Videos that share `key` but sit in different splits. Train vs anything
    /// else, or any mix that touches a reserved split, is hard; dev_val vs
    /// tune is soft; `cap` lowers the ceiling for keys that don't prove origin.
    private static func grouped(_ videos: [ManifestVideo], code: String, label: String, cap: Severity = .hard,
                                key: (ManifestVideo) -> String?) -> [Finding] {
        var out: [Finding] = []
        let groups = Dictionary(grouping: videos.compactMap { v in key(v).map { ($0, v) } }, by: { $0.0 })
        for (value, pairs) in groups.sorted(by: { $0.key < $1.key }) {
            let rows = pairs.map(\.1)
            let splits = Set(rows.map(\.split))
            guard splits.count > 1 else { continue }
            let crossesTrain = splits.contains(.train)
            let touchesReserved = splits.contains { $0.isReserved }
            // Severity orders hard < soft < info, so `max` applies the ceiling.
            let severity = max((crossesTrain || touchesReserved) ? Severity.hard : .soft, cap)
            out.append(Finding(severity: severity, code: code,
                               message: "\(rows.count) videos with \(label) \"\(value)\" sit in \(splits.map(\.rawValue).sorted().joined(separator: " + ")).",
                               videos: rows.map(\.video).sorted()))
        }
        return out
    }

    // MARK: - Report

    func markdown(manifest: DatasetSplitManifest) -> String {
        var md = "# Dataset audit — \(manifest.project)\n\n"
        md += "Run \(ISO8601DateFormatter().string(from: createdAt)) on manifest hashes project.json `\(manifestHashes.projectJson.map { String($0.prefix(16)) } ?? "—")`, sessions `\(manifestHashes.sessions.map { String($0.prefix(16)) } ?? "—")`.\n\n"
        md += hasHardLeak ? "**Result: HARD LEAK — fix before any training, scoring or tuning on this split.**\n\n" : "**Result: no hard leak.**\n\n"
        md += "| Severity | Count |\n|---|---|\n"
        for s in [Severity.hard, .soft, .info] { md += "| \(s.rawValue) | \(findings.filter { $0.severity == s }.count) |\n" }
        for s in [Severity.hard, .soft, .info] {
            let rows = findings.filter { $0.severity == s }
            guard !rows.isEmpty else { continue }
            md += "\n## \(s.rawValue.capitalized)\n\n"
            for f in rows {
                md += "- **\(f.code)** — \(f.message)"
                if !f.videos.isEmpty, f.videos.count <= 12 { md += " `" + f.videos.joined(separator: "`, `") + "`" }
                else if !f.videos.isEmpty { md += " (\(f.videos.count) videos, see audit.json)" }
                md += "\n"
            }
        }
        return md
    }

    func write(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: file, options: .atomic)
    }
}
