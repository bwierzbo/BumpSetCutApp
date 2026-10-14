//
//  AnnotationReview.swift
//  RallyLab (macOS and iPhone)
//
//  Annotation review: every labeled frame of a finished rally is checked
//  once before it's used for training — of a pre-tracked one, every frame
//  the model isn't sure of, and short stretches where it lost the ball
//  (MachineLabels). A frame with a ball is shown as a
//  crop around its box — the box fixed in the middle; you move the picture
//  under it and size it, then approve — or call it hidden (covered here).
//  The frames the model is sure of (MachineLabels) are checked apart, a
//  page of crops at a time: pick out any that are wrong, approve the rest.
//  Where it lost the ball with the ball high up at either end, the ball
//  most likely went over the top of the picture: each such gap is checked
//  at once, and called hidden as a whole.
//  Hidden frames aren't reviewed: they count as checked. "No ball" sets a frame aside for a later pass on the
//  whole frame, to place the ball or call it hidden. "Not sure" sets a
//  frame aside in its own pass for a later look.
//
//  Several people can review at once: a rally is claimed by whoever reviews
//  it (others pass it over while the claim is fresh), and each decision is
//  saved as just that frame, so no one overwrites anyone.
//

import AVFoundation
import CoreGraphics
import Foundation
import Observation

enum AnnotationReview {

    /// Which check a frame needs.
    enum Kind {
        /// A ball with a box: checked on a crop.
        case crop
        /// Said "no ball" on its crop: the ball's found on the whole frame later.
        case noBall
        /// Set aside as not sure.
        case unsure
        /// A pre-tracked rally's sure frame (MachineLabels): checked a page
        /// at a time; one picked out as wrong is set aside as not sure.
        case sure
    }

    /// One frame to review: a frame of a rally of a video (keyed however the
    /// app keys its videos — the phone by id, the Mac by session name).
    struct Item: Hashable {
        let video: String
        let track: UUID
        let index: Int
    }

    /// A pre-tracked rally to check is a rally, before its frames are reviewed.
    struct RallyCheck: Hashable {
        let video: String
        let track: UUID
        let start: Double
        let end: Double
    }

    /// The pre-tracked rallies still to check, video by video in time order.
    static func rallyChecks(_ rallies: [(video: String, rally: TrackedRally)]) -> [RallyCheck] {
        rallies.filter { $0.rally.awaitsRallyCheck }
            .sorted { ($0.video, $0.rally.start) < ($1.video, $1.rally.start) }
            .map { RallyCheck(video: $0.video, track: $0.rally.id, start: $0.rally.start, end: $0.rally.end) }
    }

    /// A stretch where a pre-tracked rally lost the ball (MachineLabels.lost)
    /// and its arc went over the top of the picture: high up on both sides,
    /// and the curve through the balls either side above the top edge
    /// during the stretch.
    struct Gap: Hashable {
        let video: String
        let track: UUID
        let frames: ClosedRange<Int>
    }

    /// High up: the ball's centre in the top 40% of the picture, both sides.
    static let highUp = 0.6
    /// Balls each side of a gap the arc is fitted through.
    static let arcReach = 4

    /// The gaps to check as over the top, video by video in time order.
    static func offTop(_ rallies: [(video: String, rally: TrackedRally)]) -> [Gap] {
        rallies.filter { $0.rally.isForReview }
            .sorted { ($0.video, $0.rally.start) < ($1.video, $1.rally.start) }
            .flatMap { v -> [Gap] in
                let p = v.rally.points
                var runs: [ClosedRange<Int>] = []
                for i in MachineLabels.lost(v.rally).sorted() {
                    if let last = runs.last, last.upperBound == i - 1 { runs[runs.count - 1] = last.lowerBound...i } else { runs.append(i...i) }
                }
                return runs.compactMap { run in
                    guard let before = p[safe: run.lowerBound - 1], before.state == .visible, let a = before.box,
                          let after = p[safe: run.upperBound + 1], after.state == .visible, let b = after.box,
                          min(a.rect.midY, b.rect.midY) >= highUp else { return nil }
                    let around = (run.lowerBound - arcReach..<run.lowerBound).map { $0 } + (run.upperBound + 1...run.upperBound + arcReach).map { $0 }
                    let balls = around.compactMap { k in
                        p[safe: k].flatMap { $0.state == .visible ? $0.box.map { b in (p[k].time, Double(b.rect.midY)) } : nil }
                    }
                    let arc = TrackSolver.fit(balls)
                    guard run.contains(where: { arc(p[$0].time) > 1 }) else { return nil }
                    return Gap(video: v.video, track: v.rally.id, frames: run)
                }
            }
    }

    /// What `point` still needs, if anything. Frames the solver couldn't
    /// decide (not found, not yours) aren't labeled, so aren't reviewed.
    static func kind(of point: TrackPoint) -> Kind? {
        guard !point.isChecked else { return nil }
        if point.unsure { return .unsure }
        switch point.state {
        case .visible: return point.box == nil ? nil : .crop
        case .hidden: return nil
        case .unknown: return point.origin == .user ? .noBall : nil
        }
    }

    /// The frames of finished (or pre-tracked) rallies still needing `kind`,
    /// rally by rally, in frame order (neighbours look alike, so they go
    /// quickly). A pre-tracked rally's sure frames (MachineLabels) are only
    /// in `.sure`.
    static func items(_ rallies: [(video: String, rally: TrackedRally)], kinds: Set<Kind>) -> [Item] {
        rallies.filter { $0.rally.isForReview }
            .sorted { ($0.video, $0.rally.start) < ($1.video, $1.rally.start) }
            .flatMap { v in
                let trusted = MachineLabels.trusted(v.rally)
                let lost = kinds.contains(.noBall) ? MachineLabels.lost(v.rally) : []
                return v.rally.points.indices
                    .filter { i in
                        if lost.contains(i) { return true }
                        if trusted.contains(i) { return kinds.contains(.sure) }
                        return Self.kind(of: v.rally.points[i]).map(kinds.contains) ?? false
                    }
                    .map { Item(video: v.video, track: v.rally.id, index: $0) }
            }
    }

    /// Reviewed of all frames for people to check in finished (or
    /// pre-tracked) rallies, and how many of those rallies have every frame
    /// checked (sure frames included): complete, nothing left to review.
    static func progress(_ rallies: [TrackedRally]) -> Progress {
        var out = Progress(reviewed: 0, total: 0, ralliesDone: 0, rallies: 0)
        for r in rallies where r.isForReview {
            let trusted = MachineLabels.trusted(r), lost = MachineLabels.lost(r)
            let points = r.points.indices.filter { !trusted.contains($0) }.map { (r.points[$0], lost.contains($0)) }
                .filter { $0.0.isChecked || $0.1 || kind(of: $0.0) != nil }
            let reviewed = points.filter(\.0.isChecked).count
            out.reviewed += reviewed
            out.total += points.count
            out.rallies += 1
            if trusted.isEmpty && reviewed == points.count { out.ralliesDone += 1 }
        }
        return out
    }

    typealias Progress = (reviewed: Int, total: Int, ralliesDone: Int, rallies: Int)

    // MARK: - Decisions

    /// The ball is in `box` (Vision-normalised): checked.
    static func approve(_ point: inout TrackPoint, box: CGRect) {
        point.state = .visible
        point.origin = .user
        point.box = TrackCandidate(rect: box, confidence: 1)
        point.reviewed = true
        point.unsure = false
    }

    /// The box isn't on the ball: for the whole-frame pass, to find it there
    /// or call it hidden.
    static func noBall(_ point: inout TrackPoint) {
        point.state = .unknown
        point.origin = .user
        point.box = nil
        point.reviewed = false
        point.unsure = false
    }

    /// The ball can't be seen on this frame: checked.
    static func confirmHidden(_ point: inout TrackPoint) {
        point.state = .hidden
        point.origin = .user
        point.box = nil
        point.reviewed = true
        point.unsure = false
    }

    /// Not sure: set aside, as it is, for a later look.
    static func markUnsure(_ point: inout TrackPoint) {
        point.unsure = true
        point.reviewed = false
    }

    /// A box for a ball placed on the full frame: the size of the box you
    /// placed or sized on one of the last 3 frames (carried on as you go),
    /// else of the balls on the frames around it (up to 3 each way within
    /// 15), else of the rally.
    static func placedBox(at centre: CGPoint, in rally: TrackedRally, frame i: Int) -> CGRect {
        let yours = stride(from: i - 1, through: max(0, i - 3), by: -1).lazy.compactMap { k -> TrackCandidate? in
            let p = rally.points[k]
            return p.state == .visible && p.origin == .user ? p.box : nil
        }.first
        if let yours {
            return CGRect(x: centre.x - yours.w / 2, y: centre.y - yours.h / 2, width: yours.w, height: yours.h)
        }
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

    /// Where the ball most likely is on frame `i`, for Find the ball to start
    /// from: the curve through the balls around it — up to 3 each side within
    /// 15 frames, or with balls on one side only, the nearest 4 within 6
    /// (yours count, so each frame you place carries the next one) — moved
    /// onto a detector candidate within two balls of it, where there are
    /// candidates (the Mac). Nil with fewer than two balls to go on, or
    /// outside the picture.
    static func guessedBox(in rally: TrackedRally, frame i: Int) -> CGRect? {
        let p = rally.points
        func ball(_ k: Int) -> (k: Int, t: Double, box: CGRect)? {
            p[k].state == .visible ? p[k].box.map { (k, p[k].time, $0.rect) } : nil
        }
        let before = stride(from: i - 1, through: max(0, i - 15), by: -1).compactMap(ball).prefix(3)
        let after = (min(i + 1, p.count)..<min(p.count, i + 16)).compactMap(ball).prefix(3)
        let balls = !before.isEmpty && !after.isEmpty ? Array(before + after)
            : Array((before + after).filter { abs($0.k - i) <= 6 }.prefix(4))
        guard balls.count >= 2, let t = p[safe: i]?.time else { return nil }
        let fx = TrackSolver.fit(balls.map { ($0.t, Double($0.box.midX)) })
        let fy = TrackSolver.fit(balls.map { ($0.t, Double($0.box.midY)) })
        var centre = CGPoint(x: fx(t), y: fy(t))
        guard (0...1).contains(centre.x), (0...1).contains(centre.y) else { return nil }
        let width = balls.map(\.box.width).reduce(0, +) / CGFloat(balls.count)
        let near = (rally.candidates[safe: i] ?? []).map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
            .min { hypot($0.x - centre.x, ($0.y - centre.y) * 9 / 16) < hypot($1.x - centre.x, ($1.y - centre.y) * 9 / 16) }
        if let near, hypot(near.x - centre.x, (near.y - centre.y) * 9 / 16) <= max(width * 2, 0.01) { centre = near }
        return placedBox(at: centre, in: rally, frame: i)
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

    /// The ball's size in image pixels for a box: a square the box's
    /// shorter side across (a ball is round; a blurred ball's box runs
    /// along the streak, and its width across is the ball).
    static func ballSide(of box: CGRect, in size: CGSize) -> CGFloat {
        min(box.width * size.width, box.height * size.height)
    }

    /// The box after moving the picture by `offset` image pixels (the ball's
    /// centre is that far from the box's) and sizing it by `scale`: always a
    /// square in pixels, `ballSide` × `scale` across.
    static func adjusted(_ box: CGRect, offset: CGSize, scale: CGFloat, in size: CGSize) -> CGRect {
        let side = ballSide(of: box, in: size) * scale
        let w = side / size.width, h = side / size.height
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
    /// The file read (a newer copy of the video has another name).
    let video: URL
    private let lock = NSLock()
    private var cache: [Int64: CGImage] = [:]
    private var order: [Int64] = []
    private static let keep = 40

    init(video: URL) {
        self.video = video
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
        // An exact read can fail on a frame; the nearest within a quarter of
        // a 30 fps frame is the same one.
        var found = try? await generator.image(at: CMTime(seconds: time + 0.0001, preferredTimescale: 600_000)).image
        if found == nil {
            let near = AVAssetImageGenerator(asset: generator.asset)
            near.appliesPreferredTrackTransform = true
            near.requestedTimeToleranceBefore = CMTime(seconds: 0.25 / 30, preferredTimescale: 600_000)
            near.requestedTimeToleranceAfter = CMTime(seconds: 0.25 / 30, preferredTimescale: 600_000)
            found = try? await near.image(at: CMTime(seconds: time, preferredTimescale: 600_000)).image
        }
        guard let image = found else { return nil }
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
    func reviewItems(_ kinds: Set<AnnotationReview.Kind>) -> [AnnotationReview.Item]
    /// The rally an item is a frame of, as it is now.
    func rally(of item: AnnotationReview.Item) -> TrackedRally?
    /// Change the frame and save its rally; the frame as it was, for going back.
    @discardableResult
    func review(_ item: AnnotationReview.Item, _ change: (inout TrackPoint) -> Void) -> TrackPoint?
    /// A video's file (keyed as items key it), downloading it if need be.
    func videoFile(video: String) async throws -> URL
    func videoName(video: String) -> String
    /// Where to play a video from: the file, or streamed if it isn't here.
    func playbackURL(video: String) async throws -> URL
    /// Claim a rally for review; false when someone else is reviewing it.
    func claim(_ track: UUID) async -> Bool
    /// Pre-tracked rallies nobody has said are or aren't rallies yet.
    func rallyChecks() -> [AnnotationReview.RallyCheck]
    /// Where the ball most likely went over the top, to check (AnnotationReview.offTop).
    func offTopGaps() -> [AnnotationReview.Gap]
    /// Say whether a pre-tracked rally is a rally (nil takes it back).
    func setIsRally(_ isRally: Bool?, _ check: AnnotationReview.RallyCheck)
}

extension ReviewStore {
    /// Rallies someone else is reviewing right now (claims lapse after 3
    /// minutes without a decision). Empty when that can't be told.
    func heldByOthers() async -> Set<UUID> {
        Set((try? await LabelingClient.shared.reviewHeldByOthers()) ?? [])
    }

    /// Take these rallies over: they're yours to review, and whoever had them
    /// has their decisions on them refused from now on.
    func takeOver(_ tracks: Set<UUID>) async {
        for t in tracks { try? await LabelingClient.shared.reviewTakeOver(t) }
    }
}

/// Walks a fixed list of frames, one at a time or a page at a time (`pageSize`):
/// loads the pictures, reads ahead, and keeps what was decided for going back.
@MainActor
@Observable
final class ReviewWalk {
    let store: any ReviewStore
    let items: [AnnotationReview.Item]
    private(set) var at = 0
    private(set) var image: CGImage?
    private(set) var failure: String?
    /// Frames shown together and decided at once (nil: one at a time).
    let pageSize: Int?
    /// This page's frames that can be shown, with their pictures.
    private(set) var page: [(item: AnnotationReview.Item, image: CGImage)] = []
    /// Where the walk goes on from after this page.
    @ObservationIgnored private var pageEnd = 0
    /// Frames decided in this walk, a decision (one frame, or a page) at a
    /// time, in order, for going back.
    private var decided: [[AnnotationReview.Item]] = []
    /// Each decided frame as it was before this walk first decided it.
    private var original: [AnnotationReview.Item: TrackPoint] = [:]
    @ObservationIgnored private var frames: [String: ReviewFrames] = [:]

    init(store: any ReviewStore, kinds: Set<AnnotationReview.Kind>, pageSize: Int? = nil) {
        self.store = store
        self.pageSize = pageSize
        items = store.reviewItems(kinds)
    }

    var item: AnnotationReview.Item? { items.indices.contains(at) ? items[at] : nil }
    var point: TrackPoint? { item.flatMap { i in store.rally(of: i)?.points[safe: i.index] } }
    var rally: TrackedRally? { item.flatMap { store.rally(of: $0) } }
    var left: Int { max(0, items.count - at) }
    var canGoBack: Bool { !decided.isEmpty }
    /// This frame as it was before this walk decided it (nil if it hasn't).
    var originalPoint: TrackPoint? { item.flatMap { original[$0] } }

    /// Frames that couldn't be read in this walk, passed over.
    private(set) var unreadable = 0
    /// Frames of rallies someone else is reviewing, passed over.
    private(set) var othersFrames = 0
    @ObservationIgnored private var claimed: Set<UUID> = []
    @ObservationIgnored private var refused: Set<UUID> = []

    func load() async {
        if let pageSize { return await loadPage(pageSize) }
        image = nil
        failure = nil
        while let item, let point {
            let mine = await isMine(item.track)
            guard item == self.item else { return }
            // Someone else is on this rally: their frames are theirs.
            if !mine {
                othersFrames += 1
                at += 1
                continue
            }
            do {
                let shown = item
                let picture = try await picture(of: item, at: point.time)
                guard shown == self.item else { return }
                if let picture {
                    image = picture
                    prefetch(after: at)
                    return
                }
                // Can't be read: pass over it (it stays to review) and go on.
                unreadable += 1
                at += 1
            } catch {
                failure = error.localizedDescription
                return
            }
        }
    }

    /// The next `size` frames from here that can be shown, passing over
    /// those of rallies someone else is on and those that can't be read.
    private func loadPage(_ size: Int) async {
        page = []
        failure = nil
        var next = at, shown: [(item: AnnotationReview.Item, image: CGImage)] = []
        while shown.count < size, items.indices.contains(next) {
            let item = items[next]
            next += 1
            guard let point = store.rally(of: item)?.points[safe: item.index] else { continue }
            guard await isMine(item.track) else { othersFrames += 1; continue }
            do {
                if let picture = try await picture(of: item, at: point.time) { shown.append((item, picture)) } else { unreadable += 1 }
            } catch {
                failure = error.localizedDescription
                return
            }
        }
        pageEnd = next
        page = shown
        prefetch(after: next - 1, count: size)
    }

    /// Whether a rally's frames are this person's to review: claimed for
    /// them, or someone else is on it.
    private func isMine(_ track: UUID) async -> Bool {
        if !claimed.contains(track) && !refused.contains(track) {
            if await store.claim(track) { claimed.insert(track) } else { refused.insert(track) }
        }
        return claimed.contains(track)
    }

    /// A frame's picture (nil if it can't be read).
    private func picture(of item: AnnotationReview.Item, at time: Double) async throws -> CGImage? {
        // The video's current file: a newer copy replaces the old one (and
        // the old file goes), so a reader on it is made again.
        let file = try await store.videoFile(video: item.video)
        if frames[item.video]?.video != file { frames[item.video] = ReviewFrames(video: file) }
        return await frames[item.video]?.image(at: time)
    }

    /// Read ahead the next few frames after `index` of the same video.
    private func prefetch(after index: Int, count: Int = 6) {
        guard let item = items[safe: index], let reader = frames[item.video] else { return }
        let ahead = items[(index + 1)...].prefix(count).filter { $0.video == item.video }
            .compactMap { i in store.rally(of: i)?.points[safe: i.index]?.time }
        reader.prefetch(ahead)
    }

    /// Decide this frame and go on.
    func decide(_ change: (inout TrackPoint) -> Void) async {
        guard let item, let before = store.review(item, change) else { return }
        decided.append([item])
        if original[item] == nil { original[item] = before }
        at += 1
        await load()
    }

    /// Decide every frame of this page (`change` per frame) and go on to the next.
    func decidePage(_ change: (AnnotationReview.Item, inout TrackPoint) -> Void) async {
        guard !page.isEmpty else { return }
        var done: [AnnotationReview.Item] = []
        for (item, _) in page {
            guard let before = store.review(item, { change(item, &$0) }) else { continue }
            done.append(item)
            if original[item] == nil { original[item] = before }
        }
        decided.append(done)
        at = pageEnd
        await load()
    }

    /// The frame `offset` frames from this one in its rally, for a look
    /// around it (nil past the rally's ends or if it can't be read).
    func neighbourImage(_ offset: Int) async -> CGImage? {
        guard let item, let rally, let point = rally.points[safe: item.index + offset],
              let reader = frames[item.video] else { return nil }
        return await reader.image(at: point.time)
    }

    /// Leave this frame as it is, for later, and go on.
    func skip() async {
        guard item != nil else { return }
        at += 1
        await load()
    }

    /// Show the last frame (or page) decided again, with your answers on it:
    /// answering again replaces them, and moving on keeps them.
    func back() async {
        guard let last = decided.popLast(), let first = last.first else { return }
        at = items.firstIndex(of: first) ?? max(0, at - 1)
        await load()
    }
}
