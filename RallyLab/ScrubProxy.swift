//
//  ScrubProxy.swift
//  RallyLab
//
//  Scrolling through a video in Rally Times seeks many times a second. The
//  footage has a keyframe only every 4–8 s, so each seek decodes up to a few
//  hundred frames and scrubbing stutters. A small copy with a keyframe every
//  few frames seeks at once. It's made in the background the first time a
//  video is opened for marking and kept in the project's scrub_proxies
//  folder; its frame times are the original's, so marks made on it are the
//  video's own.
//

import AVFoundation
import Foundation

enum ScrubProxy {
    static let longSide: CGFloat = 960
    static let keyframeInterval = 6

    /// Where `video`'s copy lives, made or not.
    static func url(for video: URL, in datasetRoot: URL) -> URL {
        datasetRoot.appendingPathComponent("scrub_proxies", isDirectory: true)
            .appendingPathComponent(video.deletingPathExtension().lastPathComponent + ".mp4")
    }

    /// The copy of `video`, made first when missing or older than the video;
    /// nil if it can't be made.
    static func ready(for video: URL, in datasetRoot: URL) async -> URL? {
        let fm = FileManager.default
        let proxy = url(for: video, in: datasetRoot)
        let dir = proxy.deletingLastPathComponent()
        if let made = modified(proxy), let source = modified(video), made >= source { return proxy }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let partial = dir.appendingPathComponent(UUID().uuidString + ".partial.mp4")
        let work = Task.detached(priority: .utility) { try await make(from: video, to: partial) }
        do {
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try? fm.removeItem(at: proxy)
            try fm.moveItem(at: partial, to: proxy)
            return proxy
        } catch {
            try? fm.removeItem(at: partial)
            return nil
        }
    }

    private static func modified(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func make(from source: URL, to dest: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let scale = min(1, longSide / max(natural.width, natural.height))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: dest, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: (natural.width * scale / 2).rounded() * 2,
            AVVideoHeightKey: (natural.height * scale / 2).rounded() * 2,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoAverageBitRateKey: 2_500_000,
            ],
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? CocoaError(.fileWriteUnknown)
        }
        writer.startSession(atSourceTime: .zero)
        do {
            while let sample = output.copyNextSampleBuffer() {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                try Task.checkCancellation()
                guard input.append(sample) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard reader.status == .completed, writer.status == .completed else {
            throw reader.error ?? writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }
}
