//
//  BallNetSampler.swift
//  BumpSetCut
//
//  Dense, fixed-stride ball + net detection pass for the deterministic Phase 1
//  pipeline. Ball detection runs on every processed frame; net detection runs on
//  the first K processed frames and is aggregated to a fixed net. Ball and net are
//  detected on the SAME raw pixel buffers, so they share one coordinate space
//  (Vision-normalized, origin bottom-left, raw frame).
//

import AVFoundation
import CoreMedia
import Foundation

enum BallNetSampler {

    /// Run the dense pass. `strideN` processes every Nth frame (1 = every frame).
    /// Cancellable via the surrounding Task.
    static func sample(
        url: URL,
        strideN: Int = 2,
        netSampleCount: Int = 12,
        ballConfidence: Float = 0.4,
        netConfidence: Float = 0.5,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (samples: [BallSample], net: DetectedNet?) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProcessingError.noVideoTrack
        }
        let durationSec = CMTimeGetSeconds(try await asset.load(.duration))

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)

        let ballDetector = YOLODetector()
        ballDetector.minConfidence = ballConfidence
        let netDetector = NetDetector()
        netDetector.minConfidence = netConfidence

        var samples: [BallSample] = []
        var netBoxes: [CGRect] = []
        var netConfs: [Double] = []
        var frameIndex = 0
        let stride = max(1, strideN)

        reader.startReading()
        defer { reader.cancelReading() }

        while reader.status == .reading,
              let sbuf = output.copyNextSampleBuffer(),
              let pix = CMSampleBufferGetImageBuffer(sbuf) {
            try Task.checkCancellation()
            frameIndex += 1
            guard frameIndex == 1 || frameIndex % stride == 0 else {
                CMSampleBufferInvalidate(sbuf)
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sbuf)
            let t = CMTimeGetSeconds(pts)

            // Ball detection — every processed frame (empty observations are kept so
            // the engine sees detection gaps).
            let ballDets = ballDetector.detect(in: pix, at: pts)
            samples.append(BallSample(
                frameIndex: frameIndex, time: t,
                observations: ballDets.map { BallObservation(rect: $0.bbox, confidence: $0.confidence) }
            ))

            // Net detection — first K processed frames, same raw space.
            if netBoxes.count < netSampleCount, let best = netDetector.detect(in: pix).first {
                netBoxes.append(best.rect)
                netConfs.append(Double(best.confidence))
            }

            if durationSec > 0 { progress?(min(1, t / durationSec)) }
            CMSampleBufferInvalidate(sbuf)
        }

        if reader.status == .failed { throw ProcessingError.assetReaderFailed(reader.error) }

        let net: DetectedNet? = netBoxes.isEmpty ? nil
            : DetectedNet(box: medianBox(netBoxes),
                          confidence: netConfs.isEmpty ? 0 : netConfs.reduce(0, +) / Double(netConfs.count))
        return (samples, net)
    }

    private static func medianBox(_ boxes: [CGRect]) -> CGRect {
        func med(_ xs: [CGFloat]) -> CGFloat {
            let s = xs.sorted(); let n = s.count
            return n == 0 ? 0 : (n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2)
        }
        return CGRect(x: med(boxes.map { $0.minX }), y: med(boxes.map { $0.minY }),
                      width: med(boxes.map { $0.width }), height: med(boxes.map { $0.height }))
    }
}
