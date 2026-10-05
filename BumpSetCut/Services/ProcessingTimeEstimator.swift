//
//  ProcessingTimeEstimator.swift
//  BumpSetCut
//
//  Estimates how long AI processing will take, self-calibrating from past runs.
//

import Foundation

/// Estimates processing wall-clock time, calibrated from completed runs.
///
/// Tracks an exponential moving average of `ratio = elapsedSeconds / videoSeconds`
/// (how many seconds of wall-clock time each second of source video costs). The
/// estimate self-corrects after every successful run, so the first guess matters
/// little once the device has processed a clip or two.
enum ProcessingTimeEstimator {
    private static let ratioKey = "processing_time_ratio_v1"
    /// Weight given to the newest sample in the moving average.
    private static let smoothing = 0.35
    /// Initial guess used before any run has been recorded.
    private static let defaultRatio: Double = 0.65

    /// Whether at least one real run has calibrated the estimate.
    static var isCalibrated: Bool {
        UserDefaults.standard.double(forKey: ratioKey) > 0
    }

    private static var ratio: Double {
        let stored = UserDefaults.standard.double(forKey: ratioKey)
        return stored > 0 ? stored : defaultRatio
    }

    /// Estimated wall-clock seconds to process `videoDuration` seconds of video.
    static func estimate(forVideoDuration videoDuration: Double) -> TimeInterval {
        guard videoDuration > 0 else { return 0 }
        return max(1, videoDuration * ratio)
    }

    /// Record a completed run to refine future estimates. No-op for trivially
    /// short runs (avoids skewing the average with noise).
    static func record(videoDuration: Double, elapsed: TimeInterval) {
        guard videoDuration > 0.5, elapsed > 0.5 else { return }
        let sample = elapsed / videoDuration
        let stored = UserDefaults.standard.double(forKey: ratioKey)
        let updated = stored > 0 ? (stored * (1 - smoothing) + sample * smoothing) : sample
        UserDefaults.standard.set(updated, forKey: ratioKey)
    }

    /// Approximate short duration, locale-aware: "~45s", "~2m", "~2m 30s"
    /// (English). Never shows less than ~5s.
    static func formatEstimate(_ seconds: TimeInterval, locale: Locale = .autoupdatingCurrent) -> String {
        let total = max(5, Int64(seconds.isFinite ? seconds.rounded() : 0))
        let duration = Duration.seconds(total)
            .formatted(.units(allowed: [.minutes, .seconds], width: .narrow).locale(locale))
        return String(localized: "~\(duration)", comment: "Approximate duration, e.g. ~2m 30s")
    }
}
