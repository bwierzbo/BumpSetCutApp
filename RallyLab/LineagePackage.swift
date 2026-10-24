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
//  it before the zip exists. The video file behind every packaged session
//  is fingerprinted and compared with every identity a withheld recording's
//  video can have (project fingerprint, cut file, session file), so a copy
//  of protected footage under another session is refused by content, not
//  by name. Any failed check removes the package. The
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
        /// Every name validation.json withholds, expanded over the whole project — including
        /// project videos that have no dataset session and so no `withheld` row. Their file
        /// identities are still checked against every packaged source.
        var withheldClosure: [String]
        var eligible: [Eligible]

        var withheldNames: Set<String> { Set(withheld.map(\.video)) }
        /// Names whose source identities the preflight must know: the rows plus the closure.
        var protectedNames: Set<String> { withheldNames.union(withheldClosure) }
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
                    withheld: withheld, withheldClosure: withheldClosure.sorted(), eligible: eligible)
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
        /// Planned frames the exporter left out as undecodable (HEVC leading pictures; D-024) and
        /// the windows that went with them, from summary.json; absent in records from before.
        var undecodableFrames: Int? = nil
        var windowsLeftOut: Int? = nil
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
        /// Fingerprint (ProjectsModel.fileFingerprint) of the video each packaged clip was exported from.
        var sourceFingerprints: [String: String]
        /// Every fingerprint a withheld recording's video can carry; no packaged source may match one.
        var protectedSourceFingerprints: [String]
        /// How many dataset image files of withheld recordings were hashed for `no-protected-content`.
        var protectedFrameFiles: Int?
        /// Withheld frame records whose file exists nowhere in the dataset (nothing to hash; noted).
        var danglingProtectedRecords: [String]?
    }

    enum SourceError: LocalizedError, Equatable {
        case protectedSourceUnknown(String)
        case sourceUnreadable(clip: String, path: String)
        case sourcesMissing([String])

        var errorDescription: String? {
            switch self {
            case .protectedSourceUnknown(let name): return "Withheld recording \(name) has no content fingerprint: neither its cut file nor its session video is on this Mac (a link identity such as youtube:… cannot match an exported file). Bring its video back before packaging; nothing is packaged."
            case .sourceUnreadable(let clip, let path): return "\(clip)'s video can't be fingerprinted: \(path). Nothing is packaged."
            case .sourcesMissing(let names): return "\(names.count) eligible recording(s) with labels have no video here, and a lineage package never skips one: \(names.prefix(12).joined(separator: ", "))\(names.count > 12 ? " …" : ""). Bring every video back (or mount the footage) before packaging; nothing is packaged."
            }
        }
    }

    /// Every identity under which a withheld recording's video can appear on disk: the
    /// project's stored or derived fingerprint, the cut file's fingerprint and the session
    /// video's fingerprint when those files are here. Exported videos carry `file:` content
    /// fingerprints, so every withheld recording must yield at least one `file:` fingerprint
    /// — a link identity alone (`youtube:…`) can match nothing. Otherwise it throws: the
    /// recording's copies could not be recognised and the check would prove nothing.
    static func protectedSourceFingerprints(sessions: [VideoSession], withheld: Set<String>, sources: [String: ClipSource]) throws -> Set<String> {
        let fm = FileManager.default
        let byName = Dictionary(sessions.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var out = Set<String>()
        for name in withheld.sorted() {
            var mine = Set<String>()
            if let s = sources[name] {
                if let f = ReservedVideos.effectiveFingerprint(s) { mine.insert(f) }
                if fm.fileExists(atPath: s.clipFile), let f = ProjectsModel.fileFingerprint(atPath: s.clipFile) { mine.insert(f) }
            }
            if let session = byName[name], fm.fileExists(atPath: session.sourcePath),
               let f = ProjectsModel.fileFingerprint(atPath: session.sourcePath) { mine.insert(f) }
            guard mine.contains(where: { $0.hasPrefix("file:") }) else { throw SourceError.protectedSourceUnknown(name) }
            out.formUnion(mine)
        }
        return out
    }

    /// The fingerprint of the video each session is exported from, for the sessions whose
    /// video is here (the exporter skips the others). Throws when a present file can't be read.
    static func sourceFingerprints(of sessions: [VideoSession]) throws -> [String: String] {
        var out: [String: String] = [:]
        for s in sessions where FileManager.default.fileExists(atPath: s.sourcePath) {
            guard let f = ProjectsModel.fileFingerprint(atPath: s.sourcePath) else { throw SourceError.sourceUnreadable(clip: s.name, path: s.sourcePath) }
            out[s.name] = f
        }
        return out
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
    /// `sourceFingerprints` / `protectedSources`: the packaged clips' source
    /// videos (sourceFingerprints(of:)) and every identity a withheld
    /// recording's video can carry (protectedSourceFingerprints): a packaged
    /// clip whose video is a withheld recording's, under any name, fails.
    /// `protectedHashes`: SHA-256 of every frame image the dataset holds for a
    /// withheld recording (kept or parked) — a secondary check that catches a
    /// byte-identical copy of a dataset frame; the exporter re-extracts frames,
    /// so it cannot stand in for the source check.
    static func preflight(packageDir: URL, plan: Plan, sourceFingerprints: [String: String], protectedSources: Set<String>,
                          protectedHashes: Set<String>, protectedFrameFiles: Int = 0, danglingProtectedRecords: [String] = [],
                          now: Date = Date()) throws -> Preflight {
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
        let summary = try? JSONSerialization.jsonObject(with: Data(contentsOf: packageDir.appendingPathComponent("summary.json"))) as? [String: Any]
        if let frames = summary?["machineFrames"] as? Int, frames > 0 { machine.append("summary.json machineFrames \(frames)") }
        check("no-machine-labels", machine, ok: "no window carries a model-written label (pseudo) and summary.json counts 0 machine frames")
        // The exporter leaves out a clip whose video is absent with only a note in the summary; the
        // planned package has every one, so that note (or a summary that can't say) fails the package.
        var skipped: [String] = []
        if let missing = summary?["missingVideos"] as? [String], let frames = summary?["framesWithoutVideo"] as? Int {
            skipped = missing.isEmpty && frames == 0 ? [] : missing + (frames > 0 ? ["framesWithoutVideo \(frames)"] : [])
        } else {
            skipped = ["summary.json does not report missingVideos and framesWithoutVideo"]
        }
        check("no-missing-videos", skipped, ok: "summary.json: no clip was left out for a missing video")

        // Frames the exporter left out as undecodable (D-024) are on record in summary.json, each for the
        // one accepted reason. Read first: a clip every window of which was left out contributes no
        // window, and its folder of decodable frames is the package's own on this record alone — when
        // the clip is eligible and not withheld. Each recorded frame must be absent (checked below).
        var undecodableBad: [String] = []
        var undecodableByClip: [String: (frames: Set<String>, windows: Int, planned: Int)] = [:]
        var undecodableTotal: Int?
        if let listed = summary?["undecodable"] as? [[String: Any]], let total = summary?["undecodableFrames"] as? Int {
            undecodableTotal = total
            for entry in listed {
                guard let clip = entry["clip"] as? String, let frames = entry["frames"] as? [Any], let reason = entry["reason"] as? String,
                      let windows = entry["windowsLeftOut"] as? Int, let planned = entry["windowsPlanned"] as? Int
                else { undecodableBad.append("summary.json undecodable entry is malformed"); continue }
                let keys = frames.map { ((($0 as? NSNumber).map { "\($0.int64Value)" }) ?? "\($0)") }
                undecodableByClip[clip] = (Set(keys.map { "frames/\(DatasetStore.safeName(clip))/\($0).jpg" }), windows, planned)
                if !reason.hasPrefix("HEVC leading picture") { undecodableBad.append("\(clip): left out for another reason (\(reason.prefix(60)))") }
                if eligibleSplit[clip] == nil { undecodableBad.append("\(clip): recorded undecodable frames but not an eligible clip") }
                if withheldNames.contains(clip) || withheldSafe.contains(DatasetStore.safeName(clip)) { undecodableBad.append("\(clip): recorded undecodable frames but withheld") }
                if windows > planned || planned == 0 { undecodableBad.append("\(clip): \(windows) of \(planned) windows left out") }
            }
        } else {
            undecodableBad.append("summary.json does not report undecodableFrames and undecodable")
        }
        /// Eligible clips with every planned window left out (by safe name): their folders are allowed, their frames are not stray.
        let noWindowClips = Set(undecodableByClip.filter { $0.value.windows == $0.value.planned && $0.value.planned > 0 && eligibleSplit[$0.key] != nil }
                                    .keys.map(DatasetStore.safeName))
        for clip in noWindowClips where eligibleBySafe[clip].map({ windowsByClip[$0] != nil }) == true {
            undecodableBad.append("\(clip): recorded with every window left out, yet windows.jsonl holds its windows")
        }
        /// A frames/ folder is a packaged clip's: one with windows, or one on record with every window left out.
        func packaged(_ safeClip: String) -> Bool {
            !withheldSafe.contains(safeClip) && (eligibleBySafe[safeClip].map { windowsByClip[$0] != nil } == true || noWindowClips.contains(safeClip))
        }

        // Files on disk: hashed, and nothing that isn't the package's own.
        guard let hashed = DatasetSplitManifest.canonicalFileHashes(ofDirectory: packageDir) else { throw PreflightError.unreadable(packageDir.path) }
        var files: [FileHash] = []
        var stray: [String] = [], protected: [String] = [], missing: [String] = []
        var present = Set<String>()
        var framesInFolder: [String: Int] = [:]   // by safe clip name
        for (path, sha, bytes) in hashed {
            present.insert(path)
            let parts = path.split(separator: "/").map(String.init)
            let own = topLevelFiles.contains(path) && parts.count == 1
            if path == recordFile && parts.count == 1 { continue }   // allowed, never hashed into its own record
            files.append(FileHash(path: path, sha256: sha, bytes: bytes))
            let frame = parts.count == 3 && parts[0] == "frames" && packaged(parts[1])
            if frame { framesInFolder[parts[1], default: 0] += 1 }
            if !(own || frame) { stray.append(path) }
            if protectedHashes.contains(sha) { protected.append(path) }
        }
        for path in referenced where !present.contains(path) { missing.append(path) }
        var clipDirs: [String] = []
        if let dirs = try? fm.contentsOfDirectory(at: packageDir.appendingPathComponent("frames"), includingPropertiesForKeys: nil) {
            for d in dirs where !packaged(d.lastPathComponent) { clipDirs.append("frames/" + d.lastPathComponent) }
        }
        check("frame-files-exist", missing, ok: "every referenced frame is in the package")
        check("no-stray-files", stray, ok: "only windows.jsonl, README.txt, summary.json, \(recordFile) and the eligible clips' frames")
        check("frame-dirs-have-windows", clipDirs,
              ok: noWindowClips.isEmpty ? "every frames/ folder belongs to a packaged clip"
                : "every frames/ folder belongs to a packaged clip (\(noWindowClips.count) on record with every window left out: \(noWindowClips.sorted().joined(separator: ", ")))")
        check("no-protected-content", protected, ok: "no file matches a withheld recording's frame by content (\(protectedHashes.count) hashes)")
        // Every clip whose frames are in the package — with windows or without — is checked against the withheld identities.
        let packagedClips = Set(windowsByClip.keys).union(noWindowClips.compactMap { eligibleBySafe[$0] })
        var badSources: [String] = []
        for clip in packagedClips.sorted() {
            guard let fp = sourceFingerprints[clip] else { badSources.append("\(clip): no source fingerprint"); continue }
            if protectedSources.contains(fp) { badSources.append("\(clip): its video is a withheld recording's (\(fp.prefix(21))…)") }
        }
        check("sources-not-protected", badSources,
              ok: "every packaged clip's video is fingerprinted and matches none of the \(protectedSources.count) withheld identities")
        // The same footage on both sides of the package (two sessions, two project identities, one
        // file) would let val score what train saw. Grouped by the file actually exported; a clip
        // without windows counts on its planned side, its frames being in the package all the same.
        func sides(_ clip: String) -> Set<String> { windowsByClip[clip]?.split ?? eligibleSplit[clip].map { [$0] } ?? [] }
        var byFingerprint: [String: [String]] = [:]
        for clip in packagedClips { if let fp = sourceFingerprints[clip] { byFingerprint[fp, default: []].append(clip) } }
        var shared: [String] = []
        for (fp, clips) in byFingerprint {
            let splits = Set(clips.flatMap(sides))
            if splits.isSuperset(of: ["train", "val"]) { shared.append("\(clips.sorted().joined(separator: "+")) share one video (\(fp.prefix(21))…) across train and val") }
        }
        check("sources-disjoint-across-splits", shared, ok: "no video file is packaged on both the train and the val side")
        let splits = Set(windowsByClip.values.flatMap(\.split))
        check("both-splits-present", splits.isSuperset(of: ["train", "val"]) ? [] : ["have: " + splits.sorted().joined(separator: ",")],
              ok: "train and val windows present")
        // …and each recorded frame is absent: no file for it, no window that names it; the counts agree.
        for (clip, entry) in undecodableByClip.sorted(by: { $0.key < $1.key }) {
            for path in entry.frames.sorted() {
                if present.contains(path) { undecodableBad.append("\(path) is recorded undecodable but exists") }
                if referenced.contains(path) { undecodableBad.append("\(path) is recorded undecodable but a window names it") }
            }
            _ = clip
        }
        if let total = undecodableTotal, total != undecodableByClip.values.reduce(0, { $0 + $1.frames.count }) {
            undecodableBad.append("summary.json undecodableFrames \(total) but \(undecodableByClip.values.reduce(0) { $0 + $1.frames.count }) frames listed")
        }
        check("undecodable-frames-recorded", undecodableBad,
              ok: undecodableByClip.isEmpty ? "no frame was left out as undecodable"
                : "\(undecodableByClip.values.reduce(0) { $0 + $1.frames.count }) frame(s) in \(undecodableByClip.count) clip(s) left out as HEVC leading pictures, "
                  + "each absent from the folder and from every window"
                  + (noWindowClips.isEmpty ? "" : "; \(noWindowClips.count) clip(s) contribute no window") + " (D-024)")

        let digest = DatasetSplitManifest.canonicalDigest(lines: files.map { ($0.path, $0.sha256) })
        let clips = packagedClips.sorted().map { clip in
            ClipRow(clip: clip, packageSplit: sides(clip).sorted().joined(separator: "+"),
                    windows: windowsByClip[clip]?.windows ?? 0,
                    frames: windowsByClip[clip]?.frames.count ?? framesInFolder[DatasetStore.safeName(clip)] ?? 0,
                    undecodableFrames: undecodableByClip[clip]?.frames.count, windowsLeftOut: undecodableByClip[clip]?.windows)
        }
        return Preflight(createdAt: now, package: packageDir.lastPathComponent, passed: checks.allSatisfy(\.passed),
                         checks: checks, clips: clips, files: files, digest: digest,
                         windowsSha256: files.first { $0.path == "windows.jsonl" }?.sha256,
                         sourceFingerprints: sourceFingerprints.filter { packagedClips.contains($0.key) },
                         protectedSourceFingerprints: protectedSources.sorted(),
                         protectedFrameFiles: protectedFrameFiles, danglingProtectedRecords: danglingProtectedRecords)
    }

    /// The rallies a lineage package takes labels from: a person's finished rally, or a
    /// pre-tracked one a person confirmed as a rally — and only when someone checked at
    /// least one of its frames. A pre-tracked rally nobody has looked at (`isRally == nil`,
    /// which the general exporter still packages) is left out whole: its only labels would
    /// be the model's own sure frames, which a lineage never trains on. Its recording keeps
    /// the rally in the dataset untouched; it simply contributes nothing here. (Audit of
    /// 2026-10-23: 43 recordings pre-tracked on 2026-10-17 and never reviewed would have put
    /// 284 such rallies — 61,006 unchecked model points — into the L2 package.)
    static func isHumanLabeled(_ rally: TrackedRally) -> Bool {
        (rally.done || (rally.isMachine && rally.isRally == true)) && rally.points.contains(where: \.isChecked)
    }

    static func humanLabeled(_ tracks: [TrackedRally]) -> [TrackedRally] { tracks.filter(isHumanLabeled) }

    /// What the rule leaves out, per recording: for the log and the record.
    struct LeftOut: Equatable {
        var video: String
        var rallies: Int
        var points: Int
    }

    static func leftOut(_ sessions: [VideoSession], plan: Plan) -> [LeftOut] {
        sessions.filter { plan.eligibleNames.contains($0.name) }.compactMap { s in
            let dropped = (s.tracks ?? []).filter { !isHumanLabeled($0) }
            return dropped.isEmpty ? nil : LeftOut(video: s.name, rallies: dropped.count, points: dropped.reduce(0) { $0 + $1.points.count })
        }.sorted { $0.video < $1.video }
    }

    /// The sessions the exporter is given: the eligible ones, each with the split the plan
    /// assigned (the manifest can place a `tune` recording on the val side while its dataset
    /// session still says "train"; the exporter reads `session.split`, so the copy carries the
    /// planned side) and only its human-labeled rallies (`isHumanLabeled`). Everything else
    /// about the session is unchanged; the dataset is not written.
    /// Throws when an eligible session the exporter would take labels from has no video on
    /// disk: the exporter skips such a session with only a note in the summary, and a lineage
    /// package quietly missing recordings is not the package that was planned.
    static func exportSessions(_ sessions: [VideoSession], plan: Plan) throws -> [VideoSession] {
        let planned = Dictionary(uniqueKeysWithValues: plan.eligible.map { ($0.video, $0.packageSplit) })
        let out = sessions.compactMap { s -> VideoSession? in
            guard let split = planned[s.name] else { return nil }
            return VideoSession(name: s.name, sourcePath: s.sourcePath, split: split, addedAt: s.addedAt, frames: s.frames,
                                rejected: s.rejected, tracks: s.tracks.map(Self.humanLabeled), ralliesMarked: s.ralliesMarked,
                                syncedTrackIds: s.syncedTrackIds, notRallies: s.notRallies, fittedTracks: s.fittedTracks, netBox: s.netBox)
        }
        let missing = out.filter { MultiFramePackage.contributes($0) && !FileManager.default.fileExists(atPath: $0.sourcePath) }
        guard missing.isEmpty else { throw SourceError.sourcesMissing(missing.map(\.name).sorted()) }
        return out
    }

    /// What the dataset holds for the withheld recordings.
    struct ProtectedFrames: Equatable {
        /// SHA-256 of every image file that is a withheld recording's.
        var hashes: Set<String>
        /// How many files those are.
        var files: Int
        /// Frame records whose file exists neither kept nor parked (dataset path): there are no
        /// bytes to protect, so they are reported, not fatal. A file that exists but can't be read
        /// is fatal — that is content whose hash would be missing.
        var danglingRecords: [String]
    }

    /// Every image file the dataset holds for the withheld recordings: the files their frame
    /// records name (kept or parked), plus any file in the image folders that carries a withheld
    /// recording's name without a record (a record can be regenerated while the old file stays).
    /// Throws when a file that exists can't be read: an incomplete reference set would let the
    /// content check pass without proving anything.
    /// Whether a path exists, told apart from a path that can't be reached: `stat` says ENOENT /
    /// ENOTDIR for a file that is genuinely absent; any other failure (a parent folder without
    /// permission, an I/O error) is content whose hash would be missing, so it is fatal.
    private static func exists(_ url: URL) throws -> Bool {
        var st = stat()
        if stat(url.path, &st) == 0 { return true }
        if errno == ENOENT || errno == ENOTDIR { return false }
        throw PreflightError.protectedFrameUnreadable("\(url.path) (\(String(cString: strerror(errno))))")
    }

    static func protectedFrames(sessions: [VideoSession], withheld: Set<String>, store: DatasetStore) throws -> ProtectedFrames {
        let fm = FileManager.default
        var hashed: [String: String] = [:]   // path → sha256
        var dangling: [String] = []
        func hash(_ url: URL) throws {
            // One entry per file whichever way it was reached (record path or folder walk, /var vs /private/var).
            let key = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard hashed[key] == nil else { return }
            guard let h = DatasetSplitManifest.sha256(of: url) else { throw PreflightError.protectedFrameUnreadable(url.path) }
            hashed[key] = h
        }
        for session in sessions where withheld.contains(session.name) {
            for frame in session.frames {
                // Kept or parked, checked here rather than through the store's fallback, which treats
                // an unreachable kept path like an absent one.
                let kept = store.root.appendingPathComponent(frame.file)
                let parked = store.root.appendingPathComponent("excluded").appendingPathComponent(frame.file)
                if try exists(kept) { try hash(kept) } else if try exists(parked) { try hash(parked) } else { dangling.append(frame.file) }
            }
        }
        // Files named for a withheld recording, in the two shapes the store writes
        // (DatasetStore.imageRelativePath): a sampled frame `<name>_<SSSS>_<mmm>.jpg` (the time,
        // %08.3f with the point as an underscore) and a copied file `<name>__<base>.<ext>`. Exact
        // shapes, so a sibling recording — `name_v2`, or the store's own `name_2` — is never swept in.
        let safeNames = Set(withheld.map(DatasetStore.safeName))
        func belongsToWithheld(_ fileName: String) -> Bool {
            guard let dot = fileName.lastIndex(of: ".") else { return false }
            let stem = fileName[..<dot]
            return safeNames.contains { safe in
                guard stem.hasPrefix(safe + "_") else { return false }
                let rest = stem.dropFirst(safe.count + 1)
                if rest.hasPrefix("_") { return rest.count > 1 }   // name__base
                let parts = rest.split(separator: "_", omittingEmptySubsequences: false)
                return parts.count == 2 && parts[0].count >= 4 && parts[1].count == 3
                    && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
            }
        }
        for folder in ["images", "excluded/images"] {
            let dir = store.root.appendingPathComponent(folder, isDirectory: true)
            guard try exists(dir) else { continue }
            // A folder that can't be listed hides files that may be a withheld recording's: fatal, never skipped.
            var walkError: (URL, Error)?
            guard let files = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [],
                                            errorHandler: { url, error in walkError = (url, error); return false })
            else { throw PreflightError.protectedFrameUnreadable("\(dir.path) (can't be listed)") }
            for case let url as URL in files {
                let regular: Bool
                do { regular = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile ?? false } catch {
                    throw PreflightError.protectedFrameUnreadable("\(url.path) (\(error.localizedDescription))")
                }
                if regular, belongsToWithheld(url.lastPathComponent) { try hash(url) }
            }
            if let (url, error) = walkError { throw PreflightError.protectedFrameUnreadable("\(url.path) (\(error.localizedDescription))") }
        }
        return ProtectedFrames(hashes: Set(hashed.values), files: hashed.count, danglingRecords: dangling.sorted())
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

    /// Written whole or not at all (temporary file, then rename): a write that fails — a full
    /// staging volume, a dropped mount — never leaves a partial record at the final name, which
    /// a later resume would have to refuse as a record.
    static func write(_ plan: Plan, to url: URL) throws { try encoder.encode(plan).write(to: url, options: .atomic) }
    static func write(_ record: Record, to url: URL) throws { try encoder.encode(record).write(to: url, options: .atomic) }

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
        md += "\nDigest `\(preflight.digest.prefix(16))` over \(preflight.files.count) files; windows.jsonl `\(preflight.windowsSha256?.prefix(16) ?? "?")`.\n"
        if let n = preflight.protectedFrameFiles {
            md += "Protected content: \(n) dataset image files of withheld recordings hashed"
            if let dangling = preflight.danglingProtectedRecords, !dangling.isEmpty {
                md += "; \(dangling.count) withheld frame record(s) have no file anywhere in the dataset (nothing to hash): "
                    + dangling.prefix(5).joined(separator: ", ") + (dangling.count > 5 ? " …" : "")
            }
            md += ".\n"
        }
        md += "\n| Clip | Split | Windows | Frames | Undecodable frames left out | Windows left out |\n|---|---|---|---|---|---|\n"
        for c in preflight.clips { md += "| \(c.clip) | \(c.packageSplit) | \(c.windows) | \(c.frames) | \(c.undecodableFrames ?? 0) | \(c.windowsLeftOut ?? 0) |\n" }
        return md
    }
}
