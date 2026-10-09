//
//  AnnotationReview.swift
//  RallyLab (macOS and iPhone)
//
//  Annotation review: every labeled frame of a finished rally is checked
//  once before it's used for training. A frame with a ball is shown as a
//  crop around its box — the box fixed in the middle; you move the picture
//  under it and size it, then approve. "No ball" sends it to the full-frame
//  check, along with every frame marked hidden while tracking: the whole
//  frame, to place the ball or confirm it can't be seen.
//

import AVFoundation
import CoreGraphics
import Foundation
import Observation

enum AnnotationReview {

    /// Which check a frame needs.
    enum Kind { case crop, fullFrame }

    /// One frame to review: a frame of a rally of a video (keyed however the
    /// app keys its videos — the phone by id, the Mac by session name).
    struct Item: Hashable {
        let video: String
        let track: UUID
        let index: Int
    }

    /// What `point` still needs, if anything. Frames the solver couldn't
    /// decide (not found, not yours) aren't labeled, so aren't reviewed.
    static func kind(of point: TrackPoint) -> Kind? {
        guard !point.reviewed else { return nil }
        switch point.state {
        case .visible: return point.box == nil ? nil : .crop
        case .hidden: return .fullFrame
        case .unknown: return point.origin == .user ? .fullFrame : nil
        }
    }

    /// The frames of finished rallies still needing `kind`, rally by rally,
    /// in frame order (neighbours look alike, so they go quickly).
    static func items(_ rallies: [(video: String, rally: TrackedRally)], kind: Kind) -> [Item] {
        rallies.filter { $0.rally.done }
            .sorted { ($0.video, $0.rally.start) < ($1.video, $1.rally.start) }
            .flatMap { v in
                v.rally.points.indices.filter { Self.kind(of: v.rally.points[$0]) == kind }
                    .map { Item(video: v.video, track: v.rally.id, index: $0) }
            }
    }

    /// Reviewed of all labeled frames in finished rallies.
    static func progress(_ rallies: [TrackedRally]) -> (reviewed: Int, total: Int) {
        let points = rallies.filter(\.done).flatMap(\.points).filter { $0.reviewed || kind(of: $0) != nil }
        return (points.filter(\.reviewed).count, points.count)
    }

    // MARK: - Decisions

    /// The ball is in `box` (Vision-normalised): checked.
    static func approve(_ point: inout TrackPoint, box: CGRect) {
        point.state = .visible
        point.origin = .user
        point.box = TrackCandidate(rect: box, confidence: 1)
        point.reviewed = true
    }

    /// The box isn't on the ball: off to the full-frame check.
    static func noBall(_ point: inout TrackPoint) {
        point.state = .unknown
        point.origin = .user
        point.box = nil
        point.reviewed = false
    }

    /// The ball can't be seen on this frame: checked.
    static func confirmHidden(_ point: inout TrackPoint) {
        point.state = .hidden
        point.origin = .user
        point.box = nil
        point.reviewed = true
    }

    /// A box for a ball placed on the full frame: the size of the balls on
    /// the frames around it (up to 3 each way within 15), else of the rally.
    static func placedBox(at centre: CGPoint, in rally: TrackedRally, frame i: Int) -> CGRect {
        let visible = { (k: Int) -> TrackCandidate? in
            let p = rally.points[k]
            return p.state == .visible ? p.box : nil
        }
        let before = stride(from: i - 1, through: max(0, i - 15), by: -1).compactMap(visible).prefix(3)
        let after = (min(i + 1, rally.points.count)..<min(rally.points.count, i + 16)).compactMap(visible).prefix(3)
        var near = Array(before) + Array(after)
        if near.isEmpty { near = rally.points.compactMap { $0.state == .visible ? $0.box : nil } }
        let w = near.isEmpty ? 0.02 : near.map(\.w).reduce(0, +) / Double(near.count)
        let h = near.isEmpty ? 0.035 : near.map(\.h).reduce(0, +) / Double(near.count)
        return CGRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h)
    }

    // MARK: - The crop

    /// The crop shows this many box widths across.
    static let cropBoxes: CGFloat = 5
    /// …but never fewer pixels than this (a far ball is a few pixels).
    static let minCropPixels: CGFloat = 72

    /// The crop's side in image pixels for a box (Vision-normalised).
    static func cropSide(for box: CGRect, in size: CGSize) -> CGFloat {
        let side = max(box.width * size.width, box.height * size.height)
        return min(max(side * cropBoxes, minCropPixels), min(size.width, size.height))
    }

    /// The box after moving the picture by `offset` image pixels (the ball's
    /// centre is that far from the box's) and sizing it by `scale`.
    static func adjusted(_ box: CGRect, offset: CGSize, scale: CGFloat, in size: CGSize) -> CGRect {
        let w = box.width * scale, h = box.height * scale
        let cx = box.midX + offset.width / size.width
        let cy = box.midY - offset.height / size.height   // pixels are top-down, Vision bottom-up
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

/// Frames for review, read from a video at their exact times and kept for a
/// while so going back and forth doesn't read them again; the next few are
/// read ahead.
final class ReviewFrames: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let lock = NSLock()
    private var cache: [Int64: CGImage] = [:]
    private var order: [Int64] = []
    private static let keep = 40

    init(video: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
    }

    private static func key(_ t: Double) -> Int64 { Int64((t * 1_000_000).rounded()) }

    func image(at time: Double) async -> CGImage? {
        let key = Self.key(time)
        if let hit = lock.withLock({ cache[key] }) { return hit }
        // Just after the frame starts: a time rounded a hair early returns
        // the frame before it.
        guard let image = try? await generator.image(at: CMTime(seconds: time + 0.0001, preferredTimescale: 600_000)).image
        else { return nil }
        lock.withLock {
            if cache[key] == nil { order.append(key) }
            cache[key] = image
            while order.count > Self.keep { cache[order.removeFirst()] = nil }
        }
        return image
    }

    /// Read these ahead, in the background.
    func prefetch(_ times: [Double]) {
        Task.detached(priority: .utility) { [self] in
            for t in times { _ = await image(at: t) }
        }
    }
}

/// Where annotation review reads and saves frames: the phone's synced
/// rallies, or a Mac project's sessions.
@MainActor
protocol ReviewStore: AnyObject {
    func reviewItems(_ kind: AnnotationReview.Kind) -> [AnnotationReview.Item]
    /// The rally an item is a frame of, as it is now.
    func rally(of item: AnnotationReview.Item) -> TrackedRally?
    /// Change the frame and save its rally; the frame as it was, for going back.
    @discardableResult
    func review(_ item: AnnotationReview.Item, _ change: (inout TrackPoint) -> Void) -> TrackPoint?
    /// The video to read the item's frame from (downloading it if need be).
    func videoFile(of item: AnnotationReview.Item) async throws -> URL
    func videoName(of item: AnnotationReview.Item) -> String
}

/// Walks a fixed list of frames: loads each one's picture, reads ahead, and
/// keeps what was decided for going back.
@MainActor
@Observable
final class ReviewWalk {
    let store: any ReviewStore
    let items: [AnnotationReview.Item]
    private(set) var at = 0
    private(set) var image: CGImage?
    private(set) var failure: String?
    private var undo: [(item: AnnotationReview.Item, point: TrackPoint)] = []
    @ObservationIgnored private var frames: [String: ReviewFrames] = [:]

    init(store: any ReviewStore, kind: AnnotationReview.Kind) {
        self.store = store
        items = store.reviewItems(kind)
    }

    var item: AnnotationReview.Item? { items.indices.contains(at) ? items[at] : nil }
    var point: TrackPoint? { item.flatMap { i in store.rally(of: i)?.points[safe: i.index] } }
    var rally: TrackedRally? { item.flatMap { store.rally(of: $0) } }
    var left: Int { max(0, items.count - at) }
    var canGoBack: Bool { !undo.isEmpty }

    func load() async {
        image = nil
        failure = nil
        guard let item, let point else { return }
        do {
            let reader: ReviewFrames
            if let r = frames[item.video] {
                reader = r
            } else {
                reader = ReviewFrames(video: try await store.videoFile(of: item))
                frames[item.video] = reader
            }
            let shown = item
            let picture = await reader.image(at: point.time)
            guard shown == self.item else { return }
            image = picture
            if picture == nil { failure = "Couldn't read this frame." }
            // The next few of the same video.
            let ahead = items[(at + 1)...].prefix(6).filter { $0.video == item.video }
                .compactMap { i in store.rally(of: i)?.points[safe: i.index]?.time }
            reader.prefetch(ahead)
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Decide this frame and go on.
    func decide(_ change: (inout TrackPoint) -> Void) async {
        guard let item, let before = store.review(item, change) else { return }
        undo.append((item, before))
        at += 1
        await load()
    }

    /// Undo the last decision and show that frame again.
    func back() async {
        guard let last = undo.popLast() else { return }
        store.review(last.item) { $0 = last.point }
        at = items.firstIndex(of: last.item) ?? max(0, at - 1)
        await load()
    }
}
