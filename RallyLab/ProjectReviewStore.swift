//
//  ProjectReviewStore.swift
//  RallyLab
//
//  Annotation review on the Mac reads and saves the project's sessions'
//  tracked rallies (keyed by session name), and lets the Track tab know
//  when a rally it has open changed.
//

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

    func reviewItems(_ kind: AnnotationReview.Kind) -> [AnnotationReview.Item] {
        AnnotationReview.items(rallies, kind: kind)
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
}
