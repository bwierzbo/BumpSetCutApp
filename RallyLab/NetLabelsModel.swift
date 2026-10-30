//
//  NetLabelsModel.swift
//  RallyLab
//
//  The Net labels tab's state: the project's recordings with why each is
//  skipped or whether it's labeled, the one being labeled with its frame,
//  the old model's proposal and the box as the person has it. A skipped
//  recording is never opened: not decoded, not shown to the old model. A
//  label is saved only for the frame on screen, and carries the recording's
//  fingerprint so it can't be inherited by a video that later takes the id.
//

import CoreGraphics
import Foundation
import Observation

/// What the tab asks of a recording's file; a test substitutes its own.
protocol NetLabelFootage: Sendable {
    func duration(of url: URL) async -> Double
    func frame(of url: URL, at time: Double) async throws -> CGImage
    /// Whether the old net model is there to propose boxes: asked before any exposure is recorded.
    var modelAvailable: Bool { get }
    /// The old net model's best box on the frame, if it finds one. Runs the model: only after
    /// the use is in the exposure ledger.
    func proposal(on frame: CGImage) -> (rect: CGRect, confidence: Float)?
}

struct RealNetLabelFootage: NetLabelFootage {
    func duration(of url: URL) async -> Double { await NetLabels.duration(of: url) }
    func frame(of url: URL, at time: Double) async throws -> CGImage { try await NetLabels.frame(of: url, at: time) }
    var modelAvailable: Bool { NetDetector().isLoaded }
    func proposal(on frame: CGImage) -> (rect: CGRect, confidence: Float)? {
        let detector = NetDetector()
        guard detector.isLoaded else { return nil }
        return detector.detect(in: frame).first
    }
}

/// Writes the model-proposal use to the exposure ledger; throws when it can't, and then no model runs.
typealias NetProposalRecorder = @MainActor (_ video: String, _ time: Double) throws -> Void

enum NetProposalExposure {
    static let ref = "Net labels tab"

    /// The real ledger: one `net_proposal` row for the recording, written before inference.
    static func recorder(projectDir: URL) -> NetProposalRecorder {
        { video, time in
            try ExposureLog.record(videos: [video], kind: .netProposal, ref: ref,
                                   note: "old net model proposed a net box on the frame at \(NetLabelsModel.clock(time))", in: projectDir)
        }
    }
}

@MainActor @Observable
final class NetLabelsModel {
    struct Item: Identifiable, Equatable {
        var id: String { video }
        let video: String
        let clip: String
        let camera: String
        let url: URL
        /// The file's identity (ReservedVideos.effectiveFingerprint); nil → skipped as unidentified.
        let fingerprint: String?
        let skip: NetLabels.Skip?
        /// A label with this recording's fingerprint exists.
        var labeled: Bool
        /// A label exists under this id but with another recording's fingerprint: not a label of this video.
        var stale: Bool
    }

    private let projects: ProjectsModel?
    private let footage: any NetLabelFootage
    /// Set with the project: records a proposal use before the model runs.
    private var recordProposal: NetProposalRecorder?
    private(set) var items: [Item] = []
    private(set) var labels: [String: NetLabel] = [:]
    private(set) var selected: String?
    private(set) var frame: CGImage?
    /// The time the frame on screen was decoded at; a label is saved for this frame only.
    private(set) var frameTime: Double?
    private(set) var time: Double = 0
    private(set) var duration: Double = 0
    /// The old net model's box on this frame, if it found one.
    private(set) var proposal: CGRect?
    /// The box as it stands: the proposal, the saved label, or what was drawn.
    var box: CGRect?
    private(set) var proposed = false
    private(set) var adjusted = false
    private(set) var loading = false
    private(set) var status = "Open a project."
    /// Why the recordings can't be listed (withheld names or labels unreadable): nothing is labeled then.
    private(set) var blocked: String?
    private var store: NetLabelStore?
    private var loadTask: Task<Void, Never>?
    /// Counts decode requests; a decode publishes its frame only while it is the latest.
    private var decodeSerial = 0

    init(projects: ProjectsModel, footage: any NetLabelFootage = RealNetLabelFootage()) {
        self.projects = projects
        self.footage = footage
        reload()
    }

    /// For tests: a fixed list and store, no project; `exposure` stands in for the ledger.
    init(items: [Item], labels: [String: NetLabel], store: NetLabelStore, footage: any NetLabelFootage, exposure: @escaping NetProposalRecorder) {
        projects = nil
        self.footage = footage
        self.store = store
        recordProposal = exposure
        self.labels = labels
        self.items = items.map { Self.marked($0, labels: labels) }.sorted { $0.video < $1.video }
        status = summary
    }

    var labeledCount: Int { items.filter(\.labeled).count }
    var toLabelCount: Int { items.filter { $0.skip == nil && !$0.labeled }.count }
    var selectedItem: Item? { items.first { $0.video == selected } }
    /// This recording's label, when it is of this recording.
    var current: NetLabel? {
        guard let item = selectedItem, item.labeled, let label = labels[item.video] else { return nil }
        return label
    }
    /// The frame on screen is the one `time` names and nothing is still decoding.
    var frameIsCurrent: Bool { !loading && frame != nil && frameTime == time }
    var canConfirm: Bool {
        guard let item = selectedItem, item.skip == nil, frameIsCurrent, let box, box.width > 0, box.height > 0 else { return false }
        return blocked == nil
    }
    private var summary: String {
        "\(labeledCount) labeled · \(toLabelCount) to label · \(items.count - labeledCount - toLabelCount) skipped"
    }

    private static func marked(_ item: Item, labels: [String: NetLabel]) -> Item {
        var it = item
        if let label = labels[item.video] {
            it.labeled = item.fingerprint != nil && label.fingerprint == item.fingerprint
            it.stale = !it.labeled
        } else {
            it.labeled = false; it.stale = false
        }
        return it
    }

    /// The project's recordings, fresh from project.json and net-labels.json.
    /// A withheld list or a labels file that can't be read blocks the tab.
    func reload() {
        loadTask?.cancel()
        decodeSerial += 1
        items = []; labels = [:]; selected = nil; frame = nil; frameTime = nil; box = nil; proposal = nil; blocked = nil
        guard let projects, let project = projects.project, let dir = projects.projectDir else { status = "Open a project."; return }
        let withheld: Set<String>
        do { withheld = try ReservedVideos.lineageWithheldNames(in: dir) } catch {
            blocked = "Withheld recordings unreadable: \(error.localizedDescription)"; status = blocked!; return
        }
        let store = NetLabelStore(projectDir: dir)
        self.store = store
        recordProposal = NetProposalExposure.recorder(projectDir: dir)
        do { labels = try store.load() } catch {
            blocked = "\(store.url.lastPathComponent) unreadable: \(error.localizedDescription)"; status = blocked!; return
        }
        items = project.clips.flatMap { clip in
            clip.videos.map { video in
                let id = clip.videoId(of: video)
                let fingerprint = ReservedVideos.effectiveFingerprint(video)
                return Self.marked(Item(video: id, clip: clip.id, camera: clip.camera, url: URL(fileURLWithPath: video.clipFile),
                                        fingerprint: fingerprint,
                                        skip: NetLabels.skip(video: id, camera: clip.camera, withheld: withheld, fingerprint: fingerprint),
                                        labeled: false, stale: false), labels: labels)
            }
        }
        .sorted { $0.video < $1.video }
        status = summary
    }

    /// Show a recording. A skipped one is named and nothing of it is opened.
    func select(_ video: String) {
        guard let item = items.first(where: { $0.video == video }) else { return }
        loadTask?.cancel()
        decodeSerial += 1
        selected = video
        frame = nil; frameTime = nil; proposal = nil; box = nil; proposed = false; adjusted = false; duration = 0; time = 0
        if let skip = item.skip {
            status = "\(item.video): skipped (\(skip.rawValue)) — not opened."
            return
        }
        loadTask = Task { await load(item) }
    }

    private func load(_ item: Item) async {
        loading = true
        defer { loading = false }
        guard FileManager.default.isReadableFile(atPath: item.url.path) else {
            status = "\(item.video): the video isn't readable here (is the footage share mounted?)"; return
        }
        let dur = await footage.duration(of: item.url)
        guard !Task.isCancelled, selected == item.video else { return }
        duration = dur
        guard duration > 0 else { status = "\(item.video): couldn't read the duration."; return }
        if item.labeled, let label = labels[item.video] {
            time = label.time
            box = label.box.rect
            proposed = label.proposed
            adjusted = label.adjusted
        } else {
            let marks = RallyMarkModel.load(RallyMarkModel.labelsURL(for: item.url)).map { (start: $0.start, end: $0.end) }
            time = NetLabels.frameTime(duration: duration, rallies: marks)
        }
        await decode(item, at: time)
        guard !Task.isCancelled, selected == item.video else { return }
        if item.labeled {
            status = "\(item.video): labeled. Change the box and confirm to replace it, or remove the label."
        } else if let frame {
            status = propose(on: frame, for: item)
            if item.stale { status += " (The label on file is another recording's and is replaced when you confirm.)" }
        }
    }

    /// The old model's box as a proposal, with the use in the exposure ledger first: if the
    /// ledger can't be written, the model does not run and the person draws the box.
    private func propose(on frame: CGImage, for item: Item) -> String {
        guard footage.modelAvailable else { return "\(item.video): no net model — drag a box around the net." }
        guard let recordProposal else { return "\(item.video): no exposure ledger for this project — drag a box around the net." }
        do { try recordProposal(item.video, time) } catch {
            return "\(item.video): the model's proposal was not made because its use could not be recorded (\(error.localizedDescription)) — drag a box around the net."
        }
        guard let best = footage.proposal(on: frame) else { return "\(item.video): no proposal — drag a box around the net." }
        proposal = best.rect
        box = best.rect
        proposed = true
        return "\(item.video): the old model's box, \(String(format: "%.2f", best.confidence)) — confirm it, move it, or draw your own."
    }

    /// Decode the frame at `t`; it goes on screen only if no later request superseded it.
    private func decode(_ item: Item, at t: Double) async {
        decodeSerial += 1
        let serial = decodeSerial
        loading = true
        defer { if serial == decodeSerial { loading = false } }
        let decoded: CGImage?
        var failure: String?
        do { decoded = try await footage.frame(of: item.url, at: t) } catch { decoded = nil; failure = error.localizedDescription }
        guard serial == decodeSerial, selected == item.video else { return }
        frame = decoded
        frameTime = decoded == nil ? nil : t
        if let failure { status = "\(item.video): no frame at \(Self.clock(t)): \(failure)" }
    }

    /// Another frame of the same recording; the box stays where it is.
    func step(seconds: Double) {
        guard let item = selectedItem, item.skip == nil, duration > 0 else { return }
        time = min(max(0, time + seconds), max(0, duration - 0.1))
        loadTask?.cancel()
        let t = time
        loadTask = Task { await decode(item, at: t) }
    }

    /// The box as the person dragged it.
    func setBox(_ rect: CGRect) {
        box = rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        adjusted = true
    }

    func useProposal() {
        guard let proposal else { return }
        box = proposal; proposed = true; adjusted = false
    }

    func clearBox() {
        box = nil; proposed = false; adjusted = false
    }

    /// Save the box as this recording's label — for the frame on screen, at its
    /// time, with the recording's fingerprint — and move on to the next one to label.
    @discardableResult
    func confirm() -> Bool {
        guard canConfirm, let item = selectedItem, let frame, let frameTime, let box, let fingerprint = item.fingerprint, let store else { return false }
        var next = labels
        next[item.video] = NetLabel(time: frameTime, box: TrackCandidate(rect: box, confidence: 1), proposed: proposed, adjusted: adjusted,
                                    reviewedAt: Date(), frameWidth: frame.width, frameHeight: frame.height, fingerprint: fingerprint)
        do { try store.save(next) } catch { status = "Not saved: \(error.localizedDescription)"; return false }
        labels = next
        if let i = items.firstIndex(where: { $0.video == item.video }) { items[i] = Self.marked(items[i], labels: labels) }
        status = "\(item.video): saved · \(summary)"
        nextToLabel()
        return true
    }

    /// Remove the label under this id, this recording's or a stale one.
    func removeLabel() {
        guard let item = selectedItem, labels[item.video] != nil, let store else { return }
        var next = labels
        next[item.video] = nil
        do { try store.save(next) } catch { status = "Not removed: \(error.localizedDescription)"; return }
        labels = next
        if let i = items.firstIndex(where: { $0.video == item.video }) { items[i] = Self.marked(items[i], labels: labels) }
        select(item.video)
    }

    /// The next unlabeled recording after the selected one, wrapping round.
    func nextToLabel() {
        let todo = items.filter { $0.skip == nil && !$0.labeled }
        guard !todo.isEmpty else { return }
        let after = selected.flatMap { s in todo.firstIndex { $0.video > s } } ?? 0
        select(todo[after].video)
    }

    static func clock(_ t: Double) -> String {
        String(format: "%d:%05.2f", Int(t) / 60, t - Double(Int(t) / 60 * 60))
    }
}
