//
//  CalibrationBinding.swift
//  BumpSetCut
//
//  What a calibration is bound to, read from the video as it is now: the file's
//  fingerprint, the upright frame's size, the orientation that makes it upright, its length.
//

import AVFoundation
import Foundation
import ImageIO

enum CalibrationBindingError: LocalizedError {
    case noVideoTrack
    case unreadable
    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return String(localized: "This file has no video to mark the court on.")
        case .unreadable: return String(localized: "The video file can't be read.")
        }
    }
}

/// A video as the calibration editor reads it.
struct CalibrationVideo: Sendable {
    var binding: CourtNetCalibrationFile.Binding
    var frameDurationSec: Double

    static func load(recordingId: String, url: URL) async throws -> CalibrationVideo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CalibrationBindingError.noVideoTrack }
        let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let orientation = VideoFrameGeometry.orientation(for: transform)
        let sideways = orientation == .left || orientation == .right
        let (width, height) = sideways ? (size.height, size.width) : (size.width, size.height)
        let path = url.path
        guard let fingerprint = await Task.detached(priority: .userInitiated, operation: { FileFingerprint.read(atPath: path) }).value,
              width > 0, height > 0, duration > 0 else { throw CalibrationBindingError.unreadable }
        return CalibrationVideo(
            binding: .init(recordingId: recordingId, sourceFingerprint: fingerprint, frameWidth: Int(width.rounded()), frameHeight: Int(height.rounded()),
                           orientation: orientation.rawValue, durationSec: duration),
            frameDurationSec: rate > 0 ? 1 / Double(rate) : 1.0 / 30)
    }
}

extension CourtNetCalibrationStore {
    /// Where the app keeps a video's calibration: with its other sidecars, under the video's id, so it goes when
    /// the video is deleted and stays when the video is processed again.
    @MainActor static var app: CourtNetCalibrationStore { CourtNetCalibrationStore(directory: MetadataStore.shared.metadataDirectory) }

    /// Where a video's calibration stands, for a status line; nil when the video can't be read.
    func status(videoId: UUID, url: URL) async -> CalibrationStatus? {
        guard let video = try? await CalibrationVideo.load(recordingId: videoId.uuidString, url: url) else { return nil }
        switch lookup(for: video.binding) {
        case .none: return .notCalibrated
        case .usable(let file): return file.status(for: video.binding)
        case .stale, .unreadable: return .needsReview
        }
    }
}

extension CalibrationStatus {
    var title: LocalizedStringResource {
        switch self {
        case .notCalibrated: return "Not calibrated"
        case .draft: return "Draft"
        case .courtConfirmed: return "Court confirmed"
        case .netConfirmed: return "Net confirmed"
        case .bothConfirmed: return "Court and net confirmed"
        case .unsuitable: return "Not a stable court view"
        case .needsReview: return "Needs review"
        }
    }
}
