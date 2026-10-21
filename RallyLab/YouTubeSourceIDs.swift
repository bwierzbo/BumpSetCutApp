//
//  YouTubeSourceIDs.swift
//  RallyLab
//
//  Decision D-015 §5: a YouTube video ID may be confirmed as a video's
//  `sourceId` when it is independently verifiable — the ID parsed from the
//  origin link the owner pasted equals the stored fingerprint, the link is a
//  YouTube host, and nothing contradicts it. Everything else stays
//  unconfirmed and is listed with the reason. The procedure is deterministic
//  (same project → same proposals), previewed before it is applied, and
//  reversible (`--set-provenance <video> --source-id ""`, and the report
//  records every prior value).
//

import Foundation

enum YouTubeSourceIDs {
    struct Proposal: Equatable {
        let video: String
        let origin: String
        let sourceId: String        // "youtube:<id>"
        let previous: String?       // what sourceId was before (nil = unknown)
    }

    struct Ambiguous: Equatable {
        let video: String
        let reason: String
    }

    struct Plan: Equatable {
        var proposals: [Proposal]
        var ambiguous: [Ambiguous]
        var alreadyConfirmed: [String]
    }

    static let hosts: Set<String> = ["youtube.com", "m.youtube.com", "youtu.be"]

    /// What `--confirm-youtube-source-ids` would set, over the project's
    /// videos by session name.
    static func plan(sources: [String: ClipSource]) -> Plan {
        var plan = Plan(proposals: [], ambiguous: [], alreadyConfirmed: [])
        for (video, s) in sources.sorted(by: { $0.key < $1.key }) {
            guard s.kind == .link else { continue }   // local files never get a YouTube source ID
            let origin = s.origin.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let host = URLComponents(string: origin)?.host?.lowercased().replacingOccurrences(of: "www.", with: ""),
                  hosts.contains(host) else {
                plan.ambiguous.append(Ambiguous(video: video, reason: "origin is not a YouTube link: \(origin)"))
                continue
            }
            guard let parsed = ProjectsModel.linkFingerprint(origin), parsed.hasPrefix("youtube:") else {
                plan.ambiguous.append(Ambiguous(video: video, reason: "no video ID could be parsed from \(origin)"))
                continue
            }
            if let stored = s.fingerprint, stored != parsed {
                plan.ambiguous.append(Ambiguous(video: video, reason: "stored fingerprint \(stored) differs from the link's \(parsed)"))
                continue
            }
            if let current = s.sourceId, !current.isEmpty {
                if current == parsed { plan.alreadyConfirmed.append(video) }
                else { plan.ambiguous.append(Ambiguous(video: video, reason: "sourceId is already confirmed as \(current), not \(parsed); left as is")) }
                continue
            }
            plan.proposals.append(Proposal(video: video, origin: origin, sourceId: parsed, previous: s.sourceId))
        }
        return plan
    }

    static func markdown(_ plan: Plan, applied: Bool) -> String {
        var md = "# YouTube source IDs — \(applied ? "applied" : "preview")\n\n"
        md += "Rule: `sourceId = youtube:<id>` only when the ID parsed from the origin link equals the stored fingerprint and the link is a YouTube host. "
        md += "What this confirms is the identity of the YouTube video that was fetched; whether that video is itself the original upload cannot be verified offline and is not claimed. "
        md += "Reversible with `RallyLab --project <name> --set-provenance <video> --source-id \"\"`.\n\n"
        md += "| Count | |\n|---|---|\n| proposed | \(plan.proposals.count) |\n| already confirmed | \(plan.alreadyConfirmed.count) |\n| ambiguous (left unconfirmed) | \(plan.ambiguous.count) |\n\n"
        if !plan.proposals.isEmpty {
            md += "## \(applied ? "Applied" : "Proposed")\n\n| Video | sourceId | was | origin |\n|---|---|---|---|\n"
            for p in plan.proposals { md += "| \(p.video) | \(p.sourceId) | \(p.previous ?? "unknown") | \(p.origin) |\n" }
        }
        if !plan.ambiguous.isEmpty {
            md += "\n## Ambiguous — unchanged\n\n| Video | Reason |\n|---|---|\n"
            for a in plan.ambiguous { md += "| \(a.video) | \(a.reason) |\n" }
        }
        return md
    }
}
