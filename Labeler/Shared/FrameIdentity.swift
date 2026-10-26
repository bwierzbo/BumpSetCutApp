//
//  FrameIdentity.swift
//  Labeler/Shared — compiled by RallyLab (macOS) and the Labeler iPhone app
//
//  Which frames a video has, as the frames themselves say: every frame's time on the
//  presentation timeline — the sample cursor's media times mapped through the track's edit
//  list, which is the timeline the player shows and seeks on — and a digest of that list.
//  (Media times alone are not it: iPhone H.264, trimmed cuts and every B-frame encode carry
//  an edit list, so their media times run ahead of what is shown.) A Stage 1 event is a
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

    /// Every frame of the video at `url` as the player presents it: each sample's media time mapped through
    /// the track's edit list onto the presentation timeline, ascending; samples outside every edit (cut off by a
    /// trim) are not frames of the video. A frame that starts before an edit but is still showing when it begins
    /// is presented from the edit's start. A local file only; a streamed item offers no cursor.
    static func allFrameTimes(of url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw EventReview.Failure.videoUnreadable("no video track") }
        let edits = try await track.load(.segments).filter { !$0.isEmpty }.map(\.timeMapping)
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: CMTime(seconds: -1_000_000, preferredTimescale: 600)) else {
            throw EventReview.Failure.videoUnreadable("no sample cursor")
        }
        var media: [Double] = []
        repeat { media.append(cursor.presentationTimeStamp.seconds) } while cursor.stepInPresentationOrder(byCount: 1) == 1
        return presentationTimes(media: media, edits: edits)
    }

    /// The presentation times of frames with these media times (ascending) under these edits. With no edit list
    /// the media times are the presentation times.
    static func presentationTimes(media: [Double], edits: [CMTimeMapping]) -> [Double] {
        let sorted = media.sorted()
        guard !edits.isEmpty else { return sorted }
        var out: [Double] = []
        for (i, m) in sorted.enumerated() {
            let next = i + 1 < sorted.count ? sorted[i + 1] : .infinity   // the frame shows until the next one starts
            for e in edits {
                let s0 = e.source.start.seconds, s1 = s0 + e.source.duration.seconds
                let t0 = e.target.start.seconds, rate = e.target.duration.seconds / max(e.source.duration.seconds, 1e-12)
                // Shown in this edit when its display interval [m, next) overlaps the edit's media range [s0, s1).
                guard m < s1 - 1e-9, next > s0 + 1e-9 else { continue }
                out.append(t0 + (max(m, s0) - s0) * rate)
            }
        }
        return out.sorted()
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

/// Whether a Stage 1 commit may be made on this device for this recording, and why not. Playback is always
/// allowed; a commit needs the recording to be reviewable here (not withheld, its project's list published)
/// and, on a device that plays a copy, the copy's frames to reproduce the original's digest.
struct CommitGate: Equatable {
    enum Verdict: Equatable {
        case allowed
        case withheld
        /// The Mac has not published the original's frame identity yet.
        case noDigestPublished
        /// The copy is streamed, not downloaded: no frames to compare.
        case copyNotDownloaded
        /// The copy's frames differ from the original's.
        case framesDiffer(copy: Int, original: String)
        /// The copy's frame times could not be read.
        case framesUnreadable(String)
    }

    let verdict: Verdict
    var allowed: Bool { verdict == .allowed }

    var reason: String {
        switch verdict {
        case .allowed: return "frames verified against the original"
        case .withheld: return "this recording is withheld: review is refused"
        case .noDigestPublished: return "the Mac has not published this recording's frame identity yet: playback only"
        case .copyNotDownloaded: return "download the copy for frame-exact review: playback only until then"
        case .framesDiffer(let n, _): return "the copy's \(n) frames do not match the original's: playback only, commits refused"
        case .framesUnreadable(let why): return "the copy's frames could not be read (\(why)): playback only"
        }
    }

    /// The decision from what is known: reviewable here, the published digest, and the copy's own frame times
    /// (nil when the copy is not downloaded; `.failure` when it could not be read).
    static func decide(reviewable: Bool, publishedDigest: String?, copyFrames: Result<[Double], Error>?) -> CommitGate {
        guard reviewable else { return CommitGate(verdict: .withheld) }
        guard let publishedDigest, !publishedDigest.isEmpty else { return CommitGate(verdict: .noDigestPublished) }
        guard let copyFrames else { return CommitGate(verdict: .copyNotDownloaded) }
        switch copyFrames {
        case .failure(let error): return CommitGate(verdict: .framesUnreadable(error.localizedDescription))
        case .success(let times):
            return FrameIdentity.matches(copy: times, original: publishedDigest) ? CommitGate(verdict: .allowed) : CommitGate(verdict: .framesDiffer(copy: times.count, original: publishedDigest))
        }
    }
}
