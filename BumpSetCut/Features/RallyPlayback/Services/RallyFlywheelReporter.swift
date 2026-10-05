import Foundation

// MARK: - Rally Flywheel Reporter

/// The rally player's line to the data flywheel (opt-in training-data
/// contributions). Injected so the view model doesn't reach for singletons;
/// `.live` forwards to AppSettings and FlywheelCaptureService.
@MainActor
struct RallyFlywheelReporter {
    /// Whether the user opted into contributing training data.
    var isEnabled: () -> Bool
    /// How many rallies of a video the user has reported.
    var reportedCount: (_ videoId: UUID) -> Int
    var markReported: (_ videoId: UUID, _ rallyIndex: Int) -> Void
    var stageCorrection: (_ videoId: UUID, _ rallyIndex: Int, _ segment: RallySegment,
                          _ trigger: FlywheelTrigger, _ reason: String?, _ originalURL: URL) async -> Void

    static let live = RallyFlywheelReporter(
        isEnabled: { AppSettings.shared.enableDataFlywheel },
        reportedCount: { FlywheelCaptureService.shared.reportedCount(videoId: $0) },
        markReported: { FlywheelCaptureService.shared.markRallyReported(videoId: $0, rallyIndex: $1) },
        stageCorrection: { videoId, rallyIndex, segment, trigger, reason, originalURL in
            await FlywheelCaptureService.shared.stageCorrection(
                videoId: videoId, rallyIndex: rallyIndex, segment: segment,
                trigger: trigger, reason: reason, originalURL: originalURL
            )
        }
    )
}
