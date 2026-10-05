//
//  ThumbnailService.swift
//  BumpSetCut
//
//  Video stills for cards and thumbnails (cached in memory, so lazy grids
//  don't re-decode on every reappearance) and evenly spaced filmstrips for
//  the trim scrubbers.
//

import UIKit
import AVFoundation

final class ThumbnailService: @unchecked Sendable {  // NSCache is thread-safe; nothing else is mutable
    static let shared = ThumbnailService()

    private let cache = NSCache<NSString, UIImage>()

    init(countLimit: Int = 100) {
        cache.countLimit = countLimit
    }

    // MARK: - Stills

    /// One entry per file, moment *and* size; the file alone would hand every
    /// rally of a game the first rally's frame.
    private static func key(url: URL, time: CMTime, maxSize: CGFloat) -> NSString {
        "\(url.absoluteString)#\(CMTimeGetSeconds(time))@\(Int(maxSize))" as NSString
    }

    /// The still already in memory, if any — lets a view show it without an
    /// async hop when it reappears.
    func cachedStill(url: URL, at time: CMTime = .zero, maxSize: CGFloat = 400) -> UIImage? {
        cache.object(forKey: Self.key(url: url, time: time, maxSize: maxSize))
    }

    /// A frame near `time` (nearest keyframe is fine), at most `maxSize` points
    /// on its long side. Throws `CancellationError` when cancelled or after
    /// `timeout`, so callers can retry later; other errors mean the file can't
    /// produce a frame.
    func still(
        url: URL,
        at time: CMTime = .zero,
        maxSize: CGFloat = 400,
        timeout: Duration = .seconds(8)
    ) async throws -> UIImage {
        let key = Self.key(url: url, time: time, maxSize: maxSize)
        if let cached = cache.object(forKey: key) { return cached }

        // The MIME hint lets extension-less remote URLs open as MP4.
        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetOutOfBandMIMETypeKey": "video/mp4",
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        // Only the one child task below uses it.
        nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let cgImage = try await withThrowingTaskGroup(of: CGImage.self) { group in
            group.addTask { try await generator.image(at: time).image }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CancellationError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
        let image = UIImage(cgImage: cgImage)
        cache.setObject(image, forKey: key)
        return image
    }

    // MARK: - Filmstrips

    /// `count` frames spread evenly over `start...start + duration` (first and
    /// last frame on the ends). Frames that fail to decode are skipped; a
    /// cancelled caller gets whatever was decoded so far.
    func filmstrip(
        url: URL,
        start: Double,
        duration: Double,
        count: Int,
        maxSize: CGFloat = 200
    ) async -> [UIImage] {
        guard count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSize, height: maxSize)

        let times: [CMTime] = (0..<count).map { i in
            let fraction = count > 1 ? Double(i) / Double(count - 1) : 0
            return CMTimeMakeWithSeconds(start + duration * fraction, preferredTimescale: 600)
        }

        var frames: [UIImage] = []
        for await result in generator.images(for: times) {
            guard !Task.isCancelled else { break }
            if let cgImage = try? result.image {
                frames.append(UIImage(cgImage: cgImage))
            }
        }
        return frames
    }
}
