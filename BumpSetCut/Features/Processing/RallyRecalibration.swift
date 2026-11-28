//
//  RallyRecalibration.swift
//  BumpSetCut
//
//  Recalibrate (D-044): a processed video's camera position, court and net are set again and its rallies are
//  decided again from the balls its run found — seconds, no frame read, no model run. The rallies are new ones,
//  so what was done to the old ones (trims and framing, saved / removed / favourite marks, the game's score)
//  starts over (D-045). A person's own rallies are kept, as on a reprocess. Favourite clips already
//  in the library are files of their own and stay; nothing posted is touched.
//

import Foundation

enum RallyRecalibration {

    enum Failure: LocalizedError {
        /// The video's run kept no ball positions: it was processed before they were kept, or Free Up Space
        /// has since cut the video down to its rallies.
        case noSavedBalls

        var errorDescription: String? {
            String(localized: "This video's ball positions weren't kept, so its rallies can't be found again without processing it.")
        }
    }

    /// Whether the video's run left the ball positions a recalibration needs.
    @MainActor
    static func isAvailable(for videoId: UUID, in metadataStore: MetadataStore) -> Bool {
        FileManager.default.fileExists(atPath: metadataStore.ballDetectionsFileURL(for: videoId).path)
    }

    /// The settings of the run whose rallies the video has, without its camera: default, or the higher
    /// sensitivity a video with no rallies was retried with. The saved balls were found under them.
    static func settings(of previous: ProcessingMetadata) -> ProcessorConfig {
        let sensitive = ProcessorConfig.highSensitivity
        let stored = previous.processingConfig
        return stored.parabolaMinR2 == sensitive.parabolaMinR2 && stored.minSegmentLength == sensitive.minSegmentLength
            ? sensitive : ProcessorConfig()
    }

    /// Decides the video's rallies again under its camera position and net as they are now, and puts them in
    /// place of the old ones with the old ones' edits cleared. Nothing changes when it throws before the
    /// answer is there (no saved balls, balls of another file, no rallies); the edits are cleared before the
    /// new rallies are saved, so a failure between the two leaves the old rallies without edits rather than
    /// new rallies under the old ones' edits.
    @MainActor
    @discardableResult
    static func run(videoId: UUID, videoURL: URL, mediaStore: MediaStore, processor: VideoProcessor = VideoProcessor(),
                    netSource: (any NetGeometrySource)? = nil) async throws -> ProcessingMetadata {
        let store = mediaStore.metadataStore
        guard let log = BallDetectionLog.load(from: store.ballDetectionsFileURL(for: videoId)) else { throw Failure.noSavedBalls }
        let video = mediaStore.getAllVideos().first { $0.id == videoId }

        var config = settings(of: try store.loadMetadata(for: videoId))
        config.applyCamera(video?.cameraSetup)
        processor.config = config
        processor.netSource = netSource ?? CalibrationNetSource(store: .app, videoId: videoId)

        let metadata = try await processor.decideRalliesAgain(from: log, forVideoAt: videoURL, videoId: videoId, persist: false)
        mediaStore.clearRallyEdits(videoId: videoId)
        try store.saveMetadata(metadata)
        if video != nil {
            mediaStore.markVideoAsProcessed(videoId: videoId, metadataFileSize: store.getMetadataFileSize(for: videoId) ?? 0)
        }
        return metadata
    }
}
