//
//  PlayerVisionExtractor.swift
//  RallyLab
//
//  Decodes the frames of a recording's intervals with AVAssetReader at their
//  presentation timestamps, picks one frame per sampling tick (the first decoded
//  frame at or after `start + k / hz`, never the same frame twice), and runs Apple
//  Vision on it — VNDetectHumanRectanglesRequest (revision 2, full body) and
//  VNDetectHumanBodyPoseRequest (revision 1, 19 joints, several people) — with the
//  orientation that turns the stored frame upright (VideoFrameGeometry, as the ball
//  pipeline does when `applyVideoRotation` is on), so every coordinate is in the same
//  upright, Vision-normalised space as `FrameEvidence`. Never on the main actor: the
//  caller runs it from a detached task. Nothing is cached and no model is bundled —
//  Vision's people models are part of macOS.
//

import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Vision

enum PlayerVisionExtractor {
    /// What one analysed (or deliberately skipped) frame produced, before tracking.
    struct RawFrame: Sendable {
        var t: Double
        var interval: String
        /// nil when it ran; "cut" / "time_break" when the frame lies in excluded time.
        var skipped: String?
        var boxes: [(PlayerFeatures.Box, Double)]
        var poses: [PlayerFeatures.Pose]
        var rectFailed: Bool
        var poseFailed: Bool
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

    static let visionJoints: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftEye, .rightEye, .leftEar, .rightEar,
        .neck, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
        .leftWrist, .rightWrist, .root, .leftHip, .rightHip,
        .leftKnee, .rightKnee, .leftAnkle, .rightAnkle,
    ]

    static var detectorDescription: [String: String] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return ["framework": "Apple Vision (system framework; no weights bundled or redistributed)",
                "os": "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(ProcessInfo.processInfo.operatingSystemVersionString))",
                "rectangles": "VNDetectHumanRectanglesRequest revision \(VNDetectHumanRectanglesRequestRevision2), upperBodyOnly false",
                "pose": "VNDetectHumanBodyPoseRequest revision \(VNDetectHumanBodyPoseRequestRevision1), 19 joints, joints with confidence 0 written null",
                "computeUnits": "Vision default (not pinned)",
                "license": "Apple SDK / macOS licence; models are not shipped with or extracted by this tool"]
    }

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

    private static func pose(_ o: VNHumanBodyPoseObservation) -> PlayerFeatures.Pose {
        let points = (try? o.recognizedPoints(.all)) ?? [:]
        let joints: [PlayerFeatures.Joint?] = visionJoints.map { name in
            guard let p = points[name], p.confidence > 0 else { return nil }
            return PlayerFeatures.Joint(x: Double(p.location.x), y: Double(p.location.y), c: Double(p.confidence))
        }
        return PlayerFeatures.Pose(conf: Double(o.confidence), joints: joints)
    }

    /// Analyse one interval of `url`. `excluded(t)` names why a frame must not be analysed (cut, time break), nil when it may be;
    /// `wantsImage(i)` asks for the upright image of the i-th sampled frame (overlays).
    static func run(url: URL, facts: FileFacts, interval: PlayerFeatures.Interval, hz: Double,
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
                frames.append(RawFrame(t: t, interval: interval.name, skipped: why, boxes: [], poses: [], rectFailed: false, poseFailed: false,
                                       thumb: [], ms: [:], image: nil))
                continue
            }
            guard let pix = CMSampleBufferGetImageBuffer(sample) else { continue }
            var ms: [String: Double] = [:]
            let c0 = DispatchTime.now().uptimeNanoseconds
            let thumb = lumaThumb(pix)
            ms["thumb"] = Double(DispatchTime.now().uptimeNanoseconds - c0) / 1e6

            let handler = VNImageRequestHandler(cvPixelBuffer: pix, orientation: facts.orientation, options: [:])
            let rect = VNDetectHumanRectanglesRequest()
            rect.revision = VNDetectHumanRectanglesRequestRevision2
            rect.upperBodyOnly = false
            let r0 = DispatchTime.now().uptimeNanoseconds
            var rectFailed = false
            do { try handler.perform([rect]) } catch { rectFailed = true }
            ms["rect"] = Double(DispatchTime.now().uptimeNanoseconds - r0) / 1e6
            let boxes: [(PlayerFeatures.Box, Double)] = (rect.results ?? []).map { o in
                let b = o.boundingBox
                return (PlayerFeatures.Box(x: Double(b.minX), y: Double(b.minY), w: Double(b.width), h: Double(b.height)), Double(o.confidence))
            }

            let poseRequest = VNDetectHumanBodyPoseRequest()
            poseRequest.revision = VNDetectHumanBodyPoseRequestRevision1
            let p0 = DispatchTime.now().uptimeNanoseconds
            var poseFailed = false
            do { try handler.perform([poseRequest]) } catch { poseFailed = true }
            ms["pose"] = Double(DispatchTime.now().uptimeNanoseconds - p0) / 1e6
            let poses = (poseRequest.results ?? []).map(pose)

            var image: CGImage?
            if wantsImage(sampledIndex) {
                let ci = CIImage(cvPixelBuffer: pix).oriented(facts.orientation)
                image = ciContext.createCGImage(ci, from: ci.extent)
            }
            frames.append(RawFrame(t: t, interval: interval.name, skipped: nil, boxes: boxes, poses: poses, rectFailed: rectFailed,
                                   poseFailed: poseFailed, thumb: thumb, ms: ms, image: image))
        }
        if reader.status == .failed { throw ExtractError.readerFailed(url, reader.error?.localizedDescription ?? "unknown") }
        return frames
    }
}
