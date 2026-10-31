//
//  ScoringExposure.swift
//  RallyLab
//
//  The identity of one pipeline scoring run, for the exposure ledger (owner,
//  2026-10-31): the command, the ball finder with its model's name and digest,
//  the detection settings that change what the pipeline sees, and a digest of
//  the decision settings that change what it cuts. The ledger drops a row that
//  repeats an earlier one's (video, kind, ref), so two runs that differ in any
//  of these are two uses and the same run again is one — before this, every
//  `--score-rallies` run shared one ref and a second model's pass left no row.
//
//  Also the one refusal for the headless scoring commands: reserved final-test
//  recordings (D-002) and the lineage-withheld closure (D-017: lineage and
//  legacy holdouts and every alias) are not scored.
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

    /// The ledger ref: `<command> <finder> <detection> decision=<digest>`.
    static func ref(command: String, config: ProcessorConfig) throws -> String {
        "\(command) \(try finder(config)) \(detection(config)) decision=\(decisionDigest(config))"
    }

    /// The readable note beside the ref: what the finder was and the decision settings the digest stands for.
    static func note(config: ProcessorConfig) -> String {
        let finder: String
        if let model = config.heatmapModel {
            finder = "multi-frame \(model.deletingPathExtension().lastPathComponent)" + (config.heatmapOnly ? " only" : " + YOLO \(config.ballModel.rawValue)")
        } else {
            finder = "YOLO \(config.ballModel.rawValue) only"
        }
        return "\(finder); " + decisionFields(config).map { "\($0.0)=\($0.1)" }.joined(separator: " ")
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

    /// Eight hex of SHA-256 over `decisionFields`.
    static func decisionDigest(_ config: ProcessorConfig) -> String {
        let text = decisionFields(config).map { "\($0.0)=\($0.1)" }.joined(separator: ";")
        return SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// Why `name` may not be scored, or nil when it may. `reserved` is the final-test closure
    /// (`ReservedVideos.reservedNames`), `withheld` the lineage-withheld closure
    /// (`ReservedVideos.lineageWithheldNames`): both are checked, the final test named first.
    static func refusal(_ name: String, reserved: Set<String>, withheld: Set<String>) -> String? {
        if reserved.contains(name) { return "⛔ \(name) is reserved as final_test (D-002) — not scored." }
        if withheld.contains(name) { return "⛔ \(name) is withheld — a lineage or legacy holdout, or an alias of one (D-017) — not scored." }
        return nil
    }
}
