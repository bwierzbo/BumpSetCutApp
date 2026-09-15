//
//  RallyTimelineViewModel.swift
//  BumpSetCut
//
//  Editing state for the rally timeline: view the whole video with detected
//  rallies as segments, add rallies the detector missed, delete false
//  positives, and drag segment edges. Saving writes rallySegments back to
//  ProcessingMetadata and remaps the index-keyed sidecars (trim adjustments,
//  review selections) so existing per-rally state survives the edit.
//

import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class RallyTimelineViewModel {

    // MARK: - Editable Segment

    struct EditableSegment: Identifiable, Equatable {
        let id: UUID
        var start: Double
        var end: Double
        let isManual: Bool
        /// Nil for segments created in this editing session.
        let source: RallySegment?

        var duration: Double { end - start }

        static func == (lhs: EditableSegment, rhs: EditableSegment) -> Bool {
            lhs.id == rhs.id && lhs.start == rhs.start && lhs.end == rhs.end && lhs.isManual == rhs.isManual
        }
    }

    // MARK: - Constants

    static let minSegmentDuration: Double = 1.0
    static let defaultNewSegmentDuration: Double = 10.0

    // MARK: - State

    private(set) var segments: [EditableSegment] = []
    var selectedSegmentID: UUID?
    var playhead: Double = 0

    let videoURL: URL
    let videoId: UUID
    private(set) var videoDuration: Double = 0
    private(set) var isLoaded = false
    private(set) var loadFailed = false

    private let metadataStore: MetadataStore
    private var originalMetadata: ProcessingMetadata?
    private var originalSegments: [EditableSegment] = []

    // MARK: - Init

    init(videoURL: URL, videoId: UUID, metadataStore: MetadataStore) {
        self.videoURL = videoURL
        self.videoId = videoId
        self.metadataStore = metadataStore
    }

    func load() async {
        do {
            let metadata = try metadataStore.loadMetadata(for: videoId)
            originalMetadata = metadata

            let asset = AVURLAsset(url: videoURL)
            videoDuration = try await CMTimeGetSeconds(asset.load(.duration))

            segments = metadata.rallySegments
                .map { EditableSegment(id: $0.id, start: $0.startTime, end: $0.endTime, isManual: $0.isManual, source: $0) }
                .sorted { $0.start < $1.start }
            originalSegments = segments
            playhead = segments.first?.start ?? 0
            isLoaded = true
        } catch {
            loadFailed = true
        }
    }

    // MARK: - Derived

    var hasChanges: Bool { segments != originalSegments }

    var selectedSegment: EditableSegment? {
        selectedSegmentID.flatMap { id in segments.first { $0.id == id } }
    }

    private func index(of id: UUID) -> Int? {
        segments.firstIndex { $0.id == id }
    }

    /// The free interval around `time` bounded by neighboring segments (and
    /// the video edges). Nil when `time` falls inside an existing segment.
    private func gap(around time: Double) -> (start: Double, end: Double)? {
        var gapStart = 0.0
        var gapEnd = videoDuration
        for segment in segments {
            if time >= segment.start && time <= segment.end { return nil }
            if segment.end <= time { gapStart = max(gapStart, segment.end) }
            if segment.start >= time { gapEnd = min(gapEnd, segment.start) }
        }
        return gapEnd - gapStart >= Self.minSegmentDuration ? (gapStart, gapEnd) : nil
    }

    /// Whether a new rally can be inserted at the current playhead.
    var canAddAtPlayhead: Bool { gap(around: playhead) != nil }

    // MARK: - Editing

    /// Insert a manual rally at the playhead, sized to the default duration
    /// but clipped to the surrounding gap. Returns the new segment's id.
    @discardableResult
    func addSegmentAtPlayhead() -> UUID? {
        guard let gap = gap(around: playhead) else { return nil }

        let half = Self.defaultNewSegmentDuration / 2
        var start = max(gap.start, playhead - half)
        var end = min(gap.end, start + Self.defaultNewSegmentDuration)
        start = max(gap.start, end - Self.defaultNewSegmentDuration)
        if end - start < Self.minSegmentDuration {
            end = min(gap.end, start + Self.minSegmentDuration)
        }

        let segment = EditableSegment(id: UUID(), start: start, end: end, isManual: true, source: nil)
        segments.append(segment)
        segments.sort { $0.start < $1.start }
        selectedSegmentID = segment.id
        return segment.id
    }

    func deleteSelected() {
        guard let id = selectedSegmentID, let index = index(of: id) else { return }
        segments.remove(at: index)
        selectedSegmentID = nil
    }

    /// Bounds within which the given segment's edges may be dragged:
    /// neighbor edges and the video edges.
    func dragBounds(for id: UUID) -> (min: Double, max: Double) {
        guard let index = index(of: id) else { return (0, videoDuration) }
        let lower = index > 0 ? segments[index - 1].end : 0
        let upper = index < segments.count - 1 ? segments[index + 1].start : videoDuration
        return (lower, upper)
    }

    func setStart(_ newStart: Double, for id: UUID) {
        guard let index = index(of: id) else { return }
        let bounds = dragBounds(for: id)
        let clamped = min(max(newStart, bounds.min), segments[index].end - Self.minSegmentDuration)
        segments[index].start = clamped
    }

    func setEnd(_ newEnd: Double, for id: UUID) {
        guard let index = index(of: id) else { return }
        let bounds = dragBounds(for: id)
        let clamped = max(min(newEnd, bounds.max), segments[index].start + Self.minSegmentDuration)
        segments[index].end = clamped
    }

    // MARK: - Save

    enum SaveError: Error {
        case noMetadata
        case writeFailed(Error)
    }

    /// Write the edited segments to ProcessingMetadata and remap the
    /// index-keyed sidecars so surviving rallies keep their trim framing and
    /// review selections.
    func save() throws {
        guard let metadata = originalMetadata else { throw SaveError.noMetadata }

        let sorted = segments.sorted { $0.start < $1.start }

        // Build the new RallySegments. A detected segment keeps its id and
        // detection stats; one the user re-timed is additionally flagged
        // manual (its boundaries are now human ground truth). New segments
        // carry neutral stats.
        let newRallySegments: [RallySegment] = sorted.map { edited in
            if let source = edited.source {
                let retimed = edited.start != source.startTime || edited.end != source.endTime
                return RallySegment(
                    id: source.id,
                    startTimeSeconds: edited.start,
                    endTimeSeconds: edited.end,
                    confidence: source.confidence,
                    quality: source.quality,
                    detectionCount: source.detectionCount,
                    averageTrajectoryLength: source.averageTrajectoryLength,
                    ballSizeTrend: source.ballSizeTrend,
                    isManual: source.isManual || retimed
                )
            } else {
                return RallySegment(
                    id: edited.id,
                    startTimeSeconds: edited.start,
                    endTimeSeconds: edited.end,
                    confidence: 1.0,
                    quality: 1.0,
                    detectionCount: 0,
                    averageTrajectoryLength: 0,
                    ballSizeTrend: nil,
                    isManual: true
                )
            }
        }

        // Old index (position in the stored metadata) → new index, by id.
        let oldIndexByID = Dictionary(uniqueKeysWithValues: metadata.rallySegments.enumerated().map { ($1.id, $0) })
        let newIndexByID = Dictionary(uniqueKeysWithValues: newRallySegments.enumerated().map { ($1.id, $0) })
        var oldToNew: [Int: Int] = [:]
        for (id, oldIndex) in oldIndexByID {
            if let newIndex = newIndexByID[id] { oldToNew[oldIndex] = newIndex }
        }

        // Segments whose boundaries changed: the new times are the truth, so
        // drop their before/after trim offsets but keep rotation/zoom/pan.
        let retimedNewIndices: Set<Int> = Set(sorted.enumerated().compactMap { newIndex, edited in
            guard let source = edited.source else { return nil }
            return (edited.start != source.startTime || edited.end != source.endTime) ? newIndex : nil
        })

        let oldAdjustments = metadataStore.loadTrimAdjustments(for: videoId)
        var newAdjustments: [Int: RallyTrimAdjustment] = [:]
        for (oldIndex, adjustment) in oldAdjustments {
            guard let newIndex = oldToNew[oldIndex] else { continue }
            var remapped = adjustment
            if retimedNewIndices.contains(newIndex) {
                remapped.before = 0
                remapped.after = 0
            }
            newAdjustments[newIndex] = remapped
        }

        let oldSelections = metadataStore.loadReviewSelections(for: videoId)
        let newSelections = RallyReviewSelections(
            saved: Set(oldSelections.saved.compactMap { oldToNew[$0] }),
            removed: Set(oldSelections.removed.compactMap { oldToNew[$0] }),
            favorited: Set(oldSelections.favorited.compactMap { oldToNew[$0] }),
            favoriteCollections: Dictionary(uniqueKeysWithValues:
                oldSelections.favoriteCollections.compactMap { old, name in oldToNew[old].map { ($0, name) } })
        )

        do {
            try metadataStore.saveMetadata(metadata.withRallySegments(newRallySegments))
            try metadataStore.saveTrimAdjustments(newAdjustments, for: videoId)
            try metadataStore.saveReviewSelections(newSelections, for: videoId)
        } catch {
            throw SaveError.writeFailed(error)
        }
    }
}
