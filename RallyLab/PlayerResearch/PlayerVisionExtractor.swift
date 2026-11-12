//
//  PlayerVisionExtractor.swift
//  RallyLab
//
//  Decodes the frames of a recording's intervals with AVAssetReader at their
//  presentation timestamps, picks one frame per sampling tick (the first decoded
//  frame at or after `start + k / hz`, never the same frame twice), turns it upright
//  with the orientation the ball pipeline uses (VideoFrameGeometry, as with
//  `applyVideoRotation`), and hands it to a PlayerDetector (Apple Vision, or the
//  research RTMDet + RTMPose models) through the chosen PlayerTiling — so every
//  coordinate is in the same upright, Vision-normalised space as `FrameEvidence`.
//  Never on the main actor: the caller runs it from a detached task.
//

import AVFoundation
import CoreImage
import Foundation
import ImageIO

enum PlayerVisionExtractor {
    /// What one analysed (or deliberately skipped) frame produced, before tracking.
    struct RawFrame: Sendable {
        var t: Double
        var interval: String
        /// nil when it ran; "cut" / "time_break" when the frame lies in excluded time.
        var skipped: String?
        var detections: PlayerDetections
        /// 32×18 luminance, 0–1, row-major; empty when skipped.
        var thumb: [Double]
        var ms: [String: Double]
        /// The upright frame, only on frames chosen for an overlay.
        var image: CGImage?
    }

    struct FileFacts: Sendable {
        var orientation: CGImagePropertyOrientation
        var uprightWidth: Int
        var uprightHeight: Int
        var nominalFrameRate: Double
        var durationSec: Double
    }

    enum ExtractError: LocalizedError {
        case noVideoTrack(URL)
        case readerFailed(URL, String)
        var errorDescription: String? {
            switch self {
            case .noVideoTrack(let u): return "\(u.lastPathComponent) has no video track."
            case .readerFailed(let u, let why): return "Decoding \(u.lastPathComponent) failed: \(why)"
            }
        }
    }

    static let thumbWidth = 32, thumbHeight = 18

    static func facts(of url: URL) async throws -> FileFacts {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExtractError.noVideoTrack(url) }
        let (size, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let duration = try await asset.load(.duration)
        let o = VideoFrameGeometry.orientation(for: transform)
        let swap = o == .left || o == .right
        return FileFacts(orientation: o, uprightWidth: Int(swap ? size.height : size.width), uprightHeight: Int(swap ? size.width : size.height),
                         nominalFrameRate: Double(fps), durationSec: duration.seconds)
    }

    /// The sampling rule, fed decoded frames in presentation order: a frame is taken when it is the first at or after
    /// the next target `start + k / hz` (within 1 µs); the target then moves past it, so no frame is taken twice and a
    /// dropped frame delays a sample rather than inventing one. Frames before `start` or from `end` on are never taken.
    struct TickSampler: Sendable {
        let start: Double, end: Double, hz: Double
        private var k = 0
        private let eps = 1e-6
        init(start: Double, end: Double, hz: Double) { self.start = start; self.end = end; self.hz = hz }
        mutating func accept(_ t: Double) -> Bool {
            guard t.isFinite, t >= start - eps, t < end, t >= start + Double(k) / hz - eps else { return false }
            while start + Double(k) / hz <= t + eps { k += 1 }
            return true
        }
    }

    /// Indices of `times` (presentation order) the sampler takes.
    static func sample(times: [Double], start: Double, end: Double, hz: Double) -> [Int] {
        var s = TickSampler(start: start, end: end, hz: hz)
        return times.indices.filter { s.accept(times[$0]) }
    }

    private static func lumaThumb(_ pix: CVPixelBuffer) -> [Double] {
        CVPixelBufferLockBaseAddress(pix, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pix, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pix, 0) else { return [] }
        let w = CVPixelBufferGetWidthOfPlane(pix, 0), h = CVPixelBufferGetHeightOfPlane(pix, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pix, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out: [Double] = []
        out.reserveCapacity(thumbWidth * thumbHeight)
        for ty in 0..<thumbHeight {
            for tx in 0..<thumbWidth {
                // Mean of a 4×4 patch at the cell centre.
                let cx = (tx * w + w / 2) / thumbWidth, cy = (ty * h + h / 2) / thumbHeight
                var sum = 0, n = 0
                for dy in -2..<2 { for dx in -2..<2 {
                    let x = min(max(cx + dx, 0), w - 1), y = min(max(cy + dy, 0), h - 1)
                    sum += Int(p[y * stride + x]); n += 1
                } }
                out.append(Double(sum) / Double(n) / 255)
            }
        }
        return out
    }

    /// Analyse one interval of `url` with `detector` through `tiling`. `excluded(t)` names why a frame must not be analysed
    /// (cut, time break), nil when it may be; `wantsImage(i)` asks for the upright image of the i-th sampled frame (overlays).
    static func run(url: URL, facts: FileFacts, interval: PlayerFeatures.Interval, hz: Double, detector: PlayerDetector, tiling: PlayerTiling,
                    excluded: (Double) -> String?, wantsImage: (Int) -> Bool) async throws -> [RawFrame] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExtractError.noVideoTrack(url) }
        let reader = try AVAssetReader(asset: asset)
        let lead = 0.5
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, interval.startSec - lead), preferredTimescale: 600),
                                       end: CMTime(seconds: interval.endSec, preferredTimescale: 600))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ExtractError.readerFailed(url, reader.error?.localizedDescription ?? "could not start") }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        var frames: [RawFrame] = []
        var sampler = TickSampler(start: interval.startSec, end: interval.endSec, hz: hz)
        var sampledIndex = 0
        while let sample = output.copyNextSampleBuffer() {
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if t.isFinite, t >= interval.endSec { break }
            guard sampler.accept(t) else { continue }
            defer { sampledIndex += 1 }
            if let why = excluded(t) {
                frames.append(RawFrame(t: t, interval: interval.name, skipped: why, detections: PlayerDetections(), thumb: [], ms: [:], image: nil))
                continue
            }
            guard let pix = CMSampleBufferGetImageBuffer(sample) else { continue }
            var ms: [String: Double] = [:]
            let c0 = DispatchTime.now().uptimeNanoseconds
            let thumb = lumaThumb(pix)
            ms["thumb"] = Double(DispatchTime.now().uptimeNanoseconds - c0) / 1e6

            let i0 = DispatchTime.now().uptimeNanoseconds
            let ci = CIImage(cvPixelBuffer: pix).oriented(facts.orientation)
            guard let upright = ciContext.createCGImage(ci, from: ci.extent) else { continue }
            ms["image"] = Double(DispatchTime.now().uptimeNanoseconds - i0) / 1e6
            let detections = tiling.detect(upright, with: detector)
            ms.merge(detections.ms) { a, _ in a }
            frames.append(RawFrame(t: t, interval: interval.name, skipped: nil, detections: detections, thumb: thumb, ms: ms,
                                   image: wantsImage(sampledIndex) ? upright : nil))
        }
        if reader.status == .failed { throw ExtractError.readerFailed(url, reader.error?.localizedDescription ?? "unknown") }
        return frames
    }
}
