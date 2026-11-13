//
//  ScoringExposure.swift
//  RallyLab
//
//  The identity of one pipeline scoring run, for the exposure ledger (owner,
//  2026-10-31): the command, the ball finder with its model's name and digest,
//  the detection settings a person reads most, and a fingerprint of every
//  other setting in the processor's config (by reflection, so a field added
//  later is in it without anyone remembering). The ledger drops a row that
//  repeats an earlier one's (video, kind, ref), so two runs that differ in any
//  of these are two uses and the same run again is one — before this, every
//  `--score-rallies` run shared one ref and a second model's pass left no row.
//
//  Also what no routine model run goes into (owner, 2026-11-12 §5C): the whole
//  withheld closure — reserved final-test recordings (D-002) and the lineage
//  and legacy holdouts with every alias (D-017). `Closures` reads it, `refusal`
//  words it for the headless scoring commands, and `admit` is the one
//  admission (refuse the withheld, then record) for a model run over named
//  recordings: a package's frames in HeatmapLab, a ball path, the Track tab's
//  and the Sampler's detectors. There is no way past it: an authorised
//  evaluation of a holdout is a separately controlled, logged path of its own.
//

import CryptoKit
import Foundation

enum ScoringExposure {
    enum IdentityError: LocalizedError {
        case modelUnreadable(URL)
        var errorDescription: String? {
            switch self {
            case .modelUnreadable(let url):
                return "The multi-frame model at \(url.path) can't be read for its digest, so this run's identity is unknown. "
                    + "Nothing is scored until the ledger can name the model."
            }
        }
    }

    /// The ledger ref: `<command> <finder> <detection> config=<fingerprint>`.
    static func ref(command: String, config: ProcessorConfig) throws -> String {
        "\(command) \(try finder(config)) \(detection(config)) config=\(fingerprint(config))"
    }

    /// The readable note beside the ref: what the finder was and the decision settings a reader asks about first
    /// (the fingerprint in the ref covers every setting).
    static func note(config: ProcessorConfig) -> String {
        let finder: String
        if let model = config.heatmapModel {
            finder = "multi-frame \(model.deletingPathExtension().lastPathComponent)" + (config.heatmapOnly ? " only" : " + YOLO \(config.ballModel.rawValue)")
        } else {
            finder = "YOLO \(config.ballModel.rawValue) only"
        }
        return "\(finder); " + decisionFields(config).map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    /// The note on a row added after its pass (owner, 2026-10-31 §3: a pass the ledger dropped as a duplicate before
    /// rows named the model is recorded afterwards, never as if it had been recorded at the time): when the pass ran,
    /// why the row is late, the day it was added, then the settings note the row would have carried.
    static func retrospectiveNote(ran: String, why: String, config: ProcessorConfig, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return "retrospective: the pass ran \(ran); \(why); row added \(f.string(from: now)); " + note(config: config)
    }

    /// Every stored property of the config but the model's URL (the finder names the model by its digest, so
    /// the same model at another path is the same run), as `name=value` lines in declaration order. Reflection,
    /// so a setting added to `ProcessorConfig` is in the identity from then on.
    static func fingerprintFields(_ config: ProcessorConfig) -> [String] {
        Mirror(reflecting: config).children.compactMap { child in
            guard let label = child.label, label != "heatmapModel" else { return nil }
            return "\(label)=\(String(describing: child.value))"
        }
    }

    /// Eight hex of SHA-256 over `fingerprintFields`.
    static func fingerprint(_ config: ProcessorConfig) -> String {
        SHA256.hash(data: Data(fingerprintFields(config).joined(separator: "\n").utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The multi-frame model by file name and the first 16 hex of its canonical digest (every file in
    /// the package, so a retrained model under the same name is another model), or the YOLO model's name.
    private static func finder(_ config: ProcessorConfig) throws -> String {
        guard let model = config.heatmapModel else { return "yolo=\(config.ballModel.rawValue)" }
        guard let digest = DatasetSplitManifest.canonicalDigest(ofDirectory: model) else { throw IdentityError.modelUnreadable(model) }
        let heat = "heat=\(model.deletingPathExtension().lastPathComponent)@\(digest.prefix(16))"
        return config.heatmapOnly ? heat : heat + "+yolo=\(config.ballModel.rawValue)"
    }

    private static func detection(_ config: ProcessorConfig) -> String {
        let threshold = config.heatmapThreshold.map { "\($0)" } ?? "model"
        return "hop=\(config.heatmapHop) thr=\(threshold) rot=\(config.applyVideoRotation ? 1 : 0) color=\(config.standardColorFrames ? "std" : "raw")"
    }

    /// The settings the rally decision, the gates and the clip padding read, in a fixed order.
    static func decisionFields(_ config: ProcessorConfig) -> [(String, String)] {
        func num(_ v: Double) -> String { String(format: "%.6g", v) }
        func flag(_ v: Bool) -> String { v ? "1" : "0" }
        var out: [(String, String)] = []
        out.append(("startBuffer", num(config.startBuffer)))
        out.append(("endTimeout", num(config.endTimeout)))
        out.append(("skyBallTopThreshold", num(Double(config.skyBallTopThreshold))))
        out.append(("skyBallTimeout", num(config.skyBallTimeout)))
        out.append(("projDropGracePeriod", String(config.projDropGracePeriod)))
        out.append(("servePrimedStart", flag(config.servePrimedStart)))
        out.append(("serveContinuationSec", num(config.serveContinuationSec)))
        out.append(("serveContinuationProjectileSec", num(config.serveContinuationProjectileSec)))
        out.append(("preroll", num(config.preroll)))
        out.append(("postroll", num(config.postroll)))
        out.append(("minGapToMerge", num(config.minGapToMerge)))
        out.append(("minSegmentLength", num(config.minSegmentLength)))
        out.append(("enableAboveNetRequirement", flag(config.enableAboveNetRequirement)))
        out.append(("aboveNetMarginY", num(Double(config.aboveNetMarginY))))
        out.append(("aboveNetArcProminence", num(Double(config.aboveNetArcProminence))))
        out.append(("enableRallyScoreGate", flag(config.enableRallyScoreGate)))
        out.append(("rallyScoreMinConfidence", num(config.rallyScoreMinConfidence)))
        out.append(("movementClassifierEnabled", flag(config.movementClassifierEnabled)))
        out.append(("minClassificationConfidence", num(config.minClassificationConfidence)))
        out.append(("minGravitySignature", num(config.minGravitySignature)))
        out.append(("parabolaMinR2", num(config.parabolaMinR2)))
        out.append(("projectileWindowSec", num(config.projectileWindowSec)))
        out.append(("minProjectileSpanY", num(Double(config.minProjectileSpanY))))
        out.append(("minCurvatureMagnitude", num(Double(config.minCurvatureMagnitude))))
        return out
    }

    /// The two closures a routine model run is checked against, read together and strictly (an unreadable
    /// validation.json or project.json throws: nothing is then cleared): `reserved`, the final-test closure
    /// (`ReservedVideos.reservedNames`: final test, candidates, lineage holdout and their aliases), and `withheld`,
    /// the whole withheld closure (`ReservedVideos.lineageWithheldNames`: those and the legacy holdout with its
    /// aliases), which contains it. No routine model run — training or packaging, pre-tracking, scoring, tuning,
    /// comparison, debug processing, proposals — goes into `withheld` (owner, 2026-11-12 §5C).
    struct Closures {
        let reserved: Set<String>
        let withheld: Set<String>

        init(in root: URL) throws {
            reserved = try ReservedVideos.reservedNames(in: root)
            withheld = try ReservedVideos.lineageWithheldNames(in: root)
        }

        /// What keeps `name` from a model run (see `ScoringExposure.standing`), or nil when it may be run.
        func standing(of name: String) -> String? {
            ScoringExposure.standing(reserved: reserved.contains(name), withheld: withheld.contains(name))
        }

        /// `sessions` less every withheld recording: the ones a model may run over, or a package may hold.
        func admitted(_ sessions: [VideoSession]) -> [VideoSession] {
            sessions.filter { !withheld.contains($0.name) }
        }

        /// The closures of validation.json and project.json as they are now, read again only when either file
        /// has changed (size, modification time, or there or not) — for a caller that asks once per frame (the
        /// project dataset's writer, `DatasetStore.writeLabel`). A read that throws is never kept: unreadable
        /// reservations throw on every call (fails closed).
        static func current(in root: URL) throws -> Closures {
            let files = [PipelineTuner.ValidationSet.file(in: root), root.appendingPathComponent("project.json")]
            let stamp = files.map { file -> String in
                guard let a = try? FileManager.default.attributesOfItem(atPath: file.path) else { return "none" }
                return "\(a[.size] as? UInt64 ?? 0)@\((a[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)"
            }
            let key = root.standardizedFileURL.path
            keptLock.lock()
            let hit = kept[key]
            keptLock.unlock()
            if let hit, hit.stamp == stamp { return hit.closures }
            let closures = try Closures(in: root)
            keptLock.lock()
            kept[key] = (stamp, closures)
            keptLock.unlock()
            return closures
        }

        private static let keptLock = NSLock()
        nonisolated(unsafe) private static var kept: [String: (stamp: [String], closures: Closures)] = [:]
    }

    /// What keeps a recording from every routine model run, worded to follow "<name> is": the final test named
    /// first, the rest of the withheld closure after it. nil for a recording that is in neither.
    static func standing(reserved: Bool, withheld: Bool) -> String? {
        if reserved { return "reserved as final_test (D-002)" }
        if withheld { return "withheld — a lineage or legacy holdout, or an alias of one (D-017)" }
        return nil
    }

    /// Why `name` may not be scored, or nil when it may. `reserved` is the final-test closure
    /// (`ReservedVideos.reservedNames`), `withheld` the lineage-withheld closure
    /// (`ReservedVideos.lineageWithheldNames`): both are checked, the final test named first.
    static func refusal(_ name: String, reserved: Set<String>, withheld: Set<String>) -> String? {
        standing(reserved: reserved.contains(name), withheld: withheld.contains(name)).map { "⛔ \(name) is \($0) — not scored." }
    }

    /// Withheld recordings among those a model was about to run over: none is run.
    struct Withheld: LocalizedError, Equatable {
        /// Those in the final-test closure (D-002), sorted.
        let reserved: [String]
        /// Those in the rest of the withheld closure (D-017: a lineage or legacy holdout's), sorted.
        let withheld: [String]

        /// Each group with what keeps it out: "z is reserved as final_test (D-002); h is withheld — a lineage or
        /// legacy holdout, or an alias of one (D-017)".
        var reason: String {
            [(reserved, true), (withheld, false)].filter { !$0.0.isEmpty }.map { names, isReserved in
                "\(names.joined(separator: ", ")) \(names.count == 1 ? "is" : "are") \(ScoringExposure.standing(reserved: isReserved, withheld: true)!)"
            }.joined(separator: "; ")
        }
        var errorDescription: String? { "\(reason) — no model is run over withheld footage." }
    }

    /// Admits a model or pipeline run over these recordings, or throws: `Withheld` when any of them is in the
    /// withheld closure (D-002, D-017: the listed final test, candidates, lineage holdout and legacy holdout, and
    /// their aliases), and what the reservations or the ledger throw when they can't be read or written (fails
    /// closed). Nothing of a refused run is recorded. The use is on the ledger when this returns — before any
    /// model runs, so an interrupted run is still on record.
    static func admit(_ names: Set<String>, kind: ExposureRecord.Kind, ref: String, note: String?, root: URL) throws {
        let closures = try Closures(in: root)
        let refused = names.intersection(closures.withheld)
        guard refused.isEmpty else {
            throw Withheld(reserved: refused.intersection(closures.reserved).sorted(), withheld: refused.subtracting(closures.reserved).sorted())
        }
        try ExposureLog.record(videos: names, kind: kind, ref: ref, note: note, in: root)
    }

    /// `admit` for the one recording a person has open, as the line its tab shows: nil once the use is on the
    /// ledger, else why no model runs over it — withheld, with `otherwise` saying what the person does without
    /// the model, or reservations or a ledger that can't be read or written.
    static func admission(of name: String, kind: ExposureRecord.Kind, ref: String, note: String, root: URL, otherwise: String) -> String? {
        do {
            try admit([name], kind: kind, ref: ref, note: note, root: root)
            return nil
        } catch let refused as Withheld {
            return "⛔ \(refused.reason) — \(otherwise)"
        } catch {
            return "❌ \(name): \(error.localizedDescription)"
        }
    }
}
