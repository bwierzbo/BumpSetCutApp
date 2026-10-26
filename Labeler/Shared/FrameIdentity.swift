//
//  FrameIdentity.swift
//  Labeler/Shared — compiled by RallyLab (macOS) and the Labeler iPhone app
//
//  Which frames a video has, as the frames themselves say: every presentation time from
//  the video track's sample cursor, and a digest of that list. A Stage 1 event is a
//  frame of the ORIGINAL recording; a copy on another device may stand in for it only
//  when its frame times reproduce the original's digest — a re-encoded copy whose
//  timestamps were kept passes, one that was snapped to a grid, trimmed or dropped frames
//  does not. Nothing here rounds a time or substitutes a frame.
//

import AVFoundation
import CryptoKit
import Foundation

enum FrameIdentity {
    /// Presentation times (seconds) from `start` to `end`, every `step`-th frame of `track`, in
    /// presentation order; nil when the track provides no cursor or the range is empty. The request
    /// is a hair after `start` (seconds round), so ask from before the first frame to include it.
    static func frameTimes(track videoTrack: AVAssetTrack, step: Int, start: Double, end: Double) -> [Double]? {
        guard end > start, let cursor = videoTrack.makeSampleCursor(presentationTimeStamp: CMTime(seconds: start + 0.0001, preferredTimescale: 600_000))
        else { return nil }
        var times: [Double] = []
        while cursor.presentationTimeStamp.seconds <= end {
            times.append(cursor.presentationTimeStamp.seconds)
            if cursor.stepInPresentationOrder(byCount: Int64(step)) != Int64(step) { break }
        }
        return times
    }

    /// Every frame's presentation time of the video at `url` (a local file; a streamed item offers no cursor).
    static func allFrameTimes(of url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EventReview.Failure.videoUnreadable("no video track") }
        let duration = try await asset.load(.duration).seconds
        guard let times = frameTimes(track: track, step: 1, start: -1, end: duration) else { throw EventReview.Failure.videoUnreadable("no sample cursor") }
        return times
    }

    /// The video track's nominal frame rate and the asset's duration.
    static func videoFacts(_ url: URL) async throws -> (frameRate: Double, duration: Double) {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EventReview.Failure.videoUnreadable("no video track") }
            let rate = Double(try await track.load(.nominalFrameRate))
            guard rate > 0, duration > 0 else { throw EventReview.Failure.videoUnreadable("frame rate \(rate), duration \(duration)") }
            return (rate, duration)
        } catch let failure as EventReview.Failure { throw failure } catch { throw EventReview.Failure.videoUnreadable(error.localizedDescription) }
    }

    /// SHA-256 over the frame times in microseconds, one per line: the same frames in the same order give
    /// the same digest on any device; one frame more, fewer or moved gives another.
    static func digest(of times: [Double]) -> String {
        var hasher = SHA256()
        for t in times {
            let micros = Int64((t * 1_000_000).rounded())
            hasher.update(data: Data("\(micros)\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a copy's frames may stand for the original's: same count and every time within half a
    /// microsecond, which is the digest's own resolution.
    static func matches(copy: [Double], original digest: String) -> Bool {
        self.digest(of: copy) == digest
    }
}

extension FrameClock {
    /// The digest of these frame times (`FrameIdentity.digest`).
    var digest: String { FrameIdentity.digest(of: times) }
}
