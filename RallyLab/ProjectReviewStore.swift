//
//  ProjectReviewStore.swift
//  RallyLab
//
//  Annotation review on the Mac reads and saves the project's sessions'
//  tracked rallies (keyed by session name), and lets the Track tab know
//  when a rally it has open changed.
//

import AVFoundation
import Foundation

@MainActor
final class ProjectReviewStore: ReviewStore {
    let sampler: SamplerModel
    let tracker: TrackLabelModel

    init(sampler: SamplerModel, tracker: TrackLabelModel) {
        self.sampler = sampler
        self.tracker = tracker
    }

    private var rallies: [(video: String, rally: TrackedRally)] {
        sampler.sessions.flatMap { s in (s.tracks ?? []).map { (s.name, $0) } }
    }

    var progress: (reviewed: Int, total: Int) { AnnotationReview.progress(rallies.map(\.rally)) }

    func reviewItems(_ kinds: Set<AnnotationReview.Kind>) -> [AnnotationReview.Item] {
        AnnotationReview.items(rallies, kinds: kinds)
    }

    func rally(of item: AnnotationReview.Item) -> TrackedRally? {
        sampler.sessions.first { $0.name == item.video }?.tracks?.first { $0.id == item.track }
    }

    @discardableResult
    func review(_ item: AnnotationReview.Item, _ change: (inout TrackPoint) -> Void) -> TrackPoint? {
        guard var tracks = sampler.sessions.first(where: { $0.name == item.video })?.tracks,
              let r = tracks.firstIndex(where: { $0.id == item.track }), tracks[r].points.indices.contains(item.index) else { return nil }
        let before = tracks[r].points[item.index]
        change(&tracks[r].points[item.index])
        sampler.setTracks(tracks, session: item.video)
        tracker.reloadRallies(session: item.video)
        return before
    }

    func videoFile(of item: AnnotationReview.Item) async throws -> URL {
        guard let path = sampler.sessions.first(where: { $0.name == item.video })?.sourcePath,
              FileManager.default.fileExists(atPath: path) else { throw CocoaError(.fileNoSuchFile) }
        return URL(fileURLWithPath: path)
    }

    func videoName(of item: AnnotationReview.Item) -> String { item.video }

    func claim(_ track: UUID) async -> Bool {
        // Not signed in to the phone side: nobody else to clash with.
        (try? await LabelingClient.shared.reviewClaim(track)) ?? true
    }

    // MARK: - Fitting boxes before review

    /// Fit the boxes of rallies finished since the last time (here or on the
    /// phone), save them, and remember they're done. True if any changed.
    func fitNewRallies() async -> Bool {
        // Taken first: a rally finished while fitting waits for next time.
        let done = sampler.sessions.map { s in (s.name, (s.tracks ?? []).filter { $0.done && !(s.fittedTracks ?? []).contains($0.id) }.map(\.id)) }
        guard done.contains(where: { !$0.1.isEmpty }) else { return false }
        let fitted = await fittedBoxes(onlyNew: true) { _, _ in }
        apply(fitted)
        for (name, ids) in done where !ids.isEmpty { sampler.markFitted(ids, session: name) }
        return !fitted.isEmpty
    }

    /// Tightened boxes (see BoxFitter) for every unreviewed ball in the
    /// project's finished rallies (`onlyNew`: rallies not fitted before), by
    /// session, rally and frame — not saved.
    func fittedBoxes(onlyNew: Bool = false, progress: @escaping (Int, Int) -> Void) async -> [String: [UUID: [Int: CGRect]]] {
        let work = sampler.sessions.compactMap { s -> (VideoSession, [TrackedRally])? in
            let rallies = (s.tracks ?? []).filter { r in
                r.done && r.points.contains { $0.state == .visible && !$0.reviewed }
                    && !(onlyNew && (s.fittedTracks ?? []).contains(r.id))
            }
            return rallies.isEmpty || !FileManager.default.fileExists(atPath: s.sourcePath) ? nil : (s, rallies)
        }
        let total = work.reduce(0) { $0 + $1.1.reduce(0) { $0 + $1.points.count } }
        var done = 0
        var out: [String: [UUID: [Int: CGRect]]] = [:]
        for (session, rallies) in work {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: session.sourcePath)))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            for rally in rallies {
                // Frames in grey, read once each, kept while they're neighbours.
                var grays: [Int: BoxFitter.Gray] = [:]
                let reach = BoxFitter.backgroundOffsets.map(abs).max() ?? 6
                var fitted: [Int: CGRect] = [:]
                for (i, p) in rally.points.enumerated() {
                    defer { done += 1; progress(done, total) }
                    guard p.state == .visible, !p.reviewed, let box = p.box?.rect else { continue }
                    for k in max(0, i - reach)...min(rally.points.count - 1, i + reach) where grays[k] == nil {
                        let t = CMTime(seconds: rally.points[k].time + 0.0001, preferredTimescale: 600_000)
                        if let image = try? await generator.image(at: t).image { grays[k] = BoxFitter.Gray(image) }
                    }
                    for k in grays.keys where k < i - reach { grays[k] = nil }
                    guard let frame = grays[i] else { continue }
                    let court = BoxFitter.backgroundOffsets.compactMap { grays[i + $0] }
                    if let box = BoxFitter.fit(box, frame: frame, court: court) { fitted[i] = box }
                }
                if !fitted.isEmpty { out[session.name, default: [:]][rally.id] = fitted }
            }
        }
        return out
    }

    /// Put fitted boxes in (each ball's box replaced; still to review).
    func apply(_ fitted: [String: [UUID: [Int: CGRect]]]) {
        for (name, byRally) in fitted {
            guard var tracks = sampler.sessions.first(where: { $0.name == name })?.tracks else { continue }
            for r in tracks.indices {
                guard let boxes = byRally[tracks[r].id] else { continue }
                for (i, rect) in boxes where tracks[r].points.indices.contains(i) && !tracks[r].points[i].reviewed {
                    let confidence = tracks[r].points[i].box?.confidence ?? 1
                    tracks[r].points[i].box = TrackCandidate(rect: rect, confidence: confidence)
                }
            }
            sampler.setTracks(tracks, session: name)
            tracker.reloadRallies(session: name)
        }
    }
}
