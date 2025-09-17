//
//  FrameExtractor.swift
//  BumpSetCut
//
//  Created by Infrastructure Layer on 9/17/25.
//

import Foundation
import AVFoundation
import CoreGraphics
import UIKit

/// Infrastructure layer service for extracting video frames with LRU caching
/// Isolates AVFoundation frame extraction from the domain layer
@MainActor
final class FrameExtractor {

    /// Configuration for frame extraction
    struct ExtractionConfig {
        let frameTime: CMTime
        let maximumSize: CGSize
        let appliesPreferredTrackTransform: Bool
        let extractionTimeout: TimeInterval

        static let defaultConfig = ExtractionConfig(
            frameTime: CMTime(seconds: 0.1, preferredTimescale: 600),
            maximumSize: CGSize(width: 640, height: 640),
            appliesPreferredTrackTransform: true,
            extractionTimeout: 0.1 // 100ms
        )
    }

    /// Cache entry containing the extracted frame and metadata
    private struct CacheEntry {
        let image: UIImage
        let extractedAt: Date
        let memoryUsage: Int
    }

    /// LRU cache implementation with automatic eviction
    private final class FrameCache {
        private var cache: [URL: CacheEntry] = [:]
        private var accessOrder: [URL] = []
        private let maxEntries: Int
        private let maxMemoryBytes: Int

        private var currentMemoryUsage: Int = 0

        init(maxEntries: Int = 5, maxMemoryMB: Int = 10) {
            self.maxEntries = maxEntries
            self.maxMemoryBytes = maxMemoryMB * 1024 * 1024
        }

        func get(_ key: URL) -> UIImage? {
            guard let entry = cache[key] else { return nil }

            // Move to front of access order
            moveToFront(key)
            return entry.image
        }

        func set(_ key: URL, image: UIImage) {
            let memoryUsage = estimateMemoryUsage(for: image)
            let entry = CacheEntry(
                image: image,
                extractedAt: Date(),
                memoryUsage: memoryUsage
            )

            // Remove existing entry if present
            if let existingEntry = cache[key] {
                currentMemoryUsage -= existingEntry.memoryUsage
            } else {
                accessOrder.append(key)
            }

            cache[key] = entry
            currentMemoryUsage += memoryUsage
            moveToFront(key)

            // Evict entries if necessary
            evictIfNecessary()
        }

        func clear() {
            cache.removeAll()
            accessOrder.removeAll()
            currentMemoryUsage = 0
        }

        private func moveToFront(_ key: URL) {
            if let index = accessOrder.firstIndex(of: key) {
                accessOrder.remove(at: index)
            }
            accessOrder.insert(key, at: 0)
        }

        private func evictIfNecessary() {
            // Evict by count
            while cache.count > maxEntries {
                evictLeastRecentlyUsed()
            }

            // Evict by memory usage
            while currentMemoryUsage > maxMemoryBytes {
                evictLeastRecentlyUsed()
            }
        }

        private func evictLeastRecentlyUsed() {
            guard let lruKey = accessOrder.last else { return }

            if let entry = cache.removeValue(forKey: lruKey) {
                currentMemoryUsage -= entry.memoryUsage
            }
            accessOrder.removeLast()
        }

        private func estimateMemoryUsage(for image: UIImage) -> Int {
            let size = image.size
            let scale = image.scale
            let pixelCount = Int(size.width * scale * size.height * scale)
            return pixelCount * 4 // 4 bytes per pixel (RGBA)
        }

        var debugDescription: String {
            return "FrameCache(entries: \(cache.count)/\(maxEntries), memory: \(currentMemoryUsage/1024/1024)MB/\(maxMemoryBytes/1024/1024)MB)"
        }
    }

    private let cache = FrameCache()
    private let config: ExtractionConfig
    private let extractionQueue = DispatchQueue(label: "com.bumpsetcut.frameextractor", qos: .userInitiated)

    init(config: ExtractionConfig = .defaultConfig) {
        self.config = config
        setupMemoryPressureMonitoring()
    }

    /// Extract a frame from the video at the configured time (0.1 seconds)
    func extractFrame(from videoURL: URL) async throws -> UIImage {
        // Check cache first
        if let cachedImage = cache.get(videoURL) {
            return cachedImage
        }

        // Extract frame on background queue
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            extractionQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(throwing: FrameExtractionError.extractorReleased)
                    return
                }

                let asset = AVAsset(url: videoURL)
                let imageGenerator = AVAssetImageGenerator(asset: asset)

                // Configure image generator
                imageGenerator.maximumSize = self.config.maximumSize
                imageGenerator.appliesPreferredTrackTransform = self.config.appliesPreferredTrackTransform
                imageGenerator.requestedTimeToleranceBefore = .zero
                imageGenerator.requestedTimeToleranceAfter = .zero

                // Create timeout mechanism
                let timeoutTask = DispatchWorkItem {
                    imageGenerator.cancelAllCGImageGeneration()
                    continuation.resume(throwing: FrameExtractionError.timeoutExceeded)
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + self.config.extractionTimeout, execute: timeoutTask)

                // Extract frame
                let requestedTime = self.config.frameTime
                imageGenerator.generateCGImagesAsynchronously(forTimes: [NSValue(time: requestedTime)]) { [weak imageGenerator] (requestedTime, cgImage, actualTime, result, error) in
                    timeoutTask.cancel()

                    if let error = error {
                        continuation.resume(throwing: FrameExtractionError.avFoundationError(error))
                        return
                    }

                    guard result == .succeeded, let cgImage = cgImage else {
                        continuation.resume(throwing: FrameExtractionError.imageGenerationFailed)
                        return
                    }

                    let uiImage = UIImage(cgImage: cgImage)
                    continuation.resume(returning: uiImage)
                }
            }
        }

        // Cache the extracted image
        await MainActor.run {
            cache.set(videoURL, image: image)
        }

        return image
    }

    /// Clear all cached frames
    func clearCache() {
        cache.clear()
    }

    /// Get current cache status for debugging
    var cacheStatus: String {
        return cache.debugDescription
    }

    // MARK: - Memory Pressure Monitoring

    private func setupMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .warning, queue: .main)

        source.setEventHandler { [weak self] in
            print("⚠️ Memory pressure detected - clearing frame cache")
            self?.cache.clear()
        }

        source.resume()
    }
}

/// Frame extraction specific errors
enum FrameExtractionError: LocalizedError {
    case invalidVideoURL
    case avFoundationError(Error)
    case imageGenerationFailed
    case timeoutExceeded
    case extractorReleased
    case memoryPressure

    var errorDescription: String? {
        switch self {
        case .invalidVideoURL:
            return "Invalid video URL provided for frame extraction"
        case .avFoundationError(let error):
            return "AVFoundation error during frame extraction: \(error.localizedDescription)"
        case .imageGenerationFailed:
            return "Failed to generate image from video frame"
        case .timeoutExceeded:
            return "Frame extraction timed out (exceeded 100ms limit)"
        case .extractorReleased:
            return "Frame extractor was released during extraction"
        case .memoryPressure:
            return "Frame extraction cancelled due to memory pressure"
        }
    }
}