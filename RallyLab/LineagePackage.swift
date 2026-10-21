//
//  LineagePackage.swift
//  RallyLab
//
//  The training package for a model lineage (D-017, D-018): a multi-frame
//  package whose clips are chosen from the versioned split manifest, not
//  from the dataset folder, and which carries its own manifest and file
//  hashes. Physically isolated: a recording that is reserved (final test,
//  provisional candidate, lineage holdout, legacy holdout) or shares a
//  confirmed identity with one is absent from the package — no frame, no
//  window, no folder — and a preflight audit of the written package proves
//  it before the zip exists. Any failed check removes the package. The
//  record's digest and file list cover everything but l2-manifest.json
//  itself (a record cannot hold its own hash): verify a package by hashing
//  it with that one file left out.
//
//  The project's own data.yaml (images/train, images/val) is NOT a lineage
//  dataset: it knows nothing of reservations. A lineage trains only from a
//  package written here with a passing preflight.
//
//    RallyLab --project Scratch --package-l2 [--dry-run] [--long-side 512]
//
//    <project>/manifests/l2/<stamp>-plan.{json,md}      the plan (always)
//    <project>/exports/<project>-L2-multiframe-<stamp>/  the package, with l2-manifest.json
//    <project>/manifests/l2/<package>.json              copy of l2-manifest.json
//

import CryptoKit
import Foundation

enum LineagePackage {

    static let lineage = "L2"

    /// A recording the manifest says the package must not contain.
    struct Withheld: Codable, Equatable {
        var video: String
        var split: DatasetSplit
        /// "listed" / "alias" from the manifest; nil for legacy_holdout.
        var reservedAs: String?
        var aliasGroup: String?
        var identities: [String]
    }

    /// A recording the package may contain, and which side it goes to.
    struct Eligible: Codable, Equatable {
        var video: String
        var split: DatasetSplit
        /// "train" or "val" in windows.jsonl.
        var packageSplit: String
        var aliasGroup: String?
        var identities: [String]
        var reviewedFrames: Int
        var ralliesMarked: Bool
    }

    struct AuditSummary: Codable, Equatable {
        var hard: Int
        var soft: Int
        var info: Int
    }

    /// What goes in and what stays out, decided from the manifest alone.
    struct Plan: Codable {
        var lineage: String
        var project: String
        var createdAt: Date
        var generator: String
        var manifestHashes: DatasetSplitManifest.Hashes
        var audit: AuditSummary
        var withheld: [Withheld]
        var eligible: [Eligible]

        var withheldNames: Set<String> { Set(withheld.map(\.video)) }
        var eligibleNames: Set<String> { Set(eligible.map(\.video)) }
        var trainCount: Int { eligible.filter { $0.packageSplit == "train" }.count }
        var valCount: Int { eligible.filter { $0.packageSplit == "val" }.count }
    }

    enum PlanError: LocalizedError, Equatable {
        case hardLeak(Int)
        case reservedButEligible([String])
        case sharedIdentity(eligible: String, withheld: String, identity: String)
        case noTrain, noVal

        var errorDescription: String? {
            switch self {
            case .hardLeak(let n): return "The audit has \(n) hard finding(s); no lineage package while the dataset leaks."
            case .reservedButEligible(let v): return "Withheld by validation.json (reserved names and legacy holdout, expanded through the project's identities) but the manifest would package: \(v.joined(separator: ", ")). The two disagree; nothing is written."
            case .sharedIdentity(let e, let w, let id): return "\(e) would be packaged but shares \(id) with withheld \(w)."
            case .noTrain: return "No eligible train recording."
            case .noVal: return "No eligible val recording (dev_val or tune)."
            }
        }
    }

    /// Identity keys as ReservedVideos.closure sees them, from the manifest row.
    static func identities(of v: ManifestVideo) -> [String] {
        var ids: [String] = []
        if let f = v.fingerprint { ids.append("fp:" + f) }
        if let s = v.sourceId.value, !s.isEmpty { ids.append("src:" + s) }
        if let s = v.sessionId.value, !s.isEmpty { ids.append("ses:" + s) }
        if let s = v.venueId.value, !s.isEmpty { ids.append("ven:" + s) }
        return ids.sorted()
    }

    /// `withheldClosure`: every name validation.json withholds — reserved names
    /// and the legacy holdout — expanded over the whole project's identities
    /// (ReservedVideos.lineageWithheldNames), read independently of the
    /// manifest, which has rows only for recordings with a dataset session.
    /// The plan fails when the two disagree on any recording.
    static func plan(manifest: DatasetSplitManifest, audit: DatasetAudit, withheldClosure: Set<String>,
                     generator: String, now: Date = Date()) throws -> Plan {
        let hard = audit.findings.filter { $0.severity == .hard }.count
        guard hard == 0 else { throw PlanError.hardLeak(hard) }

        var withheld: [Withheld] = []
        var eligible: [Eligible] = []
        for v in manifest.videos.sorted(by: { $0.video < $1.video }) {
            if v.split.isReserved {
                withheld.append(Withheld(video: v.video, split: v.split, reservedAs: v.reservedAs, aliasGroup: v.aliasGroup,
                                         identities: identities(of: v)))
            } else {
                let packageSplit = v.split == .train ? "train" : "val"
                eligible.append(Eligible(video: v.video, split: v.split, packageSplit: packageSplit, aliasGroup: v.aliasGroup,
                                         identities: identities(of: v), reviewedFrames: v.reviewedFrames, ralliesMarked: v.ralliesMarked))
            }
        }
        let withheldNames = Set(withheld.map(\.video))
        let eligibleNames = Set(eligible.map(\.video))
        let wrongly = withheldClosure.intersection(eligibleNames)
        guard wrongly.isEmpty else { throw PlanError.reservedButEligible(wrongly.sorted()) }

        // Exclusion closure, recomputed from the manifest rows: no identity and no alias group
        // may be shared between a packaged recording and a withheld one.
        var identityOwner: [String: String] = [:]
        var groupOwner: [String: String] = [:]
        for w in withheld {
            for id in w.identities { identityOwner[id] = w.video }
            if let g = w.aliasGroup { groupOwner[g] = w.video }
        }
        for e in eligible {
            for id in e.identities {
                if let w = identityOwner[id] { throw PlanError.sharedIdentity(eligible: e.video, withheld: w, identity: id) }
            }
            if let g = e.aliasGroup, let w = groupOwner[g] {
                throw PlanError.sharedIdentity(eligible: e.video, withheld: w, identity: "aliasGroup:" + g)
            }
        }
        guard eligible.contains(where: { $0.packageSplit == "train" }) else { throw PlanError.noTrain }
        guard eligible.contains(where: { $0.packageSplit == "val" }) else { throw PlanError.noVal }

        let counts = Dictionary(grouping: audit.findings, by: \.severity).mapValues(\.count)
        return Plan(lineage: lineage, project: manifest.project, createdAt: now, generator: generator,
                    manifestHashes: manifest.hashes,
                    audit: AuditSummary(hard: counts[.hard] ?? 0, soft: counts[.soft] ?? 0, info: counts[.info] ?? 0),
                    withheld: withheld, eligible: eligible)
    }

    // MARK: - Preflight of a written package

    struct FileHash: Codable, Equatable {
        var path: String
        var sha256: String
        var bytes: Int
    }

    struct ClipRow: Codable, Equatable {
        var clip: String
        var packageSplit: String
        var windows: Int
        var frames: Int
    }

    struct Check: Codable, Equatable {
        var name: String
        var passed: Bool
        var detail: String
    }

    struct Preflight: Codable {
        var createdAt: Date
        var package: String
        var passed: Bool
        var checks: [Check]
        var clips: [ClipRow]
        /// Every regular file in the package except `l2-manifest.json` (the record cannot hold its
        /// own hash), in canonical order, with its SHA-256.
        var files: [FileHash]
        /// The canonical directory digest of `files` (same formula as the manifest's `sessions`
        /// digest, over the package with `l2-manifest.json` removed). Stable whether or not the
        /// record has been written: verify with the same exclusion.
        var digest: String
        var windowsSha256: String?
    }

    enum PreflightError: LocalizedError, Equatable {
        case noWindows(String)
        case malformedWindow(Int)
        case failed([String])
        case unreadable(String)
        case protectedFrameUnreadable(String)

        var errorDescription: String? {
            switch self {
            case .noWindows(let p): return "No windows.jsonl in \(p)."
            case .malformedWindow(let line): return "windows.jsonl line \(line) has no clip, split and frames."
            case .failed(let names): return "Preflight failed: \(names.joined(separator: ", ")). The package was removed."
            case .unreadable(let p): return "Couldn't hash \(p)."
            case .protectedFrameUnreadable(let p): return "A withheld recording's frame can't be read: \(p). Without every protected frame's hash the content check would be incomplete, so nothing is packaged."
            }
        }
    }

    static let recordFile = "l2-manifest.json"
    private static let topLevelFiles: Set<String> = ["windows.jsonl", "README.txt", "summary.json", recordFile]

    /// Checks the package folder against the plan and hashes every file.
    /// `protectedHashes`: SHA-256 of every frame image the dataset holds for a
    /// withheld recording (kept or parked), so a protected frame is caught by
    /// content even under another name.
    static func preflight(packageDir: URL, plan: Plan, protectedHashes: Set<String>, now: Date = Date()) throws -> Preflight {
        let fm = FileManager.default
        let windowsURL = packageDir.appendingPathComponent("windows.jsonl")
        guard let text = try? String(contentsOf: windowsURL, encoding: .utf8) else { throw PreflightError.noWindows(packageDir.path) }

        let eligibleSplit = Dictionary(uniqueKeysWithValues: plan.eligible.map { ($0.video, $0.packageSplit) })
        let eligibleBySafe = Dictionary(plan.eligible.map { (DatasetStore.safeName($0.video), $0.video) }, uniquingKeysWith: { a, _ in a })
        let withheldSafe = Set(plan.withheld.map { DatasetStore.safeName($0.video) })
        let withheldNames = plan.withheldNames

        var windowsByClip: [String: (split: Set<String>, windows: Int, frames: Set<String>)] = [:]
        var referenced = Set<String>()
        var badClips = Set<String>(), withheldClips = Set<String>(), badPaths = Set<String>(), pseudoClips = Set<String>()
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lineNumber += 1
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let clip = obj["clip"] as? String, let split = obj["split"] as? String, let frames = obj["frames"] as? [String]
            else { throw PreflightError.malformedWindow(lineNumber) }
            var entry = windowsByClip[clip] ?? (split: [], windows: 0, frames: [])
            entry.split.insert(split)
            entry.windows += 1
            entry.frames.formUnion(frames)
            windowsByClip[clip] = entry
            referenced.formUnion(frames)
            if withheldNames.contains(clip) || withheldSafe.contains(DatasetStore.safeName(clip)) { withheldClips.insert(clip) }
            if eligibleSplit[clip] != split { badClips.insert(clip) }
            if (obj["pseudo"] as? [Bool])?.contains(true) == true { pseudoClips.insert(clip) }
            for path in frames {
                let parts = path.split(separator: "/").map(String.init)
                guard parts.count == 3, parts[0] == "frames", eligibleBySafe[parts[1]] == clip, !withheldSafe.contains(parts[1])
                else { badPaths.insert(path); continue }
            }
        }

        var checks: [Check] = []
        func check(_ name: String, _ failures: [String], ok: String) {
            checks.append(Check(name: name, passed: failures.isEmpty,
                                detail: failures.isEmpty ? ok : failures.sorted().prefix(20).joined(separator: ", ") + (failures.count > 20 ? " … (\(failures.count))" : "")))
        }
        check("windows-clips-eligible", Array(badClips), ok: "every window's clip is eligible with the planned split")
        check("windows-clips-not-withheld", Array(withheldClips), ok: "no window from a withheld recording")
        check("frame-paths-eligible", Array(badPaths), ok: "every frame path is frames/<its own eligible clip>/<frame>.jpg")
        // A label written by a model (a pre-tracked rally's "sure" frame) is L1 output; a lineage trains on people's labels only.
        var machine: [String] = Array(pseudoClips)
        if let summary = try? JSONSerialization.jsonObject(with: Data(contentsOf: packageDir.appendingPathComponent("summary.json"))) as? [String: Any],
           let frames = summary["machineFrames"] as? Int, frames > 0 { machine.append("summary.json machineFrames \(frames)") }
        check("no-machine-labels", machine, ok: "no window carries a model-written label (pseudo) and summary.json counts 0 machine frames")

        // Files on disk: hashed, and nothing that isn't the package's own.
        guard let hashed = DatasetSplitManifest.canonicalFileHashes(ofDirectory: packageDir) else { throw PreflightError.unreadable(packageDir.path) }
        var files: [FileHash] = []
        var stray: [String] = [], protected: [String] = [], missing: [String] = []
        var present = Set<String>()
        for (path, sha, bytes) in hashed {
            present.insert(path)
            let parts = path.split(separator: "/").map(String.init)
            let own = topLevelFiles.contains(path) && parts.count == 1
            if path == recordFile && parts.count == 1 { continue }   // allowed, never hashed into its own record
            files.append(FileHash(path: path, sha256: sha, bytes: bytes))
            let frame = parts.count == 3 && parts[0] == "frames" && eligibleBySafe[parts[1]].map { windowsByClip[$0] != nil } == true
                && !withheldSafe.contains(parts[1])
            if !(own || frame) { stray.append(path) }
            if protectedHashes.contains(sha) { protected.append(path) }
        }
        for path in referenced where !present.contains(path) { missing.append(path) }
        var clipDirs: [String] = []
        if let dirs = try? fm.contentsOfDirectory(at: packageDir.appendingPathComponent("frames"), includingPropertiesForKeys: nil) {
            for d in dirs where eligibleBySafe[d.lastPathComponent].map({ windowsByClip[$0] != nil }) != true { clipDirs.append("frames/" + d.lastPathComponent) }
        }
        check("frame-files-exist", missing, ok: "every referenced frame is in the package")
        check("no-stray-files", stray, ok: "only windows.jsonl, README.txt, summary.json, \(recordFile) and the eligible clips' frames")
        check("frame-dirs-have-windows", clipDirs, ok: "every frames/ folder belongs to a packaged clip")
        check("no-protected-content", protected, ok: "no file matches a withheld recording's frame by content (\(protectedHashes.count) hashes)")
        let splits = Set(windowsByClip.values.flatMap(\.split))
        check("both-splits-present", splits.isSuperset(of: ["train", "val"]) ? [] : ["have: " + splits.sorted().joined(separator: ",")],
              ok: "train and val windows present")

        let digest = DatasetSplitManifest.canonicalDigest(lines: files.map { ($0.path, $0.sha256) })
        let clips = windowsByClip.keys.sorted().map { clip in
            ClipRow(clip: clip, packageSplit: windowsByClip[clip]!.split.sorted().joined(separator: "+"),
                    windows: windowsByClip[clip]!.windows, frames: windowsByClip[clip]!.frames.count)
        }
        return Preflight(createdAt: now, package: packageDir.lastPathComponent, passed: checks.allSatisfy(\.passed),
                         checks: checks, clips: clips, files: files, digest: digest,
                         windowsSha256: files.first { $0.path == "windows.jsonl" }?.sha256)
    }

    /// SHA-256 of every frame image the dataset holds for the withheld recordings, kept or parked.
    /// Throws when any of them can't be read: an incomplete reference set would let the content
    /// check pass without proving anything.
    static func protectedFrameHashes(sessions: [VideoSession], withheld: Set<String>, store: DatasetStore) throws -> Set<String> {
        var hashes = Set<String>()
        for session in sessions where withheld.contains(session.name) {
            for frame in session.frames {
                let url = store.currentImageURL(for: frame)
                guard let h = DatasetSplitManifest.sha256(of: url) else { throw PreflightError.protectedFrameUnreadable(url.path) }
                hashes.insert(h)
            }
        }
        return hashes
    }

    // MARK: - Records

    struct Record: Codable {
        var plan: Plan
        var preflight: Preflight
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    static func write(_ plan: Plan, to url: URL) throws { try encoder.encode(plan).write(to: url) }
    static func write(_ record: Record, to url: URL) throws { try encoder.encode(record).write(to: url) }

    static func read(from url: URL) throws -> Record {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(Record.self, from: Data(contentsOf: url))
    }

    static func markdown(_ plan: Plan) -> String {
        let f = ISO8601DateFormatter()
        var md = """
        # \(plan.lineage) package plan — \(plan.project)

        Written \(f.string(from: plan.createdAt)) by \(plan.generator). Manifest hashes: project.json `\(plan.manifestHashes.projectJson.map { String($0.prefix(16)) } ?? "?")` · sessions `\(plan.manifestHashes.sessions.map { String($0.prefix(16)) } ?? "?")` · validation.json `\(plan.manifestHashes.validationJson.map { String($0.prefix(16)) } ?? "?")`. Audit: \(plan.audit.hard) hard · \(plan.audit.soft) soft · \(plan.audit.info) info.

        **Eligible:** \(plan.trainCount) train · \(plan.valCount) val recordings. **Withheld:** \(plan.withheld.count).

        ## Withheld (never in the package)

        | Recording | Split | Reserved as | Alias group |
        |---|---|---|---|

        """
        for w in plan.withheld { md += "| \(w.video) | \(w.split.rawValue) | \(w.reservedAs ?? "—") | \(w.aliasGroup ?? "—") |\n" }
        md += "\n## Eligible\n\n| Recording | Manifest split | Package split | Reviewed frames | Rallies marked |\n|---|---|---|---|---|\n"
        for e in plan.eligible { md += "| \(e.video) | \(e.split.rawValue) | \(e.packageSplit) | \(e.reviewedFrames) | \(e.ralliesMarked ? "yes" : "no") |\n" }
        return md
    }

    static func markdown(_ preflight: Preflight) -> String {
        var md = "## Preflight — \(preflight.package): \(preflight.passed ? "PASSED" : "FAILED")\n\n| Check | Result | Detail |\n|---|---|---|\n"
        for c in preflight.checks { md += "| \(c.name) | \(c.passed ? "pass" : "FAIL") | \(c.detail) |\n" }
        md += "\nDigest `\(preflight.digest.prefix(16))` over \(preflight.files.count) files; windows.jsonl `\(preflight.windowsSha256?.prefix(16) ?? "?")`.\n\n| Clip | Split | Windows | Frames |\n|---|---|---|---|\n"
        for c in preflight.clips { md += "| \(c.clip) | \(c.packageSplit) | \(c.windows) | \(c.frames) |\n" }
        return md
    }
}
