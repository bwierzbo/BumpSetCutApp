//
//  NetLabelsModel.swift
//  RallyLab
//
//  The Net labels tab's state: the project's recordings with why each is
//  skipped or whether it's labeled, the one being labeled with its frame,
//  the old model's proposal and the box as the person has it.
//

import CoreGraphics
import Foundation
import Observation

@MainActor @Observable
final class NetLabelsModel {
    struct Item: Identifiable, Equatable {
        var id: String { video }
        let video: String
        let clip: String
        let camera: String
        let url: URL
        let skip: NetLabels.Skip?
        var labeled: Bool
    }

    private let projects: ProjectsModel
    private(set) var items: [Item] = []
    private(set) var labels: [String: NetLabel] = [:]
    private(set) var selected: String?
    private(set) var frame: CGImage?
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

    init(projects: ProjectsModel) {
        self.projects = projects
        reload()
    }

    var labeledCount: Int { items.filter(\.labeled).count }
    var toLabelCount: Int { items.filter { $0.skip == nil && !$0.labeled }.count }
    var selectedItem: Item? { items.first { $0.video == selected } }
    var current: NetLabel? { selected.flatMap { labels[$0] } }

    /// The project's recordings, fresh from project.json and net-labels.json.
    /// A withheld list or a labels file that can't be read blocks the tab.
    func reload() {
        loadTask?.cancel()
        items = []; labels = [:]; selected = nil; frame = nil; box = nil; proposal = nil; blocked = nil
        guard let project = projects.project, let dir = projects.projectDir else { status = "Open a project."; return }
        let withheld: Set<String>
        do { withheld = try ReservedVideos.lineageWithheldNames(in: dir) } catch {
            blocked = "Withheld recordings unreadable: \(error.localizedDescription)"; status = blocked!; return
        }
        let store = NetLabelStore(projectDir: dir)
        self.store = store
        do { labels = try store.load() } catch {
            blocked = "\(store.url.lastPathComponent) unreadable: \(error.localizedDescription)"; status = blocked!; return
        }
        items = project.clips.flatMap { clip in
            clip.videos.map { video in
                let id = clip.videoId(of: video)
                return Item(video: id, clip: clip.id, camera: clip.camera, url: URL(fileURLWithPath: video.clipFile),
                            skip: NetLabels.skip(video: id, camera: clip.camera, withheld: withheld),
                            labeled: labels[id] != nil)
            }
        }
        .sorted { $0.video < $1.video }
        status = "\(labeledCount) labeled · \(toLabelCount) to label · \(items.count - labeledCount - toLabelCount) skipped"
    }

    func select(_ video: String) {
        guard let item = items.first(where: { $0.video == video }) else { return }
        selected = video
        frame = nil; proposal = nil; box = nil; proposed = false; adjusted = false
        loadTask?.cancel()
        loadTask = Task { await load(item) }
    }

    private func load(_ item: Item) async {
        loading = true
        defer { loading = false }
        guard FileManager.default.isReadableFile(atPath: item.url.path) else {
            status = "\(item.video): the video isn't readable here (is the footage share mounted?)"; return
        }
        duration = await NetLabels.duration(of: item.url)
        guard duration > 0 else { status = "\(item.video): couldn't read the duration."; return }
        if let label = labels[item.video] {
            time = label.time
            box = label.box.rect
            proposed = label.proposed
            adjusted = label.adjusted
        } else {
            let marks = RallyMarkModel.load(RallyMarkModel.labelsURL(for: item.url)).map { (start: $0.start, end: $0.end) }
            time = NetLabels.frameTime(duration: duration, rallies: marks)
        }
        await decode(item)
        guard !Task.isCancelled else { return }
        if labels[item.video] == nil, let frame {
            let detector = NetDetector()
            if detector.isLoaded, let best = detector.detect(in: frame).first {
                proposal = best.rect
                box = best.rect
                proposed = true
                status = "\(item.video): the old model's box, \(String(format: "%.2f", best.confidence)) — confirm it, move it, or draw your own."
            } else {
                status = "\(item.video): no proposal — drag a box around the net."
            }
        } else if labels[item.video] != nil {
            status = "\(item.video): labeled. Change the box and confirm to replace it, or remove the label."
        }
    }

    private func decode(_ item: Item) async {
        do { frame = try await NetLabels.frame(of: item.url, at: time) } catch {
            frame = nil
            status = "\(item.video): no frame at \(Self.clock(time)): \(error.localizedDescription)"
        }
    }

    /// Another frame of the same recording; the box stays where it is.
    func step(seconds: Double) {
        guard let item = selectedItem, duration > 0 else { return }
        time = min(max(0, time + seconds), max(0, duration - 0.1))
        loadTask?.cancel()
        loadTask = Task { await decode(item) }
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

    /// Save the box as this recording's label and move on to the next one to label.
    @discardableResult
    func confirm() -> Bool {
        guard let item = selectedItem, item.skip == nil, let frame, let box, box.width > 0, box.height > 0, let store else { return false }
        var next = labels
        next[item.video] = NetLabel(time: time, box: TrackCandidate(rect: box, confidence: 1), proposed: proposed, adjusted: adjusted,
                                    reviewedAt: Date(), frameWidth: frame.width, frameHeight: frame.height)
        do { try store.save(next) } catch { status = "Not saved: \(error.localizedDescription)"; return false }
        labels = next
        if let i = items.firstIndex(where: { $0.video == item.video }) { items[i].labeled = true }
        status = "\(item.video): saved · \(labeledCount) labeled · \(toLabelCount) to label"
        nextToLabel()
        return true
    }

    func removeLabel() {
        guard let item = selectedItem, labels[item.video] != nil, let store else { return }
        var next = labels
        next[item.video] = nil
        do { try store.save(next) } catch { status = "Not removed: \(error.localizedDescription)"; return }
        labels = next
        if let i = items.firstIndex(where: { $0.video == item.video }) { items[i].labeled = false }
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
