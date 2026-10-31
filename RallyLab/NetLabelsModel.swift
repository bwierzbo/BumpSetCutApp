//
//  NetLabelsModel.swift
//  RallyLab
//
//  The Net labels tab's state: the project's recordings with why each is
//  skipped or whether it's labeled, the one being labeled with its frame,
//  the old model's proposal and the net's four corners as the person has
//  them. A skipped recording is never opened: not decoded, not shown to the
//  old model. A label is saved only for the frame on screen, and carries the
//  recording's fingerprint so it can't be inherited by a video that later
//  takes the id. A label from before corners existed (a box) is still to
//  label: its box seeds the corners, no proposal is made for it.
//

import CoreGraphics
import Foundation
import Observation

/// What the tab asks of a recording's file; a test substitutes its own. The
/// files sit on the footage share, so every one of these may take seconds
/// (or block for the SMB timeout when the share has dropped): none runs on
/// the main actor.
protocol NetLabelFootage: Sendable {
    /// Whether the file can be read here (a stat on the share).
    func isReadable(_ url: URL) async -> Bool
    /// The rallies a person marked, from the labels file beside the video.
    func rallyMarks(for url: URL) async -> [(start: Double, end: Double)]
    func duration(of url: URL) async -> Double
    func frame(of url: URL, at time: Double) async throws -> CGImage
    /// Whether the old net model is there to propose boxes: asked before any exposure is recorded.
    var modelAvailable: Bool { get }
    /// The old net model's best box on the frame, if it finds one. Runs the model: only after
    /// the use is in the exposure ledger.
    func proposal(on frame: CGImage) -> (rect: CGRect, confidence: Float)?
}

struct RealNetLabelFootage: NetLabelFootage {
    func isReadable(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) { FileManager.default.isReadableFile(atPath: url.path) }.value
    }
    func rallyMarks(for url: URL) async -> [(start: Double, end: Double)] {
        await Task.detached(priority: .userInitiated) {
            RallyMarkModel.load(RallyMarkModel.labelsURL(for: url)).map { (start: $0.start, end: $0.end) }
        }.value
    }
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
        /// The file's identity as the split manifest recorded it (NetInventory); nil → skipped as unidentified.
        let fingerprint: String?
        let skip: NetLabels.Skip?
        /// A label with this recording's fingerprint and its corners exists.
        var labeled: Bool
        /// A label exists under this id but with another recording's fingerprint: not a label of this video.
        var stale: Bool
        /// This recording's label has a box but no corners (from before corners were marked): still to label.
        var boxOnly = false
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
    /// The net's corners as they stand: the proposal's, the saved label's, or what was drawn and dragged.
    private(set) var quad: NetQuad?
    /// The box the corners span.
    var box: CGRect? { quad?.bounds }
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

    /// Frames read ahead of the selection, so the next recordings open at once: the
    /// share takes seconds per frame. Only recordings still to label are read, never a
    /// skipped one, and nothing but the frame — the old model runs only when a
    /// recording is shown. At most `prefetchAhead` after the selection are kept.
    struct Prefetched: Equatable {
        let time: Double
        let duration: Double
        let frame: CGImage
    }
    private(set) var prefetched: [String: Prefetched] = [:]
    private let prefetchAhead: Int
    private var prefetchTask: Task<Void, Never>?
    /// The recordings whose frames are being read now.
    private(set) var prefetching: String?

    init(projects: ProjectsModel, footage: any NetLabelFootage = RealNetLabelFootage(), prefetchAhead: Int = 8) {
        self.projects = projects
        self.footage = footage
        self.prefetchAhead = prefetchAhead
        reload()
    }

    /// For tests: a fixed list and store, no project; `exposure` stands in for the ledger.
    init(items: [Item], labels: [String: NetLabel], store: NetLabelStore, footage: any NetLabelFootage, prefetchAhead: Int = 0,
         exposure: @escaping NetProposalRecorder) {
        projects = nil
        self.footage = footage
        self.store = store
        self.prefetchAhead = prefetchAhead
        recordProposal = exposure
        self.labels = labels
        self.items = items.map { Self.marked($0, labels: labels) }.sorted { $0.video < $1.video }
        status = summary
        prefetch()
    }

    var labeledCount: Int { items.filter(\.labeled).count }
    var toLabelCount: Int { items.filter { $0.skip == nil && !$0.labeled }.count }
    var boxOnlyCount: Int { items.filter(\.boxOnly).count }
    var selectedItem: Item? { items.first { $0.video == selected } }
    /// This recording's label, when it is of this recording.
    var current: NetLabel? {
        guard let item = selectedItem, item.labeled, let label = labels[item.video] else { return nil }
        return label
    }
    /// The frame on screen is the one `time` names and nothing is still decoding.
    var frameIsCurrent: Bool { !loading && frame != nil && frameTime == time }
    var canConfirm: Bool {
        guard let item = selectedItem, item.skip == nil, frameIsCurrent, let quad, quad.isUsable else { return false }
        return blocked == nil
    }
    private var summary: String {
        "\(labeledCount) labeled · \(toLabelCount) to label" + (boxOnlyCount > 0 ? " (\(boxOnlyCount) box-only, corners to mark)" : "")
            + " · \(items.count - labeledCount - toLabelCount) skipped"
    }

    private static func marked(_ item: Item, labels: [String: NetLabel]) -> Item {
        var it = item
        if let label = labels[item.video] {
            let mine = item.fingerprint != nil && label.fingerprint == item.fingerprint
            it.labeled = mine && label.corners != nil
            it.boxOnly = mine && label.corners == nil
            it.stale = !mine
        } else {
            it.labeled = false; it.stale = false; it.boxOnly = false
        }
        return it
    }

    /// The project's recordings, fresh from project.json, the split manifest
    /// (identities and the withheld set — no video file is read) and
    /// net-labels.json. A manifest that is missing or not of this project, or
    /// a labels file that can't be read, blocks the tab.
    func reload() {
        loadTask?.cancel()
        prefetchTask?.cancel()
        prefetched = [:]; prefetching = nil
        decodeSerial += 1
        items = []; labels = [:]; selected = nil; frame = nil; frameTime = nil; quad = nil; proposal = nil; blocked = nil
        guard let projects, let project = projects.project, let dir = projects.projectDir else { status = "Open a project."; return }
        let inventory: NetInventory
        do { inventory = try NetInventory.load(projectDir: dir) } catch {
            blocked = "Nothing can be labeled: \(error.localizedDescription)"; status = blocked!; return
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
                let fingerprint = inventory.fingerprint[id] ?? inventory.fingerprint[DatasetStore.safeName(id)]
                return Self.marked(Item(video: id, clip: clip.id, camera: clip.camera, url: URL(fileURLWithPath: video.clipFile),
                                        fingerprint: fingerprint,
                                        skip: NetLabels.skip(video: id, camera: clip.camera, withheld: inventory.withheld, fingerprint: fingerprint),
                                        labeled: false, stale: false), labels: labels)
            }
        }
        .sorted { $0.video < $1.video }
        status = summary
        prefetch()
    }

    /// The recordings still to label after the selection (wrapping round), in list order.
    private func upcoming() -> [Item] {
        let todo = items.filter { $0.skip == nil && !$0.labeled && !$0.boxOnly }
        guard !todo.isEmpty else { return [] }
        let start = selected.flatMap { s in todo.firstIndex { $0.video > s } } ?? 0
        return Array(todo[start...] + todo[..<start])
    }

    /// Read the next `prefetchAhead` recordings' frames in the background, one at a
    /// time; drop frames that have fallen out of the window.
    private func prefetch() {
        guard prefetchAhead > 0 else { return }
        let window = Array(upcoming().prefix(prefetchAhead))
        let keep = Set(window.map(\.video)).union(selected.map { [$0] } ?? [])
        prefetched = prefetched.filter { keep.contains($0.key) }
        let todo = window.filter { prefetched[$0.video] == nil }
        guard !todo.isEmpty else { return }
        if let prefetching, todo.first?.video == prefetching { return }   // already on it, in this order
        prefetchTask?.cancel()
        prefetchTask = Task { await prefetch(todo) }
    }

    private func prefetch(_ queue: [Item]) async {
        defer { prefetching = nil }
        for item in queue {
            guard !Task.isCancelled, prefetched[item.video] == nil else { continue }
            if selected == item.video { continue }   // the selection reads its own frame
            prefetching = item.video
            guard await footage.isReadable(item.url), !Task.isCancelled else { continue }
            let dur = await footage.duration(of: item.url)
            guard dur > 0, !Task.isCancelled else { continue }
            let marks = await footage.rallyMarks(for: item.url)
            guard !Task.isCancelled else { return }
            let t = NetLabels.frameTime(duration: dur, rallies: marks)
            guard let frame = try? await footage.frame(of: item.url, at: t), !Task.isCancelled else { continue }
            // Only while it is still wanted: the selection may have moved on past it.
            if items.contains(where: { $0.video == item.video && $0.skip == nil && !$0.labeled && !$0.boxOnly }) {
                prefetched[item.video] = Prefetched(time: t, duration: dur, frame: frame)
            }
        }
    }

    /// Show a recording. A skipped one is named and nothing of it is opened.
    func select(_ video: String) {
        guard let item = items.first(where: { $0.video == video }) else { return }
        loadTask?.cancel()
        decodeSerial += 1
        selected = video
        frame = nil; frameTime = nil; proposal = nil; quad = nil; proposed = false; adjusted = false; duration = 0; time = 0
        if let skip = item.skip {
            status = "\(item.video): skipped (\(skip.rawValue)) — not opened."
            return
        }
        loadTask = Task { await load(item) }
        prefetch()
    }

    private func load(_ item: Item) async {
        loading = true
        defer { loading = false }
        if !item.labeled, !item.boxOnly, let ready = prefetched[item.video] {
            // Read ahead already: on screen at once, no file touched.
            time = ready.time
            duration = ready.duration
            frame = ready.frame
            frameTime = ready.time
            status = propose(on: ready.frame, for: item)
            if item.stale { status += " (The label on file is another recording's and is replaced when you confirm.)" }
            return
        }
        let readable = await footage.isReadable(item.url)
        guard !Task.isCancelled, selected == item.video else { return }
        guard readable else {
            status = "\(item.video): the video isn't readable here (is the footage share mounted?)"; return
        }
        let dur = await footage.duration(of: item.url)
        guard !Task.isCancelled, selected == item.video else { return }
        duration = dur
        guard duration > 0 else { status = "\(item.video): couldn't read the duration."; return }
        if item.labeled || item.boxOnly, let label = labels[item.video] {
            time = label.time
            // A box-only label's box seeds the corners; the person places them and confirms.
            quad = label.corners ?? NetQuad(rect: label.box.rect)
            proposed = label.proposed
            adjusted = label.adjusted
        } else {
            let marks = await footage.rallyMarks(for: item.url)
            guard !Task.isCancelled, selected == item.video else { return }
            time = NetLabels.frameTime(duration: duration, rallies: marks)
        }
        await decode(item, at: time)
        guard !Task.isCancelled, selected == item.video else { return }
        if item.labeled {
            status = "\(item.video): labeled. Move a corner and confirm to replace it, or remove the label."
        } else if item.boxOnly {
            status = "\(item.video): a box from before corners were marked — drag the four corners onto the net's corners and confirm."
        } else if let frame {
            status = propose(on: frame, for: item)
            if item.stale { status += " (The label on file is another recording's and is replaced when you confirm.)" }
        }
    }

    /// The old model's box as a proposal, with the use in the exposure ledger first: if the
    /// ledger can't be written, the model does not run and the person draws the box.
    private func propose(on frame: CGImage, for item: Item) -> String {
        let byHand = "drag a box around the net, then drag its corners onto the net's corners."
        guard footage.modelAvailable else { return "\(item.video): no net model — \(byHand)" }
        guard let recordProposal else { return "\(item.video): no exposure ledger for this project — \(byHand)" }
        do { try recordProposal(item.video, time) } catch {
            return "\(item.video): the model's proposal was not made because its use could not be recorded (\(error.localizedDescription)) — \(byHand)"
        }
        guard let best = footage.proposal(on: frame) else { return "\(item.video): no proposal — \(byHand)" }
        proposal = best.rect
        quad = NetQuad(rect: best.rect)
        proposed = true
        return "\(item.video): the old model's box, \(String(format: "%.2f", best.confidence)) — drag its corners onto the net's corners and confirm, or draw your own."
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

    /// A new rectangle drawn by hand: its corners replace whatever was there.
    func setBox(_ rect: CGRect) {
        quad = NetQuad(rect: rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)))
        adjusted = true
    }

    /// The corners as the person dragged them (one corner, or all four together).
    func setQuad(_ q: NetQuad) {
        quad = q
        adjusted = true
    }

    func useProposal() {
        guard let proposal else { return }
        quad = NetQuad(rect: proposal); proposed = true; adjusted = false
    }

    func clearBox() {
        quad = nil; proposed = false; adjusted = false
    }

    /// Save the corners as this recording's label — for the frame on screen, at its
    /// time, with the recording's fingerprint — and move on to the next one to label.
    @discardableResult
    func confirm() -> Bool {
        guard canConfirm, let item = selectedItem, let frame, let frameTime, let quad, let fingerprint = item.fingerprint, let store else { return false }
        var next = labels
        next[item.video] = NetLabel(time: frameTime, box: TrackCandidate(rect: quad.bounds, confidence: 1), corners: quad,
                                    proposed: proposed, adjusted: adjusted,
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
