//
//  NetAIProposals.swift
//  RallyLab
//
//  AI-assisted net corners (owner pilot, 2026-10-31): a vision model looks at
//  the same upright frame the Net labels tab would show and proposes the net's
//  four corners. A proposal is never a label. It sits in
//  <project>/net-ai-proposals.json, apart from net-labels.json; the tab shows
//  it in place of the old model's box, the person drags any corner, and only
//  the tab's Confirm turns it into a label (which then says where it started).
//
//  The pilot runs in three headless steps, each refusing on its own:
//    1. `--net-ai-frames <dir>` picks eligible recordings (not withheld — by the
//       split manifest's closure and by the files' — not handheld, identified,
//       with no label and no proposal yet), one per alias group, round-robin over
//       surfaces, decodes their frames by the tab's rule and writes them with a
//       manifest of hashes. Nothing else is opened.
//    2. `--net-ai-expose <dir> <video>` writes the `net_proposal` ledger row (ref =
//       the run) and a receipt before the model is shown that frame; if the row
//       can't be written the step fails and the frame is not shown.
//    3. `--import-net-ai-proposals <dir>` takes the model's answers
//       (<dir>/proposals.json) into net-ai-proposals.json, refusing any whose
//       exposure isn't on record, whose frame changed, whose recording is now
//       withheld, another file, or already labeled.
//

import CoreGraphics
import Foundation

/// A model's proposal of a recording's net corners, on one frame.
struct NetAIProposal: Codable, Equatable {
    enum Outcome: String, Codable {
        /// The model placed the four corners.
        case proposed
        /// The net isn't visible enough to place: the person labels it as usual.
        case needsManualReview = "needs_manual_review"
    }

    enum Confidence: String, Codable { case confident, uncertain }

    var outcome: Outcome
    /// Vision-normalised (bottom-up) in the upright frame; nil when the net couldn't be placed.
    var corners: NetQuad?
    var confidence: Confidence?
    /// What made the model unsure, or why it couldn't place the net.
    var uncertainty: String?
    /// The frame the model saw: its time, size and the SHA-256 of the image file it was given.
    var time: Double
    var frameWidth: Int
    var frameHeight: Int
    var imageSHA256: String
    /// The recording's file identity when the frame was taken.
    var fingerprint: String
    /// The model's identity and the run (the exposure-ledger ref).
    var model: String
    var run: String
    /// When the exposure was recorded, before the model saw the frame.
    var exposureRecordedAt: Date
    var importedAt: Date
    /// The person rejected it in the tab; it is not offered again.
    var rejectedAt: Date?

    /// What a label that started from this proposal records as its source.
    var source: String { "\(model) · \(run)" }
}

/// `<project>/net-ai-proposals.json`: video id → proposal. Like the label store:
/// read whole, written atomically, unreadable is an error and never empty.
struct NetAIProposalStore {
    let url: URL

    init(projectDir: URL) { url = projectDir.appendingPathComponent("net-ai-proposals.json") }

    func load() throws -> [String: NetAIProposal] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try NetAIPilot.decoder.decode([String: NetAIProposal].self, from: Data(contentsOf: url))
    }

    func save(_ proposals: [String: NetAIProposal]) throws {
        try NetAIPilot.encoder.encode(proposals).write(to: url, options: .atomic)
    }
}

enum NetAIPilot {
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]; return e
    }()

    static let manifestName = "pilot-manifest.json"
    static let submissionsName = "proposals.json"

    /// One of the project's recordings, as the pilot sees it.
    struct Candidate: Equatable {
        var video: String
        var clip: String
        var camera: String
        var surface: String?
        /// The split manifest's alias group: recordings in one share a net, so the pilot takes one.
        var aliasGroup: String?
        var url: URL
        /// The identity the split manifest recorded.
        var fingerprint: String?
        /// The identity project.json gives the file now (ReservedVideos.effectiveFingerprint).
        var fileFingerprint: String?
    }

    /// Up to `count` recordings to propose on, in a stable order: not skipped (withheld,
    /// handheld, unidentified), the manifest's identity the file's, no label under the id
    /// (a box-only label stays the person's), no proposal yet; one per alias group, taken
    /// round-robin over surfaces so the pilot sees more than one kind of court.
    static func choose(_ candidates: [Candidate], labels: [String: NetLabel], proposals: [String: NetAIProposal],
                       withheld: Set<String>, count: Int) -> [Candidate] {
        let eligible = candidates.filter {
            NetLabels.skip(video: $0.video, camera: $0.camera, withheld: withheld, fingerprint: $0.fingerprint) == nil
                && $0.fileFingerprint == $0.fingerprint && labels[$0.video] == nil && proposals[$0.video] == nil
        }
        var bySurface: [String: [Candidate]] = [:]
        var groups = Set<String>()
        for c in eligible.sorted(by: { $0.video < $1.video }) {
            let group = c.aliasGroup ?? c.video
            guard groups.insert(group).inserted else { continue }
            bySurface[c.surface ?? "", default: []].append(c)
        }
        var queues = bySurface.sorted { $0.key < $1.key }.map(\.value)
        var chosen: [Candidate] = []
        while chosen.count < count, queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where chosen.count < count && !queues[i].isEmpty {
                chosen.append(queues[i].removeFirst())
            }
        }
        return chosen
    }

    struct Frame: Codable, Equatable {
        var video: String
        var clip: String
        var camera: String
        var surface: String?
        var time: Double
        var width: Int
        var height: Int
        var fingerprint: String
        var image: String
        var imageSHA256: String
    }

    struct Manifest: Codable, Equatable {
        var project: String
        var run: String
        var model: String
        var createdAt: Date
        /// The withheld set the choice excluded (the manifest's closure ∪ the files'), by count.
        var withheldCount: Int
        var eligibleCount: Int
        var frames: [Frame]
        var note: String
    }

    /// What the model answers for one frame (<dir>/proposals.json is a list of these).
    struct Submission: Codable, Equatable {
        var video: String
        var outcome: NetAIProposal.Outcome
        var corners: NetQuad?
        var confidence: NetAIProposal.Confidence?
        var uncertainty: String?
    }

    /// Written beside the frames when the exposure is recorded.
    struct Receipt: Codable, Equatable {
        var video: String
        var run: String
        var model: String
        var imageSHA256: String
        var fingerprint: String
        var recordedAt: Date
    }

    static func receiptURL(_ video: String, in dir: URL) -> URL {
        dir.appendingPathComponent("exposure/\(video).json")
    }

    static func readManifest(in dir: URL) throws -> Manifest {
        try decoder.decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent(manifestName)))
    }

    /// Decode each chosen recording's frame by the tab's rule (the first marked rally
    /// long enough, else the middle) at the tab's size, into `dir` (created; must not
    /// exist), with the manifest. A recording whose file can't be read is left out and
    /// named; nothing but the chosen recordings is touched.
    static func writeFrames(_ chosen: [Candidate], footage: any NetLabelFootage, project: String, run: String, model: String,
                            withheldCount: Int, eligibleCount: Int, to dir: URL, log: (String) -> Void = { _ in }) async throws -> Manifest {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dir.path]) }
        try fm.createDirectory(at: dir.appendingPathComponent("frames"), withIntermediateDirectories: true)
        var frames: [Frame] = []
        for c in chosen {
            guard let fingerprint = c.fingerprint else { continue }
            guard await footage.isReadable(c.url) else { log("⚠️ \(c.video): not readable here — left out."); continue }
            let duration = await footage.duration(of: c.url)
            guard duration > 0 else { log("⚠️ \(c.video): no duration — left out."); continue }
            let t = NetLabels.frameTime(duration: duration, rallies: await footage.rallyMarks(for: c.url))
            let image = try await footage.frame(of: c.url, at: t)
            let file = "frames/\(c.video).jpg"
            let url = dir.appendingPathComponent(file)
            try NetLabels.writeJPEG(image, to: url)
            guard let digest = DatasetSplitManifest.sha256(of: url) else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
            frames.append(Frame(video: c.video, clip: c.clip, camera: c.camera, surface: c.surface, time: t,
                                width: image.width, height: image.height, fingerprint: fingerprint, image: file, imageSHA256: digest))
            log("  \(frames.count)/\(chosen.count) \(c.video) @ \(NetLabelsModel.clock(t)) \(image.width)×\(image.height)")
        }
        let manifest = Manifest(project: project, run: run, model: model, createdAt: Date(), withheldCount: withheldCount,
                                eligibleCount: eligibleCount, frames: frames,
                                note: "Upright frames as the Net labels tab decodes them (its frame rule and size). Each frame is shown to \(model) only after `--net-ai-expose` has written its net_proposal ledger row (ref \(run)) and receipt. Proposals are not labels.")
        try encoder.encode(manifest).write(to: dir.appendingPathComponent(manifestName), options: .atomic)
        return manifest
    }

    /// Check that `video`'s frame may be shown to the model now: in the pilot, not withheld,
    /// the same file, the image unchanged since it was written.
    static func check(_ video: String, manifest: Manifest, dir: URL, inventory: NetInventory, fileWithheld: Set<String>) throws -> Frame {
        guard let frame = manifest.frames.first(where: { $0.video == video }) else { throw PilotError.notInPilot(video) }
        guard !inventory.withheld.contains(video), !fileWithheld.contains(video) else { throw PilotError.withheld(video) }
        guard inventory.fingerprint[video] == frame.fingerprint else { throw PilotError.otherFile(video) }
        guard DatasetSplitManifest.sha256(of: dir.appendingPathComponent(frame.image)) == frame.imageSHA256 else { throw PilotError.imageChanged(video) }
        return frame
    }

    /// Record the use before the model sees the frame: the ledger row, then the receipt.
    /// Throws (and the frame must not be shown) when either can't be written.
    static func recordExposure(_ video: String, manifest: Manifest, dir: URL, projectDir: URL, inventory: NetInventory,
                               fileWithheld: Set<String>, now: Date = Date()) throws -> Receipt {
        let frame = try check(video, manifest: manifest, dir: dir, inventory: inventory, fileWithheld: fileWithheld)
        try ExposureLog.record(videos: [video], kind: .netProposal, ref: manifest.run,
                               note: "\(manifest.model) vision proposal of the net's four corners on the frame at \(NetLabelsModel.clock(frame.time)) (image sha256 \(frame.imageSHA256), fingerprint \(frame.fingerprint))",
                               in: projectDir, now: now)
        let receipt = Receipt(video: video, run: manifest.run, model: manifest.model, imageSHA256: frame.imageSHA256,
                              fingerprint: frame.fingerprint, recordedAt: now)
        let url = receiptURL(video, in: dir)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(receipt).write(to: url, options: .atomic)
        return receipt
    }

    /// The model's answers as proposals, merged into `existing`. All or nothing: any
    /// answer that fails a check stops the import, naming the recording.
    static func importSubmissions(_ submissions: [Submission], manifest: Manifest, dir: URL, inventory: NetInventory,
                                  fileWithheld: Set<String>, ledger: [DatasetSplitManifest.ExposureLogRow],
                                  labels: [String: NetLabel], existing: [String: NetAIProposal], now: Date = Date()) throws -> [String: NetAIProposal] {
        var out = existing
        var seen = Set<String>()
        for s in submissions {
            guard seen.insert(s.video).inserted else { throw PilotError.duplicate(s.video) }
            let frame = try check(s.video, manifest: manifest, dir: dir, inventory: inventory, fileWithheld: fileWithheld)
            guard ledger.contains(where: { $0.video == s.video && $0.kind == .netProposal && $0.ref == manifest.run }) else {
                throw PilotError.noExposure(s.video)
            }
            guard let data = try? Data(contentsOf: receiptURL(s.video, in: dir)), let receipt = try? decoder.decode(Receipt.self, from: data),
                  receipt.run == manifest.run, receipt.imageSHA256 == frame.imageSHA256, receipt.fingerprint == frame.fingerprint else {
                throw PilotError.noExposure(s.video)
            }
            guard labels[s.video] == nil else { throw PilotError.labeled(s.video) }
            if let old = existing[s.video], old.run != manifest.run { throw PilotError.otherRun(s.video, old.run) }
            switch s.outcome {
            case .proposed:
                guard let q = s.corners, q.isUsable, q.points.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) }),
                      q.topLeft.y > q.bottomLeft.y, q.topRight.y > q.bottomRight.y, q.topLeft.x < q.topRight.x,
                      s.confidence != nil else { throw PilotError.badCorners(s.video) }
            case .needsManualReview:
                guard s.corners == nil, s.uncertainty?.isEmpty == false else { throw PilotError.badCorners(s.video) }
            }
            out[s.video] = NetAIProposal(outcome: s.outcome, corners: s.corners, confidence: s.confidence, uncertainty: s.uncertainty,
                                         time: frame.time, frameWidth: frame.width, frameHeight: frame.height,
                                         imageSHA256: frame.imageSHA256, fingerprint: frame.fingerprint, model: manifest.model,
                                         run: manifest.run, exposureRecordedAt: receipt.recordedAt, importedAt: now)
        }
        return out
    }

    enum PilotError: LocalizedError, Equatable {
        case notInPilot(String)
        case withheld(String)
        case otherFile(String)
        case imageChanged(String)
        case noExposure(String)
        case labeled(String)
        case otherRun(String, String)
        case badCorners(String)
        case duplicate(String)

        var errorDescription: String? {
            switch self {
            case .notInPilot(let v): return "\(v): not one of this pilot's frames."
            case .withheld(let v): return "\(v): withheld — never shown to a model."
            case .otherFile(let v): return "\(v): the split manifest's identity is not the frame's — another file now."
            case .imageChanged(let v): return "\(v): the frame's image is not the one the pilot wrote."
            case .noExposure(let v): return "\(v): no net_proposal ledger row and receipt for this run — the frame must not have been shown."
            case .labeled(let v): return "\(v): has a label in net-labels.json — a proposal never replaces a person's label."
            case .otherRun(let v, let run): return "\(v): already has a proposal from run \(run)."
            case .badCorners(let v): return "\(v): corners missing, outside the frame, collapsed or upside down (or a manual-review answer with corners or no reason)."
            case .duplicate(let v): return "\(v): answered twice."
            }
        }
    }
}
