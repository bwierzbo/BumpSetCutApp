//
//  ClipEncoder.swift
//  Labeler
//
//  A stretch of a phone video re-encoded small enough to upload: H.264 at
//  30 frames a second (RallyLab reads frames 1/30 s apart whatever the
//  rate), fitted inside 1280×1280 so portrait stays portrait, about 2 Mbit/s,
//  no sound, the index at the front so it streams. Five minutes is ~75 MB.
//

import AVFoundation
import CoreMedia

enum ClipEncoder {

    enum Failure: LocalizedError {
        case noVideo, cantRead, cantWrite(String)
        var errorDescription: String? {
            switch self {
            case .noVideo: return "That file has no video track."
            case .cantRead: return "Couldn't read the video."
            case .cantWrite(let why): return "Couldn't write the clip: \(why)"
            }
        }
    }

    static let longSide: CGFloat = 1280
    /// HEVC (the phone's hardware encoder) at 4 Mbps: grainy indoor footage
    /// fell apart at 2 Mbps H.264, and this copy is what the Mac labels from.
    static let bitRate = 4_000_000
    static let frameRate = 30.0

    /// Encode `length` seconds from `start` of `source` into `output`.
    /// Returns the clip's duration; reports progress 0–1.
    static func encode(_ source: URL, from start: Double, length: Double, to output: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (natural, transform, total) = try await (track.load(.naturalSize), track.load(.preferredTransform), asset.load(.duration))
        let begin = max(0, min(start, total.seconds))
        let span = max(0, min(length, total.seconds - begin))
        guard span > 0 else { throw Failure.cantRead }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: begin, preferredTimescale: 600),
                                       duration: CMTime(seconds: span, preferredTimescale: 600))
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange])
        readerOutput.alwaysCopiesSampleData = false
        reader.add(readerOutput)

        // Stored size scaled to fit; the rotation travels as the track's transform.
        let scale = min(1, longSide / max(abs(natural.width), abs(natural.height)))
        let width = Int((abs(natural.width) * scale / 2).rounded()) * 2
        let height = Int((abs(natural.height) * scale / 2).rounded()) * 2
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: Int(frameRate * 2),
            ],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)

        guard reader.startReading() else { throw Failure.cantRead }
        guard writer.startWriting() else { throw Failure.cantWrite(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)

        let step = 1 / frameRate
        var lastKept = -Double.infinity
        var written = 0.0
        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds - begin
            // About 30 a second: a 60 fps video keeps every other frame.
            guard t - lastKept >= step - 0.004 else { continue }
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            guard adaptor.append(pixels, withPresentationTime: CMTime(seconds: max(0, t), preferredTimescale: 600)) else {
                reader.cancelReading()
                throw Failure.cantWrite(writer.error?.localizedDescription ?? "append failed")
            }
            lastKept = t
            written = t
            progress(min(1, t / span))
        }
        input.markAsFinished()
        if reader.status == .failed { writer.cancelWriting(); throw Failure.cantRead }
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.cantWrite(writer.error?.localizedDescription ?? "unknown") }
        return written + step
    }
}
